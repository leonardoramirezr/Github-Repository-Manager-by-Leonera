#!/usr/bin/env python3
"""Minimal App Store Connect API helper for CI (Python stdlib + the openssl CLI).

Environment:
  ASC_KEY_ID, ASC_ISSUER_ID  API key id and issuer id
  ASC_KEY_PATH               path to the AuthKey_XXXX.p8 private key

Commands:
  check                        validate the key and require at least one enabled iOS device
  keychain-serials             print the serials of the "Apple Development" certificates in the keychain
  revoke-new-dev-certs FILE    revoke (through the API) the "Apple Development" certificates now in the
                               keychain whose serial is not listed in FILE (output of keychain-serials)
"""

import base64
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com"
DEV_CERT_TYPES = "DEVELOPMENT,IOS_DEVELOPMENT"


class ASCError(Exception):
    pass


def fail(message):
    print(f"::error::{message}")
    sys.exit(1)


def env(name):
    value = os.environ.get(name, "").strip()
    if not value:
        fail(f"Falta la variable de entorno {name}.")
    return value


# --- JWT (ES256) ---------------------------------------------------------------------------------

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw_signature(der):
    """Converts an ASN.1 DER ECDSA signature (what openssl outputs) into JOSE r||s (64 bytes)."""

    def read_length(data, index):
        length = data[index]
        index += 1
        if length & 0x80:
            count = length & 0x7F
            length = int.from_bytes(data[index:index + count], "big")
            index += count
        return length, index

    if der[0] != 0x30:
        raise ASCError("Firma ECDSA inesperada (no es una secuencia DER).")
    _, index = read_length(der, 1)
    parts = []
    for _ in range(2):
        if der[index] != 0x02:
            raise ASCError("Firma ECDSA inesperada (falta un entero DER).")
        length, index = read_length(der, index + 1)
        value = der[index:index + length]
        index += length
        value = value.lstrip(b"\x00")
        if len(value) > 32:
            raise ASCError("Firma ECDSA inesperada (entero demasiado largo).")
        parts.append(value.rjust(32, b"\x00"))
    return parts[0] + parts[1]


def make_token(key_id, issuer_id, key_path, lifetime=1200):
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    now = int(time.time())
    payload = {"iss": issuer_id, "iat": now, "exp": now + lifetime, "aud": "appstoreconnect-v1"}
    signing_input = (
        b64url(json.dumps(header, separators=(",", ":")).encode())
        + "."
        + b64url(json.dumps(payload, separators=(",", ":")).encode())
    )
    result = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path],
        input=signing_input.encode(),
        capture_output=True,
    )
    if result.returncode != 0:
        raise ASCError("openssl no pudo firmar el JWT; ¿es ASC_KEY_P8 una clave .p8 válida? "
                       + result.stderr.decode(errors="replace").strip())
    return signing_input + "." + b64url(der_to_raw_signature(result.stdout))


# --- HTTP ----------------------------------------------------------------------------------------

class Client:
    def __init__(self):
        self.token = make_token(env("ASC_KEY_ID"), env("ASC_ISSUER_ID"), env("ASC_KEY_PATH"))

    def request(self, method, url):
        if not url.startswith("http"):
            url = API + url
        request = urllib.request.Request(url, method=method, headers={
            "Authorization": f"Bearer {self.token}",
            "Accept": "application/json",
        })
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                body = response.read()
                return json.loads(body) if body else None
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")
            try:
                errors = json.loads(detail).get("errors", [])
                detail = "; ".join(f"{e.get('title', '')}: {e.get('detail', '')}" for e in errors) or detail
            except ValueError:
                pass
            raise ASCError(f"{method} {url} → HTTP {error.code}: {detail}") from None

    def get_all(self, path, params):
        url = API + path + "?" + urllib.parse.urlencode(params)
        items = []
        while url:
            page = self.request("GET", url)
            items += page.get("data", [])
            url = page.get("links", {}).get("next")
        return items


# --- Keychain ------------------------------------------------------------------------------------

def normalize_serial(serial):
    return serial.strip().upper().lstrip("0") or "0"


def keychain_dev_serials():
    result = subprocess.run(
        ["security", "find-certificate", "-a", "-c", "Apple Development", "-p"],
        capture_output=True, text=True,
    )
    pems = re.findall(r"-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----", result.stdout, re.S)
    serials = set()
    for pem in pems:
        info = subprocess.run(
            ["openssl", "x509", "-noout", "-serial", "-subject"],
            input=pem, capture_output=True, text=True,
        )
        if info.returncode != 0 or "Apple Development" not in info.stdout:
            continue
        match = re.search(r"serial=([0-9A-Fa-f]+)", info.stdout)
        if match:
            serials.add(normalize_serial(match.group(1)))
    return serials


# --- Commands ------------------------------------------------------------------------------------

def command_check():
    try:
        client = Client()
        devices = client.get_all("/v1/devices", {
            "filter[platform]": "IOS",
            "filter[status]": "ENABLED",
            "fields[devices]": "name,deviceClass,model",
            "limit": "200",
        })
    except ASCError as error:
        fail(f"La clave de App Store Connect no funciona: {error}. Revisa ASC_KEY_ID, ASC_ISSUER_ID y "
             "ASC_KEY_P8 (debe ser una Team Key con rol Admin).")
    print("✓ La clave de App Store Connect funciona.")
    if not devices:
        fail("No hay ningún dispositivo iOS habilitado en el portal de Apple Developer. "
             "Registra el UDID de al menos un iPhone (Certificates, Identifiers & Profiles › Devices).")
    print(f"✓ {len(devices)} dispositivo(s) iOS registrado(s):")
    for device in devices:
        attributes = device.get("attributes", {})
        print(f"  • {attributes.get('name')} ({attributes.get('model') or attributes.get('deviceClass')})")
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a") as handle:
            handle.write(f"devices={len(devices)}\n")


def command_keychain_serials():
    for serial in sorted(keychain_dev_serials()):
        print(serial)


def command_revoke(before_path):
    before = set()
    if os.path.exists(before_path):
        with open(before_path) as handle:
            before = {normalize_serial(line) for line in handle if line.strip()}
    new = keychain_dev_serials() - before
    if not new:
        print("No hay certificados de desarrollo nuevos que revocar.")
        return
    print(f"Certificados «Apple Development» nuevos en el llavero: {', '.join(sorted(new))}")
    try:
        client = Client()
        certificates = client.get_all("/v1/certificates", {
            "filter[certificateType]": DEV_CERT_TYPES,
            "fields[certificates]": "serialNumber,name,displayName,certificateType",
            "limit": "200",
        })
        pending = set(new)
        for certificate in certificates:
            attributes = certificate.get("attributes", {})
            serial = normalize_serial(attributes.get("serialNumber") or "")
            if serial in pending:
                client.request("DELETE", f"/v1/certificates/{certificate['id']}")
                pending.discard(serial)
                print(f"✓ Revocado {attributes.get('displayName') or attributes.get('name')} ({serial})")
        for serial in sorted(pending):
            print(f"::warning::No se encontró en App Store Connect el certificado {serial}; no se revocó.")
    except ASCError as error:
        fail(f"No se pudo revocar el certificado de desarrollo temporal: {error}")


def main(argv):
    if len(argv) >= 2 and argv[1] == "check":
        command_check()
    elif len(argv) >= 2 and argv[1] == "keychain-serials":
        command_keychain_serials()
    elif len(argv) >= 3 and argv[1] == "revoke-new-dev-certs":
        command_revoke(argv[2])
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv)

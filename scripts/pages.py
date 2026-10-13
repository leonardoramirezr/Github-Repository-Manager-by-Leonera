#!/usr/bin/env python3
"""Renders the GitHub Pages install site (Python stdlib only). Used by publish-pages.sh.

  pages.py build DIR    writes manifest.plist, index.html and build.json for one build into DIR
                        (the IPA and icons must already be there). Reads its data from the environment:
                        TAG VERSION BUILD_NUMBER BUNDLE_ID APP_NAME STABLE BRANCH SHA RUN_URL DEVICES
                        IPA_NAME BASE_URL REPO
  pages.py site DIR N   keeps every stable build and the newest N branch builds in DIR, and writes
                        the home page listing them
"""

import datetime
import html
import json
import os
import plistlib
import shutil
import sys
import urllib.parse

STYLE = """
:root { color-scheme: light dark; --bg: #f2f2f7; --card: #fff; --text: #1c1c1e; --muted: #6e6e73;
        --accent: #5856d6; --line: rgba(60,60,67,.18); }
@media (prefers-color-scheme: dark) {
  :root { --bg: #000; --card: #1c1c1e; --text: #f2f2f7; --muted: #98989f; --accent: #7d7aff;
          --line: rgba(84,84,88,.6); } }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--text);
       font: 17px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif; }
main { max-width: 640px; margin: 0 auto; padding: 32px 16px 48px; }
header { text-align: center; margin-bottom: 24px; }
header img { width: 96px; height: 96px; border-radius: 22px; box-shadow: 0 4px 16px rgba(0,0,0,.15); }
h1 { font-size: 28px; margin: 12px 0 4px; }
h2 { font-size: 13px; font-weight: 400; text-transform: uppercase; color: var(--muted); margin: 28px 16px 8px; }
.muted { color: var(--muted); }
.card { background: var(--card); border-radius: 12px; overflow: hidden; }
.row { display: flex; align-items: center; gap: 12px; padding: 12px 16px; border-top: .5px solid var(--line);
       color: inherit; text-decoration: none; }
.row:first-child { border-top: 0; }
.row .grow { flex: 1; min-width: 0; }
.row .title { font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.row .sub { font-size: 14px; color: var(--muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.button { display: block; text-align: center; background: var(--accent); color: #fff; font-weight: 600;
          padding: 14px 20px; border-radius: 12px; text-decoration: none; font-size: 17px; }
.button.small { display: inline-block; padding: 6px 14px; border-radius: 16px; font-size: 15px; }
.badge { font-size: 12px; font-weight: 600; padding: 2px 8px; border-radius: 10px; background: var(--line); }
.badge.stable { background: #34c759; color: #fff; }
dl { margin: 0; }
dl div { display: flex; justify-content: space-between; gap: 16px; padding: 11px 16px;
         border-top: .5px solid var(--line); }
dl div:first-child { border-top: 0; }
dt { color: var(--muted); } dd { margin: 0; text-align: right; overflow-wrap: anywhere; }
.notes { font-size: 14px; color: var(--muted); margin: 8px 16px; }
footer { text-align: center; font-size: 13px; color: var(--muted); margin-top: 32px; }
a { color: var(--accent); }
"""

HELP = """
<h2>Si no se instala</h2>
<p class="notes">Abre esta página en <b>Safari</b> en el iPhone. Si aparece «No se puede instalar la app»,
el UDID del dispositivo no está registrado en el portal de Apple Developer: regístralo y haz un push para
generar un build nuevo. En iOS 16 o posterior activa <b>Ajustes › Privacidad y seguridad › Modo de
desarrollador</b> para poder abrir la app.</p>
"""


def esc(value):
    return html.escape(str(value), quote=True)


def install_url(manifest_url):
    return "itms-services://?action=download-manifest&url=" + urllib.parse.quote(manifest_url, safe="")


def page(title, body, icon=None):
    icon_link = f'<link rel="apple-touch-icon" href="{esc(icon)}">' if icon else ""
    return f"""<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)}</title>
{icon_link}
<style>{STYLE}</style>
</head>
<body><main>
{body}
</main></body>
</html>
"""


def human_size(size):
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024 or unit == "GB":
            return f"{size:.0f} {unit}" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1024


def human_date(iso):
    try:
        moment = datetime.datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ")
        return moment.strftime("%d/%m/%Y %H:%M UTC")
    except ValueError:
        return iso


# --- One build -----------------------------------------------------------------------------------

def render_build(directory):
    e = os.environ
    base = e["BASE_URL"].rstrip("/") + "/"
    tag = e["TAG"]
    folder_url = base + urllib.parse.quote(tag) + "/"
    ipa_name = e["IPA_NAME"]
    manifest_url = folder_url + "manifest.plist"
    stable = e.get("STABLE") == "true"

    info = {
        "tag": tag,
        "app_name": e["APP_NAME"],
        "version": e["VERSION"],
        "build": e["BUILD_NUMBER"],
        "bundle_id": e["BUNDLE_ID"],
        "stable": stable,
        "branch": e.get("BRANCH", ""),
        "commit": e.get("SHA", ""),
        "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "run_url": e.get("RUN_URL", ""),
        "devices": int(e.get("DEVICES") or 0),
        "ipa": ipa_name,
        "ipa_size": os.path.getsize(os.path.join(directory, ipa_name)),
        "page_url": folder_url,
        "manifest_url": manifest_url,
        "install_url": install_url(manifest_url),
    }

    manifest = {
        "items": [{
            "assets": [
                {"kind": "software-package", "url": folder_url + urllib.parse.quote(ipa_name)},
                {"kind": "display-image", "url": folder_url + "icon-57.png"},
                {"kind": "full-size-image", "url": folder_url + "icon-512.png"},
            ],
            "metadata": {
                "bundle-identifier": info["bundle_id"],
                "bundle-version": info["version"],
                "kind": "software",
                "title": info["app_name"],
            },
        }]
    }
    with open(os.path.join(directory, "manifest.plist"), "wb") as handle:
        plistlib.dump(manifest, handle)

    with open(os.path.join(directory, "build.json"), "w") as handle:
        json.dump(info, handle, indent=2, ensure_ascii=False)

    repo = e.get("REPO", "")
    commit_link = (f'<a href="https://github.com/{esc(repo)}/commit/{esc(info["commit"])}">{esc(info["commit"][:7])}</a>'
                   if repo and info["commit"] else esc(info["commit"][:7]))
    run_link = f'<a href="{esc(info["run_url"])}">ver ejecución</a>' if info["run_url"] else ""
    badge = '<span class="badge stable">Estable</span>' if stable else '<span class="badge">Pre-release</span>'
    body = f"""
<header>
  <img src="icon-512.png" alt="">
  <h1>{esc(info["app_name"])}</h1>
  <div class="muted">{esc(tag)} {badge}</div>
</header>
<a class="button" href="{esc(info["install_url"])}">Instalar en este iPhone</a>
<h2>Detalles</h2>
<div class="card"><dl>
  <div><dt>Versión</dt><dd>{esc(info["version"])} ({esc(info["build"])})</dd></div>
  <div><dt>Rama</dt><dd>{esc(info["branch"])}</dd></div>
  <div><dt>Commit</dt><dd>{commit_link}</dd></div>
  <div><dt>Fecha</dt><dd>{esc(human_date(info["date"]))}</dd></div>
  <div><dt>Dispositivos</dt><dd>{info["devices"]} en el perfil Ad Hoc</dd></div>
  <div><dt>Tamaño</dt><dd><a href="{esc(urllib.parse.quote(ipa_name))}">{esc(human_size(info["ipa_size"]))}</a></dd></div>
  <div><dt>Bundle ID</dt><dd>{esc(info["bundle_id"])}</dd></div>
</dl></div>
{HELP}
<footer><a href="../">Todos los builds</a> {"· " + run_link if run_link else ""}</footer>
"""
    with open(os.path.join(directory, "index.html"), "w") as handle:
        handle.write(page(f"{info['app_name']} {tag}", body, icon="icon-512.png"))
    print(json.dumps({k: info[k] for k in ("page_url", "manifest_url", "install_url")}))


# --- Whole site ----------------------------------------------------------------------------------

def load_builds(site):
    builds = []
    for name in os.listdir(site):
        path = os.path.join(site, name, "build.json")
        if os.path.isfile(path):
            try:
                with open(path) as handle:
                    info = json.load(handle)
            except ValueError:
                continue
            info["_dir"] = name
            builds.append(info)
    builds.sort(key=lambda b: (b.get("date", ""), b.get("_dir", "")), reverse=True)
    return builds


def render_site(site, keep_branch_builds):
    builds = load_builds(site)
    stable = [b for b in builds if b.get("stable")]
    branch = [b for b in builds if not b.get("stable")]
    for old in branch[keep_branch_builds:]:
        shutil.rmtree(os.path.join(site, old["_dir"]), ignore_errors=True)
        print(f"Eliminado build antiguo: {old['_dir']}")
    branch = branch[:keep_branch_builds]
    builds = [b for b in builds if b in stable or b in branch]

    app_name = builds[0].get("app_name", "App") if builds else "App"
    if stable:
        latest = stable[0]
        hero = f"""
<a class="button" href="{esc(latest["install_url"])}">Instalar la última versión estable ({esc(latest["tag"])})</a>
<p class="notes" style="text-align:center">Publicada el {esc(human_date(latest.get("date", "")))} ·
<a href="{esc(latest["_dir"])}/">detalles</a></p>"""
        icon = f'{latest["_dir"]}/icon-512.png'
    else:
        hero = '<p class="notes" style="text-align:center">Todavía no hay ninguna versión estable (builds de <code>main</code>).</p>'
        icon = f'{builds[0]["_dir"]}/icon-512.png' if builds else None

    rows = []
    for build in builds:
        badge = '<span class="badge stable">Estable</span>' if build.get("stable") else ""
        rows.append(f"""
<div class="row">
  <a class="grow" href="{esc(build["_dir"])}/" style="color:inherit;text-decoration:none">
    <div class="title">{esc(build.get("tag", build["_dir"]))} {badge}</div>
    <div class="sub">{esc(build.get("branch", ""))} · {esc(build.get("version", ""))} ({esc(build.get("build", ""))}) · {esc(human_date(build.get("date", "")))}</div>
  </a>
  <a class="button small" href="{esc(build.get("install_url", ""))}">Instalar</a>
</div>""")
    listing = "".join(rows) or '<div class="row muted">Sin builds.</div>'
    icon_html = f'<img src="{esc(icon)}" alt="">' if icon else ""
    body = f"""
<header>
  {icon_html}
  <h1>{esc(app_name)}</h1>
  <div class="muted">Instalación Ad Hoc desde Safari</div>
</header>
{hero}
<h2>Todos los builds ({len(builds)})</h2>
<div class="card">{listing}</div>
{HELP}
<footer>Se conservan todas las versiones de <code>main</code> y los últimos {keep_branch_builds} builds de otras ramas.</footer>
"""
    with open(os.path.join(site, "index.html"), "w") as handle:
        handle.write(page(app_name, body, icon=icon))
    open(os.path.join(site, ".nojekyll"), "w").close()


def main(argv):
    if len(argv) == 3 and argv[1] == "build":
        render_build(argv[2])
    elif len(argv) == 4 and argv[1] == "site":
        render_site(argv[2], int(argv[3]))
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv)

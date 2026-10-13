import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// The secrets API requires values to be encrypted with a libsodium "sealed box"
// (crypto_box_seal: X25519 + XSalsa20-Poly1305, nonce = BLAKE2b(epk || pk)).
// CryptoKit only provides the X25519 part, so the rest is implemented here
// to keep the app free of third-party dependencies.

enum SealedBoxError: Error, LocalizedError {
    case invalidPublicKey

    var errorDescription: String? {
        switch self {
        case .invalidPublicKey: "La clave pública del repositorio no es válida."
        }
    }
}

enum SealedBox {
    static let publicKeyLength = 32

    #if canImport(CryptoKit)
    /// Encrypts `message` for `recipientPublicKey` (32 raw bytes), returning
    /// `ephemeralPublicKey || box`, exactly like libsodium's `crypto_box_seal`.
    static func seal(_ message: [UInt8], recipientPublicKey: [UInt8]) throws -> [UInt8] {
        guard recipientPublicKey.count == publicKeyLength else { throw SealedBoxError.invalidPublicKey }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPublicKey)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let sharedBytes = shared.withUnsafeBytes { [UInt8]($0) }
        return seal(
            message,
            recipientPublicKey: recipientPublicKey,
            ephemeralPublicKey: [UInt8](ephemeral.publicKey.rawRepresentation),
            sharedSecret: sharedBytes
        )
    }
    #endif

    /// Deterministic core of `crypto_box_seal`, given an already computed
    /// X25519 shared secret between the ephemeral key and the recipient.
    static func seal(
        _ message: [UInt8],
        recipientPublicKey: [UInt8],
        ephemeralPublicKey: [UInt8],
        sharedSecret: [UInt8]
    ) -> [UInt8] {
        let nonce = Blake2b.hash(ephemeralPublicKey + recipientPublicKey, outputLength: 24)
        // crypto_box_beforenm
        let key = Salsa20.hsalsa20(key: sharedSecret, input: [UInt8](repeating: 0, count: 16))
        return ephemeralPublicKey + secretBox(message, nonce: nonce, key: key)
    }

    /// crypto_secretbox_xsalsa20poly1305: returns `tag || ciphertext`.
    static func secretBox(_ message: [UInt8], nonce: [UInt8], key: [UInt8]) -> [UInt8] {
        let subkey = Salsa20.hsalsa20(key: key, input: Array(nonce[0..<16]))
        let stream = Salsa20.stream(count: 32 + message.count, key: subkey, nonce: Array(nonce[16..<24]))
        let polyKey = Array(stream[0..<32])
        var ciphertext = [UInt8](repeating: 0, count: message.count)
        for i in 0..<message.count {
            ciphertext[i] = message[i] ^ stream[32 + i]
        }
        return Poly1305.authenticate(ciphertext, key: polyKey) + ciphertext
    }
}

// MARK: - Helpers

@inline(__always)
private func load32(_ b: [UInt8], _ i: Int) -> UInt32 {
    UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
}

@inline(__always)
private func store32(_ v: UInt32, into out: inout [UInt8]) {
    out.append(UInt8(truncatingIfNeeded: v))
    out.append(UInt8(truncatingIfNeeded: v >> 8))
    out.append(UInt8(truncatingIfNeeded: v >> 16))
    out.append(UInt8(truncatingIfNeeded: v >> 24))
}

@inline(__always)
private func rotl(_ v: UInt32, _ n: UInt32) -> UInt32 {
    (v << n) | (v >> (32 - n))
}

// MARK: - Salsa20 / HSalsa20

enum Salsa20 {
    private static let sigma: [UInt32] = [0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574]

    private static func rounds(_ x: inout [UInt32]) {
        for _ in 0..<10 {
            // Column round
            x[4] ^= rotl(x[0] &+ x[12], 7); x[8] ^= rotl(x[4] &+ x[0], 9)
            x[12] ^= rotl(x[8] &+ x[4], 13); x[0] ^= rotl(x[12] &+ x[8], 18)
            x[9] ^= rotl(x[5] &+ x[1], 7); x[13] ^= rotl(x[9] &+ x[5], 9)
            x[1] ^= rotl(x[13] &+ x[9], 13); x[5] ^= rotl(x[1] &+ x[13], 18)
            x[14] ^= rotl(x[10] &+ x[6], 7); x[2] ^= rotl(x[14] &+ x[10], 9)
            x[6] ^= rotl(x[2] &+ x[14], 13); x[10] ^= rotl(x[6] &+ x[2], 18)
            x[3] ^= rotl(x[15] &+ x[11], 7); x[7] ^= rotl(x[3] &+ x[15], 9)
            x[11] ^= rotl(x[7] &+ x[3], 13); x[15] ^= rotl(x[11] &+ x[7], 18)
            // Row round
            x[1] ^= rotl(x[0] &+ x[3], 7); x[2] ^= rotl(x[1] &+ x[0], 9)
            x[3] ^= rotl(x[2] &+ x[1], 13); x[0] ^= rotl(x[3] &+ x[2], 18)
            x[6] ^= rotl(x[5] &+ x[4], 7); x[7] ^= rotl(x[6] &+ x[5], 9)
            x[4] ^= rotl(x[7] &+ x[6], 13); x[5] ^= rotl(x[4] &+ x[7], 18)
            x[11] ^= rotl(x[10] &+ x[9], 7); x[8] ^= rotl(x[11] &+ x[10], 9)
            x[9] ^= rotl(x[8] &+ x[11], 13); x[10] ^= rotl(x[9] &+ x[8], 18)
            x[12] ^= rotl(x[15] &+ x[14], 7); x[13] ^= rotl(x[12] &+ x[15], 9)
            x[14] ^= rotl(x[13] &+ x[12], 13); x[15] ^= rotl(x[14] &+ x[13], 18)
        }
    }

    private static func initialState(key: [UInt8], input: [UInt8]) -> [UInt32] {
        [
            sigma[0], load32(key, 0), load32(key, 4), load32(key, 8),
            load32(key, 12), sigma[1], load32(input, 0), load32(input, 4),
            load32(input, 8), load32(input, 12), sigma[2], load32(key, 16),
            load32(key, 20), load32(key, 24), load32(key, 28), sigma[3],
        ]
    }

    /// HSalsa20 with a 32-byte key and a 16-byte input, returning 32 bytes.
    static func hsalsa20(key: [UInt8], input: [UInt8]) -> [UInt8] {
        var x = initialState(key: key, input: input)
        rounds(&x)
        var out: [UInt8] = []
        out.reserveCapacity(32)
        for i in [0, 5, 10, 15, 6, 7, 8, 9] {
            store32(x[i], into: &out)
        }
        return out
    }

    /// Salsa20 keystream with a 32-byte key and an 8-byte nonce.
    static func stream(count: Int, key: [UInt8], nonce: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count + 64)
        var counter: UInt64 = 0
        while out.count < count {
            var input = nonce
            for shift in stride(from: 0, to: 64, by: 8) {
                input.append(UInt8(truncatingIfNeeded: counter >> UInt64(shift)))
            }
            let initial = initialState(key: key, input: input)
            var x = initial
            rounds(&x)
            for i in 0..<16 {
                store32(x[i] &+ initial[i], into: &out)
            }
            counter += 1
        }
        return Array(out[0..<count])
    }
}

// MARK: - Poly1305

enum Poly1305 {
    static func authenticate(_ message: [UInt8], key: [UInt8]) -> [UInt8] {
        let mask: UInt32 = 0x3ff_ffff
        let r0 = load32(key, 0) & 0x3ff_ffff
        let r1 = (load32(key, 3) >> 2) & 0x3ff_ff03
        let r2 = (load32(key, 6) >> 4) & 0x3ff_c0ff
        let r3 = (load32(key, 9) >> 6) & 0x3f0_3fff
        let r4 = (load32(key, 12) >> 8) & 0x00f_ffff
        let s1 = UInt64(r1 * 5), s2 = UInt64(r2 * 5), s3 = UInt64(r3 * 5), s4 = UInt64(r4 * 5)
        let (R0, R1, R2, R3, R4) = (UInt64(r0), UInt64(r1), UInt64(r2), UInt64(r3), UInt64(r4))

        var h0: UInt32 = 0, h1: UInt32 = 0, h2: UInt32 = 0, h3: UInt32 = 0, h4: UInt32 = 0

        var offset = 0
        while offset < message.count {
            let remaining = message.count - offset
            var block: [UInt8]
            let hibit: UInt32
            if remaining >= 16 {
                block = Array(message[offset..<(offset + 16)])
                hibit = 1 << 24
            } else {
                block = Array(message[offset..<message.count])
                block.append(1)
                block += [UInt8](repeating: 0, count: 16 - block.count)
                hibit = 0
            }
            offset += 16

            h0 = h0 &+ (load32(block, 0) & mask)
            h1 = h1 &+ ((load32(block, 3) >> 2) & mask)
            h2 = h2 &+ ((load32(block, 6) >> 4) & mask)
            h3 = h3 &+ ((load32(block, 9) >> 6) & mask)
            h4 = h4 &+ ((load32(block, 12) >> 8) | hibit)

            let H0 = UInt64(h0), H1 = UInt64(h1), H2 = UInt64(h2), H3 = UInt64(h3), H4 = UInt64(h4)
            let d0 = H0 * R0 + H1 * s4 + H2 * s3 + H3 * s2 + H4 * s1
            var d1 = H0 * R1 + H1 * R0 + H2 * s4 + H3 * s3 + H4 * s2
            var d2 = H0 * R2 + H1 * R1 + H2 * R0 + H3 * s4 + H4 * s3
            var d3 = H0 * R3 + H1 * R2 + H2 * R1 + H3 * R0 + H4 * s4
            var d4 = H0 * R4 + H1 * R3 + H2 * R2 + H3 * R1 + H4 * R0

            var c = d0 >> 26; h0 = UInt32(d0 & UInt64(mask))
            d1 += c; c = d1 >> 26; h1 = UInt32(d1 & UInt64(mask))
            d2 += c; c = d2 >> 26; h2 = UInt32(d2 & UInt64(mask))
            d3 += c; c = d3 >> 26; h3 = UInt32(d3 & UInt64(mask))
            d4 += c; c = d4 >> 26; h4 = UInt32(d4 & UInt64(mask))
            h0 = h0 &+ UInt32(c) &* 5
            let carry = h0 >> 26; h0 &= mask
            h1 = h1 &+ carry
        }

        // Fully carry h
        var c = h1 >> 26; h1 &= mask
        h2 = h2 &+ c; c = h2 >> 26; h2 &= mask
        h3 = h3 &+ c; c = h3 >> 26; h3 &= mask
        h4 = h4 &+ c; c = h4 >> 26; h4 &= mask
        h0 = h0 &+ c &* 5; c = h0 >> 26; h0 &= mask
        h1 = h1 &+ c

        // Compute h + -p
        var g0 = h0 &+ 5; c = g0 >> 26; g0 &= mask
        var g1 = h1 &+ c; c = g1 >> 26; g1 &= mask
        var g2 = h2 &+ c; c = g2 >> 26; g2 &= mask
        var g3 = h3 &+ c; c = g3 >> 26; g3 &= mask
        var g4 = h4 &+ c &- (1 << 26)

        // Select h if h < p, or h + -p if h >= p
        var selector = (g4 >> 31) &- 1
        g0 &= selector; g1 &= selector; g2 &= selector; g3 &= selector; g4 &= selector
        selector = ~selector
        h0 = (h0 & selector) | g0
        h1 = (h1 & selector) | g1
        h2 = (h2 & selector) | g2
        h3 = (h3 & selector) | g3
        h4 = (h4 & selector) | g4

        // h = h % 2^128
        h0 = h0 | (h1 << 26)
        h1 = (h1 >> 6) | (h2 << 20)
        h2 = (h2 >> 12) | (h3 << 14)
        h3 = (h3 >> 18) | (h4 << 8)

        // tag = (h + s) % 2^128
        var f = UInt64(h0) + UInt64(load32(key, 16)); h0 = UInt32(truncatingIfNeeded: f)
        f = UInt64(h1) + UInt64(load32(key, 20)) + (f >> 32); h1 = UInt32(truncatingIfNeeded: f)
        f = UInt64(h2) + UInt64(load32(key, 24)) + (f >> 32); h2 = UInt32(truncatingIfNeeded: f)
        f = UInt64(h3) + UInt64(load32(key, 28)) + (f >> 32); h3 = UInt32(truncatingIfNeeded: f)

        var tag: [UInt8] = []
        tag.reserveCapacity(16)
        store32(h0, into: &tag)
        store32(h1, into: &tag)
        store32(h2, into: &tag)
        store32(h3, into: &tag)
        return tag
    }
}

// MARK: - BLAKE2b

enum Blake2b {
    private static let iv: [UInt64] = [
        0x6a09_e667_f3bc_c908, 0xbb67_ae85_84ca_a73b, 0x3c6e_f372_fe94_f82b, 0xa54f_f53a_5f1d_36f1,
        0x510e_527f_ade6_82d1, 0x9b05_688c_2b3e_6c1f, 0x1f83_d9ab_fb41_bd6b, 0x5be0_cd19_137e_2179,
    ]

    private static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
    ]

    @inline(__always)
    private static func rotr(_ v: UInt64, _ n: UInt64) -> UInt64 {
        (v >> n) | (v << (64 - n))
    }

    private static func compress(_ h: inout [UInt64], block: [UInt8], counter: UInt64, last: Bool) {
        var m = [UInt64](repeating: 0, count: 16)
        for i in 0..<16 {
            var word: UInt64 = 0
            for j in 0..<8 {
                word |= UInt64(block[i * 8 + j]) << UInt64(8 * j)
            }
            m[i] = word
        }
        var v = h + iv
        v[12] ^= counter
        if last { v[14] = ~v[14] }

        func g(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
            v[a] = v[a] &+ v[b] &+ x; v[d] = rotr(v[d] ^ v[a], 32)
            v[c] = v[c] &+ v[d]; v[b] = rotr(v[b] ^ v[c], 24)
            v[a] = v[a] &+ v[b] &+ y; v[d] = rotr(v[d] ^ v[a], 16)
            v[c] = v[c] &+ v[d]; v[b] = rotr(v[b] ^ v[c], 63)
        }

        for round in 0..<12 {
            let s = sigma[round % 10]
            g(0, 4, 8, 12, m[s[0]], m[s[1]])
            g(1, 5, 9, 13, m[s[2]], m[s[3]])
            g(2, 6, 10, 14, m[s[4]], m[s[5]])
            g(3, 7, 11, 15, m[s[6]], m[s[7]])
            g(0, 5, 10, 15, m[s[8]], m[s[9]])
            g(1, 6, 11, 12, m[s[10]], m[s[11]])
            g(2, 7, 8, 13, m[s[12]], m[s[13]])
            g(3, 4, 9, 14, m[s[14]], m[s[15]])
        }
        for i in 0..<8 {
            h[i] ^= v[i] ^ v[i + 8]
        }
    }

    /// Unkeyed BLAKE2b with an output length between 1 and 64 bytes.
    /// Inputs are expected to be small (the counter's high word is ignored).
    static func hash(_ input: [UInt8], outputLength: Int) -> [UInt8] {
        precondition(outputLength > 0 && outputLength <= 64)
        var h = iv
        h[0] ^= 0x0101_0000 ^ UInt64(outputLength)

        var offset = 0
        var counter: UInt64 = 0
        repeat {
            let end = min(offset + 128, input.count)
            var block = Array(input[offset..<end])
            counter += UInt64(block.count)
            let last = end == input.count
            block += [UInt8](repeating: 0, count: 128 - block.count)
            compress(&h, block: block, counter: counter, last: last)
            offset = end
        } while offset < input.count

        var out: [UInt8] = []
        out.reserveCapacity(64)
        for word in h {
            for j in 0..<8 {
                out.append(UInt8(truncatingIfNeeded: word >> UInt64(8 * j)))
            }
        }
        return Array(out[0..<outputLength])
    }
}

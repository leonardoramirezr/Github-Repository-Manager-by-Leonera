import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// Vectors generated with libsodium (PyNaCl): crypto_box_seal with fixed keys.
// Run with `make test`.

@main
struct SealedBoxTests {
    static var failures = 0

    static func expect(_ condition: Bool, _ name: String) {
        print(condition ? "✓ \(name)" : "✗ \(name)")
        if !condition { failures += 1 }
    }

    static func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func main() {
        expect(hex(Blake2b.hash([], outputLength: 64)) == "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce", "BLAKE2b-512 empty")
        expect(hex(Blake2b.hash(Array("abc".utf8), outputLength: 24)) == "56a17e38cc371a46b12c32f18e0c61de2a84e9c2555b114e", "BLAKE2b-192 abc")
        expect(hex(Blake2b.hash((0..<300).map { UInt8($0 % 251) }, outputLength: 32)) == "940563f11807c8ba3192299e05cf544b82463742c8a5e80c2a5d81751cd8b0ca", "BLAKE2b-256 multi-block")

        let recipientSecret = bytes("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20")
        let recipientPublic = bytes("07a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c")
        let ephemeralSecret = bytes("65666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f8081828384")
        let ephemeralPublic = bytes("5714769d116bf76436ae74bc793d2c30ad1903c59ac5273805c7e2698b410c36")
        var shared = bytes("c9ea6a3f79a000b60b076d4afc990b272f3f0b5aaa3f0b8713c209273e363863")
        let message = Array("ghp_example-secret-value ñ with a long enough body to span several Salsa20 blocks: ".utf8)
            + (0..<256).map { UInt8($0) } + (0..<256).map { UInt8($0) }
        let expected = "5714769d116bf76436ae74bc793d2c30ad1903c59ac5273805c7e2698b410c365593dcfe026d6fd6a0ffebe07fb8d60b46f6533d667dfd6b6a905e9eba12dd819319d6e5e7fff6c9af5fa1f1f0c4ac9793b11724a27ff97e9690ae7db528cecedf6af49f4c16a6a46b37df54472b4076c85ae8ce0a6a99eafa13f9c74bf69117c2de5b9313a0aba59be31c6bd9cd3ebc19249a8777a35452fcc1e0910db9c8b3be0801aca9a95d78d895de0f7a0bf703da79c4190bbb5dd86cf76e0d8a2eaf79c5f72bfebd47b41b9f332c553990a313945cc54401ad52039e15dfdcd83b665226c5f6ff09a4b0d0bfc1e061a4e51fc3120390014253c93fc878c21bd9fddb6c80f27d6101058a431e6817e87fa56d1e511f82d09373fab25740abedc03416d251b461b71baa26165b4768a8ee4b15b5b72b39c102206585fc946f15609b3f9882dbe640d7695d36b12372446aad49c4056e31a3d64a066c33a922a4277a447e900bc9441359bd8d91142d860bb441b2ddd690bd1fe1e62b1b6e40774b778f8779f787ce7612a9c6fb1fec7454539d352212720e06233ff839c45a4e2e6b9dd30b0b90e91784b03b8afd7a181ef7ccfbc85c366040925841feda3863dcaaec7bc70898f090405a221d57c53e109786bebb11cf407a48fd81a85c1c8579af1b0f747d803f6cebb8deedf9227b90737e731ffeab2f698568770f2f81bd30e66557f644fa51706f8ecf2c1dbbbf9ef24c3ff4d57968d35a83a598dca8d1bdac1665867b1ce63e5d2ce65e158c82094b0b4ac3ead7ac5af80835b89948b386440c2a5512112090c801138b6ef738009d55200477fba8eedc681020cca8a81bbf086a8a02d584d5b51a86ed4e4436c373cd978363f2da8d97b3ff78b78d7aa195e4f739c46e3d"

        #if canImport(CryptoKit)
        do {
            let ephemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: ephemeralSecret)
            let recipient = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: recipientSecret)
            expect([UInt8](ephemeral.publicKey.rawRepresentation) == ephemeralPublic, "CryptoKit ephemeral public key")
            expect([UInt8](recipient.publicKey.rawRepresentation) == recipientPublic, "CryptoKit recipient public key")
            let secret = try ephemeral.sharedSecretFromKeyAgreement(with: recipient.publicKey)
            let computed = secret.withUnsafeBytes { [UInt8]($0) }
            expect(computed == shared, "CryptoKit X25519 shared secret")
            shared = computed

            let randomSeal = try SealedBox.seal(message, recipientPublicKey: recipientPublic)
            expect(randomSeal.count == 32 + 16 + message.count, "Random sealed box length")
        } catch {
            expect(false, "CryptoKit: \(error)")
        }
        #else
        _ = (recipientSecret, ephemeralSecret)
        #endif

        let sealed = SealedBox.seal(message, recipientPublicKey: recipientPublic, ephemeralPublicKey: ephemeralPublic, sharedSecret: shared)
        expect(hex(sealed) == expected, "crypto_box_seal matches libsodium")

        if failures > 0 {
            print("\(failures) test(s) failed")
            exit(1)
        }
        print("All tests passed")
    }
}

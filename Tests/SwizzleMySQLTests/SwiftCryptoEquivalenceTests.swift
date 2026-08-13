import Crypto
import Foundation
import Testing
@testable import SwizzleMySQL

/// Proves two things at once, and is the single most valuable test on this code.
///
/// MariaDB's `client_ed25519` is **standard ed25519 with the 32-byte seed
/// replaced by the password bytes** — nothing else differs. So whenever the
/// password happens to be exactly 32 bytes long, the two schemes coincide, and
/// swift-crypto (BoringSSL) must produce byte-identical output to `Ed25519Core`.
///
/// 1. It is the strongest available correctness oracle: agreement with a full
///    production ed25519 implementation over its entire signing path — key
///    expansion, clamping, nonce derivation, scalar multiplication, reduction
///    and encoding.
/// 2. It is the precise, demonstrable reason swift-crypto **cannot** be used for
///    this plugin in general. `Curve25519.Signing.PrivateKey` has exactly two
///    initialisers — random, and `rawRepresentation` requiring exactly 32 bytes
///    — and expands the seed internally with SHA-512. Real passwords are not
///    32 bytes, and there is no entry point that accepts an already-expanded
///    key. The equivalence below holds *only* at that one length.
@Suite("ed25519 vs swift-crypto")
struct SwiftCryptoEquivalenceTests {

    static func bytes(seed: UInt64, count: Int) -> [UInt8] {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 33)
        }
    }

    /// A 32-byte password, chosen so it survives a UTF-8 round trip through the
    /// `String` API our plugin takes.
    static func password(seed: UInt64) -> (text: String, raw: [UInt8]) {
        let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEF".utf8)
        let raw = bytes(seed: seed, count: 32).map { letters[Int($0) % letters.count] }
        return (String(decoding: raw, as: UTF8.self), raw)
    }

    @Test func publicKeysMatchBoringSSLAt32Bytes() throws {
        for seed in 0..<100 {
            let (text, raw) = Self.password(seed: UInt64(seed))
            let ours = try MySQLEd25519.publicKey(password: text)
            let theirs = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
                .publicKey.rawRepresentation
            #expect(ours == Array(theirs), "seed \(seed)")
        }
    }

    /// Whether this platform's ed25519 signing is deterministic.
    ///
    /// **It is not everywhere, which was a surprise.** On Linux swift-crypto
    /// uses BoringSSL and signs deterministically per RFC 8032 §5.1.6 — the
    /// nonce is derived from the key and message alone. On Apple platforms
    /// `Crypto` forwards to the system CryptoKit, which produces *hedged*
    /// signatures: the same key and message give a different signature each
    /// time. Both are valid ed25519 and both verify; only the byte-for-byte
    /// comparison below is affected.
    static var signingIsDeterministic: Bool {
        guard let key = try? Curve25519.Signing.PrivateKey(
            rawRepresentation: bytes(seed: 7, count: 32)
        ) else { return false }
        let message = Data(bytes(seed: 8, count: 32))
        guard let first = try? key.signature(for: message),
              let second = try? key.signature(for: message) else { return false }
        return first == second
    }

    /// The full signing path against a production implementation.
    ///
    /// Byte-equality is the strongest form of this check and is used wherever
    /// the platform signs deterministically. Where it does not, the comparison
    /// would be meaningless, so it degrades to mutual verification — each side
    /// validating the other's signature under the same derived key — which still
    /// pins the key derivation, the encoding, and the message convention.
    @Test func signaturesAgreeWithSwiftCryptoAt32Bytes() throws {
        for seed in 0..<100 {
            let (text, raw) = Self.password(seed: UInt64(seed))
            let scramble = Self.bytes(seed: UInt64(seed) &+ 31_337, count: 32)

            let ours = try MySQLEd25519.sign(password: text, scramble: scramble)
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
            let theirs = try key.signature(for: Data(scramble))

            if Self.signingIsDeterministic {
                #expect(ours == Array(theirs), "signature mismatch at seed \(seed)")
            }

            // Holds on every platform: they accept ours, and we derive the key
            // theirs verifies under.
            #expect(
                key.publicKey.isValidSignature(Data(ours), for: Data(scramble)),
                "swift-crypto rejected our signature at seed \(seed)"
            )
            let derived = try Curve25519.Signing.PublicKey(
                rawRepresentation: MySQLEd25519.publicKey(password: text)
            )
            #expect(
                derived.isValidSignature(theirs, for: Data(scramble)),
                "our derived key rejected swift-crypto's signature at seed \(seed)"
            )
        }
    }

    /// Records the platform behaviour rather than asserting one of them, so a
    /// future change in either direction is visible instead of silent.
    @Test func reportsWhetherSigningIsDeterministic() {
        print("INFO swift-crypto ed25519 deterministic: \(Self.signingIsDeterministic)")
    }

    /// The constraint itself, pinned. This is what forces `Ed25519Core` to
    /// exist: anything other than 32 bytes is rejected outright, and MariaDB
    /// passwords are arbitrary length.
    @Test(arguments: [0, 1, 8, 11, 31, 33, 64])
    func swiftCryptoRejectsEverySeedLengthButThirtyTwo(length: Int) {
        #expect(throws: (any Error).self) {
            _ = try Curve25519.Signing.PrivateKey(
                rawRepresentation: [UInt8](repeating: 0x41, count: length)
            )
        }
    }

    /// And the practical consequence: the real fixture password is 11 bytes, so
    /// swift-crypto cannot express its key at all.
    @Test func theActualFixturePasswordIsNotUsableWithSwiftCrypto() {
        #expect(Array("ed25519pass".utf8).count == 11)
        #expect(throws: (any Error).self) {
            _ = try Curve25519.Signing.PrivateKey(rawRepresentation: Array("ed25519pass".utf8))
        }
    }
}

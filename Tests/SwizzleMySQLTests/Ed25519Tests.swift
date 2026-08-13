import Crypto
import Foundation
import Testing
@testable import SwizzleMySQL

/// MariaDB `client_ed25519`.
///
/// The strongest available oracle is MariaDB itself: `CREATE USER ... IDENTIFIED
/// VIA ed25519 USING PASSWORD('x')` stores the base64 of the ed25519 **public
/// key** derived from that password. If our derivation matches the server's
/// stored value, the scalar arithmetic and the password-seeded expansion are
/// both right — and a correct public key is what makes the signature verify.
@Suite("ed25519 (MariaDB)")
struct Ed25519Tests {

    /// Taken from a live MariaDB 12.2.2 for `IDENTIFIED VIA ed25519 USING
    /// PASSWORD('ed25519pass')`, which is the fixture account.
    static let fixturePassword = "ed25519pass"
    static let fixturePublicKeyBase64 = "/JMmQAHuIaOsVNKyutTNtcJOKU9Js5bt8LwRQGRyYB8"

    /// MariaDB stores the key unpadded; Foundation wants padding.
    static func decodeBase64(_ text: String) -> [UInt8]? {
        var padded = text
        while padded.count % 4 != 0 { padded += "=" }
        return Data(base64Encoded: padded).map(Array.init)
    }

    @Test func publicKeyMatchesWhatMariaDBStores() throws {
        let derived = try MySQLEd25519.publicKey(password: Self.fixturePassword)
        let expected = Self.decodeBase64(Self.fixturePublicKeyBase64)

        #expect(expected != nil)
        #expect(derived.count == 32)
        #expect(derived == expected, "derived public key does not match the server's")
    }

    /// The key is derived from the password, so a different password must give a
    /// different key — otherwise the match above could be coincidental.
    @Test func differentPasswordsGiveDifferentKeys() throws {
        let a = try MySQLEd25519.publicKey(password: Self.fixturePassword)
        let b = try MySQLEd25519.publicKey(password: "something else")
        #expect(a != b)
    }

    @Test func signatureHasTheExpectedShape() throws {
        let scramble = [UInt8](1...32)
        let signature = try MySQLEd25519.sign(password: Self.fixturePassword, scramble: scramble)
        #expect(signature.count == MySQLEd25519.signatureLength)   // R || S
    }

    /// ed25519 signing is deterministic — the nonce comes from the key and the
    /// message, not from randomness. The same inputs must always sign the same.
    @Test func signingIsDeterministic() throws {
        let scramble = [UInt8](repeating: 0xAB, count: 32)
        let first = try MySQLEd25519.sign(password: Self.fixturePassword, scramble: scramble)
        let second = try MySQLEd25519.sign(password: Self.fixturePassword, scramble: scramble)
        #expect(first == second)
    }

    /// Different scrambles must give different signatures, or a captured
    /// response could be replayed.
    @Test func signatureDependsOnTheScramble() throws {
        let a = try MySQLEd25519.sign(
            password: Self.fixturePassword, scramble: [UInt8](repeating: 0x01, count: 32)
        )
        let b = try MySQLEd25519.sign(
            password: Self.fixturePassword, scramble: [UInt8](repeating: 0x02, count: 32)
        )
        #expect(a != b)
    }

    /// An empty password sends an empty response, as with every other plugin.
    @Test func emptyPasswordProducesEmptyResponse() throws {
        let signature = try MySQLEd25519.sign(password: "", scramble: [UInt8](1...32))
        #expect(signature.isEmpty)
    }

    /// Standard ed25519 clamping: clear the low three bits, clear the top bit,
    /// set bit 254.
    @Test func clampingFollowsRFC8032() {
        let clamped = MySQLEd25519.clamp([UInt8](repeating: 0xFF, count: 32))
        #expect(clamped[0] & 0b0000_0111 == 0)
        #expect(clamped[31] & 0b1000_0000 == 0)
        #expect(clamped[31] & 0b0100_0000 != 0)
    }

    /// The signature verifies under the derived public key using an independent
    /// implementation — swift-crypto — which checks the arithmetic end to end
    /// rather than only its shape.
    @Test func signatureVerifiesUnderTheDerivedKey() throws {
        let scramble = [UInt8](repeating: 0x5A, count: 32)
        let signature = try MySQLEd25519.sign(password: Self.fixturePassword, scramble: scramble)
        let publicKeyBytes = try MySQLEd25519.publicKey(password: Self.fixturePassword)

        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyBytes)
        #expect(
            publicKey.isValidSignature(Data(signature), for: Data(scramble)),
            "swift-crypto rejected the signature we produced"
        )
    }

    @Test func nonASCIIPasswordsHashOverUTF8() throws {
        // Derivation runs over raw UTF-8 bytes, with no normalisation.
        let key = try MySQLEd25519.publicKey(password: "pÄss‑wörd")
        #expect(key.count == 32)
    }
}

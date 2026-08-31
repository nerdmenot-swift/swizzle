import Crypto
import Foundation
import Testing
@testable import SwizzleMySQL

/// MariaDB `parsec` (11.6+).
///
/// Same oracle strategy as `client_ed25519`: MariaDB stores what the password
/// derives to, so we can check our derivation against the server's own value
/// without a live connection. Parsec's stored form is richer — it keeps the
/// salt and iteration factor alongside the public key, which means the fixture
/// below pins *every* input to the KDF, not just its output.
///
/// The reference (`rust-mysql-common/src/auth/plugins/parsec.rs`) ships no test
/// vectors, so this is the strongest oracle available.
@Suite("parsec (MariaDB)")
struct ParsecTests {

    /// From a live MariaDB 12.2.2 for the fixture account
    /// `IDENTIFIED VIA parsec USING PASSWORD('parsecpass')`. MariaDB stores it
    /// in `mysql.global_priv` as `P<factor>:<base64 salt>:<base64 public key>`.
    static let fixturePassword = "parsecpass"
    static let fixtureFactor: UInt8 = 0
    static let fixtureSaltBase64 = "Csl7Kdcsc5bB8Brr/cwj80zK"
    static let fixturePublicKeyBase64 = "WxU1o4rcpIWdmRLCelCwxUz0qzI0gS6b9ZkB4JOcBhw"

    /// MariaDB stores these unpadded; Foundation wants padding.
    static func decodeBase64(_ text: String) -> [UInt8]? {
        var padded = text
        while padded.count % 4 != 0 { padded += "=" }
        return Data(base64Encoded: padded).map(Array.init)
    }

    static func fixtureAuthString() throws -> MySQLParsec.AuthString {
        let salt = try #require(decodeBase64(fixtureSaltBase64))
        return MySQLParsec.AuthString(factor: fixtureFactor, salt: salt)
    }

    // MARK: - The oracle

    /// The whole KDF chain in one check: PBKDF2-HMAC-SHA512 over the password
    /// with the server's salt and iteration count, then ed25519 expansion. If
    /// any part were wrong — digest, round count, output length, seed handling —
    /// the public key would not match what MariaDB stored.
    @Test func publicKeyMatchesWhatMariaDBStores() throws {
        let derived = try MySQLParsec.publicKey(
            password: Self.fixturePassword, authString: Self.fixtureAuthString()
        )
        let expected = Self.decodeBase64(Self.fixturePublicKeyBase64)

        #expect(expected != nil)
        #expect(derived.count == 32)
        #expect(derived == expected, "derived public key does not match the server's")
    }

    /// Guards against the match above being coincidental.
    @Test func differentPasswordsGiveDifferentKeys() throws {
        let authString = try Self.fixtureAuthString()
        let a = try MySQLParsec.publicKey(password: Self.fixturePassword, authString: authString)
        let b = try MySQLParsec.publicKey(password: "something else", authString: authString)
        #expect(a != b)
    }

    /// The salt is the server's contribution to the KDF; ignoring it would still
    /// produce a working-looking key, so check it actually feeds in.
    @Test func differentSaltsGiveDifferentKeys() throws {
        let original = try Self.fixtureAuthString()
        var altered = original
        altered.salt[0] ^= 0xFF

        let a = try MySQLParsec.publicKey(password: Self.fixturePassword, authString: original)
        let b = try MySQLParsec.publicKey(password: Self.fixturePassword, authString: altered)
        #expect(a != b)
    }

    /// Likewise the iteration factor — an off-by-one in `1024 << factor` would
    /// otherwise go unnoticed until a server with a non-zero factor rejected us.
    @Test func differentFactorsGiveDifferentKeys() throws {
        var original = try Self.fixtureAuthString()
        original.factor = 0
        var altered = original
        altered.factor = 1

        let a = try MySQLParsec.publicKey(password: Self.fixturePassword, authString: original)
        let b = try MySQLParsec.publicKey(password: Self.fixturePassword, authString: altered)
        #expect(a != b)
    }

    // MARK: - Auth string parsing

    @Test func parsesTheServersAuthString() throws {
        let salt = try #require(Self.decodeBase64(Self.fixtureSaltBase64))
        let parsed = try MySQLParsec.AuthString.parse([UInt8(ascii: "P"), 2] + salt)

        #expect(parsed.factor == 2)
        #expect(parsed.salt == salt)
        #expect(parsed.iterations == 4096)          // 1024 << 2
    }

    @Test(arguments: [0, 1, 2, 3] as [UInt8])
    func iterationCountDoublesWithTheFactor(factor: UInt8) throws {
        var authString = try Self.fixtureAuthString()
        authString.factor = factor
        #expect(authString.iterations == 1024 << Int(factor))
    }

    @Test func rejectsAnUnknownAlgorithmMarker() throws {
        let salt = try #require(Self.decodeBase64(Self.fixtureSaltBase64))
        #expect(throws: (any Error).self) {
            _ = try MySQLParsec.AuthString.parse([UInt8(ascii: "Q"), 0] + salt)
        }
    }

    /// A factor above 3 is out of range. Without this bound a hostile server
    /// could name a huge iteration count and stall the client in the KDF.
    @Test func rejectsAnOutOfRangeFactor() throws {
        let salt = try #require(Self.decodeBase64(Self.fixtureSaltBase64))
        #expect(throws: (any Error).self) {
            _ = try MySQLParsec.AuthString.parse([UInt8(ascii: "P"), 4] + salt)
        }
    }

    @Test(arguments: [0, 19, 21, 64])
    func rejectsAWrongLengthAuthString(length: Int) {
        #expect(throws: (any Error).self) {
            _ = try MySQLParsec.AuthString.parse([UInt8](repeating: UInt8(ascii: "P"), count: length))
        }
    }

    // MARK: - Response

    /// `client_scramble || signature`, and the server reads the nonce back out
    /// of the prefix — so the prefix must be exactly what we signed with.
    @Test func responseIsTheClientNonceFollowedByTheSignature() throws {
        let serverScramble = [UInt8](repeating: 0x11, count: 32)
        let clientScramble = [UInt8](repeating: 0x22, count: 32)

        let response = try MySQLParsec.response(
            password: Self.fixturePassword,
            serverScramble: serverScramble,
            authString: Self.fixtureAuthString(),
            clientScramble: clientScramble
        )

        #expect(response.count == MySQLParsec.responseLength)   // 32 + 64
        #expect(Array(response.prefix(32)) == clientScramble)
    }

    /// The end-to-end check: the signature must verify, under the key MariaDB
    /// stores, over exactly `server_scramble || client_scramble`. Getting the
    /// message order or contents wrong still yields a well-formed 96-byte
    /// response — only verification catches it.
    @Test func signatureVerifiesOverServerThenClientScramble() throws {
        let serverScramble = [UInt8](1...32)
        let clientScramble = [UInt8](33...64)

        let response = try MySQLParsec.response(
            password: Self.fixturePassword,
            serverScramble: serverScramble,
            authString: Self.fixtureAuthString(),
            clientScramble: clientScramble
        )
        let signature = Array(response.suffix(64))

        let stored = try #require(Self.decodeBase64(Self.fixturePublicKeyBase64))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: stored)

        #expect(
            publicKey.isValidSignature(Data(signature), for: Data(serverScramble + clientScramble)),
            "signature did not verify under the public key MariaDB stores"
        )
        // The reverse order must NOT verify, or the assertion above proves little.
        #expect(
            !publicKey.isValidSignature(
                Data(signature), for: Data(clientScramble + serverScramble)
            )
        )
    }

    @Test func wrongPasswordDoesNotVerify() throws {
        let serverScramble = [UInt8](repeating: 0x5A, count: 32)
        let clientScramble = [UInt8](repeating: 0xA5, count: 32)

        let response = try MySQLParsec.response(
            password: "not-the-password",
            serverScramble: serverScramble,
            authString: Self.fixtureAuthString(),
            clientScramble: clientScramble
        )
        let signature = Array(response.suffix(64))

        let stored = try #require(Self.decodeBase64(Self.fixturePublicKeyBase64))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: stored)

        #expect(!publicKey.isValidSignature(
            Data(signature), for: Data(serverScramble + clientScramble)
        ))
    }

    /// The client nonce defends against replay, so it must not repeat.
    @Test func generatedClientNoncesDiffer() throws {
        let serverScramble = [UInt8](repeating: 0x01, count: 32)
        let authString = try Self.fixtureAuthString()

        let first = try MySQLParsec.response(
            password: Self.fixturePassword, serverScramble: serverScramble, authString: authString
        )
        let second = try MySQLParsec.response(
            password: Self.fixturePassword, serverScramble: serverScramble, authString: authString
        )
        #expect(Array(first.prefix(32)) != Array(second.prefix(32)))
        #expect(first != second)
    }

    @Test(arguments: [0, 31, 33])
    func rejectsAWrongLengthServerScramble(length: Int) throws {
        let authString = try Self.fixtureAuthString()
        #expect(throws: (any Error).self) {
            _ = try MySQLParsec.response(
                password: Self.fixturePassword,
                serverScramble: [UInt8](repeating: 0, count: length),
                authString: authString
            )
        }
    }

    @Test func rejectsAWrongLengthClientScramble() throws {
        let authString = try Self.fixtureAuthString()
        #expect(throws: (any Error).self) {
            _ = try MySQLParsec.response(
                password: Self.fixturePassword,
                serverScramble: [UInt8](repeating: 0, count: 32),
                authString: authString,
                clientScramble: [UInt8](repeating: 0, count: 16)
            )
        }
    }

    // MARK: - Parsing the server's challenge

    /// The iteration factor's upper bound, which nothing was checking.
    ///
    /// `iterations` is `1024 << factor`, so the cap is what stops a hostile
    /// server asking for an unbounded amount of PBKDF2 work — shifting by 200
    /// is undefined-ish nonsense and shifting by 40 is a client that hangs
    /// burning CPU on a login. The bound is documented as 3 and the guard is
    /// `<= 3`; the sweep relaxed it to `< 3` and nothing failed, because every
    /// test used the fixture's own factor.
    ///
    /// Both sides of the boundary, since narrowing it rejects a challenge the
    /// server is entitled to send and widening it accepts one it is not.
    @Test("the iteration factor is accepted up to three and refused above")
    func iterationFactorBounds() throws {
        func challenge(factor: UInt8) -> [UInt8] {
            [UInt8(ascii: "P"), factor] + [UInt8](repeating: 0x5A, count: MySQLParsec.saltLength)
        }

        for factor: UInt8 in 0...3 {
            let parsed = try MySQLParsec.AuthString.parse(challenge(factor: factor))
            #expect(parsed.factor == factor)
            #expect(parsed.iterations == 1024 << Int(factor))
        }
        #expect(throws: MySQLProtocolError.self) {
            _ = try MySQLParsec.AuthString.parse(challenge(factor: 4))
        }
        #expect(throws: MySQLProtocolError.self) {
            _ = try MySQLParsec.AuthString.parse(challenge(factor: 255))
        }
    }

    /// The algorithm marker and the length, which frame everything after them.
    @Test("a challenge of the wrong shape is refused")
    func malformedChallenge() throws {
        let salt = [UInt8](repeating: 0x5A, count: MySQLParsec.saltLength)

        #expect(throws: MySQLProtocolError.self) {
            _ = try MySQLParsec.AuthString.parse([UInt8(ascii: "X"), 1] + salt)
        }
        #expect(throws: MySQLProtocolError.self) {
            _ = try MySQLParsec.AuthString.parse([UInt8(ascii: "P"), 1])
        }
        #expect(throws: MySQLProtocolError.self) {
            _ = try MySQLParsec.AuthString.parse([])
        }
        #expect(throws: MySQLProtocolError.self) {
            _ = try MySQLParsec.AuthString.parse([UInt8(ascii: "P"), 1] + salt + [0x00])
        }
    }

    /// The salt is everything after the two header bytes, and it has to survive
    /// intact — a slice taken from the wrong offset changes every derived key.
    @Test("the salt is the bytes after the header, unaltered")
    func saltIsPreserved() throws {
        let salt = (0..<MySQLParsec.saltLength).map { UInt8($0 % 256) }
        let parsed = try MySQLParsec.AuthString.parse([UInt8(ascii: "P"), 2] + salt)
        #expect(parsed.salt == salt)
        #expect(parsed.factor == 2)
    }

}

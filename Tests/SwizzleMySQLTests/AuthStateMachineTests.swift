import Crypto
import Foundation
import NIOCore
import Testing
@testable import SwizzleMySQL

@Suite("Auth state machine")
struct AuthStateMachineTests {

    static let scramble: [UInt8] = Array(1...20)

    static func packet(_ bytes: [UInt8]) -> MySQLPacket {
        var buffer = ByteBuffer()
        buffer.writeBytes(bytes)
        return MySQLPacket(sequenceID: 0, payload: buffer)
    }

    static func handshakePacket(
        plugin: String = "mysql_native_password",
        serverVersion: String = "8.4.0",
        capabilitiesLow: UInt16 = 0xFFFF,
        mariaDBExtended: UInt32 = 0
    ) -> MySQLPacket {
        let buffer = HandshakeTests.makeHandshake(
            serverVersion: serverVersion,
            pluginName: plugin,
            scramble: scramble,
            capabilitiesLow: capabilitiesLow,
            mariaDBExtended: mariaDBExtended
        )
        return MySQLPacket(sequenceID: 0, payload: buffer)
    }

    /// Minimal OK: header, affected_rows, last_insert_id, status, warnings.
    static let okPacket = packet([0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00])

    static func machine(
        password: String = "secret",
        secure: Bool = false,
        allowCleartext: Bool = false,
        serverPublicKey: MySQLConnectionConfiguration.ServerPublicKey = .refuse,
        tls: MySQLConnectionConfiguration.TLSMode = .disable
    ) -> MySQLAuthStateMachine {
        MySQLAuthStateMachine(
            configuration: .init(
                username: "root",
                password: password,
                isSecureTransport: secure,
                tls: tls,
                allowCleartextPlugin: allowCleartext,
                serverPublicKey: serverPublicKey
            )
        )
    }

    // MARK: - Happy paths

    @Test func nativePasswordHappyPath() {
        var sm = Self.machine()

        guard case .sendHandshakeResponse(let response, let pluginName, let negotiated) =
                sm.receive(Self.handshakePacket()) else {
            Issue.record("expected handshake response"); return
        }
        #expect(pluginName == "mysql_native_password")
        #expect(response == MySQLAuth.nativePassword(password: "secret", scramble: Self.scramble))
        #expect(negotiated.capabilities.contains(.protocol41))

        guard case .authenticated = sm.receive(Self.okPacket) else {
            Issue.record("expected authenticated"); return
        }
        #expect(sm.state == .authenticated)
    }

    @Test func cachingSHA2FastAuthSuccess() {
        var sm = Self.machine()
        _ = sm.receive(Self.handshakePacket(plugin: "caching_sha2_password"))

        // AuthMoreData 0x01 0x03 = fast_auth_success. The server sends an OK
        // next and expects *nothing* in between. Replying with an empty packet
        // consumes a sequence number the server never expected, and the desync
        // only surfaces on the next command as "Got packets out of order" —
        // which is exactly how this was found.
        guard case .wait = sm.receive(Self.packet([0x01, 0x03])) else {
            Issue.record("fast_auth_success must send nothing"); return
        }

        guard case .authenticated = sm.receive(Self.okPacket) else {
            Issue.record("expected authenticated"); return
        }
    }

    /// On TLS or a unix socket the RSA exchange is skipped entirely.
    @Test func fullAuthOverSecureTransportSendsCleartext() {
        var sm = Self.machine(secure: true)
        _ = sm.receive(Self.handshakePacket(plugin: "caching_sha2_password"))

        guard case .sendCleartextPassword(let bytes) =
                sm.receive(Self.packet([0x01, 0x04])) else {
            Issue.record("expected cleartext password"); return
        }
        #expect(bytes == Array("secret".utf8) + [0])

        guard case .authenticated = sm.receive(Self.okPacket) else {
            Issue.record("expected authenticated"); return
        }
    }

    /// The path that is genuinely awkward to reach against a real server, and
    /// the one with the subtle step: the password is XORed with the nonce
    /// *before* RSA encryption. Omitting that makes the server reject an
    /// otherwise correctly encrypted password.
    ///
    /// The exchange has to be opted into now — see ``ServerPublicKeyPolicyTests``
    /// for why, and for what happens when it is not.
    @Test func fullAuthOverPlaintextRequestsKeyAndXORsPassword() {
        var sm = Self.machine(secure: false, serverPublicKey: .requestFromServer)
        _ = sm.receive(Self.handshakePacket(plugin: "caching_sha2_password"))

        guard case .requestPublicKey = sm.receive(Self.packet([0x01, 0x04])) else {
            Issue.record("expected public key request"); return
        }

        let pem = Array("-----BEGIN PUBLIC KEY-----".utf8)
        guard case .encryptAndSend(let plaintext, let key) =
                sm.receive(Self.packet([0x01] + pem)) else {
            Issue.record("expected encryptAndSend"); return
        }
        #expect(key == pem)

        var expected = Array("secret".utf8) + [0]
        for i in expected.indices { expected[i] ^= Self.scramble[i % Self.scramble.count] }
        #expect(plaintext == expected)

        guard case .authenticated = sm.receive(Self.okPacket) else {
            Issue.record("expected authenticated"); return
        }
    }

    // MARK: - Auth switch

    @Test func authSwitchIsHonouredOnce() {
        var sm = Self.machine()
        _ = sm.receive(Self.handshakePacket(plugin: "caching_sha2_password"))

        let newScramble = [UInt8](repeating: 0x5A, count: 20)
        var switchPayload: [UInt8] = [0xFE]
        switchPayload += Array("mysql_native_password".utf8) + [0]
        switchPayload += newScramble + [0]

        guard case .sendAuthData(let response) = sm.receive(Self.packet(switchPayload)) else {
            Issue.record("expected auth switch response"); return
        }
        // Recomputed with the *new* scramble, not the handshake one.
        #expect(response == MySQLAuth.nativePassword(password: "secret", scramble: newScramble))
        #expect(sm.hasAuthSwitched)
    }

    /// A second switch is either a broken server or a downgrade attempt.
    @Test func repeatedAuthSwitchIsRejected() {
        var sm = Self.machine()
        _ = sm.receive(Self.handshakePacket(plugin: "caching_sha2_password"))

        var payload: [UInt8] = [0xFE]
        payload += Array("mysql_native_password".utf8) + [0]
        payload += [UInt8](repeating: 0x5A, count: 20) + [0]
        _ = sm.receive(Self.packet(payload))

        guard case .fail(let error) = sm.receive(Self.packet(payload)) else {
            Issue.record("expected failure"); return
        }
        #expect(error == .repeatedAuthSwitch)
    }

    /// An auth switch to `client_ed25519` produces a real signature over the
    /// switch's fresh scramble.
    @Test func ed25519SwitchProducesASignature() throws {
        var sm = Self.machine()
        _ = sm.receive(Self.handshakePacket())

        // No trailing NUL: MariaDB sends `client_ed25519` a bare 32-byte
        // scramble. This fixture used to append one, which is precisely the
        // shape that hid the truncation bug — see `AuthSwitchFramingTests`.
        let newScramble = [UInt8](repeating: 0x11, count: 32)
        var payload: [UInt8] = [0xFE]
        payload += Array("client_ed25519".utf8) + [0]
        payload += newScramble

        guard case .sendAuthData(let response) = sm.receive(Self.packet(payload)) else {
            Issue.record("expected an ed25519 signature"); return
        }
        #expect(response.count == MySQLEd25519.signatureLength)
        // Computed over the *switch* scramble, not the handshake one.
        let expected = try MySQLEd25519.sign(password: "secret", scramble: newScramble)
        #expect(response == expected)
    }

    // MARK: - sha256_password
    //
    // The test matrix is MariaDB-only, and MariaDB implements neither
    // `sha256_password` nor `caching_sha2_password`. These tests are therefore
    // the *only* coverage this plugin can have, which is why they walk the
    // whole exchange rather than just checking the first response.

    static let sha256Scramble = [UInt8](repeating: 0x77, count: 20)

    /// `sha256_password` only ever arrives by auth switch — see
    /// `greetingNamingSha256FallsBackToNativePassword` below for why.
    static func sha256Switch() -> MySQLPacket {
        var payload: [UInt8] = [0xFE]
        payload += Array("sha256_password".utf8) + [0]
        payload += sha256Scramble + [0]
        return packet(payload)
    }

    /// Over **TLS** the password goes in the clear, NUL-terminated, and the RSA
    /// exchange never happens.
    ///
    /// TLS specifically, not "a secure transport". This test used to assert the
    /// same for a unix socket, which was wrong: MySQL does not accept cleartext
    /// `sha256_password` over a socket, and the test was encoding a bug rather
    /// than catching it. See `ServerPublicKeyPolicyTests.sha256OverUnixSocket`
    /// for the socket, and how the server settled it.
    @Test func sha256OverTLSSendsCleartext() {
        var sm = Self.machine(secure: false, tls: .require)
        _ = sm.receive(Self.handshakePacket())
        _ = sm.tlsEstablished()

        guard case .sendAuthData(let response) = sm.receive(Self.sha256Switch()) else {
            Issue.record("expected an auth-switch response"); return
        }
        #expect(response == Array("secret".utf8) + [0])

        guard case .authenticated = sm.receive(Self.okPacket) else {
            Issue.record("expected authenticated"); return
        }
    }

    /// On a plaintext socket the response is a lone `0x01` asking for the
    /// server's public key. Unlike caching_sha2 there is no fast path to try
    /// first, so this happens on *every* connection.
    @Test func sha256OverPlaintextRequestsThePublicKey() {
        var sm = Self.machine(secure: false, serverPublicKey: .requestFromServer)
        _ = sm.receive(Self.handshakePacket())

        guard case .sendAuthData(let response) = sm.receive(Self.sha256Switch()) else {
            Issue.record("expected an auth-switch response"); return
        }
        #expect(response == [0x01])

        // The AuthMoreData *is* the key — there is no marker byte to skip, which
        // is exactly where this diverges from caching_sha2.
        let pem = Array("-----BEGIN PUBLIC KEY-----".utf8)
        guard case .encryptAndSend(let plaintext, let key) =
                sm.receive(Self.packet([0x01] + pem)) else {
            Issue.record("expected encryptAndSend"); return
        }
        #expect(key == pem)

        // Same XOR-with-nonce step as caching_sha2, over the *switch* scramble.
        var expected = Array("secret".utf8) + [0]
        for i in expected.indices {
            expected[i] ^= Self.sha256Scramble[i % Self.sha256Scramble.count]
        }
        #expect(plaintext == expected)

        guard case .authenticated = sm.receive(Self.okPacket) else {
            Issue.record("expected authenticated"); return
        }
    }

    /// A lone NUL is the documented "no password" marker — not an empty packet,
    /// and not an encrypted empty string.
    @Test func sha256WithAnEmptyPasswordSendsANul() {
        var sm = Self.machine(password: "", secure: false)
        _ = sm.receive(Self.handshakePacket())

        guard case .sendAuthData(let response) = sm.receive(Self.sha256Switch()) else {
            Issue.record("expected an auth-switch response"); return
        }
        #expect(response == [0x00])
    }

    /// Deliberate, and matching the reference (`rust-mysql-async`
    /// `conn/mod.rs`): only `caching_sha2_password` and `mysql_native_password`
    /// are honoured from the greeting. `sha256_password` is deprecated as a
    /// server default and every other plugin arrives by auth switch, so an
    /// unrecognised name falls back to native rather than failing the connect.
    @Test func greetingNamingSha256FallsBackToNativePassword() {
        var sm = Self.machine(secure: true)

        guard case .sendHandshakeResponse(let response, let pluginName, _) =
                sm.receive(Self.handshakePacket(plugin: "sha256_password")) else {
            Issue.record("expected handshake response"); return
        }
        #expect(pluginName == "mysql_native_password")
        #expect(response == MySQLAuth.nativePassword(password: "secret", scramble: Self.scramble))
    }

    // MARK: - parsec

    /// parsec is the only plugin needing two round trips. The switch carries the
    /// scramble but not the salt, so the first response must be **empty** — and
    /// the scramble has to be retained for the signature that comes later.
    @Test func parsecAnswersTheSwitchWithAnEmptyPacketThenSigns() throws {
        var sm = Self.machine(password: ParsecTests.fixturePassword)
        _ = sm.receive(Self.handshakePacket())

        // As with ed25519, parsec's scramble is a bare 32 bytes.
        let serverScramble = [UInt8](repeating: 0x33, count: 32)
        var payload: [UInt8] = [0xFE]
        payload += Array("parsec".utf8) + [0]
        payload += serverScramble

        guard case .sendAuthData(let first) = sm.receive(Self.packet(payload)) else {
            Issue.record("expected an empty first response"); return
        }
        #expect(first.isEmpty, "parsec's first response must carry no data")

        // Second round trip: AuthMoreData carries 'P', the factor, and the salt.
        let salt = try #require(ParsecTests.decodeBase64(ParsecTests.fixtureSaltBase64))
        let authString: [UInt8] = [0x01, UInt8(ascii: "P"), ParsecTests.fixtureFactor] + salt

        guard case .sendAuthData(let second) = sm.receive(Self.packet(authString)) else {
            Issue.record("expected a signed response"); return
        }
        #expect(second.count == MySQLParsec.responseLength)

        // Verify against the key MariaDB stores, over the scramble from the
        // *switch* — proving the state machine carried it across both trips.
        let clientNonce = Array(second.prefix(32))
        let signature = Array(second.suffix(64))
        let stored = try #require(ParsecTests.decodeBase64(ParsecTests.fixturePublicKeyBase64))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: stored)
        #expect(publicKey.isValidSignature(
            Data(signature), for: Data(serverScramble + clientNonce)
        ))

        guard case .authenticated = sm.receive(Self.okPacket) else {
            Issue.record("expected authenticated"); return
        }
    }

    /// A malformed auth string must fail cleanly rather than reaching the KDF.
    @Test func parsecRejectsAMalformedAuthString() {
        var sm = Self.machine()
        _ = sm.receive(Self.handshakePacket())

        var payload: [UInt8] = [0xFE]
        payload += Array("parsec".utf8) + [0]
        payload += [UInt8](repeating: 0x44, count: 32)
        _ = sm.receive(Self.packet(payload))

        // 'Q' is not a known algorithm marker.
        guard case .fail = sm.receive(Self.packet([0x01, UInt8(ascii: "Q"), 0]
                                                  + [UInt8](repeating: 0, count: 18))) else {
            Issue.record("expected a failure on a bad algorithm marker"); return
        }
    }

    // MARK: - mysql_clear_password gating

    @Test func cleartextPluginRefusedByDefault() {
        var sm = Self.machine(secure: true, allowCleartext: false)
        _ = sm.receive(Self.handshakePacket())

        guard case .fail(let error) = sm.receive(Self.clearPasswordSwitch()),
              case .insecureAuthRefused(let message) = error else {
            Issue.record("expected insecureAuthRefused"); return
        }
        #expect(message.contains("disabled"))
    }

    /// Enabling it is not enough — cleartext over a plaintext socket would put
    /// the password on the wire in the open.
    @Test func cleartextPluginRefusedOnInsecureTransport() {
        var sm = Self.machine(secure: false, allowCleartext: true)
        _ = sm.receive(Self.handshakePacket())

        guard case .fail(let error) = sm.receive(Self.clearPasswordSwitch()),
              case .insecureAuthRefused(let message) = error else {
            Issue.record("expected insecureAuthRefused"); return
        }
        #expect(message.contains("TLS"))
    }

    @Test func cleartextPluginAllowedWhenEnabledAndSecure() {
        var sm = Self.machine(secure: true, allowCleartext: true)
        _ = sm.receive(Self.handshakePacket())

        guard case .sendAuthData(let bytes) = sm.receive(Self.clearPasswordSwitch()) else {
            Issue.record("expected auth data"); return
        }
        #expect(bytes == Array("secret".utf8) + [0])
    }

    static func clearPasswordSwitch() -> MySQLPacket {
        var payload: [UInt8] = [0xFE]
        payload += Array("mysql_clear_password".utf8) + [0]
        payload += [UInt8](repeating: 0x22, count: 20) + [0]
        return packet(payload)
    }

    // MARK: - Errors

    @Test func serverErrorDuringAuthIsSurfaced() {
        var sm = Self.machine()
        _ = sm.receive(Self.handshakePacket())

        var payload: [UInt8] = [0xFF]
        payload += [0x15, 0x04]                         // 1045 = access denied
        payload += [UInt8(ascii: "#")] + Array("28000".utf8)
        payload += Array("Access denied for user 'root'".utf8)

        guard case .fail(let error) = sm.receive(Self.packet(payload)),
              case .server(let code, let sqlState, let message) = error else {
            Issue.record("expected server error"); return
        }
        #expect(code == 1045)
        #expect(sqlState == "28000")
        #expect(message.contains("Access denied"))
    }

    @Test func packetAfterCompletionIsRejected() {
        var sm = Self.machine()
        _ = sm.receive(Self.handshakePacket())
        _ = sm.receive(Self.okPacket)

        guard case .fail = sm.receive(Self.okPacket) else {
            Issue.record("expected failure after completion"); return
        }
    }

    @Test func emptyPasswordStillAuthenticates() {
        var sm = Self.machine(password: "")
        guard case .sendHandshakeResponse(let response, _, _) =
                sm.receive(Self.handshakePacket()) else {
            Issue.record("expected handshake response"); return
        }
        #expect(response.isEmpty)
    }
}

@Suite("Capability negotiation")
struct NegotiationTests {

    /// Intersection, never union — asking for something the server lacks makes
    /// it misparse our handshake response.
    @Test func capabilitiesAreIntersected() {
        var buffer = HandshakeTests.makeHandshake(
            serverVersion: "8.4.0",
            pluginName: "caching_sha2_password",
            scramble: Array(1...20),
            capabilitiesLow: 0x0200,     // PROTOCOL_41 only
            capabilitiesHigh: 0x0000
        )
        let handshake = try! MySQLHandshakeV10.parse(&buffer)
        let result = MySQLCapabilityNegotiation.negotiate(handshake: handshake)

        #expect(result.capabilities.contains(.protocol41))
        // We ask for these; the server does not offer them.
        #expect(result.capabilities.contains(.deprecateEOF) == false)
        #expect(result.capabilities.contains(.pluginAuth) == false)
    }

    /// MariaDB signals that its extended block is meaningful by *not* setting
    /// CLIENT_LONG_PASSWORD. Reading the bits whenever they are non-zero would
    /// misread a MySQL server that left junk in its reserved bytes.
    @Test func mariaDBExtendedCapabilitiesHonouredOnlyWhenLongPasswordAbsent() {
        func negotiate(capabilitiesLow: UInt16, version: String) -> MySQLNegotiatedCapabilities {
            var buffer = HandshakeTests.makeHandshake(
                serverVersion: version,
                pluginName: "mysql_native_password",
                scramble: Array(1...20),
                capabilitiesLow: capabilitiesLow,
                mariaDBExtended: 0x0000_0004     // STMT_BULK_OPERATIONS
            )
            let handshake = try! MySQLHandshakeV10.parse(&buffer)
            // Explicit desired set: this pins the *negotiation rule*, not the
            // shipping default (which is deliberately empty until each MariaDB
            // extension has an implementation behind it).
            return MySQLCapabilityNegotiation.negotiate(
                handshake: handshake,
                desiredMariaDB: .mariaDBStmtBulkOperations
            )
        }

        // MariaDB, LONG_PASSWORD absent -> honoured.
        let honoured = negotiate(capabilitiesLow: 0xFFFE, version: "5.5.5-11.4.2-MariaDB")
        #expect(honoured.isMariaDB)
        #expect(honoured.mariaDBCapabilities.contains(.mariaDBStmtBulkOperations))

        // MariaDB, LONG_PASSWORD present -> ignored.
        let ignored = negotiate(capabilitiesLow: 0xFFFF, version: "5.5.5-11.4.2-MariaDB")
        #expect(ignored.mariaDBCapabilities.isEmpty)

        // MySQL with junk in the reserved bytes -> ignored regardless.
        let mysql = negotiate(capabilitiesLow: 0xFFFE, version: "8.4.0")
        #expect(mysql.isMariaDB == false)
        #expect(mysql.mariaDBCapabilities.isEmpty)
    }

    /// Extended capabilities are parsed unconditionally; only *honouring* them
    /// is conditional.
    @Test func extendedCapabilitiesAreAlwaysParsed() {
        var buffer = HandshakeTests.makeHandshake(
            serverVersion: "8.4.0",
            pluginName: "caching_sha2_password",
            scramble: Array(1...20),
            mariaDBExtended: 0x0000_0004
        )
        let handshake = try! MySQLHandshakeV10.parse(&buffer)
        #expect(handshake.mariaDBExtendedCapabilities.contains(.mariaDBStmtBulkOperations))
        #expect(handshake.capabilities.contains(.mariaDBStmtBulkOperations) == false)
    }
}

/// Regression tests for auth-switch scramble framing.
///
/// A 32-byte scramble ending in `0x00` was being truncated to 31 bytes, so the
/// signature covered the wrong message and the server answered "Access denied".
/// One connection in 256 — frequent enough to be a real production problem,
/// rare enough to look like flakiness.
@Suite("Auth switch scramble framing")
struct AuthSwitchFramingTests {

    static func packet(plugin: String, data: [UInt8]) throws -> MySQLAuthSwitchRequest {
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt8(0xFE))
        buffer.writeString(plugin)
        buffer.writeInteger(UInt8(0))
        buffer.writeBytes(data)
        return try MySQLAuthSwitchRequest.parse(&buffer)
    }

    /// The classic plugins do send `scramble || 0x00`, so that NUL must still be
    /// removed — the fix must not overcorrect.
    @Test(arguments: ["mysql_native_password", "caching_sha2_password"])
    func classicPluginsKeepTheirTrailingNulStripped(plugin: String) throws {
        let scramble = [UInt8](repeating: 0x41, count: 20)
        let parsed = try Self.packet(plugin: plugin, data: scramble + [0x00])
        #expect(parsed.pluginData == scramble)
    }

    /// The bug: a fixed-width scramble must survive intact whatever its last
    /// byte happens to be.
    @Test(arguments: ["client_ed25519", "parsec"])
    func fixedWidthScramblesAreNeverTruncated(plugin: String) throws {
        let ordinary = [UInt8](repeating: 0x41, count: 32)
        #expect(try Self.packet(plugin: plugin, data: ordinary).pluginData.count == 32)

        // The one-in-256 case.
        let endsInZero = [UInt8](repeating: 0x41, count: 31) + [0x00]
        let parsed = try Self.packet(plugin: plugin, data: endsInZero)
        #expect(parsed.pluginData.count == 32, "a zero-tailed scramble was truncated")
        #expect(parsed.pluginData == endsInZero)
    }

    /// Every byte value in the final position, so the boundary cannot regress
    /// for some other value later.
    @Test func everyTrailingByteValueSurvives() throws {
        for tail in 0...255 {
            let scramble = [UInt8](repeating: 0x41, count: 31) + [UInt8(tail)]
            let parsed = try Self.packet(plugin: "client_ed25519", data: scramble)
            #expect(parsed.pluginData.count == 32, "truncated on trailing byte \(tail)")
        }
    }
}

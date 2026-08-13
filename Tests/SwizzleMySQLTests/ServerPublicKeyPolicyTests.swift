import Foundation
import NIOCore
import SwizzleMySQL
import Testing

/// The RSA public-key policy — MySQL's answer to the problem Postgres solves
/// with SCRAM channel binding.
///
/// ## The attack, stated plainly
///
/// `caching_sha2_password` on a cold cache, and `sha256_password` always, need
/// the *cleartext* password at the server. Over TLS or a unix socket it travels
/// inside the secure channel and none of this applies. Over a plaintext socket
/// the password is RSA-encrypted instead — under a public key **the server hands
/// over during the handshake**. A key that arrives over an unauthenticated
/// channel authenticates nothing: an attacker in the path answers with their own
/// key, decrypts the password, re-encrypts it under the server's real key and
/// forwards it. Client and server both see a normal successful login, and the
/// attacker has the password in cleartext.
///
/// MySQL has no channel binding in any authentication plugin, so the fix is the
/// one `libmysqlclient` and Connector/J use: know the key in advance
/// (`--server-public-key-path`), or decline
/// (`allowPublicKeyRetrieval=false`, the Connector/J default).
///
/// These tests drive the state machine directly, which is the only way to reach
/// every branch — a real server will not present a mismatched key on request.
@Suite("MySQL server public key policy")
struct ServerPublicKeyPolicyTests {

    /// Two genuine 2048-bit RSA public keys. Real ones rather than fixture text
    /// because the pin is compared by parsed DER, so "unparseable junk" would
    /// exercise the error path instead of the comparison.
    static let keyA = """
        -----BEGIN PUBLIC KEY-----
        MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAuezS5kUnQbJJhLHdPqJs
        K7eNohvPR3i+8sWx9G6TqVyywFeUgOjoo5+cYbRsYTBobd9V2KqGb12nbdoEIXPA
        S+zylTYwEm3kviUFVZj30uaabXiSmg8rgx8fjpnjP944QAxg5JNHTUaTLquI7vCw
        Dlew/Z0pAlN/7urSZinx6oftaSdyUiT8/BJX+KUDkV+Xenjf/wAfTN6jOob4rzIo
        /2kd80IZ6fOWPPGt/0WFipMNrx6EFzwTr3kTOP47JEeAdf5GPeTa8xDxkfS5FmH6
        8pZY6MsXJQQr0f79PXMoGqc7feploMsMqJAsaTvcpZhkiqMYPihMD4x15hDcKLx1
        tQIDAQAB
        -----END PUBLIC KEY-----
        """

    static let keyB = """
        -----BEGIN PUBLIC KEY-----
        MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAvU2NWnVQZuNP9Kc7cFtm
        w5L9MdJ6iQncjftmthDF6DeSyR6TY5HTTCEx1UfhcoUDj5kByqlRDR9nq7xFgKib
        RTB+QS0viMAbXroWdJF1+y6G6UyV8CvKwGpeMxDuIMX7e0Ev6xnGPrClthKSMBVu
        sGHR1oLD5y42cEC0D/7SCziNK250IabC+Q/+yo2fcmpJ6gOJGLWPuJp+zFTKuQad
        h2VXbvjpch3LRyFduGx63QpfXa0af+ueK6zmicQHWZFAV+5XYnf1UDAzEpedcNZ0
        M5GzWyw7dYNwLUkp/LUToUTuVPHUZadfvit+6lOxL9gocSQ3r8CLJUOnf8Anmg9Y
        wQIDAQAB
        -----END PUBLIC KEY-----
        """

    static let scramble: [UInt8] = Array("0123456789abcdefghij".utf8)

    static func machine(
        secure: Bool = false,
        policy: MySQLConnectionConfiguration.ServerPublicKey
    ) -> MySQLAuthStateMachine {
        MySQLAuthStateMachine(
            configuration: .init(
                username: "root",
                password: "secret",
                isSecureTransport: secure,
                serverPublicKey: policy
            )
        )
    }

    static func packet(_ bytes: [UInt8]) -> MySQLPacket {
        MySQLPacket(sequenceID: 0, payload: ByteBuffer(bytes: bytes))
    }

    /// A greeting naming the plugin, with a fixed scramble so the XOR is
    /// predictable.
    static func handshake(plugin: String) -> MySQLPacket {
        var payload: [UInt8] = [10]
        payload += Array("8.4.0".utf8) + [0]
        payload += [1, 0, 0, 0]
        payload += Array(scramble[0..<8])
        payload += [0]
        payload += [0xFF, 0xF7]
        payload += [0x2D]
        payload += [0x02, 0x00]
        payload += [0xFF, 0x81]
        payload += [21]
        payload += Array(repeating: 0, count: 10)
        payload += Array(scramble[8...]) + [0]
        payload += Array(plugin.utf8) + [0]
        return packet(payload)
    }

    /// `perform_full_authentication` — the server telling us the cache is cold.
    static let performFullAuthentication = packet([0x01, 0x04])

    static func authMoreData(_ pem: String) -> MySQLPacket {
        packet([0x01] + Array(pem.utf8))
    }

    static func sha256Switch() -> MySQLPacket {
        packet([0xFE] + Array("sha256_password".utf8) + [0] + scramble + [0])
    }

    static func failureMessage(_ action: MySQLAuthStateMachine.Action) -> String? {
        guard case .fail(let error) = action,
            case .insecureAuthRefused(let message) = error
        else { return nil }
        return message
    }

    // MARK: - refuse, the default

    /// The default has to be the safe one, so it is asserted as a default rather
    /// than as a value someone passed in.
    @Test("the default is to refuse")
    func defaultIsRefuse() {
        let configuration = MySQLConnectionConfiguration(
            address: .hostname("127.0.0.1", port: 3306), username: "root"
        )
        #expect(configuration.serverPublicKey == .refuse)
    }

    @Test("caching_sha2 full auth over plaintext is refused by default")
    func cachingSHA2Refused() {
        var machine = Self.machine(policy: .refuse)
        _ = machine.receive(Self.handshake(plugin: "caching_sha2_password"))

        let action = machine.receive(Self.performFullAuthentication)
        guard let message = Self.failureMessage(action) else {
            Issue.record("expected insecureAuthRefused, got \(action)"); return
        }
        // The message has to be actionable: all three ways out, by name.
        #expect(message.contains("TLS"))
        #expect(message.contains("pinned"))
        #expect(message.contains("requestFromServer"))
    }

    /// `sha256_password` refuses one step earlier — at the response, not at the
    /// reply — because its request for the key *is* the response. Asking a
    /// question whose answer we have already decided to reject would only leak
    /// that we tried.
    @Test("sha256_password over plaintext is refused before asking")
    func sha256RefusedBeforeAsking() {
        var machine = Self.machine(policy: .refuse)
        _ = machine.receive(Self.handshake(plugin: "mysql_native_password"))

        let action = machine.receive(Self.sha256Switch())
        guard let message = Self.failureMessage(action) else {
            Issue.record("expected insecureAuthRefused, got \(action)"); return
        }
        #expect(message.contains("pinned"))
    }

    /// **The refusal must be about the plaintext socket, not about the plugin.**
    /// Over TLS the same configuration authenticates, because the RSA exchange
    /// never happens — a policy that also blocked the secure path would be a
    /// policy nobody could leave switched on.
    @Test("refuse does not affect TLS or unix-socket connections")
    func refuseDoesNotAffectSecureTransports() {
        var machine = Self.machine(secure: true, policy: .refuse)
        _ = machine.receive(Self.handshake(plugin: "caching_sha2_password"))

        guard case .sendCleartextPassword(let bytes) =
            machine.receive(Self.performFullAuthentication)
        else {
            Issue.record("expected the cleartext branch over a secure transport"); return
        }
        #expect(bytes == Array("secret".utf8) + [0])
    }

    // MARK: - The pre-4.1 algorithm

    /// A **bare `0xFE`** is the old auth-switch request: pre-4.1 servers had no
    /// plugin names, so an empty switch means `mysql_old_password` and nothing
    /// else. rust-mysql-common gives it its own packet type; we had been parsing
    /// it as an ordinary switch and reporting "missing plugin name", which reads
    /// like a corrupt packet rather than an account on an algorithm MySQL removed
    /// in 8.0.
    @Test("a bare auth-switch is named as the pre-4.1 algorithm")
    func bareAuthSwitchIsOldPassword() {
        var machine = Self.machine(policy: .refuse)
        _ = machine.receive(Self.handshake(plugin: "mysql_native_password"))

        let action = machine.receive(Self.packet([0xFE]))
        guard case .fail(let error) = action,
            case .unsupportedAuthPlugin(let message) = error
        else {
            Issue.record("expected unsupportedAuthPlugin, got \(action)"); return
        }
        #expect(message.contains("mysql_old_password"))
        // Actionable: the fix is a server-side ALTER USER, and saying so saves
        // the reader working out that it is not a client setting.
        #expect(message.contains("ALTER USER"))
    }

    /// And the same refusal when the server *names* the plugin rather than
    /// sending the legacy empty form. One message either way.
    @Test("a named mysql_old_password switch is refused identically")
    func namedOldPasswordIsRefused() {
        var machine = Self.machine(policy: .refuse)
        _ = machine.receive(Self.handshake(plugin: "mysql_native_password"))

        let switchPacket = Self.packet(
            [0xFE] + Array("mysql_old_password".utf8) + [0] + Self.scramble + [0]
        )
        guard case .fail(let error) = machine.receive(switchPacket),
            case .unsupportedAuthPlugin(let message) = error
        else {
            Issue.record("expected unsupportedAuthPlugin"); return
        }
        #expect(message.contains("ALTER USER"))
    }

    // MARK: - The unix socket, where the two plugins part company

    /// A unix socket is a secure transport for `caching_sha2_password` — the
    /// password goes across in the clear and no key is exchanged.
    @Test("caching_sha2 sends cleartext over a unix socket")
    func cachingSHA2OverUnixSocket() {
        var machine = Self.machine(secure: true, policy: .refuse)
        _ = machine.receive(Self.handshake(plugin: "caching_sha2_password"))

        guard case .sendCleartextPassword = machine.receive(Self.performFullAuthentication) else {
            Issue.record("expected cleartext over a unix socket"); return
        }
    }

    /// **`sha256_password` does not**, and the server is the authority: over a
    /// socket the `mysql` client is denied with the wrong `--server-public-key-path`
    /// and admitted with the right one, which a client sending cleartext could
    /// not be. So the RSA exchange runs even here.
    ///
    /// And the policy stands aside: the default is `.refuse`, yet the exchange
    /// proceeds, because a unix socket has no man in the middle to refuse on
    /// account of — and refusing the encrypted exchange while sending cleartext
    /// over the same socket for the other plugin would be incoherent.
    @Test("sha256_password takes the RSA path over a unix socket, unrefused")
    func sha256OverUnixSocket() {
        var machine = Self.machine(secure: true, policy: .refuse)
        _ = machine.receive(Self.handshake(plugin: "mysql_native_password"))

        guard case .sendAuthData(let response) = machine.receive(Self.sha256Switch()) else {
            Issue.record("expected the public-key request"); return
        }
        #expect(response == [0x01], "a unix socket must not get the cleartext branch")

        guard case .encryptAndSend = machine.receive(Self.authMoreData(Self.keyA)) else {
            Issue.record("expected encryptAndSend"); return
        }
    }

    /// A pin is still honoured over a socket. The policy standing aside means
    /// "do not refuse", not "do not check" — someone who went to the trouble of
    /// pinning a key gets the mismatch reported wherever it happens.
    @Test("a pinned key is still verified over a unix socket")
    func pinnedStillVerifiedOverUnixSocket() {
        var machine = Self.machine(secure: true, policy: .pinned(pem: Self.keyA))
        _ = machine.receive(Self.handshake(plugin: "mysql_native_password"))
        _ = machine.receive(Self.sha256Switch())

        let action = machine.receive(Self.authMoreData(Self.keyB))
        guard let message = Self.failureMessage(action) else {
            Issue.record("expected insecureAuthRefused, got \(action)"); return
        }
        #expect(message.contains("not the pinned one"))
    }

    // MARK: - requestFromServer

    @Test("requestFromServer accepts the key the server sends")
    func requestFromServerAccepts() {
        var machine = Self.machine(policy: .requestFromServer)
        _ = machine.receive(Self.handshake(plugin: "caching_sha2_password"))

        guard case .requestPublicKey = machine.receive(Self.performFullAuthentication) else {
            Issue.record("expected a public key request"); return
        }
        guard case .encryptAndSend(_, let key) = machine.receive(Self.authMoreData(Self.keyA)) else {
            Issue.record("expected encryptAndSend"); return
        }
        #expect(key == Array(Self.keyA.utf8))
    }

    // MARK: - pinned

    /// The pinned key matches, so the exchange proceeds exactly as it would
    /// without a pin — which is the part worth pinning down, since a pin that
    /// broke the happy path would be found immediately and one that silently did
    /// nothing would not be found at all.
    @Test("a matching pinned key lets the exchange proceed")
    func pinnedMatching() {
        var machine = Self.machine(policy: .pinned(pem: Self.keyA))
        _ = machine.receive(Self.handshake(plugin: "caching_sha2_password"))

        guard case .requestPublicKey = machine.receive(Self.performFullAuthentication) else {
            Issue.record("expected a public key request"); return
        }
        guard case .encryptAndSend(let plaintext, let key) =
            machine.receive(Self.authMoreData(Self.keyA))
        else {
            Issue.record("expected encryptAndSend"); return
        }
        #expect(key == Array(Self.keyA.utf8))

        // And the XOR is still applied — the pin must not have displaced it.
        var expected = Array("secret".utf8) + [0]
        for i in expected.indices { expected[i] ^= Self.scramble[i % Self.scramble.count] }
        #expect(plaintext == expected)
    }

    /// **This is the attack, and the only test that proves the pin does
    /// anything.** A different key arrives; nothing is encrypted, and the error
    /// says what it means rather than "authentication failed".
    @Test("a mismatched key is refused, and named as a substitution")
    func pinnedMismatchIsRefused() {
        var machine = Self.machine(policy: .pinned(pem: Self.keyA))
        _ = machine.receive(Self.handshake(plugin: "caching_sha2_password"))
        _ = machine.receive(Self.performFullAuthentication)

        let action = machine.receive(Self.authMoreData(Self.keyB))
        guard let message = Self.failureMessage(action) else {
            Issue.record("expected insecureAuthRefused, got \(action)"); return
        }
        #expect(message.contains("not the pinned one"))
        // Rotation is the innocent explanation and substitution is the other
        // one; a reader at 3am needs both.
        #expect(message.contains("rotated"))
    }

    /// The same key, differently formatted, is the same key. PEM line width, CRLF
    /// endings and a missing trailing newline all survive a round trip through a
    /// config file or an environment variable, and a pin that rejected them would
    /// be abandoned within a day.
    @Test("the pin compares keys, not their formatting")
    func pinnedIgnoresFormatting() {
        let reformatted =
            Self.keyA
            .replacingOccurrences(of: "\n", with: "\r\n") + "\r\n"

        var machine = Self.machine(policy: .pinned(pem: reformatted))
        _ = machine.receive(Self.handshake(plugin: "caching_sha2_password"))
        _ = machine.receive(Self.performFullAuthentication)

        guard case .encryptAndSend = machine.receive(Self.authMoreData(Self.keyA)) else {
            Issue.record("a reformatted pin should still match"); return
        }
    }

    /// A pin that cannot be parsed must fail, not quietly compare unequal and
    /// certainly not quietly pass.
    @Test("an unparseable pin fails rather than being ignored")
    func unparseablePin() {
        var machine = Self.machine(policy: .pinned(pem: "-----BEGIN PUBLIC KEY-----\nnope\n"))
        _ = machine.receive(Self.handshake(plugin: "caching_sha2_password"))
        _ = machine.receive(Self.performFullAuthentication)

        guard case .fail = machine.receive(Self.authMoreData(Self.keyA)) else {
            Issue.record("expected a failure for an unparseable pin"); return
        }
    }

    /// And the mirror image: a *server* key that cannot be parsed. Reached by a
    /// server that answers with something other than a key — which is what a
    /// crude man in the middle looks like.
    @Test("an unparseable server key fails")
    func unparseableServerKey() {
        var machine = Self.machine(policy: .pinned(pem: Self.keyA))
        _ = machine.receive(Self.handshake(plugin: "caching_sha2_password"))
        _ = machine.receive(Self.performFullAuthentication)

        guard case .fail = machine.receive(Self.authMoreData("not a key at all")) else {
            Issue.record("expected a failure for an unparseable server key"); return
        }
    }

    // MARK: - Configuration surface

    @Test("pinned(contentsOfFile:) reads a key from disk")
    func pinnedFromFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swizzle-pin-\(UInt32.random(in: 0..<UInt32.max)).pem")
        try Self.keyA.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let policy = try MySQLConnectionConfiguration.ServerPublicKey.pinned(
            contentsOfFile: url.path
        )
        #expect(policy == .pinned(pem: Self.keyA))
    }

    @Test("a missing pin file throws rather than falling back")
    func missingPinFile() {
        #expect(throws: (any Error).self) {
            _ = try MySQLConnectionConfiguration.ServerPublicKey.pinned(
                contentsOfFile: "/nonexistent/public_key.pem"
            )
        }
    }

    // MARK: - URL parameters

    @Test("allow_public_key_retrieval opts in from a URL")
    func urlRetrieval() throws {
        let configuration = try MySQLConnectionConfiguration(
            url: "mysql://root:pw@127.0.0.1:3306/db?allow_public_key_retrieval=true"
        )
        #expect(configuration.serverPublicKey == .requestFromServer)

        // The Connector/J spelling reaches the same place — someone porting a
        // JDBC URL should not have to learn a third name.
        let camel = try MySQLConnectionConfiguration(
            url: "mysql://root:pw@127.0.0.1:3306/db?allowPublicKeyRetrieval=true"
        )
        #expect(camel.serverPublicKey == .requestFromServer)
    }

    @Test("a URL without the parameter still refuses")
    func urlDefaultRefuses() throws {
        let configuration = try MySQLConnectionConfiguration(
            url: "mysql://root:pw@127.0.0.1:3306/db"
        )
        #expect(configuration.serverPublicKey == .refuse)

        // And `false` is `false`, not "mentioned, therefore enabled".
        let explicit = try MySQLConnectionConfiguration(
            url: "mysql://root:pw@127.0.0.1:3306/db?allow_public_key_retrieval=false"
        )
        #expect(explicit.serverPublicKey == .refuse)
    }

    @Test("server_public_key_path pins from a URL")
    func urlPinPath() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swizzle-pin-\(UInt32.random(in: 0..<UInt32.max)).pem")
        try Self.keyA.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let configuration = try MySQLConnectionConfiguration(
            url: "mysql://root:pw@127.0.0.1:3306/db?server_public_key_path=\(url.path)"
        )
        #expect(configuration.serverPublicKey == .pinned(pem: Self.keyA))
    }

    /// A path that does not resolve must fail the URL, not silently leave the
    /// connection unpinned — the failure mode this whole option exists to
    /// prevent.
    @Test("an unreadable pin path fails the URL")
    func urlPinPathMissing() {
        #expect(throws: MySQLURLError.self) {
            _ = try MySQLConnectionConfiguration(
                url: "mysql://root:pw@127.0.0.1:3306/db?server_public_key_path=/nope/key.pem"
            )
        }
    }
}

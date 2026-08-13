import NIOCore

/// Drives connection authentication.
///
/// Deliberately **pure**: it consumes packets and returns actions, performing no
/// I/O and no asymmetric crypto. That is what makes the whole auth flow —
/// including the paths that are awkward to reach against a real server, like
/// `perform_full_authentication` over a plaintext socket — testable without one.
///
/// Ported from `mysql_async`'s `handle_handshake` / `do_handshake_response` /
/// `perform_auth_switch` / `continue_*_auth`.
public struct MySQLAuthStateMachine: Sendable {

    public struct Configuration: Sendable {
        public var username: String
        public var password: String
        public var database: String?
        /// True when the transport is *inherently* secure — a unix socket.
        /// TLS is tracked separately because it is only established mid-flow;
        /// `effectiveSecureTransport` combines the two.
        public var isSecureTransport: Bool
        /// Defaults to `.disable` so the state machine can be tested without a
        /// TLS story; the connection layer passes the real mode.
        public var tls: MySQLConnectionConfiguration.TLSMode
        /// `mysql_clear_password` sends the password with no obfuscation, so it
        /// is refused unless explicitly enabled *and* the transport is secure.
        public var allowCleartextPlugin: Bool
        /// Governs the RSA exchange on the plaintext path — see
        /// ``MySQLConnectionConfiguration/serverPublicKey``. Defaults to
        /// ``MySQLConnectionConfiguration/ServerPublicKey/refuse``, matching the
        /// connection configuration, so a test that does not mention it gets the
        /// production posture rather than an easier one.
        public var serverPublicKey: MySQLConnectionConfiguration.ServerPublicKey
        public var desiredCapabilities: MySQLCapabilities

        public init(
            username: String,
            password: String = "",
            database: String? = nil,
            isSecureTransport: Bool = false,
            tls: MySQLConnectionConfiguration.TLSMode = .disable,
            allowCleartextPlugin: Bool = false,
            serverPublicKey: MySQLConnectionConfiguration.ServerPublicKey = .refuse,
            desiredCapabilities: MySQLCapabilities = .swizzleDefault
        ) {
            self.username = username
            self.password = password
            self.database = database
            self.isSecureTransport = isSecureTransport
            self.tls = tls
            self.allowCleartextPlugin = allowCleartextPlugin
            self.serverPublicKey = serverPublicKey
            self.desiredCapabilities = desiredCapabilities
        }
    }

    public enum Action: Sendable, Equatable {
        /// Send nothing; keep reading.
        ///
        /// Distinct from sending an empty packet. `fast_auth_success` in
        /// particular is answered by *silence* — writing a zero-length packet
        /// there consumes a sequence number the server never expected, and the
        /// desync only surfaces on the next command as
        /// "Got packets out of order".
        case wait
        /// Send an `SSLRequest` and upgrade the pipeline to TLS, then call
        /// `tlsEstablished()` to obtain the handshake response.
        ///
        /// This exists because the upgrade happens *between* the greeting and
        /// the handshake response: everything identifying (username, auth
        /// payload) must travel inside the TLS session, which is the entire
        /// point of the `SSLRequest` packet.
        case startTLS(negotiated: MySQLNegotiatedCapabilities)
        /// Send the handshake response with this auth payload.
        case sendHandshakeResponse(
            authResponse: [UInt8],
            pluginName: String,
            negotiated: MySQLNegotiatedCapabilities
        )
        /// Send a bare auth payload — the reply to an AuthSwitchRequest.
        case sendAuthData([UInt8])
        /// Send `0x02`, asking the server for its RSA public key.
        case requestPublicKey
        /// Send these bytes verbatim: the NUL-terminated password, already
        /// XORed with the nonce, ready for RSA-OAEP under `publicKeyPEM`.
        case encryptAndSend(plaintext: [UInt8], publicKeyPEM: [UInt8])
        /// Send the NUL-terminated password in the clear — only ever produced
        /// when the transport is already secure.
        case sendCleartextPassword([UInt8])
        case authenticated(MySQLOKPacket)
        case fail(MySQLProtocolError)
    }

    enum State: Sendable, Equatable {
        case awaitingHandshake
        case awaitingTLSEstablished
        case awaitingAuthResult
        case awaitingPublicKey
        case awaitingFinalResult
        case authenticated
        case failed
    }

    private(set) var state: State = .awaitingHandshake
    private(set) var negotiated = MySQLNegotiatedCapabilities(
        capabilities: [], mariaDBCapabilities: [], isMariaDB: false
    )
    private(set) var plugin: MySQLAuthPlugin = .mysqlNativePassword
    private(set) var nonce: [UInt8] = []
    /// Auth switching is allowed **once**. A server that asks twice is either
    /// broken or attempting a downgrade, and `mysql_async` treats a second
    /// request as unreachable.
    private(set) var hasAuthSwitched = false
    private(set) var isTLSActive = false
    private(set) var connectionID: UInt32 = 0

    let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// TLS *or* a unix socket. For `caching_sha2_password` both let the password
    /// travel in cleartext during `perform_full_authentication`, skipping the RSA
    /// exchange entirely.
    ///
    /// Also what decides whether the RSA key exchange is exposed to a man in the
    /// middle, and therefore whether
    /// ``MySQLConnectionConfiguration/serverPublicKey`` has anything to say. On a
    /// unix socket it does not: there is no network path to interpose on, and
    /// refusing the *encrypted* exchange there while cheerfully sending the
    /// password in cleartext over the same socket would be incoherent.
    var effectiveSecureTransport: Bool {
        configuration.isSecureTransport || isTLSActive
    }

    /// **TLS only** — a unix socket does not count.
    ///
    /// `sha256_password` is the one plugin where the two differ, and the server
    /// is the authority: over a unix socket with `--ssl-mode=DISABLED`, the
    /// `mysql` client authenticates a `sha256_password` account only when given
    /// the *right* `--server-public-key-path` and is denied with the wrong one.
    /// It is taking the RSA path, so the server is not accepting cleartext there
    /// — unlike `caching_sha2_password`, which it does accept over a socket.
    ///
    /// Found because two references disagreed: `go-sql-driver` says "unlike
    /// caching_sha2_password, sha256_password does not accept cleartext password
    /// on unix transport" and `pymysql` treats the socket as secure for both.
    /// go-sql-driver is right. We had followed pymysql, and `sha256_password`
    /// over a unix socket had never worked.
    var isTLSEncrypted: Bool { isTLSActive }

    /// Whether ``MySQLConnectionConfiguration/serverPublicKey`` applies at all.
    ///
    /// Only on a transport somebody can sit in the middle of. `sha256_password`
    /// over a unix socket still runs the RSA exchange — see ``isTLSEncrypted`` —
    /// but there is nothing to protect it from, so the policy stands aside
    /// rather than refusing a connection the `mysql` client would make.
    var policyGovernsPublicKey: Bool { !effectiveSecureTransport }

    // MARK: - Driving

    /// Called by the connection layer once the TLS handshake has completed.
    public mutating func tlsEstablished() -> Action {
        guard state == .awaitingTLSEstablished else {
            return failure(.unexpectedPacket("TLS established while not awaiting it"))
        }
        isTLSActive = true
        return makeHandshakeResponse()
    }

    public mutating func receive(_ packet: MySQLPacket) -> Action {
        var buffer = packet.payload
        switch state {
        case .awaitingHandshake:
            return handleHandshake(&buffer)
        case .awaitingTLSEstablished:
            // The server sends nothing between SSLRequest and the TLS handshake.
            return failure(.unexpectedPacket("packet received while awaiting TLS handshake"))
        case .awaitingAuthResult:
            return handleAuthResult(packet, &buffer)
        case .awaitingPublicKey:
            return handlePublicKey(&buffer)
        case .awaitingFinalResult:
            return handleFinalResult(packet, &buffer)
        case .authenticated, .failed:
            return failure(.unexpectedPacket("packet received after authentication finished"))
        }
    }

    // MARK: - Steps

    private mutating func handleHandshake(_ buffer: inout ByteBuffer) -> Action {
        let handshake: MySQLHandshakeV10
        do {
            handshake = try MySQLHandshakeV10.parse(&buffer)
        } catch let error as MySQLProtocolError {
            return failure(error)
        } catch {
            return failure(.malformedHandshake("\(error)"))
        }

        negotiated = MySQLCapabilityNegotiation.negotiate(
            handshake: handshake, desired: configuration.desiredCapabilities
        )
        nonce = handshake.authPluginData
        connectionID = handshake.connectionID

        // Only these two may appear in an initial greeting. `sha256_password` is
        // deprecated and anything else arrives via AuthSwitchRequest instead, so
        // an unrecognised name falls back to native rather than failing.
        switch MySQLAuthPlugin(name: handshake.authPluginName ?? "") {
        case .cachingSHA2Password: plugin = .cachingSHA2Password
        default: plugin = .mysqlNativePassword
        }

        // TLS is negotiated before the handshake response, so that the username
        // and auth payload travel inside the session rather than in the clear.
        let serverSupportsTLS = handshake.capabilities.contains(.ssl)
        // The verifying modes differ from `require` only in what the TLS handler
        // checks once the session is up; the negotiation is identical, so they
        // share this branch.
        if configuration.tls.requiresTLS {
            guard serverSupportsTLS else {
                return failure(.tlsNotSupportedByServer)
            }
            negotiated.capabilities.insert(.ssl)
            state = .awaitingTLSEstablished
            return .startTLS(negotiated: negotiated)
        }
        if configuration.tls == .prefer, serverSupportsTLS {
            negotiated.capabilities.insert(.ssl)
            state = .awaitingTLSEstablished
            return .startTLS(negotiated: negotiated)
        }

        return makeHandshakeResponse()
    }

    private mutating func makeHandshakeResponse() -> Action {
        guard let response = authResponse(for: plugin) else {
            return failure(unsupported(plugin))
        }
        state = .awaitingAuthResult
        return .sendHandshakeResponse(
            authResponse: response, pluginName: plugin.name, negotiated: negotiated
        )
    }

    private mutating func handleAuthResult(
        _ packet: MySQLPacket, _ buffer: inout ByteBuffer
    ) -> Action {
        guard let first = packet.firstByte else {
            return failure(.unexpectedPacket("empty packet during authentication"))
        }

        switch first {
        case 0x00:
            return finish(&buffer)

        case 0xFF:
            return serverError(&buffer)

        case 0xFE:
            return handleAuthSwitch(&buffer)

        case 0x01:
            // For sha256_password the AuthMoreData *is* the public key — there
            // is no fast-path marker, so it rejoins the RSA exchange directly.
            if plugin == .sha256Password {
                return handlePublicKey(&buffer)
            }
            // For parsec it is the auth string: algorithm, iteration factor, salt.
            if plugin == .parsec {
                return handleParsecChallenge(&buffer)
            }
            guard plugin == .cachingSHA2Password else {
                return failure(.unexpectedPacket("AuthMoreData for plugin \(plugin.name)"))
            }
            guard let marker = buffer.getInteger(at: buffer.readerIndex + 1, as: UInt8.self) else {
                return failure(.malformedPacket("truncated AuthMoreData"))
            }
            switch marker {
            case 0x03:
                // fast_auth_success. The server sends an OK next and expects
                // nothing from us in between — see `drop_packet` in the
                // reference, which reads and never writes.
                state = .awaitingFinalResult
                return .wait
            case 0x04:
                return beginFullAuthentication()
            default:
                return failure(.unexpectedPacket("unknown AuthMoreData marker 0x\(String(marker, radix: 16))"))
            }

        default:
            return failure(.unexpectedPacket("unexpected auth packet 0x\(String(first, radix: 16))"))
        }
    }

    private mutating func handleAuthSwitch(_ buffer: inout ByteBuffer) -> Action {
        guard !hasAuthSwitched else {
            return failure(.repeatedAuthSwitch)
        }

        // A bare `0xFE` with nothing after it is the **old** auth-switch request:
        // pre-4.1 servers had no plugin names, so an empty switch means
        // `mysql_old_password` and nothing else. rust-mysql-common models it as
        // its own packet type for exactly this reason.
        //
        // Parsed as an ordinary switch it fails with "missing plugin name",
        // which reads like a corrupt packet and sends the reader looking in the
        // wrong place. The real situation is an account still on an algorithm
        // MySQL removed in 8.0, and the fix is on the server.
        guard buffer.readableBytes > 1 else {
            return failure(Self.oldPasswordRefused)
        }

        let request: MySQLAuthSwitchRequest
        do {
            request = try MySQLAuthSwitchRequest.parse(&buffer)
        } catch let error as MySQLProtocolError {
            return failure(error)
        } catch {
            return failure(.malformedPacket("\(error)"))
        }

        hasAuthSwitched = true
        nonce = request.pluginData
        plugin = MySQLAuthPlugin(name: request.pluginName)

        guard let response = authResponse(for: plugin) else {
            return failure(unsupported(plugin))
        }

        state = .awaitingAuthResult
        return .sendAuthData(response)
    }

    /// Second parsec round trip: derive from the salt, sign, reply.
    private mutating func handleParsecChallenge(_ buffer: inout ByteBuffer) -> Action {
        guard buffer.readInteger(endianness: .little, as: UInt8.self) == 0x01,
              let bytes = buffer.readBytes(length: buffer.readableBytes)
        else {
            return failure(.malformedPacket("parsec: malformed challenge"))
        }

        do {
            let authString = try MySQLParsec.AuthString.parse(bytes)
            let response = try MySQLParsec.response(
                password: configuration.password,
                serverScramble: nonce,
                authString: authString
            )
            state = .awaitingFinalResult
            return .sendAuthData(response)
        } catch let error as MySQLProtocolError {
            return failure(error)
        } catch {
            return failure(.malformedPacket("parsec: \(error)"))
        }
    }

    private mutating func beginFullAuthentication() -> Action {
        // Password plus its NUL terminator is what gets sent either way.
        var plaintext = Array(configuration.password.utf8)
        plaintext.append(0)

        if effectiveSecureTransport {
            state = .awaitingFinalResult
            return .sendCleartextPassword(plaintext)
        }
        guard configuration.serverPublicKey != .refuse else {
            return failure(Self.publicKeyRefused)
        }
        state = .awaitingPublicKey
        return .requestPublicKey
    }

    /// The refusal, worded so the reader can act on it.
    ///
    /// Three genuine fixes, in the order they should be preferred: encrypt the
    /// whole session, know the key in advance, or accept the risk knowingly.
    /// An error that only says "refused" leaves the reader to find all three.
    /// The pre-4.1 password algorithm, refused.
    ///
    /// `mysql_async` refuses it too, under `secure_auth` (on by default), and for
    /// the same reason: the hash is 8 bytes of a homebrew PRNG and is trivially
    /// reversible. Unlike theirs there is no opt-out, because MySQL removed the
    /// plugin in 8.0 and MariaDB in 10.6 — there is no supported server left to
    /// opt in *to*.
    static let oldPasswordRefused = MySQLProtocolError.unsupportedAuthPlugin(
        "mysql_old_password — the server asked for the pre-4.1 password algorithm, "
            + "which is insecure and unsupported (MySQL removed it in 8.0). Give the "
            + "account a modern plugin: "
            + "ALTER USER … IDENTIFIED WITH caching_sha2_password BY …"
    )

    static let publicKeyRefused = MySQLProtocolError.insecureAuthRefused(
        "the server asked for the password RSA-encrypted under a public key it "
            + "sends over this plaintext connection, which an attacker in the path "
            + "can substitute. Connect with TLS or over a unix socket, pin the key "
            + "with serverPublicKey = .pinned(contentsOfFile: \"…/public_key.pem\"), "
            + "or accept the risk with serverPublicKey = .requestFromServer"
    )

    private mutating func handlePublicKey(_ buffer: inout ByteBuffer) -> Action {
        guard let header = buffer.readInteger(endianness: .little, as: UInt8.self),
              header == 0x01
        else {
            return failure(.unexpectedPacket("expected AuthMoreData carrying the RSA public key"))
        }
        guard buffer.readableBytes > 0, let pem = buffer.readBytes(length: buffer.readableBytes) else {
            return failure(.malformedPacket("empty RSA public key"))
        }

        switch configuration.serverPublicKey {
        case .refuse where policyGovernsPublicKey:
            // Reachable for `sha256_password`, which is sent the key unprompted
            // rather than being asked for it.
            return failure(Self.publicKeyRefused)

        case .refuse, .requestFromServer:
            break

        case .pinned(let pinned):
            do {
                guard try MySQLRSA.publicKeyDER(pem: pem)
                    == MySQLRSA.publicKeyDER(pem: Array(pinned.utf8))
                else {
                    return failure(.insecureAuthRefused(
                        "the server presented an RSA public key that is not the pinned one. "
                            + "Either the server's key was rotated, or something in the path "
                            + "is substituting its own key to read the password"
                    ))
                }
            } catch let error as MySQLProtocolError {
                return failure(error)
            } catch {
                return failure(.malformedPacket("\(error)"))
            }
        }

        var plaintext = Array(configuration.password.utf8)
        plaintext.append(0)
        // XOR with the nonce, cycling if the password is longer. Skipping this
        // makes the server reject an otherwise correctly encrypted password.
        if !nonce.isEmpty {
            for i in plaintext.indices {
                plaintext[i] ^= nonce[i % nonce.count]
            }
        }

        state = .awaitingFinalResult
        return .encryptAndSend(plaintext: plaintext, publicKeyPEM: pem)
    }

    private mutating func handleFinalResult(
        _ packet: MySQLPacket, _ buffer: inout ByteBuffer
    ) -> Action {
        guard let first = packet.firstByte else {
            return failure(.unexpectedPacket("empty packet awaiting final auth result"))
        }
        switch first {
        case 0x00: return finish(&buffer)
        case 0xFF: return serverError(&buffer)
        default:
            return failure(.unexpectedPacket("unexpected final auth packet 0x\(String(first, radix: 16))"))
        }
    }

    // MARK: - Helpers

    /// Returns nil when the plugin is recognised but unsupported or disallowed.
    private func authResponse(for plugin: MySQLAuthPlugin) -> [UInt8]? {
        switch plugin {
        case .mysqlNativePassword:
            return MySQLAuth.nativePassword(password: configuration.password, scramble: nonce)
        case .cachingSHA2Password:
            return MySQLAuth.cachingSHA2Password(password: configuration.password, scramble: nonce)

        case .sha256Password:
            // Unlike caching_sha2 there is no fast path: the password always
            // goes either in the clear over a secure transport, or RSA-encrypted
            // under a key the server hands over. An empty password sends a lone
            // NUL, which is the documented "no password" marker.
            guard !configuration.password.isEmpty else { return [0x00] }
            // `isTLSEncrypted`, not `effectiveSecureTransport`: a unix socket is
            // secure enough for every other plugin and not for this one. See the
            // property's documentation for how the server settled it.
            if isTLSEncrypted {
                var bytes = Array(configuration.password.utf8)
                bytes.append(0)
                return bytes
            }
            // 0x01 asks the server for its public key; the exchange then
            // rejoins the same RSA path caching_sha2 uses. Refusing here rather
            // than on the reply keeps us from asking a question whose answer we
            // have already decided not to accept.
            guard policyGovernsPublicKey, configuration.serverPublicKey == .refuse
            else { return [0x01] }
            return nil

        case .ed25519:
            // MariaDB signs the scramble with a key derived from the password.
            // Signing cannot meaningfully fail for well-formed input, but a
            // a signing failure surfaces as an unsupported-plugin
            // error rather than a crash.
            return try? MySQLEd25519.sign(password: configuration.password, scramble: nonce)

        case .parsec:
            // parsec is the only plugin needing two round trips: the salt and
            // iteration count arrive *after* this, so an empty packet is the
            // whole of the first response.
            return []
        case .unknown(let name):
            // Cleartext is the one unknown-by-name plugin we can serve, and only
            // under both an explicit opt-in and a secure transport.
            guard name == "mysql_clear_password",
                  configuration.allowCleartextPlugin,
                  effectiveSecureTransport
            else { return nil }
            var bytes = Array(configuration.password.utf8)
            bytes.append(0)
            return bytes
        }
    }

    private func unsupported(_ plugin: MySQLAuthPlugin) -> MySQLProtocolError {
        switch plugin {
        case .sha256Password where policyGovernsPublicKey
            && configuration.serverPublicKey == .refuse:
            // Not "unsupported" at all — the plugin works, we have declined the
            // only way it can run on a plaintext socket.
            return Self.publicKeyRefused

        case .ed25519:
            // Effectively unreachable — signing is pure arithmetic; the plugin
            // itself is implemented.
            return .unsupportedAuthPlugin(
                "client_ed25519: signing failed"
            )
        case .unknown(let name) where name == "mysql_old_password":
            // The same refusal as the bare-`0xFE` form above, for the server that
            // names the plugin instead. One message either way.
            return Self.oldPasswordRefused

        case .unknown(let name) where name == "mysql_clear_password":
            return .insecureAuthRefused(
                configuration.allowCleartextPlugin
                    ? "mysql_clear_password requires a TLS or unix-socket connection"
                    : "mysql_clear_password is disabled; enable it explicitly to use PAM/LDAP auth"
            )
        default:
            return .unsupportedAuthPlugin(plugin.name)
        }
    }

    private mutating func finish(_ buffer: inout ByteBuffer) -> Action {
        do {
            let ok = try MySQLOKPacket.parse(&buffer, capabilities: negotiated.capabilities)
            state = .authenticated
            return .authenticated(ok)
        } catch let error as MySQLProtocolError {
            return failure(error)
        } catch {
            return failure(.malformedPacket("\(error)"))
        }
    }

    private mutating func serverError(_ buffer: inout ByteBuffer) -> Action {
        do {
            let err = try MySQLErrorPacket.parse(&buffer, capabilities: negotiated.capabilities)
            return failure(err.asProtocolError)
        } catch let error as MySQLProtocolError {
            return failure(error)
        } catch {
            return failure(.malformedPacket("\(error)"))
        }
    }

    private mutating func failure(_ error: MySQLProtocolError) -> Action {
        state = .failed
        return .fail(error)
    }
}

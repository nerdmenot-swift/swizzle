import NIOCore
import NIOPosix
import Testing
@testable import SwizzleMySQL

/// The connection matrix: every seeded user on every server, TLS on and off,
/// across MariaDB 11.4, 11.8 and 12.2 — covering `mysql_native_password`,
/// `client_ed25519` and `parsec`.
@Suite(
    "Connection",
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct ConnectionTests {

    static func configuration(
        _ server: MySQLTestServer,
        user: MySQLTestServer.TestUser,
        tls: MySQLConnectionConfiguration.TLSMode
    ) -> MySQLConnectionConfiguration {
        MySQLConnectionConfiguration(
            address: .hostname(TestServers.host, port: server.port),
            username: user.name,
            password: user.password,
            database: TestServers.database,
            tls: tls,
            serverPublicKey: .requestFromServer
        )
    }

    /// The native-password pairs, used by the general connection tests.
    /// `ed25519` and `parsec` have dedicated tests further down, since their
    /// exchanges differ (a signature, and two round trips respectively).
    static let supported: [(MySQLTestServer, MySQLTestServer.TestUser)] =
        TestServers.all.flatMap { server in
            server.users
                .filter { $0.plugin == "mysql_native_password" }
                .map { (server, $0) }
        }

    // MARK: - Plaintext

    @Test("authenticates without TLS", arguments: supported)
    func connectsWithoutTLS(server: MySQLTestServer, user: MySQLTestServer.TestUser) async throws {
        let connection = try await MySQLConnection.connect(
            configuration: Self.configuration(server, user: user, tls: .disable),
            on: TestServers.group.next()
        )
        defer { connection.closeImmediately() }

        #expect(connection.isActive)
        #expect(connection.metadata.isTLSActive == false)
        #expect(connection.metadata.isMariaDB == (server.flavor == .mariaDB))
        #expect(connection.metadata.capabilities.contains(.protocol41))
    }

    // MARK: - TLS

    @Test("authenticates over TLS", arguments: supported)
    func connectsWithTLS(server: MySQLTestServer, user: MySQLTestServer.TestUser) async throws {
        let connection = try await MySQLConnection.connect(
            configuration: Self.configuration(server, user: user, tls: .require),
            on: TestServers.group.next()
        )
        defer { connection.closeImmediately() }

        #expect(connection.isActive)
        #expect(connection.metadata.isTLSActive)
        #expect(connection.metadata.capabilities.contains(.ssl))
    }

    /// Single-connection TLS case, for diagnosing the handshake in isolation
    /// without eleven parallel traces interleaved.
    @Test("TLS handshake completes against one server")
    func tlsSingleServer() async throws {
        let server = TestServers.latest
        let user = server.primaryUser
        let connection = try await MySQLConnection.connect(
            configuration: Self.configuration(server, user: user, tls: .require),
            on: TestServers.group.next()
        )
        defer { connection.closeImmediately() }
        #expect(connection.metadata.isTLSActive)
    }

    // MARK: - Negotiated capabilities

    @Test("negotiates DEPRECATE_EOF with every server", arguments: TestServers.all)
    func negotiatesDeprecateEOF(server: MySQLTestServer) async throws {
        let user = server.primaryUser
        let connection = try await MySQLConnection.connect(
            configuration: Self.configuration(server, user: user, tls: .disable),
            on: TestServers.group.next()
        )
        defer { connection.closeImmediately() }

        // Without this the server sends EOF packets the result-set reader would
        // have to special-case; every server we support honours it.
        #expect(connection.metadata.capabilities.contains(.deprecateEOF))
    }

    @Test("MariaDB extended capabilities negotiate only on MariaDB", arguments: TestServers.all)
    func mariaDBCapabilities(server: MySQLTestServer) async throws {
        let user = server.users[0]
        let connection = try await MySQLConnection.connect(
            configuration: Self.configuration(server, user: user, tls: .disable),
            on: TestServers.group.next()
        )
        defer { connection.closeImmediately() }

        if server.flavor == .mysql {
            #expect(connection.metadata.mariaDBCapabilities.isEmpty)
        }
    }

    // MARK: - Failure paths

    @Test("wrong password is rejected with the server's error", arguments: TestServers.all)
    func wrongPasswordFails(server: MySQLTestServer) async throws {
        let user = server.users.first { !$0.password.isEmpty } ?? server.users[0]
        var config = Self.configuration(server, user: user, tls: .disable)
        config.password = "definitely-not-the-password"

        await #expect(throws: (any Error).self) {
            _ = try await MySQLConnection.connect(
                configuration: config, on: TestServers.group.next()
            )
        }
    }

    @Test("unknown user is rejected", arguments: TestServers.all)
    func unknownUserFails(server: MySQLTestServer) async throws {
        var config = Self.configuration(server, user: server.users[0], tls: .disable)
        config.username = "no_such_user_at_all"

        await #expect(throws: (any Error).self) {
            _ = try await MySQLConnection.connect(
                configuration: config, on: TestServers.group.next()
            )
        }
    }

    /// `client_ed25519` against every server that offers it.
    ///
    /// This is the plugin swift-crypto cannot express — MariaDB seeds the
    /// ed25519 expansion with the password bytes rather than a 32-byte seed —
    /// so it exercises the libsodium path end to end.
    @Test("ed25519 authenticates", arguments: TestServers.mariaDB)
    func ed25519Authenticates(server: MySQLTestServer) async throws {
        guard let user = server.users.first(where: { $0.plugin == "ed25519" }) else {
            Issue.record("\(server) has no ed25519 fixture user"); return
        }

        let connection = try await MySQLConnection.connect(
            configuration: Self.configuration(server, user: user, tls: .disable),
            on: TestServers.group.next()
        )
        defer { connection.closeImmediately() }

        #expect(connection.isActive)
        let who = try await connection.query("SELECT CURRENT_USER() AS u")
        #expect(who.rows[0][0].string?.hasPrefix("ed25519") == true)
    }

    @Test("ed25519 authenticates over TLS", arguments: TestServers.mariaDB)
    func ed25519OverTLS(server: MySQLTestServer) async throws {
        guard let user = server.users.first(where: { $0.plugin == "ed25519" }) else {
            Issue.record("\(server) has no ed25519 fixture user"); return
        }

        let connection = try await MySQLConnection.connect(
            configuration: Self.configuration(server, user: user, tls: .require),
            on: TestServers.group.next()
        )
        defer { connection.closeImmediately() }

        #expect(connection.metadata.isTLSActive)
        let result = try await connection.query("SELECT 1 AS ok")
        #expect(result.rows[0][0].int == 1)
    }

    /// A wrong password must be rejected — otherwise a signature that merely
    /// *looks* well-formed would pass the tests above.
    @Test("ed25519 rejects a wrong password", arguments: TestServers.mariaDB)
    func ed25519RejectsWrongPassword(server: MySQLTestServer) async throws {
        guard let user = server.users.first(where: { $0.plugin == "ed25519" }) else {
            Issue.record("\(server) has no ed25519 fixture user"); return
        }

        var config = Self.configuration(server, user: user, tls: .disable)
        config.password = "definitely-not-the-password"

        await #expect(throws: (any Error).self) {
            _ = try await MySQLConnection.connect(
                configuration: config, on: TestServers.group.next()
            )
        }
    }

    /// `parsec` (MariaDB 11.6+) — the only plugin needing two round trips.
    @Test("parsec authenticates", arguments: TestServers.withParsec)
    func parsecAuthenticates(server: MySQLTestServer) async throws {
        guard let user = server.users.first(where: { $0.plugin == "parsec" }) else {
            Issue.record("\(server) has no parsec fixture user"); return
        }

        let connection = try await MySQLConnection.connect(
            configuration: Self.configuration(server, user: user, tls: .disable),
            on: TestServers.group.next()
        )
        defer { connection.closeImmediately() }

        let who = try await connection.query("SELECT CURRENT_USER() AS u")
        #expect(who.rows[0][0].string?.hasPrefix("parsec") == true)
    }

    @Test("parsec rejects a wrong password", arguments: TestServers.withParsec)
    func parsecRejectsWrongPassword(server: MySQLTestServer) async throws {
        guard let user = server.users.first(where: { $0.plugin == "parsec" }) else {
            Issue.record("\(server) has no parsec fixture user"); return
        }

        var config = Self.configuration(server, user: user, tls: .disable)
        config.password = "definitely-not-the-password"

        await #expect(throws: (any Error).self) {
            _ = try await MySQLConnection.connect(
                configuration: config, on: TestServers.group.next()
            )
        }
    }
}

/// The MySQL-only authentication plugins.
///
/// These are the reason a MySQL fixture exists at all. MariaDB implements
/// neither `caching_sha2_password` nor `sha256_password`, so for a long time
/// both were marked "implemented, unit-tested, never live-verified" — including
/// the RSA full-authentication exchange, which is the most intricate path in the
/// whole handshake and the one most likely to be subtly wrong.
/// `.serialized` because these tests share one piece of *server* state: the
/// `caching_sha2_password` cache. `FLUSH PRIVILEGES` clears it for every user at
/// once, so a test that needs a warm cache and a test that needs a cold one
/// cannot run at the same time against the same server. The trait applies to the
/// nested suite too, which is why the public-key tests live inside this one.
@Suite(
    "MySQL authentication", .serialized,
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct MySQLAuthenticationTests {

    static func configuration(
        _ server: MySQLTestServer,
        user: MySQLTestServer.TestUser,
        tls: MySQLConnectionConfiguration.TLSMode,
        serverPublicKey: MySQLConnectionConfiguration.ServerPublicKey = .refuse
    ) -> MySQLConnectionConfiguration {
        MySQLConnectionConfiguration(
            address: .hostname(TestServers.host, port: server.port),
            username: user.name,
            password: user.password,
            database: TestServers.database,
            tls: tls,
            serverPublicKey: serverPublicKey
        )
    }

    /// Clears the server's `caching_sha2_password` cache, which is the only way
    /// to force the cold path from outside. On its own connection, so the one
    /// under test is guaranteed to face a cold cache.
    ///
    /// **Over TLS deliberately.** MySQL 9 removed `mysql_native_password`, so the
    /// primary fixture user there is itself a `caching_sha2_password` account —
    /// and this call is the very thing that leaves its cache cold. In the clear
    /// the second invocation would be refused by its own first, which is exactly
    /// how it failed.
    static func flushPrivileges(_ server: MySQLTestServer) async throws {
        let admin = try await MySQLConnection.connect(
            configuration: Self.configuration(server, user: server.primaryUser, tls: .require),
            on: TestServers.group.next()
        )
        _ = try await admin.query("FLUSH PRIVILEGES")
        admin.closeImmediately()
    }


    static func user(_ server: MySQLTestServer, plugin: String) -> MySQLTestServer.TestUser? {
        server.users.first { $0.plugin == plugin && !$0.password.isEmpty }
    }

    // MARK: - caching_sha2_password

    /// The **fast path**: the server already has the password cached, so it
    /// answers `fast_auth_success` and expects silence in return.
    ///
    /// The cache is warmed here rather than assumed. It used to be assumed, and
    /// that held only because nothing had cleared it — the moment another test
    /// did, this one started failing for a reason that had nothing to do with
    /// the fast path.
    ///
    /// Warming over TLS then connecting in the clear also makes the assertion
    /// exact. The plaintext connection is left on the **default** `.refuse`
    /// policy, under which a cold cache cannot authenticate at all, so
    /// connecting at all is the proof that the fast path was taken.
    @Test("caching_sha2_password authenticates", arguments: TestServers.mysql)
    func cachingSHA2Authenticates(server: MySQLTestServer) async throws {
        guard let user = Self.user(server, plugin: "caching_sha2_password") else {
            Issue.record("\(server) has no caching_sha2_password fixture user"); return
        }
        let warmUp = try await MySQLConnection.connect(
            configuration: Self.configuration(server, user: user, tls: .require),
            on: TestServers.group.next()
        )
        warmUp.closeImmediately()

        let connection = try await MySQLConnection.connect(
            configuration: Self.configuration(server, user: user, tls: .disable),
            on: TestServers.group.next()
        )
        defer { connection.closeImmediately() }

        let who = try await connection.query("SELECT CURRENT_USER() AS u")
        #expect(who.rows[0][0].string?.hasPrefix("caching") == true)
    }

    /// The **RSA full-authentication path**, and the point of this whole suite.
    ///
    /// `FLUSH PRIVILEGES` clears the server's password cache, so the next
    /// connection cannot take the fast path: the server answers
    /// `perform_full_authentication`, and over a plaintext socket the client must
    /// request the server's public key, XOR the password with the nonce, encrypt
    /// it with RSA-OAEP and send that. Omitting the XOR — easy to do, since the
    /// result still looks like correctly encrypted ciphertext — makes the server
    /// reject it for no visible reason.
    /// The key is *requested from the server*, which has to be opted into —
    /// ``MySQLServerPublicKeyTests`` covers the policy itself and why the default
    /// is to refuse.
    @Test("caching_sha2_password full auth over plaintext", arguments: TestServers.mysql)
    func cachingSHA2FullAuthOverPlaintext(server: MySQLTestServer) async throws {
        guard let user = Self.user(server, plugin: "caching_sha2_password") else {
            Issue.record("\(server) has no caching_sha2_password fixture user"); return
        }

        try await Self.flushPrivileges(server)

        let connection = try await MySQLConnection.connect(
            configuration: Self.configuration(
                server, user: user, tls: .disable, serverPublicKey: .requestFromServer
            ),
            on: TestServers.group.next()
        )
        defer { connection.closeImmediately() }

        #expect(connection.metadata.isTLSActive == false, "the RSA path only applies in the clear")
        let who = try await connection.query("SELECT CURRENT_USER() AS u")
        #expect(who.rows[0][0].string?.hasPrefix("caching") == true)
    }

    /// Over TLS the same cold cache takes the *other* branch: the password goes
    /// in the clear inside the encrypted session and RSA is skipped entirely.
    @Test("caching_sha2_password full auth over TLS", arguments: TestServers.mysql)
    func cachingSHA2FullAuthOverTLS(server: MySQLTestServer) async throws {
        guard let user = Self.user(server, plugin: "caching_sha2_password") else {
            Issue.record("\(server) has no caching_sha2_password fixture user"); return
        }
        try await Self.flushPrivileges(server)

        // Note the default `.refuse` policy, left alone deliberately: over TLS
        // there is no RSA exchange to refuse, and this is what proves it.
        let connection = try await MySQLConnection.connect(
            configuration: Self.configuration(server, user: user, tls: .require),
            on: TestServers.group.next()
        )
        defer { connection.closeImmediately() }

        #expect(connection.metadata.isTLSActive)
        let who = try await connection.query("SELECT CURRENT_USER() AS u")
        #expect(who.rows[0][0].string?.hasPrefix("caching") == true)
    }

    @Test("caching_sha2_password rejects a wrong password", arguments: TestServers.mysql)
    func cachingSHA2RejectsWrongPassword(server: MySQLTestServer) async throws {
        guard let user = Self.user(server, plugin: "caching_sha2_password") else {
            Issue.record("\(server) has no caching_sha2_password fixture user"); return
        }
        // `.requestFromServer` for the same reason as the sha256 case below: a
        // wrong password misses the cache, so the server asks for full auth, and
        // under the default policy the client would refuse before the password
        // was ever sent. The test would still pass, having proven nothing.
        var config = Self.configuration(
            server, user: user, tls: .disable, serverPublicKey: .requestFromServer
        )
        config.password = "definitely-not-the-password"

        await #expect(throws: (any Error).self) {
            _ = try await MySQLConnection.connect(
                configuration: config, on: TestServers.group.next()
            )
        }
    }

    // MARK: - sha256_password

    /// The older MySQL 5.7 plugin, distinct from caching_sha2 despite the name.
    /// It has **no fast path at all**: every connection either sends the password
    /// in the clear over a secure transport, or takes the RSA exchange.
    @Test("sha256_password authenticates over plaintext", arguments: TestServers.mysql)
    func sha256AuthenticatesOverPlaintext(server: MySQLTestServer) async throws {
        guard let user = Self.user(server, plugin: "sha256_password") else {
            Issue.record("\(server) has no sha256_password fixture user"); return
        }
        let connection = try await MySQLConnection.connect(
            configuration: Self.configuration(
                server, user: user, tls: .disable, serverPublicKey: .requestFromServer
            ),
            on: TestServers.group.next()
        )
        defer { connection.closeImmediately() }

        let who = try await connection.query("SELECT CURRENT_USER() AS u")
        #expect(who.rows[0][0].string?.hasPrefix("sha256") == true)
    }

    @Test("sha256_password authenticates over TLS", arguments: TestServers.mysql)
    func sha256AuthenticatesOverTLS(server: MySQLTestServer) async throws {
        guard let user = Self.user(server, plugin: "sha256_password") else {
            Issue.record("\(server) has no sha256_password fixture user"); return
        }
        let connection = try await MySQLConnection.connect(
            configuration: Self.configuration(server, user: user, tls: .require),
            on: TestServers.group.next()
        )
        defer { connection.closeImmediately() }

        #expect(connection.metadata.isTLSActive)
        let who = try await connection.query("SELECT CURRENT_USER() AS u")
        #expect(who.rows[0][0].string?.hasPrefix("sha256") == true)
    }

    @Test("sha256_password rejects a wrong password", arguments: TestServers.mysql)
    func sha256RejectsWrongPassword(server: MySQLTestServer) async throws {
        guard let user = Self.user(server, plugin: "sha256_password") else {
            Issue.record("\(server) has no sha256_password fixture user"); return
        }
        // `.requestFromServer`, so the rejection is genuinely the server
        // refusing the password. Under the default policy this would fail
        // client-side before the password was ever sent, and the test would pass
        // without proving anything.
        var config = Self.configuration(
            server, user: user, tls: .disable, serverPublicKey: .requestFromServer
        )
        config.password = "wrong"

        await #expect(throws: (any Error).self) {
            _ = try await MySQLConnection.connect(
                configuration: config, on: TestServers.group.next()
            )
        }
    }

    /// The RSA public-key policy, against real servers.
    ///
    /// ``ServerPublicKeyPolicyTests`` drives the state machine and covers the
    /// branches a server will not produce on demand. This suite answers the
    /// questions only a server can: that the pinned key is the one MySQL actually
    /// presents, that the file it writes at `public_key.pem` is the file to pin, and
    /// that refusing does not merely fail — it fails *before* the password leaves
    /// the process.
    ///
    /// ## Why every test here uses `sha256_password`
    ///
    /// The RSA exchange is what these tests need the server to demand, and with
    /// `caching_sha2_password` that requires a cold cache — which is *server-wide
    /// state*. Forcing it with `FLUSH PRIVILEGES` worked in isolation and failed
    /// in the full run: suites execute in parallel, another suite authenticated
    /// the same account in the window between the flush and the connection, and
    /// the server answered `fast_auth_success` to a test expecting a refusal.
    ///
    /// `sha256_password` has no cache at all. Over a plaintext socket it takes
    /// the RSA path on every connection, unconditionally, so no test here has to
    /// arrange server state or can be perturbed by a neighbour that does. The
    /// code under test is the same either way: both plugins meet at
    /// `handlePublicKey`.
    ///
    /// `caching_sha2_password`'s own cold-cache path keeps its coverage next
    /// door, in `cachingSHA2FullAuthOverPlaintext`.
    @Suite("server public key, live")
    struct MySQLServerPublicKeyTests {

        typealias Auth = MySQLAuthenticationTests

        static func sha256User(_ server: MySQLTestServer) -> MySQLTestServer.TestUser? {
            guard let user = Auth.user(server, plugin: "sha256_password") else {
                Issue.record("\(server) has no sha256_password fixture user")
                return nil
            }
            return user
        }

        /// **The default, against a real server.** Not a unit test of a switch:
        /// MySQL 8.4 and 9.1 genuinely demanding the RSA exchange, and the client
        /// genuinely declining before the password leaves the process.
        @Test("the default refuses a real RSA exchange", arguments: TestServers.mysql)
        func refusedByDefault(server: MySQLTestServer) async throws {
            guard let user = Self.sha256User(server) else { return }

            do {
                let connection = try await MySQLConnection.connect(
                    configuration: Auth.configuration(server, user: user, tls: .disable),
                    on: TestServers.group.next()
                )
                connection.closeImmediately()
                Issue.record("connected without a public-key policy")
            } catch let error as MySQLProtocolError {
                guard case .insecureAuthRefused(let message) = error else {
                    Issue.record("expected insecureAuthRefused, got \(error)"); return
                }
                #expect(message.contains("pinned"))
            }
        }

        /// Pinning the file MySQL wrote at initialisation. If the key we compare
        /// against were not the key the server presents, this fails — which is what
        /// makes it worth doing live rather than with a fabricated pair.
        @Test("pinning the server's own key authenticates", arguments: TestServers.mysql)
        func pinnedKeyAuthenticates(server: MySQLTestServer) async throws {
            guard let user = Self.sha256User(server) else { return }

            let connection = try await MySQLConnection.connect(
                configuration: Auth.configuration(
                    server, user: user, tls: .disable,
                    serverPublicKey: try .pinned(contentsOfFile: server.publicKeyPath)
                ),
                on: TestServers.group.next()
            )
            defer { connection.closeImmediately() }

            #expect(connection.metadata.isTLSActive == false, "the RSA path only applies in the clear")
            let who = try await connection.query("SELECT CURRENT_USER() AS u")
            #expect(who.rows[0][0].string?.hasPrefix("sha256") == true)
        }

        /// **The substitution, as close to real as a test can get.** Each MySQL
        /// fixture generates its own key pair, so pinning one server's key while
        /// connecting to the other presents the client with a valid RSA key that is
        /// not the pinned one — exactly the shape of a man in the middle, using two
        /// genuine keys rather than a synthetic mismatch.
        @Test("a real key from the wrong server is refused")
        func mismatchedKeyIsRefused() async throws {
            let servers = TestServers.mysql
            guard servers.count >= 2 else {
                Issue.record("need two MySQL fixtures to cross their keys"); return
            }
            let server = servers[0]
            let otherKey = servers[1].publicKeyPath
            guard let user = Self.sha256User(server) else { return }

            do {
                let connection = try await MySQLConnection.connect(
                    configuration: Auth.configuration(
                        server, user: user, tls: .disable,
                        serverPublicKey: try .pinned(contentsOfFile: otherKey)
                    ),
                    on: TestServers.group.next()
                )
                connection.closeImmediately()
                Issue.record("authenticated against a key that was not the pinned one")
            } catch let error as MySQLProtocolError {
                guard case .insecureAuthRefused(let message) = error else {
                    Issue.record("expected insecureAuthRefused, got \(error)"); return
                }
                #expect(message.contains("not the pinned one"))
            }
        }

        /// **Two references disagreed, the server settled it, and we were wrong.**
        ///
        /// `pymysql` treats a unix socket as secure for `sha256_password` and
        /// sends the password in cleartext. `go-sql-driver` says the opposite —
        /// "unlike caching_sha2_password, sha256_password does not accept
        /// cleartext password on unix transport" — and takes the RSA path. We
        /// had followed pymysql.
        ///
        /// MySQL 8.4, asked directly with its own client over the socket and
        /// `--ssl-mode=DISABLED`:
        ///
        /// | account | `--server-public-key-path` | result |
        /// |---|---|---|
        /// | `sha256_password` | the server's own key | authenticates |
        /// | `sha256_password` | another server's key | **access denied** |
        /// | `caching_sha2_password` | none at all | authenticates |
        ///
        /// A client sending cleartext could not be denied for having the wrong
        /// key. So `sha256_password` takes the RSA exchange over a unix socket,
        /// `caching_sha2_password` does not, and go-sql-driver is right.
        ///
        /// Ours had therefore never worked over a socket: it sent cleartext and
        /// the server rejected it as a bad password. Nothing covered it, because
        /// nothing connected to a socket with that plugin.
        ///
        /// The default `.refuse` policy is left in place deliberately as a second
        /// assertion: the RSA exchange happens here, but there is no network to
        /// interpose on, so the policy must stand aside rather than refuse a
        /// connection the `mysql` client would make.
        @Test("sha256_password takes the RSA path over a unix socket",
              arguments: TestServers.mysql)
        func unixSocketIsSecure(server: MySQLTestServer) async throws {
            // No flush: `sha256_password` carries the claim under test and has no
            // cache to clear. `caching_sha2_password` comes along to show the
            // contrast, and takes whichever path its cache happens to allow —
            // both of which must work over a socket.
            for plugin in ["sha256_password", "caching_sha2_password"] {
                guard let user = Auth.user(server, plugin: plugin) else {
                    Issue.record("\(server) has no \(plugin) fixture user"); continue
                }
                let connection = try await MySQLConnection.connect(
                    configuration: MySQLConnectionConfiguration(
                        address: .unixDomainSocket(path: server.socketPath),
                        username: user.name,
                        password: user.password,
                        database: TestServers.database,
                        tls: .disable
                        // No `serverPublicKey` — the default `.refuse` is half
                        // the assertion here. Adding one would hide the very
                        // behaviour the test exists for.
                    ),
                    on: TestServers.group.next()
                )
                defer { connection.closeImmediately() }

                #expect(connection.metadata.isTLSActive == false)
                let who = try await connection.query("SELECT CURRENT_USER() AS u")
                #expect(who.rows[0][0].string?.hasPrefix(user.name) == true)
            }
        }

        /// Pinning must not become a second way to fail on the *secure* path, where
        /// no key is exchanged at all. A pin that broke TLS connections would be
        /// removed from every configuration that had one.
        @Test("a pinned key is irrelevant over TLS", arguments: TestServers.mysql)
        func pinnedKeyIrrelevantOverTLS(server: MySQLTestServer) async throws {
            guard let user = Self.sha256User(server) else { return }

            // Deliberately the *other* server's key: over TLS it is never consulted,
            // so even a wrong pin must not interfere.
            let wrongKey = TestServers.mysql.last!.publicKeyPath
            let connection = try await MySQLConnection.connect(
                configuration: Auth.configuration(
                    server, user: user, tls: .require,
                    serverPublicKey: try .pinned(contentsOfFile: wrongKey)
                ),
                on: TestServers.group.next()
            )
            defer { connection.closeImmediately() }

            #expect(connection.metadata.isTLSActive)
            let who = try await connection.query("SELECT CURRENT_USER() AS u")
            #expect(who.rows[0][0].string?.hasPrefix("sha256") == true)
        }
    }
}

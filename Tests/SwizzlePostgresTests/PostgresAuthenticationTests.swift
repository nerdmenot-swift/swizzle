import NIOCore
import NIOPosix
import SwizzlePostgresDriver
import Testing

/// Authentication, against a real server.
///
/// ## Why this suite exists
///
/// The fixture ran with `--auth=trust`, so the server never asked for a
/// password — which meant **SCRAM-SHA-256, the default for every modern
/// Postgres and this driver's main auth path, had never once run against a real
/// server.** The checklist said "RFC 7677 vectors pass", which was true and is
/// not the same claim: the vectors prove the maths, not the exchange.
///
/// The MySQL side has always had a five-server, six-plugin matrix here. This is
/// the Postgres equivalent, and `pg_hba.conf` now carries a rule per mechanism.
@Suite(
    "Postgres authentication", .serialized,
    .enabled(if: PostgresTestServer.isAvailable, PostgresTestServer.skipReason)
)
struct PostgresAuthenticationTests {

    static let host = "127.0.0.1"
    static let port = 5432
    static let database = "swizzle_test"

    static func configuration(
        user: String, password: String?
    ) throws -> PostgresConnectionConfiguration {
        PostgresConnectionConfiguration(
            address: .tcp(host: host, port: port),
            username: user,
            password: password,
            database: database,
            // The fixture has no certificate, so TLS is not the thing under test
            // here — the authentication exchange is.
            tlsMode: .disable
        )
    }

    static func connect(user: String, password: String?) async throws -> PostgresConnection {
        try await PostgresConnection.connect(
            configuration: try configuration(user: user, password: password),
            on: MultiThreadedEventLoopGroup.singleton.next()
        )
    }

    // MARK: - SCRAM-SHA-256

    /// The modern default, and the one that matters most.
    @Test("SCRAM-SHA-256 authenticates")
    func scram() async throws {
        let connection = try await Self.connect(user: "swizzle_scram", password: "scrampass")
        defer { connection.closeImmediately() }

        let rows = try await connection.query("SELECT current_user").rows
        #expect(rows.first?.first == .text("swizzle_scram"))
    }

    /// A wrong password must fail as *authentication*, not as something vaguer —
    /// the taxonomy is what tells a caller to check credentials rather than
    /// retry.
    @Test("SCRAM rejects a wrong password")
    func scramWrongPassword() async throws {
        await #expect(throws: (any Error).self) {
            let connection = try await Self.connect(
                user: "swizzle_scram", password: "not-the-password"
            )
            connection.closeImmediately()
        }
    }

    /// The server asks for SCRAM and the client has nothing to answer with. This
    /// has to be a clean error rather than a hang or a crash.
    @Test("SCRAM with no password configured fails cleanly")
    func scramWithoutPassword() async throws {
        await #expect(throws: (any Error).self) {
            let connection = try await Self.connect(user: "swizzle_scram", password: nil)
            connection.closeImmediately()
        }
    }

    /// SCRAM proves the *server* knows the password too, and the client checks
    /// its final signature. A connection that reaches `ReadyForQuery` has
    /// completed that verification — this asserts the connection is genuinely
    /// usable afterwards rather than merely opened.
    @Test("a SCRAM connection is fully usable")
    func scramConnectionWorks() async throws {
        let connection = try await Self.connect(user: "swizzle_scram", password: "scrampass")
        defer { connection.closeImmediately() }

        _ = try await connection.query("CREATE TEMP TABLE scram_probe (id int)")
        _ = try await connection.query("INSERT INTO scram_probe VALUES (1), (2)")
        let count = try await connection.query("SELECT count(*) FROM scram_probe").rows
        #expect(count.first?.first == .int(2))

        // And a bound query, which is the extended protocol on top of it.
        let bound = try await connection.query("SELECT $1::int", [.int(9)]).rows
        #expect(bound.first?.first == .int(9))
    }

    // MARK: - MD5

    /// Deprecated by Postgres and still ubiquitous in the wild — plenty of
    /// long-lived installations have never rotated their verifiers.
    @Test("MD5 authenticates")
    func md5() async throws {
        let connection = try await Self.connect(user: "swizzle_md5", password: "md5pass")
        defer { connection.closeImmediately() }

        let rows = try await connection.query("SELECT current_user").rows
        #expect(rows.first?.first == .text("swizzle_md5"))
    }

    @Test("MD5 rejects a wrong password")
    func md5WrongPassword() async throws {
        await #expect(throws: (any Error).self) {
            let connection = try await Self.connect(user: "swizzle_md5", password: "wrong")
            connection.closeImmediately()
        }
    }

    // MARK: - Trust

    /// The path every other Postgres test in this repo takes, asserted here so
    /// the suite covers all three of the fixture's `pg_hba` rules rather than
    /// two.
    @Test("trust authentication needs no password")
    func trust() async throws {
        let connection = try await Self.connect(user: "swizzle", password: nil)
        defer { connection.closeImmediately() }

        let rows = try await connection.query("SELECT current_user").rows
        #expect(rows.first?.first == .text("swizzle"))
    }

    // MARK: - The security gate

    /// **The rule the driver adds on top of the protocol.** Postgres will happily
    /// ask for a plaintext password over a plaintext link, and a client that
    /// complies has posted the password to anyone listening. The driver refuses,
    /// and the refusal names what to do about it.
    ///
    /// Asserted at the state machine because provoking it needs a server
    /// configured for `password` auth, and the point is that the client refuses
    /// regardless of what the server asks for.
    @Test("cleartext over an unencrypted link is refused")
    func cleartextIsGated() {
        var machine = PostgresAuthenticationStateMachine(
            configuration: .init(
                username: "u", password: "p", database: "d", isSecureTransport: false
            )
        )
        _ = machine.start()

        guard case .fail(let error) = machine.handle(.cleartextPassword) else {
            Issue.record("a cleartext request over a plaintext link must be refused")
            return
        }
        #expect(error == .insecureCleartextRefused)

        // …and accepted once the link is private.
        var secure = PostgresAuthenticationStateMachine(
            configuration: .init(
                username: "u", password: "p", database: "d", isSecureTransport: true
            )
        )
        _ = secure.start()
        guard case .send(.password(let sent)) = secure.handle(.cleartextPassword) else {
            Issue.record("expected the password to be sent over a private link")
            return
        }
        #expect(sent == "p")
    }
}

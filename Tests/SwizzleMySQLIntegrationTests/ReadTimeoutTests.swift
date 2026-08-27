import NIOCore
import NIOPosix
import Testing

@testable import SwizzleMySQL

/// The read timeout, against a server that stops answering mid-command.
///
/// `tcpKeepalive` covers the idle-connection case and is on by default. This
/// covers the narrower one it cannot: a path that dies **while a command is in
/// flight**, before keep-alive probes have had time to notice. Without it the
/// caller waits on a socket that will never answer — TCP does not abandon a
/// black-holed connection for about fifteen minutes, and if the flow was dropped
/// silently rather than reset, never.
// test-hygiene: no server — brings its own listener
@Suite("MySQL read timeout")
struct MySQLReadTimeoutTests {

    /// A socket that completes the TCP connect and then says nothing at all.
    ///
    /// It never speaks MySQL, so `connect` cannot finish either — which is
    /// exactly the point: the same silence has to be bounded wherever it
    /// happens, and `connectTimeout` is what bounds it here.
    @Test("a silent server does not hang the connect")
    func silentServerDoesNotHangConnect() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let silent = try await ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 16)
            .childChannelInitializer { _ in group.next().makeSucceededVoidFuture() }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        defer { silent.close(promise: nil) }
        let port = try #require(silent.localAddress?.port)

        var configuration = MySQLConnectionConfiguration(
            address: .hostname("127.0.0.1", port: port), username: "u", tls: .disable)
        configuration.connectTimeout = .milliseconds(500)
        // Two seconds, not 300ms. The idle period below still has to exceed the
        // timeout for this to prove anything — but the *queries* need headroom too,
        // and on a two-core runner a plain round trip can take longer than 300ms.
        // Choosing a bound that a live connection cannot meet tests the runner.
        configuration.readTimeout = .seconds(2)

        let started = ContinuousClock().now
        await #expect(throws: (any Error).self) {
            let connection = try await MySQLConnection.connect(
                configuration: configuration, on: group.next())
            connection.closeImmediately()
        }
        // Bounded well under the fifteen minutes TCP would take on its own.
        #expect(ContinuousClock().now - started < .seconds(10))
    }

    /// The setting is off unless asked for, matching `go-sql-driver`, whose
    /// `NewConfig` leaves `ReadTimeout` at zero.
    ///
    /// Deliberate rather than an oversight: a legitimate query can produce no
    /// bytes for minutes — a large aggregate, a lock wait, an `ALTER` — and a
    /// driver that killed those by default would be broken more obviously than
    /// the hang it was preventing.
    @Test("it is off by default")
    func offByDefault() {
        let configuration = MySQLConnectionConfiguration(
            address: .hostname("db.example.com", port: 3306), username: "u")
        #expect(configuration.readTimeout == nil)
    }

    /// And an ordinary query is not disturbed by it.
    @Test(
        "a working server is unaffected",
        .enabled(if: TestServers.isAvailable, "Integration servers not reachable")
    )
    func workingServerUnaffected() async throws {
        let server = TestServers.mariadb114
        let user = server.primaryUser
        var configuration = MySQLConnectionConfiguration(
            address: .hostname(TestServers.host, port: server.port),
            username: user.name, password: user.password,
            database: TestServers.database, tls: .disable,
            serverPublicKey: .requestFromServer)
        configuration.readTimeout = .seconds(5)

        let connection = try await MySQLConnection.connect(
            configuration: configuration, on: TestServers.group.next())
        defer { connection.closeImmediately() }
        #expect(try await connection.query("SELECT 1").rows[0][0].int == 1)
        // A second command on the same connection: the idle handler must not
        // have counted the gap between them as a stalled read.
        #expect(try await connection.query("SELECT 2").rows[0][0].int == 2)
    }

    /// An idle pooled connection reads nothing by definition. Failing on every
    /// idle event would close exactly the connections that are behaving, turning
    /// a safety feature into a pool that empties itself.
    @Test(
        "an idle connection is left alone",
        .enabled(if: TestServers.isAvailable, "Integration servers not reachable")
    )
    func idleConnectionSurvives() async throws {
        let server = TestServers.mariadb114
        let user = server.primaryUser
        var configuration = MySQLConnectionConfiguration(
            address: .hostname(TestServers.host, port: server.port),
            username: user.name, password: user.password,
            database: TestServers.database, tls: .disable,
            serverPublicKey: .requestFromServer)
        // Same reasoning as the Postgres suite: the idle window must outlast the
        // timeout, and a live query must comfortably beat it.
        configuration.readTimeout = .seconds(2)

        let connection = try await MySQLConnection.connect(
            configuration: configuration, on: TestServers.group.next())
        defer { connection.closeImmediately() }

        // Well past the timeout with no command outstanding.
        try await Task.sleep(for: .seconds(5))
        #expect(connection.isActive, "an idle connection was closed by the read timeout")
        #expect(try await connection.query("SELECT 1").rows[0][0].int == 1)
    }
}

extension MySQLReadTimeoutTests {
    /// The invariant the previous design did not have.
    ///
    /// The idle test above is not deterministic: it passed on macOS against the
    /// broken `IdleStateHandler` version and failed on Linux, because whether the
    /// overdue timer fired during the idle period or just after the next command
    /// started was a race. A test that only sometimes catches the bug is how this
    /// reached Linux in the first place.
    ///
    /// So this asserts the structural property instead — a deadline exists only
    /// while a command does. Under the old design the clock ran continuously and
    /// this could not have held.
    @Test(
        "no deadline is armed while the connection is idle",
        .enabled(if: TestServers.isAvailable, "Integration servers not reachable")
    )
    func deadlineOnlyExistsDuringACommand() async throws {
        let server = TestServers.mariadb114
        let user = server.primaryUser
        var configuration = MySQLConnectionConfiguration(
            address: .hostname(TestServers.host, port: server.port),
            username: user.name, password: user.password,
            database: TestServers.database, tls: .disable,
            serverPublicKey: .requestFromServer)
        configuration.readTimeout = .seconds(30)

        let connection = try await MySQLConnection.connect(
            configuration: configuration, on: TestServers.group.next())
        defer { connection.closeImmediately() }

        func handler() async throws -> MySQLCommandHandler {
            try await connection.channel.pipeline
                .handler(type: MySQLCommandHandler.self).get()
        }

        // Freshly connected and idle.
        #expect(try await handler().hasArmedDeadline == false)

        _ = try await connection.query("SELECT 1")
        // And idle again once the command has completed — not left armed to
        // expire against whatever runs next.
        #expect(
            try await handler().hasArmedDeadline == false,
            "a deadline outlived its command and would be charged to the next one")
    }
}

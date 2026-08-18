import NIOCore
import NIOPosix
import SwizzlePostgres
import SwizzlePostgresDriver
import Testing

/// The read timeout and TCP keep-alive, on the Postgres side.
///
/// Its own suite because the two drivers are near-identical here and one of them
/// was left behind once already: the whole-connection connect deadline was fixed
/// in Postgres and not in MySQL, and MySQL kept the hang for hours until a test
/// written for something else sat on it for ten minutes. Parity is asserted
/// rather than assumed.
// test-hygiene: no server — brings its own listener
@Suite("Postgres read timeout")
struct PostgresReadTimeoutTests {

    @Test("it is off by default, as go-sql-driver has it")
    func offByDefault() {
        let configuration = PostgresConnectionConfiguration(
            address: .tcp(host: "db.example.com", port: 5432), username: "u")
        #expect(configuration.readTimeout == nil)
    }

    @Test("keep-alive is on by default")
    func keepaliveOnByDefault() {
        let configuration = PostgresConnectionConfiguration(
            address: .tcp(host: "db.example.com", port: 5432), username: "u")
        #expect(configuration.tcpKeepalive.isEnabled)
        // The idle time is the part that does the work: the kernel default is
        // two hours, far longer than anything that reaps idle flows.
        #expect(configuration.tcpKeepalive.idle == .seconds(60))
    }

    /// A server that accepts and never speaks must not hang the connect. Same
    /// listener, same assertion as the MySQL suite.
    @Test("a silent server does not hang the connect")
    func silentServerDoesNotHangConnect() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let silent = try await ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 16)
            .childChannelInitializer { _ in group.next().makeSucceededVoidFuture() }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        defer { try? silent.close().wait() }
        let port = try #require(silent.localAddress?.port)

        var configuration = PostgresConnectionConfiguration(
            address: .tcp(host: "127.0.0.1", port: port), username: "u")
        configuration.tlsMode = .disable
        configuration.connectTimeout = .milliseconds(500)
        configuration.readTimeout = .milliseconds(300)

        let started = ContinuousClock().now
        await #expect(throws: (any Error).self) {
            let connection = try await PostgresConnection.connect(
                configuration: configuration, on: group.next())
            connection.closeImmediately()
        }
        #expect(ContinuousClock().now - started < .seconds(10))
    }

    /// An idle connection is left alone; a working one is undisturbed.
    @Test(
        "a live connection is unaffected, idle or busy",
        .enabled(if: PostgresTestServer.isAvailable, PostgresTestServer.skipReason)
    )
    func liveConnectionUnaffected() async throws {
        var configuration = try PostgresConnectionConfiguration(
            swizzleURL: PostgresTestServer.url)
        configuration.readTimeout = .milliseconds(300)

        let connection = try await PostgresConnection.connect(
            configuration: configuration, on: MultiThreadedEventLoopGroup.singleton.next())
        defer { connection.closeImmediately() }

        #expect(try await connection.query("SELECT 1").rows[0][0] == .int(1))
        // Idle for well over the timeout with nothing outstanding.
        try await Task.sleep(for: .milliseconds(900))
        #expect(connection.isActive, "an idle connection was closed by the read timeout")
        #expect(try await connection.query("SELECT 2").rows[0][0] == .int(2))
    }
}

import NIOCore
import NIOPosix
import SwizzlePostgres
@testable import SwizzlePostgresDriver
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
        defer { silent.close(promise: nil) }
        let port = try #require(silent.localAddress?.port)

        var configuration = PostgresConnectionConfiguration(
            address: .tcp(host: "127.0.0.1", port: port), username: "u")
        configuration.tlsMode = .disable
        configuration.connectTimeout = .milliseconds(500)
        // Two seconds, not 300ms. The idle period below still has to exceed the
        // timeout for this to prove anything — but the *queries* need headroom too,
        // and on a two-core runner a plain round trip can take longer than 300ms.
        // Choosing a bound that a live connection cannot meet tests the runner.
        configuration.readTimeout = .seconds(2)

        let started = ContinuousClock().now
        do {
            let connection = try await PostgresConnection.connect(
                configuration: configuration, on: group.next())
            connection.closeImmediately()
            Issue.record("a silent server completed the connect")
        } catch let error as PostgresConnectionError {
            // **The error is the claim**, exactly as in the MySQL twin. It names
            // the mechanism that bounded the wait, which is what this test is
            // about — that the silence was cut short by `connect_timeout` rather
            // than left to TCP.
            #expect(
                "\(error)".contains("connect_timeout"),
                Comment(rawValue: "expected the connect timeout, got \(error)")
            )
        }

        let elapsed = ContinuousClock().now - started

        // Keep the observation without asserting on it, matching the MySQL twin.
        // The bound here was ten seconds and Linux CI measured 10.99s with the
        // mechanism working; thirty was the next guess. Both were measuring the
        // runner, and the contention is now understood — these suites run
        // alongside CPU-bound work on a two-core box, and cancellation delivery
        // waits on the cooperative pool.
        if elapsed > .seconds(5) {
            print("""
                NOTE: the connect took \(elapsed) against a 500ms connect_timeout. \
                The timeout fired — the error above says so — but something \
                delayed it by more than 10x.
                """)
        }

        // A backstop, not a measurement: it only catches a connect left to TCP,
        // which takes about fifteen minutes.
        #expect(elapsed < .seconds(120))
    }

    /// An idle connection is left alone; a working one is undisturbed.
    @Test(
        "a live connection is unaffected, idle or busy",
        .enabled(if: PostgresTestServer.isAvailable, PostgresTestServer.skipReason)
    )
    func liveConnectionUnaffected() async throws {
        var configuration = try PostgresConnectionConfiguration(
            swizzleURL: PostgresTestServer.url)
        // Two seconds, not 300ms. The idle window below still has to outlast the
        // timeout for this to prove anything — but a live query needs headroom too,
        // and on a two-core runner a plain round trip can exceed 300ms. This failed
        // in CI for exactly that: `a command with no reply for 300ms` on a
        // connection that was working perfectly.
        configuration.readTimeout = .seconds(2)

        let connection = try await PostgresConnection.connect(
            configuration: configuration, on: MultiThreadedEventLoopGroup.singleton.next())
        defer { connection.closeImmediately() }

        #expect(try await connection.query("SELECT 1").rows[0][0] == .int(1))
        // Idle for well over the timeout with nothing outstanding.
        try await Task.sleep(for: .seconds(5))
        #expect(connection.isActive, "an idle connection was closed by the read timeout")
        #expect(try await connection.query("SELECT 2").rows[0][0] == .int(2))
    }
}

extension PostgresReadTimeoutTests {
    /// The same invariant asserted on the MySQL side, because the two drivers
    /// diverging silently is how the connect hang survived a whole afternoon.
    @Test(
        "no deadline is armed while the connection is idle",
        .enabled(if: PostgresTestServer.isAvailable, PostgresTestServer.skipReason)
    )
    func deadlineOnlyExistsDuringACommand() async throws {
        var configuration = try PostgresConnectionConfiguration(
            swizzleURL: PostgresTestServer.url)
        configuration.readTimeout = .seconds(30)

        let connection = try await PostgresConnection.connect(
            configuration: configuration, on: MultiThreadedEventLoopGroup.singleton.next())
        defer { connection.closeImmediately() }

        func handler() async throws -> PostgresCommandHandler {
            try await connection.channel.pipeline
                .handler(type: PostgresCommandHandler.self).get()
        }

        #expect(try await handler().hasArmedDeadline == false)
        _ = try await connection.query("SELECT 1")
        #expect(
            try await handler().hasArmedDeadline == false,
            "a deadline outlived its command and would be charged to the next one")
    }
}

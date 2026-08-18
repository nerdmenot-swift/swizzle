import NIOCore
import NIOPosix
@testable import SwizzleMySQL
import Testing

/// Keep-alive, read back off the real socket.
///
/// Asserting that the configuration holds the value proves nothing — the bug
/// worth catching is a `channelOption` that never reaches the kernel, and that
/// looks identical from the configuration's side.
///
/// The gap this closes: neither driver set any socket option at all. `libpq`
/// defaults `keepalives=1` and `pgx` inherits Go's dialer, which enables it. A
/// pooled connection reaped by a NAT or a load balancer left us holding a socket
/// that would never answer and never time out.
@Suite(
    "TCP keep-alive",
    .enabled(if: TestServers.isAvailable, "Integration servers not reachable")
)
struct TCPKeepaliveTests {

    static func connect(
        _ keepalive: TCPKeepalive, _ server: MySQLTestServer = TestServers.mariadb114
    ) async throws -> MySQLConnection {
        let user = server.primaryUser
        var configuration = MySQLConnectionConfiguration(
            address: .hostname(TestServers.host, port: server.port),
            username: user.name, password: user.password,
            database: TestServers.database, tls: .disable,
            serverPublicKey: .requestFromServer
        )
        configuration.tcpKeepalive = keepalive
        return try await MySQLConnection.connect(
            configuration: configuration, on: TestServers.group.next()
        )
    }

    /// The default is on, and on means the kernel says so.
    @Test("keep-alive is enabled on the socket by default")
    func enabledByDefault() async throws {
        let connection = try await Self.connect(TCPKeepalive())
        defer { connection.closeImmediately() }

        let enabled = try await connection.channel.getOption(.socketOption(.so_keepalive)).get()
        // Non-zero rather than `== 1`: BSD's `getsockopt` hands back the flag's
        // own bit out of `so_options`, so Darwin answers 8 (`SO_KEEPALIVE`)
        // where Linux answers 1. Asserting 1 fails on macOS for a socket that is
        // correctly configured.
        #expect(enabled != 0, "SO_KEEPALIVE is off — a reaped connection would hang forever")
    }

    /// And the idle time is set, which is the part that does the work.
    ///
    /// `SO_KEEPALIVE` on its own is nearly useless here: both Linux and Darwin
    /// default the idle time to **two hours**, so a flow dropped at 350 seconds
    /// stays dead for the rest of them. Reading it back is what distinguishes
    /// "keep-alive is on" from "keep-alive is on and will notice in time".
    @Test("the idle time is what was asked for, not the kernel's two hours")
    func idleTimeIsApplied() async throws {
        let connection = try await Self.connect(
            TCPKeepalive(idle: .seconds(45), interval: .seconds(5), count: 4)
        )
        defer { connection.closeImmediately() }

        let idle = try await connection.channel
            .getOption(.tcpOption(TCPKeepalive.idleOption)).get()
        #expect(idle == 45, "TCP_KEEPIDLE is \(idle)s — the default is 7200")
    }

    /// Off stays off, so a caller with a reason is believed.
    @Test("disabling it really disables it")
    func disabled() async throws {
        let connection = try await Self.connect(.disabled)
        defer { connection.closeImmediately() }

        let enabled = try await connection.channel.getOption(.socketOption(.so_keepalive)).get()
        #expect(enabled == 0)
    }
}

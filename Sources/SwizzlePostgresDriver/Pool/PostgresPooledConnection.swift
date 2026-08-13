import SwizzleConnectionPool

/// Keeps idle pooled connections from being reaped by something in the middle.
///
/// A connection that has sat idle for minutes may have been dropped by a NAT
/// table, a load balancer, or the server's own `idle_session_timeout` — and
/// nothing tells the client. Without a periodic ping, the first query after a
/// quiet period is the one that discovers it, which puts the failure in a user's
/// request rather than in the pool's own maintenance.
public struct PostgresKeepAliveBehavior: ConnectionKeepAliveBehavior, Sendable {
    public typealias Connection = PostgresConnection

    public var keepAliveFrequency: Duration?

    public init(frequency: Duration? = .seconds(30)) {
        self.keepAliveFrequency = frequency
    }

    public func runKeepAlive(for connection: PostgresConnection) async throws {
        try await connection.ping()
    }
}

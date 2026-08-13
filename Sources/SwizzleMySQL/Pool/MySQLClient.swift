import Logging
import NIOCore
import NIOPosix
import ServiceLifecycle
import SwizzleConnectionPool

/// A pooled MySQL client.
///
/// This is the type applications should hold: it owns a connection pool, hands
/// out connections for the duration of a closure, and returns them clean.
///
/// Run it as a `ServiceLifecycle` service so shutdown is graceful — `run()`
/// stays alive until cancelled, then closes idle connections and waits for
/// in-flight work rather than dropping sockets.
public final class MySQLClient: Sendable, Service {

    public struct Configuration: Sendable {
        public var connection: MySQLConnectionConfiguration
        /// Connections kept open when idle.
        public var minimumConnections: Int
        /// Hard ceiling on concurrent connections.
        public var maximumConnections: Int
        /// How long an idle connection above the minimum survives.
        public var idleTimeout: Duration
        /// `COM_PING` interval for idle connections. Nil disables keep-alive.
        public var keepAliveFrequency: Duration?
        /// Reset session state before a connection is reused.
        ///
        /// On by default. Without it, temp tables, session variables, user
        /// variables and the `sql_mode` set by one borrower are still there for
        /// the next — a cross-talk bug that surfaces as impossible behaviour in
        /// unrelated code.
        public var resetOnRelease: Bool

        /// How long a caller waits for a connection before giving up.
        ///
        /// The pool retries failed connections with backoff and will otherwise
        /// keep a waiter queued indefinitely — so during a database outage every
        /// request would hang rather than fail. A bounded wait turns that into a
        /// fast, visible error. Set to nil to wait forever.
        public var connectionAcquisitionTimeout: Duration?

        public init(
            connection: MySQLConnectionConfiguration,
            minimumConnections: Int = 0,
            maximumConnections: Int = 20,
            idleTimeout: Duration = .seconds(60),
            keepAliveFrequency: Duration? = .seconds(30),
            resetOnRelease: Bool = true,
            connectionAcquisitionTimeout: Duration? = .seconds(10)
        ) {
            self.connectionAcquisitionTimeout = connectionAcquisitionTimeout
            self.connection = connection
            self.minimumConnections = minimumConnections
            self.maximumConnections = maximumConnections
            self.idleTimeout = idleTimeout
            self.keepAliveFrequency = keepAliveFrequency
            self.resetOnRelease = resetOnRelease
        }
    }

    typealias Pool = ConnectionPool<
        MySQLConnection,
        MySQLConnection.ID,
        ConnectionIDGenerator,
        ConnectionRequest<MySQLConnection>,
        ConnectionRequest.ID,
        MySQLKeepAliveBehavior,
        MySQLPoolMetrics,
        ContinuousClock
    >

    private let pool: Pool
    private let configuration: Configuration
    private let eventLoopGroup: any EventLoopGroup
    private let logger: Logger
    private let metrics: MySQLPoolMetrics

    /// Live pool statistics — open connections, queue depth, keep-alive
    /// outcomes. Also emitted through `swift-metrics`.
    public var statistics: MySQLPoolStatistics { metrics.statistics }

    public init(
        configuration: Configuration,
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        logger: Logger = Logger(label: "swizzle.mysql"),
        metrics: MySQLPoolMetrics? = nil
    ) {
        self.configuration = configuration
        self.eventLoopGroup = eventLoopGroup
        self.logger = logger
        let metrics = metrics ?? MySQLPoolMetrics(logger: logger)
        self.metrics = metrics

        var poolConfiguration = ConnectionPoolConfiguration()
        poolConfiguration.minimumConnectionCount = configuration.minimumConnections
        poolConfiguration.maximumConnectionSoftLimit = configuration.maximumConnections
        poolConfiguration.maximumConnectionHardLimit = configuration.maximumConnections
        poolConfiguration.idleTimeout = configuration.idleTimeout

        let connectionConfiguration = configuration.connection
        let group = eventLoopGroup

        self.pool = ConnectionPool(
            configuration: poolConfiguration,
            idGenerator: ConnectionIDGenerator(),
            requestType: ConnectionRequest<MySQLConnection>.self,
            keepAliveBehavior: MySQLKeepAliveBehavior(
                frequency: configuration.keepAliveFrequency
            ),
            observabilityDelegate: metrics,
            clock: ContinuousClock()
        ) { poolID, _ in
            let connection = try await MySQLConnection.connect(
                configuration: connectionConfiguration,
                on: group.next()
            )
            // The pool identifies connections by the id it assigned, so this
            // must be adopted before the connection is returned to it.
            connection.assignPoolID(poolID)
            // One command at a time — MySQL has no pipelining, so a connection
            // can never serve two concurrent borrowers.
            return ConnectionAndMetadata(connection: connection, maximalStreamsOnConnection: 1)
        }
    }

    /// Runs the pool until cancelled, then shuts it down gracefully.
    public func run() async {
        await cancelOnGracefulShutdown {
            await self.pool.run()
        }
    }

    /// Borrows a connection for the duration of `body`.
    ///
    /// The connection is returned to the pool afterwards — reset first, unless
    /// that was disabled. A connection that failed mid-use is closed rather than
    /// reused, because its protocol state may be mid-result-set and the damage
    /// would land on the next borrower.
    public func withConnection<Result: Sendable>(
        _ body: (MySQLConnection) async throws -> Result
    ) async throws -> Result {
        let lease = try await leaseWithTimeout()
        let connection = lease.connection

        do {
            let result = try await body(connection)
            await releaseCleanly(connection, lease: lease)
            return result
        } catch {
            // Protocol errors can leave unread packets queued. Anything else
            // (an application error thrown from `body`) leaves the connection
            // fine, so it is still worth returning.
            if error is MySQLProtocolError {
                connection.closeImmediately()
            } else {
                await releaseCleanly(connection, lease: lease)
            }
            throw error
        }
    }

    /// Convenience for a single query.
    @discardableResult
    public func query(_ sql: String) async throws -> MySQLQueryResult {
        try await withConnection { try await $0.query(sql) }
    }

    /// Convenience for a single parameterised query.
    @discardableResult
    public func query(
        _ sql: String, _ parameters: [MySQLValue]
    ) async throws -> MySQLQueryResult {
        try await withConnection { try await $0.query(sql, parameters) }
    }

    /// Races the lease against the acquisition timeout.
    ///
    /// Cancelling the group cancels the outstanding lease request too, so a
    /// timed-out waiter does not leave a connection checked out to nobody.
    private func leaseWithTimeout() async throws -> ConnectionLease<MySQLConnection> {
        guard let timeout = configuration.connectionAcquisitionTimeout else {
            return try await pool.leaseConnection()
        }

        return try await withThrowingTaskGroup(
            of: ConnectionLease<MySQLConnection>?.self
        ) { group in
            group.addTask { try await self.pool.leaseConnection() }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }

            defer { group.cancelAll() }
            while let outcome = try await group.next() {
                if let lease = outcome { return lease }
                throw MySQLPoolError.connectionAcquisitionTimeout(timeout)
            }
            throw MySQLPoolError.connectionAcquisitionTimeout(timeout)
        }
    }

    private func releaseCleanly(
        _ connection: MySQLConnection,
        lease: ConnectionLease<MySQLConnection>
    ) async {
        if configuration.resetOnRelease {
            do {
                // Clears temp tables, session and user variables — and the
                // prepared-statement cache with them, since the server
                // deallocates every statement.
                try await connection.resetConnection()
            } catch {
                // A connection that cannot be reset is not safe to hand on.
                logger.debug("discarding connection that failed to reset: \(error)")
                connection.closeImmediately()
                return
            }
        }
        lease.release()
    }
}

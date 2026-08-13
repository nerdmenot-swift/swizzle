import Logging
import NIOCore
import NIOPosix
import ServiceLifecycle
import SwizzleConnectionPool
import SwizzleCore

public enum PostgresPoolError: Error, Sendable, CustomStringConvertible {
    case connectionAcquisitionTimeout(Duration)

    public var description: String {
        switch self {
        case .connectionAcquisitionTimeout(let timeout):
            "no connection became available within \(timeout)"
        }
    }
}

/// A pooled Postgres client.
///
/// This is the type applications should hold: it owns a connection pool, hands
/// out connections for the duration of a closure, and returns them clean.
///
/// Run it as a `ServiceLifecycle` service so shutdown is graceful — `run()` stays
/// alive until cancelled, then closes idle connections and waits for in-flight
/// work rather than dropping sockets.
public final class PostgresClient: Sendable, Service {

    public struct Configuration: Sendable {
        public var connection: PostgresConnectionConfiguration
        /// Connections kept open when idle.
        public var minimumConnections: Int
        /// Hard ceiling on concurrent connections.
        public var maximumConnections: Int
        /// How long an idle connection above the minimum survives.
        public var idleTimeout: Duration
        /// Ping interval for idle connections. Nil disables keep-alive.
        public var keepAliveFrequency: Duration?

        /// Reset session state before a connection is reused.
        ///
        /// On by default, and it matters more here than on MySQL: a borrower that
        /// returns a connection **mid-transaction** hands the next one a session
        /// silently enrolled in a transaction it never opened, holding locks it
        /// cannot see. `DISCARD ALL` is Postgres's own answer to that.
        public var resetOnRelease: Bool

        /// How long a caller waits for a connection before giving up.
        ///
        /// The pool retries failed connections with backoff and will otherwise
        /// keep a waiter queued indefinitely — so during a database outage every
        /// request would hang rather than fail. A bounded wait turns that into a
        /// fast, visible error. Nil waits forever.
        public var connectionAcquisitionTimeout: Duration?

        public init(
            connection: PostgresConnectionConfiguration,
            minimumConnections: Int = 0,
            maximumConnections: Int = 20,
            idleTimeout: Duration = .seconds(60),
            keepAliveFrequency: Duration? = .seconds(30),
            resetOnRelease: Bool = true,
            connectionAcquisitionTimeout: Duration? = .seconds(10)
        ) {
            self.connection = connection
            self.minimumConnections = minimumConnections
            self.maximumConnections = maximumConnections
            self.idleTimeout = idleTimeout
            self.keepAliveFrequency = keepAliveFrequency
            self.resetOnRelease = resetOnRelease
            self.connectionAcquisitionTimeout = connectionAcquisitionTimeout
        }
    }

    typealias Pool = ConnectionPool<
        PostgresConnection,
        PostgresConnection.ID,
        ConnectionIDGenerator,
        ConnectionRequest<PostgresConnection>,
        ConnectionRequest.ID,
        PostgresKeepAliveBehavior,
        PostgresPoolMetrics,
        ContinuousClock
    >

    private let pool: Pool
    private let configuration: Configuration
    private let logger: Logger
    private let metrics: PostgresPoolMetrics

    /// Live pool statistics — open connections, queue depth, keep-alive
    /// outcomes. Also emitted through `swift-metrics`.
    public var statistics: PostgresPoolStatistics { metrics.statistics }

    public init(
        configuration: Configuration,
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        logger: Logger = Logger(label: "swizzle.postgres"),
        metrics: PostgresPoolMetrics? = nil
    ) {
        self.configuration = configuration
        self.logger = logger
        let metrics = metrics ?? PostgresPoolMetrics(logger: logger)
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
            requestType: ConnectionRequest<PostgresConnection>.self,
            keepAliveBehavior: PostgresKeepAliveBehavior(
                frequency: configuration.keepAliveFrequency
            ),
            observabilityDelegate: metrics,
            clock: ContinuousClock()
        ) { poolID, _ in
            // The pool identifies connections by the id it assigned, and looks
            // them up by `connection.id` later. Handing it back anything else
            // trips an invariant check inside the pool — a crash, not a mismatch.
            let connection = try await PostgresConnection.connect(
                configuration: connectionConfiguration,
                id: poolID,
                on: group.next()
            )
            // One statement at a time. Pipelining would allow more, and is a
            // separate piece of work rather than something to assume here.
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
    /// The connection is returned afterwards — reset first, unless that was
    /// disabled. A connection that failed at the *protocol* level is closed
    /// instead of reused: its position in the message stream is unknown, and the
    /// damage would land on the next borrower rather than on the caller who
    /// caused it.
    public func withConnection<Result: Sendable>(
        _ body: (PostgresConnection) async throws -> Result
    ) async throws -> Result {
        let lease = try await leaseWithTimeout()
        let connection = lease.connection

        do {
            let result = try await body(connection)
            await releaseCleanly(connection, lease: lease)
            return result
        } catch {
            // A *server* error leaves the connection perfectly usable — Postgres
            // has already resynchronised at `ReadyForQuery`. Only the failures
            // that say nothing about where we are in the stream are fatal to the
            // connection.
            if let failure = error as? PostgresConnectionError, !failure.sqlKind.isStatementLevel {
                connection.closeImmediately()
            } else {
                await releaseCleanly(connection, lease: lease)
            }
            throw error
        }
    }

    /// Borrows a connection whose lifetime outlives this call.
    ///
    /// For streaming: the rows are still arriving on the connection after the
    /// call that started them returns, so it cannot be given back at the end of a
    /// closure. The caller gets a `release` it must invoke — and because it is
    /// `async`, the connection is reset before it goes back, exactly as the
    /// closure-scoped path does.
    ///
    /// Prefer ``withConnection(_:)``. This exists for the one shape that cannot
    /// use it.
    /// - Returns: the connection, and a `release` taking `discard`.
    ///
    ///   Pass `discard: true` when the borrower knows the connection is not
    ///   reusable — an abandoned row stream, say, which the driver kills rather
    ///   than draining. Checking `isActive` at release time instead is **racy**:
    ///   the close is in flight, so a connection about to die still reports
    ///   itself alive and goes back to the pool for the next caller to trip over.
    ///   Telling the pool beats asking the socket.
    public func leaseConnection() async throws
        -> (connection: PostgresConnection, release: @Sendable (Bool) async -> Void)
    {
        let lease = try await leaseWithTimeout()
        let connection = lease.connection
        let release: @Sendable (Bool) async -> Void = { [weak self] discard in
            guard let self else {
                lease.release()
                return
            }
            await self.releaseCleanly(connection, lease: lease, discard: discard)
        }
        return (connection, release)
    }

    /// Convenience for a single statement.
    @discardableResult
    public func query(_ sql: String, _ bindings: [SQLValue] = []) async throws
        -> PostgresQueryResult
    {
        try await withConnection { try await $0.query(sql, bindings) }
    }

    /// Convenience for a statement whose row count is the answer.
    @discardableResult
    public func execute(_ sql: String, _ bindings: [SQLValue] = []) async throws -> Int {
        try await withConnection { try await $0.execute(sql, bindings) }
    }

    /// Races the lease against the acquisition timeout.
    ///
    /// Cancelling the group cancels the outstanding lease request too, so a
    /// timed-out waiter does not leave a connection checked out to nobody.
    private func leaseWithTimeout() async throws -> ConnectionLease<PostgresConnection> {
        guard let timeout = configuration.connectionAcquisitionTimeout else {
            return try await pool.leaseConnection()
        }

        return try await withThrowingTaskGroup(
            of: ConnectionLease<PostgresConnection>?.self
        ) { group in
            group.addTask { try await self.pool.leaseConnection() }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }

            defer { group.cancelAll() }
            while let outcome = try await group.next() {
                if let lease = outcome { return lease }
                throw PostgresPoolError.connectionAcquisitionTimeout(timeout)
            }
            throw PostgresPoolError.connectionAcquisitionTimeout(timeout)
        }
    }

    private func releaseCleanly(
        _ connection: PostgresConnection,
        lease: ConnectionLease<PostgresConnection>,
        discard: Bool = false
    ) async {
        // **A connection known to be finished is never handed back**, whatever the
        // reset setting says. Abandoning a row stream kills the connection by
        // design, and with `resetOnRelease` off — which is how the migrator runs —
        // it went back to the pool looking healthy, so the next borrower failed
        // with "a closed connection", one caller removed from the cause.
        //
        // The close is **awaited** rather than fired off. An `isActive` check here
        // was the first attempt and still failed about one run in eight: the close
        // is in flight, so a connection about to die reports itself alive.
        if discard || !connection.isActive {
            connection.closeImmediately()
            await connection.waitForClose()
            lease.release()
            return
        }

        if configuration.resetOnRelease {
            do {
                try await connection.resetSession()
            } catch {
                // A connection that cannot be reset is not safe to hand on: the
                // whole point of the reset is that we do not know what the last
                // borrower left behind.
                logger.debug("discarding connection that failed to reset: \(error)")
                connection.closeImmediately()
                return
            }
        }
        lease.release()
    }
}

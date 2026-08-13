import Logging
import Metrics
import NIOConcurrencyHelpers
import SwizzleConnectionPool

/// A point-in-time view of pool activity.
///
/// Useful on its own, not only as a metrics feed: a sustained `requestQueueDepth`
/// with `openConnections` at the ceiling is the signature of connection
/// starvation, and it is far easier to assert on in a test than to infer from a
/// dashboard.
public struct PostgresPoolStatistics: Sendable, Equatable {
    /// Connections currently established.
    public var openConnections = 0
    /// Connection attempts in flight.
    public var connecting = 0
    public var succeededConnects = 0
    public var failedConnects = 0
    public var closedConnections = 0
    public var keepAlivesTriggered = 0
    public var keepAlivesSucceeded = 0
    public var keepAlivesFailed = 0
    /// Callers waiting for a connection. Sustained non-zero means the ceiling is
    /// too low, or connections are being held too long.
    public var requestQueueDepth = 0
    /// Connections currently leased. One stream each — the driver runs a single
    /// statement per connection, so leased and in-use are the same number.
    public var streamsInUse = 0
}

/// Pool observability: live statistics, `swift-metrics` instruments, and optional
/// logging.
///
/// The Postgres twin of `MySQLPoolMetrics`, deliberately down to the metric
/// names, because an operator running both engines should not have to learn two
/// vocabularies to answer the same question. Only the namespace differs.
///
/// `PostgresClient` fixes its delegate to this concrete type rather than being
/// generic over `ConnectionPoolObservabilityDelegate` — that keeps the client
/// spellable as a plain type while still letting callers get metrics out, through
/// the sinks here rather than a type parameter.
public struct PostgresPoolMetrics: ConnectionPoolObservabilityDelegate, Sendable {
    public typealias ConnectionID = Int

    /// Prefixes every metric label, so several pools in one process stay
    /// distinguishable.
    public let namespace: String
    private let logger: Logger?
    private let state: NIOLockedValueBox<PostgresPoolStatistics>
    private let emitMetrics: Bool

    public init(
        namespace: String = "swizzle.postgres.pool",
        logger: Logger? = nil,
        emitMetrics: Bool = true
    ) {
        self.namespace = namespace
        self.logger = logger
        self.emitMetrics = emitMetrics
        self.state = NIOLockedValueBox(PostgresPoolStatistics())
    }

    /// Current statistics.
    public var statistics: PostgresPoolStatistics {
        state.withLockedValue { $0 }
    }

    // MARK: - Delegate

    public func startedConnecting(id: Int) {
        mutate { $0.connecting += 1 }
        count("connections.attempted")
        gaugeConnecting()
    }

    public func connectFailed(id: Int, error: any Error) {
        mutate {
            $0.connecting = Swift.max(0, $0.connecting - 1)
            $0.failedConnects += 1
        }
        count("connections.failed")
        gaugeConnecting()
        logger?.warning("postgres pool connection failed", metadata: ["error": "\(error)"])
    }

    public func connectSucceeded(id: Int, streamCapacity: UInt16) {
        mutate {
            $0.connecting = Swift.max(0, $0.connecting - 1)
            $0.succeededConnects += 1
            $0.openConnections += 1
        }
        count("connections.succeeded")
        gaugeConnecting()
        gaugeOpen()
    }

    public func connectionUtilizationChanged(
        id: Int, streamsUsed: UInt16, streamCapacity: UInt16
    ) {
        // Reported per connection, so the total is recomputed rather than
        // accumulated — accumulating would drift as connections come and go.
        mutate { $0.streamsInUse = Int(streamsUsed) }
        record("streams.in_use", Int(streamsUsed))
    }

    public func keepAliveTriggered(id: Int) {
        mutate { $0.keepAlivesTriggered += 1 }
        count("keepalive.triggered")
    }

    public func keepAliveSucceeded(id: Int) {
        mutate { $0.keepAlivesSucceeded += 1 }
        count("keepalive.succeeded")
    }

    public func keepAliveFailed(id: Int, error: any Error) {
        mutate { $0.keepAlivesFailed += 1 }
        count("keepalive.failed")
        logger?.warning("postgres pool keep-alive failed", metadata: ["error": "\(error)"])
    }

    public func connectionClosing(id: Int) {
        count("connections.closing")
    }

    public func connectionClosed(id: Int, error: (any Error)?) {
        mutate {
            $0.openConnections = Swift.max(0, $0.openConnections - 1)
            $0.closedConnections += 1
        }
        count("connections.closed")
        gaugeOpen()
        if let error {
            logger?.debug("postgres pool connection closed", metadata: ["error": "\(error)"])
        }
    }

    public func requestQueueDepthChanged(_ newDepth: Int) {
        mutate { $0.requestQueueDepth = newDepth }
        record("request_queue.depth", newDepth)
    }

    // MARK: - Sinks

    private func mutate(_ body: (inout PostgresPoolStatistics) -> Void) {
        state.withLockedValue { body(&$0) }
    }

    private func count(_ name: String) {
        guard emitMetrics else { return }
        Counter(label: "\(namespace).\(name)").increment()
    }

    private func record(_ name: String, _ value: Int) {
        guard emitMetrics else { return }
        Gauge(label: "\(namespace).\(name)").record(Double(value))
    }

    private func gaugeOpen() {
        record("connections.open", statistics.openConnections)
    }

    private func gaugeConnecting() {
        record("connections.connecting", statistics.connecting)
    }
}

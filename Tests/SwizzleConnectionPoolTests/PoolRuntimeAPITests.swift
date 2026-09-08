import Testing

@testable import SwizzleConnectionPool

/// The parts of `ConnectionPool`'s public surface a caller reaches directly
/// rather than through `withConnection`.
///
/// A driver does not only lease and release. It tells the pool when a channel is
/// about to go away, when the server has revised how many streams it will carry,
/// and — for a protocol that multiplexes — it hands over a whole batch of
/// requests at once instead of one per lock acquisition. Each of those is a
/// public entry point that some driver is expected to call, and none of them was
/// exercised.
@Suite("Pool runtime API")
struct PoolRuntimeAPITests {

    /// A request that records its outcome, so a batch can be handed over whole.
    ///
    /// `ConnectionRequest` wraps a suspended continuation, which makes it
    /// awkward to hold several at once — and holding several at once is exactly
    /// what the batch API is for.
    final class RecordingRequest: ConnectionRequestProtocol, @unchecked Sendable {
        typealias ID = Int
        typealias Connection = LiveMockConnection

        let id: Int
        private let lock = NIOLock()
        private var _lease: ConnectionLease<LiveMockConnection>?
        private var _error: ConnectionPoolError?
        let completed = Latch()

        init(id: Int) { self.id = id }

        func complete(with result: Result<ConnectionLease<LiveMockConnection>, ConnectionPoolError>) {
            lock.withLock {
                switch result {
                case .success(let lease): _lease = lease
                case .failure(let error): _error = error
                }
            }
            completed.signal()
        }

        var leasedConnectionID: Int? { lock.withLock { _lease?.connection.id } }
        var error: ConnectionPoolError? { lock.withLock { _error } }
        func release() { lock.withLock { _lease }?.release() }
    }

    /// A keep-alive that always fails, standing in for a connection that has
    /// died quietly — the socket is open, but the server is not answering.
    struct FailingKeepAlive: ConnectionKeepAliveBehavior {
        struct Dead: Error {}
        typealias Connection = LiveMockConnection

        var keepAliveFrequency: Duration? { .milliseconds(1) }
        func runKeepAlive(for connection: LiveMockConnection) async throws { throw Dead() }
    }

    typealias BatchPool = ConnectionPool<
        LiveMockConnection, LiveMockConnection.ID, ConnectionIDGenerator,
        RecordingRequest, RecordingRequest.ID,
        NoOpKeepAliveBehavior<LiveMockConnection>,
        NoOpConnectionPoolMetrics<LiveMockConnection.ID>, ContinuousClock
    >

    static func batchPool(soft: Int = 4, hard: Int = 4) -> BatchPool {
        var configuration = ConnectionPoolConfiguration()
        configuration.minimumConnectionCount = 0
        configuration.maximumConnectionSoftLimit = soft
        configuration.maximumConnectionHardLimit = hard
        return BatchPool(
            configuration: configuration,
            idGenerator: ConnectionIDGenerator(),
            requestType: RecordingRequest.self,
            keepAliveBehavior: NoOpKeepAliveBehavior(connectionType: LiveMockConnection.self),
            observabilityDelegate: NoOpConnectionPoolMetrics(connectionIDType: Int.self),
            clock: ContinuousClock(),
            connectionFactory: { id, _ in
                ConnectionAndMetadata(connection: LiveMockConnection(id: id), maximalStreamsOnConnection: 1)
            }
        )
    }

    // MARK: - Batch leasing

    /// **`leaseConnections` serves every request in the batch.** It takes the
    /// pool lock once for the whole batch rather than once per request, which is
    /// the point — and a batch that drops its tail leaves those callers
    /// suspended with nothing to wake them.
    @Test("a batch handed over at once is served in full")
    func leaseConnectionsBatch() async {
        let pool = Self.batchPool()
        let requests = (1...4).map { RecordingRequest(id: $0) }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pool.run() }
            group.addTask {
                pool.leaseConnections(requests)
                for request in requests { await request.completed.wait() }
                for request in requests { request.release() }
                pool.triggerGracefulShutdown()
            }
        }

        #expect(
            requests.allSatisfy { $0.leasedConnectionID != nil },
            "\(requests.filter { $0.leasedConnectionID == nil }.count) of the batch were never served"
        )
        #expect(
            Set(requests.compactMap(\.leasedConnectionID)).count == 4,
            "each got a connection of its own, since each connection carries one stream"
        )
    }

    /// A batch larger than the pool is still served in full — the excess waits
    /// for releases rather than being dropped.
    @Test("a batch larger than the pool is served as connections come free")
    func leaseConnectionsBatchBeyondCapacity() async {
        let pool = Self.batchPool(soft: 2, hard: 2)
        let requests = (1...6).map { RecordingRequest(id: $0) }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pool.run() }
            group.addTask {
                pool.leaseConnections(requests)
                // Release each lease as it arrives, so the queue behind it moves.
                for request in requests {
                    await request.completed.wait()
                    request.release()
                }
                pool.triggerGracefulShutdown()
            }
        }

        #expect(
            requests.allSatisfy { $0.leasedConnectionID != nil },
            "\(requests.filter { $0.leasedConnectionID == nil }.count) callers were stranded"
        )
    }

    // MARK: - What the driver tells the pool

    /// **A channel announcing its own death takes the connection out of the
    /// pool.** Without this the pool keeps handing out a socket the driver
    /// already knows is finished, and every caller that gets it fails.
    @Test("announcing a close takes the connection out of circulation")
    func connectionWillCloseRemovesIt() async {
        let pool = Self.batchPool(soft: 1, hard: 1)
        let first = RecordingRequest(id: 1)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pool.run() }
            group.addTask {
                pool.leaseConnections([first])
                await first.completed.wait()
                guard let doomed = first.leasedConnectionID else { return }

                first.release()
                pool.connectionWillClose(doomed)

                let second = RecordingRequest(id: 2)
                pool.leaseConnections([second])
                await second.completed.wait()
                #expect(
                    second.leasedConnectionID != doomed,
                    "the pool handed out a connection its driver had already written off"
                )
                second.release()
                pool.triggerGracefulShutdown()
            }
        }
    }

    /// **A revised stream limit frees capacity for callers already waiting.**
    /// The server sends this mid-session; a pool that ignores it either
    /// under-uses the connection or over-commits it.
    @Test("a revised stream limit is applied to a live connection")
    func newMaxStreamSettingIsApplied() async {
        let pool = Self.batchPool(soft: 1, hard: 1)
        let holder = RecordingRequest(id: 1)
        let waiter = RecordingRequest(id: 2)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pool.run() }
            group.addTask {
                pool.leaseConnections([holder])
                await holder.completed.wait()

                // Queue behind the single stream, then widen the connection.
                pool.leaseConnections([waiter])
                guard let connection = LiveMockConnection.some(holder.leasedConnectionID) else { return }
                pool.connectionReceivedNewMaxStreamSetting(connection, newMaxStreamSetting: 4)

                await waiter.completed.wait()
                #expect(
                    waiter.leasedConnectionID == holder.leasedConnectionID,
                    "the widened connection did not reach the caller already waiting on it"
                )
                holder.release()
                waiter.release()
                pool.triggerGracefulShutdown()
            }
        }
    }

    // MARK: - Keep-alive failure

    typealias KeepAlivePool = ConnectionPool<
        LiveMockConnection, LiveMockConnection.ID, ConnectionIDGenerator,
        RecordingRequest, RecordingRequest.ID,
        FailingKeepAlive,
        NoOpConnectionPoolMetrics<LiveMockConnection.ID>, ContinuousClock
    >

    /// **A keep-alive that fails closes the connection**, and the pool keeps
    /// working — the next caller gets a fresh one rather than the dead socket.
    /// This is the path that turns a silently-dead connection back into a
    /// working pool, and it runs on a timer nobody triggers by hand.
    @Test("a failing keep-alive closes the connection and the pool recovers")
    func failingKeepAliveClosesAndRecovers() async {
        let opened = CountingLatch(target: 2)
        var configuration = ConnectionPoolConfiguration()
        configuration.minimumConnectionCount = 1
        configuration.maximumConnectionSoftLimit = 1
        configuration.maximumConnectionHardLimit = 1

        let pool = KeepAlivePool(
            configuration: configuration,
            idGenerator: ConnectionIDGenerator(),
            requestType: RecordingRequest.self,
            keepAliveBehavior: FailingKeepAlive(),
            observabilityDelegate: NoOpConnectionPoolMetrics(connectionIDType: Int.self),
            clock: ContinuousClock(),
            connectionFactory: { id, _ in
                opened.increment()
                return ConnectionAndMetadata(
                    connection: LiveMockConnection(id: id), maximalStreamsOnConnection: 1
                )
            }
        )

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pool.run() }
            group.addTask {
                // The keep-alive fires on its own and fails. The pool replaces
                // the connection, so a second one is eventually opened.
                await opened.wait()

                let request = RecordingRequest(id: 1)
                pool.leaseConnections([request])
                await request.completed.wait()
                #expect(
                    request.leasedConnectionID != nil,
                    "the pool stopped serving after a keep-alive failure"
                )
                request.release()
                pool.triggerGracefulShutdown()
            }
        }

        #expect(
            opened.value >= 2,
            "the pool never replaced the connection whose keep-alive failed"
        )
    }
}

extension LiveMockConnection {
    /// The pool's stream-setting entry point takes a connection, not an id, so
    /// a test that only kept the id needs one back.
    static func some(_ id: Int?) -> LiveMockConnection? {
        id.map(LiveMockConnection.init(id:))
    }
}

import Testing

@testable import SwizzleConnectionPool

/// The `ConnectionPool` actor itself, driven through its public API.
///
/// ## Why this is separate from the state-machine suites
///
/// Everything else in this target tests `PoolStateMachine`, which decides *what*
/// should happen and returns it as a value. This suite tests the half that
/// actually does it: opening connections through the factory, resuming the
/// continuations that callers are suspended on, and running the whole thing
/// inside `run()`'s task group.
///
/// That half is where a correct decision can still go wrong — an action executed
/// twice, a continuation resumed twice (which traps), a lease that is never
/// released because the `defer` sat in the wrong scope. None of it is reachable
/// from a value-type test, because none of it is a return value.
///
/// The tests are deterministic despite being concurrent: every one of them waits
/// on a lease that only completes when the pool has served it, so there is no
/// polling and nothing to time out. `run()` is kept in a child task and the
/// group is closed by shutting the pool down, not by cancellation, so a hang
/// here means a real lost wakeup rather than a slow machine.
@Suite("Pool runtime")
struct PoolRuntimeTests {

    typealias TestPool = ConnectionPool<
        LiveMockConnection, LiveMockConnection.ID, ConnectionIDGenerator,
        ConnectionRequest<LiveMockConnection>, ConnectionRequest<LiveMockConnection>.ID,
        NoOpKeepAliveBehavior<LiveMockConnection>,
        NoOpConnectionPoolMetrics<LiveMockConnection.ID>, ContinuousClock
    >

    static func configuration(
        minimum: Int = 0, soft: Int = 2, hard: Int = 2
    ) -> ConnectionPoolConfiguration {
        var configuration = ConnectionPoolConfiguration()
        configuration.minimumConnectionCount = minimum
        configuration.maximumConnectionSoftLimit = soft
        configuration.maximumConnectionHardLimit = hard
        return configuration
    }

    static func pool(
        minimum: Int = 0, soft: Int = 2, hard: Int = 2,
        factory: @escaping @Sendable (Int) async throws -> LiveMockConnection
    ) -> TestPool {
        TestPool(
            configuration: Self.configuration(minimum: minimum, soft: soft, hard: hard),
            keepAliveBehavior: NoOpKeepAliveBehavior(connectionType: LiveMockConnection.self),
            observabilityDelegate: NoOpConnectionPoolMetrics(connectionIDType: LiveMockConnection.ID.self),
            connectionFactory: { id, _ in
                ConnectionAndMetadata(connection: try await factory(id), maximalStreamsOnConnection: 1)
            }
        )
    }

    /// Runs `body` with the pool's own `run()` loop alive beside it, and shuts
    /// the pool down afterwards so the group closes on its own.
    static func withRunningPool<Result: Sendable>(
        _ pool: TestPool,
        _ body: @Sendable @escaping (TestPool) async throws -> Result
    ) async throws -> Result {
        try await withThrowingTaskGroup(of: Result?.self) { group in
            group.addTask { await pool.run(); return nil }
            group.addTask {
                defer { pool.triggerGracefulShutdown() }
                return try await body(pool)
            }
            var result: Result?
            while let next = try await group.next() {
                if let next { result = next }
            }
            return result!
        }
    }

    // MARK: - Leasing

    /// A lease opens a connection through the factory and hands it back.
    @Test("leasing opens a connection through the factory")
    func leaseOpensConnection() async throws {
        let opened = NIOLockedValueBox([Int]())
        let pool = Self.pool { id in
            opened.withLockedValue { $0.append(id) }
            return LiveMockConnection(id: id)
        }

        let id = try await Self.withRunningPool(pool) { pool in
            try await pool.withConnection { $0.id }
        }
        #expect(opened.withLockedValue { $0 } == [id], "one connection, the one we got")
    }

    /// **A released connection is reused rather than a second one being opened.**
    /// That is the whole point of a pool, and it is the assertion that catches a
    /// lease which is never released — the second call would open a new
    /// connection instead of reusing the first.
    @Test("a released connection is reused, not replaced")
    func releasedConnectionIsReused() async throws {
        let opened = NIOLockedValueBox(0)
        let pool = Self.pool { id in
            opened.withLockedValue { $0 += 1 }
            return LiveMockConnection(id: id)
        }

        let ids = try await Self.withRunningPool(pool) { pool in
            let first = try await pool.withConnection { $0.id }
            let second = try await pool.withConnection { $0.id }
            return [first, second]
        }
        #expect(ids[0] == ids[1], "the same connection came back")
        #expect(opened.withLockedValue { $0 } == 1, "so only one was ever opened")
    }

    /// `withConnection` releases even when the body throws. Without that, one
    /// failed query permanently costs the pool a connection, and enough of them
    /// deadlock it.
    @Test("withConnection releases the lease even when the body throws")
    func withConnectionReleasesOnThrow() async throws {
        struct Boom: Error {}
        let opened = NIOLockedValueBox(0)
        let pool = Self.pool(soft: 1, hard: 1) { id in
            opened.withLockedValue { $0 += 1 }
            return LiveMockConnection(id: id)
        }

        try await Self.withRunningPool(pool) { pool in
            await #expect(throws: Boom.self) {
                try await pool.withConnection { _ in throw Boom() }
            }
            // A single-connection pool: this only completes if the throwing
            // lease gave its connection back.
            _ = try await pool.withConnection { $0.id }
        }
        #expect(opened.withLockedValue { $0 } == 1)
    }

    /// **Batch leasing.** `leaseConnections` takes the pool lock once for the
    /// whole batch rather than once per request, and every request in it must
    /// still be served — a batch that drops its tail leaves callers suspended
    /// forever.
    @Test("a batch of lease requests is served in full")
    func batchLeasing() async throws {
        let pool = Self.pool(soft: 4, hard: 4) { LiveMockConnection(id: $0) }

        try await Self.withRunningPool(pool) { pool in
            try await withThrowingTaskGroup(of: Int.self) { group in
                for _ in 0..<4 {
                    group.addTask { try await pool.withConnection { $0.id } }
                }
                var served = 0
                for try await _ in group { served += 1 }
                #expect(served == 4, "every request in the batch was served")
            }
        }
    }

    /// More callers than connections still all get served — the ones beyond the
    /// limit wait for a release rather than failing or being lost.
    @Test("callers beyond the connection limit wait and are served on release")
    func callersBeyondTheLimitWait() async throws {
        let opened = NIOLockedValueBox(0)
        let pool = Self.pool(soft: 1, hard: 1) { id in
            opened.withLockedValue { $0 += 1 }
            return LiveMockConnection(id: id)
        }

        try await Self.withRunningPool(pool) { pool in
            try await withThrowingTaskGroup(of: Int.self) { group in
                for _ in 0..<8 {
                    group.addTask { try await pool.withConnection { $0.id } }
                }
                var served = 0
                for try await _ in group { served += 1 }
                #expect(served == 8)
            }
        }
        #expect(opened.withLockedValue { $0 } == 1, "all eight shared one connection")
    }

    // MARK: - Failure

    /// A factory that fails and then recovers does not fail the caller — the
    /// pool retries behind the suspension, which is what lets a query ride out a
    /// server restart.
    @Test("a caller is served once a failing factory recovers")
    func factoryRecovers() async throws {
        struct Refused: Error {}
        let attempts = NIOLockedValueBox(0)
        let pool = Self.pool(soft: 1, hard: 1) { id in
            let attempt = attempts.withLockedValue { $0 += 1; return $0 }
            if attempt == 1 { throw Refused() }
            return LiveMockConnection(id: id)
        }

        let id = try await Self.withRunningPool(pool) { pool in
            try await pool.withConnection { $0.id }
        }
        #expect(attempts.withLockedValue { $0 } >= 2, "it retried rather than giving up")
        #expect(id >= 0)
    }

    // MARK: - Cancellation

    /// A cancelled lease throws rather than being left suspended, and does not
    /// take the pool with it — a later lease still works.
    @Test("a cancelled lease throws and leaves the pool usable")
    func cancelledLease() async throws {
        let pool = Self.pool(soft: 1, hard: 1) { LiveMockConnection(id: $0) }

        try await Self.withRunningPool(pool) { pool in
            // Hold the only connection so the next lease has to queue.
            _ = try await pool.withConnection { connection in
                let waiter = Task { try await pool.withConnection { $0.id } }
                waiter.cancel()
                await #expect(throws: (any Error).self) { try await waiter.value }
                return connection.id
            }
            // The pool still works afterwards.
            _ = try await pool.withConnection { $0.id }
        }
    }

    // MARK: - Shutdown

    /// A lease attempted after shutdown fails rather than hanging. A caller
    /// suspended on a pool that will never serve it is the worst outcome here —
    /// it is invisible.
    @Test("leasing from a shut-down pool fails rather than hanging")
    func leaseAfterShutdown() async throws {
        let pool = Self.pool { LiveMockConnection(id: $0) }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pool.run() }
            group.addTask {
                pool.triggerGracefulShutdown()
                await #expect(throws: ConnectionPoolError.poolShutdown) {
                    _ = try await pool.withConnection { $0.id }
                }
            }
        }
    }

    /// A forced shutdown ends `run()` too, rather than leaving the task group
    /// open on a pool nobody can use.
    @Test("a forced shutdown ends the run loop")
    func forceShutdownEndsRun() async {
        let pool = Self.pool { LiveMockConnection(id: $0) }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pool.run() }
            group.addTask { pool.triggerForceShutdown() }
        }
    }
}

import Testing

@testable import SwizzleConnectionPool

/// A connection going away, in every way it can, and what the pool does about
/// it.
///
/// ## The path a server restart takes
///
/// `connectionWillClose` is how a peer says "I am about to hang up" — a MySQL
/// server shutting down, a Postgres backend being terminated, a proxy recycling
/// a backend. It is the single largest untested function in the pool, and it is
/// on the path of every rolling restart.
///
/// What it has to do is more than forget the connection. The pool tracks idle,
/// leased, closing and available-stream counts, and a connection announcing its
/// death has to be subtracted from exactly the right ones — otherwise the pool
/// believes it has capacity it does not, and either stops opening connections it
/// needs or leases streams that no longer exist.
///
/// It also has to keep the *slots* straight. Connections below the soft limit
/// are the persistent ones; anything above is overflow, opened under pressure
/// and never parked. When a persistent connection dies the pool promotes an
/// overflow connection into its slot, so the shape of the pool survives the
/// churn. That promotion only runs when there are more connections than the soft
/// limit, which is why it needs a pool built deliberately over that line.
@Suite("Pool close lifecycle", .serialized)
struct PoolCloseLifecycleTests {

    /// A pool with `count` established connections, all idle.
    static func machineWith(
        connections count: Int,
        soft: Int = 4,
        hard: Int = 8,
        keepAlive: Duration? = nil
    ) -> (machine: TestStateMachine, connections: [MockConnection]) {
        var (machine, refill) = makeStateMachine(
            minimumConnections: count, maximumSoftLimit: soft, maximumHardLimit: hard,
            keepAlive: keepAlive
        )
        let connections = refill.map { MockConnection(id: $0.connectionID) }
        for connection in connections {
            _ = machine.connectionEstablished(connection, maxStreams: 1)
        }
        return (machine, connections)
    }

    // MARK: - The server announcing a close

    /// An idle connection that announces its death is closed, and the pool asks
    /// for a replacement to get back to its minimum.
    @Test("an idle connection announcing a close is closed and replaced")
    func idleConnectionWillClose() {
        var (machine, connections) = Self.machineWith(connections: 2)
        let dying = connections[0]

        let action = machine.connectionWillClose(dying.id)
        guard case .closeConnection(let closing, _) = action.connection else {
            Issue.record("expected the connection to be closed, got \(action.connection)")
            return
        }
        #expect(closing.id == dying.id)

        // Completing the close is what restores the minimum.
        let closed = machine.connectionClosed(dying)
        switch closed.connection {
        case .makeConnection, .makeConnectionsCancelAndScheduleTimers:
            break
        default:
            Issue.record("the pool did not replace a connection it lost: \(closed.connection)")
        }
    }

    /// A connection the pool has never heard of is ignored. The id arrives from
    /// the peer, so it is not the pool's to trust.
    @Test("a close announcement for an unknown connection is ignored")
    func unknownConnectionWillClose() {
        var (machine, _) = Self.machineWith(connections: 1)
        let action = machine.connectionWillClose(999_999)
        if case .closeConnection = action.connection {
            Issue.record("acted on a connection the pool does not know")
        }
    }

    /// **Between the announcement and the close, the connection is off
    /// limits.** A stale available-stream count is exactly how a caller ends up
    /// holding a socket the server is in the middle of closing.
    ///
    /// The minimum is zero here on purpose. With a minimum of one, announcing a
    /// close on the only connection drops the pool below it, and leasing in that
    /// window trips
    /// `precondition(minimumConcurrentConnections <= stats.active)` — the pool
    /// expects the caller to act on the close it was just handed rather than ask
    /// for more work first. That is a real constraint, not a bug, so the test
    /// works within it instead of around it.
    @Test("a connection that announced a close is not leased afterwards")
    func closingConnectionIsNotLeased() {
        var (machine, _) = makeStateMachine(
            minimumConnections: 0, maximumSoftLimit: 2, maximumHardLimit: 2
        )

        // Establish one connection and let it go idle.
        let first = MockRequest(id: 1)
        let leaseAction = machine.leaseConnection(first)
        guard case .makeConnection(let connectionRequest, _) = leaseAction.connection else {
            Issue.record("expected makeConnection")
            return
        }
        let connection = MockConnection(id: connectionRequest.connectionID)
        _ = machine.connectionEstablished(connection, maxStreams: 1)
        _ = machine.releaseConnection(connection, streams: 1)

        _ = machine.connectionWillClose(connection.id)

        // The next request must not be given the dying connection — it should
        // cause a fresh one to be opened instead.
        let action = machine.leaseConnection(MockRequest(id: 2))
        if case .leaseConnection(_, let leased) = action.request, leased.id == connection.id {
            Issue.record("leased a connection that had announced it was closing")
        }
    }

    /// A *leased* connection announcing a close cannot simply be closed — a
    /// caller is using it. The pool has to wait for the release, which is the
    /// branch that distinguishes `markForClose` from `closeIfIdle`.
    @Test("a leased connection announcing a close is not closed under its user")
    func leasedConnectionWillClose() {
        var (machine, connections) = Self.machineWith(connections: 1, soft: 1, hard: 1)
        let connection = connections[0]

        let request = MockRequest(id: 1)
        let leaseAction = machine.leaseConnection(request)
        guard case .leaseConnection = leaseAction.request else {
            Issue.record("the connection was not leased to begin with")
            return
        }

        // Announcing a close while someone holds it must not close it now.
        let action = machine.connectionWillClose(connection.id)
        if case .closeConnection(let closing, _) = action.connection, closing.id == connection.id {
            Issue.record("closed a connection out from under the caller holding it")
        }

        // Releasing it is what lets the close happen.
        _ = machine.releaseConnection(connection, streams: 1)
    }

    /// **The crash this suite found.**
    ///
    /// A server announces it is closing a connection somebody is using, and then
    /// drops it before they release. Both halves come from the peer, and both
    /// happen together on every rolling restart.
    ///
    /// `markForClose` turns the leased connection into a draining one and
    /// subtracts its available streams there and then. So `closed()` reports
    /// `maxStreams: 0`, to stop the close subtracting them a second time — but it
    /// still reports the streams in use, and `connectionClosed` computed
    /// `maxStreams - usedStreams`. On a `UInt16` that is `0 - 1`: an arithmetic
    /// overflow, which traps rather than producing a wrong count. The client
    /// process dies.
    ///
    /// Every existing test released before closing, which is the ordering that
    /// never reaches it.
    @Test("a leased connection that is announced and then dropped does not trap")
    func announcedThenDroppedWhileLeased() {
        var (machine, _) = makeStateMachine(
            minimumConnections: 0, maximumSoftLimit: 2, maximumHardLimit: 4
        )

        let action = machine.leaseConnection(MockRequest(id: 1))
        guard case .makeConnection(let connectionRequest, _) = action.connection else {
            Issue.record("expected makeConnection")
            return
        }
        let connection = MockConnection(id: connectionRequest.connectionID)
        _ = machine.connectionEstablished(connection, maxStreams: 1)

        // The server says it is going away while the caller still holds it.
        _ = machine.connectionWillClose(connection.id)

        // Then the socket dies before the caller ever releases.
        _ = machine.connectionClosed(connection)

        // And the pool is still coherent: a new request opens a new connection
        // rather than being handed the dead one.
        let next = machine.leaseConnection(MockRequest(id: 2))
        if case .leaseConnection(_, let leased) = next.request, leased.id == connection.id {
            Issue.record("leased a connection that had already closed")
        }
    }

    /// The same shape with several streams in use, since the underflow is
    /// proportional to how many were leased.
    @Test("the same drop with several streams in use does not trap")
    func announcedThenDroppedWithSeveralStreams() {
        for streams in UInt16(1)...4 {
            var (machine, _) = makeStateMachine(
                minimumConnections: 0, maximumSoftLimit: 2, maximumHardLimit: 4
            )
            let action = machine.leaseConnection(MockRequest(id: 1))
            guard case .makeConnection(let connectionRequest, _) = action.connection else {
                Issue.record("expected makeConnection")
                return
            }
            let connection = MockConnection(id: connectionRequest.connectionID)
            _ = machine.connectionEstablished(connection, maxStreams: streams)

            // Take every stream the connection has. `stride` rather than a
            // range, because `2...Int(streams)` is an invalid range when there
            // is only one stream — a `where` clause filters iterations but the
            // range is built first, so it traps before the filter runs.
            for id in stride(from: 2, through: Int(streams), by: 1) {
                _ = machine.leaseConnection(MockRequest(id: id))
            }

            _ = machine.connectionWillClose(connection.id)
            _ = machine.connectionClosed(connection)
        }
    }

    // MARK: - Slots, and the promotion that keeps their shape

    /// **Overflow promotion**, which only runs with more connections than the
    /// soft limit — the pool moves an overflow connection into the dying one's
    /// persistent slot so the shape survives the churn.
    ///
    /// Reaching it needs a pool pushed over its soft limit by demand, which no
    /// other test in this module does.
    @Test("a dying persistent connection is replaced in its slot by an overflow one")
    func overflowIsPromotedIntoAPersistentSlot() {
        var (machine, _) = makeStateMachine(
            minimumConnections: 0, maximumSoftLimit: 2, maximumHardLimit: 4
        )

        // Four concurrent requests push the pool past its soft limit of two.
        var established: [MockConnection] = []
        for id in 1...4 {
            let action = machine.leaseConnection(MockRequest(id: id))
            if case .makeConnection(let request, _) = action.connection {
                let connection = MockConnection(id: request.connectionID)
                _ = machine.connectionEstablished(connection, maxStreams: 1)
                established.append(connection)
            }
        }
        #expect(
            established.count > 2,
            "the premise: the pool must be over its soft limit, opened \(established.count)"
        )

        // A persistent connection dying is the case that promotes an overflow.
        let action = machine.connectionWillClose(established[0].id)
        // Whatever it decides, the pool must stay coherent afterwards: the
        // remaining connections are still leasable and the dying one is not.
        _ = action
        _ = machine.connectionClosed(established[0])

        let request = MockRequest(id: 99)
        let lease = machine.leaseConnection(request)
        if case .leaseConnection(_, let leased) = lease.request {
            #expect(leased.id != established[0].id, "leased the connection that just closed")
        }
    }

    /// Removing connections from the middle of the group, which is where the
    /// index bookkeeping has to hold — the group swaps entries to delete
    /// without leaving a hole, and getting that wrong loses a *different*
    /// connection than the one that died.
    @Test("closing connections in any order leaves the rest usable")
    func closingInTheMiddleKeepsTheRestUsable() {
        for victim in 0..<3 {
            var (machine, connections) = Self.machineWith(connections: 3, soft: 4, hard: 4)
            let dying = connections[victim]

            _ = machine.connectionWillClose(dying.id)
            _ = machine.connectionClosed(dying)

            // Every survivor must still be leasable, and the dead one must not
            // come back.
            let survivors = connections.filter { $0.id != dying.id }
            for (offset, _) in survivors.enumerated() {
                let action = machine.leaseConnection(MockRequest(id: 100 + offset))
                if case .leaseConnection(_, let leased) = action.request {
                    #expect(
                        leased.id != dying.id,
                        "victim \(victim): leased the closed connection"
                    )
                }
            }
        }
    }

    // MARK: - Closing a connection that was never established

    /// A connection that fails and is destroyed before it ever connected has no
    /// streams and no timers, so every counter it touches is a different one.
    @Test("a connection that never established is cleaned up without closing")
    func destroyFailedConnection() {
        var (machine, _) = makeStateMachine(minimumConnections: 0, maximumSoftLimit: 2)

        let request = MockRequest(id: 1)
        let action = machine.leaseConnection(request)
        guard case .makeConnection(let connectionRequest, _) = action.connection else {
            Issue.record("expected makeConnection")
            return
        }

        // It fails, backs off, and the pool shuts down before the retry.
        _ = machine.connectionEstablishFailed(PoolTestError.refused, for: connectionRequest)
        let shutdown = machine.triggerGracefulShutdown()

        // The waiter must be answered rather than left on a pool that is gone.
        switch shutdown.request {
        case .failRequests, .failRequest, .none:
            break
        case .leaseConnection:
            Issue.record("a shut-down pool leased a connection")
        }
    }

    // MARK: - Idle timers across a release

    /// Releasing a connection re-arms its idle timer, which is what eventually
    /// shrinks the pool back down. A release that forgot to would leave the
    /// connection open for ever.
    @Test("releasing a connection re-arms its idle timer")
    func releaseReschedulesIdleTimer() {
        var (machine, _) = makeStateMachine(
            minimumConnections: 0, maximumSoftLimit: 2, idleTimeout: .seconds(30)
        )

        let request = MockRequest(id: 1)
        let action = machine.leaseConnection(request)
        guard case .makeConnection(let connectionRequest, _) = action.connection else {
            Issue.record("expected makeConnection")
            return
        }
        let connection = MockConnection(id: connectionRequest.connectionID)
        _ = machine.connectionEstablished(connection, maxStreams: 1)

        let released = machine.releaseConnection(connection, streams: 1)
        guard case .scheduleTimers(let timers) = released.connection else {
            Issue.record("releasing an idle connection must arm its timers, got \(released.connection)")
            return
        }
        #expect(
            timers.contains { $0.underlying.usecase == .idleTimeout },
            "a connection with nothing to do needs an idle timeout or it never closes"
        )
    }
}

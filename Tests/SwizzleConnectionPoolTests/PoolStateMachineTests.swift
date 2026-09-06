import Testing

@testable import SwizzleConnectionPool

/// The connection pool's decisions, on the paths that only run when something
/// has already gone wrong.
///
/// ## Why this suite exists
///
/// The pool was vendored from postgres-nio without upstream's tests, and it
/// showed: 50.7% of it covered, with the uncovered half concentrated in
/// `PoolStateMachine`. Every query on both network drivers goes through this
/// code, and the untested parts are precisely the ones that matter when a server
/// restarts, a network blips, or the process is shutting down with work still in
/// flight. Those are the moments a driver either holds together or loses
/// somebody's trust, and none of them were exercised.
///
/// ## What is being asserted
///
/// The state machine is a value type that performs no I/O: every transition maps
/// state and an event to an `Action` describing what the caller should do. So
/// these tests assert on the *decision* — close this connection, fail these
/// requests, schedule this timer — rather than on any observable side effect.
/// That is what makes them synchronous, deterministic, and free of the timing
/// assertions that have caused every flake in this project.
@Suite("Pool state machine")
struct PoolStateMachineTests {

    // MARK: - Leasing, so the failure paths have somewhere to fail from

    /// The ordinary path, stated once so the failure tests below have a
    /// baseline that is known to work.
    @Test("an established connection is leased to a waiting request")
    func leaseToWaitingRequest() {
        var (machine, _) = makeStateMachine()

        let request = MockRequest(id: 1)
        let leaseAction = machine.leaseConnection(request)
        // Nothing to lease yet, so the pool must be told to make one.
        guard case .makeConnection(let connectionRequest, _) = leaseAction.connection else {
            Issue.record("expected makeConnection, got \(leaseAction.connection)")
            return
        }

        let connection = MockConnection(id: connectionRequest.connectionID)
        let established = machine.connectionEstablished(connection, maxStreams: 1)
        guard case .leaseConnection(let requests, let leased) = established.request else {
            Issue.record("expected leaseConnection, got \(established.request)")
            return
        }
        #expect(leased.id == connection.id)
        #expect(requests.count == 1)
    }

    /// A request cancelled while queued is failed rather than left waiting, and
    /// the connection being made for it does not leak.
    @Test("cancelling a queued request fails it rather than stranding it")
    func cancelQueuedRequest() {
        var (machine, _) = makeStateMachine()

        let request = MockRequest(id: 1)
        _ = machine.leaseConnection(request)

        let action = machine.cancelRequest(id: request.id)
        guard case .failRequest(let failed, let error) = action.request else {
            Issue.record("expected failRequest, got \(action.request)")
            return
        }
        #expect(failed.id == request.id)
        #expect(error == ConnectionPoolError.requestCancelled)
    }

    // MARK: - When connections cannot be established

    /// **The path a restarting server takes.** A failed establish must produce a
    /// backoff timer rather than an immediate retry, or a pool facing a server
    /// that is down becomes a tight reconnect loop against it.
    @Test("a failed establish backs off instead of retrying immediately")
    func establishFailureBacksOff() {
        var (machine, _) = makeStateMachine()

        let request = MockRequest(id: 1)
        let leaseAction = machine.leaseConnection(request)
        guard case .makeConnection(let connectionRequest, _) = leaseAction.connection else {
            Issue.record("expected makeConnection, got \(leaseAction.connection)")
            return
        }

        let action = machine.connectionEstablishFailed(
            PoolTestError.refused, for: connectionRequest
        )
        guard case .scheduleTimers(let timers) = action.connection else {
            Issue.record("expected a backoff timer, got \(action.connection)")
            return
        }
        #expect(timers.count == 1, "one backoff timer for the one failed attempt")
        // The waiter is still waiting — a single failure is not a reason to fail
        // the request, only to wait before trying again.
        #expect(request.result == nil, "the request must not be failed by one retryable failure")
    }

    /// Backoff grows with consecutive failures. A fixed delay against a server
    /// that stays down is the same tight loop, only slower.
    ///
    /// Driven through the real cycle — fail, back off, retry, fail again —
    /// rather than by calling `backoffNextConnectionAttempt` directly. Calling
    /// it directly traps: `We tried to create a new connection that we know
    /// nothing about?`, because the machine only computes a backoff for a
    /// connection it is already tracking. That invariant is worth respecting in
    /// a test rather than routing around, since it is the same one the real
    /// caller has to satisfy.
    @Test("backoff grows with the number of consecutive failures")
    func backoffGrows() {
        var (machine, _) = makeStateMachine()

        let request = MockRequest(id: 1)
        let leaseAction = machine.leaseConnection(request)
        guard case .makeConnection(var connectionRequest, _) = leaseAction.connection else {
            Issue.record("expected makeConnection")
            return
        }

        var durations: [Duration] = []
        for _ in 1...4 {
            let failed = machine.connectionEstablishFailed(
                PoolTestError.refused, for: connectionRequest
            )
            guard case .scheduleTimers(let timers) = failed.connection,
                  let backoff = timers.first
            else {
                Issue.record("expected a backoff timer, got \(failed.connection)")
                return
            }
            durations.append(backoff.duration)

            // The backoff expiring is what produces the next attempt.
            let retry = machine.connectionCreationBackoffDone(connectionRequest.connectionID)
            switch retry.connection {
            case .makeConnection(let next, _):
                connectionRequest = next
            case .makeConnectionsCancelAndScheduleTimers(let requests, _, _):
                guard let next = requests.first else {
                    Issue.record("retry produced no connection request")
                    return
                }
                connectionRequest = next
            default:
                Issue.record("expected a retry, got \(retry.connection)")
                return
            }
        }

        #expect(durations.allSatisfy { $0 > .zero }, "every backoff must be non-zero: \(durations)")
        #expect(
            durations.last! > durations.first!,
            "backoff must grow across consecutive failures, got \(durations)"
        )
    }

    /// When the backoff expires the pool tries again, which is what makes the
    /// waiter's patience worth anything.
    @Test("a finished backoff retries the connection")
    func backoffDoneRetries() {
        var (machine, _) = makeStateMachine()

        let request = MockRequest(id: 1)
        let leaseAction = machine.leaseConnection(request)
        guard case .makeConnection(let connectionRequest, _) = leaseAction.connection else {
            Issue.record("expected makeConnection")
            return
        }
        _ = machine.connectionEstablishFailed(PoolTestError.refused, for: connectionRequest)

        let action = machine.connectionCreationBackoffDone(connectionRequest.connectionID)
        switch action.connection {
        case .makeConnection, .makeConnectionsCancelAndScheduleTimers:
            break  // retried, which is the point
        default:
            Issue.record("expected a retry after the backoff, got \(action.connection)")
        }
    }

    // MARK: - Keep-alive

    /// A keep-alive timer on an idle connection runs the check rather than
    /// closing the connection.
    @Test("a keep-alive timer runs the keep-alive")
    func keepAliveRuns() {
        var (machine, _) = makeStateMachine(minimumConnections: 1, keepAlive: .seconds(10))

        let connection = MockConnection(id: 0)
        _ = machine.connectionEstablished(connection, maxStreams: 1)

        let action = machine.connectionKeepAliveTimerTriggered(connection.id)
        guard case .runKeepAlive(let checked, _) = action.connection else {
            Issue.record("expected runKeepAlive, got \(action.connection)")
            return
        }
        #expect(checked.id == connection.id)
    }

    /// A keep-alive that succeeds returns the connection to service. The pool
    /// must not treat a healthy answer as a reason to do anything drastic.
    @Test("a successful keep-alive leaves the connection usable")
    func keepAliveSucceeds() {
        var (machine, _) = makeStateMachine(minimumConnections: 1, keepAlive: .seconds(10))

        let connection = MockConnection(id: 0)
        _ = machine.connectionEstablished(connection, maxStreams: 1)
        _ = machine.connectionKeepAliveTimerTriggered(connection.id)
        _ = machine.connectionKeepAliveDone(connection)

        // The proof it is usable: a request that arrives now gets it, rather
        // than causing a new connection to be made.
        let request = MockRequest(id: 1)
        let action = machine.leaseConnection(request)
        guard case .leaseConnection(_, let leased) = action.request else {
            Issue.record("expected the kept-alive connection to be leased, got \(action.request)")
            return
        }
        #expect(leased.id == connection.id)
        #expect(connection.closeCount == 0, "a healthy keep-alive must not close anything")
    }

    /// **A keep-alive that fails means the connection is already gone**, and the
    /// pool has to both drop it and replace it. Dropping without replacing
    /// leaves the pool below its minimum; replacing without dropping leases a
    /// dead connection to the next caller, so the failure surfaces on somebody's
    /// query instead of here.
    ///
    /// Both halves are asserted because they are separate transitions: the
    /// failure orders the close, and the *close completing* is what asks for the
    /// replacement. An earlier version of this test skipped the close and then
    /// leased, which trips
    /// `precondition(minimumConcurrentConnections <= stats.active)` — the pool
    /// is briefly below its minimum and the caller is expected to act on the
    /// close it was just handed, not to ignore it.
    @Test("a failed keep-alive closes the connection and asks for a replacement")
    func keepAliveFails() {
        var (machine, refill) = makeStateMachine(minimumConnections: 1, keepAlive: .seconds(10))
        #expect(refill.count == 1, "a minimum of one asks for one connection up front")

        let connection = MockConnection(id: refill[0].connectionID)
        _ = machine.connectionEstablished(connection, maxStreams: 1)
        _ = machine.connectionKeepAliveTimerTriggered(connection.id)

        let failed = machine.connectionKeepAliveFailed(connection.id)
        guard case .closeConnection(let closing, _) = failed.connection else {
            Issue.record("a failed keep-alive must close the connection, got \(failed.connection)")
            return
        }
        #expect(closing.id == connection.id)

        // And the close completing restores the pool to its minimum.
        let closed = machine.connectionClosed(connection)
        switch closed.connection {
        case .makeConnection, .makeConnectionsCancelAndScheduleTimers:
            break  // a replacement was requested, which is the point
        default:
            Issue.record(
                """
                closing the last connection left the pool below its minimum with \
                no replacement requested, got \(closed.connection)
                """
            )
        }
    }

    // MARK: - Idle timeout

    /// An idle connection above the minimum is closed when its timer fires —
    /// that is the whole purpose of the minimum, and a pool that never shrinks
    /// holds server resources it is not using.
    @Test("an idle connection above the minimum is closed")
    func idleConnectionClosed() {
        var (machine, _) = makeStateMachine(minimumConnections: 0, idleTimeout: .seconds(1))

        let request = MockRequest(id: 1)
        let leaseAction = machine.leaseConnection(request)
        guard case .makeConnection(let connectionRequest, _) = leaseAction.connection else {
            Issue.record("expected makeConnection")
            return
        }
        let connection = MockConnection(id: connectionRequest.connectionID)
        _ = machine.connectionEstablished(connection, maxStreams: 1)
        _ = machine.releaseConnection(connection, streams: 1)

        let action = machine.connectionIdleTimerTriggered(connection.id)
        guard case .closeConnection(let closing, _) = action.connection else {
            Issue.record("expected closeConnection, got \(action.connection)")
            return
        }
        #expect(closing.id == connection.id)
    }

    /// A connection at the minimum is kept, because the minimum is a promise to
    /// hold that many open rather than a starting point.
    @Test("an idle connection at the minimum is kept")
    func idleConnectionAtMinimumKept() {
        var (machine, refill) = makeStateMachine(minimumConnections: 1, idleTimeout: .seconds(1))
        #expect(refill.count == 1, "a minimum of one asks for one connection up front")

        let connection = MockConnection(id: refill[0].connectionID)
        _ = machine.connectionEstablished(connection, maxStreams: 1)

        let action = machine.connectionIdleTimerTriggered(connection.id)
        if case .closeConnection(let closing, _) = action.connection {
            Issue.record("closed the last connection despite a minimum of 1: \(closing.id)")
        }
    }

    // MARK: - Connections dying on their own

    /// A connection the pool did not close still has to leave the pool, and the
    /// pool has to notice rather than leasing it out again.
    @Test("a connection that closes itself is not leased again")
    func closedConnectionIsNotReused() {
        var (machine, _) = makeStateMachine(minimumConnections: 1)

        let connection = MockConnection(id: 0)
        _ = machine.connectionEstablished(connection, maxStreams: 1)
        _ = machine.connectionClosed(connection)

        let request = MockRequest(id: 1)
        let action = machine.leaseConnection(request)
        if case .leaseConnection(_, let leased) = action.request, leased.id == connection.id {
            Issue.record("leased a connection that had already closed")
        }
    }

    // MARK: - Graceful shutdown

    /// **Shutdown must resume its waiters**, one way or another. A pool that
    /// closes its connections and leaves queued requests suspended hangs every
    /// caller that was waiting, which is worse than failing them — a hang has no
    /// error to log and no stack to read.
    ///
    /// *When* they are resumed is the subtlety, and the first version of this
    /// test asserted the wrong moment. With every connection leased there is
    /// nothing for shutdown to close, so it returns `.none` and the queue drains
    /// "as they are released, established, or fail" — the machine's own comment.
    /// So the property is not that shutdown answers the waiters immediately; it
    /// is that nobody is left waiting once the connection comes back.
    @Test("shutdown drains its queued requests as connections are released")
    func shutdownDrainsQueuedRequests() {
        var (machine, _) = makeStateMachine(maximumSoftLimit: 1, maximumHardLimit: 1)

        // One request takes the only connection; the rest queue behind it.
        let holder = MockRequest(id: 1)
        let leaseAction = machine.leaseConnection(holder)
        guard case .makeConnection(let connectionRequest, _) = leaseAction.connection else {
            Issue.record("expected makeConnection")
            return
        }
        let connection = MockConnection(id: connectionRequest.connectionID)
        _ = machine.connectionEstablished(connection, maxStreams: 1)

        let waiting = [MockRequest(id: 2), MockRequest(id: 3)]
        for request in waiting { _ = machine.leaseConnection(request) }
        #expect(waiting.allSatisfy { $0.result == nil }, "the premise: both are queued")

        // Nothing is idle, so there is nothing to close yet.
        let shutdown = machine.triggerGracefulShutdown()
        if case .leaseConnection = shutdown.request {
            Issue.record("shutdown leased a connection")
        }

        // The drain is **incremental**: one release serves one waiter, and that
        // waiter's own release serves the next. Draining is therefore a loop,
        // not a single call — asserting on one release leaves the second waiter
        // outstanding and reads as a hang that is not there.
        //
        // The bound is one iteration per waiter plus slack; if the loop needed
        // more than that, the queue would not be draining at all.
        for _ in 0..<(waiting.count + 2) where waiting.contains(where: { $0.result == nil }) {
            let released = machine.releaseConnection(connection, streams: 1)
            switch released.request {
            case .failRequests(let failed, let error):
                for request in failed { request.complete(with: .failure(error)) }
            case .failRequest(let failed, let error):
                failed.complete(with: .failure(error))
            case .leaseConnection(let requests, let leased):
                for request in requests {
                    request.complete(with: .success(ConnectionLease(connection: leased) { _ in }))
                }
            case .none:
                break
            }
        }

        #expect(
            waiting.allSatisfy { $0.result != nil },
            "a waiter left unanswered after shutdown is a hang with no error and no stack"
        )
    }

    /// A request arriving after shutdown is refused immediately rather than
    /// queued against a pool that will never serve it.
    @Test("a request after shutdown is refused, not queued")
    func requestAfterShutdownIsRefused() {
        var (machine, _) = makeStateMachine()
        _ = machine.triggerGracefulShutdown()

        let request = MockRequest(id: 1)
        let action = machine.leaseConnection(request)
        guard case .failRequest(_, let error) = action.request else {
            Issue.record("expected the request to be refused, got \(action.request)")
            return
        }
        #expect(error == ConnectionPoolError.poolShutdown)
    }

    /// Shutting down an idle pool closes what it holds.
    @Test("shutdown closes the connections the pool holds")
    func shutdownClosesConnections() {
        var (machine, refill) = makeStateMachine(minimumConnections: 2)
        #expect(refill.count == 2)

        let connections = refill.map { MockConnection(id: $0.connectionID) }
        for connection in connections {
            _ = machine.connectionEstablished(connection, maxStreams: 1)
        }

        let action = machine.triggerGracefulShutdown()
        guard case .initiateShutdown(let shutdown) = action.connection else {
            Issue.record("expected initiateShutdown, got \(action.connection)")
            return
        }
        #expect(
            shutdown.connections.count == connections.count,
            "every held connection must be in the shutdown set"
        )
    }
}

/// A stand-in for whatever the connection factory failed with.
enum PoolTestError: Error {
    case refused
}

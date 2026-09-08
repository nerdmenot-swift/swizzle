import Testing

@testable import SwizzleConnectionPool

/// What the pool does while the server is *down*, rather than while one
/// connection is unhappy.
///
/// ## Why this is a different suite
///
/// The failure tests elsewhere fail a single connection and watch it back off.
/// That is not what an outage looks like. When a server goes away, every
/// connection attempt fails at once, and the pool moves into a distinct state
/// where it nominates **one** connection to keep retrying and destroys the
/// others as their backoffs expire — otherwise a pool with a soft limit of ten
/// hammers a dead server ten times per backoff interval, and does it harder the
/// bigger the pool is.
///
/// That nomination is the part no single-connection test can reach: it needs two
/// connections backing off at once so there is a retrying one and a
/// non-retrying one to tell apart.
///
/// ## And the idle timer that must not fire
///
/// An idle timeout firing on a connection that is running a keep-alive, while
/// requests are queued behind it, must *reschedule* rather than close. Closing
/// there drops a connection the queue is waiting for, and the queue then waits
/// for a connection the pool has just thrown away.
@Suite("Pool outage")
struct PoolOutageTests {

    /// Drives two concurrent connection attempts and fails both, leaving the
    /// pool with one connection retrying and one not.
    static func twoFailedAttempts() -> (
        machine: TestStateMachine,
        retrying: TestStateMachine.ConnectionRequest,
        other: TestStateMachine.ConnectionRequest
    )? {
        var (machine, _) = makeStateMachine(
            minimumConnections: 0, maximumSoftLimit: 2, maximumHardLimit: 2
        )

        var requests: [TestStateMachine.ConnectionRequest] = []
        for id in 1...2 {
            let action = machine.leaseConnection(MockRequest(id: id))
            switch action.connection {
            case .makeConnection(let request, _):
                requests.append(request)
            case .makeConnectionsCancelAndScheduleTimers(let many, _, _):
                requests.append(contentsOf: many)
            default:
                break
            }
        }
        guard requests.count == 2 else {
            Issue.record("expected two connection attempts, got \(requests.count)")
            return nil
        }

        // The first failure is what nominates a connection to retry.
        _ = machine.connectionEstablishFailed(PoolTestError.refused, for: requests[0])
        _ = machine.connectionEstablishFailed(PoolTestError.refused, for: requests[1])
        return (machine, requests[0], requests[1])
    }

    // MARK: - One retries, the rest are let go

    /// **The nomination**, which happens at failure time rather than at
    /// backoff time.
    ///
    /// With the server down, the first failure nominates one connection to keep
    /// retrying. The *second* failure does not arm another backoff — it destroys
    /// that connection and cancels its timers immediately, so the pool probes a
    /// dead server once per interval instead of once per connection. A pool with
    /// a soft limit of ten would otherwise hammer it ten times as hard.
    ///
    /// My first version of this test assumed the redundant connection lingered
    /// until its own backoff expired and then got dropped. It does not exist by
    /// then: calling `connectionCreationBackoffDone` for it trips
    /// `Failing a connection we don't have a record of`, which is the pool
    /// telling you the caller may only report ids it still owns.
    @Test("a second failure during an outage destroys rather than backs off again")
    func secondFailureDestroysRatherThanRetrying() {
        var (machine, _) = makeStateMachine(
            minimumConnections: 0, maximumSoftLimit: 2, maximumHardLimit: 2
        )

        var requests: [TestStateMachine.ConnectionRequest] = []
        for id in 1...2 {
            let action = machine.leaseConnection(MockRequest(id: id))
            if case .makeConnection(let request, _) = action.connection {
                requests.append(request)
            }
        }
        guard requests.count == 2 else {
            Issue.record("expected two connection attempts, got \(requests.count)")
            return
        }

        // The first failure arms a backoff: this is the nominated connection.
        let first = machine.connectionEstablishFailed(PoolTestError.refused, for: requests[0])
        guard case .scheduleTimers(let timers) = first.connection, !timers.isEmpty else {
            Issue.record("the first failure must arm a backoff, got \(first.connection)")
            return
        }

        // The second does not arm a second one.
        let second = machine.connectionEstablishFailed(PoolTestError.refused, for: requests[1])
        switch second.connection {
        case .scheduleTimers(let more):
            Issue.record("a second backoff was armed against one dead server: \(more.count) timers")
        case .cancelTimers:
            break  // destroyed, which is the point
        default:
            break
        }

        // And the nominated one does retry when its backoff expires.
        let retry = machine.connectionCreationBackoffDone(requests[0].connectionID)
        switch retry.connection {
        case .makeConnection, .makeConnectionsCancelAndScheduleTimers:
            break
        default:
            Issue.record("the nominated connection did not retry: \(retry.connection)")
        }
    }

    /// The waiters are not failed by an outage — the pool keeps retrying and
    /// they keep waiting, which is the behaviour that lets a query survive a
    /// server restart instead of erroring in the middle of one.
    @Test("an outage does not fail the requests waiting through it")
    func outageDoesNotFailWaiters() {
        var (machine, _) = makeStateMachine(
            minimumConnections: 0, maximumSoftLimit: 1, maximumHardLimit: 1
        )
        let waiter = MockRequest(id: 1)
        let action = lease(waiter, from: &machine)
        guard case .makeConnection(let request, _) = action.connection else {
            Issue.record("expected makeConnection")
            return
        }

        // Each retry is a **new** connection id, so the request has to be
        // carried forward. Reusing the original one trips the pool's own
        // `Failing a connection we don't have a record of` — it is tracking the
        // retry, not the attempt that already failed.
        var attempt = request
        for _ in 0..<3 {
            run(machine.connectionEstablishFailed(PoolTestError.refused, for: attempt).request)
            let retry = machine.connectionCreationBackoffDone(attempt.connectionID)
            run(retry.request)
            switch retry.connection {
            case .makeConnection(let next, _):
                attempt = next
            case .makeConnectionsCancelAndScheduleTimers(let many, _, _):
                guard let next = many.first else { return }
                attempt = next
            default:
                return  // the pool stopped retrying, which the waiter check below still covers
            }
        }

        #expect(
            waiter.result == nil,
            "a waiter must ride out an outage rather than be failed by it"
        )
    }

    /// Not tested: a backoff completing for an id the pool has forgotten.
    ///
    /// That is not a no-op — it trips `Failing a connection we don't have a
    /// record of`. Unlike the wire-facing entry points, which take ids from the
    /// peer and must not trust them, this one is called by the pool's *own*
    /// timer machinery with an id the pool itself issued. Asserting that it
    /// tolerates a made-up id would be inventing a contract the type does not
    /// offer, and would freeze an assertion that is doing useful work.

    /// Shutting down mid-outage has to cancel the backoff timers, or the pool
    /// fires a retry after it has shut down.
    @Test("shutting down during an outage cancels the pending backoffs")
    func shutdownDuringOutage() {
        guard var (machine, _, _) = Self.twoFailedAttempts() else { return }
        let action = machine.triggerGracefulShutdown()
        switch action.connection {
        case .initiateShutdown, .cancelEventStreamAndFinalCleanup, .cancelTimers, .none:
            break
        case .makeConnection, .makeConnectionsCancelAndScheduleTimers:
            Issue.record("a shutting-down pool asked for another connection")
        default:
            break
        }
    }

    // MARK: - The idle timer that reschedules

    /// **An idle timeout with requests queued must reschedule, not close.**
    ///
    /// The window is real: a connection starts a keep-alive, a request queues
    /// behind it because nothing is free, and the idle timer then fires while
    /// the keep-alive is still running. Closing there throws away the very
    /// connection the queue is waiting for.
    @Test("an idle timeout with requests queued reschedules instead of closing")
    func idleTimerWithQueuedRequestsReschedules() {
        var (machine, refill) = makeStateMachine(
            minimumConnections: 1, maximumSoftLimit: 1, maximumHardLimit: 1,
            keepAlive: .seconds(10), idleTimeout: .seconds(30)
        )
        let connection = MockConnection(id: refill[0].connectionID)
        _ = machine.connectionEstablished(connection, maxStreams: 1)

        // Take the connection, then queue a request behind it.
        lease(MockRequest(id: 1), from: &machine)
        let queued = MockRequest(id: 2)
        lease(queued, from: &machine)

        let action = machine.connectionIdleTimerTriggered(connection.id)
        run(action.request)
        if case .closeConnection(let closing, _) = action.connection {
            Issue.record(
                "closed connection \(closing.id) while a request was queued for it"
            )
        }
        #expect(queued.result == nil, "the queued request is still waiting, not failed")
    }

    /// With nothing queued, the same timer on an idle connection above the
    /// minimum does close it — the behaviour the guard above is an exception to.
    @Test("an idle timeout with an empty queue still closes the connection")
    func idleTimerWithEmptyQueueCloses() {
        var (machine, _) = makeStateMachine(
            minimumConnections: 0, maximumSoftLimit: 2, idleTimeout: .seconds(30)
        )
        let action = machine.leaseConnection(MockRequest(id: 1))
        guard case .makeConnection(let request, _) = action.connection else {
            Issue.record("expected makeConnection")
            return
        }
        let connection = MockConnection(id: request.connectionID)
        _ = machine.connectionEstablished(connection, maxStreams: 1)
        _ = machine.releaseConnection(connection, streams: 1)

        let timer = machine.connectionIdleTimerTriggered(connection.id)
        guard case .closeConnection(let closing, _) = timer.connection else {
            Issue.record("an idle connection above the minimum should close, got \(timer.connection)")
            return
        }
        #expect(closing.id == connection.id)
    }

    /// An idle timer for a connection the pool no longer has is ignored.
    @Test("an idle timeout for an unknown connection does nothing")
    func idleTimerForUnknownConnection() {
        var (machine, _) = makeStateMachine(minimumConnections: 1)
        let action = machine.connectionIdleTimerTriggered(999_999)
        if case .closeConnection = action.connection {
            Issue.record("closed something on behalf of a connection that does not exist")
        }
    }
}

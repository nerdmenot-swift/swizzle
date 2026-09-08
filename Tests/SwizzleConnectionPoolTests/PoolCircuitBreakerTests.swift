import Testing

@testable import SwizzleConnectionPool

/// The circuit breaker: what the pool does once it accepts the server is gone.
///
/// ## The three pool states this is about
///
/// A pool that cannot open a connection does not fail callers straight away. It
/// moves to `connectionCreationFailing` and keeps them queued, because the
/// common case is a restart that resolves in seconds and a query that survives
/// it is better than one that errors. But that patience cannot be unbounded: if
/// the server is not coming back, every caller in the process ends up suspended
/// on a pool that will never serve them, and the failure is invisible — nothing
/// errors, nothing logs, the application simply stops.
///
/// So after `circuitBreakerTripAfter` of continuous failure **with no working
/// connection left**, the pool trips to `circuitBreakOpen`: it fails everyone
/// waiting and fails new arrivals immediately, while one nominated connection
/// keeps retrying in the background so it can close again on its own.
///
/// Both halves of that condition matter, and the second is the one worth
/// dwelling on. A pool with one healthy connection and one failed attempt is not
/// broken — it is smaller than it wants to be. Tripping there would turn a
/// degraded pool into a dead one.
///
/// ## On timing
///
/// These tests set the trip threshold to zero rather than waiting one out, so
/// "has been failing longer than the threshold" is true the moment a second
/// failure arrives. Nothing sleeps and nothing measures elapsed time; the clock
/// only has to move forward, which it does.
@Suite("Pool circuit breaker")
struct PoolCircuitBreakerTests {

    /// A pool that has just tripped its breaker, plus the id still retrying.
    ///
    /// Two failures are the minimum: the first moves the pool from `running`
    /// into `connectionCreationFailing` and starts the clock, and only the
    /// second can find that the threshold has been exceeded.
    static func tripped() -> (machine: TestStateMachine, retrying: TestStateMachine.ConnectionRequest, waiter: MockRequest)? {
        var (machine, _) = makeStateMachine(
            minimumConnections: 0, maximumSoftLimit: 1, maximumHardLimit: 1,
            circuitBreakerTripAfter: .zero
        )
        let waiter = MockRequest(id: 1)
        guard case .makeConnection(let first, _) = lease(waiter, from: &machine).connection else {
            Issue.record("expected a connection attempt")
            return nil
        }

        _ = machine.connectionEstablishFailed(PoolTestError.refused, for: first)
        guard case .makeConnection(let retry, _) =
            machine.connectionCreationBackoffDone(first.connectionID).connection
        else {
            Issue.record("expected the nominated connection to retry")
            return nil
        }
        run(machine.connectionEstablishFailed(PoolTestError.refused, for: retry).request)
        return (machine, retry, waiter)
    }

    // MARK: - Tripping

    /// **Tripping fails everyone who was waiting**, and names the reason. A
    /// caller told "the pool gave up trying to connect" can retry or surface it;
    /// one left suspended can do neither.
    @Test("tripping the breaker fails the requests that were waiting")
    func trippingFailsWaiters() {
        guard let (_, _, waiter) = Self.tripped() else { return }
        #expect(
            waiter.failure == .connectionCreationCircuitBreakerTripped,
            "got \(String(describing: waiter.failure))"
        )
    }

    /// **And new arrivals fail immediately rather than joining a queue that is
    /// not moving.** This is the behaviour the whole state exists for.
    @Test("a request arriving while the breaker is open fails immediately")
    func openBreakerFailsNewRequests() {
        guard var (machine, _, _) = Self.tripped() else { return }
        let arrival = MockRequest(id: 2)
        let action = lease(arrival, from: &machine)

        switch action.connection {
        case .makeConnection, .makeConnectionsCancelAndScheduleTimers:
            Issue.record("opened another connection against a server known to be down")
        default:
            break
        }
        guard case .failRequest(let failed, let error) = action.request else {
            Issue.record("the request was queued rather than failed: \(action.request)")
            return
        }
        #expect(failed == arrival)
        #expect(error == .connectionCreationCircuitBreakerTripped)
    }

    /// **The breaker does not trip while a working connection remains.** A pool
    /// that has one good connection and one failed attempt is degraded, not
    /// dead, and callers must keep being served rather than failed.
    ///
    /// This is the half of the condition a test that only checks the timeout
    /// would miss entirely — and getting it wrong turns every transient failure
    /// during a busy period into an outage.
    @Test("the breaker does not trip while a working connection remains")
    func doesNotTripWithAWorkingConnection() {
        var (machine, _) = makeStateMachine(
            minimumConnections: 0, maximumSoftLimit: 2, maximumHardLimit: 2,
            circuitBreakerTripAfter: .zero
        )
        // One connection that works, leased so the pool wants a second.
        guard case .makeConnection(let good, _) =
            lease(MockRequest(id: 1), from: &machine).connection
        else {
            Issue.record("expected a connection attempt")
            return
        }
        let connection = MockConnection(id: good.connectionID)
        _ = machine.connectionEstablished(connection, maxStreams: 1)

        let queued = MockRequest(id: 2)
        guard case .makeConnection(let second, _) = lease(queued, from: &machine).connection else {
            Issue.record("expected a second connection attempt")
            return
        }

        // Fail the second one repeatedly. The threshold is zero, so only the
        // surviving connection stops the breaker tripping.
        var attempt = second
        for _ in 0..<3 {
            run(machine.connectionEstablishFailed(PoolTestError.refused, for: attempt).request)
            guard case .makeConnection(let next, _) =
                machine.connectionCreationBackoffDone(attempt.connectionID).connection
            else { break }
            attempt = next
        }

        #expect(queued.result == nil, "a waiter was failed while the pool still had a connection")

        // And a new arrival is still queued rather than failed.
        let arrival = MockRequest(id: 3)
        if case .failRequest(_, let error) = lease(arrival, from: &machine).request {
            Issue.record("failed a request with \(error) while a working connection existed")
        }
    }

    // MARK: - While open

    /// One connection keeps retrying while the breaker is open, so the pool can
    /// notice the server coming back. A breaker that stops probing never closes.
    @Test("the nominated connection keeps retrying while the breaker is open")
    func nominatedConnectionKeepsRetrying() {
        guard var (machine, retrying, _) = Self.tripped() else { return }
        let action = machine.connectionCreationBackoffDone(retrying.connectionID)
        switch action.connection {
        case .makeConnection, .makeConnectionsCancelAndScheduleTimers:
            break
        default:
            Issue.record("the pool stopped probing and can never recover: \(action.connection)")
        }
    }

    /// A second connection failing while the breaker is open is destroyed rather
    /// than given its own backoff — one probe per interval, not one per
    /// connection.
    @Test("a non-nominated connection failing while open is destroyed")
    func nonNominatedFailureIsDestroyed() {
        var (machine, _) = makeStateMachine(
            minimumConnections: 0, maximumSoftLimit: 2, maximumHardLimit: 2,
            circuitBreakerTripAfter: .zero
        )
        var requests: [TestStateMachine.ConnectionRequest] = []
        for id in 1...2 {
            if case .makeConnection(let request, _) =
                machine.leaseConnection(MockRequest(id: id)).connection
            {
                requests.append(request)
            }
        }
        guard requests.count == 2 else {
            Issue.record("expected two connection attempts, got \(requests.count)")
            return
        }

        // Trip the breaker on the nominated connection.
        _ = machine.connectionEstablishFailed(PoolTestError.refused, for: requests[0])
        guard case .makeConnection(let retry, _) =
            machine.connectionCreationBackoffDone(requests[0].connectionID).connection
        else {
            Issue.record("expected a retry")
            return
        }
        _ = machine.connectionEstablishFailed(PoolTestError.refused, for: retry)

        // The other one failing now is dropped, not scheduled.
        let action = machine.connectionEstablishFailed(PoolTestError.refused, for: requests[1])
        if case .scheduleTimers(let timers) = action.connection, !Array(timers).isEmpty {
            Issue.record("armed a second backoff against a server known to be down")
        }
    }

    /// Not tested: a backoff completing for a non-nominated connection.
    ///
    /// There is no such thing to observe. The redundant connection is destroyed
    /// at the moment its establish fails, not when its backoff expires, so by
    /// then the pool has no record of it and asking trips "Failing a connection
    /// we don't have a record of". Same non-contract as the one written up in
    /// PoolOutageTests, reached from the circuit-break state instead.


    // MARK: - Closing again

    /// **Recovery.** A connection establishing puts the pool back to running, so
    /// the next caller is queued and served rather than failed. Without this the
    /// breaker is a one-way door and the pool never works again.
    @Test("a connection establishing closes the breaker again")
    func establishingClosesTheBreaker() {
        guard var (machine, retrying, _) = Self.tripped() else { return }

        // Confirm it is open first, so the check below means something.
        let whileOpen = MockRequest(id: 2)
        guard case .failRequest = lease(whileOpen, from: &machine).request else {
            Issue.record("the breaker was not open to begin with")
            return
        }

        // The nominated connection is *backing off*, not waiting to be handed a
        // socket — establishing it directly trips "Invalid state: backingOff".
        // Its backoff has to expire first, and the attempt that follows carries
        // a new connection id.
        guard case .makeConnection(let attempt, _) =
            machine.connectionCreationBackoffDone(retrying.connectionID).connection
        else {
            Issue.record("the nominated connection did not retry")
            return
        }
        let connection = MockConnection(id: attempt.connectionID)
        run(machine.connectionEstablished(connection, maxStreams: 1).request)

        let afterRecovery = MockRequest(id: 3)
        let action = lease(afterRecovery, from: &machine)
        if case .failRequest(_, let error) = action.request {
            Issue.record("still failing requests after recovery: \(error)")
        }
        #expect(
            afterRecovery.leasedConnectionID == connection.id,
            "the recovered connection served the next caller"
        )
    }

    /// Shutting down while the breaker is open fails new requests with
    /// `poolShutdown` rather than the breaker error — the pool is gone, which is
    /// a different thing from the server being gone, and a caller should be told
    /// which.
    @Test("shutting down with the breaker open reports the pool, not the server")
    func shutdownDuringOpenBreaker() {
        guard var (machine, _, _) = Self.tripped() else { return }
        _ = machine.triggerGracefulShutdown()

        let arrival = MockRequest(id: 2)
        lease(arrival, from: &machine)
        #expect(
            arrival.failure == .poolShutdown,
            "got \(String(describing: arrival.failure))"
        )
    }

    // MARK: - The threshold is actually consulted

    /// **The breaker does not trip before its threshold has elapsed.**
    ///
    /// Every other test in this suite sets `circuitBreakerTripAfter` to zero so
    /// the trip is reachable without waiting. That makes them all agree with a
    /// pool that ignored the threshold entirely — mutation testing found exactly
    /// that, by changing the comparison at `PoolStateMachine.swift:465` and
    /// watching the whole suite stay green.
    ///
    /// So this is the negative control the others need: with the default
    /// threshold, the same sequence of failures that trips the breaker above
    /// must *not* trip it, and callers must keep waiting rather than being
    /// failed. Without it, "the breaker trips after sustained failure" is only
    /// half a claim — the half about sustained is untested.
    ///
    /// It cannot pin the boundary itself. Whether the comparison is `>` or `>=`
    /// is only observable when the elapsed time equals the threshold exactly,
    /// which needs a clock the test controls; `ContinuousClock` is not one, and
    /// the pool takes its own readings. What this pins is the property that
    /// matters: the threshold is consulted at all.
    @Test("the breaker does not trip before its threshold has elapsed")
    func breakerRespectsItsThreshold() {
        var (machine, _) = makeStateMachine(
            minimumConnections: 0, maximumSoftLimit: 1, maximumHardLimit: 1,
            circuitBreakerTripAfter: .seconds(60)
        )
        let waiter = MockRequest(id: 1)
        guard case .makeConnection(let first, _) = lease(waiter, from: &machine).connection else {
            Issue.record("expected a connection attempt")
            return
        }

        // The same two failures that trip the breaker when the threshold is
        // zero. Sixty seconds have not passed, so they must not trip it here.
        run(machine.connectionEstablishFailed(PoolTestError.refused, for: first).request)
        guard case .makeConnection(let retry, _) =
            machine.connectionCreationBackoffDone(first.connectionID).connection
        else {
            Issue.record("expected the connection to retry")
            return
        }
        run(machine.connectionEstablishFailed(PoolTestError.refused, for: retry).request)

        #expect(
            waiter.failure == nil,
            "the waiter was failed after \(String(describing: waiter.failure)) with 60s still to run"
        )

        // And a new arrival is queued rather than failed fast, which is the
        // behaviour that distinguishes "still trying" from "given up".
        let arrival = MockRequest(id: 2)
        lease(arrival, from: &machine)
        #expect(
            arrival.failure == nil,
            "a new caller was failed before the pool had given up"
        )
    }
}

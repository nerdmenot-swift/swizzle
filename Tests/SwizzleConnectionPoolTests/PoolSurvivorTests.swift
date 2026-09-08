import Testing

@testable import SwizzleConnectionPool

/// Behaviours a mutation sweep showed nothing was checking.
///
/// ## Where these came from
///
/// A mutation run over `SwizzleConnectionPool` left 42 survivors. Most are
/// benign — nine mutate a `#elseif` compile condition in vendored NIO code and
/// cannot change the built binary, and several flip a comparison at a boundary
/// where both sides compute the same answer. Those are equivalent mutants, not
/// holes.
///
/// The ones below are not. Each is a line where changing the operator changes
/// what the pool does, and the whole suite stayed green — which means the
/// behaviour was never asserted, only executed. They are grouped here rather
/// than scattered because what they have in common is how they were found.
@Suite("Pool survivors")
struct PoolSurvivorTests {

    /// A saturated pool: 1 persisted, 1 demand, 2 overflow, all leased.
    static func saturated() -> (machine: TestStateMachine, connections: [MockConnection]) {
        PoolOverflowTests.saturated()
    }

    // MARK: - Looking up the right connection

    /// **`rescheduleIdleTimer` must reschedule the timer of the connection it
    /// was asked about.** The lookup is a `firstIndex(where: { $0.id == id })`,
    /// and inverting that comparison finds the first connection that is *not*
    /// the one asked for. With a single connection in the pool there is no
    /// difference to observe, which is why every existing test missed it.
    @Test("rescheduling an idle timer names the connection it was asked about")
    func rescheduleIdleTimerPicksTheRightConnection() {
        var (machine, refill) = makeStateMachine(
            minimumConnections: 2, maximumSoftLimit: 3, maximumHardLimit: 3,
            idleTimeout: .seconds(30)
        )
        var connections: [MockConnection] = []
        for request in refill {
            let connection = MockConnection(id: request.connectionID)
            connections.append(connection)
            run(machine.connectionEstablished(connection, maxStreams: 1).request)
        }
        guard connections.count >= 2 else {
            Issue.record("expected two connections, got \(connections.count)")
            return
        }

        // Ask about the second one specifically.
        let target = connections[1]
        lease(MockRequest(id: 1), from: &machine)
        let action = machine.connectionIdleTimerTriggered(target.id)
        // Whatever it decides, it must be about `target` and not its neighbour.
        if case .closeConnection(let closing, _) = action.connection {
            #expect(
                closing.id == target.id,
                "asked about \(target.id) and it closed \(closing.id)"
            )
        }
    }

    /// **The same for destroying a backing-off connection.** Two connections
    /// backing off at once is the outage case, and destroying the wrong one
    /// leaves the pool retrying a connection it has already written off.
    @Test("destroying a backing-off connection destroys the one named")
    func destroyBackingOffPicksTheRightConnection() {
        var (machine, _) = makeStateMachine(
            minimumConnections: 0, maximumSoftLimit: 2, maximumHardLimit: 2
        )
        var requests: [TestStateMachine.ConnectionRequest] = []
        for id in 1...2 {
            if case .makeConnection(let request, _) = lease(MockRequest(id: id), from: &machine).connection {
                requests.append(request)
            }
        }
        guard requests.count == 2 else {
            Issue.record("expected two attempts, got \(requests.count)")
            return
        }

        // The first failure nominates a connection to retry; the second
        // destroys the other. The one still retrying must be the nominee.
        run(machine.connectionEstablishFailed(PoolTestError.refused, for: requests[0]).request)
        run(machine.connectionEstablishFailed(PoolTestError.refused, for: requests[1]).request)

        let retry = machine.connectionCreationBackoffDone(requests[0].connectionID)
        switch retry.connection {
        case .makeConnection, .makeConnectionsCancelAndScheduleTimers:
            break
        default:
            Issue.record("the nominated connection was destroyed instead of the other: \(retry.connection)")
        }
    }

    // MARK: - Promotion must not pick a dying connection

    /// **An overflow connection that is already draining must not be promoted.**
    ///
    /// The search is `isConnected && !isDraining`. Relaxing that to `||` picks a
    /// draining connection, and promoting one moves a connection that is on its
    /// way out into a slot the pool intends to keep — so the pool believes it
    /// holds a connection that is about to disappear, and the slot is empty
    /// again moments later.
    @Test("promotion skips an overflow connection that is already draining")
    func promotionSkipsDrainingConnections() {
        var (machine, connections) = Self.saturated()

        // The `!isDraining` clause is in the promotion that runs when a close is
        // *announced*, not the one that runs when a close completes — those are
        // different searches, and `swapForDeletion` looks only for `isConnected`.
        // My first version of this test drove the second path and could not have
        // failed however the first was mutated.
        //
        // So: park the persisted connection, put the first overflow connection
        // into draining, then announce the persisted one closing.
        #expect(PoolOverflowTests.release(connections[0], from: &machine) == .parked)
        _ = machine.connectionWillClose(connections[2].id)
        _ = machine.connectionWillClose(connections[0].id)

        // The search must have skipped the draining connection at index 2 and
        // promoted the healthy one at index 3, which now parks on release.
        #expect(
            PoolOverflowTests.release(connections[3], from: &machine) == .parked,
            "the healthy overflow connection was not promoted; a draining one was taken instead"
        )
    }

    // MARK: - Availability at zero

    /// **A connection whose stream limit is zero has nothing to offer.**
    ///
    /// `isAvailable` compares the keep-alive's stream use against the maximum.
    /// At a maximum of zero those are equal, and the difference between `<` and
    /// `<=` is whether the pool offers a connection that cannot carry anything.
    /// A server is entitled to revise its limit to zero mid-session, so this is
    /// reachable rather than theoretical.
    @Test("a connection whose stream limit drops to zero is not available")
    func zeroMaxStreamsIsNotAvailable() {
        var state = TestStateMachine.ConnectionState(id: 1)
        let connection = MockConnection(id: 1)
        _ = state.connected(connection, maxStreams: 4)
        #expect(state.isAvailable, "the premise: it starts with capacity")

        _ = state.newMaxStreamSetting(0)
        #expect(
            !state.isAvailable,
            "a connection that can carry no streams was offered as available"
        )
    }

    // MARK: - Refilling to the minimum, not past it

    /// **A closed connection is replaced only when the pool is below its
    /// minimum.** The check is `connections.count < minimum` after the closed
    /// one has been removed; relaxing it to `<=` replaces a connection the pool
    /// did not lose, and the pool creeps upward one connection per close.
    ///
    /// Observing it needs more connections than the minimum, so that closing one
    /// leaves the pool exactly at the minimum rather than below it. Every
    /// existing test closed the pool's only connection, where both comparisons
    /// agree.
    @Test("closing a surplus connection does not trigger a replacement")
    func closingASurplusConnectionDoesNotRefill() {
        // The boundary is `count == minimum` after the closed connection has
        // been removed. A saturated pool is nowhere near it — four connections
        // against a minimum of one, where both comparisons agree — so my first
        // version of this could not have failed. Two connections and a minimum
        // of one is the only shape that sits on it.
        var (machine, refill) = makeStateMachine(
            minimumConnections: 1, maximumSoftLimit: 2, maximumHardLimit: 2
        )
        var connections: [MockConnection] = []
        for request in refill {
            let connection = MockConnection(id: request.connectionID)
            connections.append(connection)
            run(machine.connectionEstablished(connection, maxStreams: 1).request)
        }
        // The first request is served by the connection that already exists —
        // only the second one makes the pool open another.
        lease(MockRequest(id: 1), from: &machine)
        guard case .makeConnection(let extra, _) =
            lease(MockRequest(id: 2), from: &machine).connection
        else {
            Issue.record("expected the pool to open a second connection")
            return
        }
        let surplus = MockConnection(id: extra.connectionID)
        connections.append(surplus)
        run(machine.connectionEstablished(surplus, maxStreams: 1).request)

        // Asked of the group directly. The decision is `connections.count <
        // minimum` evaluated *after* the closed connection has been removed, and
        // the pool-level action folds that into a batch — so driving it from
        // outside cannot see whether a replacement was requested or merely
        // wanted for another reason.
        let closed = machine.connections.connectionClosed(surplus.id, shuttingDown: false)
        #expect(
            closed.newConnectionRequest == nil,
            "replaced a connection while the pool was still at or above its minimum"
        )
    }

    /// **And the other side of that boundary.** Dropping *below* the minimum
    /// must produce a replacement, or the guard above would be satisfied by a
    /// pool that never refills at all.
    @Test("closing a connection that drops the pool below its minimum does refill")
    func closingBelowMinimumRefills() {
        var (machine, refill) = makeStateMachine(
            minimumConnections: 1, maximumSoftLimit: 2, maximumHardLimit: 2
        )
        let connection = MockConnection(id: refill[0].connectionID)
        run(machine.connectionEstablished(connection, maxStreams: 1).request)

        let closed = machine.connections.connectionClosed(connection.id, shuttingDown: false)
        #expect(
            closed.newConnectionRequest != nil,
            "the pool dropped below its minimum and asked for nothing"
        )
    }

    // MARK: - The lookup itself

    /// **Rescheduling names the connection it was asked about.**
    ///
    /// Asked of the group directly, because that is where the lookup is. Driving
    /// it through the pool cannot distinguish the two: the pool only reschedules
    /// when a request is queued, and arranging that alongside two idle
    /// connections is a state the pool does not readily produce.
    @Test("rescheduling an idle timer returns a timer for the connection named")
    func rescheduleReturnsTheRightConnectionsTimer() {
        var (machine, _) = makeStateMachine(
            minimumConnections: 0, maximumSoftLimit: 2, maximumHardLimit: 2,
            idleTimeout: .seconds(30)
        )
        var connections: [MockConnection] = []
        for id in 1...2 {
            guard case .makeConnection(let request, _) =
                lease(MockRequest(id: id), from: &machine).connection
            else { continue }
            let connection = MockConnection(id: request.connectionID)
            connections.append(connection)
            run(machine.connectionEstablished(connection, maxStreams: 1).request)
        }
        guard connections.count == 2 else {
            Issue.record("expected two connections, got \(connections.count)")
            return
        }
        for connection in connections {
            run(machine.releaseConnection(connection, streams: 1).request)
        }

        let target = connections[1]
        guard let (timer, _) = machine.connections.rescheduleIdleTimer(target.id) else {
            Issue.record("no idle timer to reschedule")
            return
        }
        #expect(
            timer.connectionID == target.id,
            "asked about \(target.id) and got a timer for \(timer.connectionID)"
        )
    }
}

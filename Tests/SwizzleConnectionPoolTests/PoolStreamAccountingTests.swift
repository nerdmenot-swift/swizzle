import Testing

@testable import SwizzleConnectionPool

/// Stream accounting when the numbers go the wrong way.
///
/// ## Why this is a security property, not a tidiness one
///
/// The pool tracks how many streams are available across its connections, and
/// keeps that running total by adding and subtracting as connections come and
/// go. The quantity it subtracts on a close is `maxStreams - usedStreams`.
///
/// That subtraction goes negative in two ordinary situations. A **draining**
/// connection reports a maximum of zero while its outstanding streams are still
/// counted, so the sum is `0 - n`. And a server may **lower** its stream limit
/// below what is already leased, which it is entitled to do at any point in a
/// session.
///
/// On `UInt16`, negative is not a small number. It is an arithmetic overflow
/// trap, and it takes the process down — no error, no unwinding, no chance for
/// the application to reconnect. The second case is peer-controlled, so this is
/// a server able to crash its client by revising a number downwards.
///
/// One site had the guard already; four did not. They are the same expression,
/// which is why they are now one named accessor rather than five copies.
///
/// ## The control
///
/// A saturating guard that always returned zero would pass every crash test
/// here while quietly corrupting the pool's idea of its own capacity — it would
/// stop subtracting, the running total would drift upward, and the pool would
/// eventually believe it had capacity it does not. So the last test checks the
/// arithmetic is still exact when nothing is degenerate.
@Suite("Pool stream accounting")
struct PoolStreamAccountingTests {

    /// A pool with one established connection carrying `maxStreams`.
    static func pool(
        maxStreams: UInt16, keepAlive: Duration? = nil
    ) -> (machine: TestStateMachine, connection: MockConnection) {
        var (machine, refill) = makeStateMachine(
            minimumConnections: 1, maximumSoftLimit: 2, maximumHardLimit: 2, keepAlive: keepAlive
        )
        let connection = MockConnection(id: refill[0].connectionID)
        run(machine.connectionEstablished(connection, maxStreams: maxStreams).request)
        return (machine, connection)
    }

    // MARK: - Draining reports a maximum of zero

    /// **A keep-alive failing on a draining connection.** The connection is
    /// draining, so it reports a maximum of zero while two streams are still
    /// outstanding on it; the keep-alive failure then asks the pool to subtract
    /// `0 - 2`.
    ///
    /// The sequence is ordinary: a keep-alive is in flight, work arrives, the
    /// driver notices the channel going away, and the keep-alive then fails
    /// because the connection really is gone.
    @Test("a keep-alive failing on a draining connection does not crash the process")
    func keepAliveFailureWhileDraining() {
        var (machine, connection) = Self.pool(maxStreams: 4, keepAlive: .seconds(10))
        _ = machine.connectionKeepAliveTimerTriggered(connection.id)
        lease(MockRequest(id: 1), from: &machine)
        lease(MockRequest(id: 2), from: &machine)
        _ = machine.connectionWillClose(connection.id)

        _ = machine.connectionKeepAliveFailed(connection.id)

        // And the pool is still usable rather than left with a corrupt total.
        let after = MockRequest(id: 3)
        lease(after, from: &machine)
        #expect(after.failure == nil, "the pool failed a caller after the drain")
    }

    // MARK: - A server lowering its limit

    /// **A server lowering its stream limit to zero on an idle connection whose
    /// keep-alive holds a stream.** The close then subtracts `0 - 1`.
    ///
    /// Nothing here is malformed. A server winding down legitimately tells its
    /// clients it will carry no more streams.
    @Test("closing after the server lowers the limit to zero does not crash the process")
    func closeAfterLimitLoweredToZero() {
        var (machine, connection) = Self.pool(maxStreams: 1, keepAlive: .seconds(10))
        _ = machine.connectionKeepAliveTimerTriggered(connection.id)
        _ = machine.connectionReceivedNewMaxStreamSetting(connection.id, newMaxStreamSetting: 0)

        _ = machine.connectionWillClose(connection.id)
    }

    /// **A server lowering its limit below what is already leased, then a forced
    /// shutdown.** Three streams are out and the limit becomes one, so the
    /// shutdown subtracts `1 - 3`.
    @Test("a forced shutdown after the limit drops below what is leased does not crash")
    func forceShutdownAfterLimitDropsBelowLeased() {
        var (machine, connection) = Self.pool(maxStreams: 4)
        for id in 1...3 { lease(MockRequest(id: id), from: &machine) }
        _ = machine.connectionReceivedNewMaxStreamSetting(connection.id, newMaxStreamSetting: 1)

        _ = machine.triggerForceShutdown()
        // Not `isShutdown` yet: a forced shutdown with connections still leased
        // closes them and waits for each to report back, so the pool reaches
        // `shutDown` only once the last one has. Asserting it here would be
        // asserting the pool forgets connections it has not heard from.
        run(machine.connectionClosed(connection).request)
        #expect(machine.isShutdown, "the pool finished once its last connection reported closed")
    }

    /// The same, shut down gracefully rather than forcibly — a different close
    /// path through the group, and the same subtraction underneath it.
    @Test("a graceful shutdown after the limit drops below what is leased does not crash")
    func gracefulShutdownAfterLimitDropsBelowLeased() {
        var (machine, connection) = Self.pool(maxStreams: 4)
        for id in 1...3 { lease(MockRequest(id: id), from: &machine) }
        _ = machine.connectionReceivedNewMaxStreamSetting(connection.id, newMaxStreamSetting: 1)

        _ = machine.triggerGracefulShutdown()
        run(machine.releaseConnection(connection, streams: 3).request)
    }

    /// Announcing a close on an idle connection after the limit dropped below
    /// what its keep-alive is using — the fourth of the four sites.
    @Test("announcing a close after the limit drops below the keep-alive's use does not crash")
    func announceCloseAfterLimitDropsBelowKeepAlive() {
        var (machine, connection) = Self.pool(maxStreams: 8, keepAlive: .seconds(10))
        _ = machine.connectionKeepAliveTimerTriggered(connection.id)
        _ = machine.connectionReceivedNewMaxStreamSetting(connection.id, newMaxStreamSetting: 0)
        _ = machine.connectionIdleTimerTriggered(connection.id)
        _ = machine.connectionWillClose(connection.id)
    }

    // MARK: - The control

    /// **The arithmetic is still exact when nothing is degenerate.** This is the
    /// test that stops the fix from being a lie: a guard that saturated to zero
    /// unconditionally would satisfy every case above while the pool's running
    /// total drifted upward, until it believed it had capacity it does not and
    /// handed out a connection with no room on it.
    @Test("a normal close still subtracts exactly the streams it was contributing")
    func closeSubtractsExactly() {
        var (machine, connection) = Self.pool(maxStreams: 4)
        let before = machine.connections.stats.availableStreams
        #expect(before == 4, "the premise: four streams on offer")

        lease(MockRequest(id: 1), from: &machine)
        #expect(
            machine.connections.stats.availableStreams == 3,
            "leasing one stream leaves three"
        )

        _ = machine.connectionWillClose(connection.id)
        _ = machine.connectionClosed(connection)
        #expect(
            machine.connections.stats.availableStreams == 0,
            "the closed connection took its remaining capacity with it, not less"
        )
    }

    /// And the degenerate case saturates to zero rather than wrapping to 65535 —
    /// the number the trap was protecting against. A total of 65535 available
    /// streams on a pool with no connections would have the pool hand out leases
    /// against connections that do not exist.
    @Test("a degenerate close saturates to zero rather than wrapping")
    func degenerateCloseSaturates() {
        var (machine, connection) = Self.pool(maxStreams: 4)
        for id in 1...3 { lease(MockRequest(id: id), from: &machine) }
        _ = machine.connectionReceivedNewMaxStreamSetting(connection.id, newMaxStreamSetting: 1)

        _ = machine.connectionWillClose(connection.id)
        #expect(
            machine.connections.stats.availableStreams < 100,
            "available streams wrapped to \(machine.connections.stats.availableStreams)"
        )
    }

    // MARK: - Leasing while a connection is closing

    /// **A lease arriving before a close has completed.**
    ///
    /// A connection begins closing — a keep-alive failed, or the driver reported
    /// its channel going away — and a request arrives before the socket has
    /// finished closing. That window is entirely ordinary and, on a pool at its
    /// minimum, used to take the process down.
    ///
    /// The pool held two different counts of itself. The assertion guarding
    /// connection creation read `stats.active`, which excludes closing
    /// connections; the refill that restores the minimum triggers on
    /// `connections.count`, which includes them. So for the whole window the
    /// pool was one below its minimum by the first measure with no refill under
    /// way by the second, and any lease needing a new connection asserted.
    ///
    /// Inherited from postgres-nio, which has the same assertion.
    @Test("a lease arriving while the only connection is closing does not crash")
    func leaseWhileClosing() {
        var (machine, connection) = Self.pool(maxStreams: 1, keepAlive: .seconds(10))
        _ = machine.connectionKeepAliveTimerTriggered(connection.id)
        _ = machine.connectionKeepAliveFailed(connection.id)

        let arrival = MockRequest(id: 1)
        lease(arrival, from: &machine)
        #expect(arrival.failure == nil, "the caller was failed rather than served")
    }

    /// The same window reached the other way: the driver announces the channel
    /// is going away, rather than a keep-alive discovering it.
    @Test("a lease arriving after a close is announced does not crash")
    func leaseAfterCloseAnnounced() {
        var (machine, connection) = Self.pool(maxStreams: 1)
        _ = machine.connectionWillClose(connection.id)

        let arrival = MockRequest(id: 1)
        lease(arrival, from: &machine)
        #expect(arrival.failure == nil)
    }

    /// **And the pool recovers rather than merely surviving.** Not crashing is
    /// not enough: the caller that arrived during the window has to be served,
    /// which means the pool must actually open a replacement connection while
    /// the old one is still closing.
    @Test("a caller arriving during the close window is served by a replacement")
    func callerDuringCloseWindowIsServed() {
        var (machine, connection) = Self.pool(maxStreams: 1)
        _ = machine.connectionWillClose(connection.id)

        let arrival = MockRequest(id: 1)
        let action = lease(arrival, from: &machine)
        guard case .makeConnection(let replacement, _) = action.connection else {
            Issue.record("no replacement was started for the waiting caller: \(action.connection)")
            return
        }

        let fresh = MockConnection(id: replacement.connectionID)
        run(machine.connectionEstablished(fresh, maxStreams: 1).request)
        #expect(
            arrival.leasedConnectionID == fresh.id,
            "the caller was not served by the replacement"
        )
        #expect(fresh.id != connection.id, "and it is a different connection")
    }

    /// The pool still honours its minimum once the old connection finally
    /// reports closed — the replacement takes its place rather than the pool
    /// ending up with two, or with none.
    @Test("the pool holds its minimum once the closing connection reports in")
    func minimumHeldAfterCloseCompletes() {
        var (machine, connection) = Self.pool(maxStreams: 1)
        _ = machine.connectionWillClose(connection.id)
        let action = lease(MockRequest(id: 1), from: &machine)
        guard case .makeConnection(let replacement, _) = action.connection else {
            Issue.record("no replacement was started")
            return
        }
        let fresh = MockConnection(id: replacement.connectionID)
        run(machine.connectionEstablished(fresh, maxStreams: 1).request)

        run(machine.connectionClosed(connection).request)
        #expect(
            machine.connections.stats.idle + machine.connections.stats.leased == 1,
            "the pool holds one connection, not none and not two"
        )
    }
}

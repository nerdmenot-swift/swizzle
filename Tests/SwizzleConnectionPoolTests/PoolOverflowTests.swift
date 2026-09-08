import Testing

@testable import SwizzleConnectionPool

/// Connections above the soft limit, and what happens to them.
///
/// ## The three kinds of slot
///
/// A pool has three bands of connection, and which band a connection sits in is
/// decided purely by its **index**, not by anything about the connection itself:
///
/// - below `minimumConnectionCount` — *persisted*. Kept open, never given an idle
///   timeout.
/// - up to `maximumConnectionSoftLimit` — *demand*. Parked when released, and
///   reaped once their idle timeout fires.
/// - up to `maximumConnectionHardLimit` — *overflow*. Opened only under a burst,
///   never parked, and **closed the moment they are released**.
///
/// Because the band is the index, a connection changes band when the array is
/// rearranged — which the pool does deliberately. When a connection in a lower
/// band dies, an established overflow connection is swapped into its slot rather
/// than the pool opening a fresh one. That promotion is the behaviour this suite
/// is about: without it, a burst that kills a persisted connection leaves the
/// pool below its minimum while simultaneously throwing away a perfectly good
/// connection it already has.
///
/// The promotion is visible without reading any internal state, because the
/// bands behave differently on release: a promoted connection is *parked*, and
/// one still in an overflow slot is *closed*.
@Suite("Pool overflow")
struct PoolOverflowTests {

    /// A pool of 1 persisted, 1 demand, and 2 overflow connections, all
    /// established and all leased — the state a burst leaves behind.
    ///
    /// Returned in creation order: `[0]` persisted, `[1]` demand, `[2]` and `[3]`
    /// overflow.
    static func saturated() -> (machine: TestStateMachine, connections: [MockConnection]) {
        var (machine, refill) = makeStateMachine(
            minimumConnections: 1, maximumSoftLimit: 2, maximumHardLimit: 4,
            keepAlive: .seconds(10)
        )
        let persisted = MockConnection(id: refill[0].connectionID)
        _ = machine.connectionEstablished(persisted, maxStreams: 1)

        var connections = [persisted]
        for id in 1...4 {
            let action = machine.leaseConnection(MockRequest(id: id))
            var requests: [TestStateMachine.ConnectionRequest] = []
            switch action.connection {
            case .makeConnection(let request, _):
                requests = [request]
            case .makeConnectionsCancelAndScheduleTimers(let many, _, _):
                requests = Array(many)
            default:
                break
            }
            for request in requests {
                let connection = MockConnection(id: request.connectionID)
                connections.append(connection)
                _ = machine.connectionEstablished(connection, maxStreams: 1)
            }
        }
        return (machine, connections)
    }

    /// How a release was handled, which is what distinguishes the bands.
    enum ReleaseOutcome: String {
        case parked, closed, other
    }

    static func release(
        _ connection: MockConnection, from machine: inout TestStateMachine
    ) -> ReleaseOutcome {
        switch machine.releaseConnection(connection, streams: 1).connection {
        case .scheduleTimers: return .parked
        case .closeConnection: return .closed
        default: return .other
        }
    }

    // MARK: - The bands

    /// A burst opens connections up to the hard limit and no further.
    @Test("a burst opens connections up to the hard limit")
    func burstOpensToHardLimit() {
        let (_, connections) = Self.saturated()
        #expect(connections.count == 4, "1 persisted + 1 demand + 2 overflow")
        #expect(Set(connections.map(\.id)).count == 4, "each is a distinct connection")
    }

    /// A request arriving once the hard limit is reached waits rather than
    /// opening a fifth connection — the hard limit is the promise the pool makes
    /// to the server about how many sockets it will ever hold.
    @Test("a request beyond the hard limit waits instead of opening another connection")
    func beyondHardLimitQueues() {
        var (machine, _) = Self.saturated()
        let extra = MockRequest(id: 99)
        let action = lease(extra, from: &machine)
        switch action.connection {
        case .makeConnection, .makeConnectionsCancelAndScheduleTimers:
            Issue.record("opened a connection past the hard limit")
        default:
            break
        }
        #expect(extra.result == nil, "it waits rather than being failed")
    }

    /// **An overflow connection is closed when released, not parked.** It exists
    /// only for the burst that opened it; keeping it would mean the pool's steady
    /// state creeps up to the hard limit and stays there.
    @Test("an overflow connection is closed when released")
    func overflowIsClosedOnRelease() {
        var (machine, connections) = Self.saturated()
        #expect(Self.release(connections[3], from: &machine) == .closed)
    }

    /// A demand connection released in the same pool is parked instead — the
    /// contrast that makes the check above mean something.
    @Test("a demand connection is parked when released")
    func demandIsParkedOnRelease() {
        var (machine, connections) = Self.saturated()
        #expect(Self.release(connections[1], from: &machine) == .parked)
    }

    /// An overflow connection released while a request is *waiting* goes to the
    /// waiter rather than being closed. Closing it here would hang up on a
    /// socket the queue is asking for.
    @Test("an overflow connection released with a request waiting is handed over")
    func overflowGoesToWaiterRatherThanClosing() {
        var (machine, connections) = Self.saturated()
        let waiter = MockRequest(id: 99)
        _ = machine.leaseConnection(waiter)

        let action = machine.releaseConnection(connections[3], streams: 1)
        if case .closeConnection = action.connection {
            Issue.record("closed a connection a request was waiting for")
        }
        guard case .leaseConnection(let leased, let connection) = action.request else {
            Issue.record("the waiting request was not given the released connection: \(action.request)")
            return
        }
        #expect(Array(leased) == [waiter])
        #expect(connection.id == connections[3].id)
    }

    // MARK: - Promotion

    /// **The promotion.** Closing the persisted connection swaps an established
    /// overflow connection into its slot, rather than dropping to zero persisted
    /// connections and opening a fresh one.
    ///
    /// It is checked entirely through behaviour: after the close, the promoted
    /// connection is *parked* on release because it now sits in a persisted slot,
    /// while the overflow connection that was not promoted is still *closed*. No
    /// internal state is read, so the test does not need to know how the swap is
    /// implemented — only that the connection changed band.
    @Test("closing a persisted connection promotes an overflow connection into its slot")
    func closingPersistedPromotesOverflow() {
        var (machine, connections) = Self.saturated()
        _ = machine.connectionClosed(connections[0])

        #expect(
            Self.release(connections[3], from: &machine) == .parked,
            "the last overflow connection was promoted into the freed persisted slot"
        )
        #expect(
            Self.release(connections[2], from: &machine) == .closed,
            "the other overflow connection was not promoted, and is still discarded"
        )
        #expect(
            Self.release(connections[1], from: &machine) == .parked,
            "the demand connection is unaffected"
        )
    }

    /// The promotion happens when the close is **announced**, not when it
    /// completes. The gap matters: between announcing and completing, the pool is
    /// still serving requests, and a connection it has already written off should
    /// not be handed to one of them.
    @Test("announcing a close promotes an overflow connection immediately")
    func announcingCloseOfIdlePersistedPromotesEarly() {
        var (machine, connections) = Self.saturated()

        // Park the persisted connection so announcing its close actually closes
        // it, rather than draining it behind an outstanding lease.
        #expect(Self.release(connections[0], from: &machine) == .parked)

        let action = machine.connectionWillClose(connections[0].id)
        guard case .closeConnection(let closing, _) = action.connection else {
            Issue.record("an idle connection told to close should close, got \(action.connection)")
            return
        }
        #expect(closing.id == connections[0].id)

        // **The two promotion paths do not pick the same connection.** This one
        // takes the *first* established overflow connection; the one that runs
        // when a close completes takes the *last*. Both are defensible — either
        // end of the overflow band is as good as the other — but they are
        // different lines of code with different search directions, so a test
        // that assumed one order would pass here and fail there for reasons
        // that look like a bug in the pool rather than in the test. My first
        // version of this one did exactly that.
        #expect(
            Self.release(connections[2], from: &machine) == .parked,
            "the first established overflow connection was promoted at announcement"
        )
        #expect(
            Self.release(connections[3], from: &machine) == .closed,
            "the last one was not, and is still discarded"
        )
    }

    /// A close announced for a connection the pool has already forgotten is
    /// ignored. This one comes off the wire — a channel reporting its own death
    /// — so it must tolerate arriving twice or late.
    @Test("announcing a close for an unknown connection does nothing")
    func announcingCloseOfUnknownConnection() {
        var (machine, connections) = Self.saturated()
        _ = machine.connectionClosed(connections[0])
        let action = machine.connectionWillClose(connections[0].id)
        if case .closeConnection = action.connection {
            Issue.record("closed a connection the pool had already dropped")
        }
    }

    /// A leased connection told to close drains rather than closing — the query
    /// on it finishes first.
    @Test("announcing a close for a leased connection drains it")
    func announcingCloseOfLeasedConnectionDrains() {
        var (machine, connections) = Self.saturated()
        let action = machine.connectionWillClose(connections[1].id)
        if case .closeConnection = action.connection {
            Issue.record("closed a connection with a query still on it")
        }

        // And the close lands once the lease comes back.
        guard case .closeConnection(let closing, _) = machine.releaseConnection(connections[1], streams: 1).connection else {
            Issue.record("the drained connection was not closed once its lease came back")
            return
        }
        #expect(closing.id == connections[1].id)
    }

    // MARK: - Keep-alive failure

    /// A keep-alive failing on a leased connection closes it. The pool cannot
    /// wait for the lease to end — the keep-alive failing *is* the evidence the
    /// connection is gone, so the query on it is already lost.
    @Test("a failed keep-alive closes a leased connection")
    func keepAliveFailureClosesLeasedConnection() {
        var (machine, connections) = Self.saturated()
        let action = machine.connectionKeepAliveFailed(connections[1].id)
        guard case .closeConnection(let closing, _) = action.connection else {
            Issue.record("a failed keep-alive should close, got \(action.connection)")
            return
        }
        #expect(closing.id == connections[1].id)
    }

    /// A keep-alive failing for a connection the pool has already dropped is a
    /// no-op rather than a second close.
    @Test("a failed keep-alive for an unknown connection does nothing")
    func keepAliveFailureForUnknownConnection() {
        var (machine, connections) = Self.saturated()
        _ = machine.connectionClosed(connections[1])
        let action = machine.connectionKeepAliveFailed(connections[1].id)
        if case .closeConnection = action.connection {
            Issue.record("closed a connection the pool had already dropped")
        }
    }

    /// Closing an overflow connection does not promote anything into a lower
    /// band — there is nothing above it to promote.
    @Test("closing an overflow connection leaves the other bands alone")
    func closingOverflowChangesNothing() {
        var (machine, connections) = Self.saturated()
        _ = machine.connectionClosed(connections[3])

        #expect(Self.release(connections[0], from: &machine) == .parked, "still persisted")
        #expect(Self.release(connections[1], from: &machine) == .parked, "still demand")
        #expect(Self.release(connections[2], from: &machine) == .closed, "still overflow")
    }
}

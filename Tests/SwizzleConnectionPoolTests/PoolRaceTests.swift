import Testing

@testable import SwizzleConnectionPool

/// Events that arrive for a connection the pool has already let go.
///
/// ## Why these are not the same as "an unknown id"
///
/// The pool arms timers and starts keep-alives against connections it owns. A
/// connection can die between arming and firing — the socket drops, the server
/// restarts, a shutdown runs — and the event is already in flight by then. The
/// vendored source marks several of these arms with a comment saying exactly
/// that: *because of a race this connection was already removed from the state
/// machine*.
///
/// So these are not defensive checks against a caller passing rubbish. They are
/// the ordinary consequence of a pool that does I/O, and each one has to be a
/// no-op rather than a trap, because the alternative is a driver that crashes
/// when a database restarts under load — which is precisely when nobody can
/// afford it.
///
/// They are worth writing down for a second reason: several *neighbouring*
/// entry points deliberately do the opposite and trap on an id they do not
/// recognise, because those are driven by the pool's own bookkeeping rather
/// than by the network. Which is which is not obvious from the signatures, and
/// the difference is the whole safety argument.
@Suite("Pool races")
struct PoolRaceTests {

    /// A pool with one established connection, and that connection.
    static func established(
        keepAlive: Duration? = .seconds(10)
    ) -> (machine: TestStateMachine, connection: MockConnection) {
        var (machine, refill) = makeStateMachine(
            minimumConnections: 1, maximumSoftLimit: 2, maximumHardLimit: 2,
            keepAlive: keepAlive
        )
        let connection = MockConnection(id: refill[0].connectionID)
        run(machine.connectionEstablished(connection, maxStreams: 1).request)
        return (machine, connection)
    }

    // MARK: - Keep-alive against a connection that has gone

    /// A keep-alive timer firing after the connection closed does nothing. The
    /// timer was armed while the connection was healthy; the close happened in
    /// between.
    @Test("a keep-alive timer firing after the connection closed does nothing")
    func keepAliveTimerAfterClose() {
        var (machine, connection) = Self.established()
        _ = machine.connectionClosed(connection)

        let action = machine.connectionKeepAliveTimerTriggered(connection.id)
        if case .runKeepAlive = action.connection {
            Issue.record("started a keep-alive on a connection that had closed")
        }
    }

    /// A keep-alive *succeeding* for a connection that has since closed does
    /// nothing either. This is the narrower race: the keep-alive query was in
    /// flight and came back after the socket died.
    @Test("a keep-alive succeeding after the connection closed does nothing")
    func keepAliveDoneAfterClose() {
        var (machine, connection) = Self.established()
        _ = machine.connectionKeepAliveTimerTriggered(connection.id)
        _ = machine.connectionClosed(connection)

        let action = machine.connectionKeepAliveDone(connection)
        if case .closeConnection = action.connection {
            Issue.record("closed a connection that was already gone")
        }
        if case .leaseConnection = action.request {
            Issue.record("leased out a connection that was already gone")
        }
    }

    /// A keep-alive succeeding on a connection that is being closed reports
    /// nothing available — the connection is on its way out and its capacity
    /// must not be offered to a waiter.
    @Test("a keep-alive succeeding on a closing connection offers no capacity")
    func keepAliveDoneWhileClosing() {
        var (machine, connection) = Self.established()
        _ = machine.connectionKeepAliveTimerTriggered(connection.id)
        _ = machine.connectionWillClose(connection.id)

        let action = machine.connectionKeepAliveDone(connection)
        if case .leaseConnection = action.request {
            Issue.record("offered a closing connection to a waiter")
        }
    }

    /// A keep-alive *failing* after the connection has gone is a no-op rather
    /// than a second close.
    @Test("a keep-alive failing after the connection closed does nothing")
    func keepAliveFailedAfterClose() {
        var (machine, connection) = Self.established()
        _ = machine.connectionClosed(connection)

        let action = machine.connectionKeepAliveFailed(connection.id)
        if case .closeConnection = action.connection {
            Issue.record("closed a connection that was already gone")
        }
    }

    // MARK: - Timers against a connection that has gone

    /// An idle timer firing after the connection closed does nothing.
    @Test("an idle timer firing after the connection closed does nothing")
    func idleTimerAfterClose() {
        var (machine, connection) = Self.established()
        _ = machine.connectionClosed(connection)

        let action = machine.connectionIdleTimerTriggered(connection.id)
        if case .closeConnection = action.connection {
            Issue.record("closed a connection that was already gone")
        }
    }

    /// A timer registration arriving for a connection that has gone hands the
    /// cancellation token straight back, so the caller cancels the timer rather
    /// than leaving it armed against nothing.
    @Test("a timer registration for a departed connection is handed back")
    func timerRegistrationAfterClose() {
        var (machine, connection) = Self.established()
        let timer = TestStateMachine.Timer(
            .init(timerID: 0, connectionID: connection.id, usecase: .idleTimeout),
            duration: .seconds(1)
        )
        _ = machine.connectionClosed(connection)

        #expect(
            machine.timerScheduled(timer, cancelContinuation: 5) == 5,
            "the token must come back so the timer is cancelled rather than orphaned"
        )
    }

    // MARK: - Stream settings against a connection that has gone

    /// A new max-stream setting for a connection that has closed is ignored. The
    /// setting arrives on the wire, so it can be in flight when the socket dies.
    @Test("a new max stream setting for a departed connection is ignored")
    func maxStreamSettingAfterClose() {
        var (machine, connection) = Self.established()
        _ = machine.connectionClosed(connection)

        let action = machine.connectionReceivedNewMaxStreamSetting(
            connection.id, newMaxStreamSetting: 8
        )
        if case .leaseConnection = action.request {
            Issue.record("leased out capacity on a connection that had gone")
        }
    }

    /// A new setting on a *live* connection does take effect, which is what
    /// makes the check above meaningful rather than vacuous.
    @Test("a new max stream setting on a live connection frees capacity for a waiter")
    func maxStreamSettingOnLiveConnection() {
        var (machine, connection) = Self.established()
        // Take its only stream, then queue behind it.
        lease(MockRequest(id: 1), from: &machine)
        let queued = MockRequest(id: 2)
        lease(queued, from: &machine)

        let action = machine.connectionReceivedNewMaxStreamSetting(
            connection.id, newMaxStreamSetting: 4
        )
        run(action.request)
        #expect(
            queued.leasedConnectionID == connection.id,
            "the extra capacity went to the request already waiting for it"
        )
    }

    // MARK: - Closing twice

    /// Not tested: the same connection reporting closed twice.
    ///
    /// It traps -- "All connections that have been created should say goodbye
    /// exactly once". That is the line between the two kinds of entry point
    /// this suite is about. Everything above tolerates a late event because the
    /// event comes off the wire and the pool cannot control how many times a
    /// peer reports something. This one is called by the pool itself, once, from
    /// its own close handler, and the assertion is load-bearing: a connection
    /// counted as gone twice corrupts the pool's accounting of how many it has.
    ///
    /// Asserting tolerance here would invent a contract the type does not offer
    /// and disarm a check that is doing real work.


    /// A close announced for a connection that has already reported closed is
    /// likewise a no-op — the announcement and the completion can cross.
    @Test("announcing a close after the connection reported closed does nothing")
    func willCloseAfterClosed() {
        var (machine, connection) = Self.established()
        _ = machine.connectionClosed(connection)
        let action = machine.connectionWillClose(connection.id)
        if case .closeConnection = action.connection {
            Issue.record("closed a connection that had already reported closed")
        }
    }

    /// Releasing a connection that has already reported closed does not hand it
    /// to a waiter. The lease and the close can cross: the query finished at the
    /// same moment the socket died.
    @Test("releasing a connection that already reported closed serves nobody")
    func releaseAfterClosed() {
        var (machine, connection) = Self.established()
        lease(MockRequest(id: 1), from: &machine)
        _ = machine.connectionClosed(connection)

        let waiter = MockRequest(id: 2)
        lease(waiter, from: &machine)
        run(machine.releaseConnection(connection, streams: 1).request)

        #expect(
            waiter.leasedConnectionID == nil,
            "a dead connection was handed to a waiting request"
        )
    }
}

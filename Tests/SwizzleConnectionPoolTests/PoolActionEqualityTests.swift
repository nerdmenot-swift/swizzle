import Testing

@testable import SwizzleConnectionPool

/// Comparing two `ConnectionAction`s, which is hand-written rather than
/// synthesised and carries a deliberate equivalence in it.
///
/// ## Why a hand-written `==` needs its own tests
///
/// The compiler cannot synthesise this one — connections are compared by
/// **identity** rather than value, so the conformance is written by hand, and
/// hand-written equality is the sort of thing that silently degrades into "the
/// cases match" without comparing the payloads.
///
/// It also encodes a decision that is not obvious from the type: an action that
/// cancels *no* timers is considered equal to no action at all, and likewise for
/// scheduling none. That is defensible — both mean "the caller has nothing to
/// do" — but it is a choice, and a test that compares actions is quietly relying
/// on it. If it changed, every such test would change meaning without changing
/// text.
///
/// Nothing compared actions before this: the state machine suites all pattern
/// match, so the whole conformance was dead in test terms while shipping in the
/// module.
@Suite("Pool action equality")
struct PoolActionEqualityTests {

    typealias Action = TestStateMachine.ConnectionAction

    static func connection(_ id: Int) -> MockConnection { MockConnection(id: id) }
    static func request(_ id: Int) -> TestStateMachine.ConnectionRequest {
        TestStateMachine.ConnectionRequest(connectionID: id)
    }

    // MARK: - The empty/none equivalence

    /// **The decision this conformance encodes.** Cancelling nothing and
    /// scheduling nothing both mean "no work", so they compare equal to
    /// `.none` — in both directions, since equality must be symmetric.
    @Test("an action carrying no timers equals no action at all")
    func emptyTimerActionsEqualNone() {
        #expect(Action.cancelTimers([]) == Action.none)
        #expect(Action.none == Action.cancelTimers([]))
        #expect(Action.scheduleTimers([]) == Action.none)
        #expect(Action.none == Action.scheduleTimers([]))
        #expect(Action.none == Action.none)
    }

    /// But an action carrying an actual timer is not nothing, which is the half
    /// that would make the equivalence dangerous if it were wrong.
    @Test("an action carrying a timer does not equal no action")
    func nonEmptyTimerActionsDifferFromNone() {
        let timer = TestStateMachine.Timer(
            .init(timerID: 0, connectionID: 1, usecase: .keepAlive), duration: .seconds(1)
        )
        #expect(Action.scheduleTimers([timer]) != Action.none)
        #expect(Action.none != Action.scheduleTimers([timer]))
        #expect(Action.cancelTimers([7]) != Action.none)
        #expect(Action.none != Action.cancelTimers([7]))
    }

    // MARK: - Payloads actually compared

    /// Same case, different payload, must not be equal — the failure mode of a
    /// hand-written `==` that only switches on the case.
    @Test("the same case with different payloads is not equal")
    func differentPayloadsDiffer() {
        #expect(Action.cancelTimers([1]) != Action.cancelTimers([2]))
        #expect(Action.cancelEventStreamAndFinalCleanup([1]) != .cancelEventStreamAndFinalCleanup([2]))
        #expect(Action.makeConnection(Self.request(1), []) != .makeConnection(Self.request(2), []))
        #expect(Action.makeConnection(Self.request(1), [1]) != .makeConnection(Self.request(1), [2]))
    }

    @Test("the same case with the same payload is equal")
    func samePayloadsMatch() {
        #expect(Action.cancelTimers([1, 2]) == Action.cancelTimers([1, 2]))
        #expect(Action.makeConnection(Self.request(1), [9]) == .makeConnection(Self.request(1), [9]))
        #expect(
            Action.cancelEventStreamAndFinalCleanup([3])
                == .cancelEventStreamAndFinalCleanup([3])
        )
    }

    /// Connections compare by **identity**, not by id — two distinct objects
    /// that happen to share an id are different connections, and treating them
    /// as one would let a test pass while the pool closed the wrong socket.
    @Test("connections in an action compare by identity, not by id")
    func connectionsCompareByIdentity() {
        let first = Self.connection(1)
        let twin = Self.connection(1)  // same id, different object

        #expect(Action.closeConnection(first, []) == Action.closeConnection(first, []))
        #expect(Action.closeConnection(first, []) != Action.closeConnection(twin, []))
        #expect(Action.runKeepAlive(first, nil) == Action.runKeepAlive(first, nil))
        #expect(Action.runKeepAlive(first, nil) != Action.runKeepAlive(twin, nil))
        // And the token beside it still counts.
        #expect(Action.runKeepAlive(first, 1) != Action.runKeepAlive(first, 2))
    }

    /// Different cases are never equal, whatever they carry.
    @Test("different cases are not equal")
    func differentCasesDiffer() {
        let connection = Self.connection(1)
        let cases: [Action] = [
            .cancelTimers([1]),
            .makeConnection(Self.request(1), []),
            .runKeepAlive(connection, nil),
            .closeConnection(connection, []),
            .cancelEventStreamAndFinalCleanup([1]),
            .none,
        ]
        for (index, lhs) in cases.enumerated() {
            for (otherIndex, rhs) in cases.enumerated() where index != otherIndex {
                #expect(lhs != rhs, "\(lhs) should not equal \(rhs)")
            }
        }
    }

    /// Shutdown compares its connections as a **set of ids**, not by identity
    /// and not in order — which is a third rule inside the same conformance and
    /// worth writing down, because it is the opposite of the one above.
    ///
    /// It is the right rule here: shutdown closes all of them, so the order it
    /// lists them in carries no meaning, and two handles to the same connection
    /// id are the same connection to close. But the outer cases use `===`, and a
    /// reader who checked only those would guess wrong. My first version of this
    /// test did.
    @Test("a shutdown action compares its connections as a set of ids")
    func shutdownEquality() {
        let empty = Action.Shutdown()
        #expect(Action.initiateShutdown(empty) == Action.initiateShutdown(Action.Shutdown()))

        var withTimer = Action.Shutdown()
        withTimer.timersToCancel = [5]
        #expect(Action.initiateShutdown(empty) != Action.initiateShutdown(withTimer))

        var one = Action.Shutdown()
        one.connections = [Self.connection(1)]
        var sameIdDifferentObject = Action.Shutdown()
        sameIdDifferentObject.connections = [Self.connection(1)]
        #expect(
            Action.initiateShutdown(one) == Action.initiateShutdown(sameIdDifferentObject),
            "by id, so two handles to connection 1 are the same connection to close"
        )

        var ordered = Action.Shutdown()
        ordered.connections = [Self.connection(1), Self.connection(2)]
        var reversed = Action.Shutdown()
        reversed.connections = [Self.connection(2), Self.connection(1)]
        #expect(
            Action.initiateShutdown(ordered) == Action.initiateShutdown(reversed),
            "a set, so the order shutdown lists them in carries no meaning"
        )

        var different = Action.Shutdown()
        different.connections = [Self.connection(3)]
        #expect(Action.initiateShutdown(one) != Action.initiateShutdown(different))
    }

    /// `RequestAction` is the third hand-written rule: requests compare by id
    /// **in order**, and the connection they are leased by identity.
    @Test("a lease action compares its requests in order and its connection by identity")
    func requestActionEquality() {
        typealias RequestAction = TestStateMachine.RequestAction
        let connection = Self.connection(1)
        let twin = Self.connection(1)

        let one = MockRequest(id: 1)
        let two = MockRequest(id: 2)

        #expect(
            RequestAction.leaseConnection([one], connection)
                == RequestAction.leaseConnection([one], connection)
        )
        #expect(
            RequestAction.leaseConnection([one], connection)
                != RequestAction.leaseConnection([one], twin),
            "the connection is compared by identity here, unlike in a shutdown"
        )
        #expect(
            RequestAction.leaseConnection([one, two], connection)
                != RequestAction.leaseConnection([two, one], connection),
            "requests are compared in order, unlike a shutdown's connections"
        )
        #expect(
            RequestAction.leaseConnection([one], connection)
                != RequestAction.leaseConnection([one, two], connection),
            "a differing count is a difference"
        )
        #expect(RequestAction.none == RequestAction.none)
        #expect(RequestAction.leaseConnection([one], connection) != RequestAction.none)
    }

    /// Equality must be reflexive for every case, which is the property a
    /// `default: return false` arm can quietly break for a case somebody forgot
    /// to list.
    @Test("every case equals itself")
    func reflexive() {
        let connection = Self.connection(1)
        let timer = TestStateMachine.Timer(
            .init(timerID: 0, connectionID: 1, usecase: .idleTimeout), duration: .seconds(1)
        )
        var shutdown = Action.Shutdown()
        shutdown.connections = [connection]

        let cases: [Action] = [
            .scheduleTimers([timer]),
            .makeConnection(Self.request(1), [1]),
            .makeConnectionsCancelAndScheduleTimers([Self.request(1)], [1], [timer]),
            .runKeepAlive(connection, 1),
            .cancelTimers([1]),
            .closeConnection(connection, [1]),
            .initiateShutdown(shutdown),
            .cancelEventStreamAndFinalCleanup([1]),
            .none,
        ]
        for action in cases {
            #expect(action == action, "\(action) does not equal itself")
        }
    }
}

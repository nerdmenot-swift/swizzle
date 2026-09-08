import Testing

@testable import SwizzleConnectionPool

/// The per-connection state machine, driven directly.
///
/// ## Why this level
///
/// `ConnectionState` is where a single connection's lifecycle actually lives:
/// starting, backing off, idle, leased, draining, closing, closed — crossed with
/// whether a keep-alive is scheduled or running and whether an idle timer is
/// armed. The pool-level suites reach it through `PoolStateMachine`, which can
/// only produce the combinations the pool happens to ask for. Several of the
/// interesting ones sit behind a specific interleaving — a keep-alive that is
/// still running when the connection is released, a timer registration that
/// arrives after the timer it names has been replaced — and are far easier to
/// state here than to arrange from outside.
///
/// It is also where the timers are *named*, which is how the bug below was
/// visible at all.
@Suite("Connection state")
struct ConnectionStateTests {

    typealias State = TestStateMachine.ConnectionState

    /// A connection that has finished starting and is idle with `maxStreams`.
    static func connected(maxStreams: UInt16 = 2) -> (State, MockConnection) {
        var state = State(id: 1)
        let connection = MockConnection(id: 1)
        _ = state.connected(connection, maxStreams: maxStreams)
        return (state, connection)
    }

    // MARK: - The idle timer that was labelled a keep-alive

    /// **A connection released while its keep-alive is still running gets an
    /// idle timer labelled `.keepAlive`.**
    ///
    /// The timer is stored in the idle-timer slot and behaves as an idle timer
    /// in every respect except its `usecase`, which is what the pool routes on.
    /// Three things follow from the wrong label, and the next test pins the one
    /// that matters:
    ///
    /// - `mapTimers` gives it `keepAliveDuration` instead of
    ///   `idleTimeoutDuration`, so it is armed for the wrong interval;
    /// - `timerScheduled` looks for a *keep-alive* timer to attach the
    ///   cancellation token to, does not find one with a matching id, and hands
    ///   the token back — which the pool reads as "stale, cancel it";
    /// - and if it ever did fire, `timerTriggered` would route it to
    ///   `connectionKeepAliveTimerTriggered`, where `runKeepAliveIfIdle` on a
    ///   connection whose keep-alive is already running is a
    ///   `preconditionFailure`.
    ///
    /// The reachable path is ordinary: keep-alive fires while the connection is
    /// leased, the query finishes, the connection is released and re-parked. The
    /// arm that handles a *fresh* connection labels its timer correctly, which is
    /// why this survived — the first park of every connection is right, and only
    /// re-parks in this one window are wrong.
    @Test("an idle timeout armed while a keep-alive is running is labelled an idle timeout")
    func idleTimerParkedDuringKeepAliveIsLabelled() {
        var (state, _) = Self.connected()
        _ = state.parkConnection(scheduleKeepAliveTimer: true, scheduleIdleTimeoutTimer: false)
        _ = state.runKeepAliveIfIdle(reducesAvailableStreams: false)

        // Leased and released with the keep-alive still in flight, which is what
        // puts the connection back in the pool's hands as newly idle.
        _ = state.lease(streams: 1)
        _ = state.release(streams: 1)

        let timers = Array(
            state.parkConnection(scheduleKeepAliveTimer: true, scheduleIdleTimeoutTimer: true)
        )
        #expect(timers.count == 1, "one timer, the idle timeout")
        #expect(
            timers.first?.usecase == .idleTimeout,
            "an idle timeout labelled \(timers.first?.usecase as Any) is routed as a keep-alive"
        )
    }

    /// **The consequence**: the pool cancels the timer it has just scheduled.
    ///
    /// `timerScheduled` is how the pool hands back a cancellation token for a
    /// timer it has armed. Returning the token means "this registration is for a
    /// timer I no longer have — cancel it". With the wrong label, the lookup goes
    /// down the keep-alive branch, finds a keep-alive that is running rather than
    /// one with a matching id, and returns the token. The idle timeout is
    /// therefore disarmed the moment it is armed, and the connection never times
    /// out.
    @Test("the idle timer armed during a keep-alive can be registered, not bounced")
    func idleTimerParkedDuringKeepAliveRegisters() {
        var (state, _) = Self.connected()
        _ = state.parkConnection(scheduleKeepAliveTimer: true, scheduleIdleTimeoutTimer: false)
        _ = state.runKeepAliveIfIdle(reducesAvailableStreams: false)
        _ = state.lease(streams: 1)
        _ = state.release(streams: 1)

        guard let timer = Array(
            state.parkConnection(scheduleKeepAliveTimer: true, scheduleIdleTimeoutTimer: true)
        ).first else {
            Issue.record("no timer was armed")
            return
        }

        #expect(
            state.timerScheduled(timer, cancelContinuation: 99) == nil,
            "the token came back, so the pool cancels the idle timeout it just armed"
        )
    }

    // MARK: - Parking

    /// A fresh connection asked for both timers gets both, named correctly.
    @Test("parking a fresh connection arms both timers")
    func parkFreshWithBothTimers() {
        var (state, _) = Self.connected()
        let timers = Array(
            state.parkConnection(scheduleKeepAliveTimer: true, scheduleIdleTimeoutTimer: true)
        )
        #expect(timers.count == 2)
        #expect(timers.contains { $0.usecase == .keepAlive })
        #expect(timers.contains { $0.usecase == .idleTimeout })
        #expect(timers.allSatisfy { $0.connectionID == 1 })
        #expect(
            Set(timers.map(\.timerID)).count == 2,
            "two timers sharing an id would cancel each other"
        )
    }

    /// A minimum connection is parked without an idle timeout — it is meant to
    /// stay. Asking for neither timer must still leave it idle rather than
    /// arming something.
    @Test("parking with no timers requested arms nothing")
    func parkWithNoTimers() {
        var (state, _) = Self.connected()
        let timers = Array(
            state.parkConnection(scheduleKeepAliveTimer: false, scheduleIdleTimeoutTimer: false)
        )
        #expect(timers.isEmpty)
        #expect(state.isIdle)
        #expect(state.isAvailable)
    }

    /// Re-parking a connection that already has an idle timer must not arm a
    /// second one — two idle timers for one connection means the second fires
    /// against a connection the first already closed.
    @Test("re-parking a connection that already has an idle timer arms only a keep-alive")
    func reparkWithExistingIdleTimer() {
        var (state, _) = Self.connected()
        _ = state.parkConnection(scheduleKeepAliveTimer: false, scheduleIdleTimeoutTimer: true)
        let timers = Array(
            state.parkConnection(scheduleKeepAliveTimer: true, scheduleIdleTimeoutTimer: false)
        )
        #expect(timers.count == 1)
        #expect(timers.first?.usecase == .keepAlive)
    }

    // MARK: - Rescheduling the idle timer

    /// Rescheduling hands back the **old** timer's cancellation token along with
    /// the new timer. Losing that token leaves the old timer armed, and it fires
    /// later against a connection that has since been leased.
    @Test("rescheduling the idle timer returns the replaced timer's token")
    func rescheduleReturnsOldToken() {
        var (state, _) = Self.connected()
        guard let first = Array(
            state.parkConnection(scheduleKeepAliveTimer: false, scheduleIdleTimeoutTimer: true)
        ).first else {
            Issue.record("no idle timer armed")
            return
        }
        #expect(state.timerScheduled(first, cancelContinuation: 42) == nil)

        guard let (replacement, oldToken) = state.rescheduleIdleTimer() else {
            Issue.record("rescheduling an armed idle timer returned nil")
            return
        }
        #expect(replacement.usecase == .idleTimeout)
        #expect(replacement.timerID != first.timerID, "a reused id cancels the wrong timer")
        #expect(oldToken == 42, "without the old token the replaced timer stays armed")
    }

    /// With no idle timer armed there is nothing to reschedule, and the caller
    /// is told so rather than being handed a timer it did not ask for.
    @Test("rescheduling with no idle timer armed returns nil")
    func rescheduleWithoutTimer() {
        var (state, _) = Self.connected()
        _ = state.parkConnection(scheduleKeepAliveTimer: false, scheduleIdleTimeoutTimer: false)
        #expect(state.rescheduleIdleTimer() == nil)
    }

    /// And a leased connection has no idle timer by definition.
    @Test("rescheduling a leased connection returns nil")
    func rescheduleWhileLeased() {
        var (state, _) = Self.connected()
        _ = state.lease(streams: 1)
        #expect(state.rescheduleIdleTimer() == nil)
    }

    // MARK: - Stale timer registrations

    /// A registration naming a timer that has since been replaced is bounced —
    /// the token comes straight back so the caller cancels it. This is the
    /// mechanism that stops a superseded idle timer from closing a live
    /// connection, and it is what the mislabelled timer above trips by accident.
    @Test("a registration for a superseded timer is handed straight back")
    func staleRegistrationBounces() {
        var (state, _) = Self.connected()
        guard let first = Array(
            state.parkConnection(scheduleKeepAliveTimer: false, scheduleIdleTimeoutTimer: true)
        ).first else {
            Issue.record("no idle timer armed")
            return
        }
        _ = state.rescheduleIdleTimer()  // `first` is now superseded
        #expect(
            state.timerScheduled(first, cancelContinuation: 7) == 7,
            "a superseded timer must be cancelled, not registered"
        )
    }

    /// A backoff registration arriving for a connection that is no longer
    /// backing off is likewise bounced.
    @Test("a backoff registration for a connection that is no longer backing off is bounced")
    func staleBackoffRegistration() {
        var state = State(id: 1)
        let backoff = state.failedToConnect()
        _ = state.retryConnect()  // back to .starting; the backoff is over
        #expect(state.timerScheduled(backoff, cancelContinuation: 3) == 3)
    }

    /// A keep-alive registration for a connection that is idle with no keep-alive
    /// scheduled is bounced rather than registered against nothing.
    @Test("a keep-alive registration with no keep-alive scheduled is bounced")
    func staleKeepAliveRegistration() {
        var (state, _) = Self.connected()
        guard let keepAlive = Array(
            state.parkConnection(scheduleKeepAliveTimer: true, scheduleIdleTimeoutTimer: false)
        ).first else {
            Issue.record("no keep-alive armed")
            return
        }
        _ = state.runKeepAliveIfIdle(reducesAvailableStreams: false)  // now .running, not .scheduled
        #expect(state.timerScheduled(keepAlive, cancelContinuation: 5) == 5)
    }

    // MARK: - Backoff

    /// Destroying a backing-off connection must hand back its backoff token. The
    /// pool destroys redundant connections during an outage, and a backoff timer
    /// left armed fires afterwards against an id the pool has forgotten — which
    /// is the `Failing a connection we don't have a record of` trap.
    @Test("destroying a backing-off connection returns its backoff token")
    func destroyBackingOffReturnsToken() {
        var state = State(id: 1)
        let backoff = state.failedToConnect()
        #expect(state.timerScheduled(backoff, cancelContinuation: 11) == nil)
        #expect(state.destroyBackingOffConnection() == 11)
        #expect(state.isClosed)
    }

    /// With no token ever registered there is nothing to hand back, and the
    /// connection still ends up closed.
    @Test("destroying a backing-off connection with no registered timer still closes it")
    func destroyBackingOffWithoutToken() {
        var state = State(id: 1)
        _ = state.failedToConnect()
        #expect(state.destroyBackingOffConnection() == nil)
        #expect(state.isClosed)
    }

    // MARK: - Releasing

    /// **A release that frees a stream but leaves none available returns
    /// `.none`.** That happens when the server lowered its stream limit while
    /// the connection was leased: streams come back, but the new maximum is
    /// already at or below what is still in use, so there is nothing to offer a
    /// waiter. Reporting availability here would hand a waiter a connection with
    /// no room on it.
    @Test("a release that frees no capacity reports nothing available")
    func releaseWithoutCapacity() {
        var (state, _) = Self.connected(maxStreams: 4)
        _ = state.lease(streams: 3)
        _ = state.newMaxStreamSetting(2)  // the server lowered it mid-lease
        #expect(state.release(streams: 1) == .none)
        #expect(state.isLeased)
    }

    /// A partial release that does leave capacity reports it, and the connection
    /// stays leased rather than being handed back as idle.
    @Test("a partial release reports the remaining capacity and stays leased")
    func partialRelease() {
        var (state, _) = Self.connected(maxStreams: 4)
        _ = state.lease(streams: 3)
        #expect(state.release(streams: 1) == .available(.leased(availableStreams: 2)))
        #expect(state.isLeased)
    }

    /// The last stream coming back makes the connection newly idle, which is the
    /// flag the pool uses to decide whether to arm an idle timeout.
    @Test("releasing the last stream reports the connection as newly idle")
    func fullRelease() {
        var (state, _) = Self.connected(maxStreams: 4)
        _ = state.lease(streams: 2)
        #expect(state.release(streams: 2) == .available(.idle(availableStreams: 4, newIdle: true)))
        #expect(state.isIdle)
    }

    /// A draining connection releasing its last stream is complete and can be
    /// closed — a different outcome from the same call on a leased one.
    @Test("the last release on a draining connection completes the drain")
    func drainingRelease() {
        var (state, connection) = Self.connected(maxStreams: 4)
        _ = state.lease(streams: 2)
        guard case .markedForClose(let available, let keepAliveWasRunning) = state.markForClose() else {
            Issue.record("a leased connection should be marked for close, not closed outright")
            return
        }
        #expect(available == 2)
        #expect(!keepAliveWasRunning)
        #expect(state.isDraining)
        #expect(state.release(streams: 1) == .none, "still draining with one stream out")
        #expect(state.release(streams: 1) == .drainingComplete(connection))
    }

    // MARK: - isIdle, which is not "the state is idle"

    /// **A connection running a keep-alive is not idle**, even though its state
    /// is `.idle`. The distinction is what stops the pool closing a connection
    /// out from under a keep-alive query it is in the middle of running.
    @Test("a connection running a keep-alive does not report itself idle")
    func runningKeepAliveIsNotIdle() {
        var (state, _) = Self.connected()
        _ = state.parkConnection(scheduleKeepAliveTimer: true, scheduleIdleTimeoutTimer: false)
        #expect(state.isIdle, "scheduled, not yet running")

        _ = state.runKeepAliveIfIdle(reducesAvailableStreams: false)
        #expect(!state.isIdle, "a keep-alive is in flight on it")
        #expect(state.isConnected, "but it is still a live connection")
    }

    /// A keep-alive that consumes a stream reduces what the connection can
    /// offer, so a single-stream connection has nothing left while it runs.
    @Test("a stream-consuming keep-alive uses up a single-stream connection")
    func keepAliveConsumingTheOnlyStream() {
        var (state, _) = Self.connected(maxStreams: 1)
        _ = state.parkConnection(scheduleKeepAliveTimer: true, scheduleIdleTimeoutTimer: false)
        _ = state.runKeepAliveIfIdle(reducesAvailableStreams: true)
        #expect(!state.isAvailable, "its only stream is carrying the keep-alive")

        #expect(state.keepAliveSucceeded() == .idle(availableStreams: 1, newIdle: false))
        #expect(state.isAvailable)
        #expect(state.isIdle)
    }

    /// A keep-alive running on a leased connection reports leased capacity when
    /// it finishes, not idle — the lease is still outstanding.
    @Test("a keep-alive finishing on a leased connection reports leased capacity")
    func keepAliveSucceededWhileLeased() {
        var (state, _) = Self.connected(maxStreams: 4)
        _ = state.parkConnection(scheduleKeepAliveTimer: true, scheduleIdleTimeoutTimer: false)
        _ = state.runKeepAliveIfIdle(reducesAvailableStreams: false)
        _ = state.lease(streams: 1)
        #expect(state.keepAliveSucceeded() == .leased(availableStreams: 3))
        #expect(state.isLeased)
    }

    /// On a closing connection there is nothing left to report.
    @Test("a keep-alive finishing on a closing connection reports nothing")
    func keepAliveSucceededWhileClosing() {
        var (state, _) = Self.connected()
        _ = state.parkConnection(scheduleKeepAliveTimer: true, scheduleIdleTimeoutTimer: false)
        _ = state.runKeepAliveIfIdle(reducesAvailableStreams: false)
        _ = state.close()
        #expect(state.keepAliveSucceeded() == nil)
    }

    /// A keep-alive cannot start on a leased connection — there is a query on it.
    @Test("a keep-alive does not start on a leased connection")
    func keepAliveDoesNotStartWhileLeased() {
        var (state, _) = Self.connected()
        _ = state.lease(streams: 1)
        #expect(state.runKeepAliveIfIdle(reducesAvailableStreams: false) == nil)
    }

    // MARK: - Max stream changes

    /// A new maximum reports both numbers plus what is in use, so the pool can
    /// work out the delta rather than assuming the old value.
    @Test("a new max stream setting reports the old value and what is in use")
    func newMaxStreamsWhileLeased() {
        var (state, _) = Self.connected(maxStreams: 4)
        _ = state.lease(streams: 2)
        guard let info = state.newMaxStreamSetting(8) else {
            Issue.record("a leased connection should accept a new maximum")
            return
        }
        #expect(info.newMaxStreams == 8)
        #expect(info.oldMaxStreams == 4)
        #expect(info.usedStreams == 2)
    }

    /// A connection on its way out does not report a change — the pool has
    /// already stopped counting its streams.
    @Test("a new max stream setting on a closing connection reports nothing")
    func newMaxStreamsWhileClosing() {
        var (state, _) = Self.connected()
        _ = state.close()
        #expect(state.newMaxStreamSetting(8) == nil)
    }

    // MARK: - Idle timer cancellation

    /// Cancelling the idle timer hands back its token and leaves the connection
    /// idle — it is a timer being disarmed, not the connection being closed.
    @Test("cancelling the idle timer returns its token and leaves the connection idle")
    func cancelIdleTimer() {
        var (state, _) = Self.connected()
        guard let timer = Array(
            state.parkConnection(scheduleKeepAliveTimer: false, scheduleIdleTimeoutTimer: true)
        ).first else {
            Issue.record("no idle timer armed")
            return
        }
        _ = state.timerScheduled(timer, cancelContinuation: 8)
        #expect(state.cancelIdleTimer() == 8)
        #expect(state.isIdle)
        #expect(state.cancelIdleTimer() == nil, "cancelling twice is not an error, just nothing to do")
    }

    /// There is no idle timer on a leased connection to cancel.
    @Test("cancelling the idle timer of a leased connection does nothing")
    func cancelIdleTimerWhileLeased() {
        var (state, _) = Self.connected()
        _ = state.lease(streams: 1)
        #expect(state.cancelIdleTimer() == nil)
    }

    // MARK: - Closing

    /// Closing an idle connection cancels both of its timers — leaving either
    /// armed means it fires against a closed connection.
    @Test("closing an idle connection cancels both its timers")
    func closeCancelsBothTimers() {
        var (state, connection) = Self.connected()
        let timers = Array(
            state.parkConnection(scheduleKeepAliveTimer: true, scheduleIdleTimeoutTimer: true)
        )
        for (index, timer) in timers.enumerated() {
            _ = state.timerScheduled(timer, cancelContinuation: index + 1)
        }
        guard let close = state.closeIfIdle() else {
            Issue.record("an idle connection should be closeable")
            return
        }
        #expect(close.connection === connection)
        #expect(Set(close.cancelTimers) == [1, 2])
    }

    /// A leased connection is not closed out from under its query — `closeIfIdle`
    /// declines, and it is `markForClose` that drains it instead.
    @Test("closeIfIdle declines a leased connection")
    func closeIfIdleDeclinesLeased() {
        var (state, _) = Self.connected()
        _ = state.lease(streams: 1)
        #expect(state.closeIfIdle() == nil)
        #expect(state.isLeased)
    }

    /// Marking an already-closing connection again is a no-op rather than a
    /// second close.
    @Test("marking an already-closing connection for close is a no-op")
    func markForCloseTwice() {
        var (state, _) = Self.connected()
        _ = state.close()
        if case .alreadyClosing = state.markForClose() {} else {
            Issue.record("a closing connection was marked for close a second time")
        }
    }

    /// A starting connection that is closed has no connection to hand back — it
    /// does not exist yet.
    @Test("closing a starting connection yields nothing to close")
    func closeWhileStarting() {
        var state = State(id: 1)
        #expect(state.close() == nil)
    }

    /// A backing-off connection closes without a connection object but with its
    /// backoff timer to cancel.
    @Test("closing a backing-off connection cancels its backoff")
    func closeWhileBackingOff() {
        var state = State(id: 1)
        let backoff = state.failedToConnect()
        _ = state.timerScheduled(backoff, cancelContinuation: 4)
        guard let close = state.close() else {
            Issue.record("a backing-off connection should close")
            return
        }
        #expect(close.connection == nil, "there is no connection yet, only an attempt")
        #expect(Array(close.cancelTimers) == [4])
        #expect(state.isClosed)
    }

    /// Closing twice is not a second close.
    @Test("closing an already-closed connection does nothing")
    func closeTwice() {
        var (state, _) = Self.connected()
        #expect(state.close() != nil)
        #expect(state.close() == nil)
    }

    // MARK: - Parking in the remaining states

    /// Parking a connection that already has a keep-alive scheduled and no idle
    /// timer arms just the idle timer. This is the arm whose timer was
    /// mislabelled; it is pinned here from the other direction, by what it
    /// returns rather than by what the label routes to.
    @Test("parking with a keep-alive already scheduled arms only the idle timer")
    func parkWithKeepAliveAlreadyScheduled() {
        var (state, _) = Self.connected()
        _ = state.parkConnection(scheduleKeepAliveTimer: true, scheduleIdleTimeoutTimer: false)

        let timers = Array(
            state.parkConnection(scheduleKeepAliveTimer: false, scheduleIdleTimeoutTimer: true)
        )
        #expect(timers.count == 1)
        #expect(timers.first?.usecase == .idleTimeout)
    }

    /// Parking a connection that already has both is a no-op. The pool parks on
    /// every release, so this runs constantly; arming a second pair each time
    /// would leak a timer per query.
    @Test("re-parking a fully armed connection arms nothing")
    func reparkFullyArmed() {
        var (state, _) = Self.connected()
        _ = state.parkConnection(scheduleKeepAliveTimer: true, scheduleIdleTimeoutTimer: true)
        #expect(
            Array(state.parkConnection(scheduleKeepAliveTimer: false, scheduleIdleTimeoutTimer: false))
                .isEmpty
        )
    }

    /// Same again while the keep-alive is actually running rather than pending.
    @Test("re-parking with a keep-alive running and an idle timer armed arms nothing")
    func reparkWithRunningKeepAliveAndIdleTimer() {
        var (state, _) = Self.connected()
        _ = state.parkConnection(scheduleKeepAliveTimer: true, scheduleIdleTimeoutTimer: true)
        _ = state.runKeepAliveIfIdle(reducesAvailableStreams: false)
        #expect(
            Array(state.parkConnection(scheduleKeepAliveTimer: false, scheduleIdleTimeoutTimer: false))
                .isEmpty
        )
    }

    // MARK: - What each state reports about itself

    /// The predicates the pool routes on, across the whole lifecycle. They are
    /// read at almost every decision point, so a state that answers wrongly is
    /// not a local bug — it sends the pool down the wrong branch everywhere.
    @Test("each state reports itself accurately")
    func statePredicates() {
        var starting = State(id: 1)
        #expect(!starting.isIdle && !starting.isAvailable && !starting.isLeased)
        #expect(!starting.isDraining && !starting.isConnected && !starting.isClosed)

        var backingOff = State(id: 2)
        _ = backingOff.failedToConnect()
        #expect(!backingOff.isIdle && !backingOff.isAvailable && !backingOff.isLeased)
        #expect(!backingOff.isDraining && !backingOff.isConnected && !backingOff.isClosed)

        var (idle, _) = Self.connected(maxStreams: 2)
        #expect(idle.isIdle && idle.isAvailable && idle.isConnected)
        #expect(!idle.isLeased && !idle.isDraining && !idle.isClosed)

        var (leased, _) = Self.connected(maxStreams: 2)
        _ = leased.lease(streams: 1)
        #expect(leased.isLeased && leased.isConnected)
        #expect(leased.isAvailable, "one of its two streams is still free")
        #expect(!leased.isIdle && !leased.isDraining && !leased.isClosed)

        var (saturated, _) = Self.connected(maxStreams: 1)
        _ = saturated.lease(streams: 1)
        #expect(saturated.isLeased && !saturated.isAvailable, "its only stream is taken")

        var (draining, _) = Self.connected(maxStreams: 2)
        _ = draining.lease(streams: 1)
        _ = draining.markForClose()
        #expect(draining.isDraining)
        #expect(!draining.isAvailable, "it is on its way out; nothing new goes on it")
        #expect(
            draining.isLeased,
            "still leased: streams are still outstanding on it, and draining is a promise to close once they come back"
        )
        #expect(!draining.isIdle && !draining.isClosed)

        var (closing, _) = Self.connected()
        _ = closing.close()
        #expect(!closing.isAvailable && !closing.isIdle && !closing.isLeased)
        #expect(!closing.isDraining)
    }

    /// Closing a draining connection reports **no maximum**, because there is no
    /// capacity left to give back — the pool has already stopped counting its
    /// streams as available. Reporting the real maximum here would credit the
    /// pool with capacity on a connection that is on its way out.
    @Test("closing a draining connection reports no available capacity")
    func closeWhileDraining() {
        var (state, connection) = Self.connected(maxStreams: 4)
        _ = state.lease(streams: 2)
        _ = state.markForClose()

        guard let close = state.close() else {
            Issue.record("a draining connection should close")
            return
        }
        #expect(close.connection === connection)
        #expect(close.maxStreams == 0, "no capacity to credit back")
        #expect(close.usedStreams == 2, "but the outstanding streams are still reported")
        #expect(!close.runningKeepAlive)
    }

    // MARK: - Equality of the action payloads

    /// `KeepAliveAction`, `LeaseAction` and `CloseAction` all carry hand-written
    /// equality, and none of it was reachable from a test — the suites all
    /// pattern match. Hand-written `==` degrades quietly into "the cases match",
    /// so each is pinned on the fields it does compare.
    ///
    /// `CloseAction` deliberately compares only its connection, its timers and
    /// its maximum — `usedStreams`, `previousConnectionState` and
    /// `runningKeepAlive` are *not* compared. That is worth knowing before
    /// leaning on it: two close actions that differ only in whether a keep-alive
    /// was running are equal, so a test comparing whole actions cannot catch a
    /// regression in that field.
    @Test("the action payloads compare on the fields they claim to")
    func actionPayloadEquality() {
        let connection = MockConnection(id: 1)
        let twin = MockConnection(id: 1)

        typealias KeepAlive = TestStateMachine.KeepAliveAction
        #expect(KeepAlive(connection: connection, keepAliveTimerCancellationContinuation: 1)
            == KeepAlive(connection: connection, keepAliveTimerCancellationContinuation: 1))
        #expect(KeepAlive(connection: connection, keepAliveTimerCancellationContinuation: 1)
            != KeepAlive(connection: twin, keepAliveTimerCancellationContinuation: 1))
        #expect(KeepAlive(connection: connection, keepAliveTimerCancellationContinuation: 1)
            != KeepAlive(connection: connection, keepAliveTimerCancellationContinuation: 2))

        typealias Lease = State.LeaseAction
        #expect(Lease(connection: connection, timersToCancel: .init(), wasIdle: true)
            == Lease(connection: connection, timersToCancel: .init(), wasIdle: true))
        #expect(Lease(connection: connection, timersToCancel: .init(), wasIdle: true)
            != Lease(connection: connection, timersToCancel: .init(), wasIdle: false))
        #expect(Lease(connection: connection, timersToCancel: .init(), wasIdle: true)
            != Lease(connection: twin, timersToCancel: .init(), wasIdle: true))
        #expect(Lease(connection: connection, timersToCancel: .init(1), wasIdle: true)
            != Lease(connection: connection, timersToCancel: .init(2), wasIdle: true))

        typealias Close = State.CloseAction
        func close(
            _ connection: MockConnection, timers: Max2Sequence<Int> = .init(),
            maxStreams: UInt16 = 4, usedStreams: UInt16 = 0, keepAlive: Bool = false
        ) -> Close {
            Close(
                connection: connection, previousConnectionState: .idle, cancelTimers: timers,
                usedStreams: usedStreams, maxStreams: maxStreams, runningKeepAlive: keepAlive
            )
        }
        #expect(close(connection) == close(connection))
        #expect(close(connection) != close(twin))
        #expect(close(connection) != close(connection, timers: .init(1)))
        #expect(close(connection) != close(connection, maxStreams: 8))
        #expect(
            close(connection, usedStreams: 0, keepAlive: false)
                == close(connection, usedStreams: 3, keepAlive: true),
            "documented: neither the used streams nor the keep-alive flag is compared"
        )
    }
}

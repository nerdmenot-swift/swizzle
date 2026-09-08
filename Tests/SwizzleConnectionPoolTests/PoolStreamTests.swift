import Testing

@testable import SwizzleConnectionPool

/// Connections that carry **more than one request at a time**, and the timer
/// bookkeeping around them.
///
/// ## The dimension the first suite missed
///
/// `PoolStateMachineTests` establishes every connection with `maxStreams: 1`,
/// which quietly tests only half the machine. A pooled connection can serve
/// several requests concurrently — that is what a "stream" is here — and the
/// arithmetic that tracks how many are in use, decides when a connection is
/// still leasable, and works out how many queued requests a new stream limit
/// releases is untouched by any single-stream test.
///
/// It is also arithmetic a server changes underneath you: `maxStreams` arrives
/// from the peer and can *grow*, at which point the pool must work out how many
/// waiters that lets it serve. Getting that wrong either strands requests that
/// could run or over-leases a connection past what the server allows.
///
/// ## Timers
///
/// The state machine never schedules anything itself. It hands back a `Timer`
/// and expects the caller to schedule it and return a cancellation token, which
/// it stores so the timer can be cancelled when it becomes irrelevant. Nothing
/// exercised that round trip, so the tokens were only ever produced and never
/// given back.
@Suite("Pool streams and timers")
struct PoolStreamTests {

    /// Establishes one connection with room for several streams.
    static func machineWithMultiStreamConnection(
        maxStreams: UInt16
    ) -> (machine: TestStateMachine, connection: MockConnection) {
        var (machine, refill) = makeStateMachine(minimumConnections: 1, maximumSoftLimit: 1, maximumHardLimit: 1)
        let connection = MockConnection(id: refill[0].connectionID)
        _ = machine.connectionEstablished(connection, maxStreams: maxStreams)
        return (machine, connection)
    }

    // MARK: - Leasing several streams from one connection

    /// A connection with four streams serves four requests before the pool has
    /// to make another — and with a hard limit of one, the fifth must queue
    /// rather than be leased a fifth time.
    @Test("one connection serves as many requests as it has streams, and no more")
    func leasesUpToTheStreamLimit() {
        var (machine, connection) = Self.machineWithMultiStreamConnection(maxStreams: 4)

        var leased: [MockRequest] = []
        for id in 1...4 {
            let request = MockRequest(id: id)
            let action = machine.leaseConnection(request)
            guard case .leaseConnection(_, let got) = action.request else {
                Issue.record("request \(id) was not leased: \(action.request)")
                return
            }
            #expect(got.id == connection.id, "every lease is the same connection")
            leased.append(request)
        }

        // The fifth has nowhere to go: the streams are gone and the hard limit
        // forbids another connection.
        let fifth = MockRequest(id: 5)
        let action = machine.leaseConnection(fifth)
        if case .leaseConnection = action.request {
            Issue.record("leased a fifth stream from a four-stream connection")
        }
    }

    /// Releasing a stream makes it available again, which is the half that
    /// would let a leak go unnoticed: a pool that never returns streams stops
    /// serving without ever erroring.
    @Test("releasing a stream lets the next request have it")
    func releasedStreamIsReused() {
        var (machine, connection) = Self.machineWithMultiStreamConnection(maxStreams: 2)

        for id in 1...2 {
            _ = machine.leaseConnection(MockRequest(id: id))
        }

        // Full: the next request queues.
        let queued = MockRequest(id: 3)
        let blocked = machine.leaseConnection(queued)
        if case .leaseConnection = blocked.request {
            Issue.record("leased a third stream from a two-stream connection")
            return
        }

        // Returning one stream serves the waiter.
        let released = machine.releaseConnection(connection, streams: 1)
        guard case .leaseConnection(let requests, let got) = released.request else {
            Issue.record("releasing a stream did not serve the waiter: \(released.request)")
            return
        }
        #expect(got.id == connection.id)
        #expect(requests.contains { $0.id == queued.id })
    }

    // MARK: - The server changing its mind

    /// **A raised stream limit must release exactly the waiters it can serve.**
    ///
    /// Too few and requests sit behind capacity that exists; too many and the
    /// pool leases past what the server permits, which the server then rejects
    /// on somebody's query rather than here.
    @Test("raising the stream limit serves the waiters the new capacity allows")
    func raisedStreamLimitServesWaiters() {
        var (machine, connection) = Self.machineWithMultiStreamConnection(maxStreams: 1)

        _ = machine.leaseConnection(MockRequest(id: 1))

        let waiting = [MockRequest(id: 2), MockRequest(id: 3), MockRequest(id: 4)]
        for request in waiting { _ = machine.leaseConnection(request) }

        // Room for two more streams, and three waiting: two should be served.
        let action = machine.connectionReceivedNewMaxStreamSetting(
            connection.id, newMaxStreamSetting: 3
        )
        guard case .leaseConnection(let served, let got) = action.request else {
            Issue.record("raising the limit served nobody: \(action.request)")
            return
        }
        #expect(got.id == connection.id)
        #expect(
            served.count == 2,
            "three waiting and two new streams should serve exactly two, served \(served.count)"
        )
    }

    /// **Capacity is not the only cap — the queue is.** With one waiter and
    /// room for four more streams, exactly one request may be dequeued.
    ///
    /// This is the case that distinguishes the three-way `min`: the other tests
    /// all have more waiters than new capacity, so the waiter count never binds
    /// and a mutation that drops it goes unnoticed. Serving more than the queue
    /// holds trips the machine's own
    /// `precondition(Int(leaseStreams) == requests.count)`.
    @Test("raising the limit past the queue serves only the waiters there are")
    func raisedStreamLimitIsCappedByTheQueue() {
        var (machine, connection) = Self.machineWithMultiStreamConnection(maxStreams: 1)

        _ = machine.leaseConnection(MockRequest(id: 1))
        let onlyWaiter = MockRequest(id: 2)
        _ = machine.leaseConnection(onlyWaiter)

        // Room for four more streams; one request waiting.
        let action = machine.connectionReceivedNewMaxStreamSetting(
            connection.id, newMaxStreamSetting: 5
        )
        guard case .leaseConnection(let served, let got) = action.request else {
            Issue.record("the waiting request was not served: \(action.request)")
            return
        }
        #expect(got.id == connection.id)
        #expect(served.count == 1, "one waiter means one lease, served \(served.count)")
    }

    /// A limit that does not grow serves nobody — and must not be mistaken for
    /// capacity by arithmetic that subtracts in the wrong direction.
    @Test("lowering or repeating the stream limit serves nobody")
    func loweredStreamLimitServesNobody() {
        for newLimit: UInt16 in [1, 2] {
            var (machine, connection) = Self.machineWithMultiStreamConnection(maxStreams: 2)
            _ = machine.leaseConnection(MockRequest(id: 1))
            _ = machine.leaseConnection(MockRequest(id: 2))
            let waiter = MockRequest(id: 3)
            _ = machine.leaseConnection(waiter)

            let action = machine.connectionReceivedNewMaxStreamSetting(
                connection.id, newMaxStreamSetting: newLimit
            )
            if case .leaseConnection = action.request {
                Issue.record("limit \(newLimit) (not an increase) served a waiter")
            }
        }
    }

    /// With nobody waiting there is nothing to do, however the limit moves.
    @Test("a new stream limit with an empty queue does nothing")
    func newStreamLimitWithNoWaiters() {
        var (machine, connection) = Self.machineWithMultiStreamConnection(maxStreams: 1)

        let action = machine.connectionReceivedNewMaxStreamSetting(
            connection.id, newMaxStreamSetting: 8
        )
        if case .leaseConnection = action.request {
            Issue.record("served a request that does not exist")
        }
    }

    /// A limit reported for a connection the pool does not have is ignored
    /// rather than trusted — the id comes off the wire.
    @Test("a stream limit for an unknown connection is ignored")
    func newStreamLimitForUnknownConnection() {
        var (machine, _) = Self.machineWithMultiStreamConnection(maxStreams: 1)

        let action = machine.connectionReceivedNewMaxStreamSetting(
            999_999, newMaxStreamSetting: 8
        )
        if case .leaseConnection = action.request {
            Issue.record("acted on a connection the pool does not know")
        }
    }

    // MARK: - Timer round trips

    /// The machine hands out timers and expects a cancellation token back. That
    /// round trip is what lets it cancel a timer that has become irrelevant —
    /// an idle timeout on a connection that has just been leased, say — and
    /// nothing was returning the tokens, so the storing half never ran.
    @Test("a scheduled timer's token comes back when the timer stops mattering")
    func timerTokenIsStoredAndReturned() {
        var (machine, refill) = makeStateMachine(
            minimumConnections: 1, keepAlive: .seconds(10), idleTimeout: .seconds(30)
        )
        let connection = MockConnection(id: refill[0].connectionID)

        // Establishing an idle connection asks for its keep-alive and idle
        // timers.
        let established = machine.connectionEstablished(connection, maxStreams: 1)
        guard case .scheduleTimers(let timers) = established.connection else {
            Issue.record("expected timers to schedule, got \(established.connection)")
            return
        }
        #expect(!timers.isEmpty, "an idle connection with a keep-alive wants timers")

        // Hand each token back, as a real caller would after scheduling.
        var token = 100
        for timer in timers {
            let displaced = machine.timerScheduled(timer, cancelContinuation: token)
            #expect(displaced == nil, "nothing was scheduled before, so nothing is displaced")
            token += 1
        }

        // Leasing the connection makes those timers irrelevant, and the machine
        // must hand the tokens back to be cancelled.
        let leaseAction = machine.leaseConnection(MockRequest(id: 1))
        guard case .cancelTimers(let cancelled) = leaseAction.connection else {
            Issue.record("leasing an idle connection must cancel its timers, got \(leaseAction.connection)")
            return
        }
        #expect(!cancelled.isEmpty, "the tokens handed in above must come back out")
    }

    /// `timerTriggered` is the single door the caller fires timers through, and
    /// it routes by kind. Sending a backoff timer where a keep-alive was meant
    /// would retry a healthy connection and never check a sick one.
    @Test("a triggered timer is routed by its kind")
    func timerTriggeredRoutesByKind() {
        var (machine, refill) = makeStateMachine(minimumConnections: 1, keepAlive: .seconds(10))
        let connection = MockConnection(id: refill[0].connectionID)
        let established = machine.connectionEstablished(connection, maxStreams: 1)
        guard case .scheduleTimers(let timers) = established.connection,
              let keepAlive = timers.first(where: { $0.underlying.usecase == .keepAlive })
        else {
            Issue.record("expected a keep-alive timer")
            return
        }

        let action = machine.timerTriggered(keepAlive)
        guard case .runKeepAlive(let checked, _) = action.connection else {
            Issue.record("a keep-alive timer must run the keep-alive, got \(action.connection)")
            return
        }
        #expect(checked.id == connection.id)
    }

    // MARK: - Shutdown while a connection is mid-backoff

    /// A connection that is waiting out its backoff is not open, not closed,
    /// and holds a timer. Shutdown has to account for it — leaving the timer
    /// armed means the pool fires a retry after it has shut down.
    @Test("shutting down while a connection is backing off cancels its timer")
    func shutdownDuringBackoff() {
        var (machine, _) = makeStateMachine()

        let request = MockRequest(id: 1)
        let leaseAction = machine.leaseConnection(request)
        guard case .makeConnection(let connectionRequest, _) = leaseAction.connection else {
            Issue.record("expected makeConnection")
            return
        }

        let failed = machine.connectionEstablishFailed(PoolTestError.refused, for: connectionRequest)
        guard case .scheduleTimers(let timers) = failed.connection, let backoff = timers.first else {
            Issue.record("expected a backoff timer")
            return
        }
        _ = machine.timerScheduled(backoff, cancelContinuation: 42)

        // Shutdown must not leave that timer running.
        let action = machine.triggerGracefulShutdown()
        switch action.connection {
        case .initiateShutdown(let shutdown):
            #expect(
                shutdown.timersToCancel.contains(42),
                "the backoff token must be handed back for cancellation"
            )
        case .cancelEventStreamAndFinalCleanup(let tokens):
            #expect(tokens.contains(42), "the backoff token must be handed back for cancellation")
        default:
            Issue.record("shutdown ignored a connection that was backing off: \(action.connection)")
        }
    }
}

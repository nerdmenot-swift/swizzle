import Testing

@testable import SwizzleConnectionPool

/// How many connections the pool will try to open **at once**, and what happens
/// to a pool that is shutting down while it still has callers.
///
/// ## The thundering herd
///
/// `maximumConcurrentConnectionRequests` is separate from every other limit. The
/// soft and hard limits bound how many connections the pool *holds*; this bounds
/// how many it is *opening* at any moment. The distinction only matters at the
/// worst possible time: a server comes back after a restart, every queued
/// caller is waiting, and without this cap the pool answers by opening one
/// socket per waiter simultaneously — a connection storm aimed at a database
/// that has just finished recovering.
///
/// With the cap, a burst opens a few at a time and the rest of the queue waits
/// for those to land. Nobody is failed; they are served in waves.
///
/// The default is 20, so nothing in the ordinary test setups ever came close and
/// the branch had never run.
@Suite("Pool connection storm")
struct PoolConnectionStormTests {

    /// Leases `count` requests and returns every connection attempt the pool
    /// asked for.
    static func burst(
        of count: Int, on machine: inout TestStateMachine
    ) -> [TestStateMachine.ConnectionRequest] {
        var requests: [TestStateMachine.ConnectionRequest] = []
        for id in 1...count {
            let action = lease(MockRequest(id: id), from: &machine)
            switch action.connection {
            case .makeConnection(let request, _):
                requests.append(request)
            case .makeConnectionsCancelAndScheduleTimers(let many, _, _):
                requests.append(contentsOf: many)
            default:
                break
            }
        }
        return requests
    }

    // MARK: - The cap

    /// **A burst opens at most the configured number of connections at once**,
    /// however many callers arrive. The rest queue rather than each bringing a
    /// socket with them.
    @Test("a burst of callers opens no more connections at once than the cap allows")
    func burstIsCappedByConcurrentRequests() {
        var (machine, _) = makeStateMachine(
            minimumConnections: 0, maximumSoftLimit: 8, maximumHardLimit: 8,
            maximumConcurrentConnectionRequests: 2
        )
        let attempts = Self.burst(of: 8, on: &machine)
        #expect(
            attempts.count == 2,
            "eight callers opened \(attempts.count) sockets at once against a cold server"
        )
    }

    /// Without the cap the same burst opens one connection per caller — the
    /// contrast that shows the cap is doing the work rather than some other
    /// limit.
    @Test("the same burst without the cap opens a connection per caller")
    func burstWithoutCap() {
        var (machine, _) = makeStateMachine(
            minimumConnections: 0, maximumSoftLimit: 8, maximumHardLimit: 8,
            maximumConcurrentConnectionRequests: 20
        )
        #expect(Self.burst(of: 8, on: &machine).count == 8)
    }

    /// **The queue is not stranded: it is served in waves.** As each attempt
    /// lands the pool starts more, but only up to the cap again, so the number
    /// in flight never exceeds it while the backlog drains.
    ///
    /// Both halves matter and they pull against each other. A cap that never
    /// lifted would leave callers waiting on connections the pool had decided
    /// not to open; a cap that lifted without limit would be no cap at all.
    ///
    /// The pool does not open one connection per caller. It stops well short of
    /// its soft limit while it already has several in flight, and the tail of
    /// the queue drains as those leases come back instead. That is why the test
    /// releases at the end rather than expecting six connections for six
    /// callers: the claim being made is that nobody is stranded, not that the
    /// pool opens a socket for everyone at once.
    ///
    /// The follow-on connections arrive as `makeConnectionsCancelAndScheduleTimers`
    /// rather than `makeConnection` — the pool asks for a batch when a
    /// connection becomes available with waiters behind it, and a single one
    /// when a caller arrives to an empty pool. A test that watches only for the
    /// second sees the queue stall and concludes the cap never lifts. Mine did.
    @Test("callers held back by the cap are served in waves that respect it")
    func cappedCallersAreServedInWaves() {
        let cap = 2
        var (machine, _) = makeStateMachine(
            minimumConnections: 0, maximumSoftLimit: 8, maximumHardLimit: 8,
            maximumConcurrentConnectionRequests: cap
        )
        let waiters = (1...6).map { MockRequest(id: $0) }
        var pending: [TestStateMachine.ConnectionRequest] = []
        for waiter in waiters {
            switch lease(waiter, from: &machine).connection {
            case .makeConnection(let request, _):
                pending.append(request)
            case .makeConnectionsCancelAndScheduleTimers(let many, _, _):
                pending.append(contentsOf: many)
            default:
                break
            }
        }
        #expect(pending.count == cap, "the premise: the burst was capped")

        // Land them one at a time, collecting whatever the pool asks for next.
        // The bound is generous; it exists so a pool that never settles fails
        // rather than loops.
        var highWaterMark = pending.count
        var established: [MockConnection] = []
        var steps = 0
        while let attempt = pending.first, steps < 50 {
            pending.removeFirst()
            steps += 1

            let connection = MockConnection(id: attempt.connectionID)
            established.append(connection)
            let action = machine.connectionEstablished(connection, maxStreams: 1)
            run(action.request)

            switch action.connection {
            case .makeConnection(let request, _):
                pending.append(request)
            case .makeConnectionsCancelAndScheduleTimers(let many, _, _):
                pending.append(contentsOf: many)
            default:
                break
            }
            highWaterMark = max(highWaterMark, pending.count)
        }

        #expect(
            highWaterMark <= cap,
            "\(highWaterMark) connection attempts were in flight at once against a cap of \(cap)"
        )
        #expect(
            waiters.contains { $0.result != nil },
            "the pool opened nothing at all and every caller is stranded"
        )

        // The pool stops opening while it already has several connections in
        // flight, so the tail of the queue drains as those leases come back
        // rather than by opening one connection per caller. Releasing them is
        // what proves nobody is stranded.
        for connection in established {
            run(machine.releaseConnection(connection, streams: 1).request)
        }
        #expect(
            waiters.allSatisfy { $0.result != nil },
            "\(waiters.filter { $0.result == nil }.count) callers were still waiting after every lease came back"
        )
    }


    // MARK: - Shutting down with callers still queued

    /// **A pool that shuts down while its last connection attempt fails must
    /// fail the queue**, not leave it. There is nothing left to serve those
    /// callers with and nothing coming, so a caller not failed here is a caller
    /// suspended forever.
    @Test("a failed attempt during shutdown fails the callers still queued")
    func shutdownWithQueuedRequestsFailsThem() {
        var (machine, _) = makeStateMachine(
            minimumConnections: 0, maximumSoftLimit: 1, maximumHardLimit: 1
        )
        let waiter = MockRequest(id: 1)
        guard case .makeConnection(let attempt, _) = lease(waiter, from: &machine).connection else {
            Issue.record("expected a connection attempt")
            return
        }
        // A second caller queues behind the one attempt.
        let queued = MockRequest(id: 2)
        lease(queued, from: &machine)

        _ = machine.triggerGracefulShutdown()
        let action = machine.connectionEstablishFailed(PoolTestError.refused, for: attempt)
        run(action.request)

        #expect(waiter.failure == .poolShutdown, "got \(String(describing: waiter.failure))")
        #expect(queued.failure == .poolShutdown, "got \(String(describing: queued.failure))")
    }

    /// The pool finishes for good once that happens — it tells the caller to
    /// tear down the event stream rather than waiting for connections that no
    /// longer exist.
    @Test("the pool finishes once its last attempt fails during shutdown")
    func shutdownFinishesAfterLastAttemptFails() {
        var (machine, _) = makeStateMachine(
            minimumConnections: 0, maximumSoftLimit: 1, maximumHardLimit: 1
        )
        guard case .makeConnection(let attempt, _) =
            lease(MockRequest(id: 1), from: &machine).connection
        else {
            Issue.record("expected a connection attempt")
            return
        }
        _ = machine.triggerGracefulShutdown()

        let action = machine.connectionEstablishFailed(PoolTestError.refused, for: attempt)
        guard case .cancelEventStreamAndFinalCleanup = action.connection else {
            Issue.record("the pool did not finish: \(action.connection)")
            return
        }
        #expect(machine.isShutdown, "and it says so")
    }

    /// A pool that has already shut down reports it. The flag is what stops a
    /// caller re-entering a pool that is gone.
    @Test("a running pool does not report itself shut down")
    func runningPoolIsNotShutDown() {
        let (machine, _) = makeStateMachine(minimumConnections: 0)
        #expect(!machine.isShutdown)
    }
}

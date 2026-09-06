import Testing

@testable import SwizzleConnectionPool

/// Doubles for driving `PoolStateMachine` directly.
///
/// ## Why the state machine and not the pool
///
/// `PoolStateMachine` is a plain value type. It performs no I/O, starts no
/// tasks, and reads no clock except to compute deadlines it hands back — every
/// transition is a function from state and an event to an `Action`. That makes
/// the interesting behaviour reachable **synchronously and deterministically**,
/// which matters because the interesting behaviour is all rare-path: a
/// connection that fails to establish, a keep-alive that comes back an error, an
/// idle timer firing while a request is queued, a shutdown with waiters
/// outstanding.
///
/// Reaching those through the real pool would mean arranging a server to die at
/// the right moment. Reaching them here is a method call, so they can be
/// exercised exhaustively rather than opportunistically — and the tests do not
/// need timing, which is what makes them not flaky.
///
/// These are written against our API rather than ported from upstream, so they
/// stay honest when the vendored code diverges.

// MARK: - Connection

/// A connection that exists only to have an identity and a close callback.
final class MockConnection: PooledConnection, @unchecked Sendable {
    typealias ID = Int

    let id: Int
    private let lock = NIOLock()
    private var onCloseCallback: (@Sendable ((any Error)?) -> Void)?
    private var _closeCount = 0

    init(id: Int) { self.id = id }

    func onClose(_ closure: @escaping @Sendable ((any Error)?) -> Void) {
        lock.withLock { onCloseCallback = closure }
    }

    /// The pool calls this to hang up. Counted rather than acted on, because
    /// several transitions are only observable as "the pool decided to close
    /// this one" — an idle timeout and a keep-alive failure leave the same
    /// state behind and differ in whether a close was ordered.
    func close() {
        lock.withLock { _closeCount += 1 }
    }

    var closeCount: Int { lock.withLock { _closeCount } }

    /// Fires the registered callback, standing in for a channel dying on its
    /// own rather than the pool closing it.
    func simulateClose(error: (any Error)? = nil) {
        let callback = lock.withLock { onCloseCallback }
        callback?(error)
    }
}

// MARK: - Request

/// A lease request that records what it was completed with.
///
/// The recorded outcome is the point: several of the transitions under test are
/// only observable through *what the waiter is told*. A shutdown that resumes
/// its waiters with `.poolShutdown` and one that strands them look identical
/// from the state machine's own state.
final class MockRequest: ConnectionRequestProtocol, @unchecked Sendable {
    typealias ID = Int
    typealias Connection = MockConnection

    let id: Int
    private let lock = NIOLock()
    private var _result: Result<ConnectionLease<MockConnection>, ConnectionPoolError>?

    init(id: Int) { self.id = id }

    func complete(with result: Result<ConnectionLease<MockConnection>, ConnectionPoolError>) {
        lock.withLock { _result = result }
    }

    /// `nil` until the request has been completed either way.
    var result: Result<ConnectionLease<MockConnection>, ConnectionPoolError>? {
        lock.withLock { _result }
    }

    var leasedConnectionID: Int? {
        guard case .success(let lease) = result else { return nil }
        return lease.connection.id
    }

    var failure: ConnectionPoolError? {
        guard case .failure(let error) = result else { return nil }
        return error
    }
}

// MARK: - The machine under test

/// The state machine with every generic parameter pinned.
///
/// `ContinuousClock` rather than a fake one: nothing here waits for time to
/// pass. Timers are *returned* by the machine as values to be scheduled, and the
/// tests fire them back in by calling `timerTriggered` — so the clock only ever
/// computes a deadline nobody reads, and a mock would add machinery without
/// removing any nondeterminism.
typealias TestStateMachine = PoolStateMachine<
    MockConnection,
    ConnectionIDGenerator,
    MockConnection.ID,
    MockRequest,
    MockRequest.ID,
    Int,                        // TimerCancellationToken: any Sendable will do
    ContinuousClock,
    ContinuousClock.Instant
>

/// A machine with the given limits, plus the timers the pool would have armed.
///
/// Returning `refill` alongside is deliberate: a fresh machine with a minimum
/// connection count immediately wants connections, and a test that ignores that
/// is testing a pool in a state the real one is never in.
func makeStateMachine(
    minimumConnections: Int = 0,
    maximumSoftLimit: Int = 4,
    maximumHardLimit: Int = 4,
    keepAlive: Duration? = nil,
    idleTimeout: Duration = .seconds(30)
) -> (machine: TestStateMachine, refill: [TestStateMachine.ConnectionRequest]) {
    var configuration = PoolConfiguration()
    configuration.minimumConnectionCount = minimumConnections
    configuration.maximumConnectionSoftLimit = maximumSoftLimit
    configuration.maximumConnectionHardLimit = maximumHardLimit
    configuration.keepAliveDuration = keepAlive
    configuration.idleTimeoutDuration = idleTimeout

    var machine = TestStateMachine(
        configuration: configuration,
        generator: ConnectionIDGenerator(),
        timerCancellationTokenType: Int.self,
        clock: ContinuousClock()
    )
    let refill = machine.refillConnections()
    return (machine, refill)
}

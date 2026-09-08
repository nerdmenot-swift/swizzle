@testable import SwizzleConnectionPool

/// A one-shot latch: `wait()` suspends until `signal()` has been called, and
/// returns immediately ever after.
///
/// ## Why not a polling loop
///
/// The obvious way to wait for the pool to do something is to check, yield, and
/// check again. That reintroduces exactly the problem this project has already
/// been bitten by: a bounded loop can exhaust its bound on a machine where the
/// cooperative pool is busy, so the test fails for load rather than for
/// behaviour — and it fails *sometimes*, which is worse than failing.
///
/// A latch has no bound to exhaust. It is woken by the event itself, so it
/// cannot be too slow, and it does not consult the clock, so it cannot be timed
/// out by a slow machine. If the event never happens the test hangs, which is a
/// real signal rather than a coin toss: the pool genuinely never did the thing.
final class Latch: @unchecked Sendable {
    private let lock = NIOLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Opens the latch and wakes everyone waiting. Safe to call more than once —
    /// the pool can complete a request from more than one path.
    func signal() {
        let toResume = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in toResume { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyOpen = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if alreadyOpen { continuation.resume() }
        }
    }
}

/// A latch that opens once it has been signalled `target` times.
final class CountingLatch: @unchecked Sendable {
    private let lock = NIOLock()
    private let target: Int
    private var count = 0
    private let latch = Latch()

    init(target: Int) { self.target = target }

    func increment() {
        let reached = lock.withLock { () -> Bool in
            count += 1
            return count >= target
        }
        if reached { latch.signal() }
    }

    var value: Int { lock.withLock { count } }
    func wait() async { await latch.wait() }
}

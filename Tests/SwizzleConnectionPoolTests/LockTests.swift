import Testing

@testable import SwizzleConnectionPool

/// The pool's mutual-exclusion primitives.
///
/// ## Why these are tested at all
///
/// `NIOLock` and `NIOLockedValueBox` are vendored alongside the pool, and every
/// piece of shared state in it goes through them — the pool's own state machine,
/// the request queue, the connection group. They are also the one place in the
/// module where a bug does not show up as a wrong answer: a lock that fails to
/// exclude produces a lost update, and a lock that fails to *release* produces a
/// deadlock. Neither is visible in a test that only checks a return value.
///
/// So the tests here assert the two properties that make a lock a lock, rather
/// than exercising the methods for their own sake:
///
/// - **exclusion** — concurrent increments do not lose any;
/// - **release on every path**, including the one where the body throws.
///
/// A regression in the second shows up as the suite *hanging* rather than
/// failing, because a leaked mutex is a deadlock by definition and pthread
/// mutexes are not recursive. That is worth stating out loud: if this suite
/// stops finishing, the lock is the first place to look.
@Suite("Locks")
struct LockTests {

    struct Boom: Error {}

    // MARK: - NIOLockedValueBox

    /// **Exclusion.** A thousand concurrent increments must produce a thousand.
    /// A read-modify-write outside the lock loses updates under contention, and
    /// the count is the only way to see it — every individual operation looks
    /// fine.
    @Test("concurrent increments through the box lose none")
    func boxExcludes() async {
        let box = NIOLockedValueBox(0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<1_000 {
                group.addTask { box.withLockedValue { $0 += 1 } }
            }
        }
        #expect(box.withLockedValue { $0 } == 1_000)
    }

    /// A body that throws propagates its error **and** leaves the lock free.
    /// The second acquisition is the real assertion: if the throw had skipped
    /// the unlock, it would not return at all.
    @Test("a throwing body propagates and still releases the lock")
    func boxReleasesOnThrow() {
        let box = NIOLockedValueBox(7)
        #expect(throws: Boom.self) {
            try box.withLockedValue { (_: inout Int) -> Void in throw Boom() }
        }
        #expect(box.withLockedValue { $0 } == 7, "and the value is untouched")
    }

    /// A mutation through the box is visible to the next reader — `inout` on a
    /// copy rather than the stored value would make every write vanish.
    @Test("a mutation through the box is visible afterwards")
    func boxMutationSticks() {
        let box = NIOLockedValueBox([1, 2, 3])
        box.withLockedValue { $0.append(4) }
        #expect(box.withLockedValue { $0 } == [1, 2, 3, 4])
    }

    /// The escape hatch: taking the lock by hand and reaching the value without
    /// taking it again. Used where the lock has to span more than one call, and
    /// the danger is that it hands out a *copy* — a write through it would then
    /// be silently dropped.
    @Test("the manual lock sees and keeps writes made through it")
    func boxUnsafeView() {
        let box = NIOLockedValueBox(1)
        let unsafe = box.unsafe
        unsafe.lock()
        unsafe.withValueAssumingLockIsAcquired { $0 += 41 }
        let seen = unsafe.withValueAssumingLockIsAcquired { $0 }
        unsafe.unlock()

        #expect(seen == 42, "the write is visible while the lock is still held")
        #expect(box.withLockedValue { $0 } == 42, "and afterwards, through the normal path")
    }

    /// And the manual lock is a real lock: once released, the ordinary path can
    /// take it. Holding it here would deadlock the next line.
    @Test("releasing the manual lock lets the ordinary path back in")
    func boxUnsafeReleases() {
        let box = NIOLockedValueBox(0)
        box.unsafe.lock()
        box.unsafe.unlock()
        #expect(box.withLockedValue { $0 } == 0)
    }

    // MARK: - NIOLock

    /// The same exclusion property for the bare lock, which guards state it does
    /// not own.
    @Test("concurrent increments under the lock lose none")
    func lockExcludes() async {
        let lock = NIOLock()
        nonisolated(unsafe) var counter = 0
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<1_000 {
                group.addTask { lock.withLock { counter += 1 } }
            }
        }
        #expect(lock.withLock { counter } == 1_000)
    }

    /// `withLock` returns its body's value and releases on the way out.
    @Test("withLock returns the body's value and releases")
    func lockReturnsAndReleases() {
        let lock = NIOLock()
        #expect(lock.withLock { "held" } == "held")
        #expect(lock.withLock { "again" } == "again", "the first call released")
    }

    /// A throwing body propagates and still unlocks — as above, a regression
    /// hangs the next acquisition rather than failing it.
    @Test("a throwing body under the lock propagates and still releases")
    func lockReleasesOnThrow() {
        let lock = NIOLock()
        #expect(throws: Boom.self) {
            try lock.withLock { throw Boom() }
        }
        #expect(lock.withLock { true }, "the lock was released despite the throw")
    }

    /// The void form is the same lock, not a separate one — taking it blocks the
    /// value-returning form and vice versa.
    @Test("withLockVoid takes and releases the same lock")
    func lockVoidForm() {
        let lock = NIOLock()
        nonisolated(unsafe) var ran = false
        lock.withLockVoid { ran = true }
        #expect(ran)
        #expect(lock.withLock { true }, "and it released")
    }

    /// The void form releases on a throw too. It is a separate function from
    /// `withLock`, so it needs its own check — sharing a name is not sharing an
    /// implementation.
    @Test("a throwing body under withLockVoid propagates and still releases")
    func lockVoidReleasesOnThrow() {
        let lock = NIOLock()
        #expect(throws: Boom.self) {
            try lock.withLockVoid { throw Boom() }
        }
        #expect(lock.withLock { true })
    }

    /// Manual lock/unlock, the form the pool uses where the critical section
    /// spans more than one expression.
    @Test("manual lock and unlock bracket a critical section")
    func lockManualPair() {
        let lock = NIOLock()
        nonisolated(unsafe) var value = 0
        lock.lock()
        value += 1
        lock.unlock()
        #expect(lock.withLock { value } == 1)
    }

    /// The raw mutex, which the lock hands out so it can be used with a
    /// condition variable — a pthread condvar has to wait on the *same* mutex
    /// the lock uses, so this only works if the pointer is stable and really is
    /// the lock's own. Nothing in this module needs it yet, so nothing had ever
    /// checked either property.
    @Test("the raw primitive is stable and is the lock's own")
    func lockPrimitiveIsStable() {
        let lock = NIOLock()
        let first = lock.withLockPrimitive { UInt(bitPattern: $0) }
        let second = lock.withLockPrimitive { UInt(bitPattern: $0) }
        #expect(first == second, "a fresh mutex each call would be useless to a condvar")

        let other = NIOLock()
        #expect(
            other.withLockPrimitive { UInt(bitPattern: $0) } != first,
            "two locks must not share one mutex"
        )
        #expect(lock.withLock { true }, "and handing out the primitive did not take the lock")
    }

    /// Reaching the primitive throws through cleanly, without leaving the lock
    /// in a state that blocks the next caller.
    @Test("a throwing body over the raw primitive propagates and leaves the lock usable")
    func lockPrimitiveThrows() {
        let lock = NIOLock()
        #expect(throws: Boom.self) {
            try lock.withLockPrimitive { _ in throw Boom() }
        }
        #expect(lock.withLock { true })
    }
}

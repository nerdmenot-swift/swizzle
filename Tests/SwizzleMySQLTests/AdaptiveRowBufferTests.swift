import Testing
@testable import SwizzleMySQL

/// The demand window that decides how far ahead the driver reads.
///
/// ## What it is trading off
///
/// Too small a window and every row costs a round trip. Too large and a slow
/// consumer lets the server fill memory with rows nobody has asked for — which
/// is the whole point of having backpressure rather than just buffering.
///
/// So the target moves: it **doubles** whenever the buffer runs dry, because a
/// consumer that drained it is faster than the window allows, and it **halves**
/// on an overshoot — but only once a yield has been seen since the last growth,
/// so a single burst cannot collapse a window that was working.
///
/// ## Reading a private target
///
/// `didConsume(bufferDepth:)` returns `bufferDepth < target`, and for a
/// non-zero depth it has no side effects — the growth arm requires a depth of
/// exactly zero. So the target can be found by asking, without disturbing it.
/// That is what makes this testable at all; asserting on the returned demand
/// signal alone would pin the behaviour only where it happens to flip.
@Suite("MySQL adaptive row buffer")
struct AdaptiveRowBufferTests {

    /// The largest depth still under the target, plus one — found by probing,
    /// which is safe because a non-zero depth changes nothing.
    static func target(of buffer: inout MySQLAdaptiveRowBuffer) -> Int {
        var low = 1
        var high = 1 << 20
        while low < high {
            let mid = (low + high) / 2
            if buffer.didConsume(bufferDepth: mid) { low = mid + 1 } else { high = mid }
        }
        return low
    }

    // MARK: - The construction bounds

    /// The precondition accepts its own boundaries. A `<` where the code says
    /// `<=` would reject a target sitting exactly on the minimum or the
    /// maximum — both of which are legal and one of which is the default when
    /// a caller pins the window.
    @Test("a target equal to the minimum or the maximum is accepted")
    func boundsAreInclusive() {
        var atMinimum = MySQLAdaptiveRowBuffer(minimum: 4, maximum: 64, target: 4)
        #expect(Self.target(of: &atMinimum) == 4)

        var atMaximum = MySQLAdaptiveRowBuffer(minimum: 4, maximum: 64, target: 64)
        #expect(Self.target(of: &atMaximum) == 64)

        var pinned = MySQLAdaptiveRowBuffer(minimum: 8, maximum: 8, target: 8)
        #expect(Self.target(of: &pinned) == 8, "a window with no room to move is legal")
    }

    @Test("the defaults sit inside their own bounds")
    func defaults() {
        var buffer = MySQLAdaptiveRowBuffer()
        #expect(Self.target(of: &buffer) == MySQLAdaptiveRowBuffer.defaultTarget)
        #expect(MySQLAdaptiveRowBuffer.defaultMinimum <= MySQLAdaptiveRowBuffer.defaultTarget)
        #expect(MySQLAdaptiveRowBuffer.defaultTarget <= MySQLAdaptiveRowBuffer.defaultMaximum)
    }

    // MARK: - Growth

    /// A buffer that ran dry doubles the window: the consumer is faster than
    /// the current one allows.
    @Test("running dry doubles the target")
    func drainingGrowsTheWindow() {
        var buffer = MySQLAdaptiveRowBuffer(minimum: 1, maximum: 64, target: 8)
        _ = buffer.didConsume(bufferDepth: 0)
        #expect(Self.target(of: &buffer) == 16)
        _ = buffer.didConsume(bufferDepth: 0)
        #expect(Self.target(of: &buffer) == 32)
    }

    /// Growth stops at the maximum rather than doubling past it — the ceiling
    /// is what bounds the memory a slow consumer can be made to hold.
    @Test("growth stops at the maximum")
    func growthIsCapped() {
        var buffer = MySQLAdaptiveRowBuffer(minimum: 1, maximum: 32, target: 32)
        for _ in 0..<5 { _ = buffer.didConsume(bufferDepth: 0) }
        #expect(Self.target(of: &buffer) == 32, "already at the ceiling, so it stays")

        var below = MySQLAdaptiveRowBuffer(minimum: 1, maximum: 32, target: 16)
        _ = below.didConsume(bufferDepth: 0)
        #expect(Self.target(of: &below) == 32)
        _ = below.didConsume(bufferDepth: 0)
        #expect(Self.target(of: &below) == 32, "and does not step past it")
    }

    /// Consuming without draining changes nothing — only an empty buffer is
    /// evidence the window is too small.
    @Test("consuming without draining leaves the target alone")
    func partialConsumptionDoesNotGrow() {
        var buffer = MySQLAdaptiveRowBuffer(minimum: 1, maximum: 64, target: 8)
        for depth in [1, 2, 7, 8, 100] { _ = buffer.didConsume(bufferDepth: depth) }
        #expect(Self.target(of: &buffer) == 8)
    }

    /// And the returned signal is the demand: more rows are wanted while the
    /// buffer is below the target.
    @Test("demand is asserted below the target and withdrawn at it")
    func demandFollowsTheTarget() {
        var buffer = MySQLAdaptiveRowBuffer(minimum: 1, maximum: 64, target: 8)
        let below = buffer.didConsume(bufferDepth: 7)
        let at = buffer.didConsume(bufferDepth: 8)
        let past = buffer.didConsume(bufferDepth: 9)
        #expect(below, "below the target: keep reading")
        #expect(!at, "at it: stop")
        #expect(!past, "and past it")
    }

    // MARK: - Shrinking

    /// **A single burst must not collapse the window.** Overshooting halves the
    /// target only once a yield has been seen since the last growth, so the
    /// burst that follows a growth is treated as the growth working rather than
    /// as evidence against it.
    @Test("the first overshoot after a growth does not shrink the window")
    func firstOvershootIsForgiven() {
        var buffer = MySQLAdaptiveRowBuffer(minimum: 1, maximum: 64, target: 8)
        _ = buffer.didConsume(bufferDepth: 0)                  // grow to 16, clears canShrink
        #expect(Self.target(of: &buffer) == 16)

        _ = buffer.didYield(bufferDepth: 100)                  // an overshoot, but the first
        #expect(Self.target(of: &buffer) == 16, "forgiven — the growth had not been tested yet")

        _ = buffer.didYield(bufferDepth: 100)                  // now a yield has been seen
        #expect(Self.target(of: &buffer) == 8, "and this one counts")
    }

    /// A yield at or below the target is not an overshoot at all.
    @Test("a yield within the target does not shrink the window")
    func yieldWithinTargetDoesNotShrink() {
        var buffer = MySQLAdaptiveRowBuffer(minimum: 1, maximum: 64, target: 8)
        _ = buffer.didYield(bufferDepth: 1)                    // sets canShrink
        _ = buffer.didYield(bufferDepth: 8)                    // exactly at the target
        #expect(Self.target(of: &buffer) == 8, "at the target is not over it")
        _ = buffer.didYield(bufferDepth: 9)
        #expect(Self.target(of: &buffer) == 4, "one past it is")
    }

    /// Shrinking stops at the minimum, which is what keeps the window from
    /// collapsing to zero and stalling the stream outright.
    @Test("shrinking stops at the minimum")
    func shrinkIsFloored() {
        var buffer = MySQLAdaptiveRowBuffer(minimum: 4, maximum: 64, target: 8)
        for _ in 0..<10 { _ = buffer.didYield(bufferDepth: 1000) }
        #expect(Self.target(of: &buffer) == 4, "never below the floor")

        var atFloor = MySQLAdaptiveRowBuffer(minimum: 8, maximum: 64, target: 8)
        for _ in 0..<5 { _ = buffer.didYield(bufferDepth: 1000) }
        #expect(Self.target(of: &atFloor) == 8, "already at it, so it stays")
    }

    /// Yielding never asserts demand — that is the consumer's side of the
    /// exchange, and answering true here would make the producer read ahead on
    /// its own delivery.
    @Test("yielding never asks for more rows")
    func yieldDoesNotDemand() {
        var buffer = MySQLAdaptiveRowBuffer(minimum: 1, maximum: 64, target: 8)
        for depth in [0, 1, 8, 1000] {
            let demanded = buffer.didYield(bufferDepth: depth)
            #expect(!demanded, "depth \(depth)")
        }
    }

    /// A full cycle: a fast consumer grows the window, a burst holds it, and a
    /// sustained overshoot brings it back down — without ever leaving the
    /// bounds it was built with.
    @Test("the window stays within its bounds across a long run")
    func staysWithinBounds() {
        var buffer = MySQLAdaptiveRowBuffer(minimum: 2, maximum: 32, target: 8)
        for step in 0..<200 {
            if step % 3 == 0 {
                _ = buffer.didConsume(bufferDepth: 0)
            } else {
                _ = buffer.didYield(bufferDepth: step % 50)
            }
            var probe = buffer
            let current = Self.target(of: &probe)
            #expect(current >= 2 && current <= 32, "step \(step): target \(current)")
        }
    }
}

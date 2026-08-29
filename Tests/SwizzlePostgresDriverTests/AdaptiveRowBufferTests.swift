import Testing
@testable import SwizzlePostgresDriver

/// The adaptive row buffer, and in particular the two limits it must not cross.
///
/// The mutation sweep relaxed `target < maximum` to `<=` and nothing failed. The
/// Postgres buffer had no test at all — the equivalent MySQL strategy is
/// exercised in `StreamingTests`, and the two are separate types.
///
/// The ceiling is the whole point of a *bounded* buffer. Doubling past it means
/// the driver holds twice the rows it promised between reads, which is memory
/// the caller sized deliberately: this is the mechanism that stops a streamed
/// million-row query from quietly becoming a buffered one.
///
/// Every call is hoisted into a `let` rather than written inside `#expect`.
/// `didConsume` and `didYield` are `mutating`, and the macro takes its argument
/// as an autoclosure over an immutable capture — so the natural spelling does
/// not compile, and the hoisted one reads better anyway: the return value and
/// the state change are separate facts.
@Suite("Postgres adaptive row buffer")
struct AdaptiveRowBufferTests {

    // MARK: - Growing

    /// An empty buffer means the consumer is faster than the server, so the
    /// target doubles to ask for more per round trip.
    @Test("draining the buffer doubles the target")
    func growsWhenDrained() {
        var buffer = PostgresAdaptiveRowBuffer(minimum: 1, maximum: 16, target: 4)
        _ = buffer.didConsume(bufferDepth: 0)  // 4 → 8

        let belowNewTarget = buffer.didConsume(bufferDepth: 5)
        #expect(belowNewTarget, "5 is below the doubled target of 8")

        let atNewTarget = buffer.didConsume(bufferDepth: 8)
        #expect(!atNewTarget, "8 is not below a target of 8")
    }

    /// The ceiling, and the mutant that survived: doubling from `maximum` would
    /// overshoot it, so the guard is `<` rather than `<=`.
    @Test("the target never grows past the maximum")
    func neverExceedsMaximum() {
        var buffer = PostgresAdaptiveRowBuffer(minimum: 1, maximum: 8, target: 8)
        _ = buffer.didConsume(bufferDepth: 0)

        let atCeiling = buffer.didConsume(bufferDepth: 8)
        #expect(!atCeiling, "a depth equal to the maximum must not still be below the target")

        // And repeated draining does not creep past it either.
        for _ in 0..<10 { _ = buffer.didConsume(bufferDepth: 0) }
        let stillAtCeiling = buffer.didConsume(bufferDepth: 8)
        #expect(!stillAtCeiling, "the target grew past its maximum")
    }

    /// Approaching the ceiling from below stops *at* it rather than short of it,
    /// which is the other way that comparison could be wrong.
    @Test("the target reaches the maximum exactly")
    func reachesMaximum() {
        var buffer = PostgresAdaptiveRowBuffer(minimum: 1, maximum: 8, target: 4)
        _ = buffer.didConsume(bufferDepth: 0)  // 4 → 8

        let justBelow = buffer.didConsume(bufferDepth: 7)
        #expect(justBelow, "7 is below the new target of 8")
    }

    // MARK: - Shrinking

    /// A buffer that stays full means the server is outrunning the consumer, so
    /// the target halves — but only once a yield has been seen, so a stream that
    /// starts deep does not shrink on its very first batch.
    @Test("a persistently full buffer halves the target, but not on the first yield")
    func shrinksWhenFull() {
        var buffer = PostgresAdaptiveRowBuffer(minimum: 1, maximum: 16, target: 8)

        // The first yield only arms shrinking; the target is untouched.
        _ = buffer.didYield(bufferDepth: 100)
        let stillEight = buffer.didConsume(bufferDepth: 8)
        #expect(!stillEight, "the target should still be 8")

        _ = buffer.didYield(bufferDepth: 100)  // 8 → 4
        let atFour = buffer.didConsume(bufferDepth: 4)
        #expect(!atFour, "4 is not below a halved target of 4")

        let belowFour = buffer.didConsume(bufferDepth: 3)
        #expect(belowFour)
    }

    /// And the floor holds: halving stops at the minimum rather than collapsing
    /// towards zero, which would stall the stream entirely.
    @Test("the target never shrinks past the minimum")
    func neverBelowMinimum() {
        var buffer = PostgresAdaptiveRowBuffer(minimum: 2, maximum: 16, target: 2)
        for _ in 0..<10 { _ = buffer.didYield(bufferDepth: 100) }

        let belowFloor = buffer.didConsume(bufferDepth: 1)
        #expect(belowFloor, "1 is below the floor of 2, so it must still ask for more")
    }
}

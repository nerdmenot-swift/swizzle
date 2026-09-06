import Foundation

/// Seeds for the fuzzing suites.
///
/// ## Why this is a function and not a literal range
///
/// Every fuzzer here was written with `[UInt64](1...16)` or similar, and a fixed
/// seed set has a property that is easy to miss: it explores **the same inputs
/// forever**. Those seeds found real bugs when they were written — a length-
/// encoded integer above `Int64.max`, an array header that overflowed on
/// multiplication — and having found them, they will never find another. The
/// suite keeps passing and stops learning.
///
/// So the base is fixed by default, which keeps the push pipeline a fast
/// regression check that reproduces exactly, and shifted by `SWIZZLE_FUZZ_SEED`
/// in the nightly job, which is where new input is worth paying for.
///
/// A failure reproduces from the printed base: the nightly logs the value it
/// used, and setting `SWIZZLE_FUZZ_SEED` to the same number reruns the identical
/// inputs. Randomness that cannot be replayed is worse than none — a crash you
/// cannot reproduce is a crash you cannot fix.
func fuzzSeeds(_ count: Int) -> [UInt64] {
    let base = ProcessInfo.processInfo.environment["SWIZZLE_FUZZ_SEED"]
        .flatMap(UInt64.init) ?? 0
    return (1...UInt64(count)).map { base &+ $0 }
}

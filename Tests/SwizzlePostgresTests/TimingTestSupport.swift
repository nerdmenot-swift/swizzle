import Foundation
import Testing

/// Whether the tests that measure **wall-clock duration** should run.
///
/// A handful of tests have no observable other than elapsed time. The TLS
/// shutdown pair is the clearest: a correct close takes about 0.25s
/// (`tlsShutdownTimeout`) and the bug they guard against took 5.0s, waiting for
/// a `close_notify` that never comes. There is no error to assert on — the
/// duration *is* the property.
///
/// Those tests cannot survive the parallel suite. Measured, not assumed: the
/// same tests pass in 0.053–0.145s when run alone in CI's isolation step and
/// take 19–26s inside the full run. The cause is contention for the cooperative
/// thread pool — our own CPU-bound tests occupy it on a two- or three-core
/// runner, and cancellation delivery waits behind them. Every previous response
/// was to raise the bound, which produced 2s → 3s, 10s → 30s, and a test that
/// still measured the machine.
///
/// So they are skipped by default and run in a dedicated CI step with nothing
/// else competing, where a real bound means something. Set `SWIZZLE_TIMING=1`
/// to run them locally.
let timingTestsEnabled = ProcessInfo.processInfo.environment["SWIZZLE_TIMING"] != nil

/// The reason shown when a timing test is skipped.
let timingTestsReason = "Measures wall-clock time, so it only runs alone — set SWIZZLE_TIMING=1"

import Foundation
import Testing

/// Retries `condition` until it holds or the deadline passes.
///
/// Replaces "sleep long enough and hope" for anything that completes
/// asynchronously in the background. Converges as fast as the work actually
/// takes, and fails with a clear message if it never completes — so a slower
/// machine costs a few more polls rather than a flake, and genuinely broken
/// behaviour fails rather than passing by luck.
func eventually(
    within timeout: Duration = .seconds(5),
    pollingEvery interval: Duration = .milliseconds(20),
    _ description: String,
    _ condition: () async throws -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while clock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: interval)
    }
    Issue.record("timed out after \(timeout) waiting for: \(description)", sourceLocation: sourceLocation)
}

/// Blocks every participant until all of them have arrived.
///
/// Used where a test needs genuine simultaneity — several tasks holding pool
/// connections at once, say. A `Task.sleep` gets the same effect only by
/// assuming the other tasks got scheduled in time; this guarantees it, so the
/// test cannot flake on a loaded machine.
actor Barrier {
    private let count: Int
    private var arrived = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(count: Int) { self.count = count }

    func arriveAndWait() async {
        arrived += 1
        if arrived >= count {
            let pending = waiters
            waiters.removeAll()
            for continuation in pending { continuation.resume() }
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

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

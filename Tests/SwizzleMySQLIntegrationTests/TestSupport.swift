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

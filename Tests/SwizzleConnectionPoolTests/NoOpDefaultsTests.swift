import Testing

@testable import SwizzleConnectionPool

/// The no-op defaults, which every pool uses unless told otherwise.
///
/// ## Why trivial code still earns a test
///
/// `NoOpKeepAliveBehavior` and `NoOpConnectionPoolMetrics` do nothing, and that
/// is precisely the contract. They are what a pool gets when the caller does not
/// supply a keep-alive or a metrics delegate, so they sit on the default path of
/// every connection — and "does nothing" is a claim that can break. A
/// `keepAliveFrequency` that returned a duration instead of `nil` would arm a
/// timer nobody asked for; a delegate method that threw would take down a pool
/// that had opted out of observability entirely.
///
/// Neither type was constructed by any test, which is why they showed as 0%
/// covered. That number was not the interesting part — the interesting part is
/// that the defaults were never exercised at all.
@Suite("Pool no-op defaults")
struct PoolNoOpDefaultsTests {

    /// A keep-alive behaviour that reports no frequency, so the pool never arms
    /// a keep-alive timer — and one that runs without throwing, in case
    /// something calls it anyway.
    @Test("the no-op keep-alive asks for no timer and does nothing when run")
    func noOpKeepAlive() async throws {
        let behaviour = NoOpKeepAliveBehavior(connectionType: MockConnection.self)
        #expect(
            behaviour.keepAliveFrequency == nil,
            "a frequency here would arm a timer for a pool that opted out"
        )

        // Must not throw: a pool that opted out of keep-alive should not be able
        // to fail one.
        try await behaviour.runKeepAlive(for: MockConnection(id: 1))
    }

    /// Every delegate callback accepts what the pool hands it and returns. The
    /// values are the ones the pool actually reports, including the edges —
    /// a zero stream capacity, a nil close error, an empty queue.
    @Test("the no-op metrics delegate accepts every callback")
    func noOpMetrics() {
        let metrics = NoOpConnectionPoolMetrics(connectionIDType: Int.self)

        metrics.startedConnecting(id: 1)
        metrics.connectFailed(id: 1, error: PoolTestError.refused)
        metrics.connectSucceeded(id: 1, streamCapacity: 0)
        metrics.connectSucceeded(id: 1, streamCapacity: .max)
        metrics.connectionUtilizationChanged(id: 1, streamsUsed: 0, streamCapacity: 0)
        metrics.connectionUtilizationChanged(id: 1, streamsUsed: 4, streamCapacity: 4)
        metrics.keepAliveTriggered(id: 1)
        metrics.keepAliveSucceeded(id: 1)
        metrics.keepAliveFailed(id: 1, error: PoolTestError.refused)
        metrics.connectionClosing(id: 1)
        metrics.connectionClosed(id: 1, error: nil)
        metrics.connectionClosed(id: 1, error: PoolTestError.refused)
        metrics.requestQueueDepthChanged(0)
        metrics.requestQueueDepthChanged(1_000)
    }
}

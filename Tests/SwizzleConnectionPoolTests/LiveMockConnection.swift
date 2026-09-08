@testable import SwizzleConnectionPool

/// A connection that actually completes its close.
///
/// `MockConnection` deliberately only *counts* closes. The state-machine suites
/// never run the actions the machine hands back, so a mock that called back
/// would be reporting an event nothing had caused.
///
/// The runtime suite does run them, and the pool waits for every connection it
/// closed to report in before `run()` returns. An inert connection therefore
/// hangs the pool at shutdown rather than failing anything — which is exactly
/// how this first showed up: every test that started the pool's run loop hung,
/// and the two that never opened a connection passed.
final class LiveMockConnection: PooledConnection, @unchecked Sendable {
    typealias ID = Int

    let id: Int
    private let lock = NIOLock()
    private var onCloseCallback: (@Sendable ((any Error)?) -> Void)?
    private var closed = false

    init(id: Int) { self.id = id }

    /// If the connection is already closed the callback fires immediately —
    /// a registration that arrives after the close must not be left waiting for
    /// an event that has already happened.
    func onClose(_ closure: @escaping @Sendable ((any Error)?) -> Void) {
        let alreadyClosed = lock.withLock { () -> Bool in
            if closed { return true }
            onCloseCallback = closure
            return false
        }
        if alreadyClosed { closure(nil) }
    }

    func close() {
        let callback = lock.withLock { () -> (@Sendable ((any Error)?) -> Void)? in
            guard !closed else { return nil }
            closed = true
            defer { onCloseCallback = nil }
            return onCloseCallback
        }
        callback?(nil)
    }
}

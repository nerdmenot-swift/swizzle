import NIOCore
import SwizzleConnectionPool

extension MySQLConnection: PooledConnection {
    public typealias ID = Int

    /// **The pool's** id for this connection, not the server's.
    ///
    /// The pool assigns an id, hands it to the connection factory, and later
    /// looks the connection up by `connection.id`. Returning the server's
    /// connection id here instead trips
    /// `preconditionFailure("There is a new connection that we didn't request!")`
    /// — a crash rather than a mismatch, because the pool treats it as an
    /// invariant violation.
    ///
    /// The server's id is still available as
    /// ``MySQLConnectionMetadata/connectionID`` for correlating with
    /// `SHOW PROCESSLIST`.
    public var id: Int { poolID }

    /// Fire-and-forget close, as the pool requires.
    ///
    /// Overloads with the async `close()`, and in async context Swift picks the
    /// async one — so callers that specifically want this must say
    /// ``closeImmediately()``.
    public func close() {
        closeImmediately()
    }

    /// Closes without waiting. Unambiguous spelling of the synchronous close.
    public func closeImmediately() {
        channel.close(promise: nil)
    }

    public func onClose(_ closure: @escaping @Sendable ((any Error)?) -> Void) {
        channel.closeFuture.whenComplete { result in
            switch result {
            case .success: closure(nil)
            case .failure(let error): closure(error)
            }
        }
    }
}

/// Keeps idle pooled connections alive with `COM_PING`.
///
/// Without this, a connection idle past the server's `wait_timeout` (8 hours by
/// default, but minutes behind many load balancers and proxies) is silently
/// closed, and the failure lands on whoever next borrows it rather than on the
/// pool.
public struct MySQLKeepAliveBehavior: ConnectionKeepAliveBehavior, Sendable {
    public typealias Connection = MySQLConnection

    public var keepAliveFrequency: Duration?

    public init(frequency: Duration? = .seconds(30)) {
        self.keepAliveFrequency = frequency
    }

    public func runKeepAlive(for connection: MySQLConnection) async throws {
        try await connection.ping()
    }
}

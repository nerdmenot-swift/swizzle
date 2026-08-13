/// A statement did not finish in time.
public struct SQLTimeoutError: SQLDiagnosable, CustomStringConvertible {
    public let duration: Duration
    public let sql: String?

    public init(duration: Duration, sql: String? = nil) {
        self.duration = duration
        self.sql = sql
    }

    public var sqlKind: SQLErrorKind { .timeout }

    /// **True**, and this is the whole reason a timeout needs its own type.
    ///
    /// Giving up on waiting says nothing about whether the server gave up on
    /// working. The statement may well be running still, and may well commit
    /// after the deadline has passed — so a timeout is never safe to retry
    /// blindly, however transient it looks.
    public var mayHaveApplied: Bool { true }

    public var description: String {
        var text = "statement exceeded \(duration)"
        if let sql { text += ": \(sql)" }
        return text
    }
}

/// Runs `body`, failing if it takes longer than `duration`.
///
/// ## What this does and does not promise
///
/// It stops the *caller* waiting, and cancels the task doing the work. Whether
/// that actually stops the database depends on the engine, and the honest summary
/// is:
///
/// - **MySQL** — cancellation propagates through the driver, which closes the
///   cursor and drains or kills the connection. The server may still finish the
///   statement.
/// - **SQLite** — a running `sqlite3_step` does not notice Swift's cancellation,
///   so `SQLiteConnection` installs a cancellation handler that calls
///   `sqlite3_interrupt`, which does. The statement really stops: a query that
///   would run for minutes returns in milliseconds and the connection is usable
///   immediately.
/// - **Postgres** — properly cancelling needs a `CancelRequest` on a second
///   connection; until the new driver carries that, the statement runs on.
///
/// So a timeout bounds *your* latency, not the database's work. That is worth
/// stating plainly, because the opposite assumption is how a "timeout" turns into
/// a duplicated write — which is why ``SQLTimeoutError/mayHaveApplied`` is true.
public func withQueryTimeout<T: Sendable>(
    _ duration: Duration,
    sql: String? = nil,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw SQLTimeoutError(duration: duration, sql: sql)
        }
        // Whichever finishes first wins; cancelling the group stops the other.
        guard let result = try await group.next() else {
            throw SQLTimeoutError(duration: duration, sql: sql)
        }
        group.cancelAll()
        return result
    }
}

extension SQLExecutor {
    /// Runs a statement, giving up after `timeout`.
    ///
    /// See ``withQueryTimeout(_:sql:_:)`` for what cancellation actually reaches
    /// per engine.
    public func execute(
        sql: String, bindings: [SQLValue] = [], timeout: Duration
    ) async throws -> [SQLRow] {
        try await withQueryTimeout(timeout, sql: sql) {
            try await execute(sql: sql, bindings: bindings)
        }
    }

    @discardableResult
    public func executeUpdate(
        sql: String, bindings: [SQLValue] = [], timeout: Duration
    ) async throws -> Int {
        try await withQueryTimeout(timeout, sql: sql) {
            try await executeUpdate(sql: sql, bindings: bindings)
        }
    }
}

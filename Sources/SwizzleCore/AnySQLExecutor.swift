/// An executor whose dialect is a runtime fact rather than a type.
///
/// ## Why both this and `SQLExecutor` exist
///
/// The generic `SQLExecutor` carries its dialect as an associated type, and that
/// is the whole point of it: handing a `SelectQuery<Postgres, …>` to a MySQL
/// connection is a **compile** error rather than a syntax error from the server
/// three hundred milliseconds later. Erasing that would throw away the best idea
/// in the library.
///
/// But not every caller is the query builder. Migrations run *raw SQL*, where
/// the dialect is something you discover by connecting, not something you know
/// while writing types. Forcing that path through the generic protocol produced
/// exactly the mess it should have warned us about: a hand-written enum with one
/// case per dialect and a method per operation switching over it, which had to
/// be edited in eight places to add a third database.
///
/// So: generic for the builder, erased for the runtime path. Each keeps the
/// property that matters to it.
public struct AnySQLExecutor: Sendable {
    /// For diagnostics and for choosing dialect-specific SQL at runtime.
    public let dialectName: String

    private let _execute: @Sendable (String, [SQLValue]) async throws -> [SQLRow]
    private let _executeUpdate: @Sendable (String, [SQLValue]) async throws -> Int
    private let _stream: (@Sendable (String, [SQLValue]) async throws -> ErasedRowSequence)?

    public init<Executor: SQLExecutor>(_ executor: Executor) {
        self.dialectName = Executor.Dialect.dialectName
        self._execute = { try await executor.execute(sql: $0, bindings: $1) }
        self._executeUpdate = { try await executor.executeUpdate(sql: $0, bindings: $1) }
        self._stream = nil
    }

    /// Erases an executor that can stream, keeping the streaming path.
    ///
    /// Erasing the row sequence does **not** cost backpressure — see
    /// ``ErasedRowSequence``, which forwards `next()` rather than buffering. What
    /// it costs is one closure indirection per row, which is why the generic
    /// `SQLStreamingExecutor` path is still there for anyone counting them.
    public init<Executor: SQLStreamingExecutor>(_ executor: Executor) {
        self.dialectName = Executor.Dialect.dialectName
        self._execute = { try await executor.execute(sql: $0, bindings: $1) }
        self._executeUpdate = { try await executor.executeUpdate(sql: $0, bindings: $1) }
        self._stream = { ErasedRowSequence(try await executor.stream(sql: $0, bindings: $1)) }
    }

    /// Whether this executor can stream. False for backends with nothing to
    /// stream from — an in-process SQLite driver, or a test double.
    public var canStream: Bool { _stream != nil }

    public func stream(
        sql: String, bindings: [SQLValue] = []
    ) async throws -> ErasedRowSequence {
        guard let _stream else { throw SQLStreamingUnsupported(dialectName: dialectName) }
        return try await _stream(sql, bindings)
    }

    /// Wraps closures directly, for a backend with no `SQLExecutor` of its own
    /// yet — or for a test double.
    public init(
        dialectName: String,
        execute: @escaping @Sendable (String, [SQLValue]) async throws -> [SQLRow],
        executeUpdate: @escaping @Sendable (String, [SQLValue]) async throws -> Int
    ) {
        self.dialectName = dialectName
        self._execute = execute
        self._executeUpdate = executeUpdate
        self._stream = nil
    }

    public func execute(sql: String, bindings: [SQLValue] = []) async throws -> [SQLRow] {
        try await _execute(sql, bindings)
    }

    @discardableResult
    public func executeUpdate(sql: String, bindings: [SQLValue] = []) async throws -> Int {
        try await _executeUpdate(sql, bindings)
    }
}

/// Streaming was asked of a backend that cannot do it.
public struct SQLStreamingUnsupported: Error, Sendable, CustomStringConvertible {
    public let dialectName: String
    public var description: String {
        "the \(dialectName) executor this query was built from cannot stream"
    }
}

extension SQLExecutor {
    /// Erases this executor for the runtime path.
    public var erased: AnySQLExecutor { AnySQLExecutor(self) }
}

extension SQLStreamingExecutor {
    /// Erases this executor **keeping the streaming path**.
    ///
    /// This becomes the witness for any type conforming to
    /// `SQLStreamingExecutor`, so it wins over the one above even when the call
    /// site only knows the value as an `SQLExecutor`.
    public var erased: AnySQLExecutor { AnySQLExecutor(self) }
}

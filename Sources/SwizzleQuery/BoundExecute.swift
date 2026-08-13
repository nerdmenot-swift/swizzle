import SwizzleCore

// Terminal operations for queries that already know their connection.
//
// Each mirrors the `on:` form exactly, minus the argument. Nothing else changes:
// same names, same return types, same warnings on an unfiltered write. Starting
// from `db.select(…)` means you never type `on:`; starting from
// `QueryBuilder<D>()` means you always do. The two never mix within one query, so
// there is no call site where it is unclear which applies.

extension SelectQuery: SQLBoundQuery {}
extension UpdateQuery: SQLBoundQuery {}
extension DeleteQuery: SQLBoundQuery {}
extension InsertQuery: SQLBoundQuery {}
extension RawQuery: SQLBoundQuery {}

extension SelectQuery {
    /// Runs the query and decodes every row.
    public func fetch() async throws -> [(repeat each V)] {
        let (sql, bindings) = try buildChecked()
        let rows = try await requireExecutor().execute(sql: sql, bindings: bindings)
        return try rows.map { try decode($0) }
    }

    /// Runs the query and returns the first row, or nil.
    ///
    /// Does **not** add `LIMIT 1`, for the same reason ``fetchFirst(on:)`` does not.
    public func fetchFirst() async throws -> (repeat each V)? {
        let (sql, bindings) = try buildChecked()
        let rows = try await requireExecutor().execute(sql: sql, bindings: bindings)
        guard let first = rows.first else { return nil }
        // Bound to a local first: returning a pack expansion straight into an
        // optional leaves the shape ambiguous to the type checker.
        let decoded: (repeat each V) = try decode(first)
        return decoded
    }

    /// Streams the query, decoding each row as it arrives.
    public func stream() async throws -> SQLRowStream<ErasedRowSequence, repeat each V> {
        let (sql, bindings) = try buildChecked()
        return SQLRowStream(source: try await requireExecutor().stream(sql: sql, bindings: bindings))
    }

    /// Streams the raw rows, leaving decoding to the caller.
    public func streamRows() async throws -> ErasedRowSequence {
        let (sql, bindings) = try buildChecked()
        return try await requireExecutor().stream(sql: sql, bindings: bindings)
    }

    /// Streams rows into a callback.
    public func forEach(_ body: (repeat each V) async throws -> Void) async throws {
        for try await row in try await stream() {
            try await body(repeat each row.values)
        }
    }
}

extension InsertQuery {
    @discardableResult
    public func execute() async throws -> Int {
        let (sql, bindings) = try buildChecked()
        return try await requireExecutor().executeUpdate(sql: sql, bindings: bindings)
    }
}

extension UpdateQuery {
    @discardableResult
    public func execute() async throws -> Int {
        let (sql, bindings) = try buildChecked()
        let affected = try await requireExecutor().executeUpdate(sql: sql, bindings: bindings)
        if core.predicates.isEmpty {
            SQLDiagnostics.unfilteredWrite("UPDATE", table: core.table, rowsAffected: affected)
        }
        return affected
    }
}

extension DeleteQuery {
    @discardableResult
    public func execute() async throws -> Int {
        let (sql, bindings) = try buildChecked()
        let affected = try await requireExecutor().executeUpdate(sql: sql, bindings: bindings)
        if core.predicates.isEmpty {
            SQLDiagnostics.unfilteredWrite("DELETE", table: core.table, rowsAffected: affected)
        }
        return affected
    }
}

extension RawQuery {
    public func fetch<each T: SQLColumnValue>(
        _ types: (repeat each T).Type
    ) async throws -> [(repeat each T)] {
        try checkPlaceholders()
        let (sql, bindings) = try buildChecked()
        let rows = try await requireExecutor().execute(sql: sql, bindings: bindings)
        return try rows.map { row in
            var index = 0
            return (repeat try Self.decodeNext((each T).self, row, &index))
        }
    }

    @discardableResult
    public func fetchRows() async throws -> [SQLRow] {
        try checkPlaceholders()
        let (sql, bindings) = try buildChecked()
        return try await requireExecutor().execute(sql: sql, bindings: bindings)
    }

    @discardableResult
    public func execute() async throws -> Int {
        try checkPlaceholders()
        let (sql, bindings) = try buildChecked()
        return try await requireExecutor().executeUpdate(sql: sql, bindings: bindings)
    }

    /// Streams a raw statement's rows.
    public func stream() async throws -> ErasedRowSequence {
        try checkPlaceholders()
        let (sql, bindings) = try buildChecked()
        return try await requireExecutor().stream(sql: sql, bindings: bindings)
    }
}

// MARK: - RETURNING

extension ReturningInsert {
    public func execute() async throws -> [(repeat each R)] {
        let (sql, bindings) = try buildChecked()
        let rows = try await insert.requireExecutor().execute(sql: sql, bindings: bindings)
        return try rows.map { try decode($0) }
    }
}

extension ReturningUpdate {
    public func execute() async throws -> [(repeat each R)] {
        let (sql, bindings) = try buildChecked()
        let rows = try await update.requireExecutor().execute(sql: sql, bindings: bindings)
        if update.core.predicates.isEmpty {
            SQLDiagnostics.unfilteredWrite("UPDATE", table: update.core.table, rowsAffected: rows.count)
        }
        return try rows.map { try decode($0) }
    }
}

extension ReturningDelete {
    public func execute() async throws -> [(repeat each R)] {
        let (sql, bindings) = try buildChecked()
        let rows = try await delete.requireExecutor().execute(sql: sql, bindings: bindings)
        if delete.core.predicates.isEmpty {
            SQLDiagnostics.unfilteredWrite("DELETE", table: delete.core.table, rowsAffected: rows.count)
        }
        return try rows.map { try decode($0) }
    }
}

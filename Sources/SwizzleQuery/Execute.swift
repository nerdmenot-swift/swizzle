import SwizzleCore

// Running a query.
//
// The `where Executor.Dialect == D` constraint is the load-bearing part: a
// `SelectQuery<Postgres, …>` will not compile against a MySQL executor. Without
// it the mistake surfaces as a server-side syntax error — `$1` is not a MySQL
// placeholder — long after the point where it was made.

extension SelectQuery {

    /// Runs the query and decodes every row into the projection's tuple type.
    ///
    /// `select(u.id, u.name).fetch(on: db)` yields `[(Int64, String)]`; the
    /// element type comes from the projection pack, so a column added to the
    /// `select` changes the tuple and any mismatched use stops compiling.
    public func fetch<Executor: SQLExecutor>(
        on executor: Executor
    ) async throws -> [(repeat each V)] where Executor.Dialect == D {
        let (sql, bindings) = try buildChecked()
        let rows = try await executor.execute(sql: sql, bindings: bindings)
        return try rows.map { try decode($0) }
    }

    /// Runs the query and returns the first row, or nil.
    ///
    /// Does **not** add `LIMIT 1` — the caller may have ordering or offsets in
    /// mind, and silently rewriting their query would be surprising. Add
    /// `.limit(1)` when that is what you want.
    public func fetchFirst<Executor: SQLExecutor>(
        on executor: Executor
    ) async throws -> (repeat each V)? where Executor.Dialect == D {
        let (sql, bindings) = try buildChecked()
        guard let row = try await executor.execute(sql: sql, bindings: bindings).first else {
            return nil
        }
        // Bound to a local first: returning a pack expansion straight into an
        // optional leaves the shape ambiguous to the type checker.
        let decoded: (repeat each V) = try decode(row)
        return decoded
    }

    /// Streams rows, handing each decoded tuple to `body` as it arrives.
    ///
    /// Kept because a closure is genuinely nicer when the body is a side effect
    /// and you want the tuple destructured for you. Reach for ``stream(on:)``
    /// when you want an `AsyncSequence` — which is most of the time, and which
    /// an earlier version of this comment wrongly claimed was impossible.
    ///
    /// (For the record: the obstacle was never pack-expansion `Element`s, it was
    /// `Optional<(repeat each V)>` in `next()`. Boxing the tuple sidesteps it.
    /// See ``Projected``.)
    public func forEach<Executor: SQLStreamingExecutor>(
        on executor: Executor,
        _ body: (repeat each V) async throws -> Void
    ) async throws where Executor.Dialect == D {
        let (sql, bindings) = try buildChecked()
        for try await row in try await executor.stream(sql: sql, bindings: bindings) {
            var index = 0
            try await body(repeat try Self.decodeColumn((each V).self, row, &index))
        }
    }

    /// Streams the raw rows, leaving decoding to the caller.
    ///
    /// The escape hatch from the limitation above: `SQLRow` is a plain type, so
    /// this is an ordinary `AsyncSequence` that iterates anywhere.
    public func streamRows<Executor: SQLStreamingExecutor>(
        on executor: Executor
    ) async throws -> Executor.RowSequence where Executor.Dialect == D {
        let (sql, bindings) = try buildChecked()
        return try await executor.stream(sql: sql, bindings: bindings)
    }

    static func decodeColumn<T: SQLColumnValue>(
        _ type: T.Type, _ row: SQLRow, _ index: inout Int
    ) throws -> T {
        defer { index += 1 }
        guard index < row.values.count else {
            throw SQLDecodeError(expected: "\(T.self) at column \(index)", actual: .null)
        }
        return try T(sqlValue: row.values[index])
    }
}

// MARK: - INSERT

extension InsertQuery {
    /// Runs the insert, returning the number of rows affected.
    @discardableResult
    public func execute<Executor: SQLExecutor>(
        on executor: Executor
    ) async throws -> Int where Executor.Dialect == D {
        let (sql, bindings) = try buildChecked()
        return try await executor.executeUpdate(sql: sql, bindings: bindings)
    }
}

// MARK: - UPDATE and DELETE

extension UpdateQuery {
    /// Runs the update, returning the number of rows affected.
    ///
    /// The only spelling, filtered or not. An unfiltered write is reported
    /// through `SQLDiagnostics` rather than refused — see that type for why the
    /// alternative was rejected.
    @discardableResult
    public func execute<Executor: SQLExecutor>(
        on executor: Executor
    ) async throws -> Int where Executor.Dialect == D {
        let (sql, bindings) = try buildChecked()
        let affected = try await executor.executeUpdate(sql: sql, bindings: bindings)
        if core.predicates.isEmpty {
            SQLDiagnostics.unfilteredWrite("UPDATE", table: core.table, rowsAffected: affected)
        }
        return affected
    }
}

extension DeleteQuery {
    /// Runs the delete, returning the number of rows removed.
    @discardableResult
    public func execute<Executor: SQLExecutor>(
        on executor: Executor
    ) async throws -> Int where Executor.Dialect == D {
        let (sql, bindings) = try buildChecked()
        let affected = try await executor.executeUpdate(sql: sql, bindings: bindings)
        if core.predicates.isEmpty {
            SQLDiagnostics.unfilteredWrite("DELETE", table: core.table, rowsAffected: affected)
        }
        return affected
    }
}

extension ReturningUpdate {
    /// Runs the update and decodes the `RETURNING` rows.
    public func execute<Executor: SQLExecutor>(
        on executor: Executor
    ) async throws -> [(repeat each R)] where Executor.Dialect == D {
        let (sql, bindings) = try buildChecked()
        let rows = try await executor.execute(sql: sql, bindings: bindings)
        if update.core.predicates.isEmpty {
            SQLDiagnostics.unfilteredWrite("UPDATE", table: update.core.table, rowsAffected: rows.count)
        }
        return try rows.map { try decode($0) }
    }
}

extension ReturningDelete {
    /// Runs the delete and decodes the `RETURNING` rows.
    public func execute<Executor: SQLExecutor>(
        on executor: Executor
    ) async throws -> [(repeat each R)] where Executor.Dialect == D {
        let (sql, bindings) = try buildChecked()
        let rows = try await executor.execute(sql: sql, bindings: bindings)
        if delete.core.predicates.isEmpty {
            SQLDiagnostics.unfilteredWrite("DELETE", table: delete.core.table, rowsAffected: rows.count)
        }
        return try rows.map { try decode($0) }
    }
}

extension ReturningInsert {
    /// Runs the insert and decodes the `RETURNING` rows.
    ///
    /// Only reachable on dialects conforming to `SupportsReturning`, so this
    /// cannot be called against MySQL at all — the capability gate is the type
    /// system, not a runtime check.
    public func execute<Executor: SQLExecutor>(
        on executor: Executor
    ) async throws -> [(repeat each R)] where Executor.Dialect == D {
        let (sql, bindings) = try buildChecked()
        let rows = try await executor.execute(sql: sql, bindings: bindings)
        return try rows.map { try decode($0) }
    }
}

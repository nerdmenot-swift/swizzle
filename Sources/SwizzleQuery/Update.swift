import SwizzleCore

/// An `UPDATE` under construction.
///
/// Follows `SelectQuery`'s shape decision: **one** type for the whole chain, no
/// phantom staging. A staged design would let the type system insist that `.set`
/// comes before `.where`, which nobody gets wrong, at the cost of a fresh generic
/// type per link — the classic "unable to type-check this expression in
/// reasonable time" recipe.
///
/// ```swift
/// try await db.update(u)
///     .set(u.name, to: "Ada")
///     .set(u.loginCount, to: u.loginCount + 1)
///     .where(u.id == 42)
///     .execute(on: connection)
/// ```
public struct UpdateQuery<D: SQLDialect, T: SQLTable>: Sendable {
    public var core: SQLUpdateCore
    public var boundExecutor: AnySQLExecutor?

    public init(_ table: T) {
        core = SQLUpdateCore(schema: T.schemaName, table: T.tableName, alias: table.tableAlias)
    }

    private func mutating(_ body: (inout SQLUpdateCore) -> Void) -> Self {
        var copy = self
        body(&copy.core)
        return copy
    }

    /// Assigns a literal value.
    public func set<V: SQLColumnValue>(_ column: SQLExpression<V>, to value: V) -> Self {
        mutating { $0.assignments.append(SQLAssignment(target: column.node, value: .bind(value.sqlValue))) }
    }

    /// Assigns an expression, so `views = views + 1` and `updated_at = NOW()`
    /// are ordinary rather than a reason to drop to raw SQL.
    public func set<V>(_ column: SQLExpression<V>, to expression: SQLExpression<V>) -> Self {
        mutating { $0.assignments.append(SQLAssignment(target: column.node, value: expression.node)) }
    }

    /// Predicates accumulate and are ANDed, so building a filter from a handful
    /// of optionals is a plain loop — no fragment API, no combinator needed.
    public func `where`(_ predicate: SQLExpression<Bool>) -> Self {
        mutating { $0.predicates.append(predicate.node) }
    }
}

// MARK: - Capability-gated clauses

extension UpdateQuery where D: SupportsWriteLimit {
    /// MySQL and MariaDB only. Postgres has no `UPDATE … LIMIT` at all, and on
    /// SQLite it depends on a compile-time flag we cannot promise.
    public func limit(_ count: Int) -> Self {
        var copy = self
        copy.core.limit = count
        return copy
    }

    /// Only meaningful alongside `limit` — it chooses *which* rows the limit
    /// keeps.
    public func orderBy(_ terms: SQLOrderTerm...) -> Self {
        var copy = self
        copy.core.orderBy.append(contentsOf: terms)
        return copy
    }
}

extension UpdateQuery where D: SupportsReturning {
    public func returning<each R: SQLColumnValue>(
        _ columns: repeat SQLExpression<each R>
    ) -> ReturningUpdate<D, T, repeat each R> {
        var copy = self
        for column in repeat each columns {
            copy.core.returning.append(column.node)
        }
        return ReturningUpdate(update: copy)
    }
}

public struct ReturningUpdate<D: SQLDialect, T: SQLTable, each R: SQLColumnValue>: @unchecked Sendable {
    public var update: UpdateQuery<D, T>

    public func decode(_ row: SQLRow) throws -> (repeat each R) {
        var index = 0
        return (repeat try Self.decodeNext((each R).self, row, &index))
    }

    private static func decodeNext<X: SQLColumnValue>(
        _ type: X.Type, _ row: SQLRow, _ index: inout Int
    ) throws -> X {
        defer { index += 1 }
        return try X(sqlValue: row.values[index])
    }
}

// MARK: - Rendering

extension UpdateQuery: SQLQueryConvertible {
    public typealias Dialect = D
    public func render(into renderer: inout SQLRenderer<D>) {
        renderer.renderUpdate(core)
    }
}

extension ReturningUpdate: SQLQueryConvertible {
    public typealias Dialect = D
    public func render(into renderer: inout SQLRenderer<D>) {
        update.render(into: &renderer)
    }
}

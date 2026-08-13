import SwizzleCore

/// A `DELETE` under construction.
///
/// ```swift
/// try await db.delete(from: s)
///     .where(s.expiresAt < now)
///     .execute(on: connection)
/// ```
public struct DeleteQuery<D: SQLDialect, T: SQLTable>: Sendable {
    public var core: SQLDeleteCore
    public var boundExecutor: AnySQLExecutor?

    public init(from table: T) {
        core = SQLDeleteCore(schema: T.schemaName, table: T.tableName, alias: table.tableAlias)
    }

    public func `where`(_ predicate: SQLExpression<Bool>) -> Self {
        var copy = self
        copy.core.predicates.append(predicate.node)
        return copy
    }
}

// MARK: - Capability-gated clauses

extension DeleteQuery where D: SupportsWriteLimit {
    /// MySQL and MariaDB only — see `SupportsWriteLimit`.
    ///
    /// Worth knowing: this is the usual way to delete a large backlog without
    /// holding one enormous transaction, run in a loop until it reports zero.
    public func limit(_ count: Int) -> Self {
        var copy = self
        copy.core.limit = count
        return copy
    }

    public func orderBy(_ terms: SQLOrderTerm...) -> Self {
        var copy = self
        copy.core.orderBy.append(contentsOf: terms)
        return copy
    }
}

extension DeleteQuery where D: SupportsReturning {
    public func returning<each R: SQLColumnValue>(
        _ columns: repeat SQLExpression<each R>
    ) -> ReturningDelete<D, T, repeat each R> {
        var copy = self
        for column in repeat each columns {
            copy.core.returning.append(column.node)
        }
        return ReturningDelete(delete: copy)
    }
}

public struct ReturningDelete<D: SQLDialect, T: SQLTable, each R: SQLColumnValue>: @unchecked Sendable {
    public var delete: DeleteQuery<D, T>

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

extension DeleteQuery: SQLQueryConvertible {
    public typealias Dialect = D
    public func render(into renderer: inout SQLRenderer<D>) {
        renderer.renderDelete(core)
    }
}

extension ReturningDelete: SQLQueryConvertible {
    public typealias Dialect = D
    public func render(into renderer: inout SQLRenderer<D>) {
        delete.render(into: &renderer)
    }
}

import SwizzleCore

/// Entry point. Carries the dialect so capability constraints resolve statically.
public struct QueryBuilder<D: SQLDialect>: Sendable {
    public init() {}

    public func select<each V: SQLColumnValue>(
        _ columns: repeat SQLExpression<each V>
    ) -> SelectQuery<D, repeat each V> {
        var core = SQLSelectCore()
        for column in repeat each columns {
            core.projection.append(column.node)
        }
        return SelectQuery(core: core)
    }

    public func insert<T: SQLTable>(into table: T) -> InsertQuery<D, T> {
        InsertQuery(into: table)
    }

    public func update<T: SQLTable>(_ table: T) -> UpdateQuery<D, T> {
        UpdateQuery(table)
    }

    public func delete<T: SQLTable>(from table: T) -> DeleteQuery<D, T> {
        DeleteQuery(from: table)
    }
}

/// A SELECT under construction.
///
/// Deliberately **one** type for the whole chain: `.where`, `.join`, `.orderBy`
/// all return `Self` rather than a new phantom-staged type. A staged design
/// (`SelectFrom` -> `SelectWhere` -> `SelectOrdered`) buys marginal ordering
/// safety and costs the solver a fresh generic type at every link — the classic
/// "unable to type-check this expression in reasonable time" recipe.
public struct SelectQuery<D: SQLDialect, each V: SQLColumnValue>: @unchecked Sendable {
    public var core: SQLSelectCore
    /// Set when this query came from `db.select(…)`. See `SQLBoundQuery`.
    public var boundExecutor: AnySQLExecutor?

    public init(core: SQLSelectCore) { self.core = core }

    private func mutating(_ body: (inout SQLSelectCore) -> Void) -> Self {
        var copy = self
        body(&copy.core)
        return copy
    }

    public func from(_ table: some SQLTable) -> Self {
        mutating { $0.from = table.source }
    }

    public func from<each S: SQLColumnValue>(
        _ subquery: SelectQuery<D, repeat each S>, as alias: String
    ) -> Self {
        mutating { $0.from = .subquery(subquery.core, alias: alias) }
    }

    public func `where`(_ predicate: SQLExpression<Bool>) -> Self {
        mutating { $0.predicates.append(predicate.node) }
    }

    public func innerJoin(_ table: some SQLTable, on predicate: SQLExpression<Bool>) -> Self {
        mutating { $0.joins.append(SQLJoin(kind: .inner, source: table.source, on: predicate.node)) }
    }

    public func leftJoin(_ table: some SQLTable, on predicate: SQLExpression<Bool>) -> Self {
        mutating { $0.joins.append(SQLJoin(kind: .left, source: table.source, on: predicate.node)) }
    }

    public func groupBy<each G: SQLColumnValue>(_ terms: repeat SQLExpression<each G>) -> Self {
        mutating { core in
            for term in repeat each terms {
                core.groupBy.append(term.node)
            }
        }
    }

    public func having(_ predicate: SQLExpression<Bool>) -> Self {
        mutating { $0.having.append(predicate.node) }
    }

    /// Non-generic variadic: order terms are pre-erased by `.asc`/`.desc`, so this
    /// link in the chain costs the solver nothing.
    public func orderBy(_ terms: SQLOrderTerm...) -> Self {
        mutating { $0.orderBy.append(contentsOf: terms) }
    }

    public func limit(_ count: Int) -> Self {
        mutating { $0.limit = count }
    }

    public func offset(_ count: Int) -> Self {
        mutating { $0.offset = count }
    }

    public func distinct() -> Self {
        mutating { $0.isDistinct = true }
    }
}

// MARK: - Capability-gated clauses

extension SelectQuery where D: SupportsDistinctOn {
    /// Postgres only. On MySQL/SQLite this method does not exist.
    public func distinctOn<each G: SQLColumnValue>(_ terms: repeat SQLExpression<each G>) -> Self {
        var copy = self
        for term in repeat each terms {
            copy.core.distinctOn.append(term.node)
        }
        return copy
    }
}

extension SelectQuery where D: SupportsFullOuterJoin {
    public func fullOuterJoin(_ table: some SQLTable, on predicate: SQLExpression<Bool>) -> Self {
        var copy = self
        copy.core.joins.append(SQLJoin(kind: .full, source: table.source, on: predicate.node))
        return copy
    }
}

extension SelectQuery where D: SupportsLateralJoin {
    public func lateralJoin<each S: SQLColumnValue>(
        _ subquery: SelectQuery<D, repeat each S>, as alias: String,
        on predicate: SQLExpression<Bool>
    ) -> Self {
        var copy = self
        copy.core.joins.append(
            SQLJoin(kind: .inner, source: .subquery(subquery.core, alias: alias),
                    on: predicate.node, isLateral: true)
        )
        return copy
    }
}

// MARK: - Rendering & decoding

extension SelectQuery: SQLQueryConvertible {
    public typealias Dialect = D
    public func render(into renderer: inout SQLRenderer<D>) {
        renderer.renderSelect(core)
    }
}

extension SelectQuery {
    /// Projects a row into the tuple the projection pack describes.
    /// `select(u.id, u.name)` decodes to `(Int64, String)`.
    public func decode(_ row: SQLRow) throws -> (repeat each V) {
        var index = 0
        return (repeat try Self.decodeNext((each V).self, row, &index))
    }

    private static func decodeNext<T: SQLColumnValue>(
        _ type: T.Type, _ row: SQLRow, _ index: inout Int
    ) throws -> T {
        defer { index += 1 }
        return try T(sqlValue: row.values[index])
    }
}

// MARK: - Subquery embedding

public func exists<D: SQLDialect, each S: SQLColumnValue>(
    _ subquery: SelectQuery<D, repeat each S>
) -> SQLExpression<Bool> {
    SQLExpression(.prefix("EXISTS", .selectSubquery(subquery.core)))
}

public func notExists<D: SQLDialect, each S: SQLColumnValue>(
    _ subquery: SelectQuery<D, repeat each S>
) -> SQLExpression<Bool> {
    SQLExpression(.prefix("NOT EXISTS", .selectSubquery(subquery.core)))
}

extension SelectQuery {
    /// Use a single-column SELECT as a scalar expression.
    public func scalar<T>(as type: T.Type = T.self) -> SQLExpression<T> {
        SQLExpression(.selectSubquery(core))
    }
}

import SwizzleCore

/// Entry points that remember the connection they came from.
///
/// ## The problem this fixes
///
/// The executor used to offer `db.select(...)`, which borrowed the *dialect* and
/// threw the connection away — so the connection had to be handed back at the
/// end:
///
/// ```swift
/// try await db.select(u.id).from(u).fetch(on: db)   // db, twice
/// ```
///
/// It was a half-binding, and the seam showed. Worse, it existed only on MySQL
/// and only for `select`, so writes read `InsertQuery<MariaDB, Users>(into: Users())
/// .execute(on: db)` — four namings for two facts.
///
/// ## Why erasure rather than a generic parameter
///
/// Carrying the executor as `SelectQuery<D, E, each V>` would force a placeholder
/// `E` onto every query built without a connection, and put it in every error
/// message. Erasing to `AnySQLExecutor` keeps the query's type exactly as it was.
/// Dialect safety is not lost: these methods only exist on an executor whose
/// `Dialect` matches, so the pairing is checked where the query is *created*
/// instead of where it runs.
///
/// ## The one thing to know
///
/// A bound query holds a reference to its connection. Store one in a property and
/// you have kept a pooled connection alive past its lease — the same hazard as
/// capturing `db` itself, but easier to do by accident. Build and run in one
/// expression, or use `QueryBuilder<D>()` for a query that outlives a connection.
extension SQLExecutor {
    /// A query builder bound to this executor.
    public var query: BoundQueryBuilder<Dialect> {
        BoundQueryBuilder(executor: erased)
    }

    public func select<each V: SQLColumnValue>(
        _ columns: repeat SQLExpression<each V>
    ) -> SelectQuery<Dialect, repeat each V> {
        query.select(repeat each columns)
    }

    public func insert<T: SQLTable>(into table: T) -> InsertQuery<Dialect, T> {
        query.insert(into: table)
    }

    public func update<T: SQLTable>(_ table: T) -> UpdateQuery<Dialect, T> {
        query.update(table)
    }

    public func delete<T: SQLTable>(from table: T) -> DeleteQuery<Dialect, T> {
        query.delete(from: table)
    }

    public func raw(_ fragment: SQLFragment) -> RawQuery<Dialect> {
        query.raw(fragment)
    }

    public func raw(_ sql: String, _ values: [SQLValue]) -> RawQuery<Dialect> {
        query.raw(sql, values)
    }
}

/// Same surface as `QueryBuilder`, except everything it produces knows where to run.
public struct BoundQueryBuilder<D: SQLDialect>: Sendable {
    let executor: AnySQLExecutor

    public init(executor: AnySQLExecutor) { self.executor = executor }

    public func select<each V: SQLColumnValue>(
        _ columns: repeat SQLExpression<each V>
    ) -> SelectQuery<D, repeat each V> {
        var query = QueryBuilder<D>().select(repeat each columns)
        query.boundExecutor = executor
        return query
    }

    public func insert<T: SQLTable>(into table: T) -> InsertQuery<D, T> {
        var query = InsertQuery<D, T>(into: table)
        query.boundExecutor = executor
        return query
    }

    public func update<T: SQLTable>(_ table: T) -> UpdateQuery<D, T> {
        var query = UpdateQuery<D, T>(table)
        query.boundExecutor = executor
        return query
    }

    public func delete<T: SQLTable>(from table: T) -> DeleteQuery<D, T> {
        var query = DeleteQuery<D, T>(from: table)
        query.boundExecutor = executor
        return query
    }

    public func raw(_ fragment: SQLFragment) -> RawQuery<D> {
        var query = RawQuery<D>(fragment)
        query.boundExecutor = executor
        return query
    }

    public func raw(_ sql: String, _ values: [SQLValue]) -> RawQuery<D> {
        raw(SQLFragment.raw(sql, values))
    }
}

/// A terminal operation was called with no `on:` on a query that was never bound.
public struct SQLQueryNotBound: Error, Sendable, CustomStringConvertible {
    public var description: String {
        "this query was built with QueryBuilder, which has no connection — "
            + "pass one with `on:`, or start from `db.select(…)` to bind it"
    }
}

/// Queries that can carry the executor they were built from.
public protocol SQLBoundQuery: SQLQueryConvertible {
    var boundExecutor: AnySQLExecutor? { get set }
}

extension SQLBoundQuery {
    func requireExecutor() throws -> AnySQLExecutor {
        guard let boundExecutor else { throw SQLQueryNotBound() }
        return boundExecutor
    }
}

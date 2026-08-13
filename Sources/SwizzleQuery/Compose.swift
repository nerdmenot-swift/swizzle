import SwizzleCore

// MARK: - Common table expressions

extension BoundQueryBuilder {
    /// Starts a `WITH` clause on a query that will remember this connection.
    public func with<each S: SQLColumnValue>(
        _ name: String, columns: [String] = [], as body: SelectQuery<D, repeat each S>
    ) -> CTEBuilder<D> {
        CTEBuilder(
            ctes: [SQLCommonTableExpression(name: name, columns: columns, body: body.core)],
            boundExecutor: executor
        )
    }

    public func withRecursive<each S: SQLColumnValue>(
        _ name: String, columns: [String] = [], as body: SelectQuery<D, repeat each S>
    ) -> CTEBuilder<D> {
        CTEBuilder(
            ctes: [SQLCommonTableExpression(
                name: name, columns: columns, body: body.core, isRecursive: true
            )],
            boundExecutor: executor
        )
    }
}

extension SQLExecutor {
    /// `WITH` from the executor, so a CTE query binds like any other.
    public func with<each S: SQLColumnValue>(
        _ name: String, columns: [String] = [], as body: SelectQuery<Dialect, repeat each S>
    ) -> CTEBuilder<Dialect> {
        query.with(name, columns: columns, as: body)
    }

    public func withRecursive<each S: SQLColumnValue>(
        _ name: String, columns: [String] = [], as body: SelectQuery<Dialect, repeat each S>
    ) -> CTEBuilder<Dialect> {
        query.withRecursive(name, columns: columns, as: body)
    }
}

extension QueryBuilder {
    /// Starts a `WITH` clause.
    ///
    /// ```swift
    /// db.with("recent", as: db.select(o.userID).from(o).where(o.createdAt > cutoff))
    ///   .select(u.id, u.name)
    ///   .from(u)
    ///   .where(sql("\(u.id) IN (SELECT \(identifier: "user_id") FROM \(identifier: "recent"))"))
    /// ```
    ///
    /// The body is an ordinary `SelectQuery`, so a CTE is built the same way
    /// everything else is — and prints, renders and inspects the same way too.
    public func with<each S: SQLColumnValue>(
        _ name: String,
        columns: [String] = [],
        as body: SelectQuery<D, repeat each S>
    ) -> CTEBuilder<D> {
        CTEBuilder(ctes: [
            SQLCommonTableExpression(name: name, columns: columns, body: body.core)
        ])
    }

    /// `WITH RECURSIVE` — the anchor and the recursive term joined by `UNION ALL`.
    ///
    /// Spelled separately because the recursion is the whole point and burying it
    /// behind a boolean flag would hide it. `RECURSIVE` renders once for the
    /// clause, as SQL requires, however many bindings there are.
    public func withRecursive<each S: SQLColumnValue>(
        _ name: String,
        columns: [String] = [],
        as body: SelectQuery<D, repeat each S>
    ) -> CTEBuilder<D> {
        CTEBuilder(ctes: [
            SQLCommonTableExpression(name: name, columns: columns, body: body.core, isRecursive: true)
        ])
    }
}

/// A `WITH` clause waiting for the query it precedes.
public struct CTEBuilder<D: SQLDialect>: Sendable {
    var ctes: [SQLCommonTableExpression]
    /// Carried through so a `WITH` started from `db.with(…)` still produces a
    /// query that knows its connection.
    var boundExecutor: AnySQLExecutor?

    /// Another binding in the same `WITH`.
    public func with<each S: SQLColumnValue>(
        _ name: String,
        columns: [String] = [],
        as body: SelectQuery<D, repeat each S>
    ) -> CTEBuilder<D> {
        var copy = self
        copy.ctes.append(
            SQLCommonTableExpression(name: name, columns: columns, body: body.core)
        )
        return copy
    }

    public func withRecursive<each S: SQLColumnValue>(
        _ name: String,
        columns: [String] = [],
        as body: SelectQuery<D, repeat each S>
    ) -> CTEBuilder<D> {
        var copy = self
        copy.ctes.append(
            SQLCommonTableExpression(name: name, columns: columns, body: body.core, isRecursive: true)
        )
        return copy
    }

    /// The query the `WITH` applies to.
    public func select<each V: SQLColumnValue>(
        _ columns: repeat SQLExpression<each V>
    ) -> SelectQuery<D, repeat each V> {
        var core = SQLSelectCore()
        core.ctes = ctes
        for column in repeat each columns {
            core.projection.append(column.node)
        }
        var query = SelectQuery<D, repeat each V>(core: core)
        query.boundExecutor = boundExecutor
        return query
    }

    // No `table(_:)` here. It returned an `SQLSource` that nothing accepts —
    // dead public API that read as if a CTE could be used where a table can.
    // `from(cte:)` is the way, and its documentation covers the alias the
    // qualifiers need.
}

extension SelectQuery {
    /// Selects from a CTE by name.
    ///
    /// Project the columns from a table **aliased to the CTE's name**, so the
    /// qualifiers match what the `FROM` actually names:
    ///
    /// ```swift
    /// let high = Users(tableAlias: "high")          // qualifies as "high"
    /// db.with("high", as: …)
    ///   .select(high.id, high.name)                  // SELECT "high"."id", …
    ///   .from(cte: "high")                           // FROM "high"
    /// ```
    ///
    /// Using the unaliased table instead yields
    /// `SELECT "users"."id" … FROM "high"`, which the server rejects — the CTE
    /// is the only thing in scope, and it is not called `users`. Drizzle avoids
    /// the trap by making a CTE a first-class table object; here the alias does
    /// the same job with nothing new to learn.
    public func from(cte name: String) -> Self {
        var copy = self
        copy.core.from = .table(schema: nil, name: name, alias: nil)
        return copy
    }
}

// MARK: - Set operations

extension SelectQuery {
    /// `UNION` — distinct rows from both sides.
    ///
    /// The operand's projection pack must match this one's, which the type
    /// signature enforces: `SelectQuery<D, repeat each V>` on both sides means a
    /// column-count or column-type mismatch is a compile error rather than a
    /// server error about differing numbers of columns.
    public func union(_ other: SelectQuery<D, repeat each V>) -> Self {
        appending(.union, other)
    }

    /// `UNION ALL` — keeps duplicates, and does not sort to find them.
    ///
    /// Almost always the one you want when you know the sides are disjoint.
    public func unionAll(_ other: SelectQuery<D, repeat each V>) -> Self {
        appending(.unionAll, other)
    }

    /// `INTERSECT` — rows present in both.
    public func intersect(_ other: SelectQuery<D, repeat each V>) -> Self {
        appending(.intersect, other)
    }

    /// `EXCEPT` — rows in this query and not the other.
    ///
    /// MySQL and MariaDB spell it `EXCEPT` too, since 8.0.31 and 10.3
    /// respectively. Older servers reject it, which is a version question rather
    /// than a dialect one — so it is not capability-gated.
    public func except(_ other: SelectQuery<D, repeat each V>) -> Self {
        appending(.except, other)
    }

    private func appending(
        _ kind: SQLSetOperation.Kind, _ other: SelectQuery<D, repeat each V>
    ) -> Self {
        var copy = self
        copy.core.setOperations.append(SQLSetOperation(kind: kind, body: other.core))
        return copy
    }
}

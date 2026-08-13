import SwizzleCore

/// The parts of SQL that would otherwise force a whole query to be rewritten as
/// raw text.
///
/// ## The audit this came from
///
/// Every SQL construct was checked against the builder, asking one question: can
/// it be expressed *without* abandoning the builder? Most could. Expressions have
/// always had a door — window functions, `CASE`, `CAST`, `ROLLUP` and anything
/// else go in as a typed fragment, because a fragment is an expression and
/// expressions compose.
///
/// What had no door was everything that is **not** an expression:
///
/// | wanted | was |
/// |---|---|
/// | `FOR UPDATE`, `SKIP LOCKED` | impossible — nothing renders after `LIMIT` |
/// | `INSERT … SELECT` | impossible — `INSERT` only knew `VALUES` |
/// | `FROM generate_series(…)` | impossible — `from` took a table or a subquery |
/// | `RIGHT JOIN`, `CROSS JOIN` | in the IR, never exposed |
/// | index hints, vendor clauses | impossible |
///
/// Each of those meant dropping the entire statement to `raw`, losing typed
/// results, capability gating and every bound column, to add four words at the
/// end. That is the wrong shape for a last resort: the escape hatch should be
/// proportional to what you are escaping.
///
/// The first four get real API below. The long tail gets ``appending(_:)`` — a
/// verbatim fragment after every other clause — so a construct nobody has thought
/// of yet still does not require a rewrite.

// MARK: - The general escape

extension SelectQuery {
    /// Appends a fragment after every other clause.
    ///
    /// The guarantee that the builder is never a dead end. Interpolation still
    /// binds, so this stays safe:
    ///
    /// ```swift
    /// db.select(u.id).from(u).appending("FOR UPDATE OF \(identifier: "users")")
    /// ```
    ///
    /// Reach for the named methods when one exists — they are checked, this is
    /// not. This is for the clause we have not modelled.
    ///
    /// Interpolating a value into a comment or a string literal is **refused** —
    /// the placeholder would land somewhere the server never reads it while the
    /// value is still sent, and the driver's reply (*"statement expects 1
    /// parameters, got 2"*) names neither the query nor the interpolation. The
    /// render catches it first and says to use `\(inline:)`, which writes an
    /// escaped literal and binds nothing. See ``SQLBindingInDeadPosition``.
    public func appending(_ fragment: SQLFragment) -> Self {
        var copy = self
        copy.core.trailing.append(fragment.node)
        return copy
    }
}

extension UpdateQuery {
    /// Appends a fragment after every other clause. See ``SelectQuery/appending(_:)``.
    public func appending(_ fragment: SQLFragment) -> Self {
        var copy = self
        copy.core.trailing.append(fragment.node)
        return copy
    }
}

extension DeleteQuery {
    /// Appends a fragment after every other clause. See ``SelectQuery/appending(_:)``.
    public func appending(_ fragment: SQLFragment) -> Self {
        var copy = self
        copy.core.trailing.append(fragment.node)
        return copy
    }
}

extension InsertQuery {
    /// Appends a fragment after every other clause. See ``SelectQuery/appending(_:)``.
    public func appending(_ fragment: SQLFragment) -> Self {
        var copy = self
        copy.trailing.append(fragment.node)
        return copy
    }
}

// MARK: - Row locking

extension SelectQuery where D: SupportsRowLocking {
    /// `FOR UPDATE` — take a write lock on every row this returns.
    ///
    /// The read half of read-modify-write, and the reason it was worth its own
    /// method rather than leaving it to ``appending(_:)``: getting it wrong is
    /// not a syntax error, it is a lost update under concurrency, which shows up
    /// as data that is quietly incorrect rather than as a failure.
    ///
    /// ```swift
    /// let job = try await db.select(j.id, j.payload).from(j)
    ///     .where(j.state == "pending")
    ///     .limit(1)
    ///     .forUpdate(.skipLocked)          // the queue-worker pattern
    ///     .fetchFirst()
    /// ```
    ///
    /// - Parameter wait: `.skipLocked` steps over rows another transaction holds,
    ///   which is what makes a table usable as a work queue. `.noWait` fails fast
    ///   instead of blocking. Both need MySQL 8.0.1+ or MariaDB 10.6+; the
    ///   default `.wait` works everywhere.
    public func forUpdate(_ wait: SQLLocking.Wait = .wait) -> Self {
        locking(.update, wait)
    }

    /// `FOR SHARE` — block writers, allow other readers.
    public func forShare(_ wait: SQLLocking.Wait = .wait) -> Self {
        locking(.share, wait)
    }

    private func locking(_ strength: SQLLocking.Strength, _ wait: SQLLocking.Wait) -> Self {
        var copy = self
        copy.core.locking = SQLLocking(strength: strength, wait: wait)
        return copy
    }
}

extension SelectQuery where D: SupportsWeakRowLocking {
    /// `FOR NO KEY UPDATE` — Postgres. Blocks deletes and key updates, but not
    /// the `FOR KEY SHARE` a foreign-key check takes.
    public func forNoKeyUpdate(_ wait: SQLLocking.Wait = .wait) -> Self {
        var copy = self
        copy.core.locking = SQLLocking(strength: .noKeyUpdate, wait: wait)
        return copy
    }

    /// `FOR KEY SHARE` — Postgres. The weakest form, what a foreign-key check takes.
    public func forKeyShare(_ wait: SQLLocking.Wait = .wait) -> Self {
        var copy = self
        copy.core.locking = SQLLocking(strength: .keyShare, wait: wait)
        return copy
    }
}

// MARK: - INSERT … SELECT

extension InsertQuery {
    /// Fills the insert from a query instead of a `VALUES` list.
    ///
    /// The shape of every backfill and every copy-with-transformation, and it was
    /// simply missing: `INSERT` knew only literal rows.
    ///
    /// ```swift
    /// db.insert(into: archive)
    ///   .columns(archive.id, archive.body)
    ///   .select(db.select(d.id, d.body).from(d).where(d.createdAt < cutoff))
    /// ```
    ///
    /// Name the columns first — the select's projection fills them in order, and
    /// without the column list the server matches by position against the whole
    /// table, which is a silent corruption waiting for the next migration to add
    /// a column.
    public func select<each S: SQLColumnValue>(
        _ query: SelectQuery<D, repeat each S>
    ) -> Self {
        var copy = self
        copy.selectSource = query.core
        return copy
    }

    /// Names the columns an ``select(_:)`` will fill.
    public func columns<each C>(_ columns: repeat SQLExpression<each C>) -> Self {
        var names: [String] = []
        for column in repeat each columns {
            if let name = column.columnName { names.append(name) }
        }
        var copy = self
        copy.columns = names
        return copy
    }
}

// MARK: - Sources that are not tables

extension SelectQuery {
    /// Selects from a hand-written source — a table-valued function,
    /// `UNNEST(…)`, `generate_series(…)`, a vendor extension.
    ///
    /// `FROM` is the one clause ``appending(_:)`` cannot reach, since it sits in
    /// the middle of the statement rather than the end.
    ///
    /// ```swift
    /// db.select(n).from(sql: "generate_series(1, \(100))", as: "n")
    /// ```
    public func from(sql fragment: SQLFragment, as alias: String? = nil) -> Self {
        var copy = self
        copy.core.from = .fragment(fragment.node, alias: alias)
        return copy
    }
}

// MARK: - The remaining join kinds

extension SelectQuery {
    /// `RIGHT JOIN`. Present in the IR from the start and never exposed, which is
    /// its own kind of limitation.
    public func rightJoin(_ table: some SQLTable, on predicate: SQLExpression<Bool>) -> Self {
        var copy = self
        copy.core.joins.append(SQLJoin(kind: .right, source: table.source, on: predicate.node))
        return copy
    }

    /// `CROSS JOIN` — every row against every row, so it takes no `ON`.
    public func crossJoin(_ table: some SQLTable) -> Self {
        var copy = self
        copy.core.joins.append(SQLJoin(kind: .cross, source: table.source, on: nil))
        return copy
    }

    /// Joins a subquery.
    public func innerJoin<each S: SQLColumnValue>(
        _ subquery: SelectQuery<D, repeat each S>, as alias: String,
        on predicate: SQLExpression<Bool>
    ) -> Self {
        var copy = self
        copy.core.joins.append(
            SQLJoin(kind: .inner, source: .subquery(subquery.core, alias: alias), on: predicate.node)
        )
        return copy
    }

    /// Left-joins a subquery.
    public func leftJoin<each S: SQLColumnValue>(
        _ subquery: SelectQuery<D, repeat each S>, as alias: String,
        on predicate: SQLExpression<Bool>
    ) -> Self {
        var copy = self
        copy.core.joins.append(
            SQLJoin(kind: .left, source: .subquery(subquery.core, alias: alias), on: predicate.node)
        )
        return copy
    }
}

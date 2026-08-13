import SwizzleCore

/// Collects `column = expression` pairs for a `SET` clause.
///
/// Carries the dialect so the sub-expressions each engine offers inside an upsert
/// are gated the same way the clause itself is: `excluded` exists only where
/// `ON CONFLICT` does, `values` only where `ON DUPLICATE KEY UPDATE` does.
public struct SQLAssignmentList<D: SQLDialect>: Sendable {
    public private(set) var assignments: [SQLAssignment] = []

    public init() {}

    /// Assigns a literal.
    public mutating func set<V: SQLColumnValue>(_ column: SQLExpression<V>, to value: V) {
        assignments.append(SQLAssignment(target: column.node, value: .bind(value.sqlValue)))
    }

    /// Assigns an expression — `views = views + 1`, `updated_at = NOW()`.
    public mutating func set<V>(_ column: SQLExpression<V>, to expression: SQLExpression<V>) {
        assignments.append(SQLAssignment(target: column.node, value: expression.node))
    }
}

extension SQLAssignmentList where D: SupportsOnConflict {
    /// `EXCLUDED.col` — the row that *would* have been inserted.
    ///
    /// Postgres and SQLite only. The MySQL equivalent is `values(_:)`, spelled
    /// differently because MySQL spells it differently.
    public func excluded<V>(_ column: SQLExpression<V>) -> SQLExpression<V> {
        guard let name = column.columnName else { return column }
        return SQLExpression(.excluded(name))
    }
}

extension SQLAssignmentList where D: SupportsOnDuplicateKeyUpdate {
    /// ``VALUES(`col`)`` — the row that *would* have been inserted.
    ///
    /// MySQL and MariaDB only. The Postgres equivalent is `excluded(_:)`.
    public func values<V>(_ column: SQLExpression<V>) -> SQLExpression<V> {
        guard let name = column.columnName else { return column }
        return SQLExpression(.valuesOf(name))
    }
}

/// Collects one row's worth of column/value pairs for an `INSERT`.
public struct SQLInsertRow: Sendable {
    public private(set) var pairs: [(column: String, value: SQLValue)] = []

    public init() {}

    public mutating func set<V: SQLColumnValue>(_ column: SQLExpression<V>, to value: V) {
        guard let name = column.columnName else { return }
        pairs.append((name, value.sqlValue))
    }
}

/// An `INSERT` under construction.
public struct InsertQuery<D: SQLDialect, T: SQLTable>: Sendable {
    public var table: T
    public var boundExecutor: AnySQLExecutor?
    public var columns: [String] = []
    public var selectSource: SQLSelectCore?
    public var trailing: [SQLNode] = []
    public var rows: [[SQLValue]] = []
    public var ignoreDuplicates: Bool = false
    public var conflictTargets: [String] = []
    public var conflictAction: SQLInsertCore.ConflictAction?
    public var duplicateKeyUpdates: [SQLAssignment] = []
    public var returning: [SQLNode] = []

    public init(into table: T) { self.table = table }

    /// Adds a row, typed against the table's columns.
    ///
    /// ```swift
    /// db.insert(into: u).values { $0.set(u.email, to: "ada@example.com") }
    /// ```
    ///
    /// Call it more than once for a multi-row insert. The first row fixes the
    /// column list; later rows are read in that same order, so a row that names
    /// a different set of columns would silently misalign — which is why the
    /// column list is taken once rather than merged.
    public func values(_ build: (inout SQLInsertRow) -> Void) -> Self {
        var row = SQLInsertRow()
        build(&row)
        var copy = self
        if copy.columns.isEmpty { copy.columns = row.pairs.map(\.column) }
        copy.rows.append(row.pairs.map(\.value))
        return copy
    }

    /// The untyped form, for values assembled dynamically.
    public func values(_ assignments: [(String, SQLValue)]) -> Self {
        var copy = self
        if copy.columns.isEmpty { copy.columns = assignments.map(\.0) }
        copy.rows.append(assignments.map(\.1))
        return copy
    }
}

// MARK: - Upsert: Postgres and SQLite

extension InsertQuery where D: SupportsOnConflict {
    /// `ON CONFLICT (targets) …` — names the constraint it reacts to.
    ///
    /// Deliberately **not** unified with MySQL's `onDuplicateKeyUpdate`. They are
    /// different operations, not one operation with two names: this one names a
    /// conflict target, MySQL's reacts to whichever unique key happened to
    /// collide. A portable `.upsert()` would have to drop the target on MySQL or
    /// pretend MySQL could express one, and the caller could not tell which had
    /// happened. So each engine keeps its own spelling, and portability is a
    /// property of what you write rather than something the API pretends about.
    public func onConflict<each C>(_ targets: repeat SQLExpression<each C>) -> ConflictClause<D, T> {
        var names: [String] = []
        for target in repeat each targets {
            if let name = target.columnName { names.append(name) }
        }
        var copy = self
        copy.conflictTargets = names
        return ConflictClause(insert: copy)
    }

    /// `ON CONFLICT` with no target — any conflict at all.
    public func onConflict() -> ConflictClause<D, T> {
        ConflictClause(insert: self)
    }
}

/// The half-built `ON CONFLICT`, waiting for its action.
///
/// A separate type only because SQL genuinely has two clauses here: naming a
/// target and choosing an action are distinct decisions, and `DO UPDATE` /
/// `DO NOTHING` is exactly the choice the SQL makes you spell out too.
public struct ConflictClause<D: SQLDialect, T: SQLTable>: Sendable {
    var insert: InsertQuery<D, T>

    /// `DO NOTHING`.
    public func doNothing() -> InsertQuery<D, T> {
        var copy = insert
        copy.conflictAction = .nothing
        return copy
    }

    /// `DO UPDATE SET …`.
    ///
    /// ```swift
    /// .onConflict(u.email).doUpdate { $0.set(u.name, to: $0.excluded(u.name)) }
    /// ```
    public func doUpdate(_ build: (inout SQLAssignmentList<D>) -> Void) -> InsertQuery<D, T> {
        var list = SQLAssignmentList<D>()
        build(&list)
        var copy = insert
        copy.conflictAction = .update(list.assignments)
        return copy
    }
}

// MARK: - Upsert: MySQL and MariaDB

extension InsertQuery where D: SupportsOnDuplicateKeyUpdate {
    /// `ON DUPLICATE KEY UPDATE …` — reacts to whichever unique key collided.
    ///
    /// ```swift
    /// .onDuplicateKeyUpdate { $0.set(u.name, to: $0.values(u.name)) }
    /// ```
    public func onDuplicateKeyUpdate(_ build: (inout SQLAssignmentList<D>) -> Void) -> Self {
        var list = SQLAssignmentList<D>()
        build(&list)
        var copy = self
        copy.duplicateKeyUpdates = list.assignments
        return copy
    }
}

// MARK: - MySQL / MariaDB / SQLite

extension InsertQuery where D: SupportsInsertIgnore {
    public func orIgnore() -> Self {
        var copy = self
        copy.ignoreDuplicates = true
        return copy
    }
}

// MARK: - Postgres / SQLite / MariaDB (not MySQL)

extension InsertQuery where D: SupportsReturning {
    public func returning<each R: SQLColumnValue>(
        _ columns: repeat SQLExpression<each R>
    ) -> ReturningInsert<D, T, repeat each R> {
        var copy = self
        for column in repeat each columns {
            copy.returning.append(column.node)
        }
        return ReturningInsert(insert: copy)
    }
}

public struct ReturningInsert<D: SQLDialect, T: SQLTable, each R: SQLColumnValue>: @unchecked Sendable {
    public var insert: InsertQuery<D, T>

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

extension InsertQuery {
    /// The dialect-neutral description the renderer consumes.
    var core: SQLInsertCore {
        var core = SQLInsertCore(table: T.tableName)
        core.columns = columns
        core.rows = rows
        core.selectSource = selectSource
        core.trailing = trailing
        core.ignoreDuplicates = ignoreDuplicates
        core.conflictTargets = conflictTargets
        core.conflictAction = conflictAction
        core.duplicateKeyUpdates = duplicateKeyUpdates
        core.returning = returning
        return core
    }
}

extension InsertQuery: SQLQueryConvertible {
    public typealias Dialect = D
    public func render(into renderer: inout SQLRenderer<D>) {
        renderer.renderInsert(core)
    }
}

extension ReturningInsert: SQLQueryConvertible {
    public typealias Dialect = D
    public func render(into renderer: inout SQLRenderer<D>) {
        insert.render(into: &renderer)
    }
}

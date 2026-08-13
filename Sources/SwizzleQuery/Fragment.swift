import SwizzleCore

/// A piece of hand-written SQL that still participates in binding.
///
/// No builder covers everything, and the ones that pretend to are the ones people
/// end up fighting. The requirement is that an escape hatch **composes**: a raw
/// fragment must slot into a clause, not force you to abandon the builder for the
/// whole statement.
///
/// Build one with string interpolation and the pieces sort themselves out:
///
/// ```swift
/// .where(sql("\(u.score) > \(threshold) AND \(u.name) LIKE \(pattern)"))
/// ```
///
/// `\(u.score)` renders a properly quoted, qualified column. `\(threshold)`
/// becomes a placeholder with the value travelling out of band. Nothing in that
/// line can be a SQL injection, which is the difference between this and building
/// the string yourself.
///
/// ## What it deliberately does not do
///
/// A fragment is never parsed, validated, or rewritten. It is the escape hatch,
/// and making it clever would defeat the reason it exists. The compile-time help
/// sits at the edges instead, where it is free: interpolated columns are still
/// typed expressions, so renaming a column breaks every fragment mentioning it.
public struct SQLFragment: Sendable, ExpressibleByStringInterpolation {
    public var parts: [SQLNode]

    /// Set when this fragment came from ``raw(_:_:)`` with the wrong number of
    /// values. Carried rather than thrown so the chain stays non-throwing;
    /// execution reports it.
    public internal(set) var mismatch: SQLPlaceholderMismatch?

    public init(parts: [SQLNode]) { self.parts = parts }

    public init(stringLiteral value: String) {
        self.parts = value.isEmpty ? [] : [.raw(value)]
    }

    public init(stringInterpolation: StringInterpolation) {
        self.parts = stringInterpolation.parts
    }

    /// The IR this fragment contributes.
    public var node: SQLNode { .fragment(parts) }

    public struct StringInterpolation: StringInterpolationProtocol {
        public typealias StringLiteralType = String
        var parts: [SQLNode] = []

        public init(literalCapacity: Int, interpolationCount: Int) {
            parts.reserveCapacity(interpolationCount * 2 + 1)
        }

        public mutating func appendLiteral(_ literal: String) {
            guard !literal.isEmpty else { return }
            parts.append(.raw(literal))
        }

        /// A value. Becomes a placeholder; the value never enters the SQL text.
        public mutating func appendInterpolation(_ value: some SQLColumnValue) {
            parts.append(.bind(value.sqlValue))
        }

        /// A column or any other expression the builder already understands.
        public mutating func appendInterpolation<V>(_ expression: SQLExpression<V>) {
            parts.append(expression.node)
        }

        /// Another fragment, so fragments nest.
        public mutating func appendInterpolation(_ fragment: SQLFragment) {
            parts.append(contentsOf: fragment.parts)
        }

        /// A whole sub-SELECT, parenthesised, with its bindings threaded through
        /// in the right order.
        public mutating func appendInterpolation<D: SQLDialect, each S: SQLColumnValue>(
            _ subquery: SelectQuery<D, repeat each S>
        ) {
            parts.append(.selectSubquery(subquery.core))
        }

        /// A comma-separated, parenthesised list — for `IN (…)`.
        ///
        /// Every element binds, so this is safe with a list that came from
        /// outside. Drizzle needs a separate `inArray()` helper for the same job;
        /// here it is just interpolation.
        public mutating func appendInterpolation(list values: [some SQLColumnValue]) {
            parts.append(.list(values.map { .bind($0.sqlValue) }))
        }

        /// A name to be quoted for this dialect. Use when the *identifier* is
        /// dynamic — a partition or tenant table chosen at runtime.
        public mutating func appendInterpolation(identifier name: String) {
            parts.append(.identifier(name))
        }

        /// Splices text verbatim: no binding, no quoting, no escaping.
        ///
        /// The equivalent of Drizzle's `sql.raw`, and like it, usable either as a
        /// chunk inside an otherwise-safe fragment or as an entire statement.
        ///
        /// - Important: deliberately ugly to type. If a value from outside your
        ///   program reaches this, you have an injection. Reach for
        ///   `\(identifier:)` for dynamic names and plain interpolation for
        ///   values; this is for SQL text your program authored.
        public mutating func appendInterpolation(unescaped sql: String) {
            parts.append(.raw(sql))
        }

        /// Writes a value into the SQL text as an escaped literal instead of
        /// binding it.
        ///
        /// For the positions a database will not let you parameterise at all —
        /// `COLLATE`, several `SET` forms, parts of DDL — where the only other
        /// option is abandoning the builder. Ecto calls this `constant()`.
        ///
        /// Safe in the way `\(unescaped:)` is not: the value is still quoted and
        /// escaped for the dialect. The real cost is elsewhere — an inlined value
        /// is part of the statement text, so every distinct value is a distinct
        /// prepared-statement cache entry. Bind when you can; inline when the
        /// database refuses.
        public mutating func appendInterpolation(inline value: some SQLColumnValue) {
            parts.append(.literal(value.sqlValue))
        }
    }
}

// MARK: - Composition

extension SQLFragment {
    /// Concatenation, with no separator inserted — write your own spacing, the
    /// same as within a single fragment.
    public static func + (lhs: Self, rhs: Self) -> Self {
        var joined = SQLFragment(parts: lhs.parts + rhs.parts)
        joined.mismatch = lhs.mismatch ?? rhs.mismatch
        return joined
    }

    public static func += (lhs: inout Self, rhs: Self) {
        lhs.parts.append(contentsOf: rhs.parts)
        lhs.mismatch = lhs.mismatch ?? rhs.mismatch
    }

    /// An empty fragment, to append onto.
    public static var empty: Self { SQLFragment(parts: []) }

    public var isEmpty: Bool { parts.isEmpty }
}

extension Collection where Element == SQLFragment {
    /// Joins fragments with a separator.
    ///
    /// This is what Drizzle spreads across `sql.empty()`, `.append()`,
    /// `sql.join()` and `sql.fromList()` — four named constructors for building a
    /// clause out of a variable number of pieces. In Swift the ordinary
    /// collection vocabulary already covers it.
    ///
    /// Worth knowing before reaching for it: for the common case of a `WHERE`
    /// assembled from optional filters, `.where()` accumulates and ANDs, so a
    /// plain loop over `.where()` needs no fragments at all.
    public func joined(separator: SQLFragment) -> SQLFragment {
        var parts: [SQLNode] = []
        var mismatch: SQLPlaceholderMismatch?
        for (index, fragment) in enumerated() {
            if index > 0 { parts.append(contentsOf: separator.parts) }
            parts.append(contentsOf: fragment.parts)
            mismatch = mismatch ?? fragment.mismatch
        }
        var joined = SQLFragment(parts: parts)
        joined.mismatch = mismatch
        return joined
    }

    public func joined(separator: String) -> SQLFragment {
        joined(separator: SQLFragment(stringLiteral: separator))
    }
}

// MARK: - Entry points

/// A fragment used as a **predicate** — in `where`, `having`, or a join `on`.
///
/// No type parameter, because there is nothing to decide: a predicate is a
/// boolean.
public func sql(_ fragment: SQLFragment) -> SQLExpression<Bool> {
    SQLExpression(fragment.node)
}

/// A fragment used as a **value** — in a projection, an `ORDER BY`, or a `SET`.
///
/// The type is needed here and only here, because the result tuple has to name
/// it. Which of the two forms you use follows from where the fragment sits rather
/// than from a preference, so it stays consistent: getting it wrong is a plain
/// compile error, not a subtly different API.
///
/// The type is a claim about what the expression evaluates to, and nothing checks
/// it at compile time. It is not, however, silently wrong: it is the instruction
/// the decoder follows, so `T(sqlValue:)` throws `SQLDecodeError` on the first row
/// if the claim was false. (Drizzle's `sql<T>` performs no runtime mapping at all,
/// and needs a second knob — `.mapWith()` — to actually convert.)
public func sql<T>(_ fragment: SQLFragment, as type: T.Type) -> SQLExpression<T> {
    SQLExpression(fragment.node)
}

extension SQLExpression {
    /// Reads a fragment as an expression of this type, for call sites where the
    /// type is already known from context.
    public init(sql fragment: SQLFragment) {
        self.init(fragment.node)
    }
}

// MARK: - A fragment as an entire statement

/// A hand-written statement that still binds its values, and still renders,
/// prints and inspects like anything else the builder produces.
///
/// The other half of the escape hatch: a fragment works as a *chunk* inside a
/// built query and as the *whole* query, the same way Drizzle's `sql` does. The
/// difference from dropping to the driver is that this keeps binding, keeps
/// dialect-correct placeholders and quoting, and keeps `debugSQL`.
public struct RawQuery<D: SQLDialect>: Sendable {
    public var fragment: SQLFragment
    public var boundExecutor: AnySQLExecutor?

    public init(_ fragment: SQLFragment) { self.fragment = fragment }
}

extension RawQuery: SQLQueryConvertible {
    public typealias Dialect = D
    public func render(into renderer: inout SQLRenderer<D>) {
        renderer.render(fragment.node)
    }
}

extension QueryBuilder {
    /// An entire statement written by hand.
    ///
    /// ```swift
    /// try await db.raw("SELECT * FROM report_view WHERE day = \(day)")
    ///     .fetch((Date, Int).self, on: connection)
    /// ```
    public func raw(_ fragment: SQLFragment) -> RawQuery<D> {
        RawQuery(fragment)
    }

    /// A statement written by hand, with `?` placeholders and their values.
    ///
    /// The path for SQL you already have. `?` works on every dialect — Postgres
    /// gets `$1`, `$2` on render — so a query pasted out of a MySQL session runs
    /// unchanged.
    ///
    /// ```swift
    /// db.raw("SELECT id FROM users WHERE age > ? AND city = ?", [.int(18), .text("Pune")])
    /// ```
    public func raw(_ sql: String, _ values: [SQLValue]) -> RawQuery<D> {
        RawQuery(SQLFragment.raw(sql, values))
    }
}

extension RawQuery {
    /// Runs the statement and decodes each row into the tuple you name.
    ///
    /// The tuple is a claim about the statement's shape, and like a typed
    /// fragment it is checked by the decoder rather than the compiler: a column
    /// that will not convert throws `SQLDecodeError` on the first row.
    public func fetch<each T: SQLColumnValue, Executor: SQLExecutor>(
        _ types: (repeat each T).Type,
        on executor: Executor
    ) async throws -> [(repeat each T)] where Executor.Dialect == D {
        try checkPlaceholders()
        let (sql, bindings) = try buildChecked()
        let rows = try await executor.execute(sql: sql, bindings: bindings)
        return try rows.map { row in
            var index = 0
            return (repeat try Self.decodeNext((each T).self, row, &index))
        }
    }

    /// Runs the statement and returns the rows untyped.
    @discardableResult
    public func fetchRows<Executor: SQLExecutor>(
        on executor: Executor
    ) async throws -> [SQLRow] where Executor.Dialect == D {
        try checkPlaceholders()
        let (sql, bindings) = try buildChecked()
        return try await executor.execute(sql: sql, bindings: bindings)
    }

    /// Runs a statement that returns no rows, reporting how many it changed.
    @discardableResult
    public func execute<Executor: SQLExecutor>(
        on executor: Executor
    ) async throws -> Int where Executor.Dialect == D {
        try checkPlaceholders()
        let (sql, bindings) = try buildChecked()
        return try await executor.executeUpdate(sql: sql, bindings: bindings)
    }

    /// Refuses to run a statement whose `?` count did not match its values.
    ///
    /// Too few values would send a bare `?` to the server; too many would
    /// silently drop one. Both are worth stopping at the boundary rather than
    /// discovering from a driver error.
    func checkPlaceholders() throws {
        if let mismatch = fragment.mismatch { throw mismatch }
    }

    static func decodeNext<X: SQLColumnValue>(
        _ type: X.Type, _ row: SQLRow, _ index: inout Int
    ) throws -> X {
        defer { index += 1 }
        guard index < row.values.count else {
            throw SQLDecodeError(expected: "\(X.self) at column \(index)", actual: .null)
        }
        return try X(sqlValue: row.values[index])
    }
}

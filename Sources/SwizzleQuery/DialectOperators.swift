import SwizzleCore

// Operators that exist on some engines and not others.
//
// ## Why these are namespaced rather than capability-gated
//
// The capability protocols gate *clauses*: `.returning()` cannot be written
// against MySQL because it hangs off `SelectQuery<D, …>`, which knows its
// dialect. Operators do not have that. `SQLExpression<Value>` deliberately
// carries only a phantom *value* type — the whole reason deep query chains stay
// cheap to type-check is that the solver never reasons about anything else on it.
// Adding a dialect parameter would double the generic arity of the hottest type
// in the library, across every one of the twenty-odd operator overloads.
//
// So these hang off the dialect itself. `Postgres.ilike(…)` names the engine at
// the call site, which makes the wrong one obvious to read and to grep for, and
// costs the solver nothing. It is a weaker guarantee than a compile error, and
// stating that plainly is better than a gate that quietly makes every query
// slower to compile.

// MARK: - Postgres

extension Postgres {
    /// `ILIKE` — case-insensitive pattern match.
    ///
    /// Postgres is the only one of the four that has it. MySQL's default
    /// collation makes plain `LIKE` case-insensitive already; SQLite's `LIKE` is
    /// case-insensitive for ASCII only. Neither *is* `ILIKE`, and papering over
    /// the difference is how a query behaves one way in test and another in
    /// production.
    public static func ilike<V>(_ column: SQLExpression<V>, _ pattern: String) -> SQLExpression<Bool> {
        SQLExpression(.binary(column.node, "ILIKE", .bind(.text(pattern))))
    }

    /// `NOT ILIKE`.
    public static func notILike<V>(_ column: SQLExpression<V>, _ pattern: String) -> SQLExpression<Bool> {
        SQLExpression(.binary(column.node, "NOT ILIKE", .bind(.text(pattern))))
    }

    /// `~` — POSIX regular expression match.
    public static func matches<V>(_ column: SQLExpression<V>, _ pattern: String) -> SQLExpression<Bool> {
        SQLExpression(.binary(column.node, "~", .bind(.text(pattern))))
    }

    /// `~*` — the same, case-insensitive.
    public static func matchesInsensitive<V>(_ column: SQLExpression<V>, _ pattern: String) -> SQLExpression<Bool> {
        SQLExpression(.binary(column.node, "~*", .bind(.text(pattern))))
    }

    /// `@>` — does the left side contain the right? `jsonb` and arrays.
    public static func contains<V>(_ lhs: SQLExpression<V>, _ rhs: SQLExpression<V>) -> SQLExpression<Bool> {
        SQLExpression(.binary(lhs.node, "@>", rhs.node))
    }

    /// `@>` against a literal — the usual `jsonb` membership test.
    public static func contains<V>(_ lhs: SQLExpression<V>, _ json: String) -> SQLExpression<Bool> {
        SQLExpression(.binary(lhs.node, "@>", .bind(.text(json))))
    }

    /// `<@` — is the left side contained by the right?
    public static func containedBy<V>(_ lhs: SQLExpression<V>, _ rhs: SQLExpression<V>) -> SQLExpression<Bool> {
        SQLExpression(.binary(lhs.node, "<@", rhs.node))
    }

    /// `?` — does the `jsonb` object have this top-level key?
    ///
    /// Named `hasKey` rather than mirroring the operator: a bare `?` in the SQL
    /// text is indistinguishable from a placeholder to every tool that reads it,
    /// including our own `raw(_:_:)` scanner.
    public static func hasKey<V>(_ column: SQLExpression<V>, _ key: String) -> SQLExpression<Bool> {
        SQLExpression(.binary(column.node, "?", .bind(.text(key))))
    }

    /// `->>` — extract a JSON field as text.
    public static func text<V>(_ column: SQLExpression<V>, _ key: String) -> SQLExpression<String> {
        SQLExpression(.binary(column.node, "->>", .bind(.text(key))))
    }

    /// `->` — extract a JSON field as JSON.
    public static func json<V>(_ column: SQLExpression<V>, _ key: String) -> SQLExpression<V> {
        SQLExpression(.binary(column.node, "->", .bind(.text(key))))
    }
}

// MARK: - MySQL and MariaDB

/// How `MATCH … AGAINST` interprets the search term.
public enum FullTextMode: String, Sendable {
    case naturalLanguage = "IN NATURAL LANGUAGE MODE"
    case boolean = "IN BOOLEAN MODE"
    case queryExpansion = "WITH QUERY EXPANSION"
}

extension MySQL {
    /// `MATCH (columns) AGAINST (term …)` — full-text search.
    ///
    /// Takes a column *pack* rather than one column, because that is what the SQL
    /// takes: a full-text index covers a set of columns and `MATCH` has to name
    /// the same set. Hanging this off a single column would misrepresent it.
    public static func match<each C>(
        _ columns: repeat SQLExpression<each C>,
        against term: String,
        mode: FullTextMode = .naturalLanguage
    ) -> SQLExpression<Bool> {
        SQLExpression(fullTextNode(repeat each columns, against: term, mode: mode))
    }

    /// `JSON_EXTRACT(column, path)`, which MySQL also spells `column -> path`.
    public static func jsonExtract<V>(_ column: SQLExpression<V>, _ path: String) -> SQLExpression<V> {
        SQLExpression(.function("JSON_EXTRACT", [column.node, .bind(.text(path))]))
    }

    /// `JSON_UNQUOTE(JSON_EXTRACT(column, path))` — the `->>` form, as text.
    public static func jsonText<V>(_ column: SQLExpression<V>, _ path: String) -> SQLExpression<String> {
        SQLExpression(.function("JSON_UNQUOTE", [
            .function("JSON_EXTRACT", [column.node, .bind(.text(path))])
        ]))
    }
}

extension MariaDB {
    /// `MATCH (columns) AGAINST (term …)` — see ``MySQL/match(_:against:mode:)``.
    public static func match<each C>(
        _ columns: repeat SQLExpression<each C>,
        against term: String,
        mode: FullTextMode = .naturalLanguage
    ) -> SQLExpression<Bool> {
        SQLExpression(fullTextNode(repeat each columns, against: term, mode: mode))
    }
}

/// Shared by both MySQL-family dialects, which spell full text identically.
private func fullTextNode<each C>(
    _ columns: repeat SQLExpression<each C>,
    against term: String,
    mode: FullTextMode
) -> SQLNode {
    var parts: [SQLNode] = [.raw("MATCH (")]
    var isFirst = true
    for column in repeat each columns {
        if !isFirst { parts.append(.raw(", ")) }
        parts.append(column.node)
        isFirst = false
    }
    parts.append(.raw(") AGAINST ("))
    parts.append(.bind(.text(term)))
    parts.append(.raw(" \(mode.rawValue))"))
    return .fragment(parts)
}

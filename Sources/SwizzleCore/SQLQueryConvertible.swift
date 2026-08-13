/// Anything the builder can turn into SQL.
///
/// The single requirement is `render(into:)`; everything a caller actually
/// touches — `build()`, `sql`, `bindings`, `debugSQL`, `print(query)` — is a
/// default implementation on top of it. That is deliberate: rendering twice, once
/// with placeholders and once with values inlined, has to be the *same* traversal
/// or the debugging output stops being evidence about the real statement.
///
/// ## Why it inherits the printable protocols
///
/// So that seeing the SQL is never something you have to remember how to do.
/// `print(query)` works, `po query` in a debugger works, and Xcode's variable
/// inspector shows the statement — without an import, a helper, or an API call.
/// Conformance is forced by the protocol rather than left to each query type to
/// remember, which is what keeps it true for `UPDATE` and `DELETE` and for
/// whatever gets added next.
///
/// ## Rendering needs no connection
///
/// The dialect is a type parameter, so a `SelectQuery<Postgres, …>` knows how to
/// spell itself without a database anywhere. Generated SQL can be asserted in an
/// ordinary unit test with nothing running.
public protocol SQLQueryConvertible: CustomStringConvertible, CustomDebugStringConvertible {
    associatedtype Dialect: SQLDialect

    /// Writes this query into a renderer. The one thing a query must implement.
    func render(into renderer: inout SQLRenderer<Dialect>)
}

/// A value was interpolated somewhere the server will not read it as a parameter.
///
/// Almost always a comment: `appending("/* tenant \(id) */")` writes a
/// placeholder the server ignores, while the value is still sent alongside. The
/// driver then refuses the statement with *"expects 1 parameters, got 2"*, which
/// says nothing about which interpolation caused it.
///
/// The fix is `\(inline:)`, which writes an escaped literal and binds nothing —
/// exactly what a position that cannot hold a parameter needs.
public struct SQLBindingInDeadPosition: Error, Sendable, CustomStringConvertible {
    public let count: Int
    public let sql: String

    public var description: String {
        """
        \(count) interpolated value\(count == 1 ? "" : "s") landed inside a comment or \
        string literal, where the server will not read \(count == 1 ? "it" : "them") as a \
        parameter. Use \(String("\\(inline:)")) there instead — it writes an escaped \
        literal and binds nothing. Statement: \(sql)
        """
    }
}

extension SQLQueryConvertible {
    /// The statement and its ordered bindings, exactly as they go to the driver.
    public func build() -> (sql: String, bindings: [SQLValue]) {
        var renderer = SQLRenderer<Dialect>()
        render(into: &renderer)
        return (renderer.sql, renderer.bindings)
    }

    /// Renders, and refuses a statement carrying bindings the server cannot consume.
    ///
    /// Every execution path goes through this rather than `build()`. The check is
    /// a lexer advanced only through text that came from a fragment, so a query
    /// with no raw SQL in it pays nothing at all.
    public func buildChecked() throws -> (sql: String, bindings: [SQLValue]) {
        var renderer = SQLRenderer<Dialect>()
        render(into: &renderer)
        guard renderer.deadBindings == 0 else {
            throw SQLBindingInDeadPosition(count: renderer.deadBindings, sql: renderer.sql)
        }
        return (renderer.sql, renderer.bindings)
    }

    /// The statement as the server receives it: placeholders, values out of band.
    ///
    /// This is the string to compare against when a query misbehaves, because it
    /// is the one that actually ran.
    public var sql: String { build().sql }

    /// The values that travel alongside `sql`, in placeholder order.
    public var bindings: [SQLValue] { build().bindings }

    /// The same statement with values written inline, so it can be pasted into
    /// `mysql` or `psql` and run by hand.
    ///
    /// - Important: **For reading, never for executing.** Inlining values is
    ///   precisely the operation the binding layer exists to prevent; sending
    ///   this string to a server would reintroduce every injection the builder
    ///   had already closed. Nothing in Swizzle accepts it as input, and it
    ///   should not be passed to a raw-query call either.
    public var debugSQL: String {
        var renderer = SQLRenderer<Dialect>(inlineBindings: true)
        render(into: &renderer)
        return renderer.sql
    }

    /// Shows the wire form — the statement plus its bindings — because that is
    /// the honest answer to "what is this query". `debugSQL` is the paste-able
    /// one, and asking for it is a deliberate act.
    public var description: String {
        let (sql, bindings) = build()
        guard !bindings.isEmpty else { return sql }
        return "\(sql)  -- \(bindings.map(Self.describe).joined(separator: ", "))"
    }

    public var debugDescription: String {
        "\(Dialect.dialectName): \(description)"
    }

    private static func describe(_ value: SQLValue) -> String {
        switch value {
        case .null: "NULL"
        case .bool(let flag): flag ? "true" : "false"
        case .int(let number): String(number)
        case .double(let number): String(number)
        case .text(let string): "\"\(string)\""
        case .blob(let bytes): "\(bytes.count) bytes"
        }
    }
}

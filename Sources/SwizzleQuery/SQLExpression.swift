import SwizzleCore

/// A SQL expression carrying a *phantom* Swift type.
///
/// `Value` never appears in stored state — it exists purely so the type checker
/// can verify comparisons and project result tuples. All structure lives in `node`.
public struct SQLExpression<Value>: @unchecked Sendable {
    public var node: SQLNode
    public init(_ node: SQLNode) { self.node = node }

    /// Reinterpret the phantom type. Used by aggregates and casts.
    @inlinable
    public func retyped<T>(_ type: T.Type = T.self) -> SQLExpression<T> {
        SQLExpression<T>(node)
    }
}

extension SQLExpression {
    public var asc: SQLOrderTerm { SQLOrderTerm(node: node, descending: false) }
    public var desc: SQLOrderTerm { SQLOrderTerm(node: node, descending: true) }
    public func asc(nulls: SQLOrderTerm.Nulls) -> SQLOrderTerm {
        SQLOrderTerm(node: node, descending: false, nulls: nulls)
    }
    public func desc(nulls: SQLOrderTerm.Nulls) -> SQLOrderTerm {
        SQLOrderTerm(node: node, descending: true, nulls: nulls)
    }
    public func alias(_ name: String) -> SQLExpression<Value> {
        SQLExpression(.aliased(node, name))
    }
}

extension SQLExpression {
    /// The bare column name, when this expression is a column.
    ///
    /// `EXCLUDED.x` and `VALUES(x)` both need the name without its qualifier, and
    /// so does the left side of a `SET`.
    var columnName: String? {
        if case .column(_, let name) = node { return name }
        return nil
    }
}

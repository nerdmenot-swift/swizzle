import SwizzleCore

// MARK: - Comparison
//
// Every overload here is deliberately shaped so the LHS *determines* the RHS type.
// `u.age > 18` binds V := Int64 from the LHS, so the integer literal resolves in
// one step instead of the solver enumerating every ExpressibleByIntegerLiteral type.
// That single rule is the difference between a fast chain and an exponential one.

@inlinable
public func == <V: SQLColumnValue & Equatable>(lhs: SQLExpression<V>, rhs: V) -> SQLExpression<Bool> {
    SQLExpression(.binary(lhs.node, "=", .bind(rhs.sqlValue)))
}

@inlinable
public func == <V>(lhs: SQLExpression<V>, rhs: SQLExpression<V>) -> SQLExpression<Bool> {
    SQLExpression(.binary(lhs.node, "=", rhs.node))
}

@inlinable
public func != <V: SQLColumnValue & Equatable>(lhs: SQLExpression<V>, rhs: V) -> SQLExpression<Bool> {
    SQLExpression(.binary(lhs.node, "<>", .bind(rhs.sqlValue)))
}

@inlinable
public func != <V>(lhs: SQLExpression<V>, rhs: SQLExpression<V>) -> SQLExpression<Bool> {
    SQLExpression(.binary(lhs.node, "<>", rhs.node))
}

@inlinable
public func < <V: SQLColumnValue & Comparable>(lhs: SQLExpression<V>, rhs: V) -> SQLExpression<Bool> {
    SQLExpression(.binary(lhs.node, "<", .bind(rhs.sqlValue)))
}

@inlinable
public func <= <V: SQLColumnValue & Comparable>(lhs: SQLExpression<V>, rhs: V) -> SQLExpression<Bool> {
    SQLExpression(.binary(lhs.node, "<=", .bind(rhs.sqlValue)))
}

@inlinable
public func > <V: SQLColumnValue & Comparable>(lhs: SQLExpression<V>, rhs: V) -> SQLExpression<Bool> {
    SQLExpression(.binary(lhs.node, ">", .bind(rhs.sqlValue)))
}

@inlinable
public func >= <V: SQLColumnValue & Comparable>(lhs: SQLExpression<V>, rhs: V) -> SQLExpression<Bool> {
    SQLExpression(.binary(lhs.node, ">=", .bind(rhs.sqlValue)))
}

@inlinable
public func > <V: Comparable>(lhs: SQLExpression<V>, rhs: SQLExpression<V>) -> SQLExpression<Bool> {
    SQLExpression(.binary(lhs.node, ">", rhs.node))
}

@inlinable
public func < <V: Comparable>(lhs: SQLExpression<V>, rhs: SQLExpression<V>) -> SQLExpression<Bool> {
    SQLExpression(.binary(lhs.node, "<", rhs.node))
}

// MARK: - Optional lifting
//
// Nullable columns and NULL-returning aggregates (AVG, MAX, SUM) are ubiquitous,
// so `avg(posts.score) > 3.5` has to work without the caller writing `3.5 as Double?`.
// These lift a non-optional literal against an optional expression.
//
// Note the SQL semantics differ from Swift's: under three-valued logic a NULL LHS
// yields NULL, not false. Use `.isNull` explicitly when you mean "missing".

@inlinable
public func == <V: SQLColumnValue & Equatable>(lhs: SQLExpression<V?>, rhs: V) -> SQLExpression<Bool> {
    SQLExpression(.binary(lhs.node, "=", .bind(rhs.sqlValue)))
}

@inlinable
public func != <V: SQLColumnValue & Equatable>(lhs: SQLExpression<V?>, rhs: V) -> SQLExpression<Bool> {
    SQLExpression(.binary(lhs.node, "<>", .bind(rhs.sqlValue)))
}

@inlinable
public func < <V: SQLColumnValue & Comparable>(lhs: SQLExpression<V?>, rhs: V) -> SQLExpression<Bool> {
    SQLExpression(.binary(lhs.node, "<", .bind(rhs.sqlValue)))
}

@inlinable
public func <= <V: SQLColumnValue & Comparable>(lhs: SQLExpression<V?>, rhs: V) -> SQLExpression<Bool> {
    SQLExpression(.binary(lhs.node, "<=", .bind(rhs.sqlValue)))
}

@inlinable
public func > <V: SQLColumnValue & Comparable>(lhs: SQLExpression<V?>, rhs: V) -> SQLExpression<Bool> {
    SQLExpression(.binary(lhs.node, ">", .bind(rhs.sqlValue)))
}

@inlinable
public func >= <V: SQLColumnValue & Comparable>(lhs: SQLExpression<V?>, rhs: V) -> SQLExpression<Bool> {
    SQLExpression(.binary(lhs.node, ">=", .bind(rhs.sqlValue)))
}

// MARK: - Boolean combinators
//
// VARIANT A: operators. Concrete operand types (no generics at all), so stdlib's
// `&&`/`||` — which take Bool and an @autoclosure — prune immediately.
// The spike A/B-tests these against the function forms below.

@inlinable
public func && (lhs: SQLExpression<Bool>, rhs: SQLExpression<Bool>) -> SQLExpression<Bool> {
    SQLExpression(.group(.binary(lhs.node, "AND", rhs.node)))
}

@inlinable
public func || (lhs: SQLExpression<Bool>, rhs: SQLExpression<Bool>) -> SQLExpression<Bool> {
    SQLExpression(.group(.binary(lhs.node, "OR", rhs.node)))
}

@inlinable
public prefix func ! (operand: SQLExpression<Bool>) -> SQLExpression<Bool> {
    SQLExpression(.prefix("NOT", .group(operand.node)))
}

// VARIANT B: Drizzle-style free functions. Zero overload ambiguity by construction.

public func and(_ terms: SQLExpression<Bool>...) -> SQLExpression<Bool> {
    combine(terms, "AND")
}

public func or(_ terms: SQLExpression<Bool>...) -> SQLExpression<Bool> {
    combine(terms, "OR")
}

private func combine(_ terms: [SQLExpression<Bool>], _ op: String) -> SQLExpression<Bool> {
    guard var acc = terms.first?.node else { return SQLExpression(.raw("TRUE")) }
    for term in terms.dropFirst() {
        acc = .binary(acc, op, term.node)
    }
    return SQLExpression(.group(acc))
}

// MARK: - Predicates

extension SQLExpression {
    public func like(_ pattern: String) -> SQLExpression<Bool> {
        SQLExpression<Bool>(.binary(node, "LIKE", .bind(.text(pattern))))
    }

    public var isNull: SQLExpression<Bool> {
        SQLExpression<Bool>(.postfix(node, "IS NULL"))
    }

    public var isNotNull: SQLExpression<Bool> {
        SQLExpression<Bool>(.postfix(node, "IS NOT NULL"))
    }
}

extension SQLExpression where Value: SQLColumnValue {
    public func `in`(_ values: [Value]) -> SQLExpression<Bool> {
        SQLExpression<Bool>(.binary(node, "IN", .list(values.map { .bind($0.sqlValue) })))
    }

    public func between(_ lower: Value, _ upper: Value) -> SQLExpression<Bool> {
        SQLExpression<Bool>(
            .binary(node, "BETWEEN", .binary(.bind(lower.sqlValue), "AND", .bind(upper.sqlValue)))
        )
    }
}

// MARK: - Aggregates

public func count<V>(_ expression: SQLExpression<V>) -> SQLExpression<Int64> {
    SQLExpression(.function("COUNT", [expression.node]))
}

public func countStar() -> SQLExpression<Int64> {
    SQLExpression(.function("COUNT", [.star(qualifier: nil)]))
}

public func countDistinct<V>(_ expression: SQLExpression<V>) -> SQLExpression<Int64> {
    SQLExpression(.function("COUNT", [.prefix("DISTINCT", expression.node)]))
}

public func sum<V>(_ expression: SQLExpression<V>) -> SQLExpression<Double?> {
    SQLExpression(.function("SUM", [expression.node]))
}

public func avg<V>(_ expression: SQLExpression<V>) -> SQLExpression<Double?> {
    SQLExpression(.function("AVG", [expression.node]))
}

public func max<V>(_ expression: SQLExpression<V>) -> SQLExpression<V?> {
    SQLExpression(.function("MAX", [expression.node]))
}

public func min<V>(_ expression: SQLExpression<V>) -> SQLExpression<V?> {
    SQLExpression(.function("MIN", [expression.node]))
}

public func coalesce<V>(_ lhs: SQLExpression<V?>, _ rhs: SQLExpression<V>) -> SQLExpression<V> {
    SQLExpression(.function("COALESCE", [lhs.node, rhs.node]))
}

// MARK: - Arithmetic
//
// Present so that `views = views + 1` and `balance - amount` are ordinary rather
// than a reason to drop to a raw fragment. Each is two overloads — expression
// against literal, and expression against expression — which is the smallest set
// that covers real assignments without widening the constraint system.
//
// No `.group` wrapper: SQL's arithmetic precedence matches the reader's
// expectation, and parenthesising every term makes rendered SQL hard to read for
// no correctness gain. Parenthesise explicitly with a fragment when mixing with
// `||` or comparison inside one expression.

@inlinable
public func + <V: SQLColumnValue>(lhs: SQLExpression<V>, rhs: V) -> SQLExpression<V> {
    SQLExpression(.binary(lhs.node, "+", .bind(rhs.sqlValue)))
}

@inlinable
public func + <V>(lhs: SQLExpression<V>, rhs: SQLExpression<V>) -> SQLExpression<V> {
    SQLExpression(.binary(lhs.node, "+", rhs.node))
}

@inlinable
public func - <V: SQLColumnValue>(lhs: SQLExpression<V>, rhs: V) -> SQLExpression<V> {
    SQLExpression(.binary(lhs.node, "-", .bind(rhs.sqlValue)))
}

@inlinable
public func - <V>(lhs: SQLExpression<V>, rhs: SQLExpression<V>) -> SQLExpression<V> {
    SQLExpression(.binary(lhs.node, "-", rhs.node))
}

@inlinable
public func * <V: SQLColumnValue>(lhs: SQLExpression<V>, rhs: V) -> SQLExpression<V> {
    SQLExpression(.binary(lhs.node, "*", .bind(rhs.sqlValue)))
}

@inlinable
public func * <V>(lhs: SQLExpression<V>, rhs: SQLExpression<V>) -> SQLExpression<V> {
    SQLExpression(.binary(lhs.node, "*", rhs.node))
}

@inlinable
public func / <V: SQLColumnValue>(lhs: SQLExpression<V>, rhs: V) -> SQLExpression<V> {
    SQLExpression(.binary(lhs.node, "/", .bind(rhs.sqlValue)))
}

@inlinable
public func / <V>(lhs: SQLExpression<V>, rhs: SQLExpression<V>) -> SQLExpression<V> {
    SQLExpression(.binary(lhs.node, "/", rhs.node))
}

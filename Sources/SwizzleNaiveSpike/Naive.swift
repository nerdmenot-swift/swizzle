import SwizzleCore

// DELIBERATELY NAIVE DESIGN — measurement artifact, not library code.
//
// This is what you'd write without thinking about the constraint solver, and it's
// roughly how a direct Drizzle transliteration into Swift comes out. Four traits
// distinguish it from SwizzleQuery:
//
//   1. Expression *types* grow with tree depth: NBin<NBin<NCol<Int64>, NLit<Int64>>, ...>
//   2. Operators are generic on BOTH operands, so literals stay unresolved longer
//   3. The select type grows with every join
//   4. Projection uses arity overloads instead of a parameter pack
//
// It lives in its own module so its operator overloads cannot contaminate the
// SwizzleQuery measurement.

protocol NExpr {
    associatedtype Value
    var node: SQLNode { get }
}

struct NCol<Value>: NExpr {
    var node: SQLNode
}

struct NLit<Value>: NExpr {
    var node: SQLNode
}

struct NBin<L: NExpr, R: NExpr, Value>: NExpr {
    var lhs: L
    var rhs: R
    var op: String
    var node: SQLNode { .binary(lhs.node, op, rhs.node) }
}

struct NFn<Arg: NExpr, Value>: NExpr {
    var name: String
    var arg: Arg
    var node: SQLNode { .function(name, [arg.node]) }
}

struct NPost<Operand: NExpr, Value>: NExpr {
    var operand: Operand
    var op: String
    var node: SQLNode { .postfix(operand.node, op) }
}

struct NIn<L: NExpr, Value>: NExpr {
    var lhs: L
    var values: [SQLValue]
    var node: SQLNode { .binary(lhs.node, "IN", .list(values.map { .bind($0) })) }
}

// Generic on both operands — the expensive shape.
func == <L: NExpr, R: NExpr>(lhs: L, rhs: R) -> NBin<L, R, Bool> where L.Value == R.Value {
    NBin(lhs: lhs, rhs: rhs, op: "=")
}

func == <L: NExpr>(lhs: L, rhs: L.Value) -> NBin<L, NLit<L.Value>, Bool> where L.Value: SQLColumnValue {
    NBin(lhs: lhs, rhs: NLit(node: .bind(rhs.sqlValue)), op: "=")
}

func != <L: NExpr, R: NExpr>(lhs: L, rhs: R) -> NBin<L, R, Bool> where L.Value == R.Value {
    NBin(lhs: lhs, rhs: rhs, op: "<>")
}

func > <L: NExpr>(lhs: L, rhs: L.Value) -> NBin<L, NLit<L.Value>, Bool>
where L.Value: SQLColumnValue & Comparable {
    NBin(lhs: lhs, rhs: NLit(node: .bind(rhs.sqlValue)), op: ">")
}

func < <L: NExpr>(lhs: L, rhs: L.Value) -> NBin<L, NLit<L.Value>, Bool>
where L.Value: SQLColumnValue & Comparable {
    NBin(lhs: lhs, rhs: NLit(node: .bind(rhs.sqlValue)), op: "<")
}

func >= <L: NExpr>(lhs: L, rhs: L.Value) -> NBin<L, NLit<L.Value>, Bool>
where L.Value: SQLColumnValue & Comparable {
    NBin(lhs: lhs, rhs: NLit(node: .bind(rhs.sqlValue)), op: ">=")
}

func <= <L: NExpr>(lhs: L, rhs: L.Value) -> NBin<L, NLit<L.Value>, Bool>
where L.Value: SQLColumnValue & Comparable {
    NBin(lhs: lhs, rhs: NLit(node: .bind(rhs.sqlValue)), op: "<=")
}

func && <L: NExpr, R: NExpr>(lhs: L, rhs: R) -> NBin<L, R, Bool>
where L.Value == Bool, R.Value == Bool {
    NBin(lhs: lhs, rhs: rhs, op: "AND")
}

func || <L: NExpr, R: NExpr>(lhs: L, rhs: R) -> NBin<L, R, Bool>
where L.Value == Bool, R.Value == Bool {
    NBin(lhs: lhs, rhs: rhs, op: "OR")
}

extension NExpr {
    var nIsNull: NPost<Self, Bool> { NPost(operand: self, op: "IS NULL") }
    func nIn(_ values: [Value]) -> NIn<Self, Bool> where Value: SQLColumnValue {
        NIn(lhs: self, values: values.map(\.sqlValue))
    }
}

func nCountDistinct<A: NExpr>(_ arg: A) -> NFn<A, Int64> { NFn(name: "COUNT_DISTINCT", arg: arg) }
func nAvg<A: NExpr>(_ arg: A) -> NFn<A, Double> { NFn(name: "AVG", arg: arg) }
func nMax<A: NExpr>(_ arg: A) -> NFn<A, Int64> { NFn(name: "MAX", arg: arg) }

// Staged select: the type grows with every join.
struct NJoined<Prev, T> {}

struct NSelect<D: SQLDialect, Cols, Sources> {
    var core: SQLSelectCore

    func from<T: SQLTable>(_ table: T) -> NSelect<D, Cols, T> {
        var copy = core
        copy.from = table.source
        return NSelect<D, Cols, T>(core: copy)
    }

    func innerJoin<T: SQLTable, P: NExpr>(
        _ table: T, on predicate: P
    ) -> NSelect<D, Cols, NJoined<Sources, T>> where P.Value == Bool {
        var copy = core
        copy.joins.append(SQLJoin(kind: .inner, source: table.source, on: predicate.node))
        return NSelect<D, Cols, NJoined<Sources, T>>(core: copy)
    }

    func leftJoin<T: SQLTable, P: NExpr>(
        _ table: T, on predicate: P
    ) -> NSelect<D, Cols, NJoined<Sources, T>> where P.Value == Bool {
        var copy = core
        copy.joins.append(SQLJoin(kind: .left, source: table.source, on: predicate.node))
        return NSelect<D, Cols, NJoined<Sources, T>>(core: copy)
    }

    func `where`<P: NExpr>(_ predicate: P) -> NSelect<D, Cols, Sources> where P.Value == Bool {
        var copy = core
        copy.predicates.append(predicate.node)
        return NSelect<D, Cols, Sources>(core: copy)
    }

    func groupBy<A: NExpr, B: NExpr>(_ a: A, _ b: B) -> NSelect<D, Cols, Sources> {
        var copy = core
        copy.groupBy.append(a.node)
        copy.groupBy.append(b.node)
        return NSelect<D, Cols, Sources>(core: copy)
    }

    func having<P: NExpr>(_ predicate: P) -> NSelect<D, Cols, Sources> where P.Value == Bool {
        var copy = core
        copy.having.append(predicate.node)
        return NSelect<D, Cols, Sources>(core: copy)
    }

    func orderBy(_ terms: SQLOrderTerm...) -> NSelect<D, Cols, Sources> {
        var copy = core
        copy.orderBy.append(contentsOf: terms)
        return NSelect<D, Cols, Sources>(core: copy)
    }

    func limit(_ count: Int) -> NSelect<D, Cols, Sources> {
        var copy = core
        copy.limit = count
        return NSelect<D, Cols, Sources>(core: copy)
    }

    func offset(_ count: Int) -> NSelect<D, Cols, Sources> {
        var copy = core
        copy.offset = count
        return NSelect<D, Cols, Sources>(core: copy)
    }

    func build() -> (sql: String, bindings: [SQLValue]) {
        var renderer = SQLRenderer<D>()
        renderer.renderSelect(core)
        return (renderer.sql, renderer.bindings)
    }
}

extension NExpr {
    var nAsc: SQLOrderTerm { SQLOrderTerm(node: node, descending: false) }
    var nDesc: SQLOrderTerm { SQLOrderTerm(node: node, descending: true) }
}

// Arity overloads instead of a parameter pack.
func nSelect<D: SQLDialect, A: NExpr, B: NExpr>(
    _ dialect: D.Type, _ a: A, _ b: B
) -> NSelect<D, (A, B), ()> {
    var core = SQLSelectCore()
    core.projection = [a.node, b.node]
    return NSelect(core: core)
}

func nSelect<D: SQLDialect, A: NExpr, B: NExpr, C: NExpr>(
    _ dialect: D.Type, _ a: A, _ b: B, _ c: C
) -> NSelect<D, (A, B, C), ()> {
    var core = SQLSelectCore()
    core.projection = [a.node, b.node, c.node]
    return NSelect(core: core)
}

func nSelect<D: SQLDialect, A: NExpr, B: NExpr, C: NExpr, E: NExpr>(
    _ dialect: D.Type, _ a: A, _ b: B, _ c: C, _ e: E
) -> NSelect<D, (A, B, C, E), ()> {
    var core = SQLSelectCore()
    core.projection = [a.node, b.node, c.node, e.node]
    return NSelect(core: core)
}

func nSelect<D: SQLDialect, A: NExpr, B: NExpr, C: NExpr, E: NExpr, F: NExpr>(
    _ dialect: D.Type, _ a: A, _ b: B, _ c: C, _ e: E, _ f: F
) -> NSelect<D, (A, B, C, E, F), ()> {
    var core = SQLSelectCore()
    core.projection = [a.node, b.node, c.node, e.node, f.node]
    return NSelect(core: core)
}

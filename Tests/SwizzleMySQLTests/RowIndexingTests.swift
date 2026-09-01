import NIOCore
import Testing
@testable import SwizzleMySQL

/// Indexing a row out of range, in both directions.
///
/// ## The bug this suite was written for
///
/// `MySQLRow`'s positional accessors guarded only the **upper** bound —
/// `index < values.count` — and then subscripted the array. A negative index
/// passes that guard and traps, taking the process down. `row[-1]` was a crash
/// on a `public` API, as were `string(at:)` and `int(at:)`, which route through
/// the same subscript, and `decode(_:at:)`, which had its own copy of the
/// half-guard.
///
/// This is the same defect the Postgres pass found in `row[-1]` and
/// `array(at:)`, repeated here. Both times a mutation survivor pointed at the
/// guard, and both times the reason nothing caught it is the same: every test
/// indexed a row with a loop counter or a literal, so no test ever supplied a
/// value the guard's missing half would have rejected.
///
/// A negative index is not hypothetical in caller code — it is what
/// `firstIndex(of:) ?? -1`, a decremented cursor, or an `Int` arriving from
/// arithmetic produces. The contract for out of range here is "returns `.null`
/// or throws", so both ends must honour it.
///
/// ## The other half: values and columns can disagree
///
/// A row's schema is a separate object from its values, and `MySQLRow(values:
/// columns:)` is public, so the two counts are not guaranteed equal. The
/// accessors bound-check them separately for that reason, and those second
/// checks are only reachable when the counts differ — which no test did either.
@Suite("MySQL row indexing")
struct RowIndexingTests {

    static func column(_ name: String) -> MySQLColumnDefinition {
        MySQLColumnDefinition(
            catalog: "def", schema: "", table: "", originalTable: "",
            name: name, originalName: name, characterSet: 33, columnLength: 64,
            type: MySQLColumnType.varString.rawValue,
            flags: MySQLColumnFlags(rawValue: 0), decimals: 0
        )
    }

    static func row(values: [MySQLValue], names: [String]) -> MySQLRow {
        MySQLRow(values: values, columns: names.map(Self.column))
    }

    static let sample = Self.row(
        values: [.int(1), .bytes(Array("two".utf8)), .null],
        names: ["a", "b", "c"]
    )

    // MARK: - Out of range, both ends

    /// The crash, pinned. Every index far outside the row in both directions,
    /// through every positional accessor.
    @Test("indexing outside the row returns null rather than trapping")
    func outOfRangeIsNull() {
        for index in [-1_000_000, -256, -2, -1, 3, 4, 1_000_000, Int.max] {
            #expect(Self.sample[index] == .null, "row[\(index)]")
            #expect(Self.sample.string(at: index) == nil, "string(at: \(index))")
            #expect(Self.sample.int(at: index) == nil, "int(at: \(index))")
        }
        // Int.min separately: negating it would overflow, so an implementation
        // that normalised a negative index by absolute value would trap here
        // even after adding a lower bound.
        #expect(Self.sample[Int.min] == .null)
        #expect(Self.sample.string(at: Int.min) == nil)
        #expect(Self.sample.int(at: Int.min) == nil)
    }

    /// `decode(_:at:)` has its own guard rather than going through the
    /// subscript, so it needs its own statement of the same property. It throws
    /// where the subscript returns `.null`, which is the documented difference.
    @Test("decoding outside the row throws rather than trapping")
    func decodingOutOfRangeThrows() {
        for index in [Int.min, -1_000_000, -1, 3, 1_000_000, Int.max] {
            #expect(throws: MySQLDecodingError.self, "decode(at: \(index))") {
                try Self.sample.decode(Int64.self, at: index)
            }
        }
    }

    /// In range still works, so the fix did not simply reject everything —
    /// which a guard written as `index > 0` would.
    @Test("every valid index still resolves")
    func inRangeStillWorks() throws {
        #expect(Self.sample[0] == .int(1))
        #expect(Self.sample[1] == .bytes(Array("two".utf8)))
        #expect(Self.sample[2] == .null, "a NULL column, distinct from out of range")
        #expect(Self.sample.int(at: 0) == 1)
        #expect(Self.sample.string(at: 1) == "two")
        #expect(try Self.sample.decode(Int64.self, at: 0) == 1)
    }

    /// Index zero on an empty row, which is the boundary where the upper guard
    /// is the only thing standing between the caller and a trap.
    @Test("index zero on an empty row is out of range")
    func emptyRow() {
        let empty = Self.row(values: [], names: [])
        #expect(empty[0] == .null)
        #expect(empty[-1] == .null)
        #expect(empty.string(at: 0) == nil)
        #expect(throws: MySQLDecodingError.self) { try empty.decode(Int64.self, at: 0) }
    }

    // MARK: - When the schema and the values disagree

    /// `MySQLRow(values:columns:)` is public and does not require the counts to
    /// match, so the name lookup inside `decode(_:at:)` bounds-checks the schema
    /// separately from the values. That check is unreachable while the counts
    /// are equal, which is why it went untested.
    @Test("a row with more values than columns decodes without a name")
    func moreValuesThanColumns() throws {
        let lopsided = Self.row(values: [.int(1), .int(2), .int(3)], names: ["only"])
        #expect(try lopsided.decode(Int64.self, at: 0) == 1)
        // Index 1 and 2 exist as values but have no column definition. The name
        // is absent; the value still decodes.
        #expect(try lopsided.decode(Int64.self, at: 1) == 2)
        #expect(try lopsided.decode(Int64.self, at: 2) == 3)
        #expect(lopsided[2] == .int(3))
    }

    /// And the reverse, where a column is described but has no value behind it.
    @Test("a row with more columns than values reports out of range")
    func moreColumnsThanValues() {
        let lopsided = Self.row(values: [.int(1)], names: ["a", "b", "c"])
        #expect(lopsided[1] == .null, "described but absent reads as null")
        #expect(throws: MySQLDecodingError.self) { try lopsided.decode(Int64.self, at: 1) }
        #expect(lopsided["b"] == nil, "and by name, because there is no value to return")
    }

    /// The name-keyed subscript has the same split: the schema can name a column
    /// whose value is missing, and it must not index past the values.
    @Test("a named column with no value behind it returns nil rather than trapping")
    func namedColumnBeyondTheValues() {
        let lopsided = Self.row(values: [], names: ["a"])
        #expect(lopsided["a"] == nil)
        #expect(lopsided["nonexistent"] == nil)
    }

    // MARK: - Null versus absent

    /// The distinction the API is built around, stated once: a column that is
    /// `NULL` and a column that is not there are different things, and only the
    /// name-keyed subscript can tell them apart.
    @Test("a NULL column is distinguishable from a missing one by name")
    func nullIsNotAbsent() {
        #expect(Self.sample["c"] == .null, "present and NULL")
        #expect(Self.sample["z"] == nil, "not present at all")
        #expect(Self.sample[2] == .null, "positionally the two are indistinguishable")
        #expect(Self.sample[9] == .null, "which is why the name-keyed form exists")
    }

    // MARK: - The variadic form, which guards separately

    /// `decode(_:_:…)` walks the row with its own cursor and its own pair of
    /// bounds checks rather than going through `decode(_:at:)`, so the same two
    /// properties have to be stated again against it. Its cursor starts at zero
    /// and only increments, so it cannot go negative — but it can walk past
    /// either the values or the columns, and those are different lengths.
    @Test("the variadic form decodes a row whose columns run out before its values")
    func variadicWithFewerColumnsThanValues() throws {
        let lopsided = Self.row(values: [.int(1), .int(2), .int(3)], names: ["only"])
        let (a, b, c) = try lopsided.decode(Int64.self, Int64.self, Int64.self)
        #expect((a, b, c) == (1, 2, 3),
                "the values decode; only their names are missing")
    }

    /// Asking for more columns than the row holds throws on the one that runs
    /// off the end, rather than trapping or returning a default.
    @Test("the variadic form throws when it walks past the last value")
    func variadicPastTheEnd() {
        #expect(throws: MySQLDecodingError.self) {
            _ = try Self.sample.decode(Int64.self, String.self, String?.self, Int64.self)
        }
        let empty = Self.row(values: [], names: [])
        #expect(throws: MySQLDecodingError.self) {
            _ = try empty.decode(Int64.self)
        }
    }

    /// Asking for exactly as many as there are is the boundary next to it.
    @Test("the variadic form decodes exactly as many columns as the row holds")
    func variadicExactFit() throws {
        let (a, b, c) = try Self.sample.decode(Int64.self, String.self, String?.self)
        #expect(a == 1)
        #expect(b == "two")
        #expect(c == nil)
    }

}

/// When two rows are the same row.
///
/// ## Why identity is deliberately not the answer
///
/// A row holds its values and a *reference* to a schema. Two executions of the
/// same query produce two schema objects describing the same columns, so
/// comparing schemas by identity would make every row unequal to a row from an
/// earlier run — which is exactly what a test asserting an expected result set
/// needs to do.
///
/// So equality is values **and** column names, with schema identity as a fast
/// path rather than as the rule. That is three conditions in one expression, and
/// nothing exercised the shape of it: the mutation sweep left all four operators
/// alive because every test compared rows that shared a schema object.
@Suite("MySQL row equality")
struct RowEqualityTests {

    static func column(_ name: String) -> MySQLColumnDefinition {
        RowIndexingTests.column(name)
    }

    static func row(_ values: [MySQLValue], _ names: [String]) -> MySQLRow {
        MySQLRow(values: values, columns: names.map(Self.column))
    }

    /// **The property the fast path exists to avoid breaking.** Two rows built
    /// from separate schema objects describing the same columns are equal.
    @Test("rows from separate executions of the same query are equal")
    func separateSchemasCompareEqual() {
        let first = Self.row([.int(1), .bytes(Array("a".utf8))], ["id", "name"])
        let second = Self.row([.int(1), .bytes(Array("a".utf8))], ["id", "name"])
        #expect(first.schema !== second.schema, "the premise: two distinct schema objects")
        #expect(first == second)
    }

    /// Sharing a schema object is the fast path, and must give the same answer.
    @Test("rows sharing a schema compare on their values")
    func sharedSchema() {
        let schema = MySQLRowSchema(["id", "name"].map(Self.column))
        let first = MySQLRow(values: [.int(1), .null], schema: schema)
        let second = MySQLRow(values: [.int(1), .null], schema: schema)
        let third = MySQLRow(values: [.int(2), .null], schema: schema)
        #expect(first == second)
        #expect(first != third, "same schema, different values")
    }

    /// Different values are never equal, whatever the schemas.
    @Test("different values are not equal")
    func differentValues() {
        #expect(Self.row([.int(1)], ["id"]) != Self.row([.int(2)], ["id"]))
        #expect(Self.row([.int(1)], ["id"]) != Self.row([.null], ["id"]))
        #expect(Self.row([.int(1)], ["id"]) != Self.row([.int(1), .int(2)], ["id", "b"]))
        #expect(Self.row([], []) == Self.row([], []), "two empty rows are the same row")
    }

    /// Same values under **different column names** is not the same row — the
    /// half that would be lost if equality were values alone.
    @Test("the same values under different names are not equal")
    func differentColumnNames() {
        let first = Self.row([.int(1), .int(2)], ["a", "b"])
        let second = Self.row([.int(1), .int(2)], ["b", "a"])
        #expect(first != second, "the order of the names is part of the row's identity")

        let third = Self.row([.int(1), .int(2)], ["a", "c"])
        #expect(first != third)
    }

    /// A NULL is a value like any other, and equal to another NULL.
    @Test("NULL compares equal to NULL")
    func nulls() {
        #expect(Self.row([.null], ["a"]) == Self.row([.null], ["a"]))
        #expect(Self.row([.null], ["a"]) != Self.row([.int(0)], ["a"]))
    }

    /// Equality is reflexive, symmetric and consistent — worth one statement
    /// because the expression has three operands and a short circuit.
    @Test("equality is symmetric across the fast path and the slow one")
    func symmetry() {
        let shared = MySQLRowSchema(["a"].map(Self.column))
        let onShared = MySQLRow(values: [.int(1)], schema: shared)
        let onOwn = Self.row([.int(1)], ["a"])

        #expect(onShared == onOwn)
        #expect(onOwn == onShared, "and the other way round")
        #expect(onShared == onShared)
    }
}

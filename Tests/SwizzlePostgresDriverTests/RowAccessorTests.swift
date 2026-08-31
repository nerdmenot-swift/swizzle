import SwizzleCore
import Testing
@testable import SwizzlePostgresDriver

/// `PostgresRow`'s accessors — the public surface a caller actually touches.
///
/// The mutation sweep found five survivors here, and following two of them
/// turned up crashes rather than coverage gaps:
///
///   - `row[-1]` trapped. The subscript guarded `index < values.count`, which is
///     true for every negative number, so it reached `values[-1]`. That is a
///     public subscript on a public type, reachable by any caller computing an
///     index — a loop counter, or a `firstIndex(of:)` that returned nothing and
///     was defaulted to -1.
///   - `array(at:)` guarded `schema.count` and then indexed `values`. Those are
///     not the same length when a row is narrower than the description it
///     arrived with, which the query state machine genuinely produces.
///
/// Both are now bounded at both ends. The rest of this pins the answers, because
/// "out of range reads as null" and "out of range crashes" are both defensible
/// designs and only one of them is the one this type promises.
@Suite("Postgres row accessors")
struct RowAccessorTests {

    static func column(_ name: String, oid: UInt32 = 25) -> PostgresColumnDescription {
        PostgresColumnDescription(
            name: name, tableOID: 0, columnAttributeNumber: 0,
            dataTypeOID: oid, dataTypeSize: -1, dataTypeModifier: -1, format: 0
        )
    }

    static func row(
        _ values: [SQLValue], _ names: [String], oid: UInt32 = 25
    ) -> PostgresRow {
        PostgresRow(values: values, columns: names.map { column($0, oid: oid) })
    }

    // MARK: - By position

    @Test("a value is read by its position")
    func byIndex() {
        let row = Self.row([.int(1), .text("x")], ["id", "name"])
        #expect(row[0] == .int(1))
        #expect(row[1] == .text("x"))
    }

    /// Both ends. Past the end was already the documented answer; below the
    /// start used to be a crash.
    @Test("an index outside the row reads as null at either end")
    func indexOutsideTheRow() {
        let row = Self.row([.int(1)], ["id"])
        #expect(row[1] == .null, "one past the end")
        #expect(row[99] == .null, "far past the end")
        #expect(row[-1] == .null, "one before the start")
        #expect(row[Int.min] == .null, "and the extreme, which is where an overflow would show")
    }

    /// An empty row has no positions at all, so every index is outside it.
    @Test("every index of an empty row reads as null")
    func emptyRow() {
        let row = Self.row([], [])
        #expect(row[0] == .null)
        #expect(row[-1] == .null)
    }

    // MARK: - By name

    /// Nil means *there is no such column*, which is a different answer from a
    /// column that exists and holds NULL — and the distinction is the reason
    /// this returns an optional at all.
    @Test("an unknown column name is nil, and a null column is not")
    func byName() {
        let row = Self.row([.int(1), .null], ["id", "note"])
        #expect(row["id"] == .int(1))
        #expect(row["note"] == .some(.null), "the column exists and holds NULL")
        #expect(row["nope"] == nil, "the column does not exist")
    }

    /// A name that the schema knows but the row has no value for — the narrow-row
    /// shape again, reached by name this time.
    @Test("a named column with no value delivered is nil")
    func namedColumnBeyondTheValues() {
        let row = Self.row([.int(1)], ["id", "missing"])
        #expect(row["id"] == .int(1))
        #expect(row["missing"] == nil)
    }

    // MARK: - Arrays

    @Test("an array column decodes its elements")
    func arrayColumn() {
        let row = Self.row([.text("{a,b}")], ["tags"], oid: 1009)
        let array = row.array(at: 0)
        #expect(array?.elements.count == 2)
    }

    /// A column that is not an array type has no elements to give, whatever it
    /// holds.
    @Test("a non-array column has no array")
    func nonArrayColumn() {
        let row = Self.row([.text("{a,b}")], ["tags"], oid: 25)
        #expect(row.array(at: 0) == nil)
    }

    /// The crash: three array columns described, one value delivered.
    @Test("an array index beyond the delivered values is nil, not a trap")
    func arrayBeyondTheValues() {
        let row = Self.row([.text("{a}")], ["a", "b", "c"], oid: 1009)
        #expect(row.array(at: 0) != nil)
        #expect(row.array(at: 2) == nil, "described but not delivered")
        #expect(row.array(at: 9) == nil, "not described either")
        #expect(row.array(at: -1) == nil, "and below the start")
    }

    // MARK: - Equality

    /// Schema *identity* is deliberately not part of equality, so rows from two
    /// executions of the same query compare equal — which is what makes a test
    /// able to assert on a result at all.
    @Test("equal values under equal column names are equal rows")
    func equality() {
        let first = Self.row([.int(1)], ["id"])
        let second = Self.row([.int(1)], ["id"])
        #expect(first == second, "different schema objects, same columns")

        #expect(first != Self.row([.int(2)], ["id"]), "different values")
        #expect(first != Self.row([.int(1)], ["other"]), "different column names")
        #expect(first != Self.row([.int(1), .int(2)], ["id", "extra"]), "different arity")
    }

    /// The identity fast path has to agree with the slow one: two rows sharing a
    /// schema object compare on values alone, and must reach the same answer as
    /// two rows that merely have matching columns.
    @Test("a shared schema takes the fast path to the same answer")
    func sharedSchemaEquality() {
        let schema = PostgresRowSchema([Self.column("id")])
        let first = PostgresRow(values: [.int(1)], schema: schema)
        let second = PostgresRow(values: [.int(1)], schema: schema)
        let third = PostgresRow(values: [.int(2)], schema: schema)

        #expect(first == second)
        #expect(first != third)
    }
}

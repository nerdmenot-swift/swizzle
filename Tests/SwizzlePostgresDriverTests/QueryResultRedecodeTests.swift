import SwizzleCore
import Testing
@testable import SwizzlePostgresDriver

/// The second decoding pass, and the bounds it indexes within.
///
/// ## Why these guards exist at all
///
/// A user-defined type cannot be decoded on the first pass: its OID means
/// nothing until the registry has asked the server about it, and that round trip
/// can only happen *after* `RowDescription` has arrived. So the raw bytes of the
/// unrecognised columns are kept, and `redecode` runs over them once the registry
/// knows what they are.
///
/// That leaves two arrays that have to agree — the retained bytes, keyed by
/// column index, and the rows they belong to — and four `index < count` guards
/// keeping them honest. The mutation sweep flipped every one of them and nothing
/// failed: `redecode` had no direct test.
///
/// Getting one wrong is an out-of-range crash rather than a wrong value, which
/// is the failure mode this driver has now met twice — once here and once in the
/// pipeline state machine, for the same reason: a state machine whose only
/// coverage was a real server doing the expected thing.
@Suite("Postgres query result redecoding")
struct QueryResultRedecodeTests {

    static func column(_ name: String, oid: UInt32) -> PostgresColumnDescription {
        PostgresColumnDescription(
            name: name, tableOID: 0, columnAttributeNumber: 0,
            dataTypeOID: oid, dataTypeSize: -1, dataTypeModifier: -1, format: 0
        )
    }

    /// An OID no built-in claims, standing in for a user-defined type.
    static let customOID: UInt32 = 99_999


    // MARK: - The happy path

    /// The pass runs and clears what it consumed. It cannot assert a *decoded*
    /// value here: types enter the registry only through `resolve`, which needs a
    /// server — so the decoding itself is covered by `PostgresUserTypeTests`
    /// against a real one, and what is checked here is the bookkeeping around it.
    @Test("the retained bytes are consumed and cleared")
    func redecodesWhatItKept() {
        var result = PostgresQueryResult()
        result.columns = [Self.column("custom", oid: Self.customOID)]
        result.rows = [[.blob(Array("hello".utf8))]]
        result.unresolvedBytes = [0: [Array("hello".utf8)]]

        result.redecode(with: PostgresTypeRegistry())

        #expect(result.unresolvedBytes.isEmpty, "the bytes are dropped once used")
        #expect(result.rows.count == 1)
    }

    // MARK: - When the two sides disagree

    /// Bytes retained for a column index the result no longer has. Skipped, not
    /// indexed — `columnIndex < columns.count`.
    @Test("bytes for a column that is not there are ignored")
    func retainedColumnBeyondTheDescription() {
        var result = PostgresQueryResult()
        result.columns = [Self.column("only", oid: Self.customOID)]
        result.rows = [[.blob([1])]]
        // Index 1 is exactly one past the end, which is the boundary the guard
        // turns on: a `<=` here would index `columns[1]` and crash. Index 3 would
        // not have caught it — it is out of range under either comparison.
        result.unresolvedBytes = [0: [[1]], 1: [[9]]]

        result.redecode(with: PostgresTypeRegistry())
        #expect(result.rows.count == 1, "it must survive rather than crash")
    }

    /// More rows than retained bytes — `rowIndex < columnBytes.count`. The rows
    /// with nothing kept for them keep whatever they decoded to first time.
    @Test("rows with no retained bytes are left as they were")
    func moreRowsThanRetainedBytes() {
        var result = PostgresQueryResult()
        result.columns = [Self.column("custom", oid: Self.customOID)]
        result.rows = [[.blob([1])], [.blob([2])], [.blob([3])]]
        // Only the first row's bytes were kept.
        result.unresolvedBytes = [0: [[1]]]

        result.redecode(with: PostgresTypeRegistry())
        #expect(result.rows.count == 3, "no row is lost and nothing is indexed off the end")
    }

    /// And the reverse — more retained bytes than rows, which is what a result
    /// truncated between the passes looks like.
    @Test("more retained bytes than rows is not an overrun")
    func moreRetainedBytesThanRows() {
        var result = PostgresQueryResult()
        result.columns = [Self.column("custom", oid: Self.customOID)]
        result.rows = [[.blob([1])]]
        result.unresolvedBytes = [0: [[1], [2], [3]]]

        result.redecode(with: PostgresTypeRegistry())
        #expect(result.rows.count == 1)
    }

    /// A result with no rows at all, which is the shape of a `SELECT` that
    /// matched nothing but still described its columns.
    @Test("an empty result redecodes to nothing")
    func emptyResult() {
        var result = PostgresQueryResult()
        result.columns = [Self.column("custom", oid: Self.customOID)]
        result.unresolvedBytes = [0: []]

        result.redecode(with: PostgresTypeRegistry())
        #expect(result.rows.isEmpty)
        #expect(result.unresolvedBytes.isEmpty)
    }

    /// A registry that still cannot name the type leaves the value alone rather
    /// than replacing it with something wrong — the bytes are dropped either way,
    /// because a second pass is all there is.
    @Test("a type the registry still does not know is left untouched")
    func unknownTypeIsLeftAlone() {
        var result = PostgresQueryResult()
        result.columns = [Self.column("custom", oid: Self.customOID)]
        result.rows = [[.blob(Array("raw".utf8))]]
        result.unresolvedBytes = [0: [Array("raw".utf8)]]

        result.redecode(with: PostgresTypeRegistry())
        #expect(result.rows[0][0] == .blob(Array("raw".utf8)))
        #expect(result.unresolvedBytes.isEmpty)
    }

    // MARK: - Rows that disagree with their description

    /// `decode` and `retainUnresolved` both walk a row against the columns the
    /// server described, and the sweep found four unguarded comparisons between
    /// them. Same family as the redecode bounds above and the pipeline machine's:
    /// a row whose width does not match its description is not something a
    /// well-behaved server produces, which is exactly why nothing reached the
    /// guards that exist for it.
    ///
    /// Driven through the state machine directly, since a real server cannot be
    /// asked to disagree with itself.
    static func machine(columns: [PostgresColumnDescription]) -> PostgresQueryStateMachine {
        var machine = PostgresQueryStateMachine(mode: .simple("SELECT 1"))
        _ = machine.start()
        _ = machine.handle(.rowDescription(columns))
        return machine
    }

    @Test("a row wider than its description decodes the surplus as untyped")
    func rowWiderThanDescription() {
        var machine = Self.machine(columns: [Self.column("only", oid: 25)])
        _ = machine.handle(.dataRow([Array("a".utf8), Array("surplus".utf8)]))
        _ = machine.handle(.commandComplete(tag: "SELECT 1"))

        guard case .succeeded(let result) = machine.handle(.readyForQuery(.idle)) else {
            Issue.record("expected success"); return
        }
        #expect(result.rows.first?.count == 2, "both values survive; neither reads off the end")
    }

    /// Unknown-typed columns on purpose: with a built-in type the retain loop
    /// short-circuits on the OID before it indexes the row, so the bounds it is
    /// meant to prove are never reached. That is how the first version of this
    /// passed while the mutant lived.
    @Test("a row narrower than its description is not an overrun")
    func rowNarrowerThanDescription() {
        var machine = Self.machine(columns: [
            Self.column("a", oid: Self.customOID),
            Self.column("b", oid: Self.customOID),
            Self.column("c", oid: Self.customOID),
        ])
        _ = machine.handle(.dataRow([Array("only".utf8)]))
        _ = machine.handle(.commandComplete(tag: "SELECT 1"))

        guard case .succeeded(let result) = machine.handle(.readyForQuery(.idle)) else {
            Issue.record("expected success"); return
        }
        #expect(result.rows.first?.count == 1)
    }

    /// A row with no description at all — every value takes the untyped
    /// fallback rather than indexing an empty array.
    @Test("a row with no description at all is decoded as untyped")
    func rowWithNoDescription() {
        var machine = PostgresQueryStateMachine(mode: .simple("SELECT 1"))
        _ = machine.start()
        _ = machine.handle(.dataRow([Array("a".utf8)]))
        _ = machine.handle(.commandComplete(tag: "SELECT 1"))

        guard case .succeeded(let result) = machine.handle(.readyForQuery(.idle)) else {
            Issue.record("expected success"); return
        }
        #expect(result.rows.count == 1)
    }

    /// `retainUnresolved` keeps bytes only for columns nothing recognised, so a
    /// projection of built-in types stores nothing at all. Inverting that test
    /// retains every column of every row — the memory this mechanism exists to
    /// avoid.
    @Test("only unrecognised columns are retained for a second pass")
    func onlyUnknownColumnsAreRetained() {
        // `25` is `text`, a built-in the driver already knows.
        var builtIn = Self.machine(columns: [Self.column("t", oid: 25)])
        _ = builtIn.handle(.dataRow([Array("a".utf8)]))
        _ = builtIn.handle(.commandComplete(tag: "SELECT 1"))
        guard case .succeeded(let plain) = builtIn.handle(.readyForQuery(.idle)) else {
            Issue.record("expected success"); return
        }
        #expect(plain.unresolvedBytes.isEmpty, "a built-in column must retain nothing")

        var custom = Self.machine(columns: [Self.column("c", oid: Self.customOID)])
        _ = custom.handle(.dataRow([Array("a".utf8)]))
        _ = custom.handle(.commandComplete(tag: "SELECT 1"))
        guard case .succeeded(let unknown) = custom.handle(.readyForQuery(.idle)) else {
            Issue.record("expected success"); return
        }
        #expect(!unknown.unresolvedBytes.isEmpty, "an unknown column must retain its bytes")
    }

}

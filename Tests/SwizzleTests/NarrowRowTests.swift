import Testing

@testable import Swizzle

/// Decoding a row that carries fewer values than the query asked for.
///
/// ## Why this happens at all
///
/// A row and the description it arrived with are not always the same width. A
/// server can send a short row; a driver can hand one back after an error; a
/// result set can be truncated mid-stream. The decoders guard against it with
/// `index < row.values.count`, and past that guard is a direct subscript — so
/// the guard is the only thing between a narrow row and an out-of-bounds read.
///
/// A mutation run relaxed all three of those guards to `<=` and the whole suite
/// stayed green, meaning nothing decoded at the boundary. This is not
/// hypothetical: the same shape was a real crash in the Postgres driver, where
/// `row.array(at: 2)` on a three-column description carrying one value went
/// straight past the end.
///
/// The three guards are in `Execute`, `Fragment` and `Streaming` — one per
/// decoding path — so a test that only covers `fetch` leaves two of them open.
@Suite("Narrow rows")
struct NarrowRowTests {

    private struct Jobs: SQLTable {
        static let tableName = "jobs"
        var tableAlias: String?
        var id: SQLColumn<Int64> { bigInt("id") }
        var state: SQLColumn<String> { varchar("state", 20) }
    }

    /// Returns rows with exactly one value, whatever was asked for.
    private struct ShortRowExecutor: SQLExecutor {
        typealias Dialect = Postgres
        func execute(sql: String, bindings: [SQLValue]) async throws -> [SQLRow] {
            [SQLRow(values: [.int(1)])]
        }
        func executeUpdate(sql: String, bindings: [SQLValue]) async throws -> Int { 0 }
    }

    /// A row with no values at all — the narrowest case, where even the first
    /// column is past the end.
    private struct EmptyRowExecutor: SQLExecutor {
        typealias Dialect = Postgres
        func execute(sql: String, bindings: [SQLValue]) async throws -> [SQLRow] {
            [SQLRow(values: [])]
        }
        func executeUpdate(sql: String, bindings: [SQLValue]) async throws -> Int { 0 }
    }

    /// **Two columns asked for, one value delivered.** The second decode sits
    /// exactly on the boundary: `index` equals `values.count`. It must report a
    /// decode failure rather than read past the end.
    @Test("a row shorter than the query asked for fails to decode rather than reading past the end")
    func shortRowIsADecodeError() async {
        let j = Jobs()
        let query = QueryBuilder<Postgres>().select(j.id, j.state).from(j)
        await #expect(throws: (any Error).self) {
            _ = try await query.fetch(on: ShortRowExecutor())
        }
    }

    /// The same for a row with nothing in it, where the *first* column is
    /// already out of range.
    @Test("an empty row fails to decode rather than reading past the end")
    func emptyRowIsADecodeError() async {
        let j = Jobs()
        let query = QueryBuilder<Postgres>().select(j.id).from(j)
        await #expect(throws: (any Error).self) {
            _ = try await query.fetch(on: EmptyRowExecutor())
        }
    }

    /// `fetchFirst` decodes through the same guard and is worth its own case —
    /// it is the call most likely to be used with a hand-written query, where
    /// the column list and the row are least likely to agree.
    @Test("fetchFirst on a short row fails to decode")
    func fetchFirstOnShortRow() async {
        let j = Jobs()
        let query = QueryBuilder<Postgres>().select(j.id, j.state).from(j)
        await #expect(throws: (any Error).self) {
            _ = try await query.fetchFirst(on: ShortRowExecutor())
        }
    }

    /// **The control.** A row of the right width still decodes, so a decoder
    /// that rejected everything would not satisfy the cases above.
    @Test("a row of the expected width still decodes")
    func matchingRowDecodes() async throws {
        struct MatchingExecutor: SQLExecutor {
            typealias Dialect = Postgres
            func execute(sql: String, bindings: [SQLValue]) async throws -> [SQLRow] {
                [SQLRow(values: [.int(7), .text("ready")])]
            }
            func executeUpdate(sql: String, bindings: [SQLValue]) async throws -> Int { 0 }
        }
        let j = Jobs()
        let rows = try await QueryBuilder<Postgres>().select(j.id, j.state).from(j)
            .fetch(on: MatchingExecutor())
        #expect(rows.count == 1)
        #expect(rows.first?.0 == 7)
        #expect(rows.first?.1 == "ready")
    }

    // MARK: - The other statement kinds

    /// **`RETURNING` decodes through its own copy of the same function.**
    ///
    /// There are seven copies of this decoder — one per statement kind plus the
    /// fragment and streaming paths — and the guard was in three of them. A test
    /// that only covers `SELECT` leaves the other four open, which is exactly
    /// how four of them came to be missing it.
    ///
    /// Postgres is used here because `RETURNING` is a Postgres capability; the
    /// builder refuses to write it for MySQL at compile time.
    @Test("INSERT ... RETURNING on a short row fails to decode rather than crashing")
    func insertReturningOnShortRow() async {
        let j = Jobs()
        let query = QueryBuilder<Postgres>()
            .insert(into: j).values { $0.set(j.id, to: 1) }
            .returning(j.id, j.state)
        await #expect(throws: (any Error).self) {
            _ = try await query.execute(on: ShortRowExecutor())
        }
    }

    @Test("UPDATE ... RETURNING on a short row fails to decode rather than crashing")
    func updateReturningOnShortRow() async {
        let j = Jobs()
        let query = QueryBuilder<Postgres>()
            .update(j).set(j.state, to: "done")
            .returning(j.id, j.state)
        await #expect(throws: (any Error).self) {
            _ = try await query.execute(on: ShortRowExecutor())
        }
    }

    @Test("DELETE ... RETURNING on a short row fails to decode rather than crashing")
    func deleteReturningOnShortRow() async {
        let j = Jobs()
        let query = QueryBuilder<Postgres>()
            .delete(from: j)
            .returning(j.id, j.state)
        await #expect(throws: (any Error).self) {
            _ = try await query.execute(on: ShortRowExecutor())
        }
    }
}

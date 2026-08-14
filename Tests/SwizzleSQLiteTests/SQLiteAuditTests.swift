import SwizzleCore
import SwizzleMigrate
import SwizzleSQLite
@testable import SwizzleSQLiteEngine
import Testing

/// The claims nothing was checking.
///
/// Written by asking of every SQLite claim the question that found five defects
/// on the other two engines: **what test proves this, and could that test pass if
/// the feature were absent?**
///
/// Most of SQLite's answers were good — the rowid-alias handling that bit twice
/// is pinned, and the timeout test measures elapsed time rather than trusting the
/// error. These are the ones that had no answer.
@Suite("SQLite audit")
struct SQLiteAuditTests {

    // MARK: - The reasons the amalgamation is vendored

    /// **The capability the version pin exists for.**
    ///
    /// `RETURNING` arrived in SQLite 3.35, and the amalgamation is vendored partly
    /// so it is always available rather than depending on whatever the platform
    /// ships. Nothing in `SwizzleSQLite` uses it, so nothing proved it — which
    /// makes it exactly the shape of `COM_QUIT`: a claim resting on a version
    /// number nobody exercised.
    ///
    /// Substituting a system SQLite older than 3.35 would break this and only
    /// this.
    @Test("RETURNING works, which is why the amalgamation is pinned")
    func returningWorks() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }

        _ = try await connection.query(
            "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL)"
        )
        let inserted = try await connection.query(
            "INSERT INTO t (name) VALUES (?1) RETURNING id, name", [.text("ada")]
        )
        #expect(inserted.count == 1)
        #expect(inserted[0].values[1] == .text("ada"))

        let deleted = try await connection.query(
            "DELETE FROM t WHERE name = ?1 RETURNING id", [.text("ada")]
        )
        #expect(deleted.count == 1)
    }

    /// The other reason: `pragma_table_info` as a **table-valued function**, which
    /// only works from 3.16. The introspector depends on it, so this is covered
    /// indirectly — asserted directly because the two reasons for the pin should
    /// both be visible.
    @Test("pragma_table_info is usable as a table-valued function")
    func pragmaAsFunction() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }

        _ = try await connection.query("CREATE TABLE t (id INTEGER, name TEXT NOT NULL)")
        let rows = try await connection.query(
            "SELECT name, \"notnull\" FROM pragma_table_info(?1) ORDER BY cid", [.text("t")]
        )
        #expect(rows.count == 2)
        #expect(rows[0].values[0] == .text("id"))
        #expect(rows[1].values[1] == .int(1))
    }

    // MARK: - Untested public API

    /// Never referenced by a test. It is also the only way to learn an
    /// auto-generated key on an engine with no `RETURNING` on every statement,
    /// so "probably fine" is not good enough.
    @Test("lastInsertRowID reports the row just inserted")
    func lastInsertRowID() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }

        _ = try await connection.query("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
        #expect(await connection.lastInsertRowID() == 0)

        _ = try await connection.query("INSERT INTO t (v) VALUES ('a')")
        #expect(await connection.lastInsertRowID() == 1)
        _ = try await connection.query("INSERT INTO t (v) VALUES ('b')")
        #expect(await connection.lastInsertRowID() == 2)

        // An explicit id sets it too — it is the rowid, not a counter.
        _ = try await connection.query("INSERT INTO t (id, v) VALUES (100, 'c')")
        #expect(await connection.lastInsertRowID() == 100)

        // A statement that inserts nothing leaves it where it was, rather than
        // resetting it — which is what makes reading it after an unrelated
        // statement a mistake.
        _ = try await connection.query("SELECT 1")
        #expect(await connection.lastInsertRowID() == 100)
    }

    /// The migrator reads the journal's shape through this, and nothing tested
    /// it. A wrong column list would surface as a migration that cannot verify.
    @Test("journalColumns names the journal's columns")
    func journalColumns() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }

        _ = try await connection.query(
            "CREATE TABLE swizzle_migrations (id INTEGER PRIMARY KEY, name TEXT, kind TEXT)"
        )
        let (sql, bindings) = SQLite.journalColumns(named: "swizzle_migrations")
        let rows = try await connection.query(sql, bindings)
        #expect(rows.map { $0.values[0] } == [.text("id"), .text("name"), .text("kind")])
    }

    /// Empty on purpose — SQLite support arrived after the journal gained `id`,
    /// so there is no older shape to migrate from. Asserted because "returns
    /// nothing" and "was never called" look identical from outside.
    @Test("there is no journal upgrade to run")
    func upgradeJournalIsEmpty() {
        #expect(SQLite.upgradeJournal(named: "swizzle_migrations").isEmpty)
    }

    // MARK: - Claims about the table name, which is interpolated

    /// The journal table name is spliced into SQL rather than bound, because
    /// SQLite takes no placeholder for a `pragma_table_info` argument in that
    /// position. So it has to be quoted, and a name with a quote in it must not
    /// escape.
    @Test("a journal table name with a quote in it cannot inject")
    func journalNameIsQuoted() {
        let (sql, _) = SQLite.journalColumns(named: "it's")
        #expect(sql.contains("'it''s'"))
        #expect(!sql.contains("'it's'"))
    }
}

/// Streaming laziness, proved rather than assumed.
@Suite("SQLite streaming is genuinely lazy")
struct SQLiteLazinessTests {

    /// **The existing test could not fail.**
    ///
    /// `SQLiteTests` streams 50,000 rows, breaks at three, and asserts it saw
    /// `[1, 2, 3]`. An implementation that materialised all 50,000 into an array
    /// and handed them out one at a time passes that identically — the consumer
    /// only reads three either way. It proves ordering and `break`; it says
    /// nothing about when the rows were produced.
    ///
    /// That matters here specifically: the first version of this stream used an
    /// `AsyncThrowingStream` buffering policy in the belief that it was
    /// backpressure. It is not — it *discards* — and it took a rewrite to a
    /// pull-based iterator to fix.
    ///
    /// This query has **no last row**. A lazy iterator reads three and stops; an
    /// eager one runs until the process dies. Nothing to assert about counts —
    /// finishing at all is the result.
    @Test("an unbounded query can be streamed and abandoned", .timeLimit(.minutes(1)))
    func infiniteQueryIsStreamable() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }

        var seen: [Int64] = []
        for try await row in try await connection.executor.stream(
            sql: """
                WITH RECURSIVE endless(n) AS (
                    SELECT 1 UNION ALL SELECT n + 1 FROM endless
                )
                SELECT n FROM endless
                """,
            bindings: []
        ) {
            if case .int(let n) = row.values[0] { seen.append(n) }
            if seen.count == 3 { break }
        }

        #expect(seen == [1, 2, 3])

        // And the connection is usable afterwards, so abandoning an unbounded
        // statement releases it rather than leaving it running.
        let rows = try await connection.query("SELECT 42")
        #expect(rows.first?.values.first == .int(42))
    }

    /// The same shape through the *erased* executor, because that is the path the
    /// generated code and the query builder take — and erasure is where streaming
    /// was silently lost once before.
    @Test("laziness survives erasure", .timeLimit(.minutes(1)))
    func lazinessSurvivesErasure() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }

        let erased = connection.executor.erased
        #expect(erased.canStream)

        var count = 0
        for try await _ in try await erased.stream(
            sql: """
                WITH RECURSIVE endless(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM endless)
                SELECT n FROM endless
                """
        ) {
            count += 1
            if count == 3 { break }
        }
        #expect(count == 3)
    }
}

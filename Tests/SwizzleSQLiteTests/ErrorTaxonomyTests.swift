import Foundation
import SwizzleCore
import Testing
@testable import SwizzleSQLite

/// The error taxonomy, exercised against a real database rather than by
/// constructing error values by hand.
///
/// Constructing them by hand would prove the switch statement compiles. Making
/// SQLite actually raise each one proves the codes are the codes SQLite really
/// sends — which is the part that would otherwise be wrong for years without
/// anybody noticing.
@Suite("SQLite error taxonomy")
struct SQLiteErrorTaxonomyTests {

    static func schema() async throws -> SQLiteConnection {
        let connection = try SQLiteConnection.inMemory()
        _ = try await connection.query(
            """
            CREATE TABLE parents (id INTEGER PRIMARY KEY, code TEXT NOT NULL UNIQUE)
            """
        )
        _ = try await connection.query(
            """
            CREATE TABLE children (
                id INTEGER PRIMARY KEY,
                parent_id INTEGER NOT NULL REFERENCES parents(id),
                score INTEGER NOT NULL CHECK (score >= 0)
            )
            """
        )
        _ = try await connection.query("INSERT INTO parents VALUES (1, 'a')")
        return connection
    }

    func kind(_ connection: SQLiteConnection, _ sql: String) async -> SQLErrorKind? {
        do {
            _ = try await connection.query(sql)
            return nil
        } catch let error as SQLDiagnosable {
            return error.sqlKind
        } catch {
            return nil
        }
    }

    /// **Corruption gets its own kind**, and this is the test that makes it more
    /// than a line in a table: a real file, really damaged, really reported.
    ///
    /// It used to land in `.other`, indistinguishable from a typo — while being
    /// the one error where retrying is pointless and the answer is a backup. All
    /// three engines could report it and all three said `.other`.
    @Test("a corrupted database file is reported as corruption")
    func corruptionIsItsOwnKind() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swizzle-corrupt-\(UInt32.random(in: 0..<UInt32.max))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("corrupt.db").path

        // A real database first, with enough rows to occupy several pages so
        // there is a B-tree to damage.
        let writer = try SQLiteConnection(path: path)
        _ = try await writer.query("PRAGMA journal_mode = DELETE")
        _ = try await writer.query("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
        for id in 1...500 {
            _ = try await writer.query(
                "INSERT INTO t VALUES (?1, ?2)", [.int(Int64(id)), .text(String(repeating: "x", count: 200))]
            )
        }
        writer.close()

        // Then damage it: overwrite the interior of the file, leaving the header
        // intact so it still opens as a database and fails on read instead.
        let handle = try FileHandle(forUpdating: URL(fileURLWithPath: path))
        try handle.seek(toOffset: 4096)
        try handle.write(contentsOf: Data(repeating: 0xFF, count: 4096))
        try handle.close()

        let reader = try SQLiteConnection(path: path)
        defer { reader.close() }
        // `PRAGMA integrity_check` reports rather than throws, so the read is a
        // plain query — the corruption has to surface as an error from stepping.
        do {
            _ = try await reader.query("SELECT count(*) FROM t")
            // Not every byte pattern breaks every page, so a clean read here is
            // not a test failure — it is a test that did not get to run.
            Issue.record("the file survived the damage; nothing was proven")
        } catch let error as SQLiteError {
            #expect(
                error.sqlKind == .dataCorrupted,
                "corruption reported as \(error.sqlKind) (code \(error.code))"
            )
        }
    }

    /// The four constraint kinds are distinguishable, which is the whole reason
    /// the extended result codes are switched on.
    @Test("each constraint failure is identified separately")
    func constraintsAreDistinguished() async throws {
        let connection = try await Self.schema()
        defer { connection.close() }

        #expect(await kind(connection, "INSERT INTO parents VALUES (2, 'a')") == .uniqueViolation)
        #expect(await kind(connection, "INSERT INTO parents VALUES (1, 'b')") == .uniqueViolation)
        #expect(
            await kind(connection, "INSERT INTO children VALUES (1, 99, 1)")
                == .foreignKeyViolation
        )
        #expect(
            await kind(connection, "INSERT INTO children VALUES (2, 1, NULL)")
                == .notNullViolation
        )
        #expect(
            await kind(connection, "INSERT INTO children VALUES (3, 1, -5)")
                == .checkViolation
        )
    }

    @Test("a statement that will not compile is a syntax error")
    func syntaxErrors() async throws {
        let connection = try await Self.schema()
        defer { connection.close() }
        #expect(await kind(connection, "SELECT * FROM nope") == .syntax)
        #expect(await kind(connection, "NOT SQL AT ALL") == .syntax)
    }

    /// SQLite is the one engine that can answer this honestly, because it is
    /// in-process: if `step` returned an error, nothing committed.
    @Test("a rejected statement definitely did not apply")
    func rejectedStatementsDidNotApply() async throws {
        let connection = try await Self.schema()
        defer { connection.close() }

        do {
            _ = try await connection.query("INSERT INTO parents VALUES (2, 'a')")
            Issue.record("expected a unique violation")
        } catch let error as SQLDiagnosable {
            #expect(error.mayHaveApplied == false)
            // And the table proves it.
            let rows = try await connection.query("SELECT COUNT(*) FROM parents")
            #expect(rows.first?.values.first == .int(1))
        }
    }

    /// The conjunction is the point. A unique violation is not transient, so it
    /// is not worth retrying however safe a retry would be.
    @Test("retry safety needs both halves")
    func retrySafetyNeedsBothHalves() async throws {
        let connection = try await Self.schema()
        defer { connection.close() }

        do {
            _ = try await connection.query("INSERT INTO parents VALUES (2, 'a')")
            Issue.record("expected a unique violation")
        } catch let error as SQLDiagnosable {
            #expect(error.mayHaveApplied == false)   // safe to repeat
            #expect(error.sqlKind.isTransient == false)  // but pointless
            #expect(error.isSafeToRetry == false)
        }
    }

    @Test("the native code survives the translation")
    func nativeCodeIsPreserved() async throws {
        let connection = try await Self.schema()
        defer { connection.close() }
        do {
            _ = try await connection.query("INSERT INTO parents VALUES (2, 'a')")
            Issue.record("expected a unique violation")
        } catch let error as SQLDiagnosable {
            // SQLITE_CONSTRAINT_UNIQUE — the taxonomy is coarse on purpose, and
            // the exact code is still there for anyone who needs it.
            #expect(error.nativeCode == 2067)
        }
    }

    @Test("connection-level and statement-level failures are separable")
    func statementLevelIsDistinguished() {
        #expect(SQLErrorKind.uniqueViolation.isStatementLevel)
        #expect(SQLErrorKind.syntax.isStatementLevel)
        // A pool discards the connection for these and keeps it for the others.
        #expect(!SQLErrorKind.connection.isStatementLevel)
        #expect(!SQLErrorKind.authentication.isStatementLevel)
    }

    @Test("only contention is transient")
    func transienceIsNarrow() {
        #expect(SQLErrorKind.deadlock.isTransient)
        #expect(SQLErrorKind.serializationFailure.isTransient)
        #expect(SQLErrorKind.lockTimeout.isTransient)

        // Retrying these forever would just fail forever.
        #expect(!SQLErrorKind.syntax.isTransient)
        #expect(!SQLErrorKind.uniqueViolation.isTransient)
        #expect(!SQLErrorKind.permission.isTransient)
    }
}

@Suite("Query timeouts")
struct QueryTimeoutTests {

    /// A slow statement is abandoned rather than waited on.
    ///
    /// The recursive CTE is the cheapest way to make SQLite genuinely busy for
    /// longer than the deadline without sleeping.
    @Test("a statement that outruns its deadline throws")
    func slowStatementTimesOut() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }

        await #expect(throws: SQLTimeoutError.self) {
            try await withQueryTimeout(.milliseconds(50)) {
                _ = try await connection.query(
                    """
                    WITH RECURSIVE slow(n) AS (
                        SELECT 1 UNION ALL SELECT n + 1 FROM slow WHERE n < 50000000
                    )
                    SELECT COUNT(*) FROM slow
                    """
                )
            }
        }
    }

    @Test("a fast statement is unaffected")
    func fastStatementPasses() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }

        let rows = try await withQueryTimeout(.seconds(5)) {
            try await connection.query("SELECT 1 AS n")
        }
        #expect(rows.first?.values.first == .int(1))
    }

    /// Giving up on waiting says nothing about whether the server gave up on
    /// working, so a timeout is never safe to retry blindly.
    @Test("a timeout reports that it may have applied")
    func timeoutMayHaveApplied() {
        let error = SQLTimeoutError(duration: .seconds(1), sql: "UPDATE t SET x = 1")
        #expect(error.sqlKind == .timeout)
        #expect(error.mayHaveApplied)
        #expect(error.sqlKind.isTransient)
        // Transient but possibly applied — precisely the combination that must
        // not be retried automatically.
        #expect(error.isSafeToRetry == false)
    }
}

extension QueryTimeoutTests {
    /// A timeout must stop the *database*, not just the caller.
    ///
    /// Without `sqlite3_interrupt` the cancelled task still waits for the
    /// blocking `sqlite3_step` to finish on its queue — so the deadline bounds
    /// nothing and the connection stays busy. This test is a stopwatch: the
    /// statement below runs for many seconds, and finishing well inside the
    /// deadline is the only evidence that the interrupt landed.
    @Test("a timeout interrupts the statement rather than waiting it out")
    func timeoutActuallyInterrupts() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }

        let started = ContinuousClock.now
        await #expect(throws: SQLTimeoutError.self) {
            try await withQueryTimeout(.milliseconds(50)) {
                _ = try await connection.query(
                    """
                    WITH RECURSIVE slow(n) AS (
                        SELECT 1 UNION ALL SELECT n + 1 FROM slow WHERE n < 200000000
                    )
                    SELECT COUNT(*) FROM slow
                    """
                )
            }
        }
        let elapsed = ContinuousClock.now - started
        // Ten seconds, not two.
        //
        // The claim is "orders of magnitude below the statement's own runtime",
        // not "fast": that CTE counts to two hundred million and runs for
        // *minutes* uninterrupted, so anything in seconds proves the interrupt
        // landed. How quickly SQLite notices depends on the machine — it checks
        // the flag every so many VDBE steps — and the original bound was
        // calibrated on one fast one. In a Linux container the same interrupt
        // took **2.95 s**, which failed a two-second bound while demonstrating
        // exactly the behaviour under test.
        #expect(
            elapsed < .seconds(10),
            "took \(elapsed) — the statement was waited out, not interrupted"
        )

        // And the connection is immediately usable again.
        let rows = try await connection.query("SELECT 1 AS n")
        #expect(rows.first?.values.first == .int(1))
    }
}

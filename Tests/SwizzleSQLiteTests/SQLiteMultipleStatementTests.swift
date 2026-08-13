import SwizzleCore
import SwizzleMigrate
import Testing

@testable import SwizzleSQLite

/// What happens to the SQL after the first statement.
///
/// `sqlite3_prepare_v2` compiles **one** statement and hands back a pointer to
/// whatever follows it. Passing `nil` for that pointer — which is the easy thing
/// to do, and what we did — means the rest is compiled by nobody and runs never.
/// The call still returns `SQLITE_OK`, the first statement still executes, and
/// the caller is told nothing.
///
/// `rusqlite` treats this as an error (`Error::MultipleStatement`) for the same
/// reason: silently executing a fraction of what was asked for is the worst
/// available outcome. Migrations here go through `SQLStatementSplitter` and were
/// never affected; `query` is public API and was.
@Suite("SQLite multiple statements")
struct SQLiteMultipleStatementTests {

    /// **The data loss.** Two inserts go in, one row comes out, and nothing
    /// anywhere reports a problem.
    @Test("a trailing statement is refused rather than silently dropped")
    func trailingStatementIsRefused() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }
        _ = try await connection.query("CREATE TABLE t (id INTEGER PRIMARY KEY)")

        await #expect(throws: SQLiteError.self) {
            _ = try await connection.query(
                "INSERT INTO t VALUES (1); INSERT INTO t VALUES (2)"
            )
        }

        // And the refusal is total: nothing ran, so the caller is not left
        // reasoning about a half-applied statement pair.
        let rows = try await connection.query("SELECT count(*) FROM t")
        #expect(rows[0].values[0] == .int(0))
    }

    /// The error has to say what to do about it. "Near ';': syntax error" would
    /// be technically a refusal and practically useless.
    @Test("the error names the problem")
    func errorNamesTheProblem() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }

        do {
            _ = try await connection.query("SELECT 1; SELECT 2")
            Issue.record("expected a refusal")
        } catch let error as SQLiteError {
            #expect(error.message.contains("one statement"))
            #expect(error.sqlKind == .syntax)
        }
    }

    // MARK: - What must still work

    /// A trailing semicolon is not a second statement, and refusing it would
    /// break every hand-written query that ends in one.
    @Test("a trailing semicolon is fine")
    func trailingSemicolonIsFine() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }

        let rows = try await connection.query("SELECT 1;")
        #expect(rows[0].values[0] == .int(1))
        _ = try await connection.query("SELECT 1;   ")
        _ = try await connection.query("SELECT 1;\n\n")
    }

    /// Nor is a trailing comment, which is what a `-- +swizzle` migration leaves
    /// behind after splitting.
    @Test("trailing comments and whitespace are fine")
    func trailingCommentsAreFine() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }

        _ = try await connection.query("SELECT 1; -- a trailing note")
        _ = try await connection.query("SELECT 1;\n-- one\n-- two\n")
        _ = try await connection.query("SELECT 1; /* block */")
        _ = try await connection.query("SELECT 1 /* before the end */;")
    }

    /// A semicolon *inside* a string or an identifier is not a statement
    /// boundary, and SQLite is the one that decides that — which is the whole
    /// reason this check asks SQLite rather than scanning for `;` itself.
    @Test("a semicolon inside a literal is not a second statement")
    func semicolonInsideLiteral() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }

        let rows = try await connection.query("SELECT 'a;b' AS v")
        #expect(rows[0].values[0] == .text("a;b"))

        let quoted = try await connection.query(#"SELECT 1 AS "odd;name""#)
        #expect(quoted[0].values[0] == .int(1))
    }

    /// Migrations split their own SQL and feed it here one statement at a time,
    /// so the new refusal must not reach them. This is the path that would have
    /// broken loudly if the check were too eager.
    @Test("a migration with several statements still applies")
    func migrationsStillApply() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }

        let splitter = SQLStatementSplitter(syntax: SQLite.migrationSyntax)
        for statement in splitter.split(
            """
            CREATE TABLE a (id INTEGER PRIMARY KEY);
            CREATE TABLE b (id INTEGER PRIMARY KEY, note TEXT DEFAULT 'x;y');
            INSERT INTO a VALUES (1);
            """
        ) {
            _ = try await connection.query(statement)
        }

        let rows = try await connection.query("SELECT count(*) FROM a")
        #expect(rows[0].values[0] == .int(1))
    }
}

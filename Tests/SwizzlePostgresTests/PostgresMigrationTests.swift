import Foundation
import Testing
@testable import SwizzleCore
@testable import SwizzleMigrate
@testable import SwizzlePostgres

/// The Postgres engine against a live server.
///
/// The dialect tests cover the SQL it emits; these cover what only a database
/// can answer — that the journal round-trips, the advisory lock actually
/// excludes, and a failed migration really does roll back, which is the one
/// behaviour that differs from MySQL by design rather than by accident.
@Suite("Postgres migrations", .serialized, .enabled(if: PostgresFixture.isAvailable,
       "Postgres not reachable — start it with ./Scripts/test-servers.sh up"))
struct PostgresMigrationTests {

    static func migrator(
        _ connection: any EngineConnection, journal: String, lock: String,
        files: [String: String]
    ) throws -> Migrator {
        var configuration = Migrator.Configuration()
        configuration.journalTable = journal
        configuration.lockName = lock
        return Migrator(
            executor: connection.executor, dialect: connection.dialect,
            source: try InMemoryMigrations(files: files, syntax: .postgres),
            configuration: configuration
        )
    }

    @Test("migrations apply, record and revert")
    func lifecycle() async throws {
        let connection = try await PostgresFixture.connect()
        defer { connection.close() }
        let unique = UInt32.random(in: 0..<UInt32.max)
        let table = "pgm_\(unique)"
        let journal = "journal_\(unique)"
        defer { Task { await PostgresFixture.drop(connection, [table, journal]) } }

        let migrator = try Self.migrator(
            connection, journal: journal, lock: "swizzle_pg_\(unique)",
            files: [
                "1_users.sql": """
                    -- +swizzle Up
                    CREATE TABLE \(table) (id SERIAL PRIMARY KEY, email TEXT NOT NULL);
                    -- +swizzle Down
                    DROP TABLE \(table);
                    """,
                "2_index.sql": """
                    -- +swizzle Up
                    CREATE UNIQUE INDEX \(table)_email ON \(table) (email);
                    -- +swizzle Down
                    DROP INDEX \(table)_email;
                    """,
            ]
        )

        #expect(try await migrator.up().compactMap(\.version) == [1, 2])
        #expect(try await migrator.up().isEmpty, "a second run is a no-op")

        // The journal round-trips: applied_at is a real timestamp, not the
        // mojibake a binary TIMESTAMPTZ produced before it was decoded properly.
        let statuses = try await migrator.status()
        #expect(statuses.allSatisfy { !$0.isPending })
        guard case .applied(let at) = statuses[0].state else {
            Issue.record("expected applied, got \(statuses[0].state)"); return
        }
        #expect(at.hasPrefix("20"), "applied_at should read as a date, got '\(at)'")

        #expect(try await migrator.down().compactMap(\.version) == [2])
        #expect(try await migrator.down().compactMap(\.version) == [1])
        #expect(try await migrator.status().allSatisfy(\.isPending))
    }

    /// The behaviour that differs from MySQL on purpose. On Postgres a failed
    /// migration really is atomic, so the first statement must not survive.
    @Test("a failed migration rolls back entirely")
    func failureRollsBack() async throws {
        let connection = try await PostgresFixture.connect()
        defer { connection.close() }
        let unique = UInt32.random(in: 0..<UInt32.max)
        let table = "pgm_\(unique)"
        let journal = "journal_\(unique)"
        defer { Task { await PostgresFixture.drop(connection, [table, journal]) } }

        let migrator = try Self.migrator(
            connection, journal: journal, lock: "swizzle_pg_\(unique)",
            files: ["1_bad.sql": """
                -- +swizzle Up
                CREATE TABLE \(table) (id INT PRIMARY KEY);
                THIS IS NOT SQL;
                """]
        )

        do {
            try await migrator.up()
            Issue.record("expected the bad statement to fail")
        } catch let error as MigrationError {
            guard case .statementFailed(let index, _, let partial) = error.kind else {
                Issue.record("expected statementFailed, got \(error.kind)"); return
            }
            #expect(index == 1)
            #expect(!partial, "Postgres rolls DDL back, so nothing is partially applied")
            #expect(error.description.contains("rolled back"))
            // The server's own message must reach the user — postgres-nio's
            // description is deliberately vague, so this is the check that
            // String(reflecting:) is still in the path.
            #expect(error.description.lowercased().contains("syntax error"))
        }

        // The first statement did *not* survive, which is the whole claim.
        let rows = try await connection.executor.execute(
            sql: "SELECT COUNT(*) FROM information_schema.tables "
                + "WHERE table_schema = CURRENT_SCHEMA() AND table_name = $1",
            bindings: [.text(table)]
        )
        #expect(PostgresFixture.int(rows.first?.values.first) == 0)
    }

    /// The retry the dialect documented and the migrator did not have: a second
    /// migrator must wait for the lock rather than fail on the spot, because
    /// `pg_try_advisory_lock` answers immediately.
    @Test("a concurrent migrator waits rather than double-applying")
    func lockSerialises() async throws {
        let first = try await PostgresFixture.connect()
        defer { first.close() }
        let second = try await PostgresFixture.connect()
        defer { second.close() }

        let unique = UInt32.random(in: 0..<UInt32.max)
        let table = "pgm_\(unique)"
        let journal = "journal_\(unique)"
        defer { Task { await PostgresFixture.drop(first, [table, journal]) } }

        let files = [
            "1_t.sql": "-- +swizzle Up\nCREATE TABLE \(table) (id INT PRIMARY KEY);"
                + "\n-- +swizzle Down\nDROP TABLE \(table);"
        ]
        let a = try Self.migrator(first, journal: journal, lock: "lk_\(unique)", files: files)
        let b = try Self.migrator(second, journal: journal, lock: "lk_\(unique)", files: files)

        // Reported rather than rethrown, so a failure names *which* migrator
        // broke and why instead of surfacing a redacted PSQLError.
        async let one = Result(catching: { try await a.up() })
        async let two = Result(catching: { try await b.up() })
        let results = await [one, two]
        var counts: [Int] = []
        for result in results {
            switch result {
            case .success(let applied): counts.append(applied.count)
            case .failure(let error):
                Issue.record("a migrator failed instead of waiting: \(String(reflecting: error))")
                return
            }
        }
        counts.sort()

        // Without the lock both would run `CREATE TABLE` and one would fail.
        #expect(counts == [0, 1], "one applied it, the other found nothing — got \(counts)")
    }

    @Test("the journal is created with Postgres types")
    func journalShape() async throws {
        let connection = try await PostgresFixture.connect()
        defer { connection.close() }
        let unique = UInt32.random(in: 0..<UInt32.max)
        let journal = "journal_\(unique)"
        defer { Task { await PostgresFixture.drop(connection, [journal]) } }

        let migrator = try Self.migrator(
            connection, journal: journal, lock: "lk_\(unique)",
            files: ["1_t.sql": "-- +swizzle Up\nSELECT 1;"]
        )
        try await migrator.up()

        let rows = try await connection.executor.execute(
            sql: """
                SELECT column_name, data_type FROM information_schema.columns
                WHERE table_schema = CURRENT_SCHEMA() AND table_name = $1
                ORDER BY ordinal_position
                """,
            bindings: [.text(journal)]
        )
        let columns = rows.compactMap { row -> String? in
            guard case .text(let name)? = row.values.first else { return nil }
            return name
        }
        #expect(columns == ["id", "version", "name", "kind", "checksum", "applied_at"])
    }

    /// Affected rows, which used to be silently zero.
    ///
    /// `executeUpdate` drained the row sequence and counted it. `UPDATE` and
    /// `DELETE` return no rows, so the answer was always 0 — and nothing caught
    /// it, because the migrator ignores the count and every other engine got it
    /// right. This is the test that would have.
    @Test("UPDATE and DELETE report how many rows they changed")
    func affectedRowsAreReported() async throws {
        let connection = try await PostgresFixture.connect()
        defer { connection.close() }
        let table = "pgaffected_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await PostgresFixture.drop(connection, [table]) } }

        let db = connection.executor
        _ = try await db.execute(
            sql: "CREATE TABLE \"\(table)\" (id INT PRIMARY KEY, score INT NOT NULL)"
        )

        let inserted = try await db.executeUpdate(
            sql: "INSERT INTO \"\(table)\" VALUES (1,10),(2,20),(3,30)"
        )
        #expect(inserted == 3, "INSERT should report 3, not the 0 rows it returns")

        let updated = try await db.executeUpdate(
            sql: "UPDATE \"\(table)\" SET score = 0 WHERE score >= $1", bindings: [.int(20)]
        )
        #expect(updated == 2)

        let deleted = try await db.executeUpdate(sql: "DELETE FROM \"\(table)\" WHERE id = 1")
        #expect(deleted == 1)

        // A statement Postgres reports no count for answers 0 rather than throwing.
        let ddl = try await db.executeUpdate(sql: "CREATE INDEX ON \"\(table)\" (score)")
        #expect(ddl == 0)

        let remaining = try await db.execute(sql: "SELECT COUNT(*) FROM \"\(table)\"")
        #expect(remaining.first?.values.first == .int(2))
    }

    /// The bug had a visible symptom beyond the number: the unfiltered-write
    /// warning reported "changed 0 rows" while rewriting a whole table.
    @Test("the unfiltered-write warning reports the real count")
    func unfilteredWarningCountsRows() async throws {
        let connection = try await PostgresFixture.connect()
        defer { connection.close() }
        let table = "pgwarn_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await PostgresFixture.drop(connection, [table]) } }

        let db = connection.executor
        _ = try await db.execute(sql: "CREATE TABLE \"\(table)\" (id INT PRIMARY KEY)")
        _ = try await db.executeUpdate(sql: "INSERT INTO \"\(table)\" VALUES (1),(2),(3),(4)")

        let affected = try await db.executeUpdate(sql: "UPDATE \"\(table)\" SET id = id + 100")
        #expect(affected == 4)
    }

}

enum PostgresFixture {
    static let url = PostgresTestServer.url

    static var isAvailable: Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let reachable = ReachabilityBox()
        Task {
            if let connection = try? await PostgresEngine.connect(url: url) {
                connection.close()
                reachable.markReachable()
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 8)
        return reachable.isReachable
    }

    static func connect() async throws -> any EngineConnection {
        try await PostgresEngine.connect(url: url)
    }

    static func drop(_ connection: any EngineConnection, _ names: [String]) async {
        for name in names {
            _ = try? await connection.executor.executeUpdate(
                sql: "DROP TABLE IF EXISTS \"\(name)\"", bindings: []
            )
        }
    }

    static func int(_ value: SQLValue?) -> Int64? {
        switch value {
        case .int(let raw): raw
        case .text(let raw): Int64(raw)
        case .double(let raw): Int64(raw)
        default: nil
        }
    }
}

extension Result where Failure == any Error {
    /// `async let` cannot bind a throwing call without rethrowing at the await,
    /// which loses which of the two failed.
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) }
        catch { self = .failure(error) }
    }
}

/// Carries a value out of a `Task` into a synchronous caller.
///
/// The obvious spelling is `nonisolated(unsafe) var` captured by the task, and it
/// compiles — on some toolchains. Swift 6.2.4 rejects it: the closure captures a
/// mutable local, so the closure itself is non-Sendable and sending it "risks causing
/// data races". Which is a fair description of what `nonisolated(unsafe)` does, since
/// the annotation silences the checker rather than making the access safe.
///
/// A locked box makes the closure capture only Sendable things and the synchronisation
/// real rather than asserted. Found because CI had been running Swift 6.1 while this
/// was developed against 6.3.3 — two versions apart, and neither of them diagnosed it.
final class ReachabilityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isReachable: Bool { lock.withLock { value } }
    func markReachable() { lock.withLock { value = true } }
}

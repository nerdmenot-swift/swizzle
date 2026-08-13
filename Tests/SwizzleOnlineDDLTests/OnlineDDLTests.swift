import SwizzleMySQLEngine
import Foundation
import NIOCore
import NIOPosix
import SwizzleCore
import Testing
@testable import SwizzleMySQL
@testable import SwizzleMigrate
@testable import SwizzleOnlineDDL

/// Zero-downtime ALTER, against a real server.
///
/// The test that matters is `survivesConcurrentWrites`: anything can copy a
/// static table correctly. The whole point of the binlog approach is that writes
/// landing *during* the copy still reach the ghost, and that is only provable by
/// writing while it runs.
@Suite(
    "Online DDL",
    .serialized,
    .enabled(if: OnlineTestSupport.isAvailable, "Integration servers not reachable")
)
struct OnlineDDLTests {

    static func connect() async throws -> MySQLConnection {
        try await OnlineTestSupport.connect()
    }

    static func makeTable(_ connection: MySQLConnection, rows: Int) async throws -> String {
        let table = "ddl_\(UInt32.random(in: 0..<UInt32.max))"
        try await connection.query("""
            CREATE TABLE \(table) (
                id INT AUTO_INCREMENT PRIMARY KEY,
                email VARCHAR(255) NOT NULL,
                score INT NOT NULL DEFAULT 0
            )
            """)
        if rows > 0 {
            var batch = 0
            while batch < rows {
                let upper = min(batch + 500, rows)
                let values = (batch..<upper).map { "('u\($0)@x', \($0))" }.joined(separator: ",")
                try await connection.query("INSERT INTO \(table) (email, score) VALUES \(values)")
                batch = upper
            }
        }
        return table
    }

    static func cleanUp(_ connection: MySQLConnection, _ table: String) async {
        for suffix in ["", "_del", "_gho", "_ghc"] {
            let name = suffix.isEmpty ? table : "_\(table)\(suffix)"
            _ = try? await connection.query("DROP TABLE IF EXISTS \(name)")
        }
    }

    static func engine(
        chunkSize: Int = 200, pause: Duration = .milliseconds(5)
    ) -> MySQLOnlineDDL {
        var configuration = MySQLOnlineDDL.Configuration()
        configuration.chunkSize = chunkSize
        configuration.pauseBetweenChunks = pause
        configuration.serverID = UInt32.random(in: 900_000..<999_999)
        return MySQLOnlineDDL(
            connect: { try await OnlineTestSupport.connect() },
            configuration: configuration
        )
    }

    // MARK: - The basic case

    @Test("adds a column without holding the table")
    func addsAColumn() async throws {
        let connection = try await Self.connect()
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection, rows: 1000)
        defer { Task { await Self.cleanUp(connection, table) } }

        try await Self.engine().alter(table: table, "ADD COLUMN nickname VARCHAR(64) NULL")

        // The new column exists, and every row came across.
        let count = try await connection.executeFirst(
            "SELECT COUNT(*) FROM \(unescaped: table)", as: Int.self)
        #expect(count == 1000)

        let columns = try await connection.execute(
            MySQLQuery(unsafeSQL: """
                SELECT column_name FROM information_schema.columns
                WHERE table_schema = DATABASE() AND table_name = ? ORDER BY ordinal_position
                """, binds: [.bytes(Array(table.utf8))]),
            as: String.self)
        #expect(columns == ["id", "email", "score", "nickname"])

        // Data is intact, not just row-shaped.
        let sample = try await connection.executeFirst(
            "SELECT email, score FROM \(unescaped: table) WHERE id = 1",
            as: (String, Int).self)
        #expect(sample?.0 == "u0@x")
        #expect(sample?.1 == 0)

        // The original is retired, not destroyed.
        let retired = try await connection.executeFirst(
            MySQLQuery(unsafeSQL: """
                SELECT COUNT(*) FROM information_schema.tables
                WHERE table_schema = DATABASE() AND table_name = ?
                """, binds: [.bytes(Array("_\(table)_del".utf8))]),
            as: Int.self)
        #expect(retired == 1, "the pre-migration data is kept, not dropped")
    }

    // MARK: - The point of the whole exercise

    /// Writes land throughout the copy. Every one must survive into the new
    /// table — inserts, updates and deletes alike.
    @Test("writes during the copy are not lost")
    func survivesConcurrentWrites() async throws {
        let connection = try await Self.connect()
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection, rows: 3000)
        defer { Task { await Self.cleanUp(connection, table) } }

        let writer = try await Self.connect()
        defer { writer.closeImmediately() }

        // Small chunks and a pause, so the copy is slow enough for the writes to
        // genuinely interleave rather than landing before or after it.
        let engine = Self.engine(chunkSize: 100, pause: .milliseconds(15))

        async let migration: Void = engine.alter(
            table: table, "ADD COLUMN nickname VARCHAR(64) NULL")

        // Insert new rows, update existing ones, and delete some — the three
        // event kinds the applier has to handle.
        var inserted: [Int] = []
        for round in 0..<40 {
            let result = try await writer.query(
                "INSERT INTO \(table) (email, score) VALUES ('new\(round)@x', \(9000 + round))")
            inserted.append(Int(result.lastInsertID))
            try await writer.query(
                "UPDATE \(table) SET score = 7777 WHERE id = \(round + 1)")
            try await writer.query("DELETE FROM \(table) WHERE id = \(1500 + round)")
            try await Task.sleep(for: .milliseconds(10))
        }

        try await migration

        // Inserts arrived.
        for id in inserted {
            let row = try await connection.executeFirst(
                "SELECT score FROM \(unescaped: table) WHERE id = \(id)", as: Int.self)
            #expect(row != nil, "row \(id) inserted during the copy is missing")
        }

        // Updates arrived.
        let updated = try await connection.executeFirst(
            "SELECT COUNT(*) FROM \(unescaped: table) WHERE score = 7777", as: Int.self)
        #expect(updated == 40, "updates during the copy did not all arrive — got \(updated ?? -1)")

        // Deletes arrived.
        let deleted = try await connection.executeFirst(
            "SELECT COUNT(*) FROM \(unescaped: table) WHERE id BETWEEN 1500 AND 1539",
            as: Int.self)
        #expect(deleted == 0, "rows deleted during the copy came back")

        // And the total adds up: 3000 original + 40 inserted - 40 deleted.
        //
        // This is the assertion that caught the copy's cursor race: the copy
        // advanced past rows it had never inserted whenever a DELETE landed
        // between its two reads of the live table, losing one row per delete that
        // hit the gap. Every other check here passed while it did — the inserts,
        // updates and deletes all arrived — because the lost rows were untouched
        // originals nobody was looking at. Only the count knew.
        let total = try await connection.executeFirst(
            "SELECT COUNT(*) FROM \(unescaped: table)", as: Int.self)
        #expect(total == 3000, "expected 3000, got \(total ?? -1)")
    }

    @Test("dropping a column copies only what remains")
    func dropsAColumn() async throws {
        let connection = try await Self.connect()
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection, rows: 500)
        defer { Task { await Self.cleanUp(connection, table) } }

        try await Self.engine().alter(table: table, "DROP COLUMN score")

        let columns = try await connection.execute(
            MySQLQuery(unsafeSQL: """
                SELECT column_name FROM information_schema.columns
                WHERE table_schema = DATABASE() AND table_name = ? ORDER BY ordinal_position
                """, binds: [.bytes(Array(table.utf8))]),
            as: String.self)
        #expect(columns == ["id", "email"])
        let remaining = try await connection.executeFirst(
            "SELECT COUNT(*) FROM \(unescaped: table)", as: Int.self)
        #expect(remaining == 500)
    }

    @Test("adds an index")
    func addsAnIndex() async throws {
        let connection = try await Self.connect()
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection, rows: 500)
        defer { Task { await Self.cleanUp(connection, table) } }

        try await Self.engine().alter(table: table, "ADD INDEX idx_email (email)")

        let indexes = try await connection.execute(
            MySQLQuery(unsafeSQL: """
                SELECT DISTINCT index_name FROM information_schema.statistics
                WHERE table_schema = DATABASE() AND table_name = ?
                """, binds: [.bytes(Array(table.utf8))]),
            as: String.self)
        #expect(indexes.contains("idx_email"))
    }

    @Test("an empty table is fine")
    func emptyTable() async throws {
        let connection = try await Self.connect()
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection, rows: 0)
        defer { Task { await Self.cleanUp(connection, table) } }

        try await Self.engine().alter(table: table, "ADD COLUMN nickname VARCHAR(64) NULL")
        let count = try await connection.executeFirst(
            "SELECT COUNT(*) FROM \(unescaped: table)", as: Int.self)
        #expect(count == 0)
    }

    // MARK: - Refusals

    /// The copy and the applier both key on a single-column primary key, so a
    /// table without one is refused rather than silently mishandled.
    @Test("a table with no primary key is refused")
    func noPrimaryKeyRefused() async throws {
        let connection = try await Self.connect()
        defer { connection.closeImmediately() }
        let table = "ddl_nopk_\(UInt32.random(in: 0..<UInt32.max))"
        try await connection.query("CREATE TABLE \(table) (a INT, b INT)")
        defer { Task { await Self.cleanUp(connection, table) } }

        await #expect(throws: OnlineDDLError.self) {
            try await Self.engine().alter(table: table, "ADD COLUMN c INT NULL")
        }
    }

    /// A renamed column cannot be matched by name between original and ghost, so
    /// its data would vanish. Refused rather than guessed at.
    @Test("renaming a column is refused")
    func renameRefused() async throws {
        let connection = try await Self.connect()
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection, rows: 10)
        defer { Task { await Self.cleanUp(connection, table) } }

        await #expect(throws: OnlineDDLError.self) {
            try await Self.engine().alter(table: table, "RENAME COLUMN email TO address")
        }
    }

    /// A failure must leave the original untouched — that is the promise that
    /// makes an online tool safe to try.
    @Test("a refused ALTER leaves the original alone")
    func refusalIsNonDestructive() async throws {
        let connection = try await Self.connect()
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection, rows: 100)
        defer { Task { await Self.cleanUp(connection, table) } }

        _ = try? await Self.engine().alter(table: table, "RENAME COLUMN email TO address")

        let columns = try await connection.execute(
            MySQLQuery(unsafeSQL: """
                SELECT column_name FROM information_schema.columns
                WHERE table_schema = DATABASE() AND table_name = ? ORDER BY ordinal_position
                """, binds: [.bytes(Array(table.utf8))]),
            as: String.self)
        #expect(columns == ["id", "email", "score"], "the original is unchanged")
        let intact = try await connection.executeFirst(
            "SELECT COUNT(*) FROM \(unescaped: table)", as: Int.self)
        #expect(intact == 100)
    }
}

/// Connection details for the online-DDL suite.
///
/// Its own helper rather than the MySQL integration target's, because this test
/// target does not depend on that one.
enum OnlineTestSupport {
    static let host = "127.0.0.1"
    static let port = 3306          // mariadb114 — the fixture with log_bin on
    static let database = "swizzle_test"
    static let group = MultiThreadedEventLoopGroup(numberOfThreads: 3)

    static var isAvailable: Bool { probe() }

    static func probe() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var reachable = false
        Task {
            if let connection = try? await connect() {
                connection.closeImmediately()
                reachable = true
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        return reachable
    }

    static func connect() async throws -> MySQLConnection {
        try await MySQLConnection.connect(
            configuration: MySQLConnectionConfiguration(
                address: .hostname(host, port: port),
                username: "native", password: "nativepass",
                database: database, tls: .disable),
            on: group.next())
    }
}

/// `-- +swizzle Online` end to end, through the migrator.
@Suite(
    "Online DDL through migrations",
    .serialized,
    .enabled(if: OnlineTestSupport.isAvailable, "Integration servers not reachable")
)
struct OnlineMigrationTests {

    @Test("an Online migration goes through the runner instead of a locking ALTER")
    func onlineMigrationRuns() async throws {
        let connection = try await OnlineTestSupport.connect()
        defer { connection.closeImmediately() }

        let unique = UInt32.random(in: 0..<UInt32.max)
        let table = "onmig_\(unique)"
        let journal = "journal_\(unique)"
        defer { Task {
            for name in [table, "_\(table)_del", "_\(table)_gho", "_\(table)_ghc", journal] {
                _ = try? await connection.query("DROP TABLE IF EXISTS \(name)")
            }
        } }

        var configuration = Migrator.Configuration()
        configuration.journalTable = journal
        configuration.lockName = "swizzle_online_\(unique)"

        var engine = MySQLOnlineDDL.Configuration()
        engine.chunkSize = 100
        engine.pauseBetweenChunks = .milliseconds(2)
        engine.serverID = UInt32.random(in: 900_000..<999_999)

        let migrator = Migrator(
            executor: try connection.executor(MariaDB.self),
            source: try InMemoryMigrations(files: [
                "1_create.sql": """
                    -- +swizzle Up
                    CREATE TABLE \(table) (id INT AUTO_INCREMENT PRIMARY KEY, email VARCHAR(255));
                    """,
                "2_alter.sql": """
                    -- +swizzle Online
                    -- +swizzle Up
                    ALTER TABLE \(table) ADD COLUMN nickname VARCHAR(64) NULL;
                    """,
            ], syntax: .mysql),
            configuration: configuration,
            onlineRunner: MySQLOnlineDDL(
                connect: { try await OnlineTestSupport.connect() }, configuration: engine)
        )

        try await migrator.up(to: 1)
        try await connection.query("INSERT INTO \(table) (email) VALUES ('a@x'), ('b@x')")

        let applied = try await migrator.up()
        #expect(applied.compactMap(\.version) == [2])

        let columns = try await connection.execute(
            MySQLQuery(unsafeSQL: """
                SELECT column_name FROM information_schema.columns
                WHERE table_schema = DATABASE() AND table_name = ? ORDER BY ordinal_position
                """, binds: [.bytes(Array(table.utf8))]),
            as: String.self)
        #expect(columns == ["id", "email", "nickname"])

        // The retired table proves it went through the shadow-copy path rather
        // than a plain ALTER.
        let retired = try await connection.executeFirst(
            MySQLQuery(unsafeSQL: """
                SELECT COUNT(*) FROM information_schema.tables
                WHERE table_schema = DATABASE() AND table_name = ?
                """, binds: [.bytes(Array("_\(table)_del".utf8))]),
            as: Int.self)
        #expect(retired == 1)
    }

    /// Asking for online and silently getting a locking ALTER is an outage
    /// nobody agreed to, so the absence of a runner is refused.
    @Test("an Online migration with no runner is refused, not downgraded")
    func refusesWithoutRunner() async throws {
        let connection = try await OnlineTestSupport.connect()
        defer { connection.closeImmediately() }

        let unique = UInt32.random(in: 0..<UInt32.max)
        let table = "onmig_\(unique)"
        let journal = "journal_\(unique)"
        defer { Task {
            for name in [table, journal] {
                _ = try? await connection.query("DROP TABLE IF EXISTS \(name)")
            }
        } }

        var configuration = Migrator.Configuration()
        configuration.journalTable = journal
        configuration.lockName = "swizzle_online_\(unique)"

        let migrator = Migrator(
            executor: try connection.executor(MariaDB.self),
            source: try InMemoryMigrations(files: [
                "1_create.sql":
                    "-- +swizzle Up\nCREATE TABLE \(table) (id INT PRIMARY KEY);",
                "2_alter.sql": """
                    -- +swizzle Online
                    -- +swizzle Up
                    ALTER TABLE \(table) ADD COLUMN nickname VARCHAR(64) NULL;
                    """,
            ], syntax: .mysql),
            configuration: configuration)

        do {
            try await migrator.up()
            Issue.record("expected the migration to be refused")
        } catch let error as MigrationError {
            guard case .onlineUnavailable = error.kind else {
                Issue.record("expected onlineUnavailable, got \(error.kind)"); return
            }
            #expect(error.description.contains("outage nobody agreed to"))
        }

        // The column was not added by a fallback path.
        let columns = try await connection.execute(
            MySQLQuery(unsafeSQL: """
                SELECT column_name FROM information_schema.columns
                WHERE table_schema = DATABASE() AND table_name = ?
                """, binds: [.bytes(Array(table.utf8))]),
            as: String.self)
        #expect(columns == ["id"])
    }
}

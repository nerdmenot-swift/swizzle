import SwizzleMySQLEngine
import Foundation
import NIOCore
import NIOPosix
import Testing
import SwizzleCore
@testable import SwizzleMigrate
@testable import SwizzleMySQL

/// The migrator against a real server.
///
/// The parsing tests cover the file format; these cover the parts that only a
/// database can answer — the journal, the lock, ordering, and what actually
/// happens when a migration fails halfway on a database that cannot roll DDL
/// back.
@Suite(
    "Migrations",
    .serialized,
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct MigrationTests {

    /// Each test gets its own journal table and table prefix, so the suite can
    /// run alongside everything else without collisions.
    struct Fixture {
        let connection: MySQLConnection
        let migrator: Migrator
        let prefix: String
        let journal: String
    }

    static func makeFixture(
        _ server: MySQLTestServer,
        files: [String: String],
        configure: (inout Migrator.Configuration) -> Void = { _ in }
    ) async throws -> Fixture {
        let user = server.primaryUser
        let connection = try await MySQLConnection.connect(
            configuration: MySQLConnectionConfiguration(
                address: .hostname(TestServers.host, port: server.port),
                username: user.name, password: user.password,
                database: TestServers.database, tls: .disable,
                serverPublicKey: .requestFromServer
            ),
            on: TestServers.group.next())

        let unique = UInt32.random(in: 0..<UInt32.max)
        let prefix = "m\(unique)_"
        let journal = "journal_\(unique)"

        let substituted = files.mapValues { $0.replacingOccurrences(of: "$T", with: prefix) }
        var configuration = Migrator.Configuration()
        configuration.journalTable = journal
        configuration.lockName = "swizzle_test_\(unique)"
        configure(&configuration)

        return Fixture(
            connection: connection,
            migrator: Migrator(
                executor: try connection.executor(MariaDB.self),
                source: try InMemoryMigrations(files: substituted, syntax: .mysql),
                configuration: configuration),
            prefix: prefix,
            journal: journal)
    }

    static func cleanUp(_ fixture: Fixture, tables: [String]) async {
        for table in tables {
            _ = try? await fixture.connection.query("DROP TABLE IF EXISTS \(fixture.prefix)\(table)")
        }
        _ = try? await fixture.connection.query("DROP TABLE IF EXISTS \(fixture.journal)")
        fixture.connection.closeImmediately()
    }

    static let basicFiles = [
        "1_users.sql": """
        -- +swizzle Up
        CREATE TABLE $Tusers (id INT PRIMARY KEY, email VARCHAR(255) NOT NULL);
        CREATE UNIQUE INDEX $Tusers_email ON $Tusers (email);
        -- +swizzle Down
        DROP TABLE $Tusers;
        """,
        "2_posts.sql": """
        -- +swizzle Up
        CREATE TABLE $Tposts (id INT PRIMARY KEY, title VARCHAR(255));
        -- +swizzle Down
        DROP TABLE $Tposts;
        """,
    ]

    @Test("migrations apply in order and are recorded", arguments: TestServers.mariaDB)
    func applyInOrder(server: MySQLTestServer) async throws {
        let fixture = try await Self.makeFixture(server, files: Self.basicFiles)
        defer { Task { await Self.cleanUp(fixture, tables: ["users", "posts"]) } }

        let applied = try await fixture.migrator.up()
        #expect(applied.compactMap(\.version) == [1, 2])

        // Both tables exist, and the index the second statement created.
        let tables = try await fixture.connection.query(
            "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() "
            + "AND table_name IN ('\(fixture.prefix)users', '\(fixture.prefix)posts')")
        #expect(tables.rows[0][0].int == 2)

        let status = try await fixture.migrator.status()
        #expect(status.count == 2)
        #expect(status.allSatisfy { if case .applied = $0.state { true } else { false } })
    }

    /// The same flow through the `MySQL` dialect rather than `MariaDB`, so both
    /// conformances are exercised. They differ only in the capabilities the
    /// builder exposes; the migration behaviour is identical, which is why the
    /// journal DDL and lock SQL are shared.
    @Test("the MySQL dialect migrates too", arguments: TestServers.mysql)
    func mysqlDialect(server: MySQLTestServer) async throws {
        let user = server.primaryUser
        let connection = try await MySQLConnection.connect(
            configuration: MySQLConnectionConfiguration(
                address: .hostname(TestServers.host, port: server.port),
                username: user.name, password: user.password,
                database: TestServers.database, tls: .disable,
                serverPublicKey: .requestFromServer
            ),
            on: TestServers.group.next())
        let unique = UInt32.random(in: 0..<UInt32.max)
        let prefix = "my\(unique)_"
        let journal = "journal_\(unique)"
        defer {
            Task {
                _ = try? await connection.query("DROP TABLE IF EXISTS \(prefix)users")
                _ = try? await connection.query("DROP TABLE IF EXISTS \(journal)")
                connection.closeImmediately()
            }
        }

        var configuration = Migrator.Configuration()
        configuration.journalTable = journal
        configuration.lockName = "swizzle_test_\(unique)"

        let migrator = Migrator(
            executor: try connection.executor(MySQL.self),
            source: try InMemoryMigrations(files: [
                "1_users.sql": "-- +swizzle Up\nCREATE TABLE \(prefix)users (id INT PRIMARY KEY);"
                    + "\n-- +swizzle Down\nDROP TABLE \(prefix)users;"
            ], syntax: .mysql),
            configuration: configuration)

        #expect(try await migrator.up().compactMap(\.version) == [1])
        #expect(try await migrator.up().isEmpty)
        #expect(try await migrator.down().compactMap(\.version) == [1])
        #expect(try await migrator.status().allSatisfy(\.isPending))
    }

    /// Running twice must be a no-op, because a deploy runs migrations on every
    /// boot.
    @Test("a second run applies nothing")
    func idempotent() async throws {
        let fixture = try await Self.makeFixture(TestServers.latest, files: Self.basicFiles)
        defer { Task { await Self.cleanUp(fixture, tables: ["users", "posts"]) } }

        #expect(try await fixture.migrator.up().count == 2)
        #expect(try await fixture.migrator.up().isEmpty, "nothing left to do is success")
    }

    @Test("down reverts the newest migration")
    func downReverts() async throws {
        let fixture = try await Self.makeFixture(TestServers.latest, files: Self.basicFiles)
        defer { Task { await Self.cleanUp(fixture, tables: ["users", "posts"]) } }

        try await fixture.migrator.up()
        let reverted = try await fixture.migrator.down()
        #expect(reverted.compactMap(\.version) == [2], "newest first")

        let status = try await fixture.migrator.status()
        #expect(status.first { $0.version == 2 }?.isPending == true)
        #expect(status.first { $0.version == 1 }?.isPending == false)

        // And the table is really gone.
        let remaining = try await fixture.connection.query(
            "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() "
            + "AND table_name = '\(fixture.prefix)posts'")
        #expect(remaining.rows[0][0].int == 0)
    }

    @Test("down to a version reverts everything above it")
    func downToVersion() async throws {
        let fixture = try await Self.makeFixture(TestServers.latest, files: Self.basicFiles)
        defer { Task { await Self.cleanUp(fixture, tables: ["users", "posts"]) } }

        try await fixture.migrator.up()
        let reverted = try await fixture.migrator.down(to: 1)
        #expect(reverted.compactMap(\.version) == [2, 1])
        #expect(try await fixture.migrator.status().allSatisfy(\.isPending))
    }

    /// A `Down`-less migration is legal, and reverting it must fail loudly
    /// rather than silently skipping.
    @Test("reverting an irreversible migration is refused")
    func irreversibleRefused() async throws {
        let fixture = try await Self.makeFixture(TestServers.latest, files: [
            "1_t.sql": "-- +swizzle Up\nCREATE TABLE $Tonly (id INT);"
        ])
        defer { Task { await Self.cleanUp(fixture, tables: ["only"]) } }

        try await fixture.migrator.up()
        await #expect(throws: MigrationError.self) { try await fixture.migrator.down() }
    }

    /// Editing a migration that already ran leaves every existing database on
    /// the old version of it and every new one on the new version, with nothing
    /// in the schema to say so.
    @Test("an edited migration is detected")
    func checksumDrift() async throws {
        let fixture = try await Self.makeFixture(TestServers.latest, files: [
            "1_t.sql": "-- +swizzle Up\nCREATE TABLE $Tdrift (id INT);\n-- +swizzle Down\nDROP TABLE $Tdrift;"
        ])
        defer { Task { await Self.cleanUp(fixture, tables: ["drift"]) } }
        try await fixture.migrator.up()

        // Same version, different body.
        var edited = fixture.migrator
        edited = Migrator(
            executor: try fixture.connection.executor(MariaDB.self),
            source: try InMemoryMigrations(files: [
                "1_t.sql": "-- +swizzle Up\nCREATE TABLE \(fixture.prefix)drift (id BIGINT);"
                    + "\n-- +swizzle Down\nDROP TABLE \(fixture.prefix)drift;"
            ], syntax: .mysql),
            configuration: fixture.migrator.configuration)

        let status = try await edited.status()
        guard case .modified = status[0].state else {
            Issue.record("expected the edit to be reported, got \(status[0].state)"); return
        }
        await #expect(throws: MigrationError.self) { try await edited.up() }

        // And it can be overridden deliberately.
        var permissive = edited.configuration
        permissive.verifyChecksums = false
        let allowed = Migrator(
            executor: try fixture.connection.executor(MariaDB.self),
            source: try InMemoryMigrations(files: [
                "1_t.sql": "-- +swizzle Up\nSELECT 1;"], syntax: .mysql),
            configuration: permissive)
        #expect(try await allowed.up().isEmpty, "already applied, so still nothing to do")
    }

    /// The branch-merge case: 2 lands and deploys, then 1 merges. Applying 1 now
    /// runs it against a schema it was never written for.
    @Test("a migration older than one already applied is refused")
    func outOfOrderRefused() async throws {
        let fixture = try await Self.makeFixture(TestServers.latest, files: [
            "2_later.sql": "-- +swizzle Up\nCREATE TABLE $Tlater (id INT);"
                + "\n-- +swizzle Down\nDROP TABLE $Tlater;"
        ])
        defer { Task { await Self.cleanUp(fixture, tables: ["later", "earlier"]) } }
        try await fixture.migrator.up()

        let merged = Migrator(
            executor: try fixture.connection.executor(MariaDB.self),
            source: try InMemoryMigrations(files: [
                "1_earlier.sql": "-- +swizzle Up\nCREATE TABLE \(fixture.prefix)earlier (id INT);",
                "2_later.sql": "-- +swizzle Up\nCREATE TABLE \(fixture.prefix)later (id INT);"
                    + "\n-- +swizzle Down\nDROP TABLE \(fixture.prefix)later;",
            ], syntax: .mysql),
            configuration: fixture.migrator.configuration)

        await #expect(throws: MigrationError.self) { try await merged.up() }
    }

    /// The honest part. MySQL commits implicitly on DDL, so a migration that
    /// fails on its second statement leaves the first one applied — and the
    /// error has to say so rather than implying a rollback happened.
    @Test("a partial failure is reported as partial")
    func partialFailureIsHonest() async throws {
        let fixture = try await Self.makeFixture(TestServers.latest, files: [
            "1_bad.sql": """
            -- +swizzle Up
            CREATE TABLE $Tpartial (id INT PRIMARY KEY);
            THIS IS NOT SQL;
            """
        ])
        defer { Task { await Self.cleanUp(fixture, tables: ["partial"]) } }

        do {
            try await fixture.migrator.up()
            Issue.record("expected the bad statement to fail")
        } catch let error as MigrationError {
            guard case .statementFailed(let index, _, let partial) = error.kind else {
                Issue.record("expected statementFailed, got \(error.kind)"); return
            }
            #expect(index == 1, "the second statement failed")
            #expect(partial, "the first statement is committed and cannot be rolled back")
            #expect(error.description.contains("CANNOT be rolled back"))
        }

        // The first table really is there — which is exactly what the error said.
        let exists = try await fixture.connection.query(
            "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() "
            + "AND table_name = '\(fixture.prefix)partial'")
        #expect(exists.rows[0][0].int == 1)

        // And the migration is not recorded, so it will be retried.
        #expect(try await fixture.migrator.status()[0].isPending)
    }

    /// Drizzle's biggest gap: without a lock, two pods rolling out together both
    /// read an empty journal and both apply migration 1.
    @Test("a concurrent migrator waits rather than double-applying")
    func lockSerialisesConcurrentMigrators() async throws {
        let fixture = try await Self.makeFixture(TestServers.latest, files: Self.basicFiles)
        defer { Task { await Self.cleanUp(fixture, tables: ["users", "posts"]) } }

        // A second connection running the same migrations at the same time.
        let user = TestServers.latest.primaryUser
        let other = try await MySQLConnection.connect(
            configuration: MySQLConnectionConfiguration(
                address: .hostname(TestServers.host, port: TestServers.latest.port),
                username: user.name, password: user.password,
                database: TestServers.database, tls: .disable,
                serverPublicKey: .requestFromServer
            ),
            on: TestServers.group.next())
        defer { other.closeImmediately() }

        let second = Migrator(
            executor: try other.executor(MariaDB.self),
            source: fixture.migrator.source,
            configuration: fixture.migrator.configuration)

        async let first = fixture.migrator.up()
        async let concurrent = second.up()
        let results = try await [first, concurrent]

        // Exactly one applied them; the other found nothing to do. Without the
        // lock both would apply migration 1 and the second would fail on
        // "table already exists".
        let counts = results.map(\.count).sorted()
        #expect(counts == [0, 2], "one applied both, the other applied none — got \(counts)")
    }

    // MARK: - Repeatable

    /// The point of repeatable migrations: a view lives in one file that reads
    /// like source code, and changing it re-runs it.
    @Test("a repeatable migration re-runs when its file changes")
    func repeatableReRuns() async throws {
        let fixture = try await Self.makeFixture(TestServers.latest, files: [
            "1_base.sql": "-- +swizzle Up\nCREATE TABLE $Tsrc (id INT, n INT);"
                + "\n-- +swizzle Down\nDROP TABLE $Tsrc;",
            "R__view.sql": "-- +swizzle Up\nCREATE OR REPLACE VIEW $Tv AS SELECT id FROM $Tsrc;",
        ])
        defer { Task {
            _ = try? await fixture.connection.query("DROP VIEW IF EXISTS \(fixture.prefix)v")
            await Self.cleanUp(fixture, tables: ["src"])
        } }

        #expect(try await fixture.migrator.up().count == 2)
        // Unchanged, so a second run does nothing.
        #expect(try await fixture.migrator.up().isEmpty)

        // Change the view: same file name, new body.
        let changed = Migrator(
            executor: try fixture.connection.executor(MariaDB.self),
            source: try InMemoryMigrations(files: [
                "1_base.sql": "-- +swizzle Up\nCREATE TABLE \(fixture.prefix)src (id INT, n INT);"
                    + "\n-- +swizzle Down\nDROP TABLE \(fixture.prefix)src;",
                "R__view.sql": "-- +swizzle Up\nCREATE OR REPLACE VIEW \(fixture.prefix)v AS "
                    + "SELECT id, n FROM \(fixture.prefix)src;",
            ], syntax: .mysql),
            configuration: fixture.migrator.configuration)

        // Reported as changed rather than as drift — editing a repeatable
        // migration is how you work, not a problem.
        let status = try await changed.status()
        let view = try #require(status.first { $0.isRepeatable })
        guard case .outdated = view.state else {
            Issue.record("expected .outdated, got \(view.state)"); return
        }

        let applied = try await changed.up()
        #expect(applied.map(\.identifier) == ["R__view"], "only the view re-runs")

        // The new column is really there.
        let columns = try await fixture.connection.query(
            "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema = DATABASE() "
            + "AND table_name = '\(fixture.prefix)v'")
        #expect(columns.rows[0][0].int == 2)

        #expect(try await changed.up().isEmpty, "stable once re-applied")
    }

    /// Repeatable migrations run after every versioned one, because a view
    /// almost always depends on a table a versioned migration just made.
    @Test("a repeatable migration runs after the versioned ones it depends on")
    func repeatableRunsLast() async throws {
        let fixture = try await Self.makeFixture(TestServers.latest, files: [
            "R__view.sql": "-- +swizzle Up\nCREATE OR REPLACE VIEW $Tv AS SELECT id FROM $Tlate;",
            "1_late.sql": "-- +swizzle Up\nCREATE TABLE $Tlate (id INT);"
                + "\n-- +swizzle Down\nDROP TABLE $Tlate;",
        ])
        defer { Task {
            _ = try? await fixture.connection.query("DROP VIEW IF EXISTS \(fixture.prefix)v")
            await Self.cleanUp(fixture, tables: ["late"])
        } }

        // Would fail if the view ran first — the table would not exist yet.
        let applied = try await fixture.migrator.up()
        #expect(applied.map(\.identifier) == ["1", "R__view"])
    }

    @Test("down ignores repeatable migrations")
    func downIgnoresRepeatable() async throws {
        let fixture = try await Self.makeFixture(TestServers.latest, files: [
            "1_base.sql": "-- +swizzle Up\nCREATE TABLE $Tsrc (id INT);"
                + "\n-- +swizzle Down\nDROP TABLE $Tsrc;",
            "R__view.sql": "-- +swizzle Up\nCREATE OR REPLACE VIEW $Tv AS SELECT id FROM $Tsrc;",
        ])
        defer { Task {
            _ = try? await fixture.connection.query("DROP VIEW IF EXISTS \(fixture.prefix)v")
            await Self.cleanUp(fixture, tables: ["src"])
        } }

        try await fixture.migrator.up()
        let reverted = try await fixture.migrator.down(count: 5)
        #expect(reverted.map(\.identifier) == ["1"], "the view is not reverted")
    }

    // MARK: - Baseline, plan, redo

    /// How an existing database adopts Swizzle: the tables are already there, so
    /// the migrations that would create them must be recorded, not run.
    @Test("baseline records migrations without running them")
    func baselineRecordsWithoutRunning() async throws {
        let fixture = try await Self.makeFixture(TestServers.latest, files: Self.basicFiles)
        defer { Task { await Self.cleanUp(fixture, tables: ["users", "posts"]) } }

        // Pretend the schema already exists by baselining past migration 1
        // without ever creating its table.
        let marked = try await fixture.migrator.baseline(to: 1)
        #expect(marked.compactMap(\.version) == [1])

        let existsAfterBaseline = try await fixture.connection.query(
            "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() "
            + "AND table_name = '\(fixture.prefix)users'")
        #expect(existsAfterBaseline.rows[0][0].int == 0, "baseline must not run anything")

        // And `up` now skips it and applies only what follows.
        let applied = try await fixture.migrator.up()
        #expect(applied.compactMap(\.version) == [2])
    }

    @Test("baseline is idempotent")
    func baselineIsIdempotent() async throws {
        let fixture = try await Self.makeFixture(TestServers.latest, files: Self.basicFiles)
        defer { Task { await Self.cleanUp(fixture, tables: ["users", "posts"]) } }

        #expect(try await fixture.migrator.baseline(to: 2).count == 2)
        #expect(try await fixture.migrator.baseline(to: 2).isEmpty)
        #expect(try await fixture.migrator.up().isEmpty)
    }

    /// A dry run must produce exactly what `up` would, and change nothing.
    @Test("plan matches up, and changes nothing")
    func planChangesNothing() async throws {
        let fixture = try await Self.makeFixture(TestServers.latest, files: Self.basicFiles)
        defer { Task { await Self.cleanUp(fixture, tables: ["users", "posts"]) } }

        let planned = try await fixture.migrator.plan()
        #expect(planned.compactMap(\.version) == [1, 2])

        // Still pending — planning is read-only.
        #expect(try await fixture.migrator.status().allSatisfy(\.isPending))

        let applied = try await fixture.migrator.up()
        #expect(applied.map(\.identifier) == planned.map(\.identifier))
        #expect(try await fixture.migrator.plan().isEmpty)
    }

    /// The development loop: apply, find it wrong, edit, run again.
    @Test("redo reverts and re-applies the newest migration")
    func redoRunsAgain() async throws {
        let fixture = try await Self.makeFixture(TestServers.latest, files: Self.basicFiles)
        defer { Task { await Self.cleanUp(fixture, tables: ["users", "posts"]) } }

        try await fixture.migrator.up()
        let redone = try await fixture.migrator.redo()
        #expect(redone.compactMap(\.version) == [2])

        // Everything is still applied afterwards.
        #expect(try await fixture.migrator.status().allSatisfy { !$0.isPending })

        // And the table really was dropped and recreated.
        let exists = try await fixture.connection.query(
            "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() "
            + "AND table_name = '\(fixture.prefix)posts'")
        #expect(exists.rows[0][0].int == 1)
    }
}

/// Swift migrations — the narrow code path.
///
/// The point being tested is that they are *not* a second mechanism: they share
/// the version space, the journal, the lock and `status` with SQL migrations.
@Suite(
    "Swift migrations",
    .serialized,
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct SwiftMigrationTests {

    /// A data transformation of the kind that genuinely needs code: derive a
    /// value from another column by rules SQL does not have.
    struct Backfill: SwiftMigration {
        static let version: Int64 = 2
        static let name = "backfill_slugs"
        let table: String

        func up(_ db: some MigrationContext) async throws {
            try await db.batches(over: table, selecting: "id, title", size: 10) { rows in
                for row in rows {
                    guard case .int(let id) = row.values[0] else { continue }
                    let title = row.values.count > 1 ? Self.text(row.values[1]) : ""
                    let slug = title.lowercased().replacingOccurrences(of: " ", with: "-")
                    try await db.executeUpdate(
                        "UPDATE \(table) SET slug = ? WHERE id = ?", [.text(slug), .int(id)]
                    )
                }
            }
        }

        static func text(_ value: SQLValue) -> String {
            if case .text(let raw) = value { return raw }
            if case .blob(let bytes) = value { return String(decoding: bytes, as: UTF8.self) }
            return ""
        }
    }

    /// Declares a real revert, so `down` works rather than refusing.
    struct Reversible: ReversibleSwiftMigration {
        static let version: Int64 = 2
        static let name = "reversible"
        let table: String

        func up(_ db: some MigrationContext) async throws {
            try await db.executeUpdate("UPDATE \(table) SET slug = 'set'")
        }
        func down(_ db: some MigrationContext) async throws {
            try await db.executeUpdate("UPDATE \(table) SET slug = NULL")
        }
    }

    struct Failing: SwiftMigration {
        static let version: Int64 = 2
        static let name = "failing"
        func up(_ db: some MigrationContext) async throws {
            try await db.executeUpdate("THIS IS NOT SQL")
        }
    }

    static func fixture(
        _ swift: [any SwiftMigration], prefix: String, journal: String
    ) async throws -> (MySQLConnection, Migrator) {
        let server = TestServers.latest
        let user = server.primaryUser
        let connection = try await MySQLConnection.connect(
            configuration: MySQLConnectionConfiguration(
                address: .hostname(TestServers.host, port: server.port),
                username: user.name, password: user.password,
                database: TestServers.database, tls: .disable,
                serverPublicKey: .requestFromServer
            ),
            on: TestServers.group.next())

        var configuration = Migrator.Configuration()
        configuration.journalTable = journal
        configuration.lockName = "swizzle_swift_\(journal)"

        let sql = try InMemoryMigrations(files: [
            "1_posts.sql": """
                -- +swizzle Up
                CREATE TABLE \(prefix)posts (
                    id INT AUTO_INCREMENT PRIMARY KEY, title VARCHAR(64), slug VARCHAR(64) NULL
                );
                -- +swizzle Down
                DROP TABLE \(prefix)posts;
                """
        ], syntax: .mysql)

        return (
            connection,
            Migrator(
                executor: try connection.executor(MariaDB.self),
                source: CombinedMigrations([sql, SwiftMigrations(swift)]),
                configuration: configuration)
        )
    }

    /// The whole design goal: SQL and Swift migrations interleave by version,
    /// under one journal.
    @Test("a Swift migration runs in version order with the SQL ones")
    func interleavesWithSQL() async throws {
        let unique = UInt32.random(in: 0..<UInt32.max)
        let prefix = "sw\(unique)_"
        let journal = "journal_\(unique)"
        let (connection, migrator) = try await Self.fixture(
            [Backfill(table: "\(prefix)posts")], prefix: prefix, journal: journal)
        defer { Task {
            _ = try? await connection.query("DROP TABLE IF EXISTS \(prefix)posts")
            _ = try? await connection.query("DROP TABLE IF EXISTS \(journal)")
            connection.closeImmediately()
        } }

        // Migration 1 creates the table and the Swift migration at 2 backfills
        // it. That the second can see what the first made is the whole point:
        // they are one ordering, not two tools that happen to run nearby.
        let applied = try await migrator.up()
        #expect(applied.map(\.identifier) == ["1", "2"], "interleaved by version")
        #expect(applied[0].isSwift == false)
        #expect(applied[1].isSwift)

        // One journal, one status list, both kinds in it.
        let statuses = try await migrator.status()
        #expect(statuses.map(\.identifier) == ["1", "2"])
        #expect(statuses.allSatisfy { !$0.isPending }, "both recorded as applied")

        // And a second run is a no-op for both.
        #expect(try await migrator.up().isEmpty)
    }

    @Test("a Swift migration transforms data")
    func transformsData() async throws {
        let unique = UInt32.random(in: 0..<UInt32.max)
        let prefix = "sw\(unique)_"
        let journal = "journal_\(unique)"

        // Seed before the Swift migration runs, by applying only migration 1.
        let (connection, migrator) = try await Self.fixture(
            [Backfill(table: "\(prefix)posts")], prefix: prefix, journal: journal)
        defer { Task {
            _ = try? await connection.query("DROP TABLE IF EXISTS \(prefix)posts")
            _ = try? await connection.query("DROP TABLE IF EXISTS \(journal)")
            connection.closeImmediately()
        } }

        try await migrator.up(to: 1)
        try await connection.query(
            "INSERT INTO \(prefix)posts (title) VALUES ('Hello World'), ('Another Post')")

        let applied = try await migrator.up()
        #expect(applied.compactMap(\.version) == [2])

        let rows = try await connection.query(
            "SELECT slug FROM \(prefix)posts ORDER BY id")
        #expect(rows.rows.map { $0[0].string } == ["hello-world", "another-post"])
    }

    /// Keyset pagination has to cover every row when the table is larger than
    /// one batch, and must not loop forever on the last partial batch.
    @Test("batching walks every row exactly once")
    func batchingCoversEverything() async throws {
        let unique = UInt32.random(in: 0..<UInt32.max)
        let prefix = "sw\(unique)_"
        let journal = "journal_\(unique)"
        let (connection, migrator) = try await Self.fixture(
            [Backfill(table: "\(prefix)posts")], prefix: prefix, journal: journal)
        defer { Task {
            _ = try? await connection.query("DROP TABLE IF EXISTS \(prefix)posts")
            _ = try? await connection.query("DROP TABLE IF EXISTS \(journal)")
            connection.closeImmediately()
        } }

        try await migrator.up(to: 1)
        // 25 rows against a batch size of 10: two full batches and a partial.
        let values = (0..<25).map { "('Post \($0)')" }.joined(separator: ",")
        try await connection.query("INSERT INTO \(prefix)posts (title) VALUES \(values)")

        try await migrator.up()

        let done = try await connection.query(
            "SELECT COUNT(*) FROM \(prefix)posts WHERE slug IS NOT NULL")
        #expect(done.rows[0][0].int == 25, "every row was visited")

        let distinct = try await connection.query(
            "SELECT COUNT(DISTINCT slug) FROM \(prefix)posts")
        #expect(distinct.rows[0][0].int == 25, "and none was visited twice with a stale value")
    }

    /// Default `down` refuses, matching a SQL migration with no Down section.
    @Test("a Swift migration is irreversible unless it says otherwise")
    func irreversibleByDefault() async throws {
        let unique = UInt32.random(in: 0..<UInt32.max)
        let prefix = "sw\(unique)_"
        let journal = "journal_\(unique)"
        let (connection, migrator) = try await Self.fixture(
            [Backfill(table: "\(prefix)posts")], prefix: prefix, journal: journal)
        defer { Task {
            _ = try? await connection.query("DROP TABLE IF EXISTS \(prefix)posts")
            _ = try? await connection.query("DROP TABLE IF EXISTS \(journal)")
            connection.closeImmediately()
        } }

        try await migrator.up()
        await #expect(throws: MigrationError.self) { try await migrator.down() }
    }

    @Test("a ReversibleSwiftMigration can be reverted")
    func reversibleReverts() async throws {
        let unique = UInt32.random(in: 0..<UInt32.max)
        let prefix = "sw\(unique)_"
        let journal = "journal_\(unique)"
        let (connection, migrator) = try await Self.fixture(
            [Reversible(table: "\(prefix)posts")], prefix: prefix, journal: journal)
        defer { Task {
            _ = try? await connection.query("DROP TABLE IF EXISTS \(prefix)posts")
            _ = try? await connection.query("DROP TABLE IF EXISTS \(journal)")
            connection.closeImmediately()
        } }

        try await migrator.up(to: 1)
        try await connection.query("INSERT INTO \(prefix)posts (title) VALUES ('x')")
        try await migrator.up()
        #expect(try await connection.query("SELECT slug FROM \(prefix)posts").rows[0][0].string == "set")

        let reverted = try await migrator.down()
        #expect(reverted.compactMap(\.version) == [2])
        #expect(try await connection.query("SELECT slug FROM \(prefix)posts").rows[0][0].isNull)
    }

    /// A failure is opaque — no statement index — and the message says so
    /// rather than implying the precision the SQL path has.
    @Test("a failing Swift migration reports honestly and is not recorded")
    func failureIsHonest() async throws {
        let unique = UInt32.random(in: 0..<UInt32.max)
        let prefix = "sw\(unique)_"
        let journal = "journal_\(unique)"
        let (connection, migrator) = try await Self.fixture(
            [Failing()], prefix: prefix, journal: journal)
        defer { Task {
            _ = try? await connection.query("DROP TABLE IF EXISTS \(prefix)posts")
            _ = try? await connection.query("DROP TABLE IF EXISTS \(journal)")
            connection.closeImmediately()
        } }

        do {
            try await migrator.up()
            Issue.record("expected the Swift migration to fail")
        } catch let error as MigrationError {
            guard case .swiftMigrationFailed = error.kind else {
                Issue.record("expected swiftMigrationFailed, got \(error.kind)"); return
            }
            #expect(error.description.contains("opaque"))
        }

        // Not recorded, so it retries — same contract as a failed SQL migration.
        let status = try await migrator.status()
        #expect(status.first { $0.version == 2 }?.isPending == true)
    }

    /// Sharing the version space means a collision is caught rather than
    /// resolved by whichever source happened to load first.
    @Test("a Swift and a SQL migration cannot claim the same version")
    func versionCollisionRefused() throws {
        let sql = try InMemoryMigrations(
            files: ["2_taken.sql": "-- +swizzle Up\nSELECT 1;"], syntax: .mysql)
        let combined = CombinedMigrations([sql, SwiftMigrations([Failing()])])
        #expect(throws: MigrationParseError.self) { try combined.load() }
    }
}

/// Introspection and schema-aware linting.
@Suite(
    "Schema introspection",
    .serialized,
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct IntrospectionTests {

    static func connect(_ server: MySQLTestServer) async throws -> MySQLConnection {
        let user = server.primaryUser
        return try await MySQLConnection.connect(
            configuration: MySQLConnectionConfiguration(
                address: .hostname(TestServers.host, port: server.port),
                username: user.name, password: user.password,
                database: TestServers.database, tls: .disable,
                serverPublicKey: .requestFromServer
            ),
            on: TestServers.group.next())
    }

    @Test("reads columns, indexes and row estimates", arguments: TestServers.mariaDB)
    func readsTheSchema(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        let table = "intro_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        try await connection.query("""
            CREATE TABLE \(table) (
                id INT AUTO_INCREMENT PRIMARY KEY,
                email VARCHAR(255) NOT NULL,
                nickname VARCHAR(64) NULL,
                score INT NOT NULL DEFAULT 0,
                UNIQUE KEY uniq_email (email),
                KEY idx_pair (nickname, score)
            )
            """)

        let schema = try await MySQLIntrospector(
            executor: try connection.executor(MariaDB.self)
        ).schema()
        let found = try #require(schema.table(named: table))

        #expect(found.columns.map(\.name) == ["id", "email", "nickname", "score"])
        #expect(try #require(found.column(named: "id")).isAutoIncrement)
        #expect(try #require(found.column(named: "nickname")).isNullable)
        #expect(!(try #require(found.column(named: "email")).isNullable))
        #expect(try #require(found.column(named: "score")).hasDefault)
        #expect(!(try #require(found.column(named: "email")).hasDefault))

        #expect(try #require(found.primaryKey).columns == ["id"])
        let unique = try #require(found.indexes.first { $0.name == "uniq_email" })
        #expect(unique.isUnique)
        // A composite index is several information_schema rows and must come
        // back as one index in column order.
        let pair = try #require(found.indexes.first { $0.name == "idx_pair" })
        #expect(pair.columns == ["nickname", "score"])
        #expect(!pair.isUnique)
    }

    /// `information_schema` is standard enough that the same queries work on
    /// both flavours, but "standard enough" is worth asserting rather than
    /// assuming.
    @Test("the same introspection works on MySQL", arguments: TestServers.mysql)
    func worksOnMySQL(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        let table = "intro_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        try await connection.query("""
            CREATE TABLE \(table) (
                id INT AUTO_INCREMENT PRIMARY KEY,
                email VARCHAR(255) NOT NULL,
                UNIQUE KEY uniq_email (email)
            )
            """)

        let schema = try await MySQLIntrospector(
            executor: try connection.executor(MySQL.self)
        ).schema()
        let found = try #require(schema.table(named: table))
        #expect(found.columns.map(\.name) == ["id", "email"])
        #expect(try #require(found.primaryKey).columns == ["id"])
        #expect(try #require(found.indexes.first { $0.name == "uniq_email" }).isUnique)
    }

    /// The reason introspection exists: the same statement is a warning against
    /// an empty table and an error against a populated one.
    @Test("row counts change the verdict")
    func rowCountsChangeSeverity() async throws {
        let connection = try await Self.connect(TestServers.latest)
        defer { connection.closeImmediately() }
        let table = "intro_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        try await connection.query(
            "CREATE TABLE \(table) (id INT AUTO_INCREMENT PRIMARY KEY, email VARCHAR(255))")

        let executor = try connection.executor(MariaDB.self)
        let migration = Migration(
            kind: .versioned(1), name: "drop",
            up: .sql(["DROP TABLE \(table)"]), down: nil, checksum: "x")

        let empty = Linter().lint(
            [migration], schema: try await MySQLIntrospector(executor: executor).schema())
        #expect(empty.first?.severity == .warning, "an empty table is cleanup")

        // Enough rows that the estimate is reliably non-zero.
        let values = (0..<2000).map { "('u\($0)@x')" }.joined(separator: ",")
        try await connection.query("INSERT INTO \(table) (email) VALUES \(values)")
        try await connection.query("ANALYZE TABLE \(table)")

        let populated = Linter().lint(
            [migration], schema: try await MySQLIntrospector(executor: executor).schema())
        #expect(populated.first?.severity == .error, "dropping real data is not cleanup")
    }

    /// A MySQL connection carries one command at a time, so introspection has to
    /// be sequential. Running it beside a live query is the shape that caught
    /// the original mistake.
    @Test("introspection works on a connection that is already in use")
    func worksSequentially() async throws {
        let connection = try await Self.connect(TestServers.latest)
        defer { connection.closeImmediately() }
        let executor = try connection.executor(MariaDB.self)

        _ = try await connection.query("SELECT 1")
        let schema = try await MySQLIntrospector(executor: executor).schema()
        _ = try await connection.query("SELECT 1")
        #expect(!schema.tables.isEmpty)
    }
}

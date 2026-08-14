import Foundation
import SwizzleCore
import SwizzleMigrate
import Testing

@testable import SwizzleSQLite
@testable import SwizzleSQLiteEngine

/// The `examples/` wiring, actually run.
///
/// The Swift examples compile because they are a build target, and the SQL
/// examples parse because `ExampleMigrationTests` parses them. Neither proves
/// the two halves work *together* — that a SQL migration and a Swift migration
/// interleave by version, share one journal, and leave the database in the state
/// the files describe.
///
/// This runs them. A compiled example that cannot be applied is still a broken
/// example, and the runner is the piece a newcomer copies first.
@Suite("Example runner")
struct ExampleRunnerTests {

    /// A directory of SQLite-flavoured migrations, mirroring `examples/migrations`
    /// in shape.
    ///
    /// Not the example files themselves: those are deliberately
    /// Postgres-flavoured — `CREATE INDEX CONCURRENTLY`, a plpgsql body — because
    /// that is what their directives exist to demonstrate, and SQLite cannot run
    /// them. What is under test here is the *wiring*, so the SQL is the portable
    /// subset and `ExampleMigrationTests` covers the real files' directives.
    static func writeMigrations(into directory: URL) throws {
        try """
        -- +swizzle Up
        CREATE TABLE users (
            id    INTEGER PRIMARY KEY,
            email TEXT NOT NULL,
            slug  TEXT
        );
        -- +swizzle Down
        DROP TABLE users;
        """.write(
            to: directory.appendingPathComponent("00001_create_users.sql"),
            atomically: true, encoding: .utf8
        )

        try """
        -- +swizzle Up
        INSERT INTO users (id, email) VALUES (1, 'Ada.Lovelace@Example.com');
        INSERT INTO users (id, email) VALUES (2, 'Alan.Turing@Example.com');
        -- +swizzle Down
        DELETE FROM users;
        """.write(
            to: directory.appendingPathComponent("00002_seed.sql"),
            atomically: true, encoding: .utf8
        )
    }

    /// The Swift halves of the example, at versions after the SQL ones so the
    /// interleaving is observable.
    struct Backfill: SwiftMigration {
        static let version: Int64 = 5
        static let name = "backfill_slugs"
        static let usesTransaction = false

        func up(_ db: some MigrationContext) async throws {
            try await db.batches(over: "users", selecting: "id, email", size: 1) { rows in
                for row in rows {
                    guard case .int(let id) = row.values[0],
                        case .text(let email) = row.values[1]
                    else { continue }
                    let slug = email.lowercased().replacingOccurrences(of: "@", with: "-at-")
                    try await db.executeUpdate(
                        "UPDATE users SET slug = ?1 WHERE id = ?2", [.text(slug), .int(id)]
                    )
                }
            }
        }
    }

    struct Normalise: ReversibleSwiftMigration {
        static let version: Int64 = 6
        static let name = "normalise_emails"
        func up(_ db: some MigrationContext) async throws {
            try await db.executeUpdate("UPDATE users SET email = LOWER(email)")
        }
        func down(_ db: some MigrationContext) async throws {}
    }

    static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swizzle-example-\(UInt32.random(in: 0..<UInt32.max))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// **The end-to-end claim.** Two SQL migrations and two Swift ones, one
    /// journal, applied in version order, with the Swift ones seeing what the SQL
    /// ones did.
    @Test("SQL and Swift migrations run together in one pass")
    func runsBothForms() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.writeMigrations(into: directory)
        let databasePath = directory.appendingPathComponent("app.db").path

        // Through the engine, which is what creates SQLite's lock table. Going
        // around it — `SQLiteConnection(path:)` plus a `Migrator` — fails at the
        // first `acquireLock`, and that is exactly the trap this example exists
        // to steer past.
        let connection = try await SQLiteEngine.connect(url: "sqlite://\(databasePath)")
        defer { connection.close() }

        let migrator = Migrator(
            executor: connection.executor,
            dialect: connection.dialect,
            source: CombinedMigrations([
                MigrationDirectory(url: directory, syntax: SQLite.migrationSyntax),
                SwiftMigrations([Backfill(), Normalise()]),
            ])
        )

        let applied = try await migrator.up()
        #expect(applied.map(\.version) == [1, 2, 5, 6], "version order across both forms")

        // The Swift migrations saw the SQL migrations' rows, and each other's
        // work: the backfill ran before the lower-casing, so the slug keeps the
        // original case and the email does not.
        let rows = try await connection.executor.execute(
            sql: "SELECT email, slug FROM users ORDER BY id", bindings: []
        )
        #expect(rows.count == 2)
        #expect(rows[0].values[0] == .text("ada.lovelace@example.com"))
        #expect(rows[0].values[1] == .text("ada.lovelace-at-example.com"))
    }

    /// Applying twice is a no-op — the journal is shared, so a Swift migration is
    /// recorded exactly like a SQL one.
    @Test("a second run applies nothing")
    func idempotent() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.writeMigrations(into: directory)
        let databasePath = directory.appendingPathComponent("app.db").path

        let connection = try await SQLiteEngine.connect(url: "sqlite://\(databasePath)")
        defer { connection.close() }
        let source = CombinedMigrations([
            MigrationDirectory(url: directory, syntax: SQLite.migrationSyntax),
            SwiftMigrations([Backfill(), Normalise()]),
        ])
        let migrator = Migrator(
            executor: connection.executor, dialect: connection.dialect, source: source
        )

        #expect(try await migrator.up().count == 4)
        #expect(try await migrator.up().isEmpty, "the journal did not record the Swift ones")

        // And status reports all four as applied, from one list.
        let status = try await migrator.status()
        #expect(status.count == 4)
        for entry in status {
            if case .pending = entry.state {
                Issue.record("\(entry.version) \(entry.name) still pending")
            }
        }
    }

    /// Two migrations claiming one version is caught, which is the reason the
    /// two forms share a version space rather than having one each.
    @Test("a version claimed by both forms is refused")
    func versionCollision() throws {
        struct Clashing: SwiftMigration {
            static let version: Int64 = 1   // the SQL example already owns this
            static let name = "clash"
            func up(_ db: some MigrationContext) async throws {}
        }
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.writeMigrations(into: directory)

        #expect(throws: (any Error).self) {
            _ = try CombinedMigrations([
                MigrationDirectory(url: directory, syntax: SQLite.migrationSyntax),
                SwiftMigrations([Clashing()]),
            ]).load()
        }
    }
}

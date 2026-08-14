import Foundation
import SwizzleCore
import SwizzleMigrate
import SwizzleSQLite
import SwizzleSQLiteEngine

/// Running SQL and Swift migrations together, from your own binary.
///
/// ## Why this file has to exist
///
/// The prebuilt `swizzle` CLI **cannot run Swift migrations**, and no flag will
/// change that: your migrations are Swift code, and a binary compiled before your
/// code existed cannot contain it. The CLI runs the SQL form and only the SQL
/// form.
///
/// goose has exactly the same constraint and exactly this answer — its
/// `examples/go-migrations/main.go` opens with *"This is custom goose binary with
/// sqlite3 support only."* You link the library into a small binary of your own,
/// name your migrations, and run that in your deploy instead of the stock CLI.
///
/// This was undocumented until somebody asked what a migration file looks like,
/// which is the wrong moment to find out.
///
/// ## Going through the engine, not around it
///
/// `SQLiteEngine.connect(url:)` rather than `SQLiteConnection(path:)`, and the
/// difference matters: SQLite has no advisory locks, so its migration lock is a
/// *table*, and the engine's `connect` is what creates it. MySQL and Postgres
/// need no such thing — their locks need no storage — so this asymmetry is easy
/// to miss until the first `acquireLock` fails on a table that is not there.
///
/// Writing this example the low-level way hit exactly that, which is the useful
/// thing an example does before a user has to.
public enum ExampleRunner {

    /// Builds a migrator over both migration forms.
    ///
    /// One `Migrator`, one journal, one lock, one version space.
    /// `CombinedMigrations` merges the SQL directory with the Swift types and
    /// validates the union, so two migrations claiming version 5 is an error
    /// rather than something silently resolved by source order.
    static func migrator(
        for connection: any EngineConnection, migrationsDirectory: URL
    ) -> Migrator {
        Migrator(
            executor: connection.executor,
            dialect: connection.dialect,
            source: CombinedMigrations([
                // The `.sql` files — the same ones the CLI would read.
                MigrationDirectory(url: migrationsDirectory, syntax: SQLite.migrationSyntax),
                // And the Swift ones, named explicitly. This list *is* the
                // registration. goose registers by side effect from `func
                // init()`, which is less typing and one more way to be wrong: a
                // file nobody imports registers nothing and the migration
                // silently does not exist. Here it is a value you did not pass.
                SwiftMigrations([BackfillSlugs(), NormaliseEmails()]),
            ])
        )
    }

    /// Applies every pending migration, SQL and Swift interleaved by version.
    ///
    /// The same shape works for MySQL and Postgres — swap the engine, and
    /// nothing else changes. That is what `SwizzleMigrate` depending on no driver
    /// buys.
    public static func migrate(url: String, migrationsDirectory: URL) async throws {
        let connection = try await SQLiteEngine.connect(url: url)
        defer { connection.close() }

        for migration in try await migrator(
            for: connection, migrationsDirectory: migrationsDirectory
        ).up() {
            print("applied \(migration.version) \(migration.name)")
        }
    }

    /// What `swizzle migrate status` prints, from the same wiring.
    public static func status(url: String, migrationsDirectory: URL) async throws {
        let connection = try await SQLiteEngine.connect(url: url)
        defer { connection.close() }

        for entry in try await migrator(
            for: connection, migrationsDirectory: migrationsDirectory
        ).status() {
            // `state` rather than a bool: "applied" and "applied but the file has
            // changed since" are different answers, and flattening them to
            // `isApplied` would hide the one worth acting on.
            switch entry.state {
            case .pending:
                print("pending  \(entry.version) \(entry.name)")
            case .applied(let at):
                print("applied  \(entry.version) \(entry.name) at \(at)")
            case .modified(let appliedAt, _, _):
                print("MODIFIED \(entry.version) \(entry.name) applied at \(appliedAt)")
            default:
                print("\(entry.state) \(entry.version) \(entry.name)")
            }
        }
    }
}

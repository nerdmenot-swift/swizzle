import SwizzleCore

/// The few things a migrator needs that differ per database.
///
/// Kept deliberately small. Everything else — parsing, ordering, checksums,
/// planning — is dialect-neutral, which is the point of writing the migrator
/// against ``SQLExecutor`` rather than against a driver.
public protocol MigrationDialect: SQLDialect {

    /// Lexical rules for splitting a migration file.
    static var migrationSyntax: SQLStatementSplitter.Syntax { get }

    /// Whether DDL can be rolled back.
    ///
    /// The single most consequential difference between these databases, and the
    /// reason a migrator cannot promise atomicity everywhere. Postgres and
    /// SQLite roll DDL back. **MySQL and MariaDB commit implicitly before and
    /// after every DDL statement**, so `BEGIN; ALTER TABLE …; ROLLBACK;` leaves
    /// the ALTER applied. Wrapping a MySQL migration in a transaction is not
    /// merely useless — believing it worked is what turns a failed migration
    /// into a silently half-migrated database.
    static var hasTransactionalDDL: Bool { get }

    /// Creates the journal table if it is not already there.
    static func createJournalTable(named table: String) -> String

    /// Lists the journal's existing column names, so an older layout can be
    /// detected.
    ///
    /// The journal is our own metadata and its shape has already changed once
    /// (gaining `id` and `kind` when repeatable migrations arrived). A tool
    /// whose whole job is migrating schemas cannot fail to migrate its own —
    /// and `CREATE TABLE IF NOT EXISTS` silently does nothing against an old
    /// table, so the first symptom is an unrelated "Unknown column" error from
    /// a later query.
    static func journalColumns(named table: String) -> (String, [SQLValue])

    /// Brings a pre-`id` journal up to the current shape, preserving its rows.
    static func upgradeJournal(named table: String) -> [String]

    /// Takes an exclusive lock, returning SQL whose single value is truthy on
    /// success and falsy on timeout.
    ///
    /// This is what Drizzle has none of: two pods rolling out at once both read
    /// an empty journal and both apply migration 5. Under a lock the second one
    /// waits, re-reads, and finds nothing to do.
    static func acquireLock(named name: String, timeoutSeconds: Int) -> (String, [SQLValue])

    /// Releases it. Advisory locks are session-scoped, so a crashed process
    /// drops its lock when the connection dies.
    static func releaseLock(named name: String) -> (String, [SQLValue])
}

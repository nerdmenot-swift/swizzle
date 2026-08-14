import Foundation
import SwizzleCore
import SwizzleSQLite
import SwizzleMigrate

/// SQLite as a migration dialect.
extension SQLite: MigrationDialect {
    public static var migrationSyntax: SQLStatementSplitter.Syntax { .sqlite }

    /// **True**, and more completely than anywhere else.
    ///
    /// Postgres rolls DDL back; SQLite rolls back *everything*, because a
    /// transaction is a journal over the whole file. There is no statement in
    /// SQLite that commits implicitly the way MySQL's DDL does.
    public static var hasTransactionalDDL: Bool { true }

    public static func createJournalTable(named table: String) -> String {
        """
        CREATE TABLE IF NOT EXISTS "\(table)" (
            id         TEXT    NOT NULL PRIMARY KEY,
            version    INTEGER NULL,
            name       TEXT    NOT NULL,
            kind       TEXT    NOT NULL,
            checksum   TEXT    NOT NULL,
            applied_at TEXT    NOT NULL DEFAULT (datetime('now'))
        )
        """
    }

    /// `PRAGMA table_info` is SQLite's information schema.
    ///
    /// It takes the table name as *syntax*, not as a parameter — pragmas cannot
    /// be parameterised — so the name is quoted rather than bound. Safe here
    /// because the journal name comes from configuration rather than from data,
    /// and the quoting doubles any embedded quote either way.
    public static func journalColumns(named table: String) -> (String, [SQLValue]) {
        ("SELECT name FROM pragma_table_info(\(quotedLiteral(table)))", [])
    }

    /// Nothing to upgrade: SQLite support arrived after the journal gained `id`
    /// and `kind`, so it has only ever had one shape here.
    public static func upgradeJournal(named table: String) -> [String] { [] }

    /// A lock **row**, because SQLite has no advisory locks.
    ///
    /// This is the one place SQLite is genuinely weaker than the other two, and
    /// it is worth being precise about why. Postgres and MySQL advisory locks are
    /// *session-scoped*: a migrator that crashes drops its lock when the
    /// connection dies, and the next deploy proceeds. A row in a table has no
    /// session, so a crash leaves it behind.
    ///
    /// So the row carries the time it was taken, and an entry older than the
    /// caller's own timeout is treated as abandoned and replaced. That makes a
    /// crashed migrator self-healing after one timeout rather than needing a
    /// human — at the cost of a theoretical window where a migrator paused for
    /// longer than the timeout could have its lock stolen. Given SQLite is
    /// single-file and usually single-process, and that the alternative is a
    /// deploy wedged until someone deletes a row, that is the right trade.
    ///
    /// `RETURNING 1` reports whether the lock was actually taken. It has to be
    /// **one** statement: `sqlite3_prepare_v2` compiles only the first statement
    /// in a string and silently ignores the rest, so an `INSERT …; SELECT
    /// changes()` pair runs the insert and returns nothing — which the migrator
    /// reads as "not acquired", forever. `RETURNING` emits a row only for a row
    /// actually written, so no row *is* the falsy answer.
    public static func acquireLock(
        named name: String, timeoutSeconds: Int
    ) -> (String, [SQLValue]) {
        (
            """
            INSERT INTO "\(lockTable)" (name, acquired_at) VALUES (?1, strftime('%s','now'))
            ON CONFLICT(name) DO UPDATE SET acquired_at = strftime('%s','now')
                WHERE strftime('%s','now') - "\(lockTable)".acquired_at > ?2
            RETURNING 1
            """,
            [.text(name), .int(Int64(timeoutSeconds))]
        )
    }

    public static func releaseLock(named name: String) -> (String, [SQLValue]) {
        ("DELETE FROM \"\(lockTable)\" WHERE name = ?1 RETURNING 1", [.text(name)])
    }

    /// Created alongside the journal — see ``SQLiteEngineConnection``.
    public static let lockTable = "swizzle_migration_lock"

    static func createLockTable() -> String {
        """
        CREATE TABLE IF NOT EXISTS "\(lockTable)" (
            name        TEXT    NOT NULL PRIMARY KEY,
            acquired_at INTEGER NOT NULL
        )
        """
    }

    /// Quotes a string as a SQL literal, doubling any embedded quote.
    static func quotedLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}

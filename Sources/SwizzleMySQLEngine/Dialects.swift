import SwizzleMigrate
import SwizzleCore

// MARK: - MySQL and MariaDB

/// Shared by both, because the migration-relevant behaviour is identical.
extension MigrationDialect where Self: SQLDialect {
    /// The journal.
    ///
    /// Keyed by a string id rather than the version, because a repeatable
    /// migration has no version — `version` is NULL for those and `id` is
    /// `R__<name>`. The index on `version` keeps "what is the highest applied
    /// version" cheap, which the ordering guard asks on every run.
    static var mysqlJournalDDL: (String) -> String {
        { table in
            """
            CREATE TABLE IF NOT EXISTS `\(table)` (
                id         VARCHAR(255) NOT NULL PRIMARY KEY,
                version    BIGINT       NULL,
                name       VARCHAR(255) NOT NULL,
                kind       VARCHAR(16)  NOT NULL,
                checksum   VARCHAR(80)  NOT NULL,
                applied_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
                KEY version_idx (version)
            ) ENGINE=InnoDB
            """
        }
    }

    /// `GET_LOCK` returns 1 on success, 0 on timeout and NULL on error, and the
    /// lock is released when the session ends — so a process killed mid-migration
    /// does not wedge every later deploy.
    ///
    /// The name is truncated to 64 characters because MySQL 5.7+ rejects longer
    /// ones outright.
    static func mysqlAcquire(_ name: String, _ timeout: Int) -> (String, [SQLValue]) {
        ("SELECT GET_LOCK(?, ?)", [.text(String(name.prefix(64))), .int(Int64(timeout))])
    }

    static func mysqlRelease(_ name: String) -> (String, [SQLValue]) {
        ("SELECT RELEASE_LOCK(?)", [.text(String(name.prefix(64)))])
    }

    static func mysqlJournalColumns(_ table: String) -> (String, [SQLValue]) {
        (
            "SELECT column_name FROM information_schema.columns "
                + "WHERE table_schema = DATABASE() AND table_name = ?",
            [.text(table)]
        )
    }

    /// v1 → v2: the journal was keyed on `version` and knew nothing of
    /// repeatable migrations. Adding `id`/`kind` and backfilling them from the
    /// existing rows preserves everything already applied.
    ///
    /// The primary key has to move before `version` can become nullable, so the
    /// order here is load-bearing.
    static func mysqlUpgradeJournal(_ table: String) -> [String] {
        [
            "ALTER TABLE `\(table)` ADD COLUMN id VARCHAR(255) NULL",
            "ALTER TABLE `\(table)` ADD COLUMN kind VARCHAR(16) NOT NULL DEFAULT \'versioned\'",
            "UPDATE `\(table)` SET id = CAST(version AS CHAR) WHERE id IS NULL",
            "ALTER TABLE `\(table)` DROP PRIMARY KEY",
            "ALTER TABLE `\(table)` MODIFY COLUMN id VARCHAR(255) NOT NULL",
            "ALTER TABLE `\(table)` ADD PRIMARY KEY (id)",
            "ALTER TABLE `\(table)` MODIFY COLUMN version BIGINT NULL",
            "ALTER TABLE `\(table)` ADD KEY version_idx (version)",
        ]
    }
}

extension MySQL: MigrationDialect {
    public static var migrationSyntax: SQLStatementSplitter.Syntax { .mysql }

    /// **False, and this is the important one.**
    ///
    /// MySQL commits implicitly before and after every DDL statement. `BEGIN;
    /// ALTER TABLE …; ROLLBACK;` leaves the ALTER applied. MySQL 8.0 made *some*
    /// data-dictionary changes atomic individually, but a multi-statement
    /// migration still cannot be rolled back as a unit.
    ///
    /// So the migrator does not wrap MySQL migrations at all, rather than
    /// wrapping them and reporting an atomicity it does not have. A failure
    /// says which statement failed and that the earlier ones are committed.
    public static var hasTransactionalDDL: Bool { false }

    public static func createJournalTable(named table: String) -> String {
        mysqlJournalDDL(table)
    }
    public static func acquireLock(named name: String, timeoutSeconds: Int) -> (String, [SQLValue]) {
        mysqlAcquire(name, timeoutSeconds)
    }
    public static func releaseLock(named name: String) -> (String, [SQLValue]) {
        mysqlRelease(name)
    }
    public static func journalColumns(named table: String) -> (String, [SQLValue]) {
        mysqlJournalColumns(table)
    }
    public static func upgradeJournal(named table: String) -> [String] {
        mysqlUpgradeJournal(table)
    }
}

extension MariaDB: MigrationDialect {
    public static var migrationSyntax: SQLStatementSplitter.Syntax { .mysql }
    public static var hasTransactionalDDL: Bool { false }

    public static func createJournalTable(named table: String) -> String {
        mysqlJournalDDL(table)
    }
    public static func acquireLock(named name: String, timeoutSeconds: Int) -> (String, [SQLValue]) {
        mysqlAcquire(name, timeoutSeconds)
    }
    public static func releaseLock(named name: String) -> (String, [SQLValue]) {
        mysqlRelease(name)
    }
    public static func journalColumns(named table: String) -> (String, [SQLValue]) {
        mysqlJournalColumns(table)
    }
    public static func upgradeJournal(named table: String) -> [String] {
        mysqlUpgradeJournal(table)
    }
}

import Foundation
import SwizzleCore
import SwizzleMigrate

/// Postgres as a migration dialect.
///
/// The whole conformance is six members, and the interesting one is the first.
extension Postgres: MigrationDialect {
    public static var migrationSyntax: SQLStatementSplitter.Syntax { .postgres }

    /// **True**, and this is the headline difference from MySQL.
    ///
    /// Postgres runs DDL inside a transaction and rolls it back like anything
    /// else. So a migration here really is atomic: a failure on statement four
    /// leaves the database exactly as it was, and the migrator's error says so
    /// instead of warning that earlier statements are committed and
    /// unrecoverable.
    ///
    /// Nothing in the migrator had to change for that — it already branched on
    /// this flag because MySQL forced the question. The behaviour a MySQL user
    /// has to work around is simply absent here.
    public static var hasTransactionalDDL: Bool { true }

    public static func createJournalTable(named table: String) -> String {
        """
        CREATE TABLE IF NOT EXISTS "\(table)" (
            id         VARCHAR(255) NOT NULL PRIMARY KEY,
            version    BIGINT       NULL,
            name       VARCHAR(255) NOT NULL,
            kind       VARCHAR(16)  NOT NULL,
            checksum   VARCHAR(80)  NOT NULL,
            applied_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
        )
        """
    }

    public static func journalColumns(named table: String) -> (String, [SQLValue]) {
        (
            "SELECT column_name FROM information_schema.columns "
                + "WHERE table_schema = CURRENT_SCHEMA() AND table_name = $1",
            [.text(table)]
        )
    }

    /// No upgrade path is needed: the journal has only ever had this shape here,
    /// because Postgres support arrived after the `id`/`kind` change that MySQL
    /// had to migrate through.
    public static func upgradeJournal(named table: String) -> [String] { [] }

    /// `pg_try_advisory_lock` takes a 64-bit key rather than a name, so the name
    /// is hashed into one.
    ///
    /// Deliberately `try` rather than the blocking `pg_advisory_lock`: blocking
    /// has no timeout, and a deploy that hangs forever waiting for a lock nobody
    /// will release is worse than one that fails and says why. The migrator
    /// retries until its timeout.
    public static func acquireLock(
        named name: String, timeoutSeconds: Int
    ) -> (String, [SQLValue]) {
        ("SELECT pg_try_advisory_lock($1)", [.int(advisoryKey(for: name))])
    }

    public static func releaseLock(named name: String) -> (String, [SQLValue]) {
        ("SELECT pg_advisory_unlock($1)", [.int(advisoryKey(for: name))])
    }

    /// FNV-1a over the name, folded into `Int64`.
    ///
    /// Any stable hash works — every process migrating one database must simply
    /// agree. Written out rather than using `Hashable`, whose seed is randomised
    /// per process and would therefore give two deploys *different* keys and no
    /// mutual exclusion at all.
    static func advisoryKey(for name: String) -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Int64(bitPattern: hash)
    }
}

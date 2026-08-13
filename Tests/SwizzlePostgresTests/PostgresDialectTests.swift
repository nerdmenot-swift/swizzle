import Testing
@testable import SwizzleCore
@testable import SwizzleMigrate
@testable import SwizzlePostgres

/// The Postgres engine's pure parts.
///
/// No server: these cover the SQL the dialect emits and the URL it accepts,
/// which is everything that can be checked without one. Behaviour against a live
/// Postgres needs a fixture the test servers do not have yet.
@Suite("Postgres dialect")
struct PostgresDialectTests {

    /// The headline difference from MySQL, and the one the migrator branches on.
    /// The migrator branches on this, and the branch is why a failed migration
    /// here reports "rolled back; the database is unchanged" where MySQL has to
    /// warn that earlier statements are committed and unrecoverable.
    @Test("Postgres has transactional DDL")
    func transactionalDDL() {
        #expect(Postgres.hasTransactionalDDL)
    }

    @Test("the dialect renders its own quoting and placeholders")
    func rendering() {
        let dialect = Postgres.erased
        #expect(dialect.identifier("swizzle_migrations") == "\"swizzle_migrations\"")
        #expect(dialect.placeholder(0) == "$1")
        #expect(dialect.placeholder(1) == "$2")
    }

    @Test("the journal DDL is Postgres-shaped")
    func journalDDL() {
        let ddl = Postgres.createJournalTable(named: "swizzle_migrations")
        #expect(ddl.contains("CREATE TABLE IF NOT EXISTS \"swizzle_migrations\""))
        #expect(ddl.contains("TIMESTAMPTZ"), "not MySQL's TIMESTAMP")
        #expect(!ddl.contains("ENGINE=InnoDB"))
    }

    /// Every process migrating one database has to derive the same key, so the
    /// hash must be stable across runs — which rules out `Hashable`, whose seed
    /// is randomised per process and would give two deploys different keys and
    /// therefore no mutual exclusion at all.
    @Test("the advisory lock key is stable and name-dependent")
    func advisoryKeyIsStable() {
        let a = Postgres.advisoryKey(for: "swizzle_migrate")
        let b = Postgres.advisoryKey(for: "swizzle_migrate")
        let c = Postgres.advisoryKey(for: "other")
        #expect(a == b)
        #expect(a != c)
        // Pinned, so a future change to the hash is caught rather than silently
        // splitting old and new deploys onto different locks.
        #expect(a == 1_296_919_791_556_677_947)
    }

    @Test("the lock uses try, not the blocking form")
    func lockIsNonBlocking() {
        let (sql, binds) = Postgres.acquireLock(named: "x", timeoutSeconds: 30)
        #expect(sql.contains("pg_try_advisory_lock"))
        #expect(!sql.contains("pg_advisory_lock("), "blocking has no timeout")
        #expect(binds.count == 1)
        #expect(Postgres.releaseLock(named: "x").0.contains("pg_advisory_unlock"))
    }

    /// Postgres bodies are dollar-quoted, so the compound-statement detection
    /// MySQL needs is off — and a bare `BEGIN` really is a transaction.
    @Test("the splitter uses Postgres rules")
    func splitterSyntax() {
        #expect(Postgres.migrationSyntax.dollarQuoting)
        #expect(!Postgres.migrationSyntax.compoundStatements)
        #expect(!Postgres.migrationSyntax.backslashEscapes)
    }

    /// `blocking-index` advises applying the index online. Postgres has
    /// `CREATE INDEX CONCURRENTLY`, so that remedy is wrong here — and a warning
    /// whose fix does not apply is how a linter gets switched off.
    @Test("engine-specific lint rules are filtered")
    func lintRules() {
        let names = PostgresEngine.lintRules.map(\.name)
        #expect(!names.contains("blocking-index"))
        #expect(names.contains("destructive-table"))
        #expect(names.contains("not-null-no-default"))
    }

    @Test("the engine claims both spellings")
    func schemes() {
        #expect(PostgresEngine.urlSchemes == ["postgres", "postgresql"])
        let registry = EngineRegistry([PostgresEngine.self])
        #expect(registry.engine(forURL: "postgres://h/d") != nil)
        #expect(registry.engine(forURL: "postgresql://h/d") != nil)
        #expect(registry.engine(forURL: "mysql://h/d") == nil)
    }
}

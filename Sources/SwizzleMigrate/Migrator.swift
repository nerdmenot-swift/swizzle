import Foundation
import SwizzleCore

/// A migration's state relative to the database.
public struct MigrationStatus: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case pending
        case applied(at: String)
        /// Applied, but the file has changed since — see ``Checksum``.
        ///
        /// An error for a versioned migration, because the database is on a
        /// version of it that no longer exists anywhere.
        case modified(appliedAt: String, recorded: String, current: String)
        /// A **repeatable** migration whose file has changed, so it will be
        /// re-applied on the next `up`.
        ///
        /// Deliberately distinct from ``modified``: for a repeatable migration
        /// a changed file is the normal way to work, not a problem.
        case outdated(appliedAt: String)
        /// Recorded in the journal with no file to match it. Usually a
        /// migration deleted from the working tree, or a rollback to a version
        /// older than the code.
        case missingFile(appliedAt: String)
    }

    public let identifier: String
    public let version: Int64?
    public let name: String
    public let isRepeatable: Bool
    public let state: State

    public var isPending: Bool { state == .pending }

    /// Whether `up` would run this.
    public var willRun: Bool {
        switch state {
        case .pending, .outdated: true
        case .applied, .modified, .missingFile: false
        }
    }
}

/// Something went wrong applying or reverting.
public struct MigrationError: Error, Sendable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        case lockTimeout(seconds: Int)
        case checksumMismatch(recorded: String, current: String)
        case irreversible
        case notApplied
        case outOfOrder(pendingBelow: Int64, applied: Int64)
        /// A statement failed. `statementIndex` is 0-based within the migration.
        case statementFailed(statementIndex: Int, statement: String, partiallyApplied: Bool)
        /// A Swift migration threw. There is no statement index, because a
        /// closure has no statements to count.
        case swiftMigrationFailed(partiallyApplied: Bool)
        /// The migration asked to be applied online and no runner was supplied.
        case onlineUnavailable(statement: String)
    }

    public let version: Int64?
    public let name: String?
    public let kind: Kind
    public let underlying: (any Error)?

    public var description: String {
        let what = version.map { "migration \($0)_\(name ?? "")" } ?? "migrations"
        // The server's own message is the useful half. Leaving it out meant an
        // error that named the failing statement and not the reason for it.
        // `String(reflecting:)` rather than interpolation: postgres-nio's error
        // has a deliberately vague `description` to avoid leaking data into logs,
        // so plain interpolation produced "Generic description to prevent
        // accidental leakage" where the actual syntax error should have been.
        let cause = underlying.map { "\n  \(String(reflecting: $0))" } ?? ""
        switch kind {
        case .lockTimeout(let seconds):
            return "could not acquire the migration lock within \(seconds)s — "
                + "another process is probably migrating"
        case .checksumMismatch(let recorded, let current):
            return "\(what) has changed since it was applied "
                + "(recorded \(recorded.prefix(15))…, now \(current.prefix(15))…). "
                + "Editing an applied migration leaves existing databases on the old version "
                + "of it. Add a new migration instead, or turn checksum verification off "
                + "if the edit was deliberate."
        case .irreversible:
            return "\(what) has no Down section and cannot be reverted"
        case .notApplied:
            return "\(what) is not applied, so there is nothing to revert"
        case .outOfOrder(let pending, let applied):
            return "migration \(pending) is pending but \(applied) has already been applied. "
                + "Applying it now would run migrations out of order; the schema it expects "
                + "is not the schema it would find."
        case .statementFailed(let index, let statement, let partial):
            let head = statement.prefix(120)
            // "Rolled back" is only true when there was a transaction. On MySQL
            // there is not — but if the *first* statement failed then nothing
            // ran, which is a different reason for the same reassurance and
            // worth saying accurately.
            let aftermath = partial
                ? "\n  Earlier statements in this migration were already committed and "
                    + "CANNOT be rolled back — this database has DDL outside a transaction. "
                    + "Fix the schema by hand, or write a migration that repairs it."
                : index == 0
                    ? "\n  It was the first statement, so nothing in this migration ran."
                    : "\n  The migration was rolled back; the database is unchanged."
            return "\(what) failed at statement \(index + 1): \(head)\(cause)\(aftermath)"
        case .onlineUnavailable(let statement):
            return "\(what) is marked `-- +swizzle Online` but no online runner was "
                + "configured, so this ALTER would have held the table:\n  "
                + String(statement.prefix(120))
                + "\n  Refused rather than run as an ordinary ALTER — a migration that "
                + "asked for online and silently got blocking is an outage nobody agreed to."
        case .swiftMigrationFailed(let partial):
            return "\(what) threw\(cause)"
                + (partial
                   ? "\n  It is a Swift migration on a database that cannot roll DDL back, so "
                     + "whatever it had already done is committed and there is no statement "
                     + "index to resume from. This is the cost of a code migration: it is "
                     + "opaque where a SQL one is not."
                   : "\n  The migration was rolled back; the database is unchanged.")
        }
    }
}

/// Applies and reverts migrations against any ``SQLExecutor``.
///
/// SQL-first: the files are the source of truth and nothing here generates them.
/// The two things this has that Drizzle's 60-line runtime migrator does not are
/// a **lock** — so two pods rolling out simultaneously cannot both apply the
/// same migration — and **real down migrations**.
public struct Migrator: Sendable {

    public struct Configuration: Sendable {
        /// Table recording what has been applied.
        public var journalTable: String = "swizzle_migrations"
        /// Advisory lock name. Shared by every process migrating this database.
        public var lockName: String = "swizzle_migrate"
        public var lockTimeoutSeconds: Int = 30
        /// Refuse to run when an applied migration's file has changed.
        public var verifyChecksums: Bool = true
        /// Refuse to apply a migration older than one already applied.
        ///
        /// This catches the branch-merge case: two developers write migration 5
        /// and 6, 6 lands and is deployed, then 5 merges. Applying 5 now runs it
        /// against a schema it was never written for. Timestamped versions make
        /// this common enough to be worth guarding by default.
        public var requireOrdered: Bool = true

        public init() {}
    }

    /// Exposed so a caller can introspect the same database the migrator is
    /// pointed at, rather than opening a second connection to it.
    /// Applies `ALTER`s without holding the table, for migrations marked
    /// `-- +swizzle Online`.
    ///
    /// Optional, and its absence is an error rather than a fallback: a migration
    /// that asked for online and quietly got a locking ALTER is an outage nobody
    /// agreed to.
    public var onlineRunner: (any OnlineDDLRunner)?

    /// Exposed so a caller can introspect the same database the migrator is
    /// pointed at, rather than opening a second connection to it.
    public let executor: AnySQLExecutor
    /// The dialect, as a value — see ``AnyMigrationDialect``.
    public let dialect: AnyMigrationDialect
    /// Where the migrations came from. Exposed so a caller can lint or list the
    /// same set the migrator would run, without rebuilding it.
    public let source: any MigrationSource
    public var configuration: Configuration

    public init(
        executor: AnySQLExecutor,
        dialect: AnyMigrationDialect,
        source: any MigrationSource,
        configuration: Configuration = Configuration(),
        onlineRunner: (any OnlineDDLRunner)? = nil
    ) {
        self.onlineRunner = onlineRunner
        self.executor = executor
        self.dialect = dialect
        self.source = source
        self.configuration = configuration
    }

    /// Convenience for a caller that does have a concrete executor.
    public init<Executor: SQLExecutor>(
        executor: Executor,
        source: any MigrationSource,
        configuration: Configuration = Configuration(),
        onlineRunner: (any OnlineDDLRunner)? = nil
    ) where Executor.Dialect: MigrationDialect {
        self.init(
            executor: executor.erased, dialect: Executor.Dialect.erased,
            source: source, configuration: configuration, onlineRunner: onlineRunner
        )
    }

    // MARK: - Journal

    /// One journal row.
    struct Record: Sendable {
        let identifier: String
        let version: Int64?
        let name: String
        let checksum: String
        let appliedAt: String
    }

    func ensureJournal() async throws {
        // `CREATE TABLE IF NOT EXISTS` is **not** race-free on Postgres: two
        // processes running it at the same instant produce a unique violation on
        // `pg_type` rather than one of them quietly losing. MySQL tolerates the
        // same race, which is why it stayed hidden until a Postgres concurrency
        // test ran two migrators at once.
        //
        // This cannot be solved by taking the lock first — the lock is advisory
        // and needs no table, but every other path here reads the journal, so it
        // has to exist before the lock is meaningful. Instead the failure is
        // absorbed and the outcome checked: if the table exists now, whoever
        // created it did the job.
        do {
            _ = try await executor.executeUpdate(
                sql: dialect.createJournalTable(named: configuration.journalTable), bindings: []
            )
        } catch {
            let (probe, probeBindings) = dialect.journalColumns(named: configuration.journalTable)
            let existing = try await executor.execute(sql: probe, bindings: probeBindings)
            guard !existing.isEmpty else { throw error }
        }

        // `CREATE TABLE IF NOT EXISTS` does nothing to a table that already
        // exists in an older shape, so the layout is checked rather than
        // assumed. Without this the first symptom of an outdated journal is an
        // "Unknown column 'id'" error from an unrelated query.
        let (sql, bindings) = dialect.journalColumns(named: configuration.journalTable)
        let rows = try await executor.execute(sql: sql, bindings: bindings)
        let columns = Set(rows.compactMap { $0.values.first.map(Self.text)?.lowercased() })

        guard !columns.isEmpty, !columns.contains("id") else { return }

        for statement in dialect.upgradeJournal(named: configuration.journalTable) {
            // Best effort per statement: a journal half-upgraded by an earlier
            // interrupted run should converge rather than wedge.
            _ = try? await executor.executeUpdate(sql: statement, bindings: [])
        }
    }

    func readJournal() async throws -> [String: Record] {
        let quoted = dialect.identifier(configuration.journalTable)
        let rows = try await executor.execute(
            sql: "SELECT id, version, name, checksum, applied_at FROM \(quoted) ORDER BY id",
            bindings: []
        )
        var records: [String: Record] = [:]
        for row in rows where row.values.count >= 5 {
            let identifier = Self.text(row.values[0])
            records[identifier] = Record(
                identifier: identifier,
                version: Self.int(row.values[1]),
                name: Self.text(row.values[2]),
                checksum: Self.text(row.values[3]),
                appliedAt: Self.text(row.values[4])
            )
        }
        return records
    }

    private static func int(_ value: SQLValue) -> Int64? {
        switch value {
        case .int(let raw): raw
        case .double(let raw): Int64(raw)
        case .text(let raw): Int64(raw)
        case .null, .bool, .blob: nil
        }
    }

    private static func text(_ value: SQLValue) -> String {
        switch value {
        case .text(let raw): raw
        case .int(let raw): String(raw)
        case .double(let raw): String(raw)
        case .bool(let raw): String(raw)
        case .null: ""
        case .blob(let bytes): String(decoding: bytes, as: UTF8.self)
        }
    }

    // MARK: - Status

    /// What is applied, what is pending, and what has drifted.
    ///
    /// Read-only and takes no lock, so it is safe to call from a health check.
    public func status() async throws -> [MigrationStatus] {
        try await ensureJournal()
        let journal = try await readJournal()
        let migrations = try source.load()

        var statuses: [MigrationStatus] = migrations.map { migration in
            let record = journal[migration.identifier]
            let state: MigrationStatus.State

            if let record {
                if record.checksum != migration.checksum, !record.checksum.isEmpty {
                    // A changed repeatable migration is the normal way to work;
                    // a changed versioned one means the database is on a version
                    // of it that no longer exists anywhere.
                    state = migration.isRepeatable
                        ? .outdated(appliedAt: record.appliedAt)
                        : .modified(
                            appliedAt: record.appliedAt,
                            recorded: record.checksum, current: migration.checksum
                        )
                } else {
                    state = .applied(at: record.appliedAt)
                }
            } else {
                state = .pending
            }

            return MigrationStatus(
                identifier: migration.identifier, version: migration.version,
                name: migration.name, isRepeatable: migration.isRepeatable, state: state
            )
        }

        // Journal rows with no matching file, so a deleted migration is visible
        // rather than simply absent.
        let known = Set(migrations.map(\.identifier))
        for record in journal.values where !known.contains(record.identifier) {
            statuses.append(
                MigrationStatus(
                    identifier: record.identifier, version: record.version,
                    name: record.name, isRepeatable: record.version == nil,
                    state: .missingFile(appliedAt: record.appliedAt)
                )
            )
        }
        return statuses.sorted {
            switch ($0.version, $1.version) {
            case (let a?, let b?): a < b
            case (_?, nil): true                 // versioned before repeatable
            case (nil, _?): false
            case (nil, nil): $0.name < $1.name
            }
        }
    }

    // MARK: - Planning

    /// Exactly what `up` would run, without running any of it.
    ///
    /// What `--dry-run` prints. A migrator that can only be understood by
    /// letting it loose on a database is no use during review, and no use at all
    /// at 3am.
    public func plan(to target: Int64? = nil) async throws -> [Migration] {
        try await ensureJournal()
        let journal = try await readJournal()
        let migrations = try source.load()
        try verify(migrations, against: journal)
        return try pending(migrations, journal, target)
    }

    /// Versioned migrations not yet applied, then repeatable ones that are new
    /// or whose content changed.
    private func pending(
        _ migrations: [Migration], _ journal: [String: Record], _ target: Int64?
    ) throws -> [Migration] {
        var result: [Migration] = []

        for migration in migrations {
            let record = journal[migration.identifier]

            if migration.isRepeatable {
                // New, or the file changed since it was last applied.
                if record == nil || record!.checksum != migration.checksum {
                    result.append(migration)
                }
                continue
            }

            guard record == nil else { continue }
            if let target, let version = migration.version, version > target { continue }
            result.append(migration)
        }

        if configuration.requireOrdered {
            let highestApplied = journal.values.compactMap(\.version).max() ?? 0
            if let earliest = result.first(where: { $0.version != nil }),
               let version = earliest.version, version < highestApplied {
                throw MigrationError(
                    version: version, name: earliest.name,
                    kind: .outOfOrder(pendingBelow: version, applied: highestApplied),
                    underlying: nil
                )
            }
        }
        return result
    }

    // MARK: - Applying

    /// Applies every pending migration, or everything up to `target`.
    ///
    /// Returns what it applied, in order. Applying nothing is success, not an
    /// error — a deploy that runs migrations on every boot must be a no-op the
    /// second time.
    @discardableResult
    public func up(to target: Int64? = nil) async throws -> [Migration] {
        try await withLock {
            let migrations = try self.source.load()
            let journal = try await self.readJournal()
            try self.verify(migrations, against: journal)

            var applied: [Migration] = []
            for migration in try self.pending(migrations, journal, target) {
                try await self.apply(
                    migration, body: migration.up,
                    recording: .record(replacing: journal[migration.identifier] != nil)
                )
                applied.append(migration)
            }
            return applied
        }
    }

    /// Reverts the most recently applied migrations, newest first.
    ///
    /// Repeatable migrations are never reverted: they have no `Down`, and the
    /// way to undo one is to change its file back.
    @discardableResult
    public func down(count: Int = 1) async throws -> [Migration] {
        try await withLock {
            let migrations = try self.source.load()
            let journal = try await self.readJournal()
            try self.verify(migrations, against: journal)

            let applied = migrations
                .filter { !$0.isRepeatable && journal[$0.identifier] != nil }
                .sorted { ($0.version ?? 0) > ($1.version ?? 0) }
                .prefix(count)

            var reverted: [Migration] = []
            for migration in applied {
                guard migration.isReversible else {
                    throw MigrationError(
                        version: migration.version, name: migration.name,
                        kind: .irreversible, underlying: nil
                    )
                }
                guard let down = migration.down else {
                    throw MigrationError(
                        version: migration.version, name: migration.name,
                        kind: .irreversible, underlying: nil
                    )
                }
                try await self.apply(migration, body: down, recording: .erase)
                reverted.append(migration)
            }
            return reverted
        }
    }

    /// Reverts down to and including `version`.
    @discardableResult
    public func down(to version: Int64) async throws -> [Migration] {
        let journal = try await readJournal()
        let count = journal.values.compactMap(\.version).filter { $0 >= version }.count
        return try await down(count: count)
    }

    /// Reverts the newest migration and applies it again.
    ///
    /// The development loop. Without it, iterating on a migration you just wrote
    /// means hand-deleting a journal row — which every tool lacking `redo` grows
    /// a folk workflow for.
    @discardableResult
    public func redo() async throws -> [Migration] {
        let reverted = try await down(count: 1)
        guard let migration = reverted.first else { return [] }
        return try await up(to: migration.version)
    }

    // MARK: - Baseline

    /// Marks every migration up to `version` as applied **without running it**.
    ///
    /// How an existing database adopts Swizzle at all. Without this, pointing the
    /// migrator at a production schema would try to run migration 1 against
    /// tables that already exist.
    ///
    /// Repeatable migrations are deliberately *not* baselined: they are cheap to
    /// re-apply and doing so proves they match what is in the database.
    @discardableResult
    public func baseline(to version: Int64) async throws -> [Migration] {
        try await withLock {
            let migrations = try self.source.load()
            let journal = try await self.readJournal()

            var marked: [Migration] = []
            for migration in migrations {
                guard let migrationVersion = migration.version,
                      migrationVersion <= version,
                      journal[migration.identifier] == nil
                else { continue }
                try await self.record(migration, replacing: false)
                marked.append(migration)
            }
            return marked
        }
    }

    /// Refuses when an applied migration's file has changed.
    ///
    /// Repeatable migrations are exempt: a changed file is how you edit a view,
    /// and re-applying it is the whole mechanism.
    private func verify(_ migrations: [Migration], against journal: [String: Record]) throws {
        guard configuration.verifyChecksums else { return }
        for migration in migrations where !migration.isRepeatable {
            guard let record = journal[migration.identifier], !record.checksum.isEmpty,
                  record.checksum != migration.checksum
            else { continue }
            throw MigrationError(
                version: migration.version, name: migration.name,
                kind: .checksumMismatch(recorded: record.checksum, current: migration.checksum),
                underlying: nil
            )
        }
    }

    /// Runs one migration's statements and updates the journal.
    ///
    /// The transaction is used only where it can actually help. On a database
    /// with non-transactional DDL, wrapping the statements would produce a
    /// migrator that *reports* atomicity it does not have — so instead nothing
    /// is wrapped and a failure says plainly that earlier statements are already
    /// committed. An honest error beats a false guarantee.
    /// What to do to the journal once the statements have run.
    enum JournalAction {
        case record(replacing: Bool)
        case erase
    }

    private func apply(
        _ migration: Migration, body: Migration.Body, recording: JournalAction
    ) async throws {
        let wrap = migration.usesTransaction && dialect.hasTransactionalDDL

        if wrap { _ = try await executor.executeUpdate(sql: "BEGIN", bindings: []) }

        switch body {
        case .sql(let statements):
            for (index, statement) in statements.enumerated() {
                do {
                    if migration.isOnline, let alter = OnlineAlter.parse(statement) {
                        guard let runner = onlineRunner else {
                            throw MigrationError(
                                version: migration.version, name: migration.name,
                                kind: .onlineUnavailable(statement: statement), underlying: nil
                            )
                        }
                        try await runner.run(table: alter.table, alterClause: alter.clause)
                    } else {
                        _ = try await executor.executeUpdate(sql: statement, bindings: [])
                    }
                } catch let error as MigrationError {
                    throw error
                } catch {
                    if wrap {
                        _ = try? await executor.executeUpdate(sql: "ROLLBACK", bindings: [])
                    }
                    throw MigrationError(
                        version: migration.version, name: migration.name,
                        kind: .statementFailed(
                            statementIndex: index, statement: statement,
                            partiallyApplied: !wrap && index > 0
                        ),
                        underlying: error
                    )
                }
            }

        case .swift(let action):
            do {
                try await action(ExecutorContext(executor: executor))
            } catch {
                if wrap { _ = try? await executor.executeUpdate(sql: "ROLLBACK", bindings: []) }
                // A Swift migration is opaque: there is no statement index to
                // report, and no way to know how far it got. The message says
                // so rather than implying the precision the SQL path has.
                throw MigrationError(
                    version: migration.version, name: migration.name,
                    kind: .swiftMigrationFailed(partiallyApplied: !wrap),
                    underlying: error
                )
            }
        }

        do {
            switch recording {
            case .record(let replacing): try await record(migration, replacing: replacing)
            case .erase: try await erase(migration)
            }
        } catch {
            if wrap { _ = try? await executor.executeUpdate(sql: "ROLLBACK", bindings: []) }
            throw error
        }

        if wrap { _ = try await executor.executeUpdate(sql: "COMMIT", bindings: []) }
    }

    /// Writes the journal row.
    ///
    /// `replacing` covers a repeatable migration being re-applied: its row
    /// already exists and only the checksum and timestamp change. Deleting and
    /// re-inserting would work too, but a delete that succeeds followed by an
    /// insert that fails would lose the record of a migration that is in fact
    /// applied.
    private func record(_ migration: Migration, replacing: Bool) async throws {
        let quoted = dialect.identifier(configuration.journalTable)

        if replacing {
            let sql = "UPDATE \(quoted) SET checksum = \(dialect.placeholder(0)), "
                + "applied_at = CURRENT_TIMESTAMP WHERE id = \(dialect.placeholder(1))"
            _ = try await executor.executeUpdate(
                sql: sql,
                bindings: [.text(migration.checksum), .text(migration.identifier)]
            )
            return
        }

        let marks = (0..<5).map { dialect.placeholder($0) }.joined(separator: ", ")
        let sql = "INSERT INTO \(quoted) (id, version, name, kind, checksum) VALUES (\(marks))"
        _ = try await executor.executeUpdate(
            sql: sql,
            bindings: [
                .text(migration.identifier),
                migration.version.map { SQLValue.int($0) } ?? .null,
                .text(migration.name),
                .text(migration.isRepeatable ? "repeatable" : "versioned"),
                .text(migration.checksum),
            ]
        )
    }

    private func erase(_ migration: Migration) async throws {
        let quoted = dialect.identifier(configuration.journalTable)
        let sql = "DELETE FROM \(quoted) WHERE id = \(dialect.placeholder(0))"
        _ = try await executor.executeUpdate(sql: sql, bindings: [.text(migration.identifier)])
    }

    // MARK: - Locking

    /// Holds the advisory lock for the duration of `body`.
    ///
    /// Released even when `body` throws, because an advisory lock outliving a
    /// failed migration would block every subsequent deploy.
    func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await ensureJournal()

        let (acquireSQL, acquireBindings) = dialect.acquireLock(
            named: configuration.lockName, timeoutSeconds: configuration.lockTimeoutSeconds
        )

        func truthy(_ rows: [SQLRow]) -> Bool {
            rows.first?.values.first.map { value -> Bool in
                switch value {
                case .int(let raw): raw != 0
                case .bool(let raw): raw
                case .double(let raw): raw != 0
                case .text(let raw): raw == "1" || raw.lowercased() == "true" || raw == "t"
                case .null, .blob: false
                }
            } ?? false
        }

        // Retried until the timeout, because the two engines answer differently.
        // MySQL's `GET_LOCK` blocks internally and returns true on the first
        // call, so this loop runs once. Postgres's `pg_try_advisory_lock`
        // returns *immediately* — the blocking form has no timeout — so without
        // retrying here a second concurrent deploy would fail on the spot rather
        // than wait its turn, which is the whole thing the lock exists to handle.
        var acquired = truthy(try await executor.execute(sql: acquireSQL, bindings: acquireBindings))
        if !acquired {
            let deadline = ContinuousClock().now.advanced(
                by: .seconds(configuration.lockTimeoutSeconds)
            )
            while !acquired, ContinuousClock().now < deadline {
                try await Task.sleep(for: .milliseconds(200))
                acquired = truthy(
                    try await executor.execute(sql: acquireSQL, bindings: acquireBindings)
                )
            }
        }

        guard acquired else {
            throw MigrationError(
                version: nil, name: nil,
                kind: .lockTimeout(seconds: configuration.lockTimeoutSeconds), underlying: nil
            )
        }

        do {
            let result = try await body()
            let (releaseSQL, releaseBindings) = dialect.releaseLock(named: configuration.lockName)
            _ = try? await executor.execute(sql: releaseSQL, bindings: releaseBindings)
            return result
        } catch {
            let (releaseSQL, releaseBindings) = dialect.releaseLock(named: configuration.lockName)
            _ = try? await executor.execute(sql: releaseSQL, bindings: releaseBindings)
            throw error
        }
    }
}

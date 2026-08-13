import Foundation
import SwizzleCore

/// A migration written in Swift rather than SQL.
///
/// ## When this is the right tool, and when it is not
///
/// The case that genuinely needs it is a **data transformation requiring logic
/// SQL does not have**: re-encrypting a column under a new key, backfilling a
/// value that must be computed, reshaping JSON by rules that live in the
/// application.
///
/// The reason people usually reach for it is a **backfill**, and a large
/// backfill inside a migration is an anti-pattern regardless of language. It
/// holds the deploy open, cannot be throttled against replica lag, times out,
/// and cannot be resumed from where it stopped. The right shape for that is a
/// separate idempotent, resumable job — with a migration doing only the schema
/// change that makes it possible.
///
/// If you are reaching for this to move a few million rows, write the job.
///
/// ## Deliberately not a peer of the SQL path
///
/// Swift migrations share the version space, the journal, the lock and `status`
/// with SQL ones, so ordering is a single mechanism rather than two. Everything
/// else about them is worse, and knowingly so:
///
/// - **Not readable by `mysql` or `psql`.** A SQL migration can be opened and
///   applied by hand during an incident. This cannot.
/// - **Not meaningfully checksummed.** The recorded checksum covers the
///   declared version and name, not the compiled behaviour — so editing the
///   body of an applied Swift migration is undetectable, exactly the thing
///   checksums exist to catch for SQL.
/// - **Schema changes belong in SQL** — advice, not a rule. Enforcing it would
///   mean keyword-matching the SQL, which is wrong at the edges and would break
///   a temp table used during a transformation or an index dropped and recreated
///   around a bulk update. A `CREATE TABLE` issued from here is allowed; it just
///   gives up the readable, reviewable, hand-appliable property that motivated
///   the file format.
///
/// ```swift
/// struct BackfillSlugs: SwiftMigration {
///     static let version: Int64 = 20_240_615_120_000
///     static let name = "backfill_slugs"
///
///     func up(_ db: some MigrationContext) async throws {
///         try await db.batches(over: "users", selecting: "id, title") { rows in
///             for row in rows {
///                 let id = row.values[0]
///                 let slug = slugify(/* … */)
///                 try await db.executeUpdate(
///                     "UPDATE users SET slug = ? WHERE id = ?", [.text(slug), id]
///                 )
///             }
///         }
///     }
/// }
/// ```
public protocol SwiftMigration: Sendable {
    /// Shares the numbering with `<version>_<name>.sql` files, so a Swift
    /// migration and a SQL one cannot claim the same slot.
    static var version: Int64 { get }
    static var name: String { get }

    func up(_ database: some MigrationContext) async throws

    /// Reverting. The default is to refuse, which matches a SQL migration with
    /// no `Down` section: most data transformations genuinely cannot be undone,
    /// and a `down` that pretends otherwise is worse than admitting it.
    func down(_ database: some MigrationContext) async throws
}

extension SwiftMigration {
    public func down(_ database: some MigrationContext) async throws {
        throw MigrationError(
            version: Self.version, name: Self.name, kind: .irreversible, underlying: nil
        )
    }

    /// Whether the type overrides `down`.
    ///
    /// Swift gives no way to ask, so it is declared: a migration that can be
    /// reverted says so by conforming to ``ReversibleSwiftMigration``.
    static var declaresDown: Bool { self is any ReversibleSwiftMigration.Type }
}

/// A Swift migration that really can be reverted.
///
/// Separate protocol rather than a flag because `down` having a default
/// implementation makes "did you write one?" unanswerable at runtime — and
/// silently doing nothing on `down` would be the worst outcome of the three.
public protocol ReversibleSwiftMigration: SwiftMigration {}

// MARK: - Context

/// What a Swift migration is handed.
///
/// Narrower than the full executor on purpose: a migration should run
/// statements, not open its own connections or start its own transactions. It
/// is already inside the migrator's lock.
public protocol MigrationContext: Sendable {
    @discardableResult
    func execute(_ sql: String, _ bindings: [SQLValue]) async throws -> [SQLRow]

    @discardableResult
    func executeUpdate(_ sql: String, _ bindings: [SQLValue]) async throws -> Int
}

extension MigrationContext {
    @discardableResult
    public func execute(_ sql: String) async throws -> [SQLRow] {
        try await execute(sql, [])
    }

    @discardableResult
    public func executeUpdate(_ sql: String) async throws -> Int {
        try await executeUpdate(sql, [])
    }
}

/// Wraps an executor for the duration of one migration.
struct ExecutorContext: MigrationContext {
    let executor: AnySQLExecutor

    @discardableResult
    func execute(_ sql: String, _ bindings: [SQLValue]) async throws -> [SQLRow] {
        try await executor.execute(sql: sql, bindings: bindings)
    }

    @discardableResult
    func executeUpdate(_ sql: String, _ bindings: [SQLValue]) async throws -> Int {
        try await executor.executeUpdate(sql: sql, bindings: bindings)
    }
}

// MARK: - Batching

extension MigrationContext {

    /// Walks a table in batches, by key rather than by offset.
    ///
    /// The known failure mode of a code migration is an unbounded
    /// `SELECT * FROM users`, so this is the shape that is offered.
    ///
    /// Keyset pagination — `WHERE key > ? ORDER BY key LIMIT n` — rather than
    /// `LIMIT n OFFSET m`, because offset makes the database walk and discard
    /// every skipped row: the last batch of a ten-million-row table costs ten
    /// million rows of work. Keyset stays flat, and it does not lose or repeat
    /// rows when the table is written to while the walk is in progress.
    ///
    /// The key must be unique, ordered, and the **first** column in
    /// `selecting` — an auto-increment primary key is the usual choice.
    ///
    /// `selecting` has no default on purpose. It used to default to `*`, which
    /// silently contradicted that rule: `SQLRow` carries no column names, so the
    /// cursor is read from column 0, and with `*` column 0 is whatever the table
    /// happens to declare first. A table written `(title, id)` would take its
    /// cursor from `title` and then run `WHERE id > '<some title>'` — wrong rows,
    /// possibly forever. Requiring the column list makes "put the key first"
    /// something the caller can actually act on.
    ///
    /// This still does not make a large backfill a good migration; see
    /// ``SwiftMigration``. It makes an unavoidable one survivable.
    public func batches(
        over table: String,
        selecting columns: String,
        where condition: String? = nil,
        keyColumn: String = "id",
        size: Int = 1_000,
        _ body: ([SQLRow]) async throws -> Void
    ) async throws {
        guard size > 0 else {
            throw MigrationContextError("batch size must be positive, got \(size)")
        }
        try Self.checkKeyIsFirst(columns, keyColumn)

        var cursor: SQLValue = .int(Int64.min)
        var isFirstBatch = true

        while true {
            let filter = condition.map { "(\($0)) AND " } ?? ""
            // The first batch has no lower bound, so a key column that is not an
            // integer — a UUID, a string — still starts from the beginning
            // rather than from a sentinel that means nothing in its type.
            let bound = isFirstBatch ? "" : "\(filter)\(keyColumn) > ? "
            let clause = isFirstBatch
                ? (condition.map { "WHERE \($0) " } ?? "")
                : "WHERE \(bound)"

            let sql = "SELECT \(columns) FROM \(table) \(clause)"
                + "ORDER BY \(keyColumn) LIMIT \(size)"
            let rows = try await execute(sql, isFirstBatch ? [] : [cursor])

            guard !rows.isEmpty else { return }
            try await body(rows)

            guard rows.count == size, let last = rows.last?.values.first else { return }
            cursor = last
            isFirstBatch = false
        }
    }

    /// Refuses when the key is demonstrably not the first selected column.
    ///
    /// **Throws rather than traps.** This began as a `precondition`, which is
    /// wrong for a library: a migration that names the wrong column would take
    /// the entire host process down with a trap instead of failing the migration
    /// the caller could have caught, logged and reported. The consequence of the
    /// mistake — paging on the wrong column — is silent, so it is worth catching
    /// at the first call; but catching is not the same as crashing.
    ///
    /// Only refused when the first selection is a plain identifier. An
    /// expression, an alias or a `*` cannot be checked from the string, and
    /// guessing there would produce false alarms.
    static func checkKeyIsFirst(_ columns: String, _ keyColumn: String) throws {
        guard let first = columns.split(separator: ",").first?
            .trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty
        else { return }

        let isPlainIdentifier = !first.contains(" ") && !first.contains("(")
            && !first.contains("*")
        guard isPlainIdentifier else { return }

        // `posts.id` and `id` both name the key.
        let bare = first.split(separator: ".").last.map(String.init) ?? first
        let key = keyColumn.split(separator: ".").last.map(String.init) ?? keyColumn

        guard bare.lowercased() == key.lowercased() else {
            throw MigrationContextError(
                "batches(over:) pages on the first selected column, but '\(first)' is "
                + "selected first and the key is '\(keyColumn)'. Put the key first, "
                + "or pass keyColumn: \"\(bare)\"."
            )
        }
    }
}

// MARK: - Source

/// Swift migrations as a ``MigrationSource``.
///
/// ```swift
/// let source = CombinedMigrations([
///     MigrationDirectory(path: "migrations", syntax: .mysql),
///     SwiftMigrations([BackfillSlugs(), ReEncryptTokens()]),
/// ])
/// ```
public struct SwiftMigrations: MigrationSource {
    let migrations: [Migration]

    public init(_ migrations: [any SwiftMigration]) {
        self.migrations = migrations.map { migration in
            let type = Swift.type(of: migration)

            // The checksum covers the declared identity, not the body — a
            // closure cannot be hashed and recompiling would change it anyway.
            // Stated here rather than hidden: editing an applied Swift
            // migration is undetectable, which is exactly what checksums catch
            // for SQL.
            let identity = "swift:\(type.version):\(type.name)"

            return Migration(
                kind: .versioned(type.version),
                name: type.name,
                up: .swift { try await migration.up($0) },
                down: type.declaresDown ? .swift { try await migration.down($0) } : nil,
                checksum: Checksum.of(identity)
            )
        }
    }

    public func load() throws -> [Migration] { migrations }
}

/// Several sources as one, ordered together.
///
/// This is what makes the version space shared: a Swift migration at 5 and a SQL
/// migration at 6 run in that order, from one journal, under one lock — rather
/// than two tools each with their own idea of what has been applied.
public struct CombinedMigrations: MigrationSource {
    let sources: [any MigrationSource]

    public init(_ sources: [any MigrationSource]) {
        self.sources = sources
    }

    public func load() throws -> [Migration] {
        var all: [Migration] = []
        for source in sources {
            all.append(contentsOf: try source.load())
        }
        // Two migrations claiming one version is exactly the mistake sharing the
        // space is meant to prevent, so it is caught rather than resolved by
        // source order.
        return try Migration.validated(all)
    }
}
/// A Swift migration used the context wrongly.
///
/// A thrown error rather than a trap, so a mistake fails the migration the
/// caller can handle rather than the process they cannot.
public struct MigrationContextError: Error, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

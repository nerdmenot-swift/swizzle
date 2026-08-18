import Foundation
import NIOCore
import SwizzleCore
import SwizzleMySQL

/// A zero-downtime `ALTER TABLE`, driven by the binlog.
///
/// ## Why this exists at all
///
/// MySQL's own online DDL is not reliably online: many `ALTER`s still copy the
/// whole table while holding it, and on a large table that is an outage. The
/// established answer is a shadow-table copy — GitHub's gh-ost and Percona's
/// pt-online-schema-change — and every migration tool that offers it shells out
/// to one of those.
///
/// The two differ in how they keep the shadow in sync. pt-osc installs
/// **triggers** on the original table, which adds write latency to every
/// statement and escalates locks on a busy primary. gh-ost instead reads the
/// **binary log**, so the original table is untouched and the copy costs the
/// primary nothing but the reads.
///
/// Swizzle already ships a production binlog client with backpressure, GTIDs and
/// row-event decoding — so the gh-ost approach is available to us directly
/// rather than as a subprocess. That is the entire reason this is worth
/// building here.
///
/// ## How it works
///
/// 1. Create `_<table>_gho` with the original's definition and apply the `ALTER`
///    to it. The original is untouched throughout.
/// 2. Note the binlog position, and start streaming from it.
/// 3. Copy rows in chunks, ordered by primary key, with `INSERT IGNORE` — so a
///    row the binlog already delivered in its newer form is not overwritten by
///    the stale copy.
/// 4. Concurrently apply the original's row events to the ghost, so it keeps up
///    with writes that land during the copy.
/// 5. Cut over: take a write lock, queue the `RENAME` behind it, let the applier
///    drain, then release. The rename is the first thing to run after the lock,
///    which is what makes the swap atomic rather than merely quick.
///
/// ## What this does not do
///
/// Stated plainly, because an online-DDL tool that overstates its coverage is
/// dangerous:
///
/// - **Single-column primary key only.** The chunked copy and the change applier
///   both key on it. A composite key is possible and not implemented.
/// - **No foreign keys** referencing or on the table. The rename would leave
///   them pointing at the old table.
/// - **Requires `binlog_format = ROW`** and binlog access, which is the same
///   requirement gh-ost has.
/// - **Renames are not supported.** A renamed column cannot be matched between
///   original and ghost by name, so its data would be dropped silently. Refused
///   rather than guessed at.
/// - Row copy is throttled by chunk size and an optional pause, not by measured
///   replica lag.
public struct MySQLOnlineDDL: Sendable {

    public struct Configuration: Sendable {
        /// Rows per copy chunk. Larger is faster and holds row locks longer.
        public var chunkSize: Int = 1_000
        /// Pause between chunks, to leave the primary room for real work.
        public var pauseBetweenChunks: Duration = .milliseconds(20)
        /// Server id for the binlog connection. Must not collide with a real
        /// replica or the primary will disconnect one of them.
        public var serverID: UInt32 = 9_000_042
        /// Suffix for the shadow table.
        public var ghostSuffix: String = "_gho"
        /// Suffix for the original after cutover. Kept rather than dropped: it
        /// is the only copy of the pre-migration data, and dropping it
        /// automatically would make a mistake unrecoverable.
        public var retiredSuffix: String = "_del"
        /// Absolute ceiling on the drain, so a pathologically busy primary cannot
        /// hold the write lock indefinitely.
        ///
        /// Raise this when a migration is abandoned while still making progress.
        /// The error says which case you are in rather than leaving you to guess.
        public var cutoverTimeout: Duration = .seconds(30)


        public init() {}
    }

    /// Opens a new connection. Online DDL needs several: the binlog stream owns
    /// one for its whole life, the copy uses another, and cutover needs a third
    /// to hold a lock while a fourth runs the rename.
    public typealias ConnectionFactory = @Sendable () async throws -> MySQLConnection

    let connect: ConnectionFactory
    public var configuration: Configuration
    /// Called with progress, so a CLI can show something during a long copy.
    public var onProgress: (@Sendable (Progress) -> Void)?

    public struct Progress: Sendable {
        public var copiedRows: Int
        public var appliedEvents: Int
        public var phase: String
    }

    public init(
        connect: @escaping ConnectionFactory,
        configuration: Configuration = Configuration(),
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) {
        self.connect = connect
        self.configuration = configuration
        self.onProgress = onProgress
    }

    // MARK: - Entry point

    /// Applies `alterClause` to `table` without holding it.
    ///
    /// `alterClause` is the part after `ALTER TABLE <name>` — for example
    /// `ADD COLUMN nickname VARCHAR(64)`.
    public func alter(table: String, _ alterClause: String) async throws {
        let control = try await connect()
        defer { control.closeImmediately() }

        let plan = try await preflight(control, table: table, alterClause: alterClause)
        report("preparing")

        try await createGhost(control, plan: plan, alterClause: alterClause)

        do {
            // The copy, the applier and the cutover are one operation: the
            // cutover has to happen while the applier is still running, so it
            // lives inside `copyAndSync` rather than after it.
            try await copyAndSync(plan: plan)
            report("done")
        } catch {
            // The ghost is left behind on failure. Dropping it here would
            // destroy the evidence of what went wrong, and it costs only disk.
            throw error
        }
    }

    func report(_ phase: String, copied: Int = 0, applied: Int = 0) {
        onProgress?(Progress(copiedRows: copied, appliedEvents: applied, phase: phase))
    }

    // MARK: - Preflight

    struct Plan: Sendable {
        let database: String
        let table: String
        let ghost: String
        let retired: String
        /// A tiny table the tool writes to so there is always an event to track.
        let changelog: String
        /// Columns of the original, in ordinal order — which is the order binlog
        /// row images arrive in.
        let originalColumns: [String]
        /// Columns present in both, so the copy and the applier agree.
        var sharedColumns: [String] = []
        let primaryKey: String
        /// Position of the primary key within `originalColumns`, for reading it
        /// out of a row image.
        let primaryKeyIndex: Int
    }

    func preflight(
        _ connection: MySQLConnection, table: String, alterClause: String
    ) async throws -> Plan {
        // ROW format is the whole basis of the approach: STATEMENT format gives
        // the SQL text rather than the changed rows, which cannot be replayed
        // into a table with a different shape.
        let format = try await connection.executeFirst(
            "SELECT @@binlog_format", as: String.self
        )
        guard format?.uppercased() == "ROW" else {
            throw OnlineDDLError.notSupported(
                "binlog_format is \(format ?? "unknown"), and online DDL needs ROW — "
                + "the copy replays changed rows, which STATEMENT format does not carry"
            )
        }

        guard let database = try await connection.executeFirst(
            "SELECT DATABASE()", as: String.self
        ), !database.isEmpty else {
            throw OnlineDDLError.notSupported("no database selected")
        }

        let originalColumns = try await connection.execute(
            MySQLQuery(
                unsafeSQL: """
                    SELECT column_name FROM information_schema.columns
                    WHERE table_schema = ? AND table_name = ? ORDER BY ordinal_position
                    """,
                binds: [.bytes(Array(database.utf8)), .bytes(Array(table.utf8))]
            ),
            as: String.self
        )
        guard !originalColumns.isEmpty else {
            throw OnlineDDLError.notSupported("table `\(table)` does not exist")
        }

        // A single-column primary key is what both the chunked copy and the
        // change applier key on.
        let keyColumns = try await connection.execute(
            MySQLQuery(
                unsafeSQL: """
                    SELECT column_name FROM information_schema.statistics
                    WHERE table_schema = ? AND table_name = ? AND index_name = 'PRIMARY'
                    ORDER BY seq_in_index
                    """,
                binds: [.bytes(Array(database.utf8)), .bytes(Array(table.utf8))]
            ),
            as: String.self
        )
        guard keyColumns.count == 1, let primaryKey = keyColumns.first else {
            throw OnlineDDLError.notSupported(
                keyColumns.isEmpty
                    ? "`\(table)` has no primary key, so rows cannot be copied in a stable "
                        + "order or matched when replaying changes"
                    : "`\(table)` has a composite primary key, which is not implemented"
            )
        }

        let foreignKeys = try await connection.executeFirst(
            MySQLQuery(
                unsafeSQL: """
                    SELECT COUNT(*) FROM information_schema.key_column_usage
                    WHERE referenced_table_schema IS NOT NULL
                      AND ((table_schema = ? AND table_name = ?)
                        OR (referenced_table_schema = ? AND referenced_table_name = ?))
                    """,
                binds: [
                    .bytes(Array(database.utf8)), .bytes(Array(table.utf8)),
                    .bytes(Array(database.utf8)), .bytes(Array(table.utf8)),
                ]
            ),
            as: Int.self
        )
        guard foreignKeys == 0 else {
            throw OnlineDDLError.notSupported(
                "`\(table)` is involved in a foreign key — the rename at cutover would "
                + "leave the constraint pointing at the retired table"
            )
        }

        // A rename cannot be matched between original and ghost by name, so the
        // column's data would silently vanish. Refused rather than guessed.
        let upper = alterClause.uppercased()
        if upper.contains("RENAME COLUMN") || upper.contains("CHANGE COLUMN")
            || upper.hasPrefix("CHANGE ") {
            throw OnlineDDLError.notSupported(
                "renaming a column is not supported online — the copy matches columns by "
                + "name, so a renamed one would be left empty"
            )
        }

        guard let keyIndex = originalColumns.firstIndex(of: primaryKey) else {
            throw OnlineDDLError.notSupported("primary key `\(primaryKey)` is not a column")
        }

        return Plan(
            database: database,
            table: table,
            ghost: "_\(table)\(configuration.ghostSuffix)",
            retired: "_\(table)\(configuration.retiredSuffix)",
            changelog: "_\(table)_ghc",
            originalColumns: originalColumns,
            primaryKey: primaryKey,
            primaryKeyIndex: keyIndex
        )
    }

    // MARK: - Ghost table

    func createGhost(
        _ connection: MySQLConnection, plan: Plan, alterClause: String
    ) async throws {
        _ = try await connection.query("DROP TABLE IF EXISTS `\(plan.ghost)`")
        _ = try await connection.query(
            "CREATE TABLE `\(plan.ghost)` LIKE `\(plan.table)`")
        _ = try await connection.query(
            "ALTER TABLE `\(plan.ghost)` \(alterClause)")

        // The changelog exists only to generate binlog events on demand. Cutover
        // cannot wait on "has the applier reached binlog position P" because on
        // an idle table no events arrive at all and the applier sits at zero
        // forever — which is exactly how the empty-table case hung.
        _ = try await connection.query("DROP TABLE IF EXISTS `\(plan.changelog)`")
        _ = try await connection.query(
            """
            CREATE TABLE `\(plan.changelog)` (
                id BIGINT AUTO_INCREMENT PRIMARY KEY,
                marker VARCHAR(64) NOT NULL
            ) ENGINE=InnoDB
            """)
    }

    /// Columns the two tables have in common, in the original's order.
    ///
    /// A dropped column is simply absent; an added one is left to its default.
    func sharedColumns(
        _ connection: MySQLConnection, plan: Plan
    ) async throws -> [String] {
        let ghostColumns = Set(
            try await connection.execute(
                MySQLQuery(
                    unsafeSQL: """
                        SELECT column_name FROM information_schema.columns
                        WHERE table_schema = ? AND table_name = ?
                        """,
                    binds: [
                        .bytes(Array(plan.database.utf8)), .bytes(Array(plan.ghost.utf8)),
                    ]
                ),
                as: String.self
            ).map { $0.lowercased() }
        )
        let shared = plan.originalColumns.filter { ghostColumns.contains($0.lowercased()) }
        guard shared.contains(where: { $0.lowercased() == plan.primaryKey.lowercased() }) else {
            throw OnlineDDLError.notSupported(
                "the ALTER removes the primary key `\(plan.primaryKey)`, which the copy "
                + "needs to match rows"
            )
        }
        return shared
    }
}

/// Why an online ALTER could not be run.
public enum OnlineDDLError: Error, Sendable, CustomStringConvertible {
    case notSupported(String)
    case cutoverTimedOut(String)
    case failed(String)

    public var description: String {
        switch self {
        case .notSupported(let why): "online DDL is not possible here: \(why)"
        case .cutoverTimedOut(let why): "online DDL could not cut over: \(why)"
        case .failed(let why): "online DDL failed: \(why)"
        }
    }
}

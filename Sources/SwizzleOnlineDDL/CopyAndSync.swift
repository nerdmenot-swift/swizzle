import Foundation
import NIOCore
import SwizzleCore
import SwizzleMySQL

extension MySQLOnlineDDL {

    /// Tracks how far the applier has got, so cutover knows when it is safe.
    final class ApplierState: @unchecked Sendable {
        private let lock = NSLock()
        private var _applied = 0
        private var _failure: (any Error)?
        private var _markers: Set<String> = []

        var applied: Int { lock.withLock { _applied } }
        var failure: (any Error)? { lock.withLock { _failure } }

        func record(applied: Int) {
            lock.withLock { _applied += applied }
        }

        /// A changelog row the applier has now seen. See `Cutover` for why this
        /// replaced tracking the binlog position.
        func sawMarker(_ marker: String) {
            lock.withLock { _markers.insert(marker) }
        }

        func hasSeen(_ marker: String) -> Bool {
            lock.withLock { _markers.contains(marker) }
        }

        func fail(_ error: any Error) {
            lock.withLock { if _failure == nil { _failure = error } }
        }
    }

    /// Runs the row copy and the change applier together, then waits for the
    /// applier to catch up.
    ///
    /// Concurrent on purpose: the copy of a large table takes minutes, and every
    /// write that lands in that window has to reach the ghost or it is lost. A
    /// copy-then-sync design would have to replay an ever-growing backlog and
    /// might never converge on a busy table.
    func copyAndSync(plan: Plan) async throws {
        let setup = try await connect()
        let shared = try await sharedColumns(setup, plan: plan)
        // Bound to a `let` before the task group captures it: a `var` cannot be
        // sent into a concurrently-running closure.
        var mutable = plan
        mutable.sharedColumns = shared
        let plan = mutable

        // Position is taken *before* the copy starts, so any write the copy
        // races against is also in the stream. The overlap is fine — the copy
        // uses INSERT IGNORE and the applier uses REPLACE, so the newer value
        // wins either way.
        let start = try await setup.binlogPosition()
        setup.closeImmediately()

        let state = ApplierState()

        try await withThrowingTaskGroup(of: Void.self) { group in
            let applierStop = StopFlag()

            group.addTask {
                try await self.runApplier(plan: plan, from: start, state: state, stop: applierStop)
            }

            group.addTask {
                try await self.runCopy(plan: plan, state: state)
            }

            // The copy finishes; the applier runs until cutover tells it to stop.
            // Wait for the copy task, then drain and cut over.
            try await self.waitForCopyThenCutover(
                plan: plan, state: state, stop: applierStop, group: &group
            )
        }

        if let failure = state.failure { throw failure }
    }

    /// Set by cutover to end the applier's stream.
    final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _stopped = false
        var isStopped: Bool { lock.withLock { _stopped } }
        func stop() { lock.withLock { _stopped = true } }
    }

    // MARK: - Applier

    /// Streams the original table's row events and replays them into the ghost.
    ///
    /// This is the part only we can do without triggers: the events come from
    /// the binlog, so the original table carries no write-path overhead at all.
    func runApplier(
        plan: Plan, from start: (filename: String, position: UInt32),
        state: ApplierState, stop: StopFlag
    ) async throws {
        let connection = try await connect()
        defer { connection.closeImmediately() }
        let writer = try await connect()
        defer { writer.closeImmediately() }

        let events = try await connection.startBinlogStream(
            serverID: configuration.serverID,
            from: .file(name: start.filename, position: start.position)
        )

        do {
            for try await event in events {
                if stop.isStopped { break }
                guard case .rows(let rows) = event.payload,
                      rows.table.schema == plan.database
                else { continue }

                // A changelog write is how cutover learns the applier has caught
                // up. It carries no data of its own.
                if rows.table.table == plan.changelog, rows.kind == .write {
                    for row in rows.rows where row.count > 1 {
                        if let marker = row[1].string { state.sawMarker(marker) }
                    }
                    continue
                }

                guard rows.table.table == plan.table else { continue }
                let count = try await apply(rows, plan: plan, using: writer)
                state.record(applied: count)
            }
        } catch is CancellationError {
            // Ending the stream is how the applier is stopped; not a failure.
        } catch {
            state.fail(error)
            throw error
        }
    }

    /// Replays one row event into the ghost table.
    func apply(
        _ event: MySQLRowsEvent, plan: Plan, using connection: MySQLConnection
    ) async throws -> Int {
        // Row images are positional against the original's columns, so the
        // shared-column projection is by index.
        let indexes = plan.sharedColumns.compactMap { plan.originalColumns.firstIndex(of: $0) }
        let columnList = plan.sharedColumns.map { "`\($0)`" }.joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: indexes.count).joined(separator: ", ")

        func project(_ row: [MySQLValue]) -> [MySQLValue] {
            indexes.compactMap { $0 < row.count ? row[$0] : nil }
        }
        func key(_ row: [MySQLValue]) -> MySQLValue? {
            plan.primaryKeyIndex < row.count ? row[plan.primaryKeyIndex] : nil
        }

        var applied = 0
        switch event.kind {
        case .write:
            for row in event.rows {
                // REPLACE rather than INSERT: the copy may already have put a
                // row with this key there, and the binlog is the newer truth.
                _ = try await connection.query(
                    "REPLACE INTO `\(plan.ghost)` (\(columnList)) VALUES (\(placeholders))",
                    project(row)
                )
                applied += 1
            }

        case .delete:
            for row in event.rows {
                guard let id = key(row) else { continue }
                _ = try await connection.query(
                    "DELETE FROM `\(plan.ghost)` WHERE `\(plan.primaryKey)` = ?", [id]
                )
                applied += 1
            }

        case .update:
            // The key may itself have changed, so the old row is removed by its
            // old key before the new one is written.
            for (index, after) in event.updatedRows.enumerated() {
                if index < event.rows.count, let oldKey = key(event.rows[index]),
                   let newKey = key(after), oldKey != newKey {
                    _ = try await connection.query(
                        "DELETE FROM `\(plan.ghost)` WHERE `\(plan.primaryKey)` = ?", [oldKey]
                    )
                }
                _ = try await connection.query(
                    "REPLACE INTO `\(plan.ghost)` (\(columnList)) VALUES (\(placeholders))",
                    project(after)
                )
                applied += 1
            }
        }
        return applied
    }

    // MARK: - Copy

    /// Copies existing rows in chunks, ordered by primary key.
    ///
    /// `INSERT IGNORE` is the load-bearing detail. The applier may already have
    /// written a newer version of a row that this chunk is about to copy in its
    /// original form; `IGNORE` makes the copy yield to it. The reverse ordering
    /// is safe too, because the applier uses `REPLACE`.
    ///
    /// ## Why the boundary is chosen *before* the copy
    ///
    /// The obvious order — copy `LIMIT n` rows, then ask where they ended — has a
    /// race that silently loses rows, and it shipped that way.
    ///
    /// Both statements read the *live* table, and each applies its own
    /// `LIMIT n`. Delete a row from the range between them and the second
    /// window reaches one row **further** than the first actually copied: the
    /// cursor advances past a row nothing ever inserted into the ghost, and no
    /// later chunk goes back for it. The applier does not save it either, because
    /// nothing happened to that row — it was simply never read.
    ///
    /// It cost one row per delete that landed in the gap, so it stayed invisible
    /// under light concurrency and failed roughly one run in three under the
    /// interleaving test. Naming the range first makes the copy and the cursor
    /// agree by construction: this chunk is exactly `(cursor, boundary]`,
    /// whatever happens to the table meanwhile. Rows deleted from that range are
    /// gone from both sides; rows inserted into it are picked up by the copy or
    /// by the applier, and `INSERT IGNORE`/`REPLACE` make either order safe.
    ///
    /// This is what gh-ost does, and now it is clear why.
    func runCopy(plan: Plan, state: ApplierState) async throws {
        let connection = try await connect()
        defer { connection.closeImmediately() }

        let columnList = plan.sharedColumns.map { "`\($0)`" }.joined(separator: ", ")
        var cursor: MySQLValue?
        var copied = 0

        while true {
            // 1. Name the range this chunk will cover.
            let boundary = try await connection.query(
                cursor == nil
                    ? "SELECT MAX(`\(plan.primaryKey)`) FROM (SELECT `\(plan.primaryKey)` "
                        + "FROM `\(plan.table)` ORDER BY `\(plan.primaryKey)` "
                        + "LIMIT \(configuration.chunkSize)) t"
                    : "SELECT MAX(`\(plan.primaryKey)`) FROM (SELECT `\(plan.primaryKey)` "
                        + "FROM `\(plan.table)` WHERE `\(plan.primaryKey)` > ? "
                        + "ORDER BY `\(plan.primaryKey)` LIMIT \(configuration.chunkSize)) t",
                cursor.map { [$0] } ?? []
            )
            guard let next = boundary.rows.first?[0], !next.isNull else { break }

            // 2. Copy exactly that range — no LIMIT, so the rows copied and the
            //    cursor's new position cannot disagree.
            let sql: String
            let binds: [MySQLValue]
            if let cursor {
                sql = """
                    INSERT IGNORE INTO `\(plan.ghost)` (\(columnList))
                    SELECT \(columnList) FROM `\(plan.table)`
                    WHERE `\(plan.primaryKey)` > ? AND `\(plan.primaryKey)` <= ?
                    """
                binds = [cursor, next]
            } else {
                sql = """
                    INSERT IGNORE INTO `\(plan.ghost)` (\(columnList))
                    SELECT \(columnList) FROM `\(plan.table)`
                    WHERE `\(plan.primaryKey)` <= ?
                    """
                binds = [next]
            }
            _ = try await connection.query(sql, binds)

            cursor = next
            copied += configuration.chunkSize
            report("copying", copied: copied, applied: state.applied)

            if configuration.pauseBetweenChunks > .zero {
                try await Task.sleep(for: configuration.pauseBetweenChunks)
            }
        }
        report("copied", copied: copied, applied: state.applied)
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

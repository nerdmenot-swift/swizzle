import Foundation
import NIOCore
import SwizzleCore
import SwizzleMySQL

extension MySQLOnlineDDL {

    /// Waits for the copy, drains the applier, and swaps the tables.
    func waitForCopyThenCutover(
        plan: Plan, state: ApplierState, stop: StopFlag,
        group: inout ThrowingTaskGroup<Void, any Error>
    ) async throws {
        // The group holds the applier and the copy. The applier does not finish
        // on its own — it streams until told to stop — so the first task to
        // complete is the copy.
        try await group.next()
        if let failure = state.failure { throw failure }

        try await cutover(plan: plan, state: state)

        // Ending the applier needs care: it is blocked awaiting the next event,
        // and on an idle server none may ever come. Setting the flag and then
        // writing one more changelog row wakes it so it can notice and return,
        // rather than being cancelled out of a blocking read.
        stop.stop()
        let waker = try await connect()
        _ = try? await waker.query(
            "INSERT INTO `\(plan.changelog)` (marker) VALUES ('stop')")
        waker.closeImmediately()

        // If it still has not returned — a stream that saw nothing at all —
        // cancellation is the fallback, and the applier treats that as a normal
        // end rather than an error.
        group.cancelAll()
        while (try? await group.next()) != nil {}
    }

    /// Swaps the ghost into place.
    ///
    /// The obvious implementation — wait for the applier to catch up, then
    /// `RENAME` — has a window: every write between the check and the rename
    /// lands in the original table and is lost. On a busy table that window is
    /// small and non-empty, which is the worst kind of bug.
    ///
    /// So the swap borrows gh-ost's ordering trick:
    ///
    /// 1. One connection takes `LOCK TABLES … WRITE`. Writers now block.
    /// 2. A second connection issues the `RENAME`, which blocks behind that lock
    ///    but is now **queued ahead of** every write that arrives afterwards.
    /// 3. The applier drains what was already committed.
    /// 4. The lock is released, and the rename is the first thing to run.
    ///
    /// No write can slip between the drain and the swap, because from step 1
    /// onwards no write runs at all, and from step 2 onwards the rename is ahead
    /// of them in the queue.
    func cutover(plan: Plan, state: ApplierState) async throws {
        let locker = try await connect()
        defer { locker.closeImmediately() }
        let renamer = try await connect()
        defer { renamer.closeImmediately() }
        let marking = try await connect()
        defer { marking.closeImmediately() }

        // 1. Block writers. The changelog is locked alongside the original
        //    because `LOCK TABLES` restricts the session to the tables it named,
        //    and the marker below has to be written from a *different* session
        //    anyway — this just keeps the two consistent.
        _ = try await locker.query("LOCK TABLES `\(plan.table)` WRITE")

        // 2. Queue the rename behind the lock. It cannot be awaited here — it
        //    blocks until the lock is released — so it runs detached and is
        //    joined after the unlock.
        let rename = Task {
            try await renamer.query(
                "RENAME TABLE `\(plan.table)` TO `\(plan.retired)`, "
                + "`\(plan.ghost)` TO `\(plan.table)`"
            )
        }

        // Give the rename a moment to reach the server and enqueue. Releasing
        // the lock before it arrives would let a waiting writer in first, which
        // is the race this whole dance exists to avoid.
        try await Task.sleep(for: .milliseconds(100))

        do {
            // 3. Drain. The marker is written *after* writers are blocked, so
            //    every change to the original is already ahead of it in the
            //    binlog. When the applier reports seeing it, everything before
            //    it has been applied.
            //
            //    This replaced comparing binlog positions, which could not work:
            //    on a table nobody is writing to, no events arrive and the
            //    applier's position never moves, so the wait could only ever
            //    time out.
            let marker = "cutover-\(UInt64.random(in: 0..<UInt64.max))"
            _ = try await marking.query(
                "INSERT INTO `\(plan.changelog)` (marker) VALUES (?)",
                [.bytes(Array(marker.utf8))]
            )
            try await waitForApplier(state, toSee: marker, plan: plan)
        } catch {
            rename.cancel()
            _ = try? await locker.query("UNLOCK TABLES")
            throw error
        }

        // 4. Release; the rename runs first.
        _ = try await locker.query("UNLOCK TABLES")

        do {
            _ = try await rename.value
        } catch {
            throw OnlineDDLError.failed("the rename did not complete: \(error)")
        }

        _ = try? await marking.query("DROP TABLE IF EXISTS `\(plan.changelog)`")
    }

    /// Blocks until the applier has replayed everything committed before cutover.
    private func waitForApplier(
        _ state: ApplierState, toSee marker: String, plan: Plan
    ) async throws {
        let deadline = ContinuousClock().now.advanced(by: configuration.cutoverTimeout)

        while ContinuousClock().now < deadline {
            if let failure = state.failure { throw failure }
            if state.hasSeen(marker) { return }
            report("draining", copied: 0, applied: state.applied)
            try await Task.sleep(for: .milliseconds(20))
        }

        throw OnlineDDLError.cutoverTimedOut(
            "the change applier did not reach the cutover marker within "
            + "\(configuration.cutoverTimeout). The original table is untouched and the "
            + "ghost `\(plan.ghost)` is left in place; nothing was swapped."
        )
    }
}

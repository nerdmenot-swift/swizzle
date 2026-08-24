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

        try await cutover(plan: plan, state: state, stop: stop)

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
    func cutover(plan: Plan, state: ApplierState, stop: StopFlag) async throws {
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

        let marker = "cutover-\(UInt64.random(in: 0..<UInt64.max))"
        do {
            // 2. Drain, **before the rename is queued**, and that order is the
            //    whole of a deadlock this used to hit.
            //
            //    The rename covers the ghost table, so once it is queued it holds
            //    a metadata lock request over it. The applier's entire job during
            //    the drain is writing pending row changes *into* the ghost — so
            //    those writes queued behind the pending rename, the rename waited
            //    for the unlock, and the unlock waited for the drain. Nothing
            //    could move.
            //
            //    It presented as a slow applier and it is not one: at a 30-second
            //    timeout it read 1079 binlog events, and at 120 seconds it read
            //    1071. Four times the patience, no further progress — which is a
            //    stall, and the reason raising the timeout was the wrong fix.
            //    It only fires when there is something to apply, which is why the
            //    one test that writes during the copy was the one that failed.
            //
            //    Draining first is safe because writers are already blocked by the
            //    lock above: no new changes can arrive while this runs, so the
            //    applier only has to catch up on what is already in the binlog.
            _ = try await marking.query(
                "INSERT INTO `\(plan.changelog)` (marker) VALUES (?)",
                [.bytes(Array(marker.utf8))]
            )
            try await waitForApplier(state, toSee: marker, plan: plan)

            // Caught up, so it is done: writers are blocked, nothing new can arrive,
            // and everything before the marker is already in the ghost.
            //
            // Stopping it here rather than after the swap closes a window the
            // reordering above opened. With the rename queued last, the applier was
            // still consuming while the swap landed — and an event for the original
            // table arriving after it becomes a REPLACE into a ghost that no longer
            // exists, which surfaced in CI as
            // `Table 'swizzle_test._ddl_..._gho' doesn't exist`.
            stop.stop()
        } catch {
            _ = try? await locker.query("UNLOCK TABLES")
            throw error
        }

        // 3. Now queue the rename behind the lock. It cannot be awaited here — it
        //    blocks until the lock is released — so it runs detached and is joined
        //    after the unlock. Queueing it while the lock is still held is what
        //    puts it ahead of every writer waiting on that lock, which is the
        //    property the whole sequence exists for.
        let rename = Task {
            try await renamer.query(
                "RENAME TABLE `\(plan.table)` TO `\(plan.retired)`, "
                + "`\(plan.ghost)` TO `\(plan.table)`"
            )
        }

        // Give the rename a moment to reach the server and enqueue. Releasing the
        // lock before it arrives would let a waiting writer in first, which is the
        // race this dance exists to avoid.
        try await Task.sleep(for: .milliseconds(100))

        // 4. Release; the rename runs first.
        _ = try await locker.query("UNLOCK TABLES")

        do {
            _ = try await rename.value
        } catch {
            rename.cancel()
            throw OnlineDDLError.failed("the rename did not complete: \(error)")
        }

        _ = try? await marking.query("DROP TABLE IF EXISTS `\(plan.changelog)`")
    }

    /// Blocks until the applier has replayed everything committed before cutover.
    ///
    /// ## Why there is no stall timeout
    ///
    /// This has been wrong twice, in opposite directions, and the second attempt
    /// is worth recording because it looked like a fix.
    ///
    /// It began as one flat deadline, which could not tell a busy applier from a
    /// dead one: `applied` counts rows written to the ghost, and an applier
    /// reading a server-wide binlog full of *other* tables' traffic is working
    /// flat out with `applied` frozen. So a "no progress" clock was added over
    /// `observed` — every event looked at, filtered or not.
    ///
    /// That fails the other way, and Linux caught it within four runs: an applier
    /// that has **caught up** also shows no progress, because there is nothing
    /// left to read. It reported an applier that had just read 1160 events as
    /// stuck, five seconds after it finished its work.
    ///
    /// There is no silence that distinguishes the two, because the signal is not
    /// in the event flow at all. What is actually known here is stronger: the
    /// marker was committed *before* this wait began, so its event exists. The
    /// applier will reach it unless the stream is broken — and a broken stream
    /// arrives as `state.failure`, or eventually as a dead connection now that
    /// the binlog socket has TCP keep-alive.
    ///
    /// So the wait is: the marker, a failure, or the ceiling. `observed` stays in
    /// the message because it is genuinely useful — "read 1160 events, applied 0"
    /// tells an operator where to look — but it is diagnosis, not a trigger.
    func waitForApplier(
        _ state: ApplierState, toSee marker: String, plan: Plan
    ) async throws {
        let clock = ContinuousClock()
        let ceiling = clock.now.advanced(by: configuration.cutoverTimeout)
        let appliedAtStart = state.applied

        while clock.now < ceiling {
            if let failure = state.failure { throw failure }
            if state.hasSeen(marker) { return }
            report("draining", copied: 0, applied: state.applied)
            try await Task.sleep(for: .milliseconds(20))
        }

        let applied = state.applied - appliedAtStart
        let observed = state.observed
        throw OnlineDDLError.cutoverTimedOut(
            "the change applier did not reach the cutover marker within "
            + "\(configuration.cutoverTimeout). It applied \(applied) change"
            + "\(applied == 1 ? "" : "s") and read \(observed) binlog event"
            + "\(observed == 1 ? "" : "s") while draining. Many events and no marker "
            + "means a backlog — retry on a quieter primary or raise cutoverTimeout; "
            + "few events means the replication stream is not delivering, which is "
            + "where to look. The original table is untouched and the ghost "
            + "`\(plan.ghost)` is left in place; nothing was swapped."
        )
    }
}

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
    ///
    /// ## Why this is not one deadline
    ///
    /// It used to be: thirty seconds from the marker, and if the applier had not
    /// arrived, give up. That measures the machine rather than the applier, in
    /// exactly the way a wall-clock assertion in a test does — and it failed on a
    /// loaded CI container while passing everywhere else, which is the signature.
    ///
    /// The two failures it was conflating want opposite responses:
    ///
    /// - **Draining a backlog.** The binlog is server-wide, so on a busy primary
    ///   the applier reads thousands of events belonging to other tables before
    ///   it reaches the marker. It is working; it simply has further to go. Cutting
    ///   it off here abandons a migration at the moment it is working hardest,
    ///   leaving a ghost table behind for a human to clean up.
    /// - **Wedged.** The stream is dead, the connection dropped, the primary
    ///   evicted the replica. No amount of waiting helps and thirty seconds is
    ///   thirty seconds of a held table lock for nothing.
    ///
    /// So the wait now watches **liveness** — events observed, not changes
    /// applied, because a backlog of other tables' traffic moves the first and
    /// not the second. Progress resets the stall clock. `cutoverTimeout` stays as
    /// an absolute ceiling so a pathologically busy server cannot hold the lock
    /// forever, and `cutoverStallTimeout` is what actually fires when something
    /// has gone wrong.
    /// Internal rather than private so the stall-versus-backlog decision can be
    /// tested directly. Staging a real wedged replica means relying on server
    /// behaviour that differs between MariaDB and MySQL versions; the decision
    /// itself is deterministic and is what actually needs proving.
    func waitForApplier(
        _ state: ApplierState, toSee marker: String, plan: Plan
    ) async throws {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let ceiling = startedAt.advanced(by: configuration.cutoverTimeout)

        let appliedAtStart = state.applied
        var lastProgressAt = startedAt
        var lastObserved = state.observed
        var lastApplied = appliedAtStart

        while true {
            if let failure = state.failure { throw failure }
            if state.hasSeen(marker) { return }

            let observed = state.observed
            let applied = state.applied
            if observed != lastObserved || applied != lastApplied {
                lastObserved = observed
                lastApplied = applied
                lastProgressAt = clock.now
            }

            let stalledFor = clock.now - lastProgressAt
            if stalledFor >= configuration.cutoverStallTimeout {
                throw OnlineDDLError.cutoverTimedOut(
                    "the change applier stopped making progress \(stalledFor) ago, "
                    + "having applied \(applied - appliedAtStart) change"
                    + "\((applied - appliedAtStart) == 1 ? "" : "s") and read \(observed) "
                    + "binlog event\(observed == 1 ? "" : "s") while draining. It is not "
                    + "behind, it is stuck — look at the replication connection rather "
                    + "than raising cutoverTimeout. The original table is untouched and "
                    + "the ghost `\(plan.ghost)` is left in place; nothing was swapped."
                )
            }
            if clock.now >= ceiling {
                throw OnlineDDLError.cutoverTimedOut(
                    "the change applier was still draining after "
                    + "\(configuration.cutoverTimeout) — it applied "
                    + "\(applied - appliedAtStart) change"
                    + "\((applied - appliedAtStart) == 1 ? "" : "s") and read \(observed) "
                    + "binlog event\(observed == 1 ? "" : "s"), and was still moving when "
                    + "the ceiling was reached. This is a backlog, not a fault: retry on a "
                    + "quieter primary or raise cutoverTimeout. The original table is "
                    + "untouched and the ghost `\(plan.ghost)` is left in place; nothing "
                    + "was swapped."
                )
            }

            report("draining", copied: 0, applied: applied)
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

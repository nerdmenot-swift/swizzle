import Foundation
import SwizzleCore
import Testing
@testable import SwizzleSQLite
@testable import SwizzleSQLiteEngine

/// The error taxonomy, exercised against a real database rather than by
/// constructing error values by hand.
///
/// Constructing them by hand would prove the switch statement compiles. Making
/// SQLite actually raise each one proves the codes are the codes SQLite really
/// sends — which is the part that would otherwise be wrong for years without
/// anybody noticing.
@Suite("SQLite error taxonomy")
struct SQLiteErrorTaxonomyTests {

    static func schema() async throws -> SQLiteConnection {
        let connection = try SQLiteConnection.inMemory()
        _ = try await connection.query(
            """
            CREATE TABLE parents (id INTEGER PRIMARY KEY, code TEXT NOT NULL UNIQUE)
            """
        )
        _ = try await connection.query(
            """
            CREATE TABLE children (
                id INTEGER PRIMARY KEY,
                parent_id INTEGER NOT NULL REFERENCES parents(id),
                score INTEGER NOT NULL CHECK (score >= 0)
            )
            """
        )
        _ = try await connection.query("INSERT INTO parents VALUES (1, 'a')")
        return connection
    }

    func kind(_ connection: SQLiteConnection, _ sql: String) async -> SQLErrorKind? {
        do {
            _ = try await connection.query(sql)
            return nil
        } catch let error as SQLDiagnosable {
            return error.sqlKind
        } catch {
            return nil
        }
    }

    /// **Corruption gets its own kind**, and this is the test that makes it more
    /// than a line in a table: a real file, really damaged, really reported.
    ///
    /// It used to land in `.other`, indistinguishable from a typo — while being
    /// the one error where retrying is pointless and the answer is a backup. All
    /// three engines could report it and all three said `.other`.
    @Test("a corrupted database file is reported as corruption")
    func corruptionIsItsOwnKind() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swizzle-corrupt-\(UInt32.random(in: 0..<UInt32.max))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("corrupt.db").path

        // A real database first, with enough rows to occupy several pages so
        // there is a B-tree to damage.
        let writer = try SQLiteConnection(path: path)
        _ = try await writer.query("PRAGMA journal_mode = DELETE")
        _ = try await writer.query("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
        for id in 1...500 {
            _ = try await writer.query(
                "INSERT INTO t VALUES (?1, ?2)", [.int(Int64(id)), .text(String(repeating: "x", count: 200))]
            )
        }
        writer.close()

        // Then damage it: overwrite the interior of the file, leaving the header
        // intact so it still opens as a database and fails on read instead.
        let handle = try FileHandle(forUpdating: URL(fileURLWithPath: path))
        try handle.seek(toOffset: 4096)
        try handle.write(contentsOf: Data(repeating: 0xFF, count: 4096))
        try handle.close()

        let reader = try SQLiteConnection(path: path)
        defer { reader.close() }
        // `PRAGMA integrity_check` reports rather than throws, so the read is a
        // plain query — the corruption has to surface as an error from stepping.
        do {
            _ = try await reader.query("SELECT count(*) FROM t")
            // Not every byte pattern breaks every page, so a clean read here is
            // not a test failure — it is a test that did not get to run.
            Issue.record("the file survived the damage; nothing was proven")
        } catch let error as SQLiteError {
            #expect(
                error.sqlKind == .dataCorrupted,
                "corruption reported as \(error.sqlKind) (code \(error.code))"
            )
        }
    }

    /// The four constraint kinds are distinguishable, which is the whole reason
    /// the extended result codes are switched on.
    @Test("each constraint failure is identified separately")
    func constraintsAreDistinguished() async throws {
        let connection = try await Self.schema()
        defer { connection.close() }

        #expect(await kind(connection, "INSERT INTO parents VALUES (2, 'a')") == .uniqueViolation)
        #expect(await kind(connection, "INSERT INTO parents VALUES (1, 'b')") == .uniqueViolation)
        #expect(
            await kind(connection, "INSERT INTO children VALUES (1, 99, 1)")
                == .foreignKeyViolation
        )
        #expect(
            await kind(connection, "INSERT INTO children VALUES (2, 1, NULL)")
                == .notNullViolation
        )
        #expect(
            await kind(connection, "INSERT INTO children VALUES (3, 1, -5)")
                == .checkViolation
        )
    }

    @Test("a statement that will not compile is a syntax error")
    func syntaxErrors() async throws {
        let connection = try await Self.schema()
        defer { connection.close() }
        #expect(await kind(connection, "SELECT * FROM nope") == .syntax)
        #expect(await kind(connection, "NOT SQL AT ALL") == .syntax)
    }

    /// SQLite is the one engine that can answer this honestly, because it is
    /// in-process: if `step` returned an error, nothing committed.
    @Test("a rejected statement definitely did not apply")
    func rejectedStatementsDidNotApply() async throws {
        let connection = try await Self.schema()
        defer { connection.close() }

        do {
            _ = try await connection.query("INSERT INTO parents VALUES (2, 'a')")
            Issue.record("expected a unique violation")
        } catch let error as SQLDiagnosable {
            #expect(error.mayHaveApplied == false)
            // And the table proves it.
            let rows = try await connection.query("SELECT COUNT(*) FROM parents")
            #expect(rows.first?.values.first == .int(1))
        }
    }

    /// The conjunction is the point. A unique violation is not transient, so it
    /// is not worth retrying however safe a retry would be.
    @Test("retry safety needs both halves")
    func retrySafetyNeedsBothHalves() async throws {
        let connection = try await Self.schema()
        defer { connection.close() }

        do {
            _ = try await connection.query("INSERT INTO parents VALUES (2, 'a')")
            Issue.record("expected a unique violation")
        } catch let error as SQLDiagnosable {
            #expect(error.mayHaveApplied == false)   // safe to repeat
            #expect(error.sqlKind.isTransient == false)  // but pointless
            #expect(error.isSafeToRetry == false)
        }
    }

    @Test("the native code survives the translation")
    func nativeCodeIsPreserved() async throws {
        let connection = try await Self.schema()
        defer { connection.close() }
        do {
            _ = try await connection.query("INSERT INTO parents VALUES (2, 'a')")
            Issue.record("expected a unique violation")
        } catch let error as SQLDiagnosable {
            // SQLITE_CONSTRAINT_UNIQUE — the taxonomy is coarse on purpose, and
            // the exact code is still there for anyone who needs it.
            #expect(error.nativeCode == 2067)
        }
    }

    @Test("connection-level and statement-level failures are separable")
    func statementLevelIsDistinguished() {
        #expect(SQLErrorKind.uniqueViolation.isStatementLevel)
        #expect(SQLErrorKind.syntax.isStatementLevel)
        // A pool discards the connection for these and keeps it for the others.
        #expect(!SQLErrorKind.connection.isStatementLevel)
        #expect(!SQLErrorKind.authentication.isStatementLevel)
    }

    @Test("only contention is transient")
    func transienceIsNarrow() {
        #expect(SQLErrorKind.deadlock.isTransient)
        #expect(SQLErrorKind.serializationFailure.isTransient)
        #expect(SQLErrorKind.lockTimeout.isTransient)

        // Retrying these forever would just fail forever.
        #expect(!SQLErrorKind.syntax.isTransient)
        #expect(!SQLErrorKind.uniqueViolation.isTransient)
        #expect(!SQLErrorKind.permission.isTransient)
    }
}

@Suite("Query timeouts")
struct QueryTimeoutTests {

    /// A slow statement is abandoned rather than waited on.
    ///
    /// The recursive CTE is the cheapest way to make SQLite genuinely busy for
    /// longer than the deadline without sleeping.
    @Test("a statement that outruns its deadline throws")
    func slowStatementTimesOut() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }

        await #expect(throws: SQLTimeoutError.self) {
            try await withQueryTimeout(.milliseconds(50)) {
                _ = try await connection.query(
                    """
                    WITH RECURSIVE slow(n) AS (
                        SELECT 1 UNION ALL SELECT n + 1 FROM slow WHERE n < 50000000
                    )
                    SELECT COUNT(*) FROM slow
                    """
                )
            }
        }
    }

    @Test("a fast statement is unaffected")
    func fastStatementPasses() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }

        let rows = try await withQueryTimeout(.seconds(5)) {
            try await connection.query("SELECT 1 AS n")
        }
        #expect(rows.first?.values.first == .int(1))
    }

    /// Giving up on waiting says nothing about whether the server gave up on
    /// working, so a timeout is never safe to retry blindly.
    @Test("a timeout reports that it may have applied")
    func timeoutMayHaveApplied() {
        let error = SQLTimeoutError(duration: .seconds(1), sql: "UPDATE t SET x = 1")
        #expect(error.sqlKind == .timeout)
        #expect(error.mayHaveApplied)
        #expect(error.sqlKind.isTransient)
        // Transient but possibly applied — precisely the combination that must
        // not be retried automatically.
        #expect(error.isSafeToRetry == false)
    }
}

extension QueryTimeoutTests {
    /// A timeout must stop the *database*, not just the caller.
    ///
    /// Without `sqlite3_interrupt` the cancelled task still waits for the
    /// blocking `sqlite3_step` to finish on its queue — so the deadline bounds
    /// nothing and the connection stays busy. This test is a stopwatch: the
    /// statement below runs for many seconds, and finishing well inside the
    /// deadline is the only evidence that the interrupt landed.
    @Test("a timeout interrupts the statement rather than waiting it out")
    func timeoutActuallyInterrupts() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }

        let started = ContinuousClock.now

        // Both errors are captured rather than asserted away, because which one
        // arrives is the diagnosis. `#expect(throws:)` would confirm a timeout was
        // reported and discard the thing worth knowing: what the statement did.
        var thrown: (any Error)?
        // A box, because the query runs in a concurrently-executing closure and a
        // captured `var` cannot be written from one.
        let queryError = ErrorBox()
        do {
            try await withQueryTimeout(.milliseconds(50)) {
                do {
                    _ = try await connection.query(
                        """
                        WITH RECURSIVE slow(n) AS (
                            SELECT 1 UNION ALL SELECT n + 1 FROM slow WHERE n < 4000000000
                        )
                        SELECT COUNT(*) FROM slow
                        """
                    )
                } catch {
                    queryError.set(error)
                    throw error
                }
            }
        } catch {
            thrown = error
        }
        let elapsed = ContinuousClock.now - started

        #expect(thrown is SQLTimeoutError, "expected a timeout, got \(String(describing: thrown))")
        // Sixty seconds against a statement that counts to four billion — measured at
        // 34 seconds for a *fifth* of that count on the machine this was written on,
        // so unbounded it runs for many minutes anywhere.
        //
        // The earlier version counted to two hundred million and asserted under ten
        // seconds, and failed CI at 19.1s, 20.6s, 25.9s — numbers that are neither
        // "the abort landed" nor "the query ran to completion". A bound that cannot
        // tell its two outcomes apart is measuring the machine, and this suite has
        // now learned that four times.
        //
        // It has failed in CI at 36.7s, 43.9s, 25.9s and 20.6s while passing here in
        // 0.05s, including under full parallel load. Four attempts to fix it from
        // the driver side changed the number and not the outcome, and the same
        // vendored SQLite with the same flags is on both machines.
        //
        // So the failure message now carries the evidence instead of the elapsed
        // time alone, because the next occurrence should say what happened rather
        // than prompt another round of reasoning from the machine that works.
        #expect(
            elapsed < .seconds(60),
            """
            took \(elapsed) — the statement was waited out, not aborted.
              thrown by the timeout: \(String(describing: thrown))
              error the statement itself returned: \(String(describing: queryError.value))
            An SQLITE_INTERRUPT here means the abort worked and the bound is wrong.
            Anything else means the progress handler never fired.
            """
        )

        // And the connection is immediately usable again.
        let rows = try await connection.query("SELECT 1 AS n")
        #expect(rows.first?.values.first == .int(1))
    }
}

extension QueryTimeoutTests {
    /// The race the CI runner found, staged rather than waited for.
    ///
    /// `sqlite3_interrupt` does nothing when no statement is running. The
    /// stopwatch test above cancels while the slow query is *already stepping*,
    /// so the interrupt lands, and it passes on any machine quick enough to have
    /// started it. That is why it passed locally for months and failed on
    /// GitHub's macOS runner as `elapsed → 36.69 seconds < 10.0 seconds` — the
    /// interrupt arriving before there was anything to interrupt, after which the
    /// query ran all 200,000,000 iterations.
    ///
    /// ## Two things this test got wrong before getting them right
    ///
    /// It first blocked the queue with a slow *query* and timed a `SELECT 1`.
    /// That passed with the fix removed, because `interrupt()` is
    /// connection-wide: cancelling the `SELECT` interrupted the blocker, freed
    /// the queue, and the timing proved nothing.
    ///
    /// It then blocked the queue with a plain sleep and drove cancellation from a
    /// 50ms `withQueryTimeout`. That failed on a two-core CI runner — not
    /// because the fix was wrong, but because a 50ms timer racing a 1.5s block is
    /// only a 30× margin, and under that much contention `Task.sleep(50ms)` can
    /// be delayed past the block entirely. The statement then ran normally and
    /// both assertions failed.
    ///
    /// So there is no timer here at all. The task is cancelled **explicitly**,
    /// which drives exactly the same `withTaskCancellationHandler` path a timeout
    /// would, and the claim is checked by side effect: a statement cancelled
    /// before it starts must not run. An `INSERT` leaves evidence either way.
    @Test("a statement cancelled before it starts never runs")
    func cancelledBeforeTheStatementBegins() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }
        _ = try await connection.query("CREATE TABLE marks (id INTEGER PRIMARY KEY)")

        // Held by something SQLite has no idea about, so cancellation cannot free
        // it the way interrupting a query would. The queue is **serial**, which is
        // the property the rest of this test is built on.
        connection.occupyQueueForTesting(seconds: 6)

        // Third version, and the first with no margin in it.
        //
        // The two above each picked a number — 250ms against 2s, then 300ms
        // against 6s — and a margin is not a margin when the machine can stall
        // the short side past the long one. CI stalled the 300ms past the 6s and
        // the statement ran normally.
        //
        // The task now signals as its body begins, so the cancel lands after the
        // statement was enqueued and before the queue could reach it, with
        // nothing in between that a scheduler can stretch.
        let (begun, signalBegun) = AsyncStream<Void>.makeStream()
        let insert = Task {
            signalBegun.yield()
            signalBegun.finish()
            return try await connection.query("INSERT INTO marks (id) VALUES (1)")
        }
        var iterator = begun.makeAsyncIterator()
        _ = await iterator.next()
        insert.cancel()
        _ = try? await insert.value

        // Drain deterministically rather than outwaiting the blocker.
        //
        // The insert's task has finished, so it can enqueue nothing further, and
        // the queue is serial — when a statement queued *now* comes back, the
        // blocker and everything behind it have run, including the insert if it
        // was merely queued rather than refused. That is the same claim the old
        // eight-second sleep was making, without the sleep.
        _ = try await connection.query("SELECT 1")

        let rows = try await connection.query("SELECT COUNT(*) FROM marks")
        let value = rows[0].values[0]
        #expect(value == .int(0), "a statement cancelled before it began still ran: \(value)")
    }
}

/// What `withQueryTimeout` promises, tested without a stopwatch.
///
/// Its sibling test in `QueryTimeoutTests` times a deliberately enormous query and
/// asserts it finishes early. That test is only meaningful on a machine slow enough that
/// the query would *not* finish on its own — which is why it passed on a laptop for
/// months while failing in CI at 36.7s, 43.9s, 25.9s and 20.6s against a ten-second
/// bound, and why four attempts to fix the SQLite driver's interrupt path changed
/// nothing. The driver's cancellation was correct and was never being invoked.
///
/// The cause was one line out of place: `group.cancelAll()` sat *after*
/// `try await group.next()`, so when the deadline won and `next()` rethrew, the cancel
/// was skipped and the group awaited the still-running query. The timeout reported on
/// time and stopped nothing, on every engine.
///
/// This asserts the thing itself — that the body is cancelled — with no clock involved,
/// so it means the same on any machine.
// test-hygiene: no server — pure concurrency
@Suite("Query timeout cancellation")
struct QueryTimeoutCancellationTests {

    final class Signal: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    @Test("the body is cancelled when the deadline wins")
    func deadlineCancelsTheBody() async {
        let cancelled = Signal()

        _ = try? await withQueryTimeout(.milliseconds(50)) {
            await withTaskCancellationHandler {
                // Far longer than the deadline. If cancellation never arrives this
                // sleeps it out and the assertion below fails — which is exactly what
                // the old code did, only with a query instead of a sleep.
                try? await Task.sleep(for: .seconds(30))
            } onCancel: {
                cancelled.set()
            }
        }

        #expect(cancelled.isSet, "the deadline fired but the work was never cancelled")
    }

    /// And it returns rather than waiting the body out.
    ///
    /// Ten minutes of abandoned work against a one-minute bound, and the gap is
    /// deliberate. The first version slept thirty seconds and asserted under ten,
    /// which failed CI at 19.1s — a number that is neither "returned promptly" nor
    /// "waited out the sleep", so the assertion could not tell the two apart and
    /// was really measuring the runner.
    ///
    /// At these values there is no scheduling delay that blurs them: returning
    /// takes milliseconds, and waiting takes ten minutes.
    @Test("it does not wait for the abandoned work")
    func returnsWithoutAwaitingTheBody() async {
        let started = ContinuousClock.now
        _ = try? await withQueryTimeout(.milliseconds(50)) {
            try? await Task.sleep(for: .seconds(600))
        }
        #expect(ContinuousClock.now - started < .seconds(60))
    }

    /// The success path is untouched: a body that finishes first still returns its value
    /// and is not cancelled out from under itself.
    @Test("work that beats the deadline still returns")
    func fastWorkStillReturns() async throws {
        let value = try await withQueryTimeout(.seconds(5)) { 42 }
        #expect(value == 42)
    }
}

/// Carries an error out of a concurrently-executing closure, which a captured `var`
/// cannot do under strict concurrency.
final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (any Error)?
    var value: (any Error)? { lock.withLock { stored } }
    func set(_ error: any Error) { lock.withLock { stored = error } }
}

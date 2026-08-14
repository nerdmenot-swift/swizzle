import Foundation
import SwizzleCore
import Testing

@testable import SwizzleSQLite
@testable import SwizzleSQLiteEngine

/// Blocks every participant until all of them have arrived.
///
/// Duplicated from the MySQL integration target rather than shared, because test
/// targets do not depend on one another. It is here for the same reason it is
/// there: proving that N things happened *at once* by sleeping only proves the
/// sleep was long enough on this machine today.
private actor Barrier {
    private let count: Int
    private var arrived = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(count: Int) { self.count = count }

    func arriveAndWait() async {
        arrived += 1
        if arrived >= count {
            let pending = waiters
            waiters.removeAll()
            for continuation in pending { continuation.resume() }
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private func eventually(
    within timeout: Duration = .seconds(5),
    pollingEvery interval: Duration = .milliseconds(5),
    _ description: String,
    _ condition: () async throws -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: interval)
    }
    Issue.record(
        "timed out after \(timeout) waiting for: \(description)", sourceLocation: sourceLocation
    )
}

/// ``SQLiteReaderPool`` — N read-only connections and one writer.
///
/// The pool exists for one measured reason: eight concurrent readers through a
/// single `SQLiteConnection` took 405 ms and through one connection each took
/// 84 ms. So the tests have to prove the *concurrency* rather than the API
/// shape — a pool that hands out one connection at a time would satisfy every
/// signature here and none of the point.
@Suite("SQLite reader pool")
struct SQLiteReaderPoolTests {

    /// A fresh directory per test. The pool refuses `:memory:`, so every test
    /// here needs a real file.
    static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swizzle-pool-\(UInt32.random(in: 0..<UInt32.max))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func seeded(
        _ directory: URL, readers: Int = 4, rows: Int = 50
    ) async throws -> SQLiteReaderPool {
        let pool = try SQLiteReaderPool(
            path: directory.appendingPathComponent("app.db").path, readers: readers
        )
        try await pool.withWriter { writer in
            _ = try await writer.query("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
            for id in 1...rows {
                _ = try await writer.query(
                    "INSERT INTO t (id, name) VALUES (?1, ?2)", [.int(Int64(id)), .text("n\(id)")]
                )
            }
        }
        return pool
    }

    // MARK: - The refusal that prevents a silent empty database

    /// **The failure this refusal exists to prevent is invisible.** Every
    /// connection to `:memory:` is its own database, so a pool of them would be a
    /// pool of empty databases: the writer's inserts land in one, and readers
    /// return zero rows for ever with no error anywhere.
    @Test("an in-memory database is refused, in every spelling")
    func inMemoryIsRefused() throws {
        for path in [
            ":memory:",
            "",
            "file::memory:",
            "file::memory:?cache=shared",
            // The one that looks like a filename. `mode=memory` makes it
            // in-memory whatever the name says.
            "file:app.db?mode=memory&cache=shared",
        ] {
            #expect(throws: SQLiteReaderPool.PoolError.inMemoryCannotBePooled) {
                _ = try SQLiteReaderPool(path: path)
            }
        }
    }

    /// And an ordinary path is not swept up by the check — a rule that refuses
    /// too much is just as broken, and `memory` is a perfectly good file name.
    @Test("a file path that merely mentions memory is fine")
    func ordinaryPathsAreAccepted() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let pool = try SQLiteReaderPool(
            path: directory.appendingPathComponent("memory.db").path, readers: 2
        )
        defer { pool.close() }
        try await pool.withWriter { _ = try await $0.query("CREATE TABLE t (id INTEGER)") }
    }

    // MARK: - Concurrency, which is the entire reason for the type

    /// **The claim the pool is built on.** Every task takes a reader, runs a real
    /// query, and only then arrives at the barrier — so the test cannot complete
    /// at all unless all eight are holding distinct connections simultaneously.
    ///
    /// A pool that serialised (or that handed the same connection to everyone)
    /// deadlocks here rather than passing slowly, which is the property a timing
    /// assertion would not have.
    @Test("eight readers hold eight distinct connections at the same time")
    func readersRunConcurrently() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let readers = 8
        let pool = try await Self.seeded(directory, readers: readers)
        defer { pool.close() }

        let barrier = Barrier(count: readers)
        let identities = try await withThrowingTaskGroup(of: ObjectIdentifier.self) { group in
            for _ in 0..<readers {
                group.addTask {
                    try await pool.withReader { reader in
                        let rows = try await reader.query("SELECT count(*) FROM t")
                        #expect(rows.first?.values.first == .int(50))
                        // Still holding it: nobody leaves until everybody is here.
                        await barrier.arriveAndWait()
                        return ObjectIdentifier(reader)
                    }
                }
            }
            var seen: Set<ObjectIdentifier> = []
            for try await identity in group { seen.insert(identity) }
            return seen
        }

        #expect(identities.count == readers)
        #expect(pool.statistics.readersInUse == 0)
        #expect(pool.statistics.readsServed == readers)
    }

    /// With fewer connections than callers the extra callers must *wait* — and
    /// then actually be served. The barrier makes the wait real: the two holders
    /// cannot release until a third caller has queued behind them.
    @Test("callers beyond the reader count wait, then are served")
    func waitersAreServed() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let pool = try await Self.seeded(directory, readers: 2)
        defer { pool.close() }

        let holdersReady = Barrier(count: 3)  // the two holders and the test
        let release = Barrier(count: 3)

        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    try await pool.withReader { reader in
                        await holdersReady.arriveAndWait()
                        await release.arriveAndWait()
                        return try await reader.query("SELECT count(*) FROM t").count
                    }
                }
            }
            await holdersReady.arriveAndWait()
            #expect(pool.statistics.readersInUse == 2)

            // A third caller with nothing left to take.
            group.addTask {
                try await pool.withReader { reader in
                    try await reader.query("SELECT count(*) FROM t").count
                }
            }
            try await eventually("the third caller to be queued") {
                pool.statistics.waiting == 1
            }

            await release.arriveAndWait()
            var results: [Int] = []
            for try await count in group { results.append(count) }
            #expect(results == [1, 1, 1])
        }

        #expect(pool.statistics.waiting == 0)
        #expect(pool.statistics.readersInUse == 0)
        #expect(pool.statistics.readsServed == 3)
    }

    // MARK: - Read-only is enforced by SQLite, not by convention

    /// A reader that can write is a reader that can hold the write lock while the
    /// writer waits on it. `SQLITE_OPEN_READONLY` turns that into an error at the
    /// statement that did it — a named failure in a test run instead of a stall
    /// in production.
    @Test("a write through a reader is refused, not queued")
    func writeThroughReaderIsRefused() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let pool = try await Self.seeded(directory, readers: 2)
        defer { pool.close() }

        let kind: SQLErrorKind? = try await pool.withReader { reader in
            do {
                _ = try await reader.query("INSERT INTO t (id, name) VALUES (999, 'x')")
                return nil
            } catch let error as SQLDiagnosable {
                return error.sqlKind
            }
        }
        #expect(kind == .readOnly)

        // And the refusal did not corrupt the pool or the database.
        let rows = try await pool.withReader { try await $0.query("SELECT count(*) FROM t") }
        #expect(rows.first?.values.first == .int(50))
    }

    /// The whole arrangement is pointless if readers cannot see what the writer
    /// wrote. This is WAL doing its job across separate connections — and it also
    /// pins the ordering in `init`, where the writer must open first so the `-shm`
    /// file exists before a read-only connection needs it.
    @Test("readers see the writer's committed rows")
    func readersSeeCommittedWrites() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let pool = try await Self.seeded(directory, readers: 3, rows: 1)
        defer { pool.close() }

        try await pool.withWriter {
            _ = try await $0.query("INSERT INTO t (id, name) VALUES (2, 'later')")
        }
        let rows = try await pool.withReader {
            try await $0.query("SELECT name FROM t WHERE id = 2")
        }
        #expect(rows.first?.values.first == .text("later"))
    }

    // MARK: - Returning the connection on every path

    /// A reader lost to a thrown error is a reader the pool never gets back, and
    /// with a small count that is an outage rather than a slowdown. One reader
    /// makes it unambiguous: if the throwing call kept it, the next call hangs.
    @Test("a throwing body still returns its reader")
    func throwingBodyReturnsReader() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let pool = try await Self.seeded(directory, readers: 1)
        defer { pool.close() }

        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await pool.withReader { _ in throw Boom() }
        }
        #expect(pool.statistics.readersInUse == 0)

        let rows = try await pool.withReader { try await $0.query("SELECT count(*) FROM t") }
        #expect(rows.first?.values.first == .int(50))
    }

    /// The same for a SQLite error raised inside the body, which is the common
    /// case rather than the contrived one.
    @Test("a failing query still returns its reader")
    func failingQueryReturnsReader() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let pool = try await Self.seeded(directory, readers: 1)
        defer { pool.close() }

        _ = try? await pool.withReader { try await $0.query("SELECT * FROM nope") }
        let rows = try await pool.withReader { try await $0.query("SELECT count(*) FROM t") }
        #expect(rows.first?.values.first == .int(50))
    }

    // MARK: - Cancellation

    /// A task cancelled while queued must leave the queue. `withCheckedContinuation`
    /// is not cancellation-aware on its own, so without the handler the task
    /// stays suspended until some unrelated caller happens to check a reader back
    /// in — which, if the holders never release, is never.
    ///
    /// Deliberately ordered so a regression **fails rather than hangs**: the
    /// counter is checked with a deadline, and the holder is released before the
    /// cancelled task is awaited. Removing the cancellation handler was tried,
    /// and it fails here on both assertions.
    @Test("a cancelled waiter leaves the queue instead of hanging")
    func cancelledWaiterLeavesTheQueue() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let pool = try await Self.seeded(directory, readers: 1)
        defer { pool.close() }

        let holding = Barrier(count: 2)
        let release = Barrier(count: 2)
        let holder = Task {
            try await pool.withReader { _ in
                await holding.arriveAndWait()
                await release.arriveAndWait()
            }
        }
        await holding.arriveAndWait()

        let waiter = Task { try await pool.withReader { _ in "served" } }
        try await eventually("the waiter to queue") { pool.statistics.waiting == 1 }

        waiter.cancel()
        // Left the queue rather than merely reporting an error. Checked with a
        // deadline so an un-cancellable waiter is reported, not waited on.
        try await eventually("the cancelled waiter to leave the queue") {
            pool.statistics.waiting == 0
        }

        // Released first: a waiter still parked in the queue then completes with
        // a reader and returns `"served"`, so the expectation below fails on the
        // wrong outcome rather than blocking on a task that never finishes.
        await release.arriveAndWait()
        try await holder.value
        await #expect(throws: CancellationError.self) { try await waiter.value }

        // And the reader really did come back, to a pool with nothing wedged in
        // front of it.
        let rows = try await pool.withReader { try await $0.query("SELECT count(*) FROM t") }
        #expect(rows.first?.values.first == .int(50))
    }

    /// Cancelling before the checkout even suspends takes a different path — the
    /// handler can run before `withCheckedContinuation` hands over the
    /// continuation, which is the race the `cancelledBeforeRegistering` set
    /// exists for. Either outcome is correct; hanging is not.
    @Test("cancelling a checkout that has not suspended yet does not hang")
    func cancellationRaceDoesNotHang() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let pool = try await Self.seeded(directory, readers: 1)
        defer { pool.close() }

        let holding = Barrier(count: 2)
        let release = Barrier(count: 2)
        let holder = Task {
            try await pool.withReader { _ in
                await holding.arriveAndWait()
                await release.arriveAndWait()
            }
        }
        await holding.arriveAndWait()

        // Cancelled immediately, so the handler races the registration rather
        // than arriving long after it. Nothing is awaited inside the loop: the
        // point is to have many of them in flight at once, and awaiting each in
        // turn would serialise the race away.
        var waiters: [Task<String, Error>] = []
        for _ in 0..<50 {
            let waiter = Task { try await pool.withReader { _ in "served" } }
            waiter.cancel()
            waiters.append(waiter)
        }
        try await eventually("every cancelled checkout to leave the queue") {
            pool.statistics.waiting == 0
        }

        // Released before awaiting, so a waiter that lost the race and parked
        // anyway is drained here instead of hanging the test.
        await release.arriveAndWait()
        try await holder.value
        for waiter in waiters { _ = try? await waiter.value }
        let rows = try await pool.withReader { try await $0.query("SELECT count(*) FROM t") }
        #expect(rows.first?.values.first == .int(50))
    }

    // MARK: - Close

    /// Closing while somebody is queued must resume them. A continuation that is
    /// never resumed leaks its task for the life of the process and shows up
    /// nowhere — the worst kind of shutdown bug.
    @Test("closing resumes waiters rather than stranding them")
    func closeResumesWaiters() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let pool = try await Self.seeded(directory, readers: 1)

        let holding = Barrier(count: 2)
        let release = Barrier(count: 2)
        let holder = Task {
            try await pool.withReader { _ in
                await holding.arriveAndWait()
                await release.arriveAndWait()
            }
        }
        await holding.arriveAndWait()

        let waiter = Task { try await pool.withReader { _ in "served" } }
        try await eventually("the waiter to queue") { pool.statistics.waiting == 1 }

        pool.close()
        await #expect(throws: SQLiteReaderPool.PoolError.closed) { try await waiter.value }

        await release.arriveAndWait()
        _ = try? await holder.value
    }

    @Test("a closed pool refuses new work, and closing twice is fine")
    func closedPoolRefusesWork() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let pool = try await Self.seeded(directory, readers: 2)
        pool.close()
        pool.close()

        await #expect(throws: SQLiteReaderPool.PoolError.closed) {
            try await pool.withReader { _ in }
        }
        await #expect(throws: SQLiteReaderPool.PoolError.closed) {
            try await pool.withWriter { _ in }
        }
    }

    // MARK: - A failed open leaves nothing behind

    /// Half a pool is not a pool. If the fourth reader cannot be opened, the
    /// three before it and the writer must be closed rather than left to a
    /// `deinit` that never runs — `init` threw, so there is no object to
    /// deinitialise and no one holding the handles.
    ///
    /// Reached through the factory seam because SQLite will not fail here on its
    /// own: `sqlite3_open` does not touch the file, so even a nonsense path
    /// succeeds until the first statement runs.
    @Test("a failed open closes everything opened before it")
    func partialOpenIsCleanedUp() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("app.db").path

        struct OpenFailed: Error {}
        nonisolated(unsafe) var created: [SQLiteConnection] = []

        #expect(throws: OpenFailed.self) {
            _ = try SQLiteReaderPool(path: path, readers: 8) { readOnly in
                // The writer plus three readers, then failure.
                guard created.count < 4 else { throw OpenFailed() }
                let connection = try SQLiteConnection(path: path, readOnly: readOnly)
                created.append(connection)
                return connection
            }
        }

        #expect(created.count == 4)
        for connection in created {
            // A closed connection says so rather than crashing, which is what
            // makes this observable at all.
            await #expect(throws: SQLiteError.self) { try await connection.query("SELECT 1") }
        }
    }

    // MARK: - Statistics

    @Test("statistics describe the pool rather than guessing at it")
    func statistics() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let pool = try await Self.seeded(directory, readers: 3, rows: 1)
        defer { pool.close() }

        // Seeding used the writer twice: the CREATE and the INSERT are one
        // `withWriter` call, so exactly one write is served.
        #expect(pool.statistics.readers == 3)
        #expect(pool.statistics.writesServed == 1)
        #expect(pool.statistics.readsServed == 0)

        try await pool.withReader { reader in
            #expect(pool.statistics.readersInUse == 1)
            _ = try await reader.query("SELECT 1")
        }
        #expect(pool.statistics.readersInUse == 0)
        #expect(pool.statistics.readsServed == 1)
    }

    /// Asking for fewer than one reader is a configuration mistake, not a request
    /// for a pool that can never serve anybody.
    @Test("a non-positive reader count still yields a usable pool")
    func degenerateReaderCount() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let pool = try SQLiteReaderPool(
            path: directory.appendingPathComponent("app.db").path, readers: 0
        )
        defer { pool.close() }
        #expect(pool.statistics.readers == 1)

        try await pool.withWriter { _ = try await $0.query("CREATE TABLE t (id INTEGER)") }
        let rows = try await pool.withReader { try await $0.query("SELECT count(*) FROM t") }
        #expect(rows.first?.values.first == .int(0))
    }
}

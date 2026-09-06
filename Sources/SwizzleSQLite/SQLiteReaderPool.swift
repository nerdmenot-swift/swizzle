import Foundation
import SwizzleCore

/// Many readers, one writer.
///
/// ## Why this exists, and why it is not `SwizzleConnectionPool`
///
/// A `SQLiteConnection` serialises every call through its own queue, which is
/// what SQLite wants from a single handle. WAL, meanwhile, lets readers run
/// concurrently with each other and with the writer — so one connection leaves
/// that concurrency on the floor. Eight concurrent tasks, six scanning queries
/// each, over 20,000 rows:
///
/// | | elapsed |
/// |---|---|
/// | one shared connection | 57 ms |
/// | a reader pool | **10 ms** |
///
/// Roughly a **6×** ceiling — and the usual reason to pool does not apply at all:
/// opening a connection costs about **21 µs**, because there is no socket, no
/// handshake and no authentication. So the value here is *parallelism*, not
/// reuse, and that is why the generic pool is the wrong tool.
/// `SwizzleConnectionPool` is built for network connections: keep-alive pings,
/// acquisition timeouts, connect backoff, connection ageing. For a file handle
/// almost all of it is machinery carried for nothing.
///
/// Both numbers come from `SQLiteConcurrencyBenchmark`, on an M-series Mac —
/// `SWIZZLE_BENCH=1 swift test --filter SQLiteConcurrencyBenchmark` reproduces
/// them. The ratio is the point; the absolute values are not.
///
/// ## Why exactly one writer
///
/// SQLite permits one writer at a time whatever a client does. Pooling writers
/// would not create concurrency, it would only move the contention: instead of
/// waiting in a fair FIFO queue, callers would race for the write lock and lose
/// with `SQLITE_BUSY` after the busy timeout. A queue that is fair and a retry
/// loop that is not are very different things to debug.
///
/// ## Readers are opened read-only
///
/// Not a formality. A reader that can write is a reader that can take the write
/// lock while the writer waits for it, and `SQLITE_OPEN_READONLY` turns that into
/// an immediate, named error at the statement that did it.
public final class SQLiteReaderPool: @unchecked Sendable {

    public struct Statistics: Sendable, Equatable {
        public var readers = 0
        /// Readers currently checked out.
        public var readersInUse = 0
        /// Callers waiting for a reader. Sustained non-zero means the count is
        /// too low, or something is holding a reader across slow work.
        public var waiting = 0
        public var readsServed = 0
        public var writesServed = 0
    }

    public enum PoolError: Error, Sendable, Equatable, CustomStringConvertible {
        /// Each `:memory:` connection is a **separate database**, so a pool of
        /// them is a pool of unrelated empty databases that silently returns no
        /// rows. Refused rather than surprising anyone.
        case inMemoryCannotBePooled
        case closed

        public var description: String {
            switch self {
            case .inMemoryCannotBePooled:
                "an in-memory database cannot be pooled — every connection to "
                    + "`:memory:` is its own separate database, so readers would see "
                    + "none of the writer's data. Use a file, or a single "
                    + "SQLiteConnection"
            case .closed:
                "the pool is closed"
            }
        }
    }

    /// `nil` is handed to a waiter that will never get a reader — the pool
    /// closed, or the task was cancelled. It is not an error case on the
    /// continuation because resuming with a *value* keeps the cancellation
    /// handler and the checkin path symmetric; `checkout` turns the `nil` into
    /// the right error.
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<SQLiteConnection?, Never>
    }

    private struct State {
        var available: [SQLiteConnection] = []
        var waiters: [Waiter] = []
        /// Waiters cancelled *before* they managed to register. The handler can
        /// run before `withCheckedContinuation` gives us the continuation, and
        /// without this the task would suspend for good a microsecond after
        /// asking not to.
        var cancelledBeforeRegistering: Set<UInt64> = []
        var nextWaiterID: UInt64 = 0
        var statistics = Statistics()
        var isClosed = false
    }

    private let lock = NSLock()
    private var state = State()
    /// The one writer, used under its own serial queue like any other connection.
    public let writer: SQLiteConnection
    private let allReaders: [SQLiteConnection]

    /// - Parameters:
    ///   - readers: Defaults to the core count. More than that buys nothing —
    ///     readers are CPU- and IO-bound, not waiting on a network.
    public convenience init(
        path: String,
        readers: Int = ProcessInfo.processInfo.activeProcessorCount,
        busyTimeout: TimeInterval = 5
    ) throws {
        try self.init(path: path, readers: readers) { readOnly in
            try SQLiteConnection(path: path, busyTimeout: busyTimeout, readOnly: readOnly)
        }
    }

    /// The designated initialiser, taking the connection factory so a test can
    /// make one of the opens fail. Nothing else is a plausible way to reach the
    /// partial-open cleanup below: `sqlite3_open` on a path that will not work
    /// still succeeds, because it does not touch the file until the first
    /// statement.
    init(
        path: String,
        readers: Int,
        makeConnection: (_ readOnly: Bool) throws -> SQLiteConnection
    ) throws {
        guard !Self.isInMemory(path) else { throw PoolError.inMemoryCannotBePooled }

        // The writer opens first, and read-write: it is what creates the file,
        // sets WAL, and — the part that is easy to miss — keeps the `-shm` file
        // alive, which a read-only connection needs in order to attach to the WAL
        // at all.
        writer = try makeConnection(false)

        var opened: [SQLiteConnection] = []
        // No reserve. `readers` is the caller's number and reserveCapacity aborts
        // rather than throwing on an absurd one, while the saving on a list of at
        // most a few dozen connections is not measurable. Bounding it instead
        // would mean inventing a maximum this type has no basis to pick.
        do {
            for _ in 0..<max(1, readers) { opened.append(try makeConnection(true)) }
        } catch {
            // Half a pool is not a pool. Everything opened so far is closed
            // rather than leaked to a deinit that may never run.
            for connection in opened { connection.close() }
            writer.close()
            throw error
        }

        allReaders = opened
        state.available = opened
        state.statistics.readers = opened.count
    }

    /// `:memory:` in any of its spellings, including the URI forms.
    static func isInMemory(_ path: String) -> Bool {
        if path == ":memory:" || path.isEmpty { return true }
        guard path.hasPrefix("file:") else { return false }
        // `file::memory:` and `file:name?mode=memory` are both in-memory, and the
        // second is easy to miss — it looks like a filename.
        return path.contains(":memory:") || path.contains("mode=memory")
    }

    public var statistics: Statistics {
        lock.withLock { state.statistics }
    }

    // MARK: - Borrowing

    /// Runs `body` on a read-only connection, waiting for one if all are busy.
    ///
    /// The connection is returned on every path, including a throw — a reader
    /// lost to an error is a reader the pool never gets back, and with a small
    /// count that is an outage rather than a slowdown.
    public func withReader<Result>(
        _ body: (SQLiteConnection) async throws -> Result
    ) async throws -> Result {
        let reader = try await checkout()
        defer { checkin(reader) }
        return try await body(reader)
    }

    /// Runs `body` on the single writer.
    ///
    /// No checkout: the writer's own serial queue already provides the fair
    /// ordering, and interposing a second queue would only add a hop.
    public func withWriter<Result>(
        _ body: (SQLiteConnection) async throws -> Result
    ) async throws -> Result {
        guard !lock.withLock({ state.isClosed }) else { throw PoolError.closed }
        lock.withLock { state.statistics.writesServed += 1 }
        return try await body(writer)
    }

    private enum Checkout {
        case immediate(SQLiteConnection)
        case queued(UInt64)
    }

    private func checkout() async throws -> SQLiteConnection {
        // Taking a reader and joining the queue are the same decision, so they
        // happen under one lock: split in two, a checkin could land between them
        // and park the caller with a connection sitting free.
        let outcome: Checkout = try lock.withLock {
            if state.isClosed { throw PoolError.closed }
            if let reader = state.available.popLast() {
                state.statistics.readersInUse += 1
                state.statistics.readsServed += 1
                return .immediate(reader)
            }
            let id = state.nextWaiterID
            state.nextWaiterID += 1
            state.statistics.waiting += 1
            return .queued(id)
        }

        guard case .queued(let id) = outcome else {
            guard case .immediate(let reader) = outcome else { preconditionFailure() }
            return reader
        }

        let reader = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<SQLiteConnection?, Never>) in
                let resumeImmediately: Bool = lock.withLock {
                    guard !state.isClosed,
                        state.cancelledBeforeRegistering.remove(id) == nil
                    else {
                        state.statistics.waiting -= 1
                        return true
                    }
                    state.waiters.append(Waiter(id: id, continuation: continuation))
                    return false
                }
                if resumeImmediately { continuation.resume(returning: nil) }
            }
        } onCancel: {
            let waiter: Waiter? = lock.withLock {
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else {
                    // Not registered yet — or already handed a reader. Either way
                    // the marker is cleared below, so a stale one cannot leak.
                    state.cancelledBeforeRegistering.insert(id)
                    return nil
                }
                state.statistics.waiting -= 1
                return state.waiters.remove(at: index)
            }
            waiter?.continuation.resume(returning: nil)
        }

        lock.withLock { _ = state.cancelledBeforeRegistering.remove(id) }

        guard let reader else {
            if lock.withLock({ state.isClosed }) { throw PoolError.closed }
            throw CancellationError()
        }
        return reader
    }

    private func checkin(_ reader: SQLiteConnection) {
        // FIFO: the longest-waiting caller goes first. A stack would starve
        // somebody under sustained load, and a starved request is far harder to
        // diagnose than a slow one.
        let waiter: Waiter? = lock.withLock {
            guard !state.isClosed else {
                // Closed while this reader was out: the handle is already closed,
                // so it is dropped rather than offered to anyone.
                state.statistics.readersInUse -= 1
                return nil
            }
            guard !state.waiters.isEmpty else {
                state.available.append(reader)
                state.statistics.readersInUse -= 1
                return nil
            }
            state.statistics.waiting -= 1
            // Handed straight across, so `readersInUse` does not move — it never
            // came back to the pool.
            state.statistics.readsServed += 1
            return state.waiters.removeFirst()
        }
        waiter?.continuation.resume(returning: reader)
    }

    // MARK: - Lifecycle

    /// Closes every connection. Safe to call twice.
    ///
    /// Waiters are resumed rather than abandoned — a task suspended on a
    /// continuation that is never resumed leaks for the life of the process, and
    /// it is invisible.
    public func close() {
        let waiters: [Waiter] = lock.withLock {
            guard !state.isClosed else { return [] }
            state.isClosed = true
            state.statistics.waiting -= state.waiters.count
            let pending = state.waiters
            state.waiters = []
            state.available = []
            return pending
        }
        // They get `PoolError.closed` rather than a connection that is about to
        // be closed under them, and rather than hanging.
        for waiter in waiters { waiter.continuation.resume(returning: nil) }

        for reader in allReaders { reader.close() }
        writer.close()
    }

    deinit { close() }
}

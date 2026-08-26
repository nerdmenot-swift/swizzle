import CSQLite
import Dispatch
import Foundation
import SwizzleCore

/// An open SQLite database.
///
/// ## Why a dedicated queue rather than an actor
///
/// SQLite's API is synchronous and blocking: `sqlite3_step` waits on disk, and
/// under contention it waits on another writer's lock for up to
/// `busy_timeout` milliseconds. Running that inside an actor would block a thread
/// from Swift's cooperative pool — a pool sized to the core count, whose whole
/// contract is that nothing on it blocks. A handful of concurrent SQLite reads
/// could stall every other async task in the process, including the ones that
/// would have released the lock.
///
/// So every call hops to a serial `DispatchQueue` and suspends the caller with a
/// continuation. The queue also gives the serialisation SQLite wants for free:
/// one connection is used from exactly one thread at a time, regardless of how
/// the library was compiled.
public final class SQLiteConnection: @unchecked Sendable {
    private let handle: OpaquePointer
    private let queue: DispatchQueue
    /// Guards `handle` against use after `close()`, which can race a query.
    private var isOpen = true
    /// Held while interrupting, so a cancellation cannot race `close()` into
    /// calling `sqlite3_interrupt` on a freed handle.
    private let interruptLock = NSLock()

    /// Read by SQLite from *inside* a running statement, every few thousand
    /// virtual-machine instructions.
    ///
    /// This is what actually bounds a long query, and `sqlite3_interrupt` is not.
    /// The interrupt is pushed from outside and is documented to do nothing when
    /// no statement is running and to have no effect on one begun afterwards — so
    /// it has a window it can be spent in, and on a loaded machine it lands in
    /// that window often enough to matter. CI measured a query with a 50ms
    /// timeout running for 36.7s, then 19.4s, then 43.9s across three attempts to
    /// fix it from that side.
    ///
    /// A progress handler is polled by the statement itself, so there is no window
    /// to miss: returning non-zero aborts the step with `SQLITE_INTERRUPT`, which
    /// the taxonomy already maps to `.timeout`. The interrupt is kept alongside it
    /// because it is instant when it does land; this is the guarantee underneath.
    private let progress = ProgressState()

    final class ProgressState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func set(_ value: Bool) { lock.withLock { cancelled = value } }
    }

    /// Opens a database file, creating it if it does not exist.
    ///
    /// - Parameters:
    ///   - path: A filesystem path, or `":memory:"` for a private in-memory
    ///     database that lasts as long as the connection.
    ///   - busyTimeout: How long to wait for another writer before giving up.
    ///     SQLite's default is **zero** — a concurrent writer fails instantly
    ///     with `SQLITE_BUSY` rather than waiting, which is a surprising default
    ///     for anything with more than one process. Five seconds is a saner one.
    ///   - readOnly: Opens with `SQLITE_OPEN_READONLY`, so a write is refused by
    ///     SQLite itself rather than contending for the write lock. Used by
    ///     ``SQLiteReaderPool``: a reader that can write is a reader that can
    ///     deadlock against the writer, and catching it at the connection is far
    ///     clearer than catching it at 3am.
    public init(path: String, busyTimeout: TimeInterval = 5, readOnly: Bool = false) throws {
        var pointer: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(path, &pointer, flags, nil)
        guard code == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open database"
            if let pointer { sqlite3_close_v2(pointer) }
            throw SQLiteError(code: code, message: message, sql: nil)
        }
        handle = pointer
        queue = DispatchQueue(label: "swizzle.sqlite.\(UInt(bitPattern: Int(bitPattern: pointer)))")

        sqlite3_busy_timeout(handle, Int32(busyTimeout * 1000))
        // Every 2000 VDBE instructions — often enough that a cancelled query stops
        // promptly, rare enough that the check costs nothing measurable.
        sqlite3_progress_handler(
            handle, 2000,
            { context in
                guard let context else { return 0 }
                return Unmanaged<ProgressState>.fromOpaque(context)
                    .takeUnretainedValue().isCancelled ? 1 : 0
            },
            Unmanaged.passUnretained(progress).toOpaque()
        )
        // Off by default, and without them every constraint failure reports the
        // same bare `SQLITE_CONSTRAINT` — so a caller cannot tell a unique
        // violation from a foreign-key one, which is exactly the distinction
        // worth branching on.
        sqlite3_extended_result_codes(handle, 1)
        // Foreign keys are off by default for backwards compatibility, which
        // means a schema that declares them does not enforce them. Anyone
        // writing REFERENCES expects it to mean something.
        _ = try? executeSync("PRAGMA foreign_keys = ON")
        // Both pragmas below write, so they are skipped on a read-only handle —
        // where `journal_mode` would fail anyway, and where the mode is already
        // whatever the writer set, because it is a property of the file.
        guard !readOnly else { return }
        // WAL lets readers and one writer proceed concurrently instead of
        // excluding each other. It is persistent, so this is a no-op after the
        // first connection, and it is skipped silently for in-memory databases
        // where it does not apply.
        _ = try? executeSync("PRAGMA journal_mode = WAL")
    }

    /// Opens a private in-memory database.
    public static func inMemory() throws -> SQLiteConnection {
        try SQLiteConnection(path: ":memory:")
    }

    public func close() {
        queue.sync {
            interruptLock.lock()
            defer { interruptLock.unlock() }
            guard isOpen else { return }
            isOpen = false
            sqlite3_close_v2(handle)
        }
    }

    deinit {
        if isOpen { sqlite3_close_v2(handle) }
    }

    // MARK: - Running statements

    /// Runs a statement and returns every row.
    public func query(_ sql: String, _ bindings: [SQLValue] = []) async throws -> [SQLRow] {
        try await withQueue { try self.executeSync(sql, bindings) }
    }

    /// Runs a statement and reports how many rows it changed.
    @discardableResult
    public func execute(_ sql: String, _ bindings: [SQLValue] = []) async throws -> Int {
        try await withQueue {
            _ = try self.executeSync(sql, bindings)
            // `sqlite3_changes` counts the most recent statement only, which is
            // exactly the affected-row count callers expect.
            return Int(sqlite3_changes(self.handle))
        }
    }

    /// The rowid the last insert produced.
    public func lastInsertRowID() async -> Int64 {
        await withUnsafeContinuation { continuation in
            queue.async { continuation.resume(returning: sqlite3_last_insert_rowid(self.handle)) }
        }
    }

    /// Reads something from the raw handle on the connection's own queue.
    ///
    /// For the handful of C calls that are pure reads of connection state —
    /// `sqlite3_get_autocommit` and friends. They still have to happen on the
    /// queue: SQLite is compiled `NOMUTEX`, so the handle belongs to whichever
    /// thread is using it, and reading it from another is a data race however
    /// harmless the call looks.
    func withHandle<T: Sendable>(_ work: @escaping @Sendable (OpaquePointer) -> T) async -> T {
        await withUnsafeContinuation { continuation in
            queue.async { continuation.resume(returning: work(self.handle)) }
        }
    }

    // MARK: - Stepping a statement by hand
    //
    // Exposed so `SQLiteRowSequence` can hold one open statement and step it once
    // per `next()`, which is what makes streaming genuinely demand-driven.

    /// A compiled statement, ready to step.
    ///
    /// A box rather than a bare `OpaquePointer` because that type is explicitly
    /// **not** `Sendable` — for good reason, since a raw pointer says nothing
    /// about who may touch it. The guarantee here is one level up: every use goes
    /// through the connection's serial queue, so exactly one thread ever holds it.
    struct Statement: @unchecked Sendable {
        let pointer: OpaquePointer
    }

    /// Compiles a statement and binds it, leaving it ready to step.
    ///
    /// The caller owns the result and **must** pass it to
    /// ``finalizeStatement(_:)``.
    func prepareStatement(_ sql: String, _ bindings: [SQLValue]) async throws -> Statement {
        try await withQueue { Statement(pointer: try self.prepare(sql, bindings)) }
    }

    /// Steps once. `nil` means the result set is finished.
    func stepStatement(_ statement: Statement) async throws -> SQLRow? {
        try await withQueue {
            let code = sqlite3_step(statement.pointer)
            if code == SQLITE_DONE { return nil }
            guard code == SQLITE_ROW else { throw self.error(code, sql: nil) }
            return self.readRow(statement.pointer)
        }
    }

    /// Rewinds a statement so it can be stepped again.
    ///
    /// `sqlite3_reset` was the one statement-lifecycle call this driver never
    /// made, because every query prepares and finalises its own statement and
    /// never re-runs one. It is here for the measurement that asks whether that
    /// is costing anything — see `SQLitePrepareCostBenchmark`.
    ///
    /// Bindings survive a reset; only the cursor rewinds. `sqlite3_clear_bindings`
    /// is the separate call that discards them, and is deliberately not made:
    /// re-stepping with the same parameters is the point.
    func resetStatement(_ statement: Statement) async throws {
        try await withQueue {
            // The return value repeats the last error from stepping rather than
            // reporting a new one, so a failure here has already been reported by
            // `stepStatement`. Reset is still what makes the statement reusable.
            _ = sqlite3_reset(statement.pointer)
        }
    }

    /// Releases a statement. Fire-and-forget, so it can be called from `deinit`.
    func finalizeStatement(_ statement: Statement) {
        queue.async { sqlite3_finalize(statement.pointer) }
    }

    /// Steps one statement at a time, handing rows to `body` as they are read.
    ///
    /// The pull is genuine: `sqlite3_step` produces exactly one row per call and
    /// does no work until asked, so a table larger than memory is read in bounded
    /// space with no buffer anywhere. Of the three engines this is the one where
    /// backpressure is free rather than engineered.
    func forEachRow(
        _ sql: String, _ bindings: [SQLValue], _ body: @escaping @Sendable (SQLRow) -> Bool
    ) async throws {
        try await withQueue {
            let statement = try self.prepare(sql, bindings)
            defer { sqlite3_finalize(statement) }
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return }
                guard code == SQLITE_ROW else { throw self.error(code, sql: sql) }
                if !body(self.readRow(statement)) { return }
            }
        }
    }

    // MARK: - The queue hop

    /// A one-way flag belonging to a single `withQueue` call.
    ///
    /// Not on the connection: connection-wide state would let a cancelled query
    /// poison the next one.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    private func withQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        // `sqlite3_step` is a blocking C call on a dispatch queue: it does not
        // notice Swift's cancellation, so a cancelled task would otherwise wait
        // for the statement to finish anyway — which makes a timeout bound
        // nothing at all.
        //
        // `sqlite3_interrupt` is the mechanism SQLite provides for exactly this,
        // and it is explicitly documented as safe to call from another thread
        // while a statement is running. The interrupted step returns
        // `SQLITE_INTERRUPT`, which the taxonomy maps to `.timeout`.
        //
        // ## The flag, and the race it closes
        //
        // The interrupt alone is not enough, and the gap is a real one rather
        // than a theoretical one: **`sqlite3_interrupt` does nothing if no
        // statement is running.** Cancellation fires on whatever thread the
        // deadline expires on, while the work is sitting in `queue.async`
        // waiting for its turn. If the interrupt lands in that window it is a
        // no-op, the step then starts *afterwards*, and the statement runs to
        // completion with nothing bounding it.
        //
        // Which side of the window you land on is a scheduling race, so it is
        // invisible on an idle laptop and reproducible on a loaded machine. It
        // failed in CI on macOS as `elapsed → 36.69 seconds < 10.0 seconds`: not
        // a slow interrupt, a query that ran all 200,000,000 iterations because
        // the interrupt arrived before there was anything to interrupt.
        //
        // The flag closes it from the other side. Either the step is already
        // running, and the interrupt stops it, or it has not started, and this
        // refuses to start it.
        let cancelled = Flag()
        let finished = Flag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard self.isOpen else {
                        continuation.resume(throwing: SQLiteError(
                            code: SQLITE_MISUSE, message: "connection is closed", sql: nil
                        ))
                        return
                    }
                    // Cleared **before** the guard below, and the order is the whole of a
                    // race. Clearing after it leaves a window: the guard reads
                    // `cancelled` as false, cancellation then fires and arms the
                    // handler, and this line wipes it — after which the statement
                    // runs with nothing polling it.
                    //
                    // Clearing first has no such window. A cancellation before this
                    // point is caught by the guard; one after it leaves the flag
                    // armed and the handler aborts the step. The clear is here at all
                    // because the flag is per connection while a cancellation belongs
                    // to one call, and the serial queue makes this the exact moment
                    // the previous call is done with it.
                    self.progress.set(false)
                    guard !cancelled.isSet else {
                        // Reported as an interrupt rather than as a cancellation
                        // so it lands in the taxonomy where an interrupted step
                        // does — the caller cannot tell the two apart and should
                        // not have to.
                        continuation.resume(throwing: SQLiteError(
                            code: SQLITE_INTERRUPT,
                            message: "interrupted before the statement began",
                            sql: nil
                        ))
                        return
                    }
                    defer { finished.set() }
                    continuation.resume(with: Result { try work() })
                }
            }
        } onCancel: {
            // Order matters: the flag first, so a step that is about to start
            // sees it. Interrupting first would leave a window where the flag is
            // still clear and the interrupt has already been spent.
            cancelled.set()
            // The handler is the guarantee; the interrupt is the fast path when it
            // happens to land.
            self.progress.set(true)
            self.interrupt()
        }
    }

    /// Occupies the serial queue with work SQLite knows nothing about.
    ///
    /// Test-only, and it exists because `interrupt()` is connection-wide: a
    /// blocker made of SQLite work gets interrupted by the very cancellation
    /// under test, which frees the queue and makes the test pass for the wrong
    /// reason. A plain sleep cannot be interrupted, so the queue stays held.
    func occupyQueueForTesting(seconds: Double) {
        queue.async { Thread.sleep(forTimeInterval: seconds) }
    }

    /// Stops whatever statement is running on this connection, from any thread.
    ///
    /// Task cancellation already does this, so most callers never need it. It is
    /// public for the cases cancellation does not cover: a pool aborting in-flight
    /// work at shutdown, or a cancel button that holds a connection rather than a
    /// `Task`. Both references expose the same capability — GRDB as `interrupt()`
    /// on four types, rusqlite as a `Send + Sync` `InterruptHandle` — and its
    /// absence here was an omission rather than a decision.
    ///
    /// The interrupted statement fails with `SQLITE_INTERRUPT`, which the taxonomy
    /// maps to `.timeout`.
    ///
    /// Deliberately not routed through `queue`: the whole point is to reach a step
    /// that is currently occupying it. `interruptLock` guards only against racing
    /// `close()`, and is never held across a query — rusqlite documents why that
    /// matters, since a lock held across the query would make this useless.
    public func interrupt() {
        interruptLock.lock()
        defer { interruptLock.unlock() }
        guard isOpen else { return }
        sqlite3_interrupt(handle)
    }

    // MARK: - The synchronous core, always on `queue`

    @discardableResult
    private func executeSync(_ sql: String, _ bindings: [SQLValue] = []) throws -> [SQLRow] {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }

        var rows: [SQLRow] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return rows }
            guard code == SQLITE_ROW else { throw error(code, sql: sql) }
            rows.append(readRow(statement))
        }
    }

    /// Compiles exactly one statement, refusing SQL that holds more.
    ///
    /// `sqlite3_prepare_v2`'s fifth argument is the **tail**: it compiles one
    /// statement and points at whatever follows. Passing `nil` there — the easy
    /// thing to do, and what this did — means everything after the first
    /// statement is compiled by nobody and runs never, while the call still
    /// returns `SQLITE_OK`. `INSERT …; INSERT …` inserted one row and reported
    /// success. `rusqlite` refuses the same input with `Error::MultipleStatement`
    /// for the same reason: silently running a fraction of what was asked for is
    /// the worst available outcome.
    ///
    /// The remainder is handed back to SQLite rather than scanned here. A `;`
    /// inside a string literal or a quoted identifier is not a statement
    /// boundary, and SQLite is the authority on which is which — so the question
    /// is "does the rest compile to a statement?", not "is there a semicolon?".
    /// Trailing whitespace, comments and a final `;` all compile to nothing.
    func compileSingleStatement(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        var trailing = false

        // `withCString` rather than passing `sql` directly, and that is
        // load-bearing: implicit `String` → `UnsafePointer<CChar>` bridging
        // creates a buffer that lives only for the duration of *that call*, so
        // the tail points into freed memory the moment it returns. Reading it
        // appeared to work — it found a zero byte, so the check quietly never
        // fired, which is worse than a crash.
        let code: Int32 = sql.withCString { start in
            var tail: UnsafePointer<CChar>?
            let code = sqlite3_prepare_v2(handle, start, -1, &statement, &tail)
            guard code == SQLITE_OK, statement != nil else { return code }

            if let tail, tail.pointee != 0 {
                var next: OpaquePointer?
                let tailCode = sqlite3_prepare_v2(handle, tail, -1, &next, nil)
                if next != nil {
                    sqlite3_finalize(next)
                    trailing = true
                } else if tailCode != SQLITE_OK {
                    // The remainder does not compile. Either way this is not one
                    // statement, and reporting the tail's syntax error would point
                    // at text the caller may not realise is being compiled.
                    trailing = true
                }
            }
            return code
        }

        guard code == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw error(code, sql: sql)
        }
        guard !trailing else {
            sqlite3_finalize(statement)
            throw SQLiteError(
                code: SQLITE_ERROR,
                message: "expected one statement, got more than one — run them "
                    + "separately, or split the script with SQLStatementSplitter "
                    + "as the migration runner does",
                sql: sql
            )
        }
        return statement
    }

    private func prepare(_ sql: String, _ bindings: [SQLValue]) throws -> OpaquePointer {
        let statement = try compileSingleStatement(sql)

        let expected = Int(sqlite3_bind_parameter_count(statement))
        guard expected == bindings.count else {
            sqlite3_finalize(statement)
            throw SQLiteError(
                code: SQLITE_RANGE,
                message: "statement takes \(expected) parameter\(expected == 1 ? "" : "s"), got \(bindings.count)",
                sql: sql
            )
        }

        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, index)
            case .bool(let flag):
                // SQLite has no boolean type; 0 and 1 is the documented convention.
                result = sqlite3_bind_int64(statement, index, flag ? 1 : 0)
            case .int(let number):
                result = sqlite3_bind_int64(statement, index, number)
            case .double(let number):
                result = sqlite3_bind_double(statement, index, number)
            case .text(let string):
                // The length is passed **explicitly** rather than as `-1`.
                //
                // `-1` means "up to the NUL", and SQLite text may legitimately
                // contain NUL bytes: `"before\0after"` bound with `-1` stored six
                // characters, and `length()` on the server agreed. Silent
                // truncation, no error, and the round trip looked fine because
                // the read side truncated identically.
                //
                // SQLITE_TRANSIENT because SQLite copies the bytes; without it
                // the pointer dangles the moment this Swift string is released.
                let bytes = Array(string.utf8)
                guard bytes.count <= Int32.max else {
                    sqlite3_finalize(statement)
                    throw SQLiteError(
                        code: SQLITE_TOOBIG,
                        message: "text parameter is \(bytes.count) bytes, over the "
                            + "\(Int32.max) SQLite can bind",
                        sql: sql
                    )
                }
                result = bytes.withUnsafeBufferPointer { buffer in
                    // A NULL pointer binds SQL NULL, so an empty string needs a
                    // real one — otherwise `""` would silently become `NULL`.
                    guard let base = buffer.baseAddress else {
                        return sqlite3_bind_text(statement, index, "", 0, sqliteTransient)
                    }
                    return base.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                        sqlite3_bind_text(statement, index, $0, Int32(buffer.count), sqliteTransient)
                    }
                }
            case .blob(let bytes):
                result = bytes.isEmpty
                    ? sqlite3_bind_zeroblob(statement, index, 0)
                    : bytes.withUnsafeBufferPointer {
                        sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), sqliteTransient)
                    }
            }
            guard result == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw error(result, sql: sql)
            }
        }
        return statement
    }

    private func readRow(_ statement: OpaquePointer) -> SQLRow {
        let count = Int(sqlite3_column_count(statement))
        var values: [SQLValue] = []
        values.reserveCapacity(count)
        for index in 0..<Int32(count) {
            switch sqlite3_column_type(statement, index) {
            case SQLITE_NULL:
                values.append(.null)
            case SQLITE_INTEGER:
                values.append(.int(sqlite3_column_int64(statement, index)))
            case SQLITE_FLOAT:
                values.append(.double(sqlite3_column_double(statement, index)))
            case SQLITE_BLOB:
                if let pointer = sqlite3_column_blob(statement, index) {
                    let length = Int(sqlite3_column_bytes(statement, index))
                    values.append(.blob(Array(UnsafeRawBufferPointer(start: pointer, count: length))))
                } else {
                    values.append(.blob([]))
                }
            default:
                // Read by **length**, not as a C string. `String(cString:)` stops
                // at the first NUL, and SQLite text may contain them — so
                // `'a' || char(0) || 'b'` arrived as `"a"` and nothing reported a
                // problem. `rusqlite` reads the same way, quoting the SQLite book
                // on calling `column_text` first and `column_bytes` after: the
                // conversion to text can change the length, so the order matters.
                //
                // `String(decoding:as:)` repairs invalid UTF-8 rather than
                // failing. A stray byte in one column should not cost the caller
                // the whole row, and a replacement character is visible where a
                // truncation is not.
                if let text = sqlite3_column_text(statement, index) {
                    let length = Int(sqlite3_column_bytes(statement, index))
                    values.append(
                        .text(String(decoding: UnsafeRawBufferPointer(start: text, count: length), as: UTF8.self))
                    )
                } else {
                    values.append(.null)
                }
            }
        }
        return SQLRow(values: values)
    }

    private func error(_ code: Int32, sql: String?) -> SQLiteError {
        SQLiteError(code: code, message: String(cString: sqlite3_errmsg(handle)), sql: sql)
    }
}

/// `SQLITE_TRANSIENT` is a macro cast, so it does not import. This is the same
/// value, spelled in Swift.
private let sqliteTransient = unsafeBitCast(
    -1, to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self
)

public struct SQLiteError: Error, Sendable, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public let sql: String?

    public var description: String {
        var text = "sqlite error \(code): \(message)"
        if let sql { text += " — \(sql)" }
        return text
    }
}

// MARK: - Describing a statement without running it

/// What SQLite says about a statement's shape.
public struct SQLiteStatementDescription: Sendable, Equatable {
    public var parameterCount: Int
    /// Names for `:name` / `@name` / `$name` placeholders; `nil` for bare `?`
    /// and for `?NNN`, which is numbered but unnamed.
    public var parameterNames: [String?]
    public var columns: [SQLiteColumnDescription]
}

public struct SQLiteColumnDescription: Sendable, Equatable {
    /// As the result set labels it, alias included.
    public var name: String
    /// `sqlite3_column_decltype` — the *declared* type of the base column.
    /// `nil` for any expression, aggregate or literal, which is most of the
    /// interesting cases.
    public var declaredType: String?
    public var databaseName: String?
    public var tableName: String?
    /// The base column's real name, before any alias.
    public var originName: String?
    /// From `sqlite3_table_column_metadata`, and therefore only meaningful when
    /// `originName` is non-nil.
    public var isNotNull: Bool
    public var isPrimaryKey: Bool
    public var isAutoIncrement: Bool

    /// Whether this column traces back to a real table column at all.
    public var hasOrigin: Bool { originName != nil && tableName != nil }
}

extension SQLiteConnection {
    /// Prepares a statement, reads its shape, and throws it away.
    ///
    /// ## Why this rather than exposing `prepareStatement`
    ///
    /// That one takes bindings and hands back a pointer the caller must finalise.
    /// Neither suits a describe: column metadata does not depend on bound values,
    /// and a caller who only wants the shape should not be given a resource to
    /// leak. This prepares, reads, and finalises inside one queue hop.
    ///
    /// ## The C-string trap
    ///
    /// Every string SQLite returns here — column name, decltype, table and origin
    /// names — is owned by the statement and dies at `sqlite3_finalize`, or
    /// earlier if SQLite silently reprepares on the first step. They are copied
    /// into Swift `String`s before the `defer` runs, which is why all the reading
    /// happens in this one closure rather than being handed back as pointers.
    public func describe(_ sql: String) async throws -> SQLiteStatementDescription {
        try await withQueue {
            // Not through `prepare`, which validates the placeholder count
            // against the bindings it was given — a describe has no bindings by
            // design, and `[]` for a statement with two placeholders is the point
            // rather than a mismatch.
            //
            // Through `compileSingleStatement` all the same, for its tail check:
            // a query file entry holding two statements would otherwise be
            // described by its first alone, and the generated function would
            // carry a shape that does not match the SQL it came from.
            let handle = try self.compileSingleStatement(sql)
            defer { sqlite3_finalize(handle) }

            let parameterCount = Int(sqlite3_bind_parameter_count(handle))
            var parameterNames: [String?] = []
            parameterNames.reserveCapacity(parameterCount)
            for ordinal in 1...max(parameterCount, 1) where parameterCount > 0 {
                // NULL for a bare `?`. `?NNN` is numbered but still unnamed,
                // and SQLite reports the `?NNN` text itself, which is not a name
                // anyone would want as a Swift label — so it is dropped too.
                let raw = sqlite3_bind_parameter_name(handle, Int32(ordinal))
                let name = raw.map { String(cString: $0) }
                parameterNames.append(name.flatMap { $0.hasPrefix("?") ? nil : String($0.dropFirst()) })
            }

            var columns: [SQLiteColumnDescription] = []
            let columnCount = Int(sqlite3_column_count(handle))
            columns.reserveCapacity(columnCount)

            for index in 0..<Int32(columnCount) {
                let name = sqlite3_column_name(handle, index).map { String(cString: $0) } ?? ""
                let declared = sqlite3_column_decltype(handle, index).map { String(cString: $0) }
                let database = sqlite3_column_database_name(handle, index).map { String(cString: $0) }
                let table = sqlite3_column_table_name(handle, index).map { String(cString: $0) }
                let origin = sqlite3_column_origin_name(handle, index).map { String(cString: $0) }

                var isNotNull = false
                var isPrimaryKey = false
                var isAutoIncrement = false
                if let table, let origin {
                    var notNull: Int32 = 0
                    var primaryKey: Int32 = 0
                    var autoIncrement: Int32 = 0
                    // The authoritative answer, and the reason
                    // SQLITE_ENABLE_COLUMN_METADATA is compiled in. `decltype`
                    // alone cannot tell you NOT NULL.
                    if sqlite3_table_column_metadata(
                        self.handle, database, table, origin,
                        nil, nil, &notNull, &primaryKey, &autoIncrement
                    ) == SQLITE_OK {
                        isNotNull = notNull != 0
                        isPrimaryKey = primaryKey != 0
                        isAutoIncrement = autoIncrement != 0
                    }
                }

                columns.append(
                    SQLiteColumnDescription(
                        name: name, declaredType: declared,
                        databaseName: database, tableName: table, originName: origin,
                        isNotNull: isNotNull, isPrimaryKey: isPrimaryKey,
                        isAutoIncrement: isAutoIncrement
                    )
                )
            }

            return SQLiteStatementDescription(
                parameterCount: parameterCount,
                parameterNames: parameterNames,
                columns: columns
            )
        }
    }
}

import SwizzleCore
import SwizzleQuery

/// Runs `SwizzleQuery`-built statements against a SQLite database.
///
/// ## The engine that proved the seams
///
/// SQLite differs from the other two in almost every way that matters — no
/// server, no network, no row locks, dynamic typing, one writer at a time — so it
/// is the honest test of whether the capability protocols describe real
/// differences or just the two databases they were written against.
///
/// They held. `SQLite` conforms to `SupportsReturning`, `SupportsOnConflict`,
/// `SupportsInsertIgnore` and `SupportsFullOuterJoin`, and to
/// `SupportsRowLocking` it does **not** — so `.forUpdate()` is a compile error
/// here and nowhere else, which is exactly the shape the design promised.
///
/// One expectation was wrong, and pleasantly so. This was written down as the
/// engine that "cannot stream". It streams better than either of the others:
/// `sqlite3_step` produces one row per call and does no work until asked, so
/// backpressure is the natural behaviour of the API rather than something built
/// on top of it.
public struct SQLiteExecutor: SQLExecutor, SQLStreamingExecutor {
    public typealias Dialect = SQLite

    public let connection: SQLiteConnection

    public init(_ connection: SQLiteConnection) {
        self.connection = connection
    }

    public func execute(sql: String, bindings: [SQLValue]) async throws -> [SQLRow] {
        try await connection.query(sql, bindings)
    }

    @discardableResult
    public func executeUpdate(sql: String, bindings: [SQLValue]) async throws -> Int {
        try await connection.execute(sql, bindings)
    }

    public func stream(sql: String, bindings: [SQLValue]) async throws -> SQLiteRowSequence {
        SQLiteRowSequence(connection: connection, sql: sql, bindings: bindings)
    }
}

/// Rows read one `sqlite3_step` at a time.
///
/// Genuinely demand-driven: `next()` steps the statement exactly once and does
/// nothing until asked again, so a table larger than memory is read in bounded
/// space with no buffer anywhere. Of the three engines this is the one where
/// backpressure is the natural behaviour of the API rather than something built
/// on top of it.
///
/// ## What the first attempt got wrong
///
/// It pushed rows into an `AsyncThrowingStream` with `bufferingPolicy:
/// .bufferingOldest(1)`, on the reasoning that a one-element buffer is a handoff
/// and therefore backpressure. It is not: `yield` never suspends, and when the
/// buffer is full that policy **discards** the new element. The stream silently
/// returned two of three rows. A buffering policy is a dropping policy, and no
/// amount of making the buffer smaller turns it into a brake.
///
/// So the statement stays open across calls instead. That costs an explicit
/// lifetime — hence the class — and the finaliser runs from `deinit`, which is
/// what makes abandoning the sequence safe.
public struct SQLiteRowSequence: AsyncSequence, Sendable {
    public typealias Element = SQLRow

    let connection: SQLiteConnection
    let sql: String
    let bindings: [SQLValue]

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(connection: connection, sql: sql, bindings: bindings)
    }

    /// A class so `deinit` can finalise the statement.
    ///
    /// The alternative — finalising when the walk reaches its end — leaks on
    /// every `break`, which is exactly the bug the MySQL driver shipped and had
    /// to be found with `Prepared_stmt_count`. Letting the iterator's lifetime
    /// own the statement's makes abandonment the same path as completion.
    public final class AsyncIterator: AsyncIteratorProtocol, @unchecked Sendable {
        private let connection: SQLiteConnection
        private let sql: String
        private let bindings: [SQLValue]
        private var statement: SQLiteConnection.Statement?
        private var isFinished = false

        init(connection: SQLiteConnection, sql: String, bindings: [SQLValue]) {
            self.connection = connection
            self.sql = sql
            self.bindings = bindings
        }

        public func next() async throws -> SQLRow? {
            guard !isFinished else { return nil }
            // Compiled on first use rather than in `makeAsyncIterator`, which is
            // not async and so cannot reach the connection's queue.
            let statement: SQLiteConnection.Statement
            if let existing = self.statement {
                statement = existing
            } else {
                statement = try await connection.prepareStatement(sql, bindings)
                self.statement = statement
            }

            do {
                guard let row = try await connection.stepStatement(statement) else {
                    finish()
                    return nil
                }
                return row
            } catch {
                finish()
                throw error
            }
        }

        private func finish() {
            guard !isFinished else { return }
            isFinished = true
            if let statement { connection.finalizeStatement(statement) }
            statement = nil
        }

        deinit {
            if let statement { connection.finalizeStatement(statement) }
        }
    }
}

extension SQLiteConnection {
    /// A typed executor for the query builder.
    public var executor: SQLiteExecutor { SQLiteExecutor(self) }
}

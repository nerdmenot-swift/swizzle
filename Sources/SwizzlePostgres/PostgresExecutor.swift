import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import SwizzleCore
import SwizzlePostgresDriver

/// Bridges the Postgres driver to ``SQLExecutor``.
///
/// ## Why this file shrank
///
/// It used to be the whole Postgres "driver": a translation between our value
/// type and postgres-nio's, plus a per-type decode table, plus a date formatter,
/// plus a workaround for a row count the library would not surface.
///
/// All of that now lives in `SwizzlePostgresDriver`, where it belongs — the wire
/// already produces `SQLValue`, so there is nothing left to translate. What
/// remains is the seam itself.
///
/// ## One thing to know about the pool
///
/// Every call takes a connection from the client's pool and gives it back. That
/// is fine for a single statement and **not** fine for a sequence that has to
/// share a session — `BEGIN` … `COMMIT`, `SET LOCAL`, an advisory lock — because
/// a larger pool could hand each statement a different connection.
///
/// The migrator is the caller that issues those, and `PostgresEngine` pins its
/// client to `maximumConnections = 1` precisely so the session is shared. That
/// invariant lives in another file, so it is repeated here: an executor built
/// over a multi-connection pool is safe for ordinary queries and not for
/// anything that spans statements.
public struct PostgresExecutor: SQLExecutor {
    public typealias Dialect = Postgres

    let client: PostgresClient
    let logger: Logger

    public init(client: PostgresClient, logger: Logger = Logger(label: "swizzle.postgres")) {
        self.client = client
        self.logger = logger
    }

    public func execute(sql: String, bindings: [SQLValue]) async throws -> [SQLRow] {
        // The SQL already carries `$1`-style placeholders, because `Postgres`
        // renders them — the builder and the migrator both went through
        // `writePlaceholder`, so nothing has to be rewritten here.
        let result = try await client.query(sql, bindings)
        return result.rows.map { SQLRow(values: $0) }
    }

    /// Runs a statement and reports how many rows it **changed**.
    ///
    /// ## What this used to do, and why it was wrong
    ///
    /// It drained the row sequence and counted. For a `SELECT` that is the right
    /// number by accident; for the statements this method exists to serve it is
    /// always **zero**, because `UPDATE` and `DELETE` return no rows. So
    /// `db.update(u)…execute()` reported 0 however many rows it changed, and the
    /// unfiltered-write warning dutifully announced "changed 0 rows" while
    /// rewriting a table.
    ///
    /// The count lives in Postgres's *command tag* (`UPDATE 42`), and the driver
    /// parses it now — so this is one line rather than a borrowed-connection
    /// workaround around someone else's access control.
    @discardableResult
    public func executeUpdate(sql: String, bindings: [SQLValue]) async throws -> Int {
        // Nil for commands that report no count — DDL, `BEGIN`, `SET`. Zero is
        // the honest answer there: nothing was changed that Postgres will count.
        try await client.query(sql, bindings).affectedRows ?? 0
    }
}

extension PostgresExecutor: SQLStreamingExecutor {
    /// Rows as they arrive, with real backpressure.
    ///
    /// **New with this driver.** postgres-nio streams too, but the seam was never
    /// wired up here because the executor collected everything before returning.
    /// A result larger than memory now streams in bounded space, which is what
    /// the streaming red line asked for on every engine rather than most of them.
    ///
    /// The connection is held for the sequence's whole life — it has to be, since
    /// the rows are still arriving on it — so this leases one rather than going
    /// through the convenience path.
    public func stream(sql: String, bindings: [SQLValue]) async throws -> PostgresSQLRowSequence {
        let (connection, release) = try await client.leaseConnection()
        do {
            return PostgresSQLRowSequence(
                base: try await connection.stream(sql, bindings), release: release
            )
        } catch {
            // The statement never started, so the connection goes straight back
            // rather than being held by a sequence nobody will iterate.
            await release(true)
            throw error
        }
    }
}

/// Returns the borrowed connection exactly once, however the stream ended.
///
/// ## Why this is a class
///
/// An `AsyncIteratorProtocol` iterator is a **struct**, so it has no `deinit` —
/// and a consumer that `break`s out of a `for try await` never calls `next()`
/// again. Releasing only from `next()` therefore covers the two tidy endings and
/// misses the untidy one: abandonment leaks the lease, and with a
/// single-connection pool the next query waits for the acquisition timeout and
/// then fails. That is not hypothetical — it is what the abandonment test caught
/// the moment it was written.
///
/// So the release lives on a class the iterator holds, and `deinit` is the
/// backstop. The eager path in `next()` stays, because a connection that is idle
/// should go back now rather than whenever ARC gets round to it.
private final class ConnectionReleaseToken: @unchecked Sendable {
    private let release: @Sendable (Bool) async -> Void
    private var isReleased = false
    private let lock = NIOLock()

    init(release: @escaping @Sendable (Bool) async -> Void) {
        self.release = release
    }

    /// The tidy endings: the rows ran out, or the statement failed. Either way
    /// the statement reached `ReadyForQuery`, so the connection is reusable.
    func releaseNow() async {
        guard claim() else { return }
        await release(false)
    }

    deinit {
        // The untidy ending: the consumer walked away mid-result. The driver
        // kills the connection rather than draining an unbounded remainder, so
        // it is **discarded** rather than returned — telling the pool beats
        // having it discover a dead socket on the next borrow.
        //
        // Releasing needs to be async and `deinit` is not, so this is the one
        // place a detached task is the only option. Safe because the lease is
        // still exclusively ours until it is handed back.
        guard claim() else { return }
        let release = release
        Task { await release(true) }
    }

    private func claim() -> Bool {
        lock.withLock {
            guard !isReleased else { return false }
            isReleased = true
            return true
        }
    }
}

/// The neutral row sequence, over the driver's own.
public struct PostgresSQLRowSequence: AsyncSequence, Sendable {
    public typealias Element = SQLRow

    let base: PostgresRowSequence
    private let token: ConnectionReleaseToken

    /// - Parameter release: runs the session reset before the connection goes
    ///   back, so a connection returned mid-stream carries nothing forward.
    init(base: PostgresRowSequence, release: @escaping @Sendable (Bool) async -> Void) {
        self.base = base
        self.token = ConnectionReleaseToken(release: release)
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator(), token: token)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: PostgresRowSequence.AsyncIterator
        /// Held so abandoning the iterator releases the connection.
        private let token: ConnectionReleaseToken
        private var isFinished = false

        fileprivate init(
            base: PostgresRowSequence.AsyncIterator, token: ConnectionReleaseToken
        ) {
            self.base = base
            self.token = token
        }

        public mutating func next() async throws -> SQLRow? {
            guard !isFinished else { return nil }
            do {
                guard let row = try await base.next() else {
                    isFinished = true
                    await token.releaseNow()
                    return nil
                }
                return SQLRow(values: row.values)
            } catch {
                isFinished = true
                await token.releaseNow()
                throw error
            }
        }
    }
}

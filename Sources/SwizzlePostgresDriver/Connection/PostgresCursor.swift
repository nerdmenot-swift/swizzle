import NIOCore
import SwizzleCore

/// A portal read a batch at a time.
///
/// ## How this differs from the ordinary stream
///
/// `PostgresRowSequence` streams under **`autoRead`** backpressure: the server
/// sends the whole result as fast as the socket takes it, and the client stops
/// reading when the consumer falls behind. That works, and it leaves a server
/// backend blocked in a write for as long as the consumer is slow.
///
/// A cursor is the protocol-level alternative. A row-limited `Execute` returns at
/// most `batchSize` rows and then `PortalSuspended`; the server is *idle* between
/// batches rather than blocked, so the connection can sit mid-result for as long
/// as the caller likes. The cost is a round trip per batch, which is why this is
/// not the default.
///
/// Use it when the consumer is slow or the result is enormous; use the stream
/// when the consumer is fast.
public final class PostgresCursor: @unchecked Sendable {
    private let connection: PostgresConnection
    private let batchSize: Int32
    /// The columns, known from the first batch's `RowDescription`.
    public private(set) var schema: PostgresRowSchema?
    /// False once the server has answered with `CommandComplete` rather than
    /// `PortalSuspended`.
    public private(set) var isExhausted = false
    private var hasStarted = false
    private let sql: String
    private let bindings: [[UInt8]?]

    init(
        connection: PostgresConnection, sql: String, bindings: [[UInt8]?], batchSize: Int32
    ) {
        self.connection = connection
        self.sql = sql
        self.bindings = bindings
        self.batchSize = batchSize
    }

    /// The next batch, or an empty array once the portal is done.
    ///
    /// The first call runs the statement; every call after that resumes the
    /// portal. **No re-`Bind`** — the portal holds its position, and binding
    /// again would restart it from the first row, which is an infinite loop that
    /// looks like a slow query.
    public func next() async throws -> [PostgresRow] {
        guard !isExhausted else { return [] }

        let result: PostgresQueryResult
        if hasStarted {
            result = try await connection.runResumePortal(
                maxRows: batchSize, columns: schema?.columns ?? []
            )
        } else {
            hasStarted = true
            result = try await connection.runQueryMode(
                .extended(sql: sql, bindings: bindings, maxRows: batchSize)
            )
        }

        if !result.columns.isEmpty {
            schema = PostgresRowSchema(result.columns)
        }
        // `PortalSuspended` means there is more; `CommandComplete` means there is
        // not. A batch that comes back short is *not* the signal — the server may
        // send fewer rows than asked for and still have more.
        isExhausted = !result.isSuspended

        guard let schema else { return [] }
        return result.rows.map { PostgresRow(values: $0, schema: schema) }
    }

    /// Every remaining row, batch by batch.
    ///
    /// Still bounded per round trip, so this streams — it just hides the batching
    /// from a caller who only wants rows.
    public var rows: AsyncThrowingStream<PostgresRow, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    while true {
                        let batch = try await self.next()
                        if batch.isEmpty { break }
                        for row in batch { continuation.yield(row) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Closes the portal early.
    ///
    /// A suspended portal holds resources on the server until the transaction
    /// ends, so abandoning one inside a long transaction is a leak the connection
    /// alone will not clean up.
    public func close() async throws {
        guard !isExhausted else { return }
        isExhausted = true
        _ = try await connection.query("")
    }
}

extension PostgresConnection {

    /// Opens a cursor over `sql`, reading `batchSize` rows per round trip.
    ///
    /// **Must be inside a transaction.** An unnamed portal is destroyed at the
    /// end of the statement's transaction, and outside an explicit one every
    /// statement is its own transaction — so the portal would be gone before the
    /// second batch was asked for. Postgres reports that as "portal does not
    /// exist", which does not obviously mean "wrap this in a BEGIN".
    public func cursor(
        _ sql: String, _ bindings: [SQLValue] = [], batchSize: Int = 512
    ) async throws -> PostgresCursor {
        guard try await isInTransaction else {
            throw PostgresTransactionError.notInTransaction
        }
        return PostgresCursor(
            connection: self, sql: sql, bindings: try encode(bindings),
            batchSize: Int32(max(1, batchSize))
        )
    }

    /// Runs a prepared mode directly. Internal plumbing for the cursor.
    func runQueryMode(_ mode: PostgresQueryStateMachine.Mode) async throws
        -> PostgresQueryResult
    {
        try await dispatch { .query(mode, $0) }
    }

    func runResumePortal(
        maxRows: Int32, columns: [PostgresColumnDescription]
    ) async throws -> PostgresQueryResult {
        try await dispatch { .query(.resumePortal(maxRows: maxRows, columns: columns), $0) }
    }
}

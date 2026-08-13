import NIOCore
import SwizzleCore

/// Statements that see each other's results, in one implicit transaction.
///
/// ## What `Flush` is for, and why nothing else needed it
///
/// Every other path in this driver ends a statement with `Sync`, which both
/// pushes the results out **and** commits the implicit transaction block. That is
/// right for a single statement and right for a batch pipeline, and it is why
/// `Flush` sat encoded and unused for so long.
///
/// `Flush` is the other half: push the results out and leave the block **open**.
/// That is the one thing `Sync` cannot do, and it buys a shape neither the single
/// statement nor the batch pipeline can express — statements that depend on each
/// other's results while still being atomic together:
///
/// ```swift
/// try await connection.withPipelineSession { session in
///     let order = try await session.execute(
///         "INSERT INTO orders (total) VALUES ($1) RETURNING id", [.int(100)]
///     )
///     try await session.execute(
///         "INSERT INTO items (order_id) VALUES ($1)", [order.rows[0][0]]
///     )
/// }
/// ```
///
/// Both land or neither does, with no explicit `BEGIN` — the `Sync` at the end of
/// the block is what commits.
///
/// ## What it does *not* buy
///
/// Round trips. Each `execute` waits for its own result, so this costs the same
/// as running the statements one at a time. Use ``PostgresConnection/pipeline(_:)``
/// when the statements are independent and the round trips are what you want back.
public final class PostgresPipelineSession: @unchecked Sendable {
    private let connection: PostgresConnection
    /// Set once a statement has failed. The server discards everything until
    /// `Sync`, so sending more would be waiting for replies that will not come.
    private(set) var hasFailed = false

    init(connection: PostgresConnection) {
        self.connection = connection
    }

    /// Runs one statement and waits for its result, without ending the block.
    @discardableResult
    public func execute(
        _ sql: String, _ bindings: [SQLValue] = []
    ) async throws -> PostgresQueryResult {
        guard !hasFailed else {
            throw PostgresTransactionError.transactionAborted
        }
        do {
            return try await connection.runQueryMode(
                .pipelined(sql: sql, bindings: try connection.encode(bindings))
            )
        } catch {
            // One failure ends the session: from here the server is discarding
            // until `Sync`, so a second statement would hang rather than fail.
            hasFailed = true
            throw error
        }
    }
}

extension PostgresConnection {

    /// Opens a pipeline session, and ends it with `Sync`.
    ///
    /// The `Sync` is what commits, so it is sent on **both** paths: on success it
    /// commits the block, and on failure it is what clears the aborted state and
    /// makes the connection usable again. Skipping it after a throw would leave
    /// the session wedged for the next borrower.
    @discardableResult
    public func withPipelineSession<Result>(
        _ body: (PostgresPipelineSession) async throws -> Result
    ) async throws -> Result {
        let session = PostgresPipelineSession(connection: self)
        do {
            let result = try await body(session)
            try await sync()
            return result
        } catch {
            // Best-effort: the connection may already be gone, and reporting that
            // instead of the caller's error would bury the reason.
            try? await sync()
            throw error
        }
    }

    /// A bare `Sync`, ending the implicit transaction block.
    func sync() async throws {
        try await dispatch { .pipelineSync($0) }
    }
}

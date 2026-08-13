import NIOCore
import SwizzleCore

extension PostgresConnection {

    /// Runs several statements with a single `Sync`.
    ///
    /// ## What this saves
    ///
    /// Round trips, not bytes. Serially, ten statements cost ten round trips
    /// because each waits for `ReadyForQuery` before the next goes out. Pipelined
    /// they cost one. Over a link with any latency that is the whole cost of the
    /// batch.
    ///
    /// ## What it costs
    ///
    /// A failure is **not local**. After an error the server discards everything
    /// until `Sync`, so the statements after the failing one never ran — and the
    /// ones before it are *not* undone. `PostgresPipelineError` carries the index
    /// and the completed results precisely so a caller can tell those apart
    /// instead of re-running work that already succeeded.
    ///
    /// **This is not a transaction.** Wrap it in one if the batch has to be
    /// atomic.
    @discardableResult
    public func pipeline(
        _ statements: [PostgresPipelineStatement]
    ) async throws -> [PostgresQueryResult] {
        guard !statements.isEmpty else { return [] }
        return try await dispatch { .pipeline(statements, $0) }
    }

    /// Convenience for statements with no parameters.
    @discardableResult
    public func pipeline(_ sql: [String]) async throws -> [PostgresQueryResult] {
        try await pipeline(sql.map { PostgresPipelineStatement(sql: $0) })
    }

    /// Convenience for the same statement run with different bindings — the
    /// batch-insert shape.
    @discardableResult
    public func pipeline(
        _ sql: String, bindings: [[SQLValue]]
    ) async throws -> [PostgresQueryResult] {
        try await pipeline(
            try bindings.map {
                PostgresPipelineStatement(sql: sql, bindings: try encode($0))
            }
        )
    }

    // MARK: - Parameter type hints

    /// Runs a statement, telling the server what the parameters are.
    ///
    /// ## When the server needs telling
    ///
    /// Usually it does not: Postgres infers parameter types from context, and an
    /// empty type list is the right default. It cannot infer where there is no
    /// context — `SELECT $1` on its own is `could not determine data type of
    /// parameter $1`, and so is a parameter used only inside an ambiguous
    /// operator. The usual workaround is a cast in the SQL; this is the same
    /// thing said in the protocol instead, which leaves the SQL as the author
    /// wrote it.
    ///
    /// A hint that disagrees with the statement is an error from the server
    /// rather than a silent coercion, which is the right way round.
    public func query(
        _ sql: String, _ bindings: [SQLValue], parameterTypes: [PostgresOID]
    ) async throws -> PostgresQueryResult {
        let mode = PostgresQueryStateMachine.Mode.extended(
            sql: sql, bindings: try encode(bindings),
            parameterTypes: parameterTypes.map(\.rawValue)
        )
        return try await dispatch { .query(mode, $0) }
    }

    // MARK: - Close

    /// Deallocates a named prepared statement on the server.
    ///
    /// The cache closes what it evicts, so this is for statements a caller named
    /// itself — with `PREPARE`, or through another tool sharing the session.
    public func closeStatement(named name: String) async throws {
        try await dispatch { .close(.statement, name: name, $0) }
    }

    /// Closes a named portal.
    ///
    /// A suspended portal holds server resources until its transaction ends, so a
    /// cursor abandoned inside a long transaction is a leak that closing fixes.
    public func closePortal(named name: String) async throws {
        try await dispatch { .close(.portal, name: name, $0) }
    }
}

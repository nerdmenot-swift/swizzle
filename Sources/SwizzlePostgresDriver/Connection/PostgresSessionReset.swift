import SwizzleCore

extension PostgresConnection {

    /// Checks the connection is alive and the server is responding.
    ///
    /// An empty query is the idiom: the server answers `EmptyQueryResponse` and
    /// `ReadyForQuery` without planning anything, so it costs one round trip and
    /// no work. `SELECT 1` is the folk version and is strictly worse — it goes
    /// through the planner and shows up in `pg_stat_statements` as noise.
    public func ping() async throws {
        _ = try await query("")
    }

    /// Returns the session to a clean state before the connection is reused.
    ///
    /// ## What this actually protects against
    ///
    /// A pooled connection carries session state across borrowers: `SET`
    /// variables, temporary tables, prepared statements, `LISTEN` registrations,
    /// cursors, and — worst of all — an **open transaction**. A borrower that
    /// returns a connection mid-transaction hands the next one a session that
    /// silently participates in a transaction it never opened, and whose locks it
    /// cannot see.
    ///
    /// `DISCARD ALL` is Postgres's own answer to this and is the analogue of
    /// MySQL's `COM_RESET_CONNECTION`. It rolls back, drops the temporary schema,
    /// deallocates prepared statements, and resets every `SET`.
    ///
    /// **It deallocates prepared statements**, which is why the driver's own
    /// statement cache is cleared alongside it. Leaving the cache populated would
    /// have it bind names the server has just thrown away — every subsequent
    /// query failing with "prepared statement does not exist", on a connection
    /// that looks perfectly healthy.
    public func resetSession() async throws {
        // `DISCARD ALL` cannot run inside a transaction, and a connection being
        // returned may well be in one — that is the case this exists for. The
        // rollback is unconditional and harmless outside a transaction.
        _ = try await query("ROLLBACK")
        _ = try await query("DISCARD ALL")
        try await clearStatementCache()
    }

    /// Drops the driver's record of server-side prepared statements.
    ///
    /// No `Close` messages are sent: this is called when the server has already
    /// discarded them, and closing names that no longer exist would fail.
    func clearStatementCache() async throws {
        let cleared = channel.eventLoop.makePromise(of: Void.self)
        channel.eventLoop.execute { [channel] in
            do {
                let handler = try channel.pipeline.syncOperations
                    .handler(type: PostgresCommandHandler.self)
                handler.forgetPreparedStatements()
                cleared.succeed(())
            } catch {
                // No command handler means no cache to clear, which is not a
                // failure — it is a connection that never finished its handshake.
                cleared.succeed(())
            }
        }
        try await cleared.futureResult.get()
    }
}

extension PostgresCommandHandler {
    /// Forgets every cached statement without closing anything.
    ///
    /// Deliberately not `removeAll` + close: the two callers — `DISCARD ALL` and
    /// the stale-plan retry — are both cases where the *server* has already
    /// discarded the statements, so a `Close` would name something that no longer
    /// exists.
    func forgetPreparedStatements() {
        forgetCache()
    }
}

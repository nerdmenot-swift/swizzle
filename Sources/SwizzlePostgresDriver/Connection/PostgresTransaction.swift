import SwizzleCore

/// How a transaction should be started.
public struct PostgresTransactionOptions: Sendable {

    public enum IsolationLevel: String, Sendable, CaseIterable {
        /// Accepted and **silently treated as `READ COMMITTED`** — Postgres has
        /// no dirty reads to offer. Listed because a caller porting from another
        /// engine will write it, and it should not be an error.
        case readUncommitted = "READ UNCOMMITTED"
        case readCommitted = "READ COMMITTED"
        case repeatableRead = "REPEATABLE READ"
        /// Genuinely serializable here, via predicate locking — unlike MySQL,
        /// where it is repeatable read plus shared locks. The cost is
        /// `40001` serialization failures, which the error taxonomy already
        /// classifies as safe to retry.
        case serializable = "SERIALIZABLE"
    }

    public enum AccessMode: Sendable {
        case readOnly
        case readWrite
    }

    public var isolationLevel: IsolationLevel?
    /// `READ ONLY` rejects writes outright, which makes it a useful guard around
    /// reporting queries.
    public var accessMode: AccessMode?

    /// `DEFERRABLE`, which has no MySQL equivalent.
    ///
    /// Only meaningful for a `SERIALIZABLE READ ONLY` transaction: it waits for a
    /// snapshot that cannot produce a serialization failure, trading start-up
    /// latency for the guarantee that a long report will not be aborted and have
    /// to run again. Ignored by Postgres in any other combination.
    public var deferrable: Bool

    public init(
        isolationLevel: IsolationLevel? = nil,
        accessMode: AccessMode? = nil,
        deferrable: Bool = false
    ) {
        self.isolationLevel = isolationLevel
        self.accessMode = accessMode
        self.deferrable = deferrable
    }

    public static let `default` = PostgresTransactionOptions()

    /// The `BEGIN` this describes.
    ///
    /// Everything goes on the `BEGIN` itself rather than a preceding
    /// `SET TRANSACTION`. MySQL needs the two-statement form because
    /// `START TRANSACTION` takes no isolation level; Postgres accepts the lot in
    /// one statement, so there is no window where a second connection could see
    /// a half-configured session.
    public var beginStatement: String {
        var parts = ["BEGIN"]
        if let isolationLevel {
            parts.append("ISOLATION LEVEL \(isolationLevel.rawValue)")
        }
        if let accessMode {
            parts.append(accessMode == .readOnly ? "READ ONLY" : "READ WRITE")
        }
        if deferrable {
            parts.append("DEFERRABLE")
        }
        return parts.joined(separator: " ")
    }
}

public enum PostgresTransactionError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Postgres warns `there is already a transaction in progress` and carries
    /// on, so a nested `BEGIN` is a no-op whose `COMMIT` would end the *outer*
    /// transaction. Refused rather than flattened.
    case alreadyInTransaction
    case notInTransaction
    /// The transaction is in the aborted state: Postgres rejects every statement
    /// with `25P02` until it is rolled back.
    case transactionAborted

    public var description: String {
        switch self {
        case .alreadyInTransaction:
            "a transaction is already open — Postgres has no nested transactions, "
                + "so use withSavepoint(_:_:) for a nested scope"
        case .notInTransaction:
            "no transaction is open"
        case .transactionAborted:
            "the transaction is aborted and every statement will be rejected with "
                + "25P02 until it is rolled back"
        }
    }
}

extension PostgresConnection {

    /// What the server says about the current transaction.
    ///
    /// **Reported by the server, not tracked by us.** Every `ReadyForQuery`
    /// carries the status, so this cannot drift from the truth the way a
    /// client-side flag would — and it is how the aborted state becomes visible
    /// at all.
    public var transactionStatus: PostgresTransactionStatus {
        get async throws {
            try await commandHandlerForTransaction().transactionStatus
        }
    }

    public var isInTransaction: Bool {
        get async throws {
            try await transactionStatus != .idle
        }
    }

    // MARK: - Explicit control

    public func beginTransaction(
        _ options: PostgresTransactionOptions = .default
    ) async throws {
        guard try await !isInTransaction else {
            throw PostgresTransactionError.alreadyInTransaction
        }
        _ = try await query(options.beginStatement)
    }

    public func commitTransaction() async throws {
        guard try await isInTransaction else {
            throw PostgresTransactionError.notInTransaction
        }
        _ = try await query("COMMIT")
    }

    public func rollbackTransaction() async throws {
        guard try await isInTransaction else {
            throw PostgresTransactionError.notInTransaction
        }
        _ = try await query("ROLLBACK")
    }

    // MARK: - Scoped

    /// Runs `body` in a transaction, committing on success and rolling back on
    /// any error.
    ///
    /// ## Two ways this differs from MySQL, both in Postgres's favour
    ///
    /// **DDL is transactional.** `CREATE TABLE`, `ALTER`, `DROP` all roll back
    /// here. MySQL commits implicitly on DDL, which is why its version has to
    /// detect a transaction that ended underneath the block and report it; there
    /// is no such case to detect.
    ///
    /// **A failed statement aborts the whole transaction.** After any error
    /// Postgres rejects everything with `25P02` until a rollback — there is no
    /// carrying on past a failed statement as MySQL allows. So a `body` that
    /// catches an error and continues will find every subsequent statement
    /// failing, and the commit is refused rather than sent, because committing an
    /// aborted transaction silently performs a rollback.
    @discardableResult
    public func withTransaction<Result>(
        _ options: PostgresTransactionOptions = .default,
        _ body: (PostgresConnection) async throws -> Result
    ) async throws -> Result {
        try await beginTransaction(options)

        let result: Result
        do {
            result = try await body(self)
        } catch {
            // The rollback is best-effort: the connection may already be gone,
            // and reporting *that* instead of the caller's error would bury the
            // reason any of this happened.
            try? await query("ROLLBACK")
            throw error
        }

        // `COMMIT` on an aborted transaction performs a **rollback** and reports
        // success. A caller that swallowed an error inside `body` would otherwise
        // be told its work was committed when it was discarded.
        if try await transactionStatus == .failed {
            _ = try? await query("ROLLBACK")
            throw PostgresTransactionError.transactionAborted
        }

        _ = try await query("COMMIT")
        return result
    }

    // MARK: - Savepoints

    /// Runs `body` inside a savepoint, releasing it on success and rolling back
    /// to it on error.
    ///
    /// This is the only nesting Postgres has, and it is also the *only* way to
    /// recover from a failed statement without discarding the whole
    /// transaction — rolling back to a savepoint clears the aborted state.
    @discardableResult
    public func withSavepoint<Result>(
        _ name: String? = nil,
        _ body: (PostgresConnection) async throws -> Result
    ) async throws -> Result {
        guard try await isInTransaction else {
            throw PostgresTransactionError.notInTransaction
        }
        let identifier = Self.savepointIdentifier(name)

        _ = try await query("SAVEPOINT \(identifier)")
        do {
            let result = try await body(self)
            // Releasing keeps the savepoint stack bounded in a long transaction;
            // the work itself stays part of the transaction.
            _ = try await query("RELEASE SAVEPOINT \(identifier)")
            return result
        } catch {
            // This is what clears `25P02`, so it has to come before anything else
            // is attempted on the connection.
            _ = try? await query("ROLLBACK TO SAVEPOINT \(identifier)")
            _ = try? await query("RELEASE SAVEPOINT \(identifier)")
            throw error
        }
    }

    public func savepoint(_ name: String) async throws {
        _ = try await query("SAVEPOINT \(Self.savepointIdentifier(name))")
    }

    public func rollbackToSavepoint(_ name: String) async throws {
        _ = try await query("ROLLBACK TO SAVEPOINT \(Self.savepointIdentifier(name))")
    }

    public func releaseSavepoint(_ name: String) async throws {
        _ = try await query("RELEASE SAVEPOINT \(Self.savepointIdentifier(name))")
    }

    /// Quotes a savepoint name, generating one when none was supplied.
    ///
    /// A savepoint name is an identifier spliced into SQL — Postgres accepts no
    /// placeholder here — so it is double-quoted with any embedded quote doubled.
    /// Without that, a caller-supplied name is an injection point in the one
    /// place a parameter cannot be used.
    public static func savepointIdentifier(_ name: String?) -> String {
        let raw = name ?? "swizzle_sp_\(UInt32.random(in: 0..<UInt32.max))"
        return "\"\(raw.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func commandHandlerForTransaction() async throws -> PostgresCommandHandler {
        let channel = self.channel
        return try await channel.eventLoop.submit {
            try channel.pipeline.syncOperations.handler(type: PostgresCommandHandler.self)
        }.get()
    }
}

extension PostgresClient {
    /// Leases a connection and runs `body` inside a transaction on it.
    ///
    /// The connection is pinned for the whole transaction, because a transaction
    /// is session state and cannot span connections. This is the API that makes
    /// the pool safe to use for multi-statement work — `withConnection` alone
    /// leaves the caller to remember.
    @discardableResult
    public func withTransaction<Result: Sendable>(
        _ options: PostgresTransactionOptions = .default,
        _ body: @Sendable (PostgresConnection) async throws -> Result
    ) async throws -> Result {
        try await withConnection { connection in
            try await connection.withTransaction(options, body)
        }
    }
}

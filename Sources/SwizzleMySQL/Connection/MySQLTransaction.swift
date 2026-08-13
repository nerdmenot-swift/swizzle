import NIOCore

/// How a transaction should be started.
public struct MySQLTransactionOptions: Sendable {
    public enum IsolationLevel: String, Sendable, CaseIterable {
        case readUncommitted = "READ UNCOMMITTED"
        case readCommitted = "READ COMMITTED"
        case repeatableRead = "REPEATABLE READ"
        case serializable = "SERIALIZABLE"
    }

    public enum AccessMode: Sendable {
        case readOnly
        case readWrite
    }

    /// Applied with `SET TRANSACTION ISOLATION LEVEL` *before* the transaction
    /// starts — it configures the next transaction, not the current one.
    public var isolationLevel: IsolationLevel?
    /// `READ ONLY` lets the server skip some bookkeeping and rejects writes
    /// outright, which is a useful guard around reporting queries.
    public var accessMode: AccessMode?
    /// `START TRANSACTION WITH CONSISTENT SNAPSHOT` — takes the read view
    /// immediately rather than at the first read. InnoDB only, and only
    /// meaningful at REPEATABLE READ.
    public var consistentSnapshot: Bool

    public init(
        isolationLevel: IsolationLevel? = nil,
        accessMode: AccessMode? = nil,
        consistentSnapshot: Bool = false
    ) {
        self.isolationLevel = isolationLevel
        self.accessMode = accessMode
        self.consistentSnapshot = consistentSnapshot
    }

    public static let `default` = MySQLTransactionOptions()
}

public enum MySQLTransactionError: Error, Sendable, Equatable {
    /// MySQL has no nested transactions — `START TRANSACTION` inside one
    /// commits the outer transaction implicitly. Use a savepoint instead.
    case alreadyInTransaction
    /// A commit or rollback was issued with no transaction open, usually because
    /// something committed it implicitly.
    case notInTransaction
    /// The transaction ended before the block did — almost always because a DDL
    /// statement caused an implicit commit.
    case transactionEndedUnexpectedly(String)
}

extension MySQLConnection {

    /// True while a transaction is open, **as the server reports it**.
    public var isInTransaction: Bool { sessionState.isInTransaction }

    // MARK: - Explicit control

    /// Issues `START TRANSACTION`, applying options first.
    ///
    /// Isolation level and access mode are separate `SET TRANSACTION`
    /// statements that configure the *next* transaction, so they must precede
    /// `START TRANSACTION` rather than being folded into it.
    public func beginTransaction(
        _ options: MySQLTransactionOptions = .default
    ) async throws {
        guard !isInTransaction else {
            throw MySQLTransactionError.alreadyInTransaction
        }

        if let level = options.isolationLevel {
            try await query("SET TRANSACTION ISOLATION LEVEL \(level.rawValue)")
        }
        if let mode = options.accessMode {
            try await query(mode == .readOnly ? "SET TRANSACTION READ ONLY" : "SET TRANSACTION READ WRITE")
        }
        try await query(
            options.consistentSnapshot
                ? "START TRANSACTION WITH CONSISTENT SNAPSHOT"
                : "START TRANSACTION"
        )
    }

    public func commit() async throws {
        guard isInTransaction else { throw MySQLTransactionError.notInTransaction }
        try await query("COMMIT")
    }

    public func rollback() async throws {
        guard isInTransaction else { throw MySQLTransactionError.notInTransaction }
        try await query("ROLLBACK")
    }

    // MARK: - Scoped

    /// Runs `body` inside a transaction, committing on success and rolling back
    /// on any thrown error.
    ///
    /// Nesting is rejected rather than silently flattened: in MySQL a second
    /// `START TRANSACTION` commits the outer one, so a nested call that appeared
    /// to work would quietly have committed work the caller believed was still
    /// provisional. Use ``withSavepoint(_:_:)`` for nested scopes.
    ///
    /// **DDL commits implicitly.** `CREATE TABLE`, `DROP TABLE`, `ALTER`,
    /// `TRUNCATE` and friends end the transaction where they stand — MySQL has
    /// no transactional DDL. A rollback afterwards cannot undo anything before
    /// them either. This is detected and surfaced rather than left silent.
    @discardableResult
    public func withTransaction<Result>(
        _ options: MySQLTransactionOptions = .default,
        _ body: (MySQLConnection) async throws -> Result
    ) async throws -> Result {
        try await beginTransaction(options)

        let result: Result
        do {
            result = try await body(self)
        } catch {
            // Only roll back if there is still a transaction to roll back; DDL
            // inside the block may have committed it already.
            if isInTransaction {
                try? await query("ROLLBACK")
            }
            throw error
        }

        guard isInTransaction else {
            throw MySQLTransactionError.transactionEndedUnexpectedly(
                "the transaction was committed before the block finished — a DDL "
                + "statement (CREATE/DROP/ALTER/TRUNCATE) commits implicitly in MySQL"
            )
        }
        try await query("COMMIT")
        return result
    }

    // MARK: - Savepoints

    /// Runs `body` inside a savepoint, releasing it on success and rolling back
    /// to it on error.
    ///
    /// This is MySQL's only form of nesting. A rollback here undoes just the
    /// work inside `body`, leaving the enclosing transaction open.
    @discardableResult
    public func withSavepoint<Result>(
        _ name: String? = nil,
        _ body: (MySQLConnection) async throws -> Result
    ) async throws -> Result {
        guard isInTransaction else {
            throw MySQLTransactionError.notInTransaction
        }
        let identifier = MySQLConnection.savepointIdentifier(name)

        try await query("SAVEPOINT \(identifier)")
        do {
            let result = try await body(self)
            // Releasing keeps the savepoint stack from growing without bound in
            // a long transaction; the work itself stays part of the transaction.
            try await query("RELEASE SAVEPOINT \(identifier)")
            return result
        } catch {
            if isInTransaction {
                try? await query("ROLLBACK TO SAVEPOINT \(identifier)")
                try? await query("RELEASE SAVEPOINT \(identifier)")
            }
            throw error
        }
    }

    public func savepoint(_ name: String) async throws {
        try await query("SAVEPOINT \(MySQLConnection.savepointIdentifier(name))")
    }

    public func rollbackToSavepoint(_ name: String) async throws {
        try await query("ROLLBACK TO SAVEPOINT \(MySQLConnection.savepointIdentifier(name))")
    }

    public func releaseSavepoint(_ name: String) async throws {
        try await query("RELEASE SAVEPOINT \(MySQLConnection.savepointIdentifier(name))")
    }

    /// Quotes a savepoint name, generating one when none was supplied.
    ///
    /// Savepoint names are identifiers spliced into SQL, so they are
    /// backtick-quoted and any embedded backtick is doubled. Without that a
    /// caller-supplied name would be an injection point in the one place a
    /// parameter cannot be used — MySQL does not accept a placeholder here.
    static func savepointIdentifier(_ name: String?) -> String {
        let raw = name ?? "swizzle_sp_\(UInt32.random(in: 0..<UInt32.max))"
        return "`\(raw.replacingOccurrences(of: "`", with: "``"))`"
    }
}

extension MySQLClient {
    /// Leases a connection and runs `body` inside a transaction on it.
    ///
    /// The connection is pinned for the whole transaction — MySQL transactions
    /// are session state, so they cannot span connections.
    @discardableResult
    public func withTransaction<Result: Sendable>(
        _ options: MySQLTransactionOptions = .default,
        _ body: @Sendable (MySQLConnection) async throws -> Result
    ) async throws -> Result {
        try await withConnection { connection in
            try await connection.withTransaction(options, body)
        }
    }
}

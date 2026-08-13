import CSQLite
import Foundation
import SwizzleCore

/// Transactions, which this driver did not have.
///
/// MySQL and Postgres both grew a `withTransaction` early; SQLite was left with
/// "issue `BEGIN` yourself as a query". `rusqlite` has `Connection::transaction`
/// with the same three behaviours, so this was a gap against the reference and an
/// inconsistency between our own three engines at once.
public struct SQLiteTransactionOptions: Sendable, Equatable {
    /// SQLite's three `BEGIN` flavours. They differ in *when* locks are taken,
    /// which is the whole of concurrency control in a single-writer database.
    public enum Behavior: String, Sendable, CaseIterable {
        /// Take no lock until the first read or write. The default, and SQLite's.
        ///
        /// The catch worth knowing: a deferred transaction that reads and *then*
        /// writes can fail with `SQLITE_BUSY` at the upgrade, after work has
        /// already been done — and it cannot be retried in place, because the
        /// read it already performed may no longer be valid. `immediate` is the
        /// fix for a read-then-write transaction.
        case deferred = "DEFERRED"
        /// Take the write lock at `BEGIN`.
        ///
        /// Costs concurrency and buys predictability: contention surfaces
        /// immediately, where it can be retried cleanly, rather than partway
        /// through.
        case immediate = "IMMEDIATE"
        /// Take the write lock at `BEGIN` and keep other connections from reading.
        ///
        /// Only meaningfully different from `immediate` outside WAL — in WAL
        /// mode readers are never blocked by a writer, so this is the same thing
        /// with a stronger name.
        case exclusive = "EXCLUSIVE"
    }

    public var behavior: Behavior

    public init(behavior: Behavior = .deferred) {
        self.behavior = behavior
    }

    public static let `default` = SQLiteTransactionOptions()
    public static let deferred = SQLiteTransactionOptions(behavior: .deferred)
    public static let immediate = SQLiteTransactionOptions(behavior: .immediate)
    public static let exclusive = SQLiteTransactionOptions(behavior: .exclusive)
}

extension SQLiteConnection {

    /// Whether a transaction is open, **as SQLite sees it**.
    ///
    /// `sqlite3_get_autocommit` rather than a flag of our own, for the reason the
    /// MySQL driver reads the server's status word rather than counting `BEGIN`s:
    /// local bookkeeping drifts from reality exactly when it matters, and does so
    /// silently.
    ///
    /// SQLite drifts in a specific way. Some errors — `SQLITE_FULL`,
    /// `SQLITE_IOERR`, `SQLITE_BUSY` and `SQLITE_NOMEM`, depending on when they
    /// strike — cause SQLite to **roll the transaction back itself**. A client
    /// counting `BEGIN`s still believes it is in a transaction, and its `ROLLBACK`
    /// then fails with "cannot rollback - no transaction is active", turning one
    /// error into two and hiding the first.
    public var isInTransaction: Bool {
        get async { await withHandle { sqlite3_get_autocommit($0) == 0 } }
    }

    /// Runs `body` inside a transaction, committing on return and rolling back on
    /// any thrown error.
    ///
    /// Nesting is refused rather than silently flattened: SQLite has no nested
    /// `BEGIN`, so an inner one would either error or — worse, if we swallowed it
    /// — leave the inner scope's "commit" ending the outer transaction. Use
    /// ``withSavepoint(_:_:)`` for that, which is what savepoints are for.
    @discardableResult
    public func withTransaction<Result>(
        _ options: SQLiteTransactionOptions = .default,
        _ body: (SQLiteConnection) async throws -> Result
    ) async throws -> Result {
        guard await !isInTransaction else {
            throw SQLiteError(
                code: SQLITE_MISUSE,
                message: "already in a transaction — SQLite has no nested BEGIN; "
                    + "use withSavepoint to scope work inside one",
                sql: nil
            )
        }

        _ = try await query("BEGIN \(options.behavior.rawValue)")

        let result: Result
        do {
            result = try await body(self)
        } catch {
            // Only if there is still something to roll back. SQLite may have done
            // it already, and a `ROLLBACK` with no transaction active raises an
            // error that would replace the one actually worth reporting.
            if await isInTransaction {
                _ = try? await query("ROLLBACK")
            }
            throw error
        }

        // The same check on the way out, and it is not symmetry for its own sake:
        // a body that provoked an automatic rollback and then returned normally
        // would otherwise `COMMIT` with nothing open, and the caller would be told
        // its work committed.
        guard await isInTransaction else {
            throw SQLiteError(
                code: SQLITE_ABORT,
                message: "the transaction was rolled back by SQLite before it could "
                    + "be committed — usually a full disk, an I/O error, or a lock "
                    + "SQLite could not take",
                sql: nil
            )
        }
        _ = try await query("COMMIT")
        return result
    }

    /// Runs `body` inside a savepoint, releasing it on return and rolling back to
    /// it on error.
    ///
    /// Unlike ``withTransaction(_:_:)`` these nest, which is the point. A
    /// savepoint outside any transaction starts one implicitly — SQLite's own
    /// behaviour, kept rather than second-guessed.
    @discardableResult
    public func withSavepoint<Result>(
        _ name: String? = nil,
        _ body: (SQLiteConnection) async throws -> Result
    ) async throws -> Result {
        let identifier = name ?? "swizzle_sp_\(UInt32.random(in: 0..<UInt32.max))"
        let quoted = Self.quoteIdentifier(identifier)

        _ = try await query("SAVEPOINT \(quoted)")

        let result: Result
        do {
            result = try await body(self)
        } catch {
            // `ROLLBACK TO` rewinds to the savepoint and *keeps it*, so the
            // `RELEASE` is what actually removes it. Doing only the first leaves
            // the savepoint on the stack and the transaction open.
            if await isInTransaction {
                _ = try? await query("ROLLBACK TO \(quoted)")
                _ = try? await query("RELEASE \(quoted)")
            }
            throw error
        }

        _ = try await query("RELEASE \(quoted)")
        return result
    }

    /// A savepoint name is an identifier spliced into SQL — SQLite takes no
    /// placeholder there — so it is quoted exactly as the other two drivers quote
    /// theirs, doubling any embedded quote.
    static func quoteIdentifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

import Foundation
import SwizzleCore
import Testing

@testable import SwizzleSQLite

/// Transactions and savepoints.
///
/// MySQL and Postgres both had `withTransaction` early; SQLite was left telling
/// callers to issue `BEGIN` themselves. `rusqlite` has `Connection::transaction`
/// with the same three behaviours, so this was a gap against the reference and an
/// inconsistency between our own three engines at once.
@Suite("SQLite transactions")
struct SQLiteTransactionTests {

    static func seeded() async throws -> SQLiteConnection {
        let connection = try SQLiteConnection.inMemory()
        _ = try await connection.query("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
        return connection
    }

    @Test("a committed transaction keeps its work")
    func commits() async throws {
        let connection = try await Self.seeded()
        defer { connection.close() }

        try await connection.withTransaction { db in
            _ = try await db.query("INSERT INTO t VALUES (1, 'a')")
            _ = try await db.query("INSERT INTO t VALUES (2, 'b')")
        }

        let rows = try await connection.query("SELECT count(*) FROM t")
        #expect(rows[0].values[0] == .int(2))
    }

    /// The half that matters: a throw must undo **everything**, not just the
    /// statement that failed.
    @Test("a thrown error rolls the whole transaction back")
    func rollsBack() async throws {
        let connection = try await Self.seeded()
        defer { connection.close() }

        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await connection.withTransaction { db in
                _ = try await db.query("INSERT INTO t VALUES (1, 'a')")
                throw Boom()
            }
        }

        let rows = try await connection.query("SELECT count(*) FROM t")
        #expect(rows[0].values[0] == .int(0))
        #expect(await connection.isInTransaction == false)
    }

    /// A SQLite error inside the body is the common case, and the rollback has to
    /// survive the connection being mid-error.
    @Test("a constraint failure rolls back and leaves the connection usable")
    func constraintFailureRollsBack() async throws {
        let connection = try await Self.seeded()
        defer { connection.close() }

        _ = try await connection.query("INSERT INTO t VALUES (1, 'first')")

        await #expect(throws: SQLiteError.self) {
            try await connection.withTransaction { db in
                _ = try await db.query("INSERT INTO t VALUES (2, 'second')")
                _ = try await db.query("INSERT INTO t VALUES (1, 'duplicate')")
            }
        }

        let rows = try await connection.query("SELECT count(*) FROM t")
        #expect(rows[0].values[0] == .int(1), "the successful insert must have been undone too")
        #expect(await connection.isInTransaction == false)

        // And the connection still works, which a stuck-open transaction would
        // prevent.
        _ = try await connection.query("INSERT INTO t VALUES (3, 'after')")
    }

    // MARK: - State comes from SQLite, not from us

    /// `sqlite3_get_autocommit` rather than counting `BEGIN`s, which is what lets
    /// the rollback path notice SQLite already did the work.
    @Test("isInTransaction reflects SQLite's own view")
    func isInTransactionTracksSQLite() async throws {
        let connection = try await Self.seeded()
        defer { connection.close() }

        #expect(await connection.isInTransaction == false)
        try await connection.withTransaction { db in
            #expect(await db.isInTransaction)
        }
        #expect(await connection.isInTransaction == false)

        // Including a transaction started as raw SQL, which a counter of our own
        // would not see at all.
        _ = try await connection.query("BEGIN")
        #expect(await connection.isInTransaction)
        _ = try await connection.query("ROLLBACK")
        #expect(await connection.isInTransaction == false)
    }

    /// **The case the whole design turns on.** `ROLLBACK` inside the body ends
    /// the transaction; the wrapper must notice rather than issue a `COMMIT` that
    /// fails — or worse, appear to succeed.
    @Test("a body that ends the transaction itself is reported, not papered over")
    func bodyEndingTheTransaction() async throws {
        let connection = try await Self.seeded()
        defer { connection.close() }

        await #expect(throws: SQLiteError.self) {
            try await connection.withTransaction { db in
                _ = try await db.query("INSERT INTO t VALUES (1, 'a')")
                _ = try await db.query("ROLLBACK")
            }
        }
        #expect(await connection.isInTransaction == false)

        let rows = try await connection.query("SELECT count(*) FROM t")
        #expect(rows[0].values[0] == .int(0))
    }

    /// SQLite has no nested `BEGIN`. Refusing is the honest answer: swallowing
    /// the inner one would make the inner scope's "commit" end the *outer*
    /// transaction, so work the caller believed provisional would be durable.
    @Test("a nested transaction is refused and names the alternative")
    func nestingIsRefused() async throws {
        let connection = try await Self.seeded()
        defer { connection.close() }

        try await connection.withTransaction { db in
            do {
                try await db.withTransaction { _ in }
                Issue.record("expected a refusal")
            } catch let error as SQLiteError {
                #expect(error.message.contains("withSavepoint"))
            }
        }
    }

    // MARK: - Savepoints

    @Test("a savepoint rolls back only its own work")
    func savepointScopesItsWork() async throws {
        let connection = try await Self.seeded()
        defer { connection.close() }

        struct Boom: Error {}
        try await connection.withTransaction { db in
            _ = try await db.query("INSERT INTO t VALUES (1, 'kept')")

            await #expect(throws: Boom.self) {
                try await db.withSavepoint { inner in
                    _ = try await inner.query("INSERT INTO t VALUES (2, 'discarded')")
                    throw Boom()
                }
            }

            _ = try await db.query("INSERT INTO t VALUES (3, 'also kept')")
        }

        let rows = try await connection.query("SELECT id FROM t ORDER BY id")
        #expect(rows.map { $0.values[0] } == [.int(1), .int(3)])
    }

    /// Savepoints nest, which is the whole reason they exist alongside
    /// transactions.
    @Test("savepoints nest")
    func savepointsNest() async throws {
        let connection = try await Self.seeded()
        defer { connection.close() }

        struct Boom: Error {}
        try await connection.withTransaction { db in
            try await db.withSavepoint { outer in
                _ = try await outer.query("INSERT INTO t VALUES (1, 'outer')")
                await #expect(throws: Boom.self) {
                    try await outer.withSavepoint { inner in
                        _ = try await inner.query("INSERT INTO t VALUES (2, 'inner')")
                        throw Boom()
                    }
                }
            }
        }

        let rows = try await connection.query("SELECT id FROM t ORDER BY id")
        #expect(rows.map { $0.values[0] } == [.int(1)])
    }

    /// A savepoint outside any transaction starts one — SQLite's own behaviour,
    /// kept rather than second-guessed.
    @Test("a savepoint outside a transaction works on its own")
    func savepointOutsideTransaction() async throws {
        let connection = try await Self.seeded()
        defer { connection.close() }

        try await connection.withSavepoint { db in
            _ = try await db.query("INSERT INTO t VALUES (1, 'a')")
        }
        #expect(await connection.isInTransaction == false)

        let rows = try await connection.query("SELECT count(*) FROM t")
        #expect(rows[0].values[0] == .int(1))
    }

    /// The name is spliced into SQL — SQLite takes no placeholder there — so it
    /// has to be quoted, and the quoting has to survive a quote.
    @Test("an awkward savepoint name survives")
    func awkwardSavepointName() async throws {
        let connection = try await Self.seeded()
        defer { connection.close() }

        try await connection.withSavepoint(#"we"ird name"#) { db in
            _ = try await db.query("INSERT INTO t VALUES (1, 'a')")
        }
        let rows = try await connection.query("SELECT count(*) FROM t")
        #expect(rows[0].values[0] == .int(1))
    }

    // MARK: - Behaviours

    /// `IMMEDIATE` takes the write lock at `BEGIN`, which is the fix for a
    /// read-then-write transaction that would otherwise discover contention
    /// partway through and be unable to retry cleanly.
    @Test("every begin behaviour is accepted", arguments: SQLiteTransactionOptions.Behavior.allCases)
    func behaviors(behavior: SQLiteTransactionOptions.Behavior) async throws {
        let connection = try await Self.seeded()
        defer { connection.close() }

        try await connection.withTransaction(.init(behavior: behavior)) { db in
            _ = try await db.query("INSERT INTO t VALUES (1, 'a')")
        }
        let rows = try await connection.query("SELECT count(*) FROM t")
        #expect(rows[0].values[0] == .int(1))
    }

    /// And the behaviour reaches SQLite rather than being decoration: an
    /// `IMMEDIATE` transaction holds the write lock from the start, so a second
    /// connection's `IMMEDIATE` cannot begin at the same time.
    @Test("immediate really does take the write lock at BEGIN")
    func immediateTakesTheLockEarly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swizzle-tx-\(UInt32.random(in: 0..<UInt32.max))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("tx.db").path

        let writer = try SQLiteConnection(path: path, busyTimeout: 0.1)
        defer { writer.close() }
        _ = try await writer.query("CREATE TABLE t (id INTEGER PRIMARY KEY)")

        let other = try SQLiteConnection(path: path, busyTimeout: 0.1)
        defer { other.close() }

        try await writer.withTransaction(.immediate) { _ in
            // The lock is already held, so this must not be able to take it.
            await #expect(throws: SQLiteError.self) {
                try await other.withTransaction(.immediate) { db in
                    _ = try await db.query("INSERT INTO t VALUES (1)")
                }
            }
        }

        // A deferred transaction, by contrast, begins happily — it takes no lock
        // until it touches something. That contrast is what proves the behaviour
        // is being passed through rather than ignored.
        try await writer.withTransaction(.immediate) { _ in
            try await other.withTransaction(.deferred) { _ in }
        }
    }
}

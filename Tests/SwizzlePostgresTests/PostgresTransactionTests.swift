import NIOCore
import NIOPosix
import SwizzleCore
import SwizzlePostgresDriver
import Testing

/// Transactions, against a real server.
///
/// The last place the two engines this project ships were not at parity:
/// `MySQLTransaction` had isolation levels, savepoints and scoped rollback, and
/// Postgres callers hand-wrote `BEGIN`/`COMMIT` and owned rollback-on-error.
@Suite(
    "Postgres transactions", .serialized,
    .enabled(if: PostgresTestServer.isAvailable, PostgresTestServer.skipReason)
)
struct PostgresTransactionTests {

    static let url = "postgres://swizzle:swizzlepass@127.0.0.1:5432/swizzle_test?sslmode=require"

    static func open() async throws -> PostgresConnection {
        try await PostgresConnection.connect(
            configuration: PostgresConnectionConfiguration(swizzleURL: url),
            on: MultiThreadedEventLoopGroup.singleton.next()
        )
    }

    func withTable(
        _ body: (PostgresConnection, String) async throws -> Void
    ) async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }
        let table = "tx_probe_\(UInt32.random(in: 0..<UInt32.max))"
        _ = try await connection.query("CREATE TEMP TABLE \(table) (id int)")
        try await body(connection, table)
    }

    func count(_ connection: PostgresConnection, _ table: String) async throws -> Int64 {
        let rows = try await connection.query("SELECT count(*) FROM \(table)").rows
        guard case .int(let value) = rows[0][0] else { return -1 }
        return value
    }

    // MARK: - The BEGIN statement

    /// Everything goes on the `BEGIN` itself. MySQL needs a preceding
    /// `SET TRANSACTION` because `START TRANSACTION` takes no isolation level;
    /// Postgres accepts the lot in one statement, so there is no window where a
    /// second connection could observe a half-configured session.
    @Test("options render onto a single BEGIN")
    func beginStatement() {
        #expect(PostgresTransactionOptions().beginStatement == "BEGIN")
        #expect(
            PostgresTransactionOptions(isolationLevel: .serializable).beginStatement
                == "BEGIN ISOLATION LEVEL SERIALIZABLE"
        )
        #expect(
            PostgresTransactionOptions(accessMode: .readOnly).beginStatement
                == "BEGIN READ ONLY"
        )
        #expect(
            PostgresTransactionOptions(
                isolationLevel: .serializable, accessMode: .readOnly, deferrable: true
            ).beginStatement == "BEGIN ISOLATION LEVEL SERIALIZABLE READ ONLY DEFERRABLE"
        )
    }

    @Test("every isolation level is accepted by the server")
    func isolationLevels() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        for level in PostgresTransactionOptions.IsolationLevel.allCases {
            try await connection.withTransaction(.init(isolationLevel: level)) { _ in }
        }

        // `DEFERRABLE` has no MySQL equivalent and is only meaningful alongside
        // SERIALIZABLE READ ONLY, which is the combination worth proving.
        try await connection.withTransaction(
            .init(isolationLevel: .serializable, accessMode: .readOnly, deferrable: true)
        ) { _ in }
    }

    /// `READ ONLY` rejects writes outright, which is what makes it a guard rather
    /// than a hint.
    ///
    /// **Not a temp table.** `READ ONLY` explicitly permits writes to temporary
    /// tables — they are session-local and cannot affect anyone else — so the
    /// first version of this test inserted happily and proved nothing. The
    /// exception is documented, and it is the kind a fixture hides.
    @Test("a read-only transaction refuses to write")
    func readOnlyRefusesWrites() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }
        let table = "tx_readonly_\(UInt32.random(in: 0..<UInt32.max))"
        _ = try await connection.query("CREATE TABLE \(table) (id int)")
        defer { Task { _ = try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        await #expect(throws: (any Error).self) {
            try await connection.withTransaction(.init(accessMode: .readOnly)) { db in
                _ = try await db.query("INSERT INTO \(table) VALUES (1)")
            }
        }
        let rowCount = try await count(connection, table)
        #expect(rowCount == 0)

        // And a read in the same mode is fine, so the guard is not just refusing
        // everything.
        try await connection.withTransaction(.init(accessMode: .readOnly)) { db in
            _ = try await db.query("SELECT count(*) FROM \(table)")
        }
    }

    // MARK: - Commit and rollback

    @Test("work commits when the block returns")
    func commits() async throws {
        try await withTable { connection, table in
            try await connection.withTransaction { db in
                _ = try await db.query("INSERT INTO \(table) VALUES (1), (2)")
            }
            let rowCount = try await count(connection, table)
            #expect(rowCount == 2)
        }
    }

    @Test("work rolls back when the block throws")
    func rollsBack() async throws {
        struct Boom: Error {}
        try await withTable { connection, table in
            await #expect(throws: Boom.self) {
                try await connection.withTransaction { db in
                    _ = try await db.query("INSERT INTO \(table) VALUES (1)")
                    throw Boom()
                }
            }
            let rowCount = try await count(connection, table)
            #expect(rowCount == 0)
            // And the session is usable again rather than stuck aborted.
            let txStatus = try await connection.transactionStatus
            #expect(txStatus == .idle)
        }
    }

    /// **Transactional DDL, which MySQL does not have.** Its version has to
    /// detect a transaction that ended underneath the block, because `CREATE
    /// TABLE` commits implicitly there. Here it simply rolls back.
    @Test("DDL rolls back too")
    func ddlRollsBack() async throws {
        struct Boom: Error {}
        let connection = try await Self.open()
        defer { connection.closeImmediately() }
        let table = "tx_ddl_\(UInt32.random(in: 0..<UInt32.max))"

        await #expect(throws: Boom.self) {
            try await connection.withTransaction { db in
                _ = try await db.query("CREATE TABLE \(table) (id int)")
                throw Boom()
            }
        }

        let exists = try await connection.query(
            "SELECT to_regclass($1) IS NOT NULL", [.text(table)]
        ).rows
        #expect(exists[0][0] == .bool(false))
    }

    // MARK: - The aborted state

    /// **`COMMIT` on an aborted transaction performs a rollback and reports
    /// success.** A caller that swallowed an error inside the block would be told
    /// its work was committed when it was discarded — so the commit is refused
    /// rather than sent.
    @Test("a swallowed error does not commit silently")
    func abortedTransactionIsNotReportedAsCommitted() async throws {
        try await withTable { connection, table in
            await #expect(throws: PostgresTransactionError.transactionAborted) {
                try await connection.withTransaction { db in
                    _ = try await db.query("INSERT INTO \(table) VALUES (1)")
                    // Swallowed on purpose — this is the mistake being guarded.
                    _ = try? await db.query("SELECT nonexistent_column")
                }
            }
            let rowCount = try await count(connection, table)
            #expect(rowCount == 0)
            let txStatus = try await connection.transactionStatus
            #expect(txStatus == .idle)
        }
    }

    /// The status comes from the server on every `ReadyForQuery`, so it cannot
    /// drift the way a client-side flag would — and the aborted state is only
    /// visible because of that.
    @Test("the server's transaction status is reported, not inferred")
    func statusTracksTheServer() async throws {
        try await withTable { connection, table in
            var status = try await connection.transactionStatus
            #expect(status == .idle)

            try await connection.beginTransaction()
            status = try await connection.transactionStatus
            #expect(status == .inTransaction)

            _ = try? await connection.query("SELECT nonexistent_column")
            // Nobody issued anything to cause this; the failed statement did.
            status = try await connection.transactionStatus
            #expect(status == .failed)

            try await connection.rollbackTransaction()
            status = try await connection.transactionStatus
            #expect(status == .idle)
        }
    }

    // MARK: - Nesting

    /// Postgres warns `there is already a transaction in progress` and carries
    /// on, so a nested `BEGIN` is a no-op whose `COMMIT` would end the *outer*
    /// transaction. Refused rather than flattened.
    @Test("nesting is refused rather than silently flattened")
    func nestingRefused() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        try await connection.beginTransaction()
        await #expect(throws: PostgresTransactionError.alreadyInTransaction) {
            try await connection.beginTransaction()
        }
        try await connection.rollbackTransaction()
    }

    @Test("commit and rollback outside a transaction are refused")
    func noTransaction() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        await #expect(throws: PostgresTransactionError.notInTransaction) {
            try await connection.commitTransaction()
        }
        await #expect(throws: PostgresTransactionError.notInTransaction) {
            try await connection.rollbackTransaction()
        }
    }

    // MARK: - Savepoints

    @Test("a savepoint rolls back only its own work")
    func savepointPartialRollback() async throws {
        struct Boom: Error {}
        try await withTable { connection, table in
            try await connection.withTransaction { db in
                _ = try await db.query("INSERT INTO \(table) VALUES (1)")

                await #expect(throws: Boom.self) {
                    try await db.withSavepoint { inner in
                        _ = try await inner.query("INSERT INTO \(table) VALUES (2)")
                        throw Boom()
                    }
                }

                _ = try await db.query("INSERT INTO \(table) VALUES (3)")
            }
            // 1 and 3 survive; 2 does not.
            let rows = try await connection.query(
                "SELECT id FROM \(table) ORDER BY id"
            ).rows
            #expect(rows.map { $0[0] } == [.int(1), .int(3)])
        }
    }

    /// Rolling back to a savepoint is the **only** way to recover from a failed
    /// statement without discarding the whole transaction — it clears `25P02`.
    @Test("a savepoint clears the aborted state")
    func savepointClearsAbortedState() async throws {
        try await withTable { connection, table in
            try await connection.withTransaction { db in
                _ = try await db.query("INSERT INTO \(table) VALUES (1)")

                // A failed statement inside a savepoint, recovered from.
                try? await db.withSavepoint { inner in
                    _ = try await inner.query("SELECT nonexistent_column")
                }

                // Without the savepoint this would fail with 25P02.
                let status = try await db.transactionStatus
                #expect(status == .inTransaction)
                _ = try await db.query("INSERT INTO \(table) VALUES (2)")
            }
            let rowCount = try await count(connection, table)
            #expect(rowCount == 2)
        }
    }

    @Test("a savepoint outside a transaction is refused")
    func savepointNeedsATransaction() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        await #expect(throws: PostgresTransactionError.notInTransaction) {
            try await connection.withSavepoint { _ in }
        }
    }

    /// A savepoint name is an identifier spliced into SQL — Postgres accepts no
    /// placeholder here — so it is the one place a caller-supplied string could
    /// inject.
    @Test("a savepoint name with a quote in it is escaped")
    func savepointQuoting() {
        #expect(PostgresConnection.savepointIdentifier("outer") == "\"outer\"")
        #expect(
            PostgresConnection.savepointIdentifier(#"a"; DROP TABLE users; --"#)
                == #""a""; DROP TABLE users; --""#
        )
        // A generated name is used when none is given, so two anonymous
        // savepoints in one transaction cannot collide.
        #expect(PostgresConnection.savepointIdentifier(nil).hasPrefix("\"swizzle_sp_"))
    }

    // MARK: - Through the pool

    /// A transaction is session state and cannot span connections, so the pool
    /// API has to pin one for the whole block. `withConnection` alone leaves the
    /// caller to remember.
    @Test("the client pins one connection for the transaction")
    func clientTransaction() async throws {
        let configuration = PostgresClient.Configuration(
            connection: try PostgresConnectionConfiguration(swizzleURL: Self.url),
            maximumConnections: 4
        )
        let client = PostgresClient(configuration: configuration)
        let running = Task { await client.run() }
        defer { running.cancel() }

        let table = "tx_pool_\(UInt32.random(in: 0..<UInt32.max))"
        _ = try await client.query("CREATE TABLE \(table) (id int)")
        defer { Task { _ = try? await client.query("DROP TABLE IF EXISTS \(table)") } }

        try await client.withTransaction { db in
            // Both statements must land on the same session or the second would
            // not see the first's uncommitted row.
            _ = try await db.query("INSERT INTO \(table) VALUES (1)")
            let seen = try await db.query("SELECT count(*) FROM \(table)").rows
            #expect(seen[0][0] == .int(1))
        }

        let rows = try await client.query("SELECT count(*) FROM \(table)").rows
        #expect(rows[0][0] == .int(1))
    }
}

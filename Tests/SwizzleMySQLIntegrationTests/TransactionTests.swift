import NIOCore
import Testing
@testable import SwizzleMySQL

@Suite(
    "Transactions",
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct TransactionTests {

    static func connect(_ server: MySQLTestServer) async throws -> MySQLConnection {
        try await TestServers.connect(server)
    }

    /// InnoDB explicitly — MyISAM silently ignores transactions entirely, which
    /// would make every test here pass for the wrong reason.
    static func makeTable(_ connection: MySQLConnection, _ table: String) async throws {
        try await connection.query("DROP TABLE IF EXISTS \(table)")
        try await connection.query(
            "CREATE TABLE \(table) (id INT PRIMARY KEY, note VARCHAR(32)) ENGINE=InnoDB"
        )
    }

    static func rowCount(_ connection: MySQLConnection, _ table: String) async throws -> Int64 {
        let result = try await connection.query("SELECT COUNT(*) AS c FROM \(table)")
        return result.rows[0][0].int ?? -1
    }

    // MARK: - Commit and rollback

    @Test("commit persists work", arguments: TestServers.all)
    func commitPersists(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "tx_commit_\(server.name)"
        try await Self.makeTable(connection, table)

        try await connection.withTransaction { tx in
            try await tx.query("INSERT INTO \(table) VALUES (1, 'a')")
            try await tx.query("INSERT INTO \(table) VALUES (2, 'b')")
        }

        #expect(try await Self.rowCount(connection, table) == 2)
        try await connection.query("DROP TABLE \(table)")
    }

    @Test("a thrown error rolls back", arguments: TestServers.all)
    func throwRollsBack(server: MySQLTestServer) async throws {
        struct Marker: Error {}

        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "tx_rollback_\(server.name)"
        try await Self.makeTable(connection, table)

        do {
            try await connection.withTransaction { tx in
                try await tx.query("INSERT INTO \(table) VALUES (1, 'a')")
                throw Marker()
            }
            Issue.record("expected the error to propagate")
        } catch is Marker {
            // expected
        }

        #expect(try await Self.rowCount(connection, table) == 0)
        #expect(connection.isInTransaction == false)

        try await connection.query("DROP TABLE \(table)")
    }

    /// A SQL error inside the block must roll back too, and leave the connection
    /// usable afterwards.
    @Test("a SQL error rolls back and leaves the connection usable", arguments: TestServers.all)
    func sqlErrorRollsBack(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "tx_sqlerr_\(server.name)"
        try await Self.makeTable(connection, table)

        _ = try? await connection.withTransaction { tx in
            try await tx.query("INSERT INTO \(table) VALUES (1, 'a')")
            // Duplicate primary key.
            try await tx.query("INSERT INTO \(table) VALUES (1, 'dup')")
        }

        #expect(try await Self.rowCount(connection, table) == 0)
        let after = try await connection.query("SELECT 5 AS five")
        #expect(after.rows[0][0].int == 5)

        try await connection.query("DROP TABLE \(table)")
    }

    @Test("explicit begin/commit works", arguments: TestServers.all)
    func explicitControl(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "tx_explicit_\(server.name)"
        try await Self.makeTable(connection, table)

        try await connection.beginTransaction()
        #expect(connection.isInTransaction)
        try await connection.query("INSERT INTO \(table) VALUES (1, 'a')")
        try await connection.rollback()
        #expect(connection.isInTransaction == false)
        #expect(try await Self.rowCount(connection, table) == 0)

        try await connection.beginTransaction()
        try await connection.query("INSERT INTO \(table) VALUES (2, 'b')")
        try await connection.commit()
        #expect(try await Self.rowCount(connection, table) == 1)

        try await connection.query("DROP TABLE \(table)")
    }

    // MARK: - Isolation and access mode

    /// Verified **behaviourally**, by whether a dirty read is possible.
    ///
    /// Reading `@@SESSION.transaction_isolation` does not work here and is a
    /// trap: `SET TRANSACTION ISOLATION LEVEL` without a scope keyword applies
    /// to the *next transaction only* and deliberately leaves the session
    /// variable alone, so that check reports the session default for every level
    /// and "proves" the setting never applied.
    @Test("isolation level changes visibility of uncommitted rows", arguments: TestServers.all)
    func isolationLevelIsApplied(server: MySQLTestServer) async throws {
        let writer = try await Self.connect(server)
        let reader = try await Self.connect(server)
        defer {
            writer.closeImmediately()
            reader.closeImmediately()
        }

        let table = "tx_iso_\(server.name)"
        try await Self.makeTable(writer, table)

        try await writer.beginTransaction()
        try await writer.query("INSERT INTO \(table) VALUES (1, 'uncommitted')")

        // READ UNCOMMITTED permits a dirty read — the row is visible despite
        // never having been committed.
        try await reader.withTransaction(.init(isolationLevel: .readUncommitted)) { tx in
            let dirty = try await Self.rowCount(tx, table)
            #expect(dirty == 1, "expected a dirty read")
        }

        // REPEATABLE READ must not see it.
        try await reader.withTransaction(.init(isolationLevel: .repeatableRead)) { tx in
            let isolated = try await Self.rowCount(tx, table)
            #expect(isolated == 0, "unexpected dirty read")
        }

        try await writer.rollback()
        #expect(try await Self.rowCount(reader, table) == 0)

        try await writer.query("DROP TABLE \(table)")
    }

    /// Every level is at least accepted by the server; the semantic check above
    /// covers that the setting genuinely takes effect.
    @Test("every isolation level is accepted", arguments: TestServers.all)
    func allIsolationLevelsAccepted(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        for level in MySQLTransactionOptions.IsolationLevel.allCases {
            try await connection.withTransaction(.init(isolationLevel: level)) { tx in
                let result = try await tx.query("SELECT 1 AS ok")
                #expect(result.rows[0][0].int == 1)
            }
            #expect(connection.isInTransaction == false)
        }
    }

    /// `READ ONLY` must actually reject writes, or the guard is decorative.
    @Test("a read-only transaction rejects writes", arguments: TestServers.all)
    func readOnlyRejectsWrites(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "tx_readonly_\(server.name)"
        try await Self.makeTable(connection, table)

        await #expect(throws: (any Error).self) {
            try await connection.withTransaction(.init(accessMode: .readOnly)) { tx in
                try await tx.query("INSERT INTO \(table) VALUES (1, 'nope')")
            }
        }

        #expect(try await Self.rowCount(connection, table) == 0)
        try await connection.query("DROP TABLE \(table)")
    }

    @Test("a read-write transaction permits writes", arguments: TestServers.all)
    func readWriteAllowsWrites(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "tx_readwrite_\(server.name)"
        try await Self.makeTable(connection, table)

        try await connection.withTransaction(.init(accessMode: .readWrite)) { tx in
            try await tx.query("INSERT INTO \(table) VALUES (1, 'yes')")
        }
        #expect(try await Self.rowCount(connection, table) == 1)

        try await connection.query("DROP TABLE \(table)")
    }

    @Test("consistent snapshot starts a transaction", arguments: TestServers.all)
    func consistentSnapshot(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        try await connection.withTransaction(
            .init(isolationLevel: .repeatableRead, consistentSnapshot: true)
        ) { tx in
            #expect(tx.isInTransaction)
            _ = try await tx.query("SELECT 1")
        }
    }

    // MARK: - Isolation actually isolates

    /// Two connections, one uncommitted write: the second must not see it.
    /// Without this, "commit persists" alone would pass even if the driver never
    /// opened a transaction at all.
    @Test("uncommitted work is invisible to another connection", arguments: TestServers.all)
    func uncommittedWorkIsInvisible(server: MySQLTestServer) async throws {
        let writer = try await Self.connect(server)
        let reader = try await Self.connect(server)
        defer {
            writer.closeImmediately()
            reader.closeImmediately()
        }

        let table = "tx_isolation_\(server.name)"
        try await Self.makeTable(writer, table)

        try await writer.beginTransaction()
        try await writer.query("INSERT INTO \(table) VALUES (1, 'pending')")

        // Visible on the writer's own session…
        #expect(try await Self.rowCount(writer, table) == 1)
        // …but not to anyone else until it commits.
        #expect(try await Self.rowCount(reader, table) == 0)

        try await writer.commit()
        #expect(try await Self.rowCount(reader, table) == 1)

        try await writer.query("DROP TABLE \(table)")
    }

    // MARK: - Nesting

    /// MySQL has no nested transactions — a second `START TRANSACTION` commits
    /// the outer one. Rejecting is safer than silently committing work the
    /// caller believed was provisional.
    @Test("nested transactions are rejected", arguments: TestServers.all)
    func nestedTransactionRejected(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        await #expect(throws: MySQLTransactionError.alreadyInTransaction) {
            try await connection.withTransaction { tx in
                try await tx.withTransaction { _ in }
            }
        }
        #expect(connection.isInTransaction == false)
    }

    @Test("commit outside a transaction is rejected", arguments: TestServers.all)
    func commitOutsideTransaction(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        await #expect(throws: MySQLTransactionError.notInTransaction) {
            try await connection.commit()
        }
    }

    // MARK: - Savepoints

    @Test("a savepoint rolls back only its own work", arguments: TestServers.all)
    func savepointPartialRollback(server: MySQLTestServer) async throws {
        struct Marker: Error {}

        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "tx_savepoint_\(server.name)"
        try await Self.makeTable(connection, table)

        try await connection.withTransaction { tx in
            try await tx.query("INSERT INTO \(table) VALUES (1, 'keep')")

            do {
                try await tx.withSavepoint { inner in
                    try await inner.query("INSERT INTO \(table) VALUES (2, 'discard')")
                    throw Marker()
                }
            } catch is Marker {
                // The savepoint rolled back; the enclosing transaction lives on.
            }

            try await tx.query("INSERT INTO \(table) VALUES (3, 'keep')")
        }

        let result = try await connection.query("SELECT id FROM \(table) ORDER BY id")
        #expect(result.rows.map { $0[0].int } == [1, 3])

        try await connection.query("DROP TABLE \(table)")
    }

    @Test("savepoints nest", arguments: TestServers.all)
    func savepointsNest(server: MySQLTestServer) async throws {
        struct Marker: Error {}

        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "tx_savepoint_nest_\(server.name)"
        try await Self.makeTable(connection, table)

        try await connection.withTransaction { tx in
            try await tx.query("INSERT INTO \(table) VALUES (1, 'outer')")
            try await tx.withSavepoint { level1 in
                try await level1.query("INSERT INTO \(table) VALUES (2, 'level1')")
                do {
                    try await level1.withSavepoint { level2 in
                        try await level2.query("INSERT INTO \(table) VALUES (3, 'level2')")
                        throw Marker()
                    }
                } catch is Marker {}
            }
        }

        let result = try await connection.query("SELECT id FROM \(table) ORDER BY id")
        #expect(result.rows.map { $0[0].int } == [1, 2])

        try await connection.query("DROP TABLE \(table)")
    }

    /// Savepoint names are identifiers spliced into SQL — a placeholder is not
    /// accepted there — so they must be quoted and escaped.
    @Test("savepoint names are escaped")
    func savepointNamesAreEscaped() {
        #expect(MySQLConnection.savepointIdentifier("plain") == "`plain`")
        #expect(MySQLConnection.savepointIdentifier("we`ird") == "`we``ird`")
        // A generated name is still quoted.
        #expect(MySQLConnection.savepointIdentifier(nil).hasPrefix("`swizzle_sp_"))
    }

    @Test("a savepoint outside a transaction is rejected", arguments: TestServers.all)
    func savepointRequiresTransaction(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        await #expect(throws: MySQLTransactionError.notInTransaction) {
            try await connection.withSavepoint { _ in }
        }
    }

    // MARK: - Implicit commit

    /// MySQL has no transactional DDL: `CREATE TABLE` inside a transaction
    /// commits it where it stands. Detected and surfaced rather than leaving the
    /// caller believing their earlier work is still provisional.
    @Test("DDL inside a transaction is reported as an implicit commit", arguments: TestServers.all)
    func ddlImplicitlyCommits(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "tx_ddl_\(server.name)"
        let victim = "tx_ddl_victim_\(server.name)"
        try await Self.makeTable(connection, table)
        try await connection.query("DROP TABLE IF EXISTS \(victim)")

        do {
            try await connection.withTransaction { tx in
                try await tx.query("INSERT INTO \(table) VALUES (1, 'a')")
                // Ends the transaction, silently, as far as MySQL is concerned.
                try await tx.query("CREATE TABLE \(victim) (n INT) ENGINE=InnoDB")
            }
            Issue.record("expected the implicit commit to be reported")
        } catch let error as MySQLTransactionError {
            guard case .transactionEndedUnexpectedly(let message) = error else {
                Issue.record("expected transactionEndedUnexpectedly, got \(error)")
                return
            }
            #expect(message.contains("DDL"))
        }

        // The row before the DDL was committed by it — that is MySQL's
        // behaviour, and the point of surfacing it.
        #expect(try await Self.rowCount(connection, table) == 1)

        try await connection.query("DROP TABLE IF EXISTS \(victim)")
        try await connection.query("DROP TABLE \(table)")
    }

    // MARK: - Streaming inside a transaction

    /// A stream holds the connection, and a transaction is session state on that
    /// same connection — so the two compose, and the rows must reflect the
    /// transaction's own uncommitted writes.
    @Test("streaming inside a transaction sees uncommitted rows", arguments: TestServers.all)
    func streamingInsideTransaction(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "tx_stream_\(server.name)"
        try await Self.makeTable(connection, table)

        try await connection.withTransaction { tx in
            for index in 1...50 {
                try await tx.query("INSERT INTO \(table) VALUES (\(index), 'row')")
            }

            let rows = try await tx.stream("SELECT id FROM \(table) ORDER BY id")
            var seen: [Int64] = []
            for try await row in rows { seen.append(row[0].int ?? -1) }
            #expect(seen.count == 50)
            #expect(tx.isInTransaction, "the stream must not have ended the transaction")
        }

        #expect(try await Self.rowCount(connection, table) == 50)
        try await connection.query("DROP TABLE \(table)")
    }

    // MARK: - Through the pool

    @Test("pooled transactions commit and roll back", arguments: TestServers.all)
    func pooledTransactions(server: MySQLTestServer) async throws {
        struct Marker: Error {}

        let user = server.primaryUser
        let client = MySQLClient(
            configuration: MySQLClient.Configuration(
                connection: MySQLConnectionConfiguration(
                    address: .hostname(TestServers.host, port: server.port),
                    username: user.name,
                    password: user.password,
                    database: TestServers.database,
                    tls: .disable,
                    serverPublicKey: .requestFromServer
                ),
                maximumConnections: 2
            )
        )

        let table = "tx_pool_\(server.name)"
        try await withThrowingTaskGroup(of: Bool?.self) { group in
            group.addTask {
                await client.run()
                return nil
            }
            group.addTask {
                try await client.query("DROP TABLE IF EXISTS \(table)")
                try await client.query(
                    "CREATE TABLE \(table) (id INT PRIMARY KEY) ENGINE=InnoDB"
                )

                try await client.withTransaction { tx in
                    try await tx.query("INSERT INTO \(table) VALUES (1)")
                }

                do {
                    try await client.withTransaction { tx in
                        try await tx.query("INSERT INTO \(table) VALUES (2)")
                        throw Marker()
                    }
                } catch is Marker {}

                let result = try await client.query("SELECT id FROM \(table) ORDER BY id")
                #expect(result.rows.map { $0[0].int } == [1])

                try await client.query("DROP TABLE \(table)")
                return true
            }
            while let next = try await group.next() {
                if next != nil { break }
            }
            group.cancelAll()
        }
    }
}

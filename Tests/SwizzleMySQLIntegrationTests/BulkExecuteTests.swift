import NIOCore
import NIOPosix
import Testing
@testable import SwizzleMySQL

/// `COM_STMT_BULK_EXECUTE` against real MariaDB.
///
/// Scoped to `TestServers.mariaDB` because MySQL has no equivalent command at
/// all — running these against a MySQL fixture asserts nothing except that we
/// correctly refuse.
@Suite(
    "Bulk execute",
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct BulkExecuteTests {

    static func connect(_ server: MySQLTestServer) async throws -> MySQLConnection {
        let user = server.primaryUser
        return try await MySQLConnection.connect(
            configuration: MySQLConnectionConfiguration(
                address: .hostname(TestServers.host, port: server.port),
                username: user.name,
                password: user.password,
                database: TestServers.database,
                tls: .disable,
                serverPublicKey: .requestFromServer
            ),
            on: TestServers.group.next()
        )
    }

    static func makeTable(_ connection: MySQLConnection) async throws -> String {
        let name = "bulk_\(UInt32.random(in: 0..<UInt32.max))"
        _ = try await connection.query(
            "CREATE TEMPORARY TABLE \(name) (id INT, label VARCHAR(64), score BIGINT)"
        )
        return name
    }

    @Test("negotiates the bulk capability", arguments: TestServers.mariaDB)
    func negotiatesCapability(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        #expect(connection.supportsBulkExecute)
    }

    /// Proof that the rows really went in one command rather than a loop.
    ///
    /// Everything else in this suite would also pass if `executeBulk` quietly
    /// fell back to running `COM_STMT_EXECUTE` per row — the data would land
    /// either way. The server's own `Com_stmt_execute` counter is what tells
    /// the two apart.
    @Test("the server counts one execute, not one per row", arguments: TestServers.mariaDB)
    func serverConfirmsASingleExecute(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)

        func executeCount() async throws -> Int64 {
            let status = try await connection.query(
                "SHOW SESSION STATUS LIKE 'Com_stmt_execute'"
            )
            return status.rows[0][1].int ?? -1
        }

        let before = try await executeCount()
        let rows: [[MySQLValue]] = (1...500).map {
            [.int(Int64($0)), .bytes(Array("r\($0)".utf8)), .int(Int64($0))]
        }
        _ = try await connection.queryBulk(
            "INSERT INTO \(table) (id, label, score) VALUES (?, ?, ?)", rows: rows
        )
        let after = try await executeCount()

        let inserted = try await connection.query("SELECT COUNT(*) FROM \(table)")
        #expect(inserted.rows[0][0].int == 500)

        // A per-row fallback would add ~500 here.
        #expect(
            after - before < 10,
            "Com_stmt_execute rose by \(after - before) for 500 rows — that is a per-row fallback"
        )
    }

    @Test("inserts many rows in one round trip", arguments: TestServers.mariaDB)
    func insertsManyRows(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)

        let rows: [[MySQLValue]] = (1...1000).map {
            [.int(Int64($0)), .bytes(Array("label-\($0)".utf8)), .int(Int64($0 * 10))]
        }
        let results = try await connection.queryBulk(
            "INSERT INTO \(table) (id, label, score) VALUES (?, ?, ?)", rows: rows
        )
        #expect(results.count == 1, "1000 small rows should fit in a single request")

        let count = try await connection.query("SELECT COUNT(*) FROM \(table)")
        #expect(count.rows[0][0].int == 1000)

        let sample = try await connection.query("SELECT label, score FROM \(table) WHERE id = 777")
        #expect(sample.rows[0][0].string == "label-777")
        #expect(sample.rows[0][1].int == 7770)
    }

    /// The case the per-parameter type computation exists for: a column that is
    /// NULL in the first row and an integer later. Taking types from row one
    /// alone sends `MYSQL_TYPE_NULL` and MariaDB rejects the batch with
    /// "Incorrect arguments to mysqld_stmt_bulk_execute".
    @Test("handles a parameter that is NULL in the first row", arguments: TestServers.mariaDB)
    func nullInFirstRow(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)

        let rows: [[MySQLValue]] = [
            [.int(1), .null, .null],
            [.int(2), .bytes(Array("two".utf8)), .int(20)],
            [.int(3), .null, .int(30)],
        ]
        _ = try await connection.queryBulk(
            "INSERT INTO \(table) (id, label, score) VALUES (?, ?, ?)", rows: rows
        )

        let nulls = try await connection.query(
            "SELECT COUNT(*) FROM \(table) WHERE label IS NULL"
        )
        #expect(nulls.rows[0][0].int == 2)

        let second = try await connection.query("SELECT label, score FROM \(table) WHERE id = 2")
        #expect(second.rows[0][0].string == "two")
        #expect(second.rows[0][1].int == 20)

        let third = try await connection.query("SELECT score FROM \(table) WHERE id = 3")
        #expect(third.rows[0][0].int == 30)
    }

    /// Rows large enough that the batch must be split. The caller passes one
    /// array and should not have to think about `max_allowed_packet`.
    @Test("splits a batch that exceeds max_allowed_packet", arguments: [TestServers.latest])
    func splitsLargeBatch(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "bulk_big_\(UInt32.random(in: 0..<UInt32.max))"
        _ = try await connection.query(
            "CREATE TEMPORARY TABLE \(table) (id INT, blob_col LONGTEXT)"
        )

        // ~8 KB each × 2000 rows ≈ 16 MB, well past the 4 MiB default.
        let padding = Array(String(repeating: "x", count: 8192).utf8)
        let rows: [[MySQLValue]] = (1...2000).map { [.int(Int64($0)), .bytes(padding)] }

        let results = try await connection.queryBulk(
            "INSERT INTO \(table) (id, blob_col) VALUES (?, ?)", rows: rows
        )
        #expect(results.count > 1, "batch should have been split into several requests")

        let count = try await connection.query("SELECT COUNT(*) FROM \(table)")
        #expect(count.rows[0][0].int == 2000)

        let length = try await connection.query(
            "SELECT LENGTH(blob_col) FROM \(table) WHERE id = 1500"
        )
        #expect(length.rows[0][0].int == 8192)
    }

    @Test("updates many rows", arguments: [TestServers.latest])
    func updatesManyRows(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)

        let inserts: [[MySQLValue]] = (1...100).map {
            [.int(Int64($0)), .bytes(Array("before".utf8)), .int(0)]
        }
        _ = try await connection.queryBulk(
            "INSERT INTO \(table) (id, label, score) VALUES (?, ?, ?)", rows: inserts
        )

        let updates: [[MySQLValue]] = (1...100).map {
            [.bytes(Array("after-\($0)".utf8)), .int(Int64($0))]
        }
        _ = try await connection.queryBulk(
            "UPDATE \(table) SET label = ? WHERE id = ?", rows: updates
        )

        let changed = try await connection.query(
            "SELECT COUNT(*) FROM \(table) WHERE label LIKE 'after-%'"
        )
        #expect(changed.rows[0][0].int == 100)
    }

    @Test("rejects rows of differing arity", arguments: [TestServers.latest])
    func rejectsMixedArity(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)

        await #expect(throws: (any Error).self) {
            _ = try await connection.queryBulk(
                "INSERT INTO \(table) (id, label, score) VALUES (?, ?, ?)",
                rows: [
                    [.int(1), .bytes(Array("a".utf8)), .int(1)],
                    [.int(2), .bytes(Array("b".utf8))],
                ]
            )
        }
    }

    @Test("an empty row set is a no-op", arguments: [TestServers.latest])
    func emptyRowsIsNoOp(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)

        let results = try await connection.queryBulk(
            "INSERT INTO \(table) (id, label, score) VALUES (?, ?, ?)", rows: []
        )
        #expect(results.isEmpty)

        let count = try await connection.query("SELECT COUNT(*) FROM \(table)")
        #expect(count.rows[0][0].int == 0)
    }

    /// The connection has to be clean afterwards — a bulk reply is a series of
    /// OKs, and mis-counting them would desync everything after.
    @Test("connection stays usable after a bulk execute", arguments: TestServers.mariaDB)
    func connectionStaysUsable(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)

        let rows: [[MySQLValue]] = (1...50).map {
            [.int(Int64($0)), .bytes(Array("x".utf8)), .int(Int64($0))]
        }
        _ = try await connection.queryBulk(
            "INSERT INTO \(table) (id, label, score) VALUES (?, ?, ?)", rows: rows
        )

        for i in 1...5 {
            let result = try await connection.query("SELECT \(i) AS n")
            #expect(result.rows[0][0].int == Int64(i))
        }
    }
}

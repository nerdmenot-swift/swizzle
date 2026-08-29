import NIOCore
import Testing
@testable import SwizzleMySQL

/// Text-protocol queries against all four real servers.
@Suite(
    "Queries",
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct QueryTests {

    /// Connects as a user that exists on every server.
    static func connect(_ server: MySQLTestServer) async throws -> MySQLConnection {
        try await TestServers.connect(server)
    }

    // MARK: - Basics

    @Test("SELECT of a literal round-trips", arguments: TestServers.all)
    func selectLiteral(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let result = try await connection.query("SELECT 1 AS one, 'hello' AS greeting")
        #expect(result.columns.count == 2)
        #expect(result.columns[0].name == "one")
        #expect(result.columns[1].name == "greeting")
        #expect(result.rows.count == 1)
        #expect(result.rows[0].string(at: 0) == "1")
        #expect(result.rows[0].string(at: 1) == "hello")
    }

    @Test("NULL is distinguished from empty string", arguments: TestServers.all)
    func nullHandling(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        // `empty` is a reserved word in MySQL, so the alias is quoted-free-safe.
        let result = try await connection.query("SELECT NULL AS n, '' AS blank")
        #expect(result.rows[0].values[0].isNull)
        #expect(!result.rows[0].values[1].isNull)
        #expect(result.rows[0].string(at: 1) == "")
    }

    @Test("multi-row results arrive in order", arguments: TestServers.all)
    func multipleRows(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let result = try await connection.query(
            "SELECT 1 AS n UNION ALL SELECT 2 UNION ALL SELECT 3"
        )
        #expect(result.rows.count == 3)
        #expect(result.rows.map { $0.string(at: 0) } == ["1", "2", "3"])
    }

    @Test("ping round-trips", arguments: TestServers.all)
    func ping(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        try await connection.ping()
        #expect(connection.isActive)
    }

    // MARK: - DDL and DML

    @Test("DDL, INSERT and SELECT against a real table", arguments: TestServers.all)
    func tableLifecycle(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "phase2_\(server.name)"
        try await connection.query("DROP TABLE IF EXISTS \(table)")
        try await connection.query(
            "CREATE TABLE \(table) (id INT PRIMARY KEY AUTO_INCREMENT, name VARCHAR(64), note TEXT NULL)"
        )

        let insert = try await connection.query(
            "INSERT INTO \(table) (name, note) VALUES ('ada', 'first'), ('grace', NULL)"
        )
        #expect(insert.affectedRows == 2)
        #expect(insert.lastInsertID == 1)

        let select = try await connection.query("SELECT id, name, note FROM \(table) ORDER BY id")
        #expect(select.rows.count == 2)
        #expect(select.rows[0].string(at: 1) == "ada")
        #expect(select.rows[1].string(at: 1) == "grace")
        #expect(select.rows[1].values[2].isNull)   // NULL note

        let update = try await connection.query("UPDATE \(table) SET note = 'x' WHERE name = 'grace'")
        #expect(update.affectedRows == 1)

        try await connection.query("DROP TABLE \(table)")
    }

    // MARK: - Column metadata

    @Test("column metadata carries type, flags and charset", arguments: TestServers.all)
    func columnMetadata(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "phase2_meta_\(server.name)"
        try await connection.query("DROP TABLE IF EXISTS \(table)")
        try await connection.query(
            "CREATE TABLE \(table) (id INT UNSIGNED NOT NULL, label VARCHAR(32), payload BLOB)"
        )
        let result = try await connection.query("SELECT id, label, payload FROM \(table)")

        #expect(result.columns.count == 3)
        #expect(result.columns[0].name == "id")
        #expect(result.columns[0].isUnsigned)
        #expect(result.columns[0].flags.contains(.notNull))
        // A BLOB is told from a TEXT only by the binary charset, since they
        // share a column type.
        #expect(result.columns[2].isBinary)
        #expect(result.columns[1].isBinary == false)

        try await connection.query("DROP TABLE \(table)")
    }

    // MARK: - Errors

    @Test("a SQL error surfaces the server's code and SQL state", arguments: TestServers.all)
    func sqlErrorSurfaces(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        do {
            _ = try await connection.query("SELECT * FROM definitely_no_such_table")
            Issue.record("expected a server error")
        } catch let error as MySQLProtocolError {
            guard case .server(let code, let sqlState, _) = error else {
                Issue.record("expected .server, got \(error)")
                return
            }
            #expect(code == 1146)          // ER_NO_SUCH_TABLE
            #expect(sqlState == "42S02")
        }
    }

    /// A failed command must leave the connection usable.
    @Test("connection survives a SQL error", arguments: TestServers.all)
    func connectionUsableAfterError(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        _ = try? await connection.query("SELECT * FROM definitely_no_such_table")

        let result = try await connection.query("SELECT 42 AS answer")
        #expect(result.rows[0].string(at: 0) == "42")
    }

    // MARK: - Multi-resultset

    /// A stored procedure always returns a trailing status result set. Failing
    /// to drain it desynchronises the connection — this is MySQLNIO's open
    /// crash #118.
    @Test("stored procedure produces multiple result sets", arguments: TestServers.all)
    func storedProcedureMultiResult(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let name = "phase2_proc_\(server.name)"
        try await connection.query("DROP PROCEDURE IF EXISTS \(name)")
        try await connection.query(
            "CREATE PROCEDURE \(name)() BEGIN SELECT 1 AS a; END"
        )

        let all = try await connection.queryAll("CALL \(name)()")
        // One set of rows plus the procedure's trailing status set.
        #expect(all.count >= 2)
        #expect(all[0].rows.count == 1)
        #expect(all[0].rows[0].string(at: 0) == "1")

        // The connection must still be usable — the trailing set was drained.
        let after = try await connection.query("SELECT 7 AS seven")
        #expect(after.rows[0].string(at: 0) == "7")

        try await connection.query("DROP PROCEDURE \(name)")
    }

    // MARK: - Larger payloads

    @Test("a value larger than one packet round-trips", arguments: TestServers.all)
    func largeValue(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        // Comfortably over a single TCP segment, and enough rows to require
        // several reads under demand-driven read control.
        let result = try await connection.query("SELECT REPEAT('a', 100000) AS big")
        #expect(result.rows[0].string(at: 0)?.count == 100_000)
    }

    @Test("many rows arrive completely", arguments: TestServers.all)
    func manyRows(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "phase2_bulk_\(server.name)"
        try await connection.query("DROP TABLE IF EXISTS \(table)")
        try await connection.query("CREATE TABLE \(table) (n INT)")
        // 1000 rows via a recursive CTE-free approach that works on both flavours.
        try await connection.query(
            """
            INSERT INTO \(table) (n)
            SELECT a.i + b.i * 10 + c.i * 100
            FROM (SELECT 0 i UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4
                  UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a,
                 (SELECT 0 i UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4
                  UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b,
                 (SELECT 0 i UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4
                  UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
            """
        )

        let result = try await connection.query("SELECT n FROM \(table)")
        #expect(result.rows.count == 1000)

        try await connection.query("DROP TABLE \(table)")
    }
}

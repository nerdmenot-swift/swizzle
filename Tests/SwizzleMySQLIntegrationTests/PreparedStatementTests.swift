import NIOCore
import Testing
@testable import SwizzleMySQL

/// Prepared statements against real servers. This is also the first end-to-end
/// exercise of the **binary** protocol decoders from Phase 3 — `COM_STMT_EXECUTE`
/// returns binary rows, not text.
@Suite(
    "Prepared statements",
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct PreparedStatementTests {

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

    // MARK: - Basics

    @Test("prepare reports parameter and column counts", arguments: TestServers.all)
    func prepareMetadata(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let statement = try await connection.prepare("SELECT ? AS a, ? AS b")
        #expect(statement.parameterCount == 2)
        #expect(statement.id > 0)

        // Both lists can be empty, and the empty cases are where off-by-one
        // state bugs hide.
        let noParams = try await connection.prepare("SELECT 1")
        #expect(noParams.parameterCount == 0)
        #expect(noParams.columns.count == 1)
    }

    @Test("execute round-trips parameters", arguments: TestServers.all)
    func executeWithParameters(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let result = try await connection.query(
            "SELECT ? AS n, ? AS s", [.int(42), .bytes(Array("hello".utf8))]
        )
        #expect(result.rows.count == 1)
        #expect(result.rows[0][0].int == 42)
        #expect(result.rows[0][1].string == "hello")
    }

    /// Binary rows omit NULL values entirely, so the bitmap is the only thing
    /// keeping the remaining values aligned.
    @Test("NULL parameters and NULL results", arguments: TestServers.all)
    func nullHandling(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let result = try await connection.query(
            "SELECT ? AS a, ? AS b, ? AS c", [.int(1), .null, .int(3)]
        )
        #expect(result.rows[0][0].int == 1)
        #expect(result.rows[0][1].isNull)
        #expect(result.rows[0][2].int == 3)
    }

    @Test("parameter count is validated", arguments: TestServers.all)
    func parameterCountValidated(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let statement = try await connection.prepare("SELECT ? AS a, ? AS b")
        await #expect(throws: (any Error).self) {
            _ = try await connection.execute(statement, [.int(1)])
        }
    }

    // MARK: - Binary protocol types

    @Test("binary protocol decodes types correctly", arguments: TestServers.all)
    func binaryTypes(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "phase4_types_\(server.name)"
        try await connection.query("DROP TABLE IF EXISTS \(table)")
        try await connection.query(
            """
            CREATE TABLE \(table) (
              i INT, ub BIGINT UNSIGNED, d DOUBLE, dec1 DECIMAL(20,6),
              s VARCHAR(32), dt DATETIME(6), t TIME, n INT NULL
            )
            """
        )
        try await connection.query(
            "INSERT INTO \(table) VALUES (-7, 18446744073709551615, 1.5, "
            + "'12345678901234.123456', 'text', '2024-01-15 13:45:30.123456', '-838:59:59', NULL)"
        )

        // Read back through the *binary* protocol.
        let result = try await connection.query("SELECT * FROM \(table)", [])

        #expect(result.value("i") == .int(-7))
        #expect(result.value("ub") == .uint(18_446_744_073_709_551_615))
        #expect(result.value("d")?.double == 1.5)
        // DECIMAL stays textual in the binary protocol too.
        #expect(result.value("dec1")?.string == "12345678901234.123456")
        #expect(result.value("s")?.string == "text")

        guard case .dateTime(let dt)? = result.value("dt") else {
            Issue.record("expected DATETIME"); return
        }
        #expect(dt.year == 2024 && dt.hour == 13 && dt.microsecond == 123_456)

        guard case .time(let time)? = result.value("t") else {
            Issue.record("expected TIME"); return
        }
        #expect(time.isNegative && time.totalHours == 838)

        #expect(result.value("n")?.isNull == true)

        try await connection.query("DROP TABLE \(table)")
    }

    /// Parameters must survive the round trip in the shapes we encode them.
    @Test("temporal and unsigned parameters bind correctly", arguments: TestServers.all)
    func parameterEncoding(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let dateTime = MySQLDateTime(
            year: 2024, month: 3, day: 9, hour: 1, minute: 2, second: 3, microsecond: 456_789
        )
        let result = try await connection.query(
            "SELECT ? AS d, ? AS u, ? AS f", [
                .dateTime(dateTime),
                .uint(18_446_744_073_709_551_615),
                .double(2.25),
            ]
        )
        #expect(result.value("d")?.string?.hasPrefix("2024-03-09 01:02:03") == true)
        #expect(result.value("u")?.string == "18446744073709551615")
        #expect(result.value("f")?.double == 2.25)
    }

    // MARK: - Statement cache

    /// The reason for writing our own driver: MySQLNIO closes every statement
    /// as soon as its result set finishes, paying PREPARE/EXECUTE/CLOSE on
    /// every query.
    @Test("repeated queries reuse one server-side statement", arguments: TestServers.all)
    func cacheReusesStatements(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let sql = "SELECT ? AS cached_probe"
        let first = try await connection.prepare(sql)
        for _ in 0..<10 {
            let again = try await connection.prepare(sql)
            #expect(again.id == first.id, "the cache must return the same statement")
        }
        let cached = try await connection.cachedStatementCount
        #expect(cached == 1)
    }

    /// Executing repeatedly must not re-prepare.
    ///
    /// Deliberately *not* asserted against `Prepared_stmt_count`: that status
    /// variable is **global**, not per-session, so parallel test connections
    /// pollute it and the assertion would be flaky rather than wrong. Statement
    /// identity is connection-local and proves the same property.
    @Test("executing repeatedly reuses one statement", arguments: TestServers.all)
    func executeDoesNotRePrepare(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let sql = "SELECT ? AS flat_probe"
        let statement = try await connection.prepare(sql)
        for _ in 0..<20 {
            let result = try await connection.query(sql, [.int(1)])
            #expect(result.rows[0][0].int == 1)
        }

        let again = try await connection.prepare(sql)
        #expect(again.id == statement.id)
        let cached = try await connection.cachedStatementCount
        #expect(cached == 1)
    }

    /// An evicted statement is still allocated on the server, so eviction must
    /// close it rather than orphaning it. A tiny cache makes eviction certain.
    @Test("cache eviction is bounded and closes evicted statements")
    func evictionIsBounded() async throws {
        let server = TestServers.latest
        let user = server.primaryUser
        let connection = try await MySQLConnection.connect(
            configuration: MySQLConnectionConfiguration(
                address: .hostname(TestServers.host, port: server.port),
                username: user.name, password: user.password,
                database: TestServers.database, tls: .disable,
                statementCacheCapacity: 4,
                serverPublicKey: .requestFromServer
            ),
            on: TestServers.group.next()
        )
        defer { connection.closeImmediately() }

        for index in 0..<20 {
            _ = try await connection.prepare("SELECT ? AS probe_\(index)")
        }

        let cached = try await connection.cachedStatementCount
        #expect(cached <= 4, "cache exceeded its capacity: \(cached)")

        // Evicted statements were closed, so the connection is still healthy and
        // a fresh statement still works.
        let result = try await connection.query("SELECT ? AS after_eviction", [.int(9)])
        #expect(result.rows[0][0].int == 9)
    }

    /// Capacity 0 disables caching entirely — which is effectively what
    /// MySQLNIO does on every query.
    @Test("caching can be disabled")
    func cachingCanBeDisabled() async throws {
        let server = TestServers.latest
        let user = server.primaryUser
        let connection = try await MySQLConnection.connect(
            configuration: MySQLConnectionConfiguration(
                address: .hostname(TestServers.host, port: server.port),
                username: user.name, password: user.password,
                database: TestServers.database, tls: .disable,
                statementCacheCapacity: 0,
                serverPublicKey: .requestFromServer
            ),
            on: TestServers.group.next()
        )
        defer { connection.closeImmediately() }

        let first = try await connection.prepare("SELECT ? AS uncached")
        let second = try await connection.prepare("SELECT ? AS uncached")
        #expect(first.id != second.id, "with caching off each prepare is distinct")

        let cached = try await connection.cachedStatementCount
        #expect(cached == 0)

        // A statement returned with caching off must be usable — not already
        // closed. Only executing catches that; comparing ids does not.
        let result = try await connection.execute(first, [.int(3)])
        #expect(result.rows[0][0].int == 3)

        // And the prepare+execute path must still work repeatedly without
        // leaking statements server-side.
        for index in 0..<5 {
            let each = try await connection.query("SELECT ? AS uncached", [.int(Int64(index))])
            #expect(each.rows[0][0].int == Int64(index))
        }
    }

    // MARK: - Reset

    /// `COM_RESET_CONNECTION` deallocates every prepared statement server-side.
    /// Keeping the cache afterwards would hand out ids the server has forgotten,
    /// and the failure would surface on a later, unrelated query.
    @Test("connection reset invalidates the cache", arguments: TestServers.all)
    func resetInvalidatesCache(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let sql = "SELECT ? AS reset_probe"
        let before = try await connection.prepare(sql)
        try await connection.resetConnection()

        let after = try await connection.prepare(sql)
        let cached = try await connection.cachedStatementCount
        #expect(after.id != before.id || cached == 1)

        // Most importantly, it still works.
        let result = try await connection.query(sql, [.int(5)])
        #expect(result.rows[0][0].int == 5)
    }

    // MARK: - DML

    @Test("prepared INSERT reports affected rows", arguments: TestServers.all)
    func preparedInsert(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "phase4_dml_\(server.name)"
        try await connection.query("DROP TABLE IF EXISTS \(table)")
        try await connection.query(
            "CREATE TABLE \(table) (id INT PRIMARY KEY AUTO_INCREMENT, name VARCHAR(32))"
        )

        let insert = try await connection.query(
            "INSERT INTO \(table) (name) VALUES (?)", [.bytes(Array("ada".utf8))]
        )
        #expect(insert.affectedRows == 1)
        #expect(insert.lastInsertID == 1)

        let select = try await connection.query(
            "SELECT name FROM \(table) WHERE id = ?", [.int(1)]
        )
        #expect(select.rows[0][0].string == "ada")

        try await connection.query("DROP TABLE \(table)")
    }
}

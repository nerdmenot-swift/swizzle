import Foundation
import SwizzleCore
import Testing
@testable import SwizzleMySQL

/// Query analysis against a real MySQL/MariaDB server.
///
/// MySQL is the engine that answers the nullability question properly — it
/// computes `NOT_NULL` for the projected expression rather than for the base
/// column — so the tests that matter most here are the ones SQLite and Postgres
/// cannot pass: a `NOT NULL` column reached through a `LEFT JOIN` must come back
/// optional, with no heuristic involved.
@Suite(
    "MySQL query analysis",
    .serialized,
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct MySQLAnalyzerTests {

    static let table = "analyze_users"
    static let orders = "analyze_orders"

    static func connect(_ server: MySQLTestServer) async throws -> MySQLConnection {
        let user = server.primaryUser
        return try await MySQLConnection.connect(
            configuration: .init(
                address: .hostname(TestServers.host, port: server.port),
                username: user.name, password: user.password,
                database: TestServers.database, tls: .disable,
                // Without this the suite is flaky against MySQL 9, and only
                // sometimes. `caching_sha2_password` needs the RSA exchange on a
                // **cache miss** and not otherwise, so a plaintext connection
                // authenticates fine while the server happens to hold the
                // password and is refused — correctly — when it does not. Which
                // of those a test sees depends on what ran before it.
                //
                // The refusal is right: the server would send a public key over
                // a plaintext connection for an attacker in the path to
                // substitute. These fixtures are loopback-only, so accepting it
                // explicitly is what the other integration suites already do.
                serverPublicKey: .requestFromServer
            ),
            on: TestServers.group.next()
        )
    }

    static func seed(_ connection: MySQLConnection) async throws {
        _ = try await connection.query("DROP TABLE IF EXISTS \(orders)")
        _ = try await connection.query("DROP TABLE IF EXISTS \(table)")
        _ = try await connection.query(
            """
            CREATE TABLE \(table) (
                id        BIGINT UNSIGNED NOT NULL PRIMARY KEY,
                email     VARCHAR(255) NOT NULL,
                nickname  VARCHAR(64) NULL,
                balance   DECIMAL(10,2) NOT NULL,
                is_active TINYINT(1) NOT NULL DEFAULT 1,
                avatar    BLOB NULL,
                notes     TEXT NULL
            )
            """
        )
        _ = try await connection.query(
            """
            CREATE TABLE \(orders) (
                id BIGINT NOT NULL PRIMARY KEY,
                user_id BIGINT UNSIGNED NOT NULL,
                total DECIMAL(12,2) NOT NULL
            )
            """
        )
    }

    @Test("columns, types and origins come back from a prepare", arguments: TestServers.mariaDB)
    func describesColumns(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        try await Self.seed(connection)

        let analyzer = MySQLQueryAnalyzer(connection)
        let signature = try await analyzer.analyze(
            "SELECT id, email, nickname, balance FROM \(Self.table) WHERE id = ?"
        )
        await analyzer.finish()

        #expect(signature.columns.map(\.name) == ["id", "email", "nickname", "balance"])
        #expect(signature.parameters.count == 1)

        #expect(signature.columns[1].isOptional == false)
        #expect(signature.columns[2].isOptional)
        // Every answer comes from the server here, never from a heuristic.
        #expect(signature.columns.allSatisfy { $0.nullability == .engineFlag })

        // Origins trace back to the physical table, not the alias.
        #expect(signature.columns[1].origin?.table == Self.table)
        #expect(signature.columns[1].origin?.column == "email")
    }

    /// The one thing no other engine can do: a `NOT NULL` column really can
    /// arrive null through an outer join, and MySQL says so itself.
    @Test("an outer join is handled by the server, not by a heuristic", arguments: TestServers.mariaDB)
    func outerJoinIsServerComputed(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        try await Self.seed(connection)

        let analyzer = MySQLQueryAnalyzer(connection)
        let inner = try await analyzer.analyze(
            "SELECT u.id, o.total FROM \(Self.table) u "
                + "JOIN \(Self.orders) o ON o.user_id = u.id"
        )
        let outer = try await analyzer.analyze(
            "SELECT u.id, o.total FROM \(Self.table) u "
                + "LEFT JOIN \(Self.orders) o ON o.user_id = u.id"
        )
        await analyzer.finish()

        // `total` is NOT NULL in the schema.
        #expect(inner.columns[1].isOptional == false)
        // …and nullable through the join, which the server worked out.
        #expect(outer.columns[1].isOptional)
        #expect(outer.columns[1].nullability == .engineFlag)

        // No widening was applied — the flag is trusted directly, so `hasOuterJoin`
        // is recorded as false and nothing depends on it.
        #expect(outer.hasOuterJoin == false)
    }

    @Test("MySQL's own type quirks map correctly", arguments: TestServers.mariaDB)
    func typeMapping(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        try await Self.seed(connection)

        let analyzer = MySQLQueryAnalyzer(connection)
        let signature = try await analyzer.analyze(
            "SELECT id, balance, is_active, avatar, notes FROM \(Self.table)"
        )
        await analyzer.finish()

        // BIGINT UNSIGNED does not fit Int64, and the driver hands large values
        // over as text rather than wrapping.
        #expect(signature.columns[0].swiftType == .uint64)
        // Exact numerics stay text, or the cents go missing.
        #expect(signature.columns[1].swiftType == .decimalString)
        // TINYINT(1) is how MySQL spells a boolean.
        #expect(signature.columns[2].swiftType == .bool)
        // BLOB and TEXT share a type byte; only the charset separates them.
        #expect(signature.columns[3].swiftType == .bytes)
        #expect(signature.columns[4].swiftType == .string)
    }

    @Test("an expression has no origin", arguments: [TestServers.latest])
    func expressionsHaveNoOrigin(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        try await Self.seed(connection)

        let analyzer = MySQLQueryAnalyzer(connection)
        let signature = try await analyzer.analyze(
            "SELECT COUNT(*) AS n, MAX(balance) AS peak FROM \(Self.table)"
        )
        await analyzer.finish()

        #expect(signature.columns.allSatisfy { $0.origin == nil })
        // COUNT is never null; MAX over no rows is. The server knows both.
        #expect(signature.columns[0].isOptional == false)
        #expect(signature.columns[1].isOptional)
    }

    /// Describing must not run the statement.
    @Test("describing a destructive statement changes nothing", arguments: [TestServers.latest])
    func describeDoesNotExecute(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        try await Self.seed(connection)
        _ = try await connection.query(
            "INSERT INTO \(Self.table) (id, email, balance) VALUES (1, 'a@b.c', 0)"
        )

        let analyzer = MySQLQueryAnalyzer(connection)
        _ = try await analyzer.analyze("DELETE FROM \(Self.table)")
        _ = try await analyzer.analyze("UPDATE \(Self.table) SET email = 'x'")
        await analyzer.finish()

        let rows = try await connection.query("SELECT email FROM \(Self.table)")
        #expect(rows.rows.count == 1)
        #expect(rows.rows.first?[0].string == "a@b.c")
    }

    /// `finish()` is correctness, not tidying.
    ///
    /// `prepare` leaves each statement allocated **on the server**. Analysing a
    /// directory of queries without closing them leaks one per query and evicts
    /// the LRU everything else depends on — the same failure the driver already
    /// paid for once, found the same way, with `Prepared_stmt_count`.
    @Test("analysing many queries leaks no server-side statements", arguments: [TestServers.latest])
    func finishClosesStatements(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        try await Self.seed(connection)

        let baseline = try await Self.preparedCount(connection)

        let analyzer = MySQLQueryAnalyzer(connection)
        for index in 0..<40 {
            _ = try await analyzer.analyze(
                "SELECT id, email FROM \(Self.table) WHERE id = ? /* \(index) */"
            )
        }
        await analyzer.finish()

        // `Prepared_stmt_count` is a **global**, so neighbouring suites move it in
        // both directions while this runs. The leak this guards against was one
        // statement per query — it would show as +40, not as noise.
        var last = -1
        try await eventually(within: .seconds(5), "analysis to release its statements") {
            last = try await Self.preparedCount(connection)
            return last - baseline < 20
        }
        #expect(last - baseline < 20, "analysing 40 queries left \(last - baseline) allocated")
    }

    static func preparedCount(_ connection: MySQLConnection) async throws -> Int {
        let result = try await connection.query(
            "SHOW GLOBAL STATUS LIKE 'Prepared_stmt_count'"
        )
        guard let row = result.rows.first, let text = row[1].string, let value = Int(text) else {
            throw MySQLProtocolError.malformedPacket("could not read Prepared_stmt_count")
        }
        return value
    }

    @Test("a statement the server rejects is reported", arguments: [TestServers.latest])
    func badSQLIsReported(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        try await Self.seed(connection)

        let analyzer = MySQLQueryAnalyzer(connection)
        await #expect(throws: QueryAnalysisError.self) {
            _ = try await analyzer.analyze("SELECT nope FROM \(Self.table)")
        }
        await analyzer.finish()
    }
}

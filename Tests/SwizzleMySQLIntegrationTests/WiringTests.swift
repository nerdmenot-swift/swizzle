import NIOCore
import Testing
@testable import SwizzleMySQL

/// Covers the pieces that existed as encoders or configuration but had no live
/// exercise: cursors, `COM_SET_OPTION`, `COM_CHANGE_USER`, `COM_STMT_RESET`,
/// session-state tracking, unix sockets and connection attributes.
@Suite(
    "Wiring",
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct WiringTests {

    static func connect(
        _ server: MySQLTestServer,
        user: MySQLTestServer.TestUser? = nil,
        tls: MySQLConnectionConfiguration.TLSMode = .disable
    ) async throws -> MySQLConnection {
        let account = user
            ?? server.primaryUser
        return try await MySQLConnection.connect(
            configuration: MySQLConnectionConfiguration(
                address: .hostname(TestServers.host, port: server.port),
                username: account.name,
                password: account.password,
                database: TestServers.database,
                tls: tls,
                serverPublicKey: .requestFromServer
            ),
            on: TestServers.group.next()
        )
    }

    static func makeRows(
        _ connection: MySQLConnection, table: String, count: Int
    ) async throws {
        try await connection.query("DROP TABLE IF EXISTS \(table)")
        try await connection.query("CREATE TABLE \(table) (n INT)")
        let digits = "(SELECT 0 i UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 "
            + "UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9)"
        try await connection.query(
            """
            INSERT INTO \(table) (n)
            SELECT v FROM (
              SELECT a.i + b.i * 10 + c.i * 100 + d.i * 1000 AS v
              FROM \(digits) a, \(digits) b, \(digits) c, \(digits) d
            ) g WHERE v < \(count)
            """
        )
    }

    // MARK: - Cursor streaming

    @Test("cursor streaming returns every row", arguments: TestServers.all)
    func cursorStreamsAllRows(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "wire_cursor_\(server.name)"
        try await Self.makeRows(connection, table: table, count: 1000)

        let rows = try await connection.streamWithCursor(
            "SELECT n FROM \(table) ORDER BY n", [], prefetch: 64
        )
        var seen: [Int64] = []
        for try await row in rows { seen.append(row[0].int ?? -1) }

        #expect(seen.count == 1000)
        #expect(seen == Array(0..<1000).map(Int64.init))

        try await connection.query("DROP TABLE \(table)")
    }

    /// A prefetch that does not divide the row count evenly is where an
    /// off-by-one in the fetch loop would show up.
    @Test("cursor prefetch boundaries are handled", arguments: TestServers.all)
    func cursorPrefetchBoundaries(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "wire_cursor_odd_\(server.name)"
        try await Self.makeRows(connection, table: table, count: 101)

        for prefetch in [1, 7, 100, 101, 500] {
            let rows = try await connection.streamWithCursor(
                "SELECT n FROM \(table) ORDER BY n", [], prefetch: prefetch
            )
            let collected = try await rows.collect()
            #expect(collected.count == 101, "prefetch \(prefetch) returned \(collected.count)")
        }

        try await connection.query("DROP TABLE \(table)")
    }

    @Test("cursor streaming handles an empty result", arguments: TestServers.all)
    func cursorEmptyResult(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let rows = try await connection.streamWithCursor("SELECT 1 AS n WHERE 1 = 0")
        let collected = try await rows.collect()
        #expect(collected.isEmpty)

        let after = try await connection.query("SELECT 4 AS four")
        #expect(after.rows[0][0].int == 4)
    }

    @Test("cursor streaming binds parameters", arguments: TestServers.all)
    func cursorWithParameters(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "wire_cursor_param_\(server.name)"
        try await Self.makeRows(connection, table: table, count: 500)

        let rows = try await connection.streamWithCursor(
            "SELECT n FROM \(table) WHERE n < ? ORDER BY n", [.int(50)], prefetch: 16
        )
        let collected = try await rows.collect()
        #expect(collected.count == 50)

        try await connection.query("DROP TABLE \(table)")
    }

    // MARK: - Statement reset

    /// A cached statement left mid-cursor must be resettable, or the server
    /// refuses to re-execute it.
    @Test("statement reset clears an open cursor", arguments: TestServers.all)
    func statementResetClearsCursor(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "wire_reset_\(server.name)"
        try await Self.makeRows(connection, table: table, count: 200)

        let statement = try await connection.prepare("SELECT n FROM \(table) ORDER BY n")
        try await connection.resetStatement(statement)

        let result = try await connection.execute(statement, [])
        #expect(result.rows.count == 200)

        try await connection.query("DROP TABLE \(table)")
    }

    // MARK: - Session options

    /// Multi-statements are off by default, and should stay off: one injected
    /// `;` becomes an arbitrary second statement.
    @Test("multi-statements are off by default", arguments: TestServers.all)
    func multiStatementsDefaultOff(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        await #expect(throws: (any Error).self) {
            _ = try await connection.query("SELECT 1; SELECT 2")
        }
    }

    @Test("multi-statements can be enabled and disabled", arguments: TestServers.all)
    func multiStatementsToggle(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        try await connection.setMultiStatements(true)
        let results = try await connection.queryAll("SELECT 1 AS a; SELECT 2 AS b")
        #expect(results.count >= 2)
        #expect(results[0].rows[0][0].int == 1)
        #expect(results[1].rows[0][0].int == 2)

        try await connection.setMultiStatements(false)
        await #expect(throws: (any Error).self) {
            _ = try await connection.query("SELECT 1; SELECT 2")
        }
    }

    // MARK: - COM_CHANGE_USER

    @Test("change user re-authenticates and clears the statement cache")
    func changeUserWorks() async throws {
        let server = TestServers.latest
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        _ = try await connection.prepare("SELECT ? AS before_change")
        let cachedBefore = try await connection.cachedStatementCount
        #expect(cachedBefore == 1)

        // Any account whose plugin COM_CHANGE_USER can answer — native or
        // caching_sha2. `nopass` also exercises the empty-password response.
        let target = server.users.first { $0.name == "nopass" }!
        try await connection.changeUser(
            username: target.name, password: target.password, database: TestServers.database
        )

        // Re-authentication deallocates every statement server-side.
        let cachedAfter = try await connection.cachedStatementCount
        #expect(cachedAfter == 0)

        let who = try await connection.query("SELECT CURRENT_USER() AS u")
        #expect(who.rows[0][0].string?.hasPrefix("nopass") == true)

        // And the connection still works for prepared statements.
        let result = try await connection.query("SELECT ? AS after_change", [.int(7)])
        #expect(result.rows[0][0].int == 7)
    }

    // MARK: - Plugins with no live fixture
    //
    // `caching_sha2_password` and `sha256_password` are MySQL plugins; MariaDB
    // implements neither, so with a MariaDB-only matrix there is no server to
    // run them against. The implementations and their known-answer tests stay
    // in `Tests/SwizzleMySQLTests/AuthTests.swift` (vectors from go-sql-driver
    // and rust-mysql-common), but the end-to-end paths — including the RSA
    // full-authentication exchange — are no longer covered here.
    //
    // Restoring that coverage means adding a MySQL server back to the matrix.

    // MARK: - Connection attributes

    /// Attributes are cheap and make a connection identifiable during incident
    /// triage — worth confirming they actually reach the server.
    @Test("connection attributes reach the server")
    func connectionAttributesArrive() async throws {
        let connection = try await Self.connect(TestServers.latest)
        defer { connection.closeImmediately() }

        let result = try await connection.query(
            """
            SELECT ATTR_VALUE FROM performance_schema.session_connect_attrs
            WHERE PROCESSLIST_ID = CONNECTION_ID() AND ATTR_NAME = '_client_name'
            """
        )
        #expect(result.rows.first?[0].string == "swizzle-mysql")
    }

    // MARK: - ANSI_QUOTES detection

    /// Surfaced on the connection because it changes how generated SQL must be
    /// quoted — a `SwizzleCore` concern, not only a driver one.
    @Test("ANSI_QUOTES is reported", arguments: TestServers.all)
    func ansiQuotesDetected(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        // Fixtures run with the default sql_mode, so this must be false.
        #expect(connection.metadata.isANSIQuotes == false)
    }

    // MARK: - Session state tracking

    /// With `SESSION_TRACK` negotiated the OK packet's `info` field is
    /// length-encoded and may be followed by a state-change block. Parsing it
    /// as the non-tracking form swallows the changes into the info string.
    @Test("session state changes are reported", arguments: TestServers.all)
    func sessionStateTracking(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        #expect(connection.metadata.capabilities.contains(.sessionTrack))

        // Ask the server to report system-variable changes, then make one.
        try await connection.query("SET @@SESSION.session_track_system_variables = 'autocommit'")
        try await connection.query("SET autocommit = 0")

        // The connection must remain correct regardless of what was tracked —
        // the parse is what is under test here.
        let result = try await connection.query("SELECT @@autocommit AS ac")
        #expect(result.rows[0][0].int == 0)

        try await connection.query("SET autocommit = 1")
    }

    // MARK: - Unix socket

    /// A unix socket counts as a secure transport, so `caching_sha2_password`
    /// full auth may send the password in the clear over it.
    @Test("unix socket transport is treated as secure")
    func unixSocketIsSecure() {
        let tcp = MySQLConnectionConfiguration.Address.hostname("127.0.0.1", port: 3306)
        let socket = MySQLConnectionConfiguration.Address.unixDomainSocket(path: "/tmp/mysql.sock")
        #expect(tcp.isSecureTransport == false)
        #expect(socket.isSecureTransport)
    }
}

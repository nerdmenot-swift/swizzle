import NIOCore
import NIOPosix
import SwizzleMySQL
import Testing

/// The two commands the checklist marked done with nothing exercising them.
///
/// Found by asking, of every ✅ row, "what test proves this" — the same question
/// that turned up `COM_QUIT`, which had been ticked for a year on the strength of
/// an enum case that nothing ever sent.
@Suite(
    "MySQL session commands", .serialized,
    .enabled(if: TestServers.isAvailable, "Integration servers not reachable")
)
struct SessionCommandTests {

    static func connect(_ server: MySQLTestServer) async throws -> MySQLConnection {
        let user = server.primaryUser
        let configuration = try MySQLConnectionConfiguration(
            url: "mysql://\(user.name):\(user.password)@\(TestServers.host):\(server.port)"
                + "/\(TestServers.database)?allow_public_key_retrieval=true&tls=require"
                + "&connect_timeout=\(TestServers.connectTimeout.nanoseconds / 1_000_000_000)"
        )
        return try await MySQLConnection.connect(
            configuration: configuration, on: MultiThreadedEventLoopGroup.singleton.next()
        )
    }

    // MARK: - COM_INIT_DB

    @Test("useDatabase changes the current schema", arguments: TestServers.all)
    func useDatabase(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let before = try await connection.query("SELECT DATABASE()")
        #expect(before.rows[0][0].string == TestServers.database)

        try await connection.useDatabase("information_schema")
        let after = try await connection.query("SELECT DATABASE()")
        #expect(after.rows[0][0].string == "information_schema")

        // And back, so the connection is left as it was found.
        try await connection.useDatabase(TestServers.database)
        let restored = try await connection.query("SELECT DATABASE()")
        #expect(restored.rows[0][0].string == TestServers.database)
    }

    /// A failed `COM_INIT_DB` must leave the connection usable and the current
    /// schema unchanged — an error is not a reason to lose the session.
    @Test("a bad database name errors without disturbing the session", arguments: TestServers.all)
    func useMissingDatabase(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        await #expect(throws: MySQLProtocolError.self) {
            try await connection.useDatabase("swizzle_no_such_database")
        }

        let current = try await connection.query("SELECT DATABASE()")
        #expect(current.rows[0][0].string == TestServers.database)
    }

    // MARK: - COM_STMT_CLOSE

    /// Closing a statement has to remove it from the driver's cache *and*
    /// deallocate it on the server.
    ///
    /// The obvious evidence — `Prepared_stmt_count` — is the wrong instrument:
    /// despite answering to `SHOW SESSION STATUS`, it is a **server-global**
    /// counter, so any other suite preparing a statement on the same fixture
    /// moves it. Written that way first, this test failed on roughly one run in
    /// three.
    ///
    /// The hermetic evidence is the statement handle itself: after a close, the
    /// server no longer knows the id, so executing it must fail.
    @Test("closing a statement deallocates it on the server", arguments: TestServers.all)
    func closeStatement(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let statement = try await connection.prepare("SELECT ? + 1")
        let before = try await connection.execute(statement, [.int(41)])
        #expect(before.rows[0][0].int == 42)
        #expect(try await connection.cachedStatementCount > 0)

        try await connection.closeStatement(statement)

        // The cache has forgotten it, or the next execution would bind an id the
        // server no longer knows.
        #expect(try await connection.cachedStatementCount == 0)

        // And so has the server: the handle is dead, which is what "deallocated"
        // actually means.
        await #expect(throws: MySQLProtocolError.self) {
            _ = try await connection.execute(statement, [.int(1)])
        }

        // The connection survives that — an unknown statement id is a statement
        // error, not a protocol desync — and the same SQL prepares afresh.
        let again = try await connection.prepare("SELECT ? + 1")
        let rows = try await connection.execute(again, [.int(41)])
        #expect(rows.rows[0][0].int == 42)
    }
}

import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import SwizzleMySQL

/// Server-side prepared statements must not outlive their use.
///
/// A `COM_STMT_PREPARE` allocates a statement **on the server**, and it stays
/// allocated until `COM_STMT_CLOSE` or the connection dies. The statement cache
/// is what normally owns that lifetime — but with caching switched off nothing
/// owns it, and every call has to close what it prepared.
///
/// `Prepared_stmt_count` is the server's own count of currently-allocated
/// statements, so it measures the thing directly rather than by proxy. The cap
/// is `max_prepared_stmt_count`, 16382 by default: a leak does not degrade
/// gradually, it works fine and then the connection starts refusing every query
/// with *"Can't create more than max_prepared_stmt_count statements"*.
@Suite(
    "Prepared statement lifetime",
    .serialized,
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct StatementLifetimeTests {

    /// A connection with the statement cache **disabled**, which is the
    /// configuration where every path has to clean up after itself.
    static func uncachedConnection(_ server: MySQLTestServer) async throws -> MySQLConnection {
        let user = server.primaryUser
        return try await MySQLConnection.connect(
            configuration: MySQLConnectionConfiguration(
                address: .hostname(TestServers.host, port: server.port),
                username: user.name, password: user.password,
                database: TestServers.database, tls: .disable,
                statementCacheCapacity: 0,
                serverPublicKey: .requestFromServer
            ),
            on: TestServers.group.next()
        )
    }

    /// Asserts the count does not end up above `baseline`.
    ///
    /// Two things make this weaker than an equality check, both deliberate.
    ///
    /// It **polls** rather than sampling once, because the buffered path closes
    /// its statement from a detached task: a count taken the instant the loop
    /// ends catches closes still in flight and reports a leak that is not one.
    /// Polling separates *slow to clean up* from *never cleans up*, which is the
    /// distinction being tested.
    ///
    /// And it asserts `<=` rather than `==`, because `Prepared_stmt_count` is a
    /// **global** status variable — it counts statements across every session on
    /// the server, so a suite running in parallel moves it underneath us. It has
    /// been seen to finish *below* baseline for that reason. Growth is still
    /// caught: the bug this guards against left one statement per call, so it
    /// showed up as +25 and +50, not as noise.
    static func expectSettles(
        _ connection: MySQLConnection, to baseline: Int, _ what: String,
        operations: Int
    ) async throws {
        var last = -1
        // Tolerance rather than equality, because `Prepared_stmt_count` is a
        // **global**: every other suite sharing this server moves it in both
        // directions while we measure. An earlier `== baseline` failed when a
        // concurrent suite closed statements; `<= baseline` then failed when one
        // opened them.
        //
        // The bug this guards against leaked one statement per operation — it
        // showed up as +25 and +50, not as noise — so anything under half the
        // operation count is comfortably below a real leak and comfortably above
        // what neighbouring suites contribute.
        let tolerance = max(4, operations / 2)
        try await eventually(within: .seconds(5), "\(what) to release its statements") {
            last = try await preparedCount(connection)
            return last - baseline < tolerance
        }
        #expect(
            last - baseline < tolerance,
            "\(what) left \(last - baseline) statements allocated after \(operations) operations"
        )
    }

    /// The server's count of statements currently allocated, across all sessions.
    static func preparedCount(_ connection: MySQLConnection) async throws -> Int {
        let result = try await connection.query(
            "SHOW GLOBAL STATUS LIKE 'Prepared_stmt_count'"
        )
        guard let row = result.rows.first, let text = row[1].string, let value = Int(text) else {
            throw MySQLProtocolError.malformedPacket("could not read Prepared_stmt_count")
        }
        return value
    }

    static func makeTable(_ connection: MySQLConnection) async throws -> String {
        let name = "stmtlife_\(UInt32.random(in: 0..<UInt32.max))"
        _ = try await connection.query("CREATE TABLE \(name) (n INT PRIMARY KEY)")
        let values = (0..<200).map { "(\($0))" }.joined(separator: ",")
        _ = try await connection.query("INSERT INTO \(name) VALUES \(values)")
        return name
    }

    /// The path that already cleaned up, kept as the control: if this drifts,
    /// the measurement itself is wrong rather than the code under test.
    @Test("a buffered parameterised query leaves nothing allocated")
    func bufferedQueryDoesNotLeak() async throws {
        let connection = try await Self.uncachedConnection(TestServers.latest)
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        let baseline = try await Self.preparedCount(connection)
        for index in 0..<50 {
            let result = try await connection.query(
                "SELECT n FROM \(table) WHERE n < ?", [.int(Int64(index))]
            )
            #expect(result.rows.count == index)
        }
        try await Self.expectSettles(connection, to: baseline, "buffered queries", operations: 50)
    }

    /// A stream cannot close its statement when `stream(_:_:)` returns — the
    /// rows have not been read yet. It has to close when the *sequence* ends,
    /// which is why this leaked when the buffered path did not.
    @Test("a fully consumed stream leaves nothing allocated")
    func consumedStreamDoesNotLeak() async throws {
        let connection = try await Self.uncachedConnection(TestServers.latest)
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        let baseline = try await Self.preparedCount(connection)
        for index in 0..<50 {
            var seen = 0
            for try await _ in try await connection.stream(
                "SELECT n FROM \(table) WHERE n < ?", [.int(Int64(index))]
            ) { seen += 1 }
            #expect(seen == index)
        }
        try await Self.expectSettles(connection, to: baseline, "streaming", operations: 50)
    }

    /// Abandoning a stream part-way is the harder case: the sequence terminates
    /// without reaching its end, and the statement still has to go.
    @Test("an abandoned stream leaves nothing allocated")
    func abandonedStreamDoesNotLeak() async throws {
        let connection = try await Self.uncachedConnection(TestServers.latest)
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        let baseline = try await Self.preparedCount(connection)
        for _ in 0..<25 {
            for try await _ in try await connection.stream(
                "SELECT n FROM \(table) WHERE n < ?", [.int(200)]
            ) { break }
        }
        // The drain that follows abandonment is asynchronous, so let the
        // connection come back to idle before counting.
        _ = try await connection.query("SELECT 1")
        try await Self.expectSettles(connection, to: baseline, "abandoning", operations: 25)
    }

    @Test("a cursor stream leaves nothing allocated")
    func cursorStreamDoesNotLeak() async throws {
        let connection = try await Self.uncachedConnection(TestServers.latest)
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        let baseline = try await Self.preparedCount(connection)
        for _ in 0..<25 {
            var seen = 0
            for try await _ in try await connection.streamWithCursor(
                "SELECT n FROM \(table) WHERE n < ?", [.int(200)], prefetch: 32
            ) { seen += 1 }
            #expect(seen == 200)
        }
        try await Self.expectSettles(connection, to: baseline, "cursor streaming", operations: 25)
    }
}

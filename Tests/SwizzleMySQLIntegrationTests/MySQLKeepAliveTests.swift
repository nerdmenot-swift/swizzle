import NIOCore
import NIOPosix
import SwizzleMySQL
import Testing

/// The same check on the MySQL side, for the same reason: the pool calls this on
/// a timer no test's lifetime reaches, so nothing proved it worked.
@Suite(
    "MySQL keep-alive", .serialized,
    .enabled(if: TestServers.isAvailable, "Integration servers not reachable")
)
struct MySQLKeepAliveTests {

    static func connect(_ server: MySQLTestServer) async throws -> MySQLConnection {
        let user = server.primaryUser
        let configuration = try MySQLConnectionConfiguration(
            url: "mysql://\(user.name):\(user.password)@\(TestServers.host):\(server.port)"
                + "/\(TestServers.database)?allow_public_key_retrieval=true&tls=require"
        )
        return try await MySQLConnection.connect(
            configuration: configuration, on: MultiThreadedEventLoopGroup.singleton.next()
        )
    }

    @Test("the keep-alive succeeds on a live connection and leaves it usable")
    func succeedsOnLiveConnection() async throws {
        let connection = try await Self.connect(TestServers.mariadb114)
        defer { connection.closeImmediately() }

        let behavior = MySQLKeepAliveBehavior()
        try await behavior.runKeepAlive(for: connection)
        try await behavior.runKeepAlive(for: connection)

        let result = try await connection.query("SELECT 1")
        #expect(result.rows[0][0].int == 1)
    }

    /// Throwing is how the pool learns to discard the connection. Hanging would
    /// stall the maintenance loop for every other connection in the pool — and
    /// `ping` goes through the same `send` path that used to hang forever on a
    /// closed channel.
    @Test("the keep-alive fails on a dead connection rather than hanging")
    func failsOnDeadConnection() async throws {
        let connection = try await Self.connect(TestServers.mariadb114)
        try await connection.close()

        let behavior = MySQLKeepAliveBehavior()
        await #expect(throws: MySQLProtocolError.self) {
            try await behavior.runKeepAlive(for: connection)
        }
    }

    @Test("the frequency is configurable and can be switched off")
    func frequency() {
        #expect(MySQLKeepAliveBehavior().keepAliveFrequency == .seconds(30))
        #expect(MySQLKeepAliveBehavior(frequency: nil).keepAliveFrequency == nil)
    }
}

import NIOCore
import NIOPosix
import Testing
@testable import SwizzleMySQL

/// Connection options added to reach parity with `mysql_async`'s `Opts`.
@Suite(
    "Parity options",
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct ParityOptionsTests {

    static func connect(
        _ server: MySQLTestServer,
        matchedRows: Bool = false,
        setup: [String] = []
    ) async throws -> MySQLConnection {
        var config = TestServers.configuration(for: server)
        config.reportsMatchedRows = matchedRows
        config.setupStatements = setup
        return try await MySQLConnection.connect(
            configuration: config, on: TestServers.group.next()
        )
    }

    /// `CLIENT_FOUND_ROWS` changes what an UPDATE reports: matched rows rather
    /// than changed rows. The distinction only shows on an update that changes
    /// nothing, which is exactly the case callers get wrong.
    @Test("reportsMatchedRows changes UPDATE accounting", arguments: TestServers.all)
    func matchedRows(server: MySQLTestServer) async throws {
        let table = "parity_\(UInt32.random(in: 0..<UInt32.max))"

        let plain = try await Self.connect(server)
        defer { plain.closeImmediately() }
        _ = try await plain.query("DROP TABLE IF EXISTS \(table)")
        _ = try await plain.query("CREATE TABLE \(table) (id INT PRIMARY KEY, n INT)")
        defer { Task { try? await plain.query("DROP TABLE IF EXISTS \(table)") } }
        _ = try await plain.query("INSERT INTO \(table) VALUES (1, 5)")

        // Setting n to the value it already has changes nothing.
        let changed = try await plain.query("UPDATE \(table) SET n = 5 WHERE id = 1")
        #expect(changed.affectedRows == 0, "default should report changed rows")

        let matching = try await Self.connect(server, matchedRows: true)
        defer { matching.closeImmediately() }
        #expect(matching.metadata.capabilities.contains(.foundRows))

        let matched = try await matching.query("UPDATE \(table) SET n = 5 WHERE id = 1")
        #expect(matched.affectedRows == 1, "with CLIENT_FOUND_ROWS it should report matched rows")
    }

    @Test("setup statements run before the connection is handed out",
          arguments: TestServers.all)
    func setupStatementsApply(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(
            server, setup: ["SET SESSION time_zone = '+05:30'", "SET SESSION sql_mode = ''"]
        )
        defer { connection.closeImmediately() }

        let zone = try await connection.query("SELECT @@SESSION.time_zone")
        #expect(zone.rows[0][0].string == "+05:30")
        let mode = try await connection.query("SELECT @@SESSION.sql_mode")
        #expect(mode.rows[0][0].string == "")
    }

    /// A failing setup statement must fail the *connect*, not hand back a
    /// half-configured connection whose misconfiguration surfaces later as
    /// wrong results.
    @Test("a failing setup statement fails the connection", arguments: [TestServers.latest])
    func failingSetupFailsConnect(server: MySQLTestServer) async throws {
        await #expect(throws: (any Error).self) {
            _ = try await Self.connect(server, setup: ["THIS IS NOT SQL"])
        }
    }

    @Test("no setup statements is the default", arguments: [TestServers.latest])
    func noSetupByDefault(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        #expect(!connection.metadata.capabilities.contains(.foundRows))
        #expect(connection.isActive)
    }
}

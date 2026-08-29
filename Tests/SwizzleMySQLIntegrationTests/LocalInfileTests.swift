import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import SwizzleMySQL

/// `LOAD DATA LOCAL INFILE` against real servers.
///
/// The feature is unusual in that the *server* names the file, so most of what
/// is worth testing here is the refusal path rather than the happy one: that a
/// path outside the allow-list is not sent, and — just as important — that
/// refusing leaves the connection usable rather than desynchronised.
@Suite(
    "LOCAL INFILE",
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct LocalInfileTests {

    static func configuration(
        _ server: MySQLTestServer,
        localInfile: MySQLConnectionConfiguration.LocalInfile
    ) -> MySQLConnectionConfiguration {
        var config = TestServers.configuration(for: server)
        config.localInfile = localInfile
        return config
    }

    static func connect(
        _ server: MySQLTestServer,
        localInfile: MySQLConnectionConfiguration.LocalInfile
    ) async throws -> MySQLConnection {
        try await MySQLConnection.connect(
            configuration: configuration(server, localInfile: localInfile),
            on: TestServers.group.next()
        )
    }

    /// Writes a CSV and returns its path, cleaned up by the caller.
    static func makeCSV(rows: Int) throws -> String {
        let directory = FileManager.default.temporaryDirectory
        let url = directory.appendingPathComponent("swizzle-infile-\(UUID().uuidString).csv")
        let body = (1...rows).map { "\($0),name-\($0)" }.joined(separator: "\n") + "\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    static func makeTable(_ connection: MySQLConnection) async throws -> String {
        let name = "infile_\(UInt32.random(in: 0..<UInt32.max))"
        _ = try await connection.query(
            "CREATE TEMPORARY TABLE \(name) (id INT, label VARCHAR(64))"
        )
        return name
    }

    // MARK: - Happy path

    @Test("loads an allow-listed file", arguments: TestServers.all)
    func loadsAllowedFile(server: MySQLTestServer) async throws {
        let path = try Self.makeCSV(rows: 500)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let connection = try await Self.connect(server, localInfile: .allowList([path]))
        defer { connection.closeImmediately() }

        let table = try await Self.makeTable(connection)
        _ = try await connection.query(
            """
            LOAD DATA LOCAL INFILE '\(path)' INTO TABLE \(table)
            FIELDS TERMINATED BY ',' LINES TERMINATED BY '\\n'
            """
        )

        let count = try await connection.query("SELECT COUNT(*) FROM \(table)")
        #expect(count.rows[0][0].int == 500)

        let sample = try await connection.query("SELECT label FROM \(table) WHERE id = 42")
        #expect(sample.rows[0][0].string == "name-42")
    }

    /// Larger than the 1 MiB transfer chunk, so the file spans several packets.
    @Test("loads a file spanning several packets", arguments: [TestServers.latest])
    func loadsMultiPacketFile(server: MySQLTestServer) async throws {
        let path = try Self.makeCSV(rows: 120_000)          // ~2 MB
        defer { try? FileManager.default.removeItem(atPath: path) }

        let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int ?? 0
        #expect(size > 1 << 20, "fixture must exceed one transfer chunk to be meaningful")

        let connection = try await Self.connect(server, localInfile: .allowList([path]))
        defer { connection.closeImmediately() }

        let table = try await Self.makeTable(connection)
        _ = try await connection.query(
            """
            LOAD DATA LOCAL INFILE '\(path)' INTO TABLE \(table)
            FIELDS TERMINATED BY ',' LINES TERMINATED BY '\\n'
            """
        )

        let count = try await connection.query("SELECT COUNT(*) FROM \(table)")
        #expect(count.rows[0][0].int == 120_000)
    }

    // MARK: - Refusal

    /// The default. A server that asks for a file gets nothing.
    @Test("refuses when disabled", arguments: TestServers.all)
    func refusesWhenDisabled(server: MySQLTestServer) async throws {
        let path = try Self.makeCSV(rows: 10)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let connection = try await Self.connect(server, localInfile: .disabled)
        defer { connection.closeImmediately() }

        let table = try await Self.makeTable(connection)
        await #expect(throws: (any Error).self) {
            _ = try await connection.query(
                "LOAD DATA LOCAL INFILE '\(path)' INTO TABLE \(table)"
            )
        }
    }

    /// The case the allow-list exists for: the server names a file we hold, but
    /// not one we agreed to send.
    @Test("refuses a path outside the allow-list", arguments: TestServers.all)
    func refusesUnlistedPath(server: MySQLTestServer) async throws {
        let listed = try Self.makeCSV(rows: 10)
        let unlisted = try Self.makeCSV(rows: 10)
        defer {
            try? FileManager.default.removeItem(atPath: listed)
            try? FileManager.default.removeItem(atPath: unlisted)
        }

        let connection = try await Self.connect(server, localInfile: .allowList([listed]))
        defer { connection.closeImmediately() }

        let table = try await Self.makeTable(connection)
        await #expect(throws: (any Error).self) {
            _ = try await connection.query(
                "LOAD DATA LOCAL INFILE '\(unlisted)' INTO TABLE \(table)"
            )
        }

        // Nothing was loaded — the refusal is real, not just a reported error.
        let count = try await connection.query("SELECT COUNT(*) FROM \(table)")
        #expect(count.rows[0][0].int == 0)
    }

    /// The property that makes refusal safe to use. The protocol is mid-transfer
    /// when we refuse, so the terminator still has to be sent and the server's
    /// reply consumed. Without that the next query would read the *previous*
    /// exchange's reply and everything after it would be off by one.
    @Test("connection stays usable after a refusal", arguments: TestServers.all)
    func connectionSurvivesRefusal(server: MySQLTestServer) async throws {
        let path = try Self.makeCSV(rows: 10)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let connection = try await Self.connect(server, localInfile: .disabled)
        defer { connection.closeImmediately() }

        let table = try await Self.makeTable(connection)
        _ = try? await connection.query("LOAD DATA LOCAL INFILE '\(path)' INTO TABLE \(table)")

        // Several queries, because a one-off desync shows up as the *second*
        // query returning the first one's answer.
        for i in 1...5 {
            let result = try await connection.query("SELECT \(i) AS n")
            #expect(result.rows[0][0].int == Int64(i))
        }
        #expect(connection.isActive)
    }

    /// A file that vanishes between allow-listing and transfer takes the same
    /// path as a refusal, and must be just as survivable.
    @Test("connection stays usable when the file is unreadable", arguments: [TestServers.latest])
    func connectionSurvivesMissingFile(server: MySQLTestServer) async throws {
        let path = try Self.makeCSV(rows: 10)
        let connection = try await Self.connect(server, localInfile: .allowList([path]))
        defer { connection.closeImmediately() }

        let table = try await Self.makeTable(connection)
        try FileManager.default.removeItem(atPath: path)

        await #expect(throws: (any Error).self) {
            _ = try await connection.query(
                "LOAD DATA LOCAL INFILE '\(path)' INTO TABLE \(table)"
            )
        }

        let result = try await connection.query("SELECT 99 AS n")
        #expect(result.rows[0][0].int == 99)
    }

    /// The capability must not be advertised when the feature is off. A server
    /// that never sees `CLIENT_LOCAL_FILES` cannot ask in the first place, which
    /// is a stronger defence than refusing the request.
    @Test("does not advertise CLIENT_LOCAL_FILES when disabled", arguments: TestServers.all)
    func capabilityWithheldWhenDisabled(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server, localInfile: .disabled)
        defer { connection.closeImmediately() }
        #expect(!connection.metadata.capabilities.contains(.localFiles))
    }

    @Test("advertises CLIENT_LOCAL_FILES when enabled", arguments: TestServers.all)
    func capabilityAdvertisedWhenEnabled(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server, localInfile: .allowList(["/tmp/x"]))
        defer { connection.closeImmediately() }
        #expect(connection.metadata.capabilities.contains(.localFiles))
    }
}

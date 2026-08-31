import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import SwizzleMySQL

/// The session context recorded alongside every `QUERY_EVENT`.
///
/// A statement's text is not enough to replay it: `NOW()` depends on the time
/// zone, string comparison on the collation, and whether a zero date is legal on
/// `sql_mode`. The server writes those into each query event, and the decoder
/// used to skip the whole block.
///
/// `rust-mysql-common` parses these; this closes that gap. The time-zone entry
/// is the one that matters most for the same reason ``MySQLSessionTimeZone``
/// does — it is what says which zone a `TIMESTAMP` in the statement meant.
@Suite(
    "Query status variables",
    .serialized,
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct QueryStatusVarTests {

    /// Runs `body` and returns the query events **that connection** produced.
    ///
    /// Filtered by thread id rather than just by binlog position. The binlog is
    /// server-wide, so a position window also catches whatever other suites are
    /// writing concurrently — and with a collection limit that noise can push
    /// our own events out of the window entirely. This test was flaky exactly
    /// once in five full runs before the filter went in.
    ///
    /// A `QUERY_EVENT` records the thread that wrote it, and a connection's id
    /// *is* its thread id, so the correlation is exact.
    static func queryEvents(
        _ server: MySQLTestServer, running body: (MySQLConnection) async throws -> Void
    ) async throws -> [MySQLQueryEvent] {
        let connection = try await BinlogTests.connect(server)
        defer { connection.closeImmediately() }
        let threadID = connection.metadata.connectionID
        let start = try await connection.binlogPosition()
        try await body(connection)
        let events = try await BinlogTests.collect(server, from: start)
        return events.compactMap {
            guard case .query(let q) = $0.payload, q.threadID == threadID else { return nil }
            return q
        }
    }

    /// The session zone reaches the consumer — on the servers that record it.
    ///
    /// `Q_TIME_ZONE_CODE` is written only when the statement actually consulted
    /// the zone (MySQL sets it from `thd->time_zone_used`), so it appears on the
    /// `BEGIN` that wraps a row-based `INSERT` into a `TIMESTAMP` and *not* on a
    /// `CREATE TABLE`. Measured across all five servers, MySQL 8.4 and 9.1 emit
    /// it and the three MariaDB versions never do in row-based mode.
    ///
    /// That is a fact about the servers rather than about the decoder, and worth
    /// pinning: a CDC consumer cannot rely on the zone being present, and on
    /// MariaDB has to fall back to the zone it configured itself.
    @Test("the session time zone is recorded where the server records it",
          arguments: TestServers.mysql)
    func timeZoneIsRecorded(server: MySQLTestServer) async throws {
        let table = "qsv_\(UInt32.random(in: 0..<UInt32.max))"
        let events = try await Self.queryEvents(server) { connection in
            _ = try await connection.query("SET SESSION time_zone = \'+05:30\'")
            _ = try await connection.query("CREATE TABLE \(table) (id INT, at TIMESTAMP NULL)")
            _ = try await connection.query(
                "INSERT INTO \(table) VALUES (1, \'2024-06-15 12:00:00\')"
            )
            _ = try await connection.query("DROP TABLE IF EXISTS \(table)")
        }

        let zones = events.compactMap(\.statusVariables.timeZone)
        #expect(zones.contains("+05:30"), "expected the session zone, got \(Set(zones))")
    }

    /// Absence must be absence, not a misparse: the other variables still have
    /// to come through on a server that omits the zone.
    @Test("a server that omits the zone still yields the rest",
          arguments: TestServers.mariaDB)
    func mariaDBOmitsTheZoneButNotTheRest(server: MySQLTestServer) async throws {
        let table = "qsv_mdb_\(UInt32.random(in: 0..<UInt32.max))"
        let events = try await Self.queryEvents(server) { connection in
            _ = try await connection.query("CREATE TABLE \(table) (id INT)")
            _ = try await connection.query("DROP TABLE IF EXISTS \(table)")
        }
        let create = try #require(events.first { $0.query.contains("CREATE TABLE \(table)") })
        #expect(create.statusVariables.timeZone == nil)
        #expect(create.statusVariables.sqlMode != nil, "sql_mode must still parse")
        #expect(create.statusVariables.charset != nil, "charset must still parse")
    }

    /// Everything after an entry depends on its length being right, so a
    /// misparse would show up as garbage here rather than as a clean failure.
    @Test("the rest of the event survives the status block")
    func statementTextIsIntact() async throws {
        let table = "qsv_intact_\(UInt32.random(in: 0..<UInt32.max))"
        let events = try await Self.queryEvents(TestServers.latestMySQL) { connection in
            _ = try await connection.query("SET SESSION time_zone = '-08:00'")
            _ = try await connection.query("CREATE TABLE \(table) (id INT)")
            _ = try await connection.query("DROP TABLE IF EXISTS \(table)")
        }

        let create = try #require(
            events.first { $0.query.contains("CREATE TABLE \(table)") },
            "the statement text did not survive: \(events.map(\.query))"
        )
        #expect(create.schema == TestServers.database, "the schema name follows the status block")
        #expect(create.statusVariables.sqlMode != nil)
    }

    /// `sql_mode` and the charset triple decide how a statement behaves, so they
    /// are surfaced too.
    @Test("sql_mode and charset are recorded")
    func modeAndCharsetRecorded() async throws {
        let table = "qsv_mode_\(UInt32.random(in: 0..<UInt32.max))"
        let events = try await Self.queryEvents(TestServers.latest) { connection in
            _ = try await connection.query("CREATE TABLE \(table) (id INT)")
            _ = try await connection.query("DROP TABLE IF EXISTS \(table)")
        }
        let create = try #require(events.first { $0.query.contains("CREATE TABLE") })

        #expect(create.statusVariables.sqlMode != nil, "sql_mode should be present")
        let charset = try #require(create.statusVariables.charset, "charset should be present")
        #expect(charset.client > 0)
        #expect(charset.connection > 0)
        #expect(charset.server > 0)
    }

    /// An empty block must parse to empty rather than throwing or consuming the
    /// bytes after it.
    @Test("an empty status block is handled")
    func emptyBlock() {
        var buffer = ByteBuffer()
        let parsed = MySQLQueryStatusVariables.parse(&buffer)
        #expect(parsed == MySQLQueryStatusVariables())
    }

    /// An unknown key has no known length, so parsing stops rather than
    /// guessing — everything already read stays valid.
    @Test("an unknown key stops parsing without corrupting what came before")
    func unknownKeyStopsParsing() {
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt8(0x05))                  // TIME_ZONE
        buffer.writeInteger(UInt8(6))
        buffer.writeString("+05:30")
        buffer.writeInteger(UInt8(0x7F))                  // not a key we know
        buffer.writeBytes([0xDE, 0xAD, 0xBE, 0xEF])

        let parsed = MySQLQueryStatusVariables.parse(&buffer)
        #expect(parsed.timeZone == "+05:30", "what was read before the unknown key is kept")
    }

    /// A truncated entry must not read past the end of the block.
    @Test("a truncated entry is survivable")
    func truncatedEntry() {
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt8(0x01))                  // SQL_MODE, needs 8 bytes
        buffer.writeBytes([0x01, 0x02])                   // only 2
        let parsed = MySQLQueryStatusVariables.parse(&buffer)
        #expect(parsed.sqlMode == nil)
    }

    // MARK: - Equality

    /// `MySQLQueryStatusVariables` has a hand-written `==` over nine properties,
    /// and the sweep found five of its clauses unguarded: drop any one and two
    /// statements with genuinely different session state compare equal.
    ///
    /// It is hand-written because `autoIncrement` and `charset` are tuples, which
    /// Swift will not synthesise conformance for — so the whole chain is manual,
    /// and every clause is somewhere a property gets forgotten when one is added.
    /// The block already has six fields and MySQL keeps adding status variables.
    ///
    /// Each case below differs from the baseline in exactly one property, so a
    /// missing clause fails here and nowhere else.
    static var baseline: MySQLQueryStatusVariables {
        var value = MySQLQueryStatusVariables()
        value.timeZone = "+00:00"
        value.sqlMode = 0x1234
        value.autoIncrement = (increment: 1, offset: 2)
        value.charset = (client: 33, connection: 33, server: 45)
        value.defaultCollationForUTF8MB4 = 255
        value.updatedDatabases = ["app", "other"]
        return value
    }

    @Test("identical status variables compare equal")
    func statusVariablesEqual() {
        #expect(Self.baseline == Self.baseline)
    }

    @Test("differing in any single field makes two status blocks unequal")
    func statusVariablesInequality() {
        var zone = Self.baseline; zone.timeZone = "+05:30"
        var mode = Self.baseline; mode.sqlMode = 0x4321
        var increment = Self.baseline; increment.autoIncrement = (increment: 9, offset: 2)
        var offset = Self.baseline; offset.autoIncrement = (increment: 1, offset: 9)
        var client = Self.baseline; client.charset = (client: 99, connection: 33, server: 45)
        var connection = Self.baseline; connection.charset = (client: 33, connection: 99, server: 45)
        var server = Self.baseline; server.charset = (client: 33, connection: 33, server: 99)
        var collation = Self.baseline; collation.defaultCollationForUTF8MB4 = 1
        var databases = Self.baseline; databases.updatedDatabases = ["app"]
        var noZone = Self.baseline; noZone.timeZone = nil
        var noAutoIncrement = Self.baseline; noAutoIncrement.autoIncrement = nil
        var noCharset = Self.baseline; noCharset.charset = nil

        for (label, other) in [
            ("time zone", zone), ("sql mode", mode),
            ("auto_increment_increment", increment), ("auto_increment_offset", offset),
            ("charset client", client), ("charset connection", connection),
            ("charset server", server), ("utf8mb4 collation", collation),
            ("updated databases", databases),
            ("absent time zone", noZone), ("absent auto increment", noAutoIncrement),
            ("absent charset", noCharset),
        ] {
            #expect(other != Self.baseline, "\(label) should distinguish two blocks")
        }
    }

}

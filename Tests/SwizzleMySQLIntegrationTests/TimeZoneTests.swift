import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import SwizzleMySQL

/// `TIMESTAMP` is the one timezone-aware type MySQL has, and the tests below
/// pin down exactly what that means.
///
/// The distinction is invisible on the wire: a `TIMESTAMP` and a `DATETIME`
/// arrive in the identical format, a broken-down wall clock with no zone. Only
/// the column type byte separates them (7 vs 12). What differs is that the
/// server *converts* a `TIMESTAMP` through `@@session.time_zone` on the way in
/// and out, so the same stored row reads back differently depending on a session
/// variable — and is therefore uninterpretable unless the driver knows it.
@Suite(
    "Session time zone",
    .serialized,
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct TimeZoneTests {

    static func connect(
        _ server: MySQLTestServer, timeZone: MySQLSessionTimeZone = .server
    ) async throws -> MySQLConnection {
        var config = TestServers.configuration(for: server)
        config.timeZone = timeZone
        return try await MySQLConnection.connect(
            configuration: config, on: TestServers.group.next()
        )
    }

    static func makeTable(_ connection: MySQLConnection) async throws -> String {
        let name = "tz_\(UInt32.random(in: 0..<UInt32.max))"
        try await connection.execute(
            "CREATE TABLE \(unescaped: name) (id INT, ts TIMESTAMP NULL, dt DATETIME NULL)"
        )
        return name
    }

    /// The measurement that motivates all of this: a `TIMESTAMP` moves with the
    /// session zone and a `DATETIME` does not.
    @Test("TIMESTAMP follows the session zone, DATETIME does not", arguments: TestServers.all)
    func timestampFollowsTheSessionZone(server: MySQLTestServer) async throws {
        let utc = try await Self.connect(server, timeZone: .utc)
        defer { utc.closeImmediately() }
        let table = try await Self.makeTable(utc)
        defer { Task { try? await utc.query("DROP TABLE IF EXISTS \(table)") } }

        try await utc.execute(
            """
            INSERT INTO \(unescaped: table) VALUES
            (1, '2024-06-15 12:00:00', '2024-06-15 12:00:00')
            """
        )

        // Same row, a session five and a half hours east.
        let india = try await Self.connect(server, timeZone: .offset(hours: 5, minutes: 30))
        defer { india.closeImmediately() }

        let (utcTS, utcDT) = try #require(
            try await utc.executeFirst(
                "SELECT ts, dt FROM \(unescaped: table)", as: (String, String).self
            )
        )
        let (indiaTS, indiaDT) = try #require(
            try await india.executeFirst(
                "SELECT ts, dt FROM \(unescaped: table)", as: (String, String).self
            )
        )

        #expect(utcTS == "2024-06-15 12:00:00")
        #expect(indiaTS == "2024-06-15 17:30:00", "TIMESTAMP is converted by the session zone")
        #expect(utcDT == indiaDT, "DATETIME carries no zone and must not move")
        #expect(utcDT == "2024-06-15 12:00:00")
    }

    /// Both wire formats convert identically — the binary protocol is not a way
    /// to get the "raw" value.
    @Test("the binary protocol converts the same way")
    func binaryProtocolConvertsToo() async throws {
        let connection = try await Self.connect(
            TestServers.latest, timeZone: .offset(hours: -8)
        )
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        try await connection.query(
            "INSERT INTO \(table) VALUES (1, '2024-06-15 04:00:00', '2024-06-15 04:00:00')"
        )
        // Bound parameter forces the prepared/binary path.
        let (ts, _) = try #require(
            try await connection.executeFirst(
                "SELECT ts, dt FROM \(unescaped: table) WHERE id = \(1)",
                as: (String, String).self
            )
        )
        #expect(ts == "2024-06-15 04:00:00")
    }

    /// The column type is the only thing that says a value is zone-converted.
    @Test("only TIMESTAMP reports itself as zone-aware")
    func columnMetadataIdentifiesTimestamps() async throws {
        let connection = try await Self.connect(TestServers.latest, timeZone: .utc)
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        let result = try await connection.query("SELECT ts, dt FROM \(table)")
        let ts = try #require(result.columns.first { $0.name == "ts" })
        let dt = try #require(result.columns.first { $0.name == "dt" })
        #expect(ts.isTimeZoneAware)
        #expect(!dt.isTimeZoneAware)
    }

    /// With the zone pinned, a `TIMESTAMP` becomes an instant. This is the whole
    /// point: the same moment read through two different sessions converts to
    /// the same `Date`.
    @Test("a pinned zone makes TIMESTAMP convertible to an instant")
    func timestampConvertsToAnInstant() async throws {
        let utc = try await Self.connect(TestServers.latest, timeZone: .utc)
        defer { utc.closeImmediately() }
        let table = try await Self.makeTable(utc)
        defer { Task { try? await utc.query("DROP TABLE IF EXISTS \(table)") } }

        try await utc.execute(
            "INSERT INTO \(unescaped: table) VALUES (1, '2024-06-15 12:00:00', NULL)"
        )

        let india = try await Self.connect(
            TestServers.latest, timeZone: .offset(hours: 5, minutes: 30)
        )
        defer { india.closeImmediately() }

        func instant(_ connection: MySQLConnection) async throws -> Date {
            let value = try #require(
                try await connection.executeFirst(
                    "SELECT ts FROM \(unescaped: table)", as: MySQLDateTime.self
                )
            )
            return try #require(value.date(in: connection.sessionTimeZone))
        }

        let fromUTC = try await instant(utc)
        let fromIndia = try await instant(india)

        // 2024-06-15T12:00:00Z
        #expect(fromUTC.timeIntervalSince1970 == 1_718_452_800)
        #expect(
            abs(fromUTC.timeIntervalSince(fromIndia)) < 0.001,
            "two sessions in different zones must resolve to the same instant"
        )
    }

    /// Without a pinned zone there is nothing to convert against, and the API
    /// says so rather than guessing.
    @Test("an unpinned session cannot convert")
    func serverZoneCannotConvert() {
        let wall = MySQLDateTime(year: 2024, month: 6, day: 15, hour: 12)
        #expect(wall.date(in: .server) == nil)
        #expect(wall.date(in: .named("Europe/London")) == nil, "a name alone does not fix an offset")
        #expect(wall.date(in: .utc) != nil)
    }

    /// MySQL permits values `Date` cannot represent, and those must not silently
    /// become some nearby real date.
    @Test("the zero date does not convert")
    func zeroDateDoesNotConvert() {
        #expect(MySQLDateTime().date(in: .utc) == nil)
        #expect(MySQLDateTime(year: 2024, month: 0, day: 0).date(in: .utc) == nil)
    }

    @Test("microseconds survive the conversion")
    func microsecondsSurvive() throws {
        let wall = MySQLDateTime(
            year: 2024, month: 6, day: 15, hour: 12, minute: 0, second: 0, microsecond: 500_000
        )
        let date = try #require(wall.date(in: .utc))
        #expect(date.timeIntervalSince1970 == 1_718_452_800.5)
    }

    @Test("offsets render in MySQL's format")
    func offsetFormatting() {
        #expect(MySQLSessionTimeZone.utc.settingValue == "+00:00")
        #expect(MySQLSessionTimeZone.offset(hours: 5, minutes: 30).settingValue == "+05:30")
        #expect(MySQLSessionTimeZone.offset(hours: -8).settingValue == "-08:00")
        #expect(MySQLSessionTimeZone.offset(hours: -3, minutes: 30).settingValue == "-03:30")
        #expect(MySQLSessionTimeZone.server.settingValue == nil)
    }

    /// A zone name is the one value here that comes from the caller and reaches
    /// a SQL literal, so it is validated rather than escaped.
    @Test(arguments: ["Europe/London'; DROP TABLE x; --", "a'b", "", "x\\y"])
    func hostileZoneNamesAreRefused(name: String) {
        #expect(throws: (any Error).self) {
            try MySQLSessionTimeZone.named(name).setupStatement()
        }
    }

    @Test("the time zone can come from a URL")
    func urlParameter() throws {
        #expect(try MySQLConnectionConfiguration(url: "mysql://r@h/d?time_zone=utc").timeZone == .utc)
        #expect(
            try MySQLConnectionConfiguration(url: "mysql://r@h/d?time_zone=%2B05:30").timeZone
                == .offset(hours: 5, minutes: 30)
        )
        #expect(
            try MySQLConnectionConfiguration(url: "mysql://r@h/d?time_zone=-08:00").timeZone
                == .offset(hours: -8, minutes: 0)
        )
        #expect(
            try MySQLConnectionConfiguration(url: "mysql://r@h/d?tz=Europe/London").timeZone
                == .named("Europe/London")
        )
    }
}

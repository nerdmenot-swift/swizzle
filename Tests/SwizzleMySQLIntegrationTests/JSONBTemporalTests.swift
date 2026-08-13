import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import SwizzleMySQL

/// Temporal values *inside* a JSON document.
///
/// MySQL stores a `DATETIME` inside JSON as an opaque value: a column-type byte
/// followed by MySQL's packed 64-bit representation — not as text. Reading it
/// therefore means unpacking it by type.
///
/// The decoder used to guess instead, rendering the payload as a string when its
/// bytes happened to be printable ASCII and base64 otherwise. That is wrong in a
/// way that is hard to notice: the eight bytes of a packed datetime can be
/// entirely printable, and the result is convincing garbage inside a document
/// that still parses as valid JSON.
///
/// `rust-mysql-common` decodes these (`MysqlTime::from_int64_datetime_packed`);
/// this closes that gap.
@Suite(
    "JSONB temporals",
    .serialized,
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct JSONBTemporalTests {

    /// Round-trips a JSON document through the binlog, which is the only path
    /// that hands us MySQL's binary JSON rather than the server's own rendering.
    static func documentFromBinlog(
        _ server: MySQLTestServer, buildingWith expression: String
    ) async throws -> String {
        let connection = try await BinlogTests.connect(server)
        defer { connection.closeImmediately() }

        let table = "jsonbt_\(UInt32.random(in: 0..<UInt32.max))"
        _ = try await connection.query("SET SESSION time_zone = '+00:00'")
        _ = try await connection.query("CREATE TABLE \(table) (id INT PRIMARY KEY, doc JSON)")
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        let start = try await connection.binlogPosition()
        _ = try await connection.query("INSERT INTO \(table) VALUES (1, \(expression))")

        let events = try await BinlogTests.collect(server, from: start)
        for event in events {
            guard case .rows(let rows) = event.payload, rows.table.table == table,
                  let first = rows.rows.first, first.count > 1,
                  let text = first[1].string
            else { continue }
            return text
        }
        Issue.record("no row event carrying the document")
        return ""
    }

    @Test("a DATETIME inside JSON decodes, rather than being guessed at")
    func datetimeInsideJSON() async throws {
        let document = try await Self.documentFromBinlog(
            TestServers.latestMySQL,
            buildingWith: "JSON_OBJECT('at', CAST('2024-06-15 12:34:56' AS DATETIME))"
        )
        #expect(document.contains("2024-06-15 12:34:56"), "got \(document)")
        #expect(!document.contains("base64"), "a datetime should not fall back to base64")
    }

    @Test("a DATE inside JSON decodes without a spurious clock")
    func dateInsideJSON() async throws {
        let document = try await Self.documentFromBinlog(
            TestServers.latestMySQL,
            buildingWith: "JSON_OBJECT('on', CAST('2024-06-15' AS DATE))"
        )
        #expect(document.contains("2024-06-15"), "got \(document)")
        #expect(!document.contains("00:00:00"), "a DATE has no time part: \(document)")
    }

    /// `TIME` is a duration, so it is signed and its hours run past 24 — a
    /// different packed layout from `DATETIME`.
    @Test("a TIME inside JSON decodes as a duration")
    func timeInsideJSON() async throws {
        let document = try await Self.documentFromBinlog(
            TestServers.latestMySQL,
            buildingWith: "JSON_OBJECT('took', CAST('26:03:04' AS TIME))"
        )
        #expect(document.contains("26:03:04"), "hours past 24 must survive: \(document)")
    }

    @Test("fractional seconds survive")
    func fractionalSeconds() async throws {
        let document = try await Self.documentFromBinlog(
            TestServers.latestMySQL,
            buildingWith: "JSON_OBJECT('at', CAST('2024-06-15 12:34:56.500000' AS DATETIME(6)))"
        )
        #expect(document.contains("12:34:56.500000"), "got \(document)")
    }

    /// Types we do not unpack must stay base64 rather than being rendered as
    /// whatever their bytes resemble.
    @Test("a DECIMAL inside JSON stays base64 rather than being guessed")
    func decimalStaysEncoded() async throws {
        let document = try await Self.documentFromBinlog(
            TestServers.latestMySQL,
            buildingWith: "JSON_OBJECT('amount', CAST('123.45' AS DECIMAL(10,2)))"
        )
        // MySQL's own convention for an undecoded opaque value.
        #expect(
            document.contains("base64:type") || document.contains("123.45"),
            "a decimal must be either decoded or explicitly marked: \(document)"
        )
    }

    /// Ordinary strings and numbers must be untouched by any of this.
    @Test("plain values are unaffected")
    func plainValuesUnaffected() async throws {
        let document = try await Self.documentFromBinlog(
            TestServers.latestMySQL,
            buildingWith: "JSON_OBJECT('name', 'ada', 'n', 42, 'ok', TRUE)"
        )
        #expect(document.contains("\"ada\""))
        #expect(document.contains("42"))
        #expect(document.contains("true"))
    }
}

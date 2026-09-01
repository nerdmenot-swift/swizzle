import Foundation
import Testing
@testable import SwizzleMySQL

/// What the server makes of the bytes this driver sends for a **parameter**.
///
/// ## The direction the result oracle does not cover
///
/// `MySQLProtocolOracleTests` compares the two ways a *result* is decoded. That
/// leaves the other direction entirely ungrounded: nothing checks that the bytes
/// `COM_STMT_EXECUTE` writes for a bound value mean to the server what the
/// driver intended. A unit test cannot close this, because the only thing it can
/// compare the encoder against is this driver's own decoder — and the two
/// agreeing proves only that they share an assumption.
///
/// Temporal parameters are where that matters. Their width is variable and
/// derived from the value's contents: a DATETIME whose time is midnight is sent
/// as a **four-byte body with no time fields at all**, and a TIME carries a sign
/// byte and a day count that DATETIME has no equivalent of. Those are decisions
/// the driver makes unilaterally, and the server is the only authority on
/// whether they were right.
///
/// ## The differential
///
/// Each value is inserted twice into the same column: once **bound as a
/// parameter**, once as a **SQL literal** in the statement text. The literal path
/// never touches the parameter encoder — the server parses it from the query
/// string — so the two rows agreeing means the encoder produced bytes the server
/// read as the value intended.
///
/// Reading back uses `COM_QUERY`, so the comparison is between two stored rows
/// rather than between two of this driver's decoders. Nothing here can pass by
/// comparing the code against itself.
@Suite(
    "MySQL parameter oracle",
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct MySQLParameterOracleTests {

    /// A column, a value bound as a parameter, and the literal that means the
    /// same thing.
    struct Subject: Sendable, CustomStringConvertible {
        let column: String
        let value: MySQLValue
        let literal: String
        /// Why this shape is here — which encoder branch it reaches.
        let reaches: String
        var description: String { "\(column) \(literal)" }
    }

    static func dateTime(
        _ year: UInt16, _ month: UInt8, _ day: UInt8,
        _ hour: UInt8 = 0, _ minute: UInt8 = 0, _ second: UInt8 = 0, _ micro: UInt32 = 0
    ) -> MySQLValue {
        .dateTime(.init(year: year, month: month, day: day, hour: hour,
                        minute: minute, second: second, microsecond: micro))
    }

    static let subjects: [Subject] = [
        // DATETIME's four widths. The date-only one is the branch worth the
        // whole suite: the driver decides on its own to omit the time fields.
        .init(column: "DATETIME(6)", value: dateTime(2024, 3, 5),
              literal: "'2024-03-05 00:00:00'", reaches: "the 4-byte date-only body"),
        .init(column: "DATETIME(6)", value: dateTime(2024, 3, 5, 14, 30, 7),
              literal: "'2024-03-05 14:30:07'", reaches: "the 7-byte body"),
        .init(column: "DATETIME(6)", value: dateTime(2024, 3, 5, 14, 30, 7, 123_456),
              literal: "'2024-03-05 14:30:07.123456'", reaches: "the 11-byte body"),
        // Microseconds with a midnight time still needs the 11-byte body, which
        // is the one case where "no time" and "has micros" both apply.
        .init(column: "DATETIME(6)", value: dateTime(2024, 3, 5, 0, 0, 0, 500_000),
              literal: "'2024-03-05 00:00:00.500000'",
              reaches: "the 11-byte body with a zero time"),
        .init(column: "DATETIME(6)", value: dateTime(1000, 1, 1),
              literal: "'1000-01-01 00:00:00'", reaches: "MySQL's minimum DATETIME"),
        .init(column: "DATETIME(6)", value: dateTime(9999, 12, 31, 23, 59, 59, 999_999),
              literal: "'9999-12-31 23:59:59.999999'", reaches: "its maximum"),

        // DATE, where the server truncates the body it is given.
        .init(column: "DATE", value: dateTime(2024, 2, 29),
              literal: "'2024-02-29'", reaches: "a leap day through the 4-byte body"),

        // TIMESTAMP, which is stored in UTC and read back in the session zone —
        // both paths take the same conversion, so they still have to agree.
        .init(column: "TIMESTAMP(6) NULL", value: dateTime(2024, 3, 5, 14, 30, 7, 123_456),
              literal: "'2024-03-05 14:30:07.123456'", reaches: "TIMESTAMP's conversion"),

        // TIME's three widths, and the sign and day count DATETIME lacks.
        .init(column: "TIME(6)", value: .time(.init(hours: 12, minutes: 34, seconds: 56)),
              literal: "'12:34:56'", reaches: "the 8-byte body"),
        .init(column: "TIME(6)",
              value: .time(.init(hours: 12, minutes: 34, seconds: 56, microseconds: 500_000)),
              literal: "'12:34:56.500000'", reaches: "the 12-byte body"),
        .init(column: "TIME(6)", value: .time(.init(isNegative: true, hours: 12, minutes: 34,
                                                    seconds: 56)),
              literal: "'-12:34:56'", reaches: "the sign byte"),
        // Beyond a day in both directions, which is where the days/hours split
        // is the only thing that can carry the value — 838:59:59 is the limit,
        // and it is 34 days plus 22 hours.
        .init(column: "TIME(6)",
              value: .time(.init(days: 34, hours: 22, minutes: 59, seconds: 59)),
              literal: "'838:59:59'", reaches: "the day count at its maximum"),
        .init(column: "TIME(6)",
              value: .time(.init(isNegative: true, days: 34, hours: 22, minutes: 59,
                                 seconds: 59)),
              literal: "'-838:59:59'", reaches: "the day count and the sign together"),
        .init(column: "TIME(6)", value: .time(.init(days: 1)),
              literal: "'24:00:00'", reaches: "a day with no hour remainder"),
        .init(column: "TIME(6)", value: .time(.init()),
              literal: "'00:00:00'", reaches: "the zero-length body"),
        .init(column: "TIME(6)", value: .time(.init(isNegative: true)),
              literal: "'00:00:00'", reaches: "negative zero, which has no sign to carry"),
        .init(column: "TIME(6)", value: .time(.init(microseconds: 1)),
              literal: "'00:00:00.000001'", reaches: "microseconds with nothing else set"),

        // The integer boundaries, where the UNSIGNED flag on the parameter is
        // the only thing keeping a large value from arriving negative.
        .init(column: "BIGINT", value: .int(.min), literal: "-9223372036854775808",
              reaches: "the signed minimum"),
        .init(column: "BIGINT", value: .int(.max), literal: "9223372036854775807",
              reaches: "the signed maximum"),
        .init(column: "BIGINT UNSIGNED", value: .uint(.max),
              literal: "18446744073709551615", reaches: "the UNSIGNED parameter flag"),
        .init(column: "BIGINT UNSIGNED", value: .uint(UInt64(Int64.max) + 1),
              literal: "9223372036854775808", reaches: "one past where signed stops"),

        // Floating point, which binds by bit pattern.
        .init(column: "DOUBLE", value: .double(1.5), literal: "1.5", reaches: "a double"),
        .init(column: "DOUBLE", value: .double(-1e300), literal: "-1e300",
              reaches: "a double at magnitude"),
        .init(column: "FLOAT", value: .float(1.5), literal: "1.5", reaches: "a float"),

        // Bytes, including the ones that would break if anything escaped them.
        .init(column: "VARCHAR(64)", value: .bytes(Array("a'b\\c".utf8)),
              literal: "'a\\'b\\\\c'", reaches: "characters a literal has to escape"),
        .init(column: "VARBINARY(64)", value: .bytes([0x00, 0xFF, 0x00]),
              literal: "0x00FF00", reaches: "a NUL inside a binary value"),
        .init(column: "VARCHAR(64)", value: .bytes([]), literal: "''",
              reaches: "an empty length-encoded string"),
        .init(column: "VARCHAR(64)", value: .bytes(Array("ünïcødé".utf8)),
              literal: "'ünïcødé'", reaches: "multi-byte UTF-8"),
    ]

    /// Inserts the value both ways and compares the stored rows.
    static func compare(
        _ connection: MySQLConnection, table: String, subject: Subject,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        _ = try await connection.query("DELETE FROM \(table)")
        // Bound as a parameter: through the encoder under test.
        _ = try await connection.query("INSERT INTO \(table) (v) VALUES (?)", [subject.value])
        let bound = try await connection.query("SELECT v FROM \(table)").rows.first?[0]

        _ = try await connection.query("DELETE FROM \(table)")
        // As a literal: parsed by the server from the statement text, so it
        // never reaches the parameter encoder at all.
        _ = try await connection.query("INSERT INTO \(table) (v) VALUES (\(subject.literal))")
        let literal = try await connection.query("SELECT v FROM \(table)").rows.first?[0]

        #expect(
            bound == literal,
            """
            \(subject.column) \(subject.literal) — \(subject.reaches): \
            bound parameter stored \(bound as Any), the literal stored \(literal as Any)
            """,
            sourceLocation: sourceLocation
        )
    }

    // MARK: - The oracle

    @Test("a bound parameter stores what the equivalent literal stores",
          arguments: TestServers.all, subjects)
    func boundMatchesLiteral(server: MySQLTestServer, subject: Subject) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "param_\(UInt32.random(in: 0..<UInt32.max))"
        do {
            _ = try await connection.query("CREATE TABLE \(table) (v \(subject.column))")
        } catch {
            // A type this server does not have is a fact about the server.
            return
        }
        // Dropped awaited, not in a detached Task: the fixtures had accumulated
        // thousands of tables from that pattern.
        do {
            try await Self.compare(connection, table: table, subject: subject)
        } catch {
            _ = try? await connection.query("DROP TABLE IF EXISTS \(table)")
            throw error
        }
        _ = try? await connection.query("DROP TABLE IF EXISTS \(table)")
    }

    static func connect(_ server: MySQLTestServer) async throws -> MySQLConnection {
        try await TestServers.connect(server)
    }

    // MARK: - Round trip through the server

    /// The same values read back **as parameters were sent**, so the encoder and
    /// the binary decoder meet across a real server rather than in a unit test.
    ///
    /// This is weaker than the differential above — both halves are this
    /// driver's code — but it catches the case where the server accepts and
    /// stores the value correctly and the driver then cannot read its own
    /// round trip.
    @Test("every temporal parameter survives a round trip through the server",
          arguments: TestServers.all)
    func temporalRoundTrip(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "roundtrip_\(UInt32.random(in: 0..<UInt32.max))"
        _ = try await connection.query(
            "CREATE TABLE \(table) (d DATETIME(6) NULL, t TIME(6) NULL)"
        )
        for subject in Self.subjects {
            let column: String
            switch subject.value {
            case .dateTime where subject.column.hasPrefix("DATETIME"): column = "d"
            case .time: column = "t"
            default: continue
            }
            _ = try await connection.query("DELETE FROM \(table)")
            _ = try await connection.query(
                "INSERT INTO \(table) (\(column)) VALUES (?)", [subject.value]
            )
            let text = try await connection.query("SELECT \(column) FROM \(table)")
            let binary = try await connection.query("SELECT \(column) FROM \(table)", [])
            #expect(
                text.rows.first?[0] == binary.rows.first?[0],
                Comment(rawValue: "\(subject): text \(text.rows.first?[0] as Any), "
                    + "binary \(binary.rows.first?[0] as Any)")
            )
        }
        _ = try? await connection.query("DROP TABLE IF EXISTS \(table)")
    }
}

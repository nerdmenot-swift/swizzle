import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing
@testable import SwizzleMySQL

/// Every column type, round-tripped through the binlog.
///
/// This suite exists because the narrow happy-path tests missed a real bug.
/// `YEAR` is a `SMALLINT` in a result set but a **single byte** in a row image;
/// decoding it as two consumed a byte belonging to the next column and
/// misaligned the rest of the row. It only surfaced when the full suite ran and
/// the binlog stream happened to encounter a table another suite had created.
///
/// A row image is a positional format with no delimiters, so a width error in
/// one column silently corrupts every column after it. Sweeping the whole type
/// matrix is the only way to be sure of the widths, and the assertion has to be
/// on the decoded *value* — a wrong width still "succeeds" when the bad column
/// happens to be last.
@Suite(
    "Binlog column types",
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct BinlogColumnTypeTests {

    struct Case: Sendable, CustomStringConvertible {
        let sqlType: String
        let literal: String
        /// Checked against the value decoded out of the row image.
        let check: @Sendable (MySQLValue) -> Bool
        var description: String { sqlType }
    }

    static let cases: [Case] = [
        Case(sqlType: "TINYINT", literal: "-42", check: { $0.int == -42 }),
        Case(sqlType: "SMALLINT", literal: "-32768", check: { $0.int == -32_768 }),
        Case(sqlType: "MEDIUMINT", literal: "8388607", check: { $0.int == 8_388_607 }),
        Case(sqlType: "INT", literal: "2147483647", check: { $0.int == 2_147_483_647 }),
        Case(sqlType: "BIGINT", literal: "9223372036854775807",
             check: { $0.int == 9_223_372_036_854_775_807 }),
        Case(sqlType: "DECIMAL(10,2)", literal: "123.45", check: { $0.string == "123.45" }),
        Case(sqlType: "DECIMAL(10,2)", literal: "-987.65", check: { $0.string == "-987.65" }),
        Case(sqlType: "DECIMAL(20,6)", literal: "12345678901234.567890",
             check: { $0.string == "12345678901234.567890" }),
        Case(sqlType: "FLOAT", literal: "1.5", check: { $0.double == 1.5 }),
        Case(sqlType: "DOUBLE", literal: "2.25", check: { $0.double == 2.25 }),
        Case(sqlType: "DATE", literal: "'2024-01-15'", check: {
            guard case .dateTime(let d) = $0 else { return false }
            return d.year == 2024 && d.month == 1 && d.day == 15
        }),
        Case(sqlType: "DATETIME", literal: "'2024-01-15 10:30:45'", check: {
            guard case .dateTime(let d) = $0 else { return false }
            return d.year == 2024 && d.hour == 10 && d.minute == 30 && d.second == 45
        }),
        Case(sqlType: "TIME", literal: "'10:30:45'", check: {
            guard case .time(let t) = $0 else { return false }
            return t.hours == 10 && t.minutes == 30 && t.seconds == 45
        }),
        // The one that was wrong: a single byte holding an offset from 1900.
        Case(sqlType: "YEAR", literal: "2024", check: { $0.int == 2024 }),
        Case(sqlType: "CHAR(10)", literal: "'abc'", check: { $0.string == "abc" }),
        Case(sqlType: "VARCHAR(50)", literal: "'abc'", check: { $0.string == "abc" }),
        // Over 255 bytes the length prefix widens from one byte to two.
        Case(sqlType: "VARCHAR(500)", literal: "'\(String(repeating: "x", count: 300))'",
             check: { $0.string?.count == 300 }),
        Case(sqlType: "TEXT", literal: "'hello'", check: { $0.string == "hello" }),
        Case(sqlType: "BLOB", literal: "'hello'", check: { $0.string == "hello" }),
        Case(sqlType: "LONGBLOB", literal: "'hello'", check: { $0.string == "hello" }),
        // ENUM decodes to its 1-based index, SET to its bitmask.
        Case(sqlType: "ENUM('a','b','c')", literal: "'b'", check: { $0.int == 2 }),
        Case(sqlType: "SET('x','y','z')", literal: "'x,z'", check: {
            guard case .uint(let mask) = $0 else { return false }
            return mask == 5          // bits for 'x' and 'z'
        }),
        // BIT is metadata-driven, and the metadata is two bytes: `bits % 8`
        // first, then `bits / 8`. BIT(8) alone cannot tell a correct reading of
        // those from a transposed one — for it, both give one byte — so the
        // widths that *do* distinguish them are the point of these cases.
        //
        // A wrong byte count here is not a wrong value: it consumes the wrong
        // number of bytes and every later column in the row decodes from the
        // wrong offset, which the sentinel column catches.
        Case(sqlType: "BIT(1)", literal: "b'1'", check: {
            guard case .uint(let bits) = $0 else { return false }
            return bits == 1
        }),
        Case(sqlType: "BIT(8)", literal: "b'10101010'", check: {
            guard case .uint(let bits) = $0 else { return false }
            return bits == 170
        }),
        // 12 bits: one whole byte plus four. `bits/8 * 8 + bits%8` reads two
        // bytes; transposing it reads five.
        Case(sqlType: "BIT(12)", literal: "b'101010101010'", check: {
            guard case .uint(let bits) = $0 else { return false }
            return bits == 0b1010_1010_1010
        }),
        Case(sqlType: "BIT(20)", literal: "b'10101010101010101010'", check: {
            guard case .uint(let bits) = $0 else { return false }
            return bits == 0b1010_1010_1010_1010_1010
        }),
        // The widest BIT there is, and a whole number of bytes again.
        Case(sqlType: "BIT(64)", literal: "b'\(String(repeating: "10", count: 32))'", check: {
            guard case .uint(let bits) = $0 else { return false }
            return bits == 0xAAAA_AAAA_AAAA_AAAA
        }),
        Case(sqlType: "JSON", literal: "'{\"k\": 1}'", check: { ($0.string?.contains("k")) == true }),
    ]

    /// Serialised, and deliberately so: each case opens a replica connection,
    /// and running two dozen of them in parallel alongside the rest of the suite
    /// exhausted the server's `max_connections`. The types are checked in one
    /// pass per test rather than one test per type.
    ///
    /// A trailing sentinel column guards against a width error in the column
    /// under test. Without it, over-reading the last column would go unnoticed;
    /// with it, the sentinel decodes wrong and the test fails.
    static func connect() async throws -> MySQLConnection {
        let server = TestServers.latest
        let user = server.primaryUser
        return try await MySQLConnection.connect(
            configuration: .init(
                address: .hostname(TestServers.host, port: server.port),
                username: user.name, password: user.password,
                database: TestServers.database, tls: .disable
            ),
            on: TestServers.group.next()
        )
    }

    /// Runs the whole matrix in a single pass over one binlog stream.
    ///
    /// Serialised deliberately: a connection per case, run in parallel with the
    /// rest of the suite, exhausted the server's `max_connections` — which
    /// surfaced as unrelated suites failing to connect. Two connections total.
    ///
    /// A trailing sentinel column guards against a width error in the column
    /// under test. Without it, over-reading the *last* column would go
    /// unnoticed; with it, the sentinel decodes wrong and the test fails. That
    /// is exactly how `YEAR` hid.
    @Test("every column type round-trips through a row image")
    func allTypesRoundTrip() async throws {
        let connection = try await Self.connect()
        defer { connection.closeImmediately() }

        var tables: [(table: String, testCase: Case)] = []
        for (index, testCase) in Self.cases.enumerated() {
            let table = "bintype_\(UInt32.random(in: 0..<UInt32.max))_\(index)"
            _ = try await connection.query(
                "CREATE TABLE \(table) (id INT PRIMARY KEY, v \(testCase.sqlType), sentinel INT)"
            )
            tables.append((table, testCase))
        }
        defer {
            let names = tables.map(\.table)
            Task {
                for name in names { try? await connection.query("DROP TABLE IF EXISTS \(name)") }
            }
        }

        let start = try await connection.binlogPosition()
        for (table, testCase) in tables {
            // Both a concrete value and NULL: NULL takes a different path, being
            // absent from the image entirely with only the bitmap recording it.
            _ = try await connection.query(
                "INSERT INTO \(table) VALUES (1, \(testCase.literal), 987654)"
            )
            _ = try await connection.query("INSERT INTO \(table) VALUES (2, NULL, 987654)")
        }

        let replica = try await Self.connect()
        defer { replica.closeImmediately() }
        let stream = try await replica.startBinlogStream(
            serverID: UInt32(BinlogTests.serverIDs.next()),
            from: .file(name: start.filename, position: start.position),
            flags: .nonBlocking
        )

        var byTable: [String: [[MySQLValue]]] = [:]
        for try await event in stream {
            guard case .rows(let rows) = event.payload, rows.kind == .write else { continue }
            byTable[rows.table.table, default: []] += rows.rows
        }

        for (table, testCase) in tables {
            let rows = try #require(byTable[table], "no row events for \(testCase.sqlType)")
            #expect(rows.count == 2, "\(testCase.sqlType): expected 2 rows, got \(rows.count)")
            guard rows.count == 2 else { continue }

            let valued = rows[0]
            let nulled = rows[1]

            #expect(valued.count == 3, "\(testCase.sqlType): wrong column count")
            #expect(testCase.check(valued[1]), "\(testCase.sqlType) decoded as \(valued[1])")
            #expect(
                valued[2].int == 987_654,
                "sentinel corrupted — \(testCase.sqlType) consumed the wrong number of bytes"
            )

            #expect(nulled[1].isNull, "\(testCase.sqlType): NULL did not decode as null")
            #expect(
                nulled[2].int == 987_654,
                "sentinel corrupted on the NULL path for \(testCase.sqlType)"
            )
        }
    }

    /// `VECTOR`, which only MySQL 9 has — hence its own test rather than a row
    /// in the matrix above, which runs against MariaDB.
    ///
    /// It is metadata-carrying: one byte giving the width of the length prefix,
    /// exactly like a blob. We read **no** metadata byte for it, so the metadata
    /// of every column after a VECTOR started one byte early — and the value
    /// itself hit the decoder's `default:` and failed the stream outright. Two
    /// sentinels here, before and after, because the misalignment showed up in
    /// the *following* column rather than in the vector.
    @Test("a MySQL 9 VECTOR column round-trips through a row image")
    func vectorRoundTrips() async throws {
        let server = TestServers.mysql91
        let user = server.primaryUser
        func open() async throws -> MySQLConnection {
            try await MySQLConnection.connect(
                configuration: .init(
                    address: .hostname(TestServers.host, port: server.port),
                    username: user.name, password: user.password,
                    database: TestServers.database, tls: .disable,
                    serverPublicKey: .requestFromServer
                ),
                on: TestServers.group.next()
            )
        }

        let connection = try await open()
        defer { connection.closeImmediately() }

        let table = "binvec_\(UInt32.random(in: 0..<UInt32.max))"
        _ = try await connection.query(
            "CREATE TABLE \(table) (id INT PRIMARY KEY, v VECTOR(4), sentinel INT)"
        )
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        let start = try await connection.binlogPosition()
        _ = try await connection.query(
            "INSERT INTO \(table) VALUES (1, TO_VECTOR('[1,2,3,4]'), 987654)"
        )
        _ = try await connection.query("INSERT INTO \(table) VALUES (2, NULL, 987654)")

        let replica = try await open()
        defer { replica.closeImmediately() }
        let stream = try await replica.startBinlogStream(
            serverID: UInt32(BinlogTests.serverIDs.next()),
            from: .file(name: start.filename, position: start.position),
            flags: .nonBlocking
        )

        var rows: [[MySQLValue]] = []
        for try await event in stream {
            guard case .rows(let event) = event.payload, event.kind == .write,
                event.table.table == table
            else { continue }
            rows += event.rows
        }

        #expect(rows.count == 2)
        guard rows.count == 2 else { return }

        // Four float32s, little-endian — MySQL's on-disk vector format.
        guard case .bytes(let payload) = rows[0][1] else {
            Issue.record("VECTOR decoded as \(rows[0][1]), expected bytes"); return
        }
        #expect(payload.count == 16, "four float32s")
        let components = stride(from: 0, to: payload.count, by: 4).map { offset in
            Float(
                bitPattern: payload[offset..<(offset + 4)].reversed()
                    .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            )
        }
        #expect(components == [1, 2, 3, 4])

        #expect(
            rows[0][2].int == 987_654,
            "sentinel corrupted — VECTOR consumed the wrong number of bytes"
        )
        #expect(rows[1][1].isNull)
        #expect(rows[1][2].int == 987_654, "sentinel corrupted on the NULL path")
    }
}

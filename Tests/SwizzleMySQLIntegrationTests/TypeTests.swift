import NIOCore
import Testing
@testable import SwizzleMySQL

/// Type decoding against real servers, over the text protocol.
///
/// The binary protocol path is unit-tested but cannot be exercised end to end
/// until prepared statements land in Phase 4.
@Suite(
    "Types",
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct TypeTests {

    static func connect(_ server: MySQLTestServer) async throws -> MySQLConnection {
        let user = server.primaryUser
        return try await MySQLConnection.connect(
            configuration: MySQLConnectionConfiguration(
                address: .hostname(TestServers.host, port: server.port),
                username: user.name,
                password: user.password,
                database: TestServers.database,
                tls: .disable,
                serverPublicKey: .requestFromServer
            ),
            on: TestServers.group.next()
        )
    }

    @Test("integer widths and signedness decode correctly", arguments: TestServers.all)
    func integers(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "types_int_\(server.name)"
        try await connection.query("DROP TABLE IF EXISTS \(table)")
        try await connection.query(
            """
            CREATE TABLE \(table) (
              t TINYINT, ut TINYINT UNSIGNED,
              s SMALLINT, m MEDIUMINT, i INT,
              b BIGINT, ub BIGINT UNSIGNED
            )
            """
        )
        try await connection.query(
            "INSERT INTO \(table) VALUES (-128, 255, -32768, -8388608, -2147483648, "
            + "-9223372036854775808, 18446744073709551615)"
        )

        let result = try await connection.query("SELECT * FROM \(table)")
        #expect(result.value("t") == .int(-128))
        #expect(result.value("ut") == .uint(255))
        #expect(result.value("s") == .int(-32768))
        #expect(result.value("m") == .int(-8_388_608))
        #expect(result.value("i") == .int(-2_147_483_648))
        #expect(result.value("b") == .int(-9_223_372_036_854_775_808))
        // Only the UNSIGNED flag makes this decodable at all — it exceeds Int64.
        #expect(result.value("ub") == .uint(18_446_744_073_709_551_615))

        try await connection.query("DROP TABLE \(table)")
    }

    /// The reason DECIMAL is kept textual: a Double cannot hold this.
    @Test("DECIMAL keeps full precision", arguments: TestServers.all)
    func decimalPrecision(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "types_dec_\(server.name)"
        try await connection.query("DROP TABLE IF EXISTS \(table)")
        try await connection.query("CREATE TABLE \(table) (d DECIMAL(30,10))")
        try await connection.query("INSERT INTO \(table) VALUES ('12345678901234567890.1234567890')")

        let result = try await connection.query("SELECT d FROM \(table)")
        let value = result.value("d")
        #expect(value?.string == "12345678901234567890.1234567890")

        guard case .bytes = value else {
            Issue.record("DECIMAL must decode as bytes, never a Double")
            return
        }
        // Confirms the loss that would occur if it went through Double.
        #expect(Double("12345678901234567890.1234567890").map { String($0) }
            != "12345678901234567890.1234567890")

        try await connection.query("DROP TABLE \(table)")
    }

    @Test("temporal types decode", arguments: TestServers.all)
    func temporals(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "types_time_\(server.name)"
        try await connection.query("DROP TABLE IF EXISTS \(table)")
        try await connection.query(
            "CREATE TABLE \(table) (d DATE, dt DATETIME, ts TIMESTAMP NULL, "
            + "t TIME, tf DATETIME(6), y YEAR)"
        )
        try await connection.query(
            "INSERT INTO \(table) VALUES ('2024-01-15', '2024-01-15 13:45:30', "
            + "'2024-01-15 13:45:30', '-838:59:59', '2024-01-15 13:45:30.123456', 2024)"
        )

        let result = try await connection.query("SELECT * FROM \(table)")

        guard case .dateTime(let date)? = result.value("d") else {
            Issue.record("expected DATE"); return
        }
        #expect(date.year == 2024 && date.month == 1 && date.day == 15)

        guard case .dateTime(let dateTime)? = result.value("dt") else {
            Issue.record("expected DATETIME"); return
        }
        #expect(dateTime.hour == 13 && dateTime.minute == 45 && dateTime.second == 30)

        // TIME is a signed duration and can exceed 24 hours.
        guard case .time(let time)? = result.value("t") else {
            Issue.record("expected TIME"); return
        }
        #expect(time.isNegative)
        #expect(time.totalHours == 838)

        guard case .dateTime(let fractional)? = result.value("tf") else {
            Issue.record("expected DATETIME(6)"); return
        }
        #expect(fractional.microsecond == 123_456)

        // YEAR carries the UNSIGNED flag on every server we test, so it decodes
        // as `.uint` — the flag, not the column type, decides signedness.
        #expect(result.value("y") == .uint(2024))
        #expect(result.columns.first { $0.name == "y" }?.isUnsigned == true)

        try await connection.query("DROP TABLE \(table)")
    }

    /// MySQL permits `0000-00-00`, which `Foundation.Date` cannot represent —
    /// the reason `MySQLDateTime` exists.
    @Test("the zero date survives a round trip", arguments: TestServers.all)
    func zeroDate(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "types_zero_\(server.name)"
        try await connection.query("DROP TABLE IF EXISTS \(table)")
        try await connection.query("SET SESSION sql_mode = ''")
        try await connection.query("CREATE TABLE \(table) (d DATE)")
        try await connection.query("INSERT INTO \(table) VALUES ('0000-00-00')")

        let result = try await connection.query("SELECT d FROM \(table)")
        guard case .dateTime(let value)? = result.value("d") else {
            Issue.record("expected a DATE"); return
        }
        #expect(value.isZero)

        try await connection.query("DROP TABLE \(table)")
    }

    @Test("text, blob and JSON are distinguished", arguments: TestServers.all)
    func textAndBinary(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "types_blob_\(server.name)"
        try await connection.query("DROP TABLE IF EXISTS \(table)")
        try await connection.query(
            "CREATE TABLE \(table) (t TEXT, b BLOB, j JSON, e ENUM('a','b'), s SET('x','y'))"
        )
        try await connection.query(
            "INSERT INTO \(table) VALUES ('hello', 'bytes', '{\"k\": 1}', 'b', 'x,y')"
        )

        let result = try await connection.query("SELECT * FROM \(table)")
        #expect(result.value("t")?.string == "hello")
        #expect(result.value("b")?.string == "bytes")
        #expect(result.value("j")?.string?.contains("\"k\"") == true)
        #expect(result.value("e")?.string == "b")
        #expect(result.value("s")?.string == "x,y")

        // A BLOB is told from a TEXT only by the binary charset — they share a
        // column type.
        let blobColumn = result.columns.first { $0.name == "b" }
        let textColumn = result.columns.first { $0.name == "t" }
        #expect(blobColumn?.isBinary == true)
        #expect(textColumn?.isBinary == false)

        try await connection.query("DROP TABLE \(table)")
    }

    @Test("floats and doubles decode", arguments: TestServers.all)
    func floatingPoint(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let result = try await connection.query(
            "SELECT CAST(1.5 AS DOUBLE) AS d, 2.25E0 AS e"
        )
        #expect(result.value("d")?.double == 1.5)
        #expect(result.value("e")?.double == 2.25)
    }

    @Test("NULL decodes as null for every type", arguments: TestServers.all)
    func nullsAcrossTypes(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let result = try await connection.query(
            "SELECT CAST(NULL AS SIGNED) AS i, CAST(NULL AS CHAR) AS c, "
            + "CAST(NULL AS DATE) AS d, CAST(NULL AS DECIMAL) AS n"
        )
        for name in ["i", "c", "d", "n"] {
            #expect(result.value(name)?.isNull == true, "column \(name) should be null")
        }
    }
}

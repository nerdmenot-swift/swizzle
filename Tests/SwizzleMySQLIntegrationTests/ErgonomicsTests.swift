import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import SwizzleMySQL

/// The high-level API, end to end.
///
/// The unit tests prove the SQL and binds are shaped correctly; these prove the
/// server agrees — that a bound value round-trips as the same value, that an
/// injection payload is stored as text rather than executed, and that the typed
/// decode matches what the column actually holds.
@Suite(
    "Ergonomics",
    .serialized,
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct ErgonomicsTests {

    static func connect(_ server: MySQLTestServer) async throws -> MySQLConnection {
        try await TestServers.connect(server)
    }

    static func makeTable(_ connection: MySQLConnection) async throws -> String {
        let name = "ergo_\(UInt32.random(in: 0..<UInt32.max))"
        try await connection.execute(
            """
            CREATE TABLE \(unescaped: name) (
                id INT PRIMARY KEY, name VARCHAR(64), score DOUBLE,
                nickname VARCHAR(64) NULL, active TINYINT(1)
            )
            """
        )
        for (id, name_, score, nickname, active) in [
            (1, "ada", 9.5, "countess", true),
            (2, "grace", 9.9, nil, true),
            (3, "alan", 9.7, "prof", false),
        ] as [(Int, String, Double, String?, Bool)] {
            try await connection.execute(
                """
                INSERT INTO \(unescaped: name) (id, name, score, nickname, active)
                VALUES (\(id), \(name_), \(score), \(nickname), \(active))
                """
            )
        }
        return name
    }

    /// The headline: write the query as one string, get typed tuples back.
    @Test("an interpolated query round-trips into typed tuples")
    func typedRoundTrip() async throws {
        let connection = try await Self.connect(TestServers.latest)
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        let minimum = 9.6
        let people = try await connection.execute(
            """
            SELECT id, name, score, nickname FROM \(unescaped: table)
            WHERE score > \(minimum) ORDER BY id
            """,
            as: (Int, String, Double, String?).self
        )

        #expect(people.count == 2)
        #expect(people[0].0 == 2)
        #expect(people[0].1 == "grace")
        #expect(people[0].3 == nil, "a NULL column decodes to nil")
        #expect(people[1].1 == "alan")
        #expect(people[1].3 == "prof")
    }

    /// The claim that makes the design worth having: a value containing SQL is
    /// stored as text. If interpolation built a string, the table would be gone.
    @Test("an injection payload is stored as data")
    func injectionIsStoredNotExecuted() async throws {
        let connection = try await Self.connect(TestServers.latest)
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        let hostile = "'); DROP TABLE \(table); --"
        try await connection.execute(
            "INSERT INTO \(unescaped: table) (id, name, score, active) VALUES (99, \(hostile), 0, 0)"
        )

        // The table still exists, and holds the payload verbatim.
        let stored = try await connection.executeFirst(
            "SELECT name FROM \(unescaped: table) WHERE id = \(99)",
            as: String.self
        )
        #expect(stored == hostile)

        let count = try await connection.executeFirst(
            "SELECT COUNT(*) FROM \(unescaped: table)", as: Int.self
        )
        #expect(count == 4, "the table survived, so nothing was executed")
    }

    /// `IN` with a runtime-sized list — the case every reference client makes
    /// you build by hand.
    @Test("a list interpolates into IN")
    func listInClause() async throws {
        let connection = try await Self.connect(TestServers.latest)
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        let wanted = [1, 3]
        let names = try await connection.execute(
            "SELECT name FROM \(unescaped: table) WHERE id IN (\(list: wanted)) ORDER BY id",
            as: String.self
        )
        #expect(names == ["ada", "alan"])

        // An empty list matches nothing rather than failing to parse.
        let none = try await connection.execute(
            "SELECT name FROM \(unescaped: table) WHERE id IN (\(list: [Int]()))",
            as: String.self
        )
        #expect(none.isEmpty)
    }

    @Test("executeFirst returns nil when there is no row")
    func firstIsOptional() async throws {
        let connection = try await Self.connect(TestServers.latest)
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        let hit = try await connection.executeFirst(
            "SELECT name FROM \(unescaped: table) WHERE id = \(1)", as: String.self
        )
        #expect(hit == "ada")

        let miss = try await connection.executeFirst(
            "SELECT name FROM \(unescaped: table) WHERE id = \(999)", as: String.self
        )
        #expect(miss == nil)
    }

    @Test("executeUpdate and executeInsert report what the server did")
    func updateAndInsertCounts() async throws {
        let connection = try await Self.connect(TestServers.latest)
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        let changed = try await connection.executeUpdate(
            "UPDATE \(unescaped: table) SET score = score + \(0.1) WHERE active = \(true)"
        )
        #expect(changed == 2)

        try await connection.execute(
            "CREATE TABLE \(unescaped: table)_auto (id INT AUTO_INCREMENT PRIMARY KEY, n INT)"
        )
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)_auto") } }
        let id = try await connection.executeInsert(
            "INSERT INTO \(unescaped: table)_auto (n) VALUES (\(5))"
        )
        #expect(id == 1)
    }

    /// The typed streaming form, which keeps backpressure while decoding.
    @Test("forEach streams typed tuples")
    func typedStreaming() async throws {
        let connection = try await Self.connect(TestServers.latest)
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        var seen: [(Int, String)] = []
        try await connection.forEach(
            "SELECT id, name FROM \(unescaped: table) ORDER BY id",
            as: (Int, String).self
        ) { id, name in
            seen.append((id, name))
        }
        #expect(seen.map(\.1) == ["ada", "grace", "alan"])
    }

    /// A quoted identifier reaches the server as a name, not a value.
    @Test("an identifier interpolation names a real table")
    func identifierNamesATable() async throws {
        let connection = try await Self.connect(TestServers.latest)
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        let count = try await connection.executeFirst(
            "SELECT COUNT(*) FROM \(identifier: table)", as: Int.self
        )
        #expect(count == 3)
    }

    /// Every bindable type survives the round trip as itself.
    @Test("value types round-trip unchanged")
    func valueTypesRoundTrip() async throws {
        let connection = try await Self.connect(TestServers.latest)
        defer { connection.closeImmediately() }

        let big = UInt64.max
        let returnedBig = try await connection.executeFirst(
            "SELECT \(big)", as: UInt64.self
        )
        #expect(returnedBig == UInt64.max, "an unsigned value above Int64.max stayed positive")

        let negative = try await connection.executeFirst("SELECT \(Int.min)", as: Int.self)
        #expect(negative == Int.min)

        let text = "Ada Lovelace — 1815 ✨"
        let returnedText = try await connection.executeFirst("SELECT \(text)", as: String.self)
        #expect(returnedText == text, "non-ASCII survived")

        let bytes: [UInt8] = [0x00, 0xFF, 0x10]
        let returnedBytes = try await connection.executeFirst(
            "SELECT \(bytes)", as: [UInt8].self
        )
        #expect(returnedBytes == bytes)
    }
}

import Foundation
import NIOPosix
import Testing

import SwizzleCore
@testable import SwizzlePostgresDriver

/// What the server makes of the bytes this driver sends for a **parameter**.
///
/// ## The direction the existing oracle does not cover
///
/// `PostgresBinaryOracleTests` compares the two ways a *result* is decoded —
/// binary against the server's own text rendering. That is the half that found
/// thirteen bugs. It leaves the other half untouched: nothing checks that the
/// bytes this driver *sends* for a bound value mean to the server what the
/// driver intended.
///
/// A unit test cannot close that. The only thing it can compare an encoder
/// against is this driver's own decoder, and the two agreeing proves they share
/// an assumption rather than that either is right.
///
/// ## The differential
///
/// Each value goes into the same column twice: once **bound as a parameter**,
/// once as a **SQL literal** the server parses from the statement text. The
/// literal path never touches the parameter encoder, so the two rows agreeing is
/// evidence rather than a tautology.
///
/// This is the MySQL suite's shape — `MySQLParameterOracleTests` — pointed at
/// Postgres, which had four oracle suites' worth of coverage in MySQL and one
/// here. The asymmetry was never a judgement about Postgres being safer; it was
/// which driver got attention, and the last time that gap was closed it produced
/// a client crash within minutes.
@Suite(
    "Postgres parameter oracle",
    .enabled(
        if: !PostgresTestServer.available.isEmpty,
        "Postgres fixture not reachable — start it with ./Scripts/test-servers.sh up"
    )
)
struct PostgresParameterOracleTests {

    /// A column, a value bound as a parameter, and the literal that means the
    /// same thing.
    struct Subject: Sendable, CustomStringConvertible {
        let column: String
        let value: SQLValue
        let literal: String
        /// Which encoder branch this reaches — the reason the row is here.
        let reaches: String
        var description: String { "\(column) \(literal)" }
    }

    static let subjects: [Subject] = [
        // Integers at every width's edges. `int2` and `int8` take different
        // paths, and the sign is where a magnitude-based encoder goes wrong.
        .init(column: "smallint", value: .int(0), literal: "0", reaches: "int2 zero"),
        .init(column: "smallint", value: .int(-32768), literal: "-32768",
              reaches: "int2 minimum, which cannot be negated"),
        .init(column: "smallint", value: .int(32767), literal: "32767", reaches: "int2 maximum"),
        .init(column: "integer", value: .int(-2147483648), literal: "-2147483648",
              reaches: "int4 minimum"),
        .init(column: "integer", value: .int(2147483647), literal: "2147483647",
              reaches: "int4 maximum"),
        .init(column: "bigint", value: .int(.min), literal: "-9223372036854775808",
              reaches: "int8 minimum, the classic negation trap"),
        .init(column: "bigint", value: .int(.max), literal: "9223372036854775807",
              reaches: "int8 maximum"),

        // Floating point, which binds by bit pattern and has values SQL spells
        // as words rather than numbers.
        .init(column: "double precision", value: .double(0), literal: "0", reaches: "zero"),
        .init(column: "double precision", value: .double(-0.0), literal: "-0.0",
              reaches: "negative zero, which compares equal to zero but is not it"),
        .init(column: "double precision", value: .double(1.5), literal: "1.5",
              reaches: "an exact binary fraction"),
        .init(column: "double precision", value: .double(-1e308), literal: "-1e308",
              reaches: "magnitude near the limit"),
        .init(column: "double precision", value: .double(.infinity), literal: "'Infinity'",
              reaches: "a non-finite the text form spells as a word"),
        .init(column: "double precision", value: .double(-.infinity), literal: "'-Infinity'",
              reaches: "the other non-finite"),

        // Booleans and NULL, where the wire form is a single byte and the
        // literal is a keyword.
        .init(column: "boolean", value: .bool(true), literal: "true", reaches: "true"),
        .init(column: "boolean", value: .bool(false), literal: "false", reaches: "false"),

        // Text that a literal has to escape and a parameter must not.
        .init(column: "text", value: .text(""), literal: "''", reaches: "the empty string"),
        .init(column: "text", value: .text("a'b"), literal: "'a''b'",
              reaches: "a quote, which the literal doubles and the parameter does not"),
        .init(column: "text", value: .text("a\\b"), literal: "E'a\\\\b'",
              reaches: "a backslash"),
        .init(column: "text", value: .text("a\nb"), literal: "E'a\\nb'", reaches: "a newline"),
        .init(column: "text", value: .text("ünïcødé"), literal: "'ünïcødé'",
              reaches: "multi-byte UTF-8"),

        // Bytea, where a NUL is the byte that breaks anything C-string shaped.
        .init(column: "bytea", value: .blob([]), literal: "'\\x'::bytea",
              reaches: "an empty blob"),
        .init(column: "bytea", value: .blob([0x00, 0xFF, 0x00]), literal: "'\\x00ff00'::bytea",
              reaches: "a NUL inside a binary value"),
        .init(column: "bytea", value: .blob([0xDE, 0xAD, 0xBE, 0xEF]),
              literal: "'\\xdeadbeef'::bytea", reaches: "ordinary bytes"),
    ]

    /// Inserts the value both ways and compares the stored rows.
    static func compare(
        _ connection: PostgresConnection, table: String, subject: Subject,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        _ = try await connection.query("DELETE FROM \(table)")
        // Bound as a parameter: through the encoder under test.
        _ = try await connection.query("INSERT INTO \(table) (v) VALUES ($1)", [subject.value])
        let bound = try await connection.query("SELECT v FROM \(table)").rows.first?[0]

        _ = try await connection.query("DELETE FROM \(table)")
        // As a literal: parsed by the server from the statement text, so it
        // never reaches the parameter encoder at all.
        _ = try await connection.query("INSERT INTO \(table) (v) VALUES (\(subject.literal))")
        let literal = try await connection.query("SELECT v FROM \(table)").rows.first?[0]

        #expect(
            bound == literal,
            Comment(rawValue: """
                \(subject.column) \(subject.literal) — \(subject.reaches): \
                bound parameter stored \(bound as Any), the literal stored \(literal as Any)
                """),
            sourceLocation: sourceLocation
        )
    }

    /// One connection per server, looping the subjects — **not** one per case.
    ///
    /// The first version opened a connection per `(server, subject)` pair: 115
    /// of them, run in parallel across five servers, which exhausted
    /// `max_connections` and surfaced as `FATAL: sorry, too many clients
    /// already` in *unrelated* suites. The MySQL oracles carry the same note for
    /// the same reason; this suite rediscovered it rather than reading it.
    @Test("a bound parameter stores what the equivalent literal stores",
          arguments: PostgresTestServer.available)
    func boundMatchesLiteral(server: PostgresTestServer.Instance) async throws {
        let connection = try await PostgresConnection.connect(
            configuration: PostgresConnectionConfiguration(swizzleURL: server.url),
            on: MultiThreadedEventLoopGroup.singleton.next()
        )
        defer { connection.closeImmediately() }

        for subject in Self.subjects {
            let table = "param_\(UInt32.random(in: 0..<UInt32.max))"
            _ = try await connection.query("CREATE TABLE \(table) (v \(subject.column))")
            do {
                try await Self.compare(connection, table: table, subject: subject)
            } catch {
                _ = try? await connection.query("DROP TABLE IF EXISTS \(table)")
                throw error
            }
            _ = try? await connection.query("DROP TABLE IF EXISTS \(table)")
        }
    }

    /// NULL is its own case: it has no literal to escape and no bytes to
    /// encode, and binding it must not become the string `"NULL"`.
    @Test("a bound NULL is SQL NULL, not a string",
          arguments: PostgresTestServer.available)
    func boundNullIsNull(server: PostgresTestServer.Instance) async throws {
        let connection = try await PostgresConnection.connect(
            configuration: PostgresConnectionConfiguration(swizzleURL: server.url),
            on: MultiThreadedEventLoopGroup.singleton.next()
        )
        defer { connection.closeImmediately() }

        let table = "paramnull_\(UInt32.random(in: 0..<UInt32.max))"
        _ = try await connection.query("CREATE TABLE \(table) (v text)")
        _ = try await connection.query("INSERT INTO \(table) (v) VALUES ($1)", [.null])

        let rows = try await connection.query(
            "SELECT v IS NULL, v FROM \(table)"
        ).rows
        #expect(rows.first?[0] == .bool(true), "the server must see SQL NULL")
        #expect(rows.first?[1] == .null)
        _ = try? await connection.query("DROP TABLE IF EXISTS \(table)")
    }
}

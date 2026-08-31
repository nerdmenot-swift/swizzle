import Foundation
import Testing
@testable import SwizzleMySQL

/// Every column type, read both ways, compared.
///
/// ## The MySQL analogue of the Postgres oracle
///
/// MySQL has two result encodings and this driver decodes both: `COM_QUERY`
/// returns every value as **text**, and `COM_STMT_EXECUTE` returns it in a
/// **binary** encoding that varies per column type. A caller cannot tell which
/// one they got — `query(sql)` takes the first path and `query(sql, [])` the
/// second, and the same column has to produce the same `MySQLValue` either way.
///
/// The Postgres pass found thirteen bugs this way, five of them because three
/// separate suites compared the server's rendering against itself and could not
/// fail. The shape of the mistake transfers even though the contract does not:
/// MySQL returns *typed* values rather than rendering to text, so the "must match
/// what the server prints" bug class mostly does not apply here — but "text and
/// binary must agree" applies exactly.
///
/// ## Why this is worth more than the mutation sweep
///
/// A survivor tells you a line is unexercised. This tells you the two decoders
/// disagree, which is a defect on its own terms and needs no interpretation.
/// Every one of the Postgres bugs came from an oracle, not from a survivor.
///
/// ## Completeness
///
/// The suite **discovers** which wire types it exercised — reading the column
/// definition the server sent rather than assuming what a SQL type maps to — and
/// then asserts that every `MySQLColumnType` the driver knows was either covered
/// or is exempt with a reason. Guessing the mapping is how a table like this
/// quietly stops covering what it claims.
@Suite(
    "MySQL text/binary oracle",
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct MySQLProtocolOracleTests {

    /// One column definition and the literals worth storing in it.
    struct Subject: Sendable, CustomStringConvertible {
        let column: String
        let literals: [String]
        var description: String { column }
    }

    /// Literals at the edges: the sign, the width of the representation, the
    /// zero, and whatever the encoder has to make a decision about — a fraction
    /// that rounds, a string that needs escaping, a date at the boundary of what
    /// the type can hold.
    static let subjects: [Subject] = [
        .init(column: "TINYINT", literals: ["0", "1", "-1", "127", "-128"]),
        .init(column: "TINYINT UNSIGNED", literals: ["0", "255"]),
        .init(column: "SMALLINT", literals: ["0", "-32768", "32767"]),
        .init(column: "SMALLINT UNSIGNED", literals: ["0", "65535"]),
        .init(column: "MEDIUMINT", literals: ["0", "-8388608", "8388607"]),
        .init(column: "MEDIUMINT UNSIGNED", literals: ["0", "16777215"]),
        .init(column: "INT", literals: ["0", "-2147483648", "2147483647"]),
        .init(column: "INT UNSIGNED", literals: ["0", "4294967295"]),
        .init(column: "BIGINT", literals: ["0", "-9223372036854775808", "9223372036854775807"]),
        // The one the plan flagged: `SQLValue.int` is signed, so anything past
        // Int64.max has nowhere to go without becoming negative.
        .init(column: "BIGINT UNSIGNED",
              literals: ["0", "9223372036854775807", "9223372036854775808",
                         "18446744073709551615"]),
        .init(column: "FLOAT", literals: ["0", "1.5", "-1.5"]),
        .init(column: "DOUBLE", literals: ["0", "1.5", "-1.5", "1e300", "-1e300"]),
        .init(column: "DECIMAL(20,6)",
              literals: ["0", "1.100000", "-1.100000", "0.000001",
                         "99999999999999.999999", "-99999999999999.999999"]),
        .init(column: "DECIMAL(65,0)",
              literals: ["0",
                         "99999999999999999999999999999999999999999999999999999999999999999"]),
        .init(column: "BIT(8)", literals: ["b'00000000'", "b'10101010'", "b'11111111'"]),
        .init(column: "BIT(64)", literals: ["b'1'", "b'1111111111111111111111111111111111111111111111111111111111111111'"]),
        .init(column: "DATE", literals: ["'1000-01-01'", "'9999-12-31'", "'2024-02-29'"]),
        .init(column: "DATETIME(6)",
              literals: ["'1000-01-01 00:00:00.000000'", "'9999-12-31 23:59:59.999999'",
                         "'2024-03-05 14:30:00.123456'"]),
        .init(column: "TIMESTAMP(6) NULL",
              literals: ["'1970-01-02 00:00:01.000000'", "'2024-03-05 14:30:00.123456'"]),
        // TIME is signed and reaches beyond a day in both directions, which is
        // the part a naive encoder gets wrong.
        .init(column: "TIME(6)",
              literals: ["'00:00:00.000000'", "'838:59:59.000000'", "'-838:59:59.000000'",
                         "'-00:00:01.500000'", "'12:34:56.500000'"]),
        .init(column: "YEAR", literals: ["1901", "2155", "2024"]),
        .init(column: "CHAR(10)", literals: ["'abc'", "''", "'ünïcødé'"]),
        .init(column: "VARCHAR(64)",
              literals: ["'abc'", "''", "'a\\'b'", "'a\\\\b'", "'a\nb'", "'ünïcødé'"]),
        .init(column: "BINARY(4)", literals: ["0x00000000", "0xDEADBEEF"]),
        .init(column: "VARBINARY(64)", literals: ["''", "0xDEADBEEF", "0x00"]),
        .init(column: "TINYBLOB", literals: ["''", "0xDEADBEEF"]),
        .init(column: "BLOB", literals: ["''", "0xDEADBEEF"]),
        .init(column: "MEDIUMBLOB", literals: ["''", "0xDEADBEEF"]),
        .init(column: "LONGBLOB", literals: ["''", "0xDEADBEEF"]),
        .init(column: "TEXT", literals: ["''", "'abc'", "'ünïcødé'"]),
        .init(column: "ENUM('a','b','c')", literals: ["'a'", "'c'"]),
        .init(column: "SET('a','b','c')", literals: ["'a'", "'a,c'", "''"]),
        .init(column: "JSON", literals: ["'{\"a\": 1}'", "'[]'", "'null'"]),
        .init(column: "GEOMETRY", literals: ["ST_GeomFromText('POINT(1 2)')"]),
    ]

    /// Wire types with no subject, and why.
    ///
    /// Every reason here was **measured**, not assumed: a probe created a column
    /// of each shape on all six fixtures and read back the type byte the server
    /// actually sent. Several of these are types the protocol defines and no
    /// server ever puts in a result.
    static let exempt: [MySQLColumnType: String] = [
        .null: "the type of a literal NULL in a result, never a column's own type",
        .newdate: "an internal type the server never sends on the wire",
        .timestamp2: "internal storage format; the wire type stays `timestamp`",
        .datetime2: "internal storage format; the wire type stays `datetime`",
        .time2: "internal storage format; the wire type stays `time`",
        .typedArray: "used only in the binary protocol's array parameters, not results",
        .decimal: "pre-5.0 DECIMAL; every modern server sends `newdecimal`",
        .varchar: "the server sends `varString` for VARCHAR results, not this",
        .vector: "MySQL 9 only, and not yet decoded by this driver",
        .unknown: "the driver's own fallback for a type it does not recognise",
        // Measured across all six fixtures:
        .enumeration: "ENUM columns report as `string`; the distinction is in the "
            + "column flags, not the type byte. No server sends this in a result",
        .set: "SET columns report as `string`, for the same reason as ENUM",
        .tinyBlob: "every BLOB width reports as `blob`; the size is in the length "
            + "metadata rather than the type",
        .mediumBlob: "as tinyBlob",
        .longBlob: "as tinyBlob",
    ]

    static func connect(_ server: MySQLTestServer) async throws -> MySQLConnection {
        try await TestServers.connect(server)
    }

    /// Reads one column both ways and compares.
    ///
    /// `query(sql)` is `COM_QUERY` and returns text; `query(sql, [])` prepares
    /// and executes, which returns binary. Nothing else differs.
    static func compare(
        _ connection: MySQLConnection, table: String, literal: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> MySQLColumnType? {
        _ = try await connection.query("DELETE FROM \(table)")
        _ = try await connection.query("INSERT INTO \(table) (v) VALUES (\(literal))")

        let text = try await connection.query("SELECT v FROM \(table)")
        let binary = try await connection.query("SELECT v FROM \(table)", [])

        #expect(
            text.rows.first?[0] == binary.rows.first?[0],
            """
            \(table) \(literal): \
            text \(text.rows.first?[0] as Any), binary \(binary.rows.first?[0] as Any)
            """,
            sourceLocation: sourceLocation
        )
        return text.columns.first.map { MySQLColumnType(rawValueOrUnknown: $0.type) }
    }

    // MARK: - The oracle

    @Test("text and binary decode every column type identically",
          arguments: TestServers.all, subjects)
    func textAndBinaryAgree(server: MySQLTestServer, subject: Subject) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "oracle_\(UInt32.random(in: 0..<UInt32.max))"
        do {
            _ = try await connection.query("CREATE TABLE \(table) (v \(subject.column))")
        } catch {
            // A type this server does not have is a fact about the server, not a
            // failure — `MEDIUMINT` exists everywhere, `VECTOR` does not.
            return
        }
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        for literal in subject.literals {
            _ = try await Self.compare(connection, table: table, literal: literal)
        }
    }

    // MARK: - Completeness

    /// Which wire types the subjects above actually produced, discovered by
    /// asking the server rather than by assuming what a SQL type maps to.
    ///
    /// The assumption is exactly what goes stale: `VARCHAR` reports as
    /// `varString`, `MEDIUMINT` as `int24`, and `DECIMAL` as `newdecimal` on
    /// every server since 5.0. A hand-written mapping would claim coverage it
    /// does not have.
    @Test("every column type the driver decodes is covered or exempt")
    func everyColumnTypeIsAccountedFor() async throws {
        // Every server, unioned: `json` is a distinct wire type on MySQL and
        // reports as `blob` on MariaDB, which stores JSON as LONGTEXT. Probing
        // one server would exempt a type another does send.
        var seen = Set<MySQLColumnType>()
        for server in TestServers.all {
            let connection = try await Self.connect(server)
            defer { connection.closeImmediately() }

            for subject in Self.subjects {
                let table = "probe_\(UInt32.random(in: 0..<UInt32.max))"
                do {
                    _ = try await connection.query("CREATE TABLE \(table) (v \(subject.column))")
                } catch {
                    // A type this server does not have is a fact about the
                    // server rather than a gap in the table.
                    continue
                }
                let result = try await connection.query("SELECT v FROM \(table)")
                if let column = result.columns.first {
                    seen.insert(MySQLColumnType(rawValueOrUnknown: column.type))
                }
                // Dropped **awaited**, not in a detached Task. The first version
                // spawned the drops and they raced the next CREATE on the same
                // connection, so most tables were never created and the
                // discovered set came back nearly empty — which read as "nothing
                // is covered" rather than as a broken probe.
                _ = try? await connection.query("DROP TABLE IF EXISTS \(table)")
            }
        }

        let exempted = Set(Self.exempt.keys)
        let missing = MySQLColumnType.allCases.filter {
            !seen.contains($0) && !exempted.contains($0)
        }
        #expect(
            missing.isEmpty,
            Comment(rawValue: "these wire types have a decoder but nothing exercises them, "
                + "and no exemption: " + missing.map { "\($0)" }.joined(separator: ", "))
        )
    }
}

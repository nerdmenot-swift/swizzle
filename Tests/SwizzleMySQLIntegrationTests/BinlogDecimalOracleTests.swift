import Foundation
import Testing
@testable import SwizzleMySQL

/// The packed-decimal decoder, checked against the server's own rendering.
///
/// ## Why DECIMAL needs an oracle rather than examples
///
/// Every other binlog column type is a fixed-width integer or a packed temporal
/// with a documented layout. DECIMAL is neither: it stores **nine digits per
/// four big-endian bytes with a partial group at each end**, flips the sign bit
/// of the first byte so the encoding sorts as raw bytes, and complements every
/// byte when the value is negative. The width of each partial group comes from a
/// lookup table indexed by `digits % 9`.
///
/// That is four interacting decisions, and the existing coverage was three
/// hand-picked values with the answers written next to them — which tests that
/// the decoder agrees with what someone expected, not that it agrees with
/// MySQL. The mutation sweep left five survivors across the renderer for exactly
/// that reason: `123.45` and `-987.65` take the same path, so the partial-group
/// arithmetic was never varied.
///
/// ## The differential
///
/// The same row is read two ways. The **binlog** path goes through
/// `decodeDecimal` on the packed bytes; the **`SELECT`** path is the server
/// rendering its own stored value as text. Nothing is shared between them, so
/// agreement is evidence.
///
/// The shapes are chosen to make `(precision - scale) % 9` and `scale % 9` take
/// every value from 0 to 8 — the index into the partial-group table — rather
/// than to look like realistic columns. Realistic columns are what left the
/// survivors.
@Suite(
    "Binlog DECIMAL oracle",
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct BinlogDecimalOracleTests {

    struct Shape: Sendable, CustomStringConvertible {
        let precision: Int
        let scale: Int
        var description: String { "DECIMAL(\(precision),\(scale))" }
        var integerDigits: Int { precision - scale }

        /// Literals that exercise this shape's edges: zero, the units, the
        /// widest value it holds, and values whose leading digits fall inside a
        /// partial group — which is where the leading-zero stripping either
        /// works or eats a digit.
        var literals: [String] {
            // `1` needs an integer digit, which an entirely fractional column
            // does not have — DECIMAL(30,30) holds nothing at or above 1.
            var out = integerDigits > 0 ? ["0", "1", "-1"] : ["0", "0.1", "-0.1"]
            let maxInteger = String(repeating: "9", count: max(integerDigits, 0))
            let maxFraction = String(repeating: "9", count: scale)

            func compose(_ integer: String, _ fraction: String) -> String {
                if scale == 0 { return integer.isEmpty ? "0" : integer }
                return "\(integer.isEmpty ? "0" : integer).\(fraction)"
            }

            if integerDigits > 0 || scale > 0 {
                out.append(compose(maxInteger, maxFraction))
                out.append("-" + compose(maxInteger, maxFraction))
            }
            // The smallest non-zero value the scale can express, which is all
            // leading zeros in the fraction.
            if scale > 0 {
                out.append(compose("", String(repeating: "0", count: scale - 1) + "1"))
                out.append("-" + compose("", String(repeating: "0", count: scale - 1) + "1"))
            }
            // A value whose integer part is one digit short of full, so the
            // first group decodes with a leading zero that must be stripped —
            // but only one, and only from the front.
            if integerDigits > 1 {
                out.append(compose("1" + String(repeating: "0", count: integerDigits - 1),
                                   String(repeating: "0", count: scale)))
                out.append(compose(String(repeating: "0", count: integerDigits - 1) + "7",
                                   maxFraction))
            }
            return out
        }
    }

    /// `(precision - scale) % 9` and `scale % 9` between them cover 0…8 in both
    /// positions, plus the extremes MySQL allows: precision 65, scale 30, and a
    /// column that is entirely fractional.
    static let shapes: [Shape] = [
        .init(precision: 1, scale: 0),
        .init(precision: 2, scale: 0),
        .init(precision: 9, scale: 0),      // exactly one full group, no partial
        .init(precision: 10, scale: 0),     // one partial digit, then a group
        .init(precision: 17, scale: 0),
        .init(precision: 18, scale: 0),     // two full groups
        .init(precision: 19, scale: 0),
        .init(precision: 10, scale: 2),
        .init(precision: 20, scale: 6),
        .init(precision: 18, scale: 9),     // a full group on each side
        .init(precision: 27, scale: 9),
        .init(precision: 20, scale: 10),    // a partial group on each side
        .init(precision: 30, scale: 30),    // entirely fractional
        .init(precision: 65, scale: 0),     // the widest integer MySQL stores
        .init(precision: 65, scale: 30),    // and the widest overall
        .init(precision: 38, scale: 4),
        .init(precision: 16, scale: 7),
        .init(precision: 12, scale: 8),
    ]

    static func connect() async throws -> MySQLConnection {
        try await TestServers.connect(TestServers.latest)
    }

    /// One pass over one binlog stream for the whole matrix.
    ///
    /// Serialised the way the sibling suite is, and for the same reason: a
    /// connection per shape exhausted `max_connections` and surfaced as
    /// unrelated suites failing to connect.
    @Test("every DECIMAL shape decodes to what the server renders")
    func decimalsMatchTheServer() async throws {
        let connection = try await Self.connect()
        defer { connection.closeImmediately() }

        var tables: [(table: String, shape: Shape, literals: [String])] = []
        for (index, shape) in Self.shapes.enumerated() {
            let table = "bindec_\(UInt32.random(in: 0..<UInt32.max))_\(index)"
            _ = try await connection.query(
                """
                CREATE TABLE \(table) (
                    id INT PRIMARY KEY,
                    v DECIMAL(\(shape.precision),\(shape.scale)),
                    sentinel INT
                )
                """
            )
            tables.append((table, shape, shape.literals))
        }

        let start = try await connection.binlogPosition()
        for (table, _, literals) in tables {
            for (row, literal) in literals.enumerated() {
                _ = try await connection.query(
                    "INSERT INTO \(table) VALUES (\(row), \(literal), 987654)"
                )
            }
        }

        // What the server itself says each row holds. This is the other half of
        // the differential and it never touches the packed format.
        var rendered: [String: [Int: String]] = [:]
        for (table, _, _) in tables {
            let result = try await connection.query("SELECT id, v FROM \(table) ORDER BY id")
            var byID: [Int: String] = [:]
            for row in result.rows {
                guard let id = row[0].int, let text = row[1].string else { continue }
                byID[Int(id)] = text
            }
            rendered[table] = byID
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

        for (table, shape, literals) in tables {
            let rows = try #require(byTable[table], "no row events for \(shape)")
            #expect(rows.count == literals.count, "\(shape): \(rows.count) rows")
            let expected = try #require(rendered[table])

            for row in rows {
                guard row.count == 3, let id = row[0].int else {
                    Issue.record("\(shape): malformed row image \(row)")
                    continue
                }
                let fromServer = try #require(expected[Int(id)], "\(shape) row \(id)")
                #expect(
                    row[1].string == fromServer,
                    Comment(rawValue: "\(shape) row \(id) (\(literals[Int(id)])): "
                        + "binlog \(row[1].string ?? "nil"), server \(fromServer)")
                )
                // A width error in the decimal would eat the sentinel, which is
                // how a wrong partial-group size shows up when the rendered
                // digits happen to still look plausible.
                #expect(
                    row[2].int == 987_654,
                    Comment(rawValue: "\(shape) row \(id): sentinel corrupted, "
                        + "the decimal consumed the wrong number of bytes")
                )
            }
        }

        for (table, _, _) in tables {
            _ = try? await connection.query("DROP TABLE IF EXISTS \(table)")
        }
    }
}

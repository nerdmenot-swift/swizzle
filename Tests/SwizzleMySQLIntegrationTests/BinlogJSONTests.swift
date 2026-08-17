import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import SwizzleMySQL

/// JSON columns through the binlog, on both flavours.
///
/// The two store JSON completely differently and both report
/// `MYSQL_TYPE_JSON`: MariaDB keeps text (`JSON` is an alias for `LONGTEXT`),
/// MySQL keeps a compact binary tree. Without decoding the binary form, every
/// JSON column in a MySQL CDC stream is unreadable bytes — on the *default*
/// configuration, which is what made this worth doing before the partial-update
/// events that also need it.
///
/// Documents are compared **semantically**, via `JSONSerialization`, because
/// MySQL's storage sorts object keys by length and then value — so a faithful
/// decode legitimately returns keys in a different order from the input.
@Suite(
    "Binlog JSON",
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct BinlogJSONTests {

    static var documents: [String] {
        let longString = String(repeating: "x", count: 70_000)
        let manyKeys = "{" + (1...200).map { "\"k\($0)\":\($0)" }.joined(separator: ",") + "}"
        let deepArray = String(repeating: "[", count: 30) + "1"
            + String(repeating: "]", count: 30)

        return [
            #"{"name":"ada","n":42,"ok":true}"#,
            #"{}"#,
            #"[]"#,
            #"[1,2,3,4,5]"#,
            #"{"nested":{"deep":{"deeper":[1,{"x":null}]}}}"#,
            // Every scalar the format gives a distinct type byte.
            #"{"null":null,"true":true,"false":false,"neg":-32768,"small":42}"#,
            #"{"big":2147483647,"huge":9223372036854775807,"float":1.5,"negfloat":-0.25}"#,
            // Escaping.
            #"{"quote":"a\"b","backslash":"a\\b","newline":"a\nb","tab":"a\tb"}"#,
            // Multi-byte UTF-8.
            #"{"unicode":"héllo wörld","emoji":"🎉"}"#,
            // Long enough to force the 32-bit "large" container layout.
            "{\"pad\":\"\(longString)\"}",
            // Many keys, pushing the key-entry table past a small object.
            manyKeys,
            deepArray,
        ]
    }

    static func normalise(_ json: String) throws -> NSObject? {
        try JSONSerialization.jsonObject(
            with: Data(json.utf8), options: [.fragmentsAllowed]
        ) as? NSObject
    }

    @Test("JSON documents round-trip through a row image", arguments: TestServers.all)
    func documentsRoundTrip(server: MySQLTestServer) async throws {
        let connection = try await BinlogTests.connect(server)
        defer { connection.closeImmediately() }

        let table = "binjson_\(UInt32.random(in: 0..<UInt32.max))"
        _ = try await connection.query("CREATE TABLE \(table) (id INT PRIMARY KEY, doc JSON)")
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        let documents = Self.documents
        let start = try await connection.binlogPosition()
        for (index, document) in documents.enumerated() {
            _ = try await connection.query(
                "INSERT INTO \(table) VALUES (?, ?)",
                [.int(Int64(index)), .bytes(Array(document.utf8))]
            )
        }

        let events = try await BinlogTests.collect(server, from: start)
        var decoded: [Int64: String] = [:]
        for event in events {
            guard case .rows(let rows) = event.payload, rows.table.table == table,
                  rows.kind == .write else { continue }
            for row in rows.rows {
                guard let id = row[0].int, let text = row[1].string else { continue }
                decoded[id] = text
            }
        }

        #expect(decoded.count == documents.count, "not every document produced a row event")

        for (index, original) in documents.enumerated() {
            guard let text = decoded[Int64(index)] else {
                Issue.record("no row for document \(index)"); continue
            }
            let expected = try Self.normalise(original)
            let actual = try Self.normalise(text)
            #expect(
                expected == actual,
                "document \(index) differs — expected \(original.prefix(80)), got \(text.prefix(80))"
            )
        }
    }

    /// The decoded text must be *valid JSON*, not merely similar — a decoder
    /// that forgot to escape a quote would still compare equal on documents that
    /// happen to contain none.
    @Test("decoded documents are valid JSON", arguments: TestServers.all)
    func decodedIsValidJSON(server: MySQLTestServer) async throws {
        let connection = try await BinlogTests.connect(server)
        defer { connection.closeImmediately() }

        let table = "binjsonv_\(UInt32.random(in: 0..<UInt32.max))"
        _ = try await connection.query("CREATE TABLE \(table) (id INT PRIMARY KEY, doc JSON)")
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        let tricky = #"{"q":"say \"hi\"","b":"back\\slash","c":"line\nbreak"}"#
        let start = try await connection.binlogPosition()
        _ = try await connection.query(
            "INSERT INTO \(table) VALUES (1, ?)", [.bytes(Array(tricky.utf8))]
        )

        let events = try await BinlogTests.collect(server, from: start)
        let text = events.compactMap { event -> String? in
            guard case .rows(let rows) = event.payload, rows.table.table == table
            else { return nil }
            return rows.rows.first?[1].string
        }.first

        let decoded = try #require(text, "no row event")
        // Throws if the escaping is wrong.
        _ = try JSONSerialization.jsonObject(with: Data(decoded.utf8))
    }

    /// A NULL column is a different thing from a JSON `null` document, and the
    /// two must not collapse into each other.
    @Test("a NULL column is not a null document", arguments: [TestServers.latestMySQL])
    func nullColumnVersusNullDocument(server: MySQLTestServer) async throws {
        let connection = try await BinlogTests.connect(server)
        defer { connection.closeImmediately() }

        let table = "binjsonn_\(UInt32.random(in: 0..<UInt32.max))"
        _ = try await connection.query("CREATE TABLE \(table) (id INT PRIMARY KEY, doc JSON NULL)")
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        let start = try await connection.binlogPosition()
        _ = try await connection.query("INSERT INTO \(table) VALUES (1, NULL), (2, 'null')")

        let events = try await BinlogTests.collect(server, from: start)
        var byID: [Int64: MySQLValue] = [:]
        for event in events {
            guard case .rows(let rows) = event.payload, rows.table.table == table else { continue }
            for row in rows.rows {
                if let id = row[0].int { byID[id] = row[1] }
            }
        }

        #expect(byID[1]?.isNull == true, "a NULL column should decode as null")
        #expect(byID[2]?.string == "null", "a JSON null document should decode as the text null")
    }
}

import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import SwizzleMySQL

/// `PARTIAL_UPDATE_ROWS_EVENT` — MySQL's `binlog_row_value_options=PARTIAL_JSON`.
///
/// MySQL replaces the after-image of a JSON column with a *diff*, so changing
/// one field of a large document costs bytes rather than the whole document. It
/// also changes the event type, so a client that only knows `UPDATE_ROWS_EVENT`
/// sees **every UPDATE vanish** — which is what happened before this existed.
///
/// No reference client parses this: `rust-mysql-common` treats the event as a
/// plain rows event and hands the blob back raw. The layout below was therefore
/// established from the wire, and the placement of `value_options` is the part
/// that is easy to get wrong — it precedes **each after-image**, not the event.
///
/// The diffs are surfaced rather than applied: `rows` still carries the complete
/// before-image and `jsonDiffs` the changes. Applying them needs a JSON path
/// evaluator and a mutable document model, and a consumer forwarding changes
/// downstream usually wants the diffs themselves.
@Suite(
    "Binlog partial JSON",
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct BinlogPartialJSONTests {

    static func withPartialJSON(
        _ connection: MySQLConnection, _ body: () async throws -> Void
    ) async throws {
        _ = try await connection.query("SET SESSION binlog_row_value_options = \'PARTIAL_JSON\'")
        defer {
            Task { try? await connection.query("SET SESSION binlog_row_value_options = \'\'") }
        }
        try await body()
    }

    static func makeTable(_ connection: MySQLConnection) async throws -> String {
        let name = "partjson_\(UInt32.random(in: 0..<UInt32.max))"
        _ = try await connection.query("CREATE TABLE \(name) (id INT PRIMARY KEY, doc JSON)")
        return name
    }

    static func updates(
        _ events: [MySQLBinlogEvent], table: String
    ) -> [MySQLRowsEvent] {
        events.compactMap { event in
            guard case .rows(let rows) = event.payload, rows.table.table == table,
                  rows.kind == .update else { return nil }
            return rows
        }
    }

    @Test("a partial update is decoded rather than lost", arguments: TestServers.mysql)
    func partialUpdateDecoded(server: MySQLTestServer) async throws {
        let connection = try await BinlogTests.connect(server)
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        // Large enough that MySQL prefers a diff to a rewrite.
        let padding = String(repeating: "x", count: 2_000)
        _ = try await connection.query(
            "INSERT INTO \(table) VALUES (1, ?)",
            [.bytes(Array("{\"name\":\"ada\",\"pad\":\"\(padding)\"}".utf8))]
        )

        let start = try await connection.binlogPosition()
        try await Self.withPartialJSON(connection) {
            _ = try await connection.query(
                "UPDATE \(table) SET doc = JSON_SET(doc, \'$.name\', \'grace\') WHERE id = 1"
            )
        }

        let events = try await BinlogTests.collect(server, from: start)

        let undecoded = events.filter { event in
            guard case .other(let raw) = event.payload else { return false }
            return raw.eventType == .partialUpdateRows
        }
        #expect(undecoded.isEmpty, "the partial update event was not decoded")

        let update = try #require(
            Self.updates(events, table: table).first, "no update row event — the UPDATE was lost"
        )

        // The before-image is complete regardless of what the after-image did.
        #expect(update.rows.count == 1)
        #expect(try #require(update.rows[0][1].string).contains("ada"))

        let columnDiffs = try #require(
            update.jsonDiffs[0]?[1], "no diffs recorded for the JSON column"
        )
        let change = try #require(
            columnDiffs.first { $0.path.contains("name") },
            "no diff touching $.name — got \(columnDiffs.map(\.path))"
        )
        #expect(change.path == "$.name")
        #expect(change.value?.contains("grace") == true, "value was \(change.value ?? "nil")")
    }

    /// The decisive test for where `value_options` lives. If it were written
    /// once per event rather than once per after-image, the second row would
    /// mis-frame and either throw or decode as nonsense.
    @Test("several partially-updated rows in one event", arguments: TestServers.mysql)
    func multipleRows(server: MySQLTestServer) async throws {
        let connection = try await BinlogTests.connect(server)
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        let padding = String(repeating: "z", count: 2_000)
        for id in 1...4 {
            _ = try await connection.query(
                "INSERT INTO \(table) VALUES (?, ?)",
                [.int(Int64(id)),
                 .bytes(Array("{\"name\":\"n\(id)\",\"pad\":\"\(padding)\"}".utf8))]
            )
        }

        let start = try await connection.binlogPosition()
        try await Self.withPartialJSON(connection) {
            // One statement, four rows — so one event carrying four after-images.
            _ = try await connection.query(
                "UPDATE \(table) SET doc = JSON_SET(doc, \'$.name\', \'updated\')"
            )
        }

        let events = try await BinlogTests.collect(server, from: start)
        let allUpdates = Self.updates(events, table: table)
        let totalRows = allUpdates.reduce(0) { $0 + $1.rows.count }
        #expect(totalRows == 4, "expected 4 updated rows, decoded \(totalRows)")

        // Every row must carry its own diff, and every before-image must be intact.
        for update in allUpdates {
            for index in update.rows.indices {
                #expect(
                    try #require(update.rows[index][1].string).contains("pad"),
                    "before-image \(index) is corrupt"
                )
                let diffs = try #require(
                    update.jsonDiffs[index]?[1], "row \(index) has no diffs"
                )
                #expect(diffs.contains { $0.value?.contains("updated") == true })
            }
        }
    }

    /// A removal carries no value, which is a distinct wire shape.
    @Test("a removal diff has no value", arguments: [TestServers.latestMySQL])
    func removalDiff(server: MySQLTestServer) async throws {
        let connection = try await BinlogTests.connect(server)
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        let padding = String(repeating: "y", count: 2_000)
        _ = try await connection.query(
            "INSERT INTO \(table) VALUES (1, ?)",
            [.bytes(Array("{\"drop\":\"me\",\"keep\":\"this\",\"pad\":\"\(padding)\"}".utf8))]
        )

        let start = try await connection.binlogPosition()
        try await Self.withPartialJSON(connection) {
            _ = try await connection.query(
                "UPDATE \(table) SET doc = JSON_REMOVE(doc, \'$.drop\') WHERE id = 1"
            )
        }

        let events = try await BinlogTests.collect(server, from: start)
        let update = try #require(Self.updates(events, table: table).first, "no update row event")
        let diffs = try #require(update.jsonDiffs[0]?[1], "no diffs for the JSON column")
        let removal = try #require(
            diffs.first { $0.operation == .remove },
            "no remove diff — got \(diffs.map { "\($0.operation) \($0.path)" })"
        )
        #expect(removal.value == nil, "a removal must carry no value")
        #expect(removal.path.contains("drop"))
    }

    /// Without the setting, updates stay ordinary full-image events. The default
    /// path must be untouched by any of this.
    @Test("ordinary updates are unaffected", arguments: TestServers.mysql)
    func ordinaryUpdatesUnaffected(server: MySQLTestServer) async throws {
        let connection = try await BinlogTests.connect(server)
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        _ = try await connection.query(
            "INSERT INTO \(table) VALUES (1, ?)",
            [.bytes(Array("{\"name\":\"ada\"}".utf8))]
        )
        let start = try await connection.binlogPosition()
        _ = try await connection.query(
            "UPDATE \(table) SET doc = JSON_SET(doc, \'$.name\', \'grace\') WHERE id = 1"
        )

        let events = try await BinlogTests.collect(server, from: start)
        let update = try #require(Self.updates(events, table: table).first, "no update row event")

        #expect(update.jsonDiffs.isEmpty, "an ordinary update should carry no diffs")
        #expect(try #require(update.updatedRows.first?[1].string).contains("grace"))
    }
}

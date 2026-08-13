import NIOCore
import NIOPosix
import SwizzleCore
import SwizzlePostgresDriver
import Testing

/// `COPY`, against a real server.
///
/// The bulk-load path. Without it an import goes through `INSERT` — the
/// difference between a few thousand rows a second and a few hundred thousand —
/// and `pg_dump`-shaped work is impossible.
@Suite(
    "Postgres COPY", .serialized,
    .enabled(if: PostgresTestServer.isAvailable, PostgresTestServer.skipReason)
)
struct PostgresCopyTests {

    static let url = "postgres://swizzle:swizzlepass@127.0.0.1:5432/swizzle_test?sslmode=require"

    static func open() async throws -> PostgresConnection {
        try await PostgresConnection.connect(
            configuration: PostgresConnectionConfiguration(swizzleURL: url),
            on: MultiThreadedEventLoopGroup.singleton.next()
        )
    }

    func withTable(
        _ body: (PostgresConnection, String) async throws -> Void
    ) async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }
        let table = "copy_probe_\(UInt32.random(in: 0..<UInt32.max))"
        _ = try await connection.query(
            "CREATE TEMP TABLE \(table) (id int, name text, note text)"
        )
        try await body(connection, table)
    }

    func count(_ connection: PostgresConnection, _ table: String) async throws -> Int64 {
        let rows = try await connection.query("SELECT count(*) FROM \(table)").rows
        guard case .int(let value) = rows[0][0] else { return -1 }
        return value
    }

    // MARK: - COPY OUT

    @Test("copy out streams the table's contents")
    func copyOut() async throws {
        try await withTable { connection, table in
            _ = try await connection.query(
                "INSERT INTO \(table) VALUES (1,'ada','x'), (2,'grace','y')"
            )

            let bytes = try await connection.copyOutCollected("COPY \(table) TO STDOUT")
            let text = String(decoding: bytes, as: UTF8.self)
            #expect(text == "1\tada\tx\n2\tgrace\ty\n")
        }
    }

    @Test("copy out honours the CSV format")
    func copyOutCSV() async throws {
        try await withTable { connection, table in
            _ = try await connection.query("INSERT INTO \(table) VALUES (1,'ada','x')")

            let bytes = try await connection.copyOutCollected(
                "COPY \(table) TO STDOUT WITH (FORMAT csv)"
            )
            #expect(String(decoding: bytes, as: UTF8.self) == "1,ada,x\n")
        }
    }

    /// A copy that produces nothing must still end the sequence rather than
    /// leaving the caller waiting — the same shape that hung the row stream when
    /// a statement returned no `RowDescription`.
    @Test("an empty table yields an empty stream, not a hang")
    func copyOutEmpty() async throws {
        try await withTable { connection, table in
            let bytes = try await connection.copyOutCollected("COPY \(table) TO STDOUT")
            #expect(bytes.isEmpty)

            // And the connection is immediately usable again.
            let rows = try await connection.query("SELECT 1").rows
            #expect(rows[0][0] == .int(1))
        }
    }

    /// `CopyData` boundaries are **not** row boundaries — a row can span two
    /// chunks — so a caller must buffer across them. This checks the driver does
    /// not lose or reorder anything while chunking.
    @Test("a large copy out reassembles exactly")
    func copyOutLarge() async throws {
        try await withTable { connection, table in
            _ = try await connection.query(
                "INSERT INTO \(table) SELECT g, 'name-' || g, repeat('x', 100) "
                + "FROM generate_series(1, 5000) g"
            )

            let bytes = try await connection.copyOutCollected("COPY \(table) TO STDOUT")
            let lines = String(decoding: bytes, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true)
            #expect(lines.count == 5000)
            #expect(lines.first?.hasPrefix("1\tname-1\t") == true)
            #expect(lines.last?.hasPrefix("5000\tname-5000\t") == true)
        }
    }

    // MARK: - COPY IN

    @Test("copy in loads rows and reports the count")
    func copyIn() async throws {
        try await withTable { connection, table in
            let loaded = try await connection.copyIn("COPY \(table) FROM STDIN") { writer in
                try await writer.writeTextRow(["1", "ada", "x"])
                try await writer.writeTextRow(["2", "grace", "y"])
            }
            #expect(loaded == 2)

            let rows = try await connection.query(
                "SELECT id, name FROM \(table) ORDER BY id"
            ).rows
            #expect(rows.map { $0[1] } == [.text("ada"), .text("grace")])
        }
    }

    /// The escaping is the part worth not hand-rolling: a literal tab or newline
    /// in a value would end the field or the row, silently shifting every column
    /// after it.
    @Test("tabs, newlines and backslashes survive a text copy")
    func copyInEscaping() async throws {
        try await withTable { connection, table in
            let awkward = "a\tb\nc\\d"
            _ = try await connection.copyIn("COPY \(table) FROM STDIN") { writer in
                try await writer.writeTextRow(["1", awkward, nil])
            }

            let rows = try await connection.query("SELECT name, note FROM \(table)").rows
            #expect(rows[0][0] == .text(awkward))
            // `\N` is null, not the two-character string.
            #expect(rows[0][1] == .null)
        }
    }

    /// **`CopyFail`, not `CopyDone`.** Finishing a half-written import cleanly is
    /// the one outcome nobody wants, so a throwing body aborts the copy and the
    /// server discards everything it has taken.
    @Test("a failing writer aborts the import rather than committing part of it")
    func copyInAborts() async throws {
        struct Boom: Error {}
        try await withTable { connection, table in
            await #expect(throws: Boom.self) {
                try await connection.copyIn("COPY \(table) FROM STDIN") { writer in
                    try await writer.writeTextRow(["1", "ada", "x"])
                    throw Boom()
                }
            }

            let rowCount = try await count(connection, table)
            #expect(rowCount == 0)
            // The connection recovers — a failed copy is a statement error, not a
            // protocol desync.
            let rows = try await connection.query("SELECT 1").rows
            #expect(rows[0][0] == .int(1))
        }
    }

    /// A bad row is rejected by the server mid-copy, and that has to surface as
    /// an error rather than a silent partial load.
    @Test("the server's own rejection surfaces")
    func copyInServerRejection() async throws {
        try await withTable { connection, table in
            await #expect(throws: (any Error).self) {
                try await connection.copyIn("COPY \(table) FROM STDIN") { writer in
                    // `id` is an int, so this cannot be parsed.
                    try await writer.writeTextRow(["not-a-number", "ada", "x"])
                }
            }
            let rowCount = try await count(connection, table)
            #expect(rowCount == 0)
        }
    }

    // MARK: - Binary COPY

    /// The header is `PGCOPY\n\377\r\n\0` — chosen so that anything treating the
    /// stream as text mangles it visibly, and a transfer corrupted by a
    /// line-ending conversion fails instead of importing nonsense.
    @Test("the binary header carries the signature Postgres checks")
    func binaryHeader() {
        let header = PostgresBinaryCopy.header()
        #expect(Array(header.prefix(7)) == Array("PGCOPY\n".utf8))
        #expect(Array(header.dropFirst(7).prefix(4)) == [0xFF, 0x0D, 0x0A, 0x00])
        // Signature, a flags word, and an extension-area length.
        #expect(header.count == 19)

        #expect(throws: PostgresCopyError.malformedBinaryHeader) {
            _ = try PostgresBinaryCopy.stripHeader(Array("not a copy stream…".utf8))
        }
    }

    @Test("binary copy in loads rows")
    func copyInBinary() async throws {
        try await withTable { connection, table in
            func int32(_ value: Int32) -> [UInt8] {
                withUnsafeBytes(of: value.bigEndian) { Array($0) }
            }

            let rows: [[[UInt8]?]] = [
                [int32(1), Array("ada".utf8), Array("x".utf8)],
                [int32(2), Array("grace".utf8), nil],
            ]
            let loaded = try await connection.copyInBinary(
                "COPY \(table) FROM STDIN WITH (FORMAT binary)", rows: rows
            )
            #expect(loaded == 2)

            let read = try await connection.query(
                "SELECT id, name, note FROM \(table) ORDER BY id"
            ).rows
            #expect(read.map { $0[0] } == [.int(1), .int(2)])
            #expect(read.map { $0[1] } == [.text("ada"), .text("grace")])
            // A `-1` field length is a null, which is how binary copy spells it.
            #expect(read[1][2] == .null)
        }
    }

    @Test("binary copy round-trips through copy out")
    func binaryRoundTrip() async throws {
        try await withTable { connection, table in
            _ = try await connection.query(
                "INSERT INTO \(table) SELECT g, 'n' || g, NULL FROM generate_series(1,100) g"
            )

            let dumped = try await connection.copyOutCollected(
                "COPY \(table) TO STDOUT WITH (FORMAT binary)"
            )
            // The header is there, and stripping it leaves the rows.
            #expect(Array(dumped.prefix(11)) == PostgresBinaryCopy.signature)
            let body = try PostgresBinaryCopy.stripHeader(dumped)
            #expect(body.count > 0)

            _ = try await connection.query("DELETE FROM \(table)")
            _ = try await connection.copyIn(
                "COPY \(table) FROM STDIN WITH (FORMAT binary)"
            ) { writer in
                try await writer.write(dumped)
            }

            let rowCount = try await count(connection, table)
            #expect(rowCount == 100)
        }
    }

    // MARK: - Misuse

    /// A statement that is not a `COPY` never puts the server into copy mode, so
    /// the caller must be told rather than left waiting for data that is not
    /// coming.
    @Test("copying a statement that is not a COPY does not hang")
    func notACopy() async throws {
        try await withTable { connection, table in
            let bytes = try await connection.copyOutCollected("SELECT 1")
            #expect(bytes.isEmpty)

            let rows = try await connection.query("SELECT 2").rows
            #expect(rows[0][0] == .int(2))
        }
    }
}

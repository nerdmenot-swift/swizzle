import SwizzleCore
import SwizzleMigrate
import SwizzlePostgres
import Testing

/// Streaming, end to end against a real server.
///
/// New with the in-house driver. postgres-nio streams too, but this seam was
/// never wired up — the executor collected everything before returning — so
/// "streaming is not optional" held on two engines out of three.
@Suite(
    "Postgres streaming", .serialized,
    .enabled(if: PostgresTestServer.isAvailable, PostgresTestServer.skipReason)
)
struct PostgresStreamingTests {

    static let url = PostgresTestServer.url

    func withConnection(
        _ body: (any EngineConnection) async throws -> Void
    ) async throws {
        let connection = try await PostgresEngine.connect(url: Self.url)
        defer { connection.close() }
        try await body(connection)
    }

    /// The seam that broke once before: `erased` resolved statically to the
    /// non-streaming overload, so a bound query silently lost streaming. It is a
    /// protocol requirement now, and this is the check that it stayed one.
    @Test("the erased executor keeps its streaming path")
    func erasureKeepsStreaming() async throws {
        try await withConnection { connection in
            #expect(connection.executor.canStream)
        }
    }

    @Test("rows arrive through the stream")
    func streamsRows() async throws {
        try await withConnection { connection in
            let executor = connection.executor
            var values: [Int64] = []
            for try await row in try await executor.stream(
                sql: "SELECT generate_series(1, 5) AS n"
            ) {
                guard case .int(let value) = row.values[0] else {
                    Issue.record("expected an integer, got \(row.values[0])"); return
                }
                values.append(value)
            }
            #expect(values == [1, 2, 3, 4, 5])
        }
    }

    @Test("a streamed query takes bindings")
    func streamsWithBindings() async throws {
        try await withConnection { connection in
            var values: [Int64] = []
            for try await row in try await connection.executor.stream(
                sql: "SELECT generate_series(1, $1::int) AS n", bindings: [.int(3)]
            ) {
                if case .int(let value) = row.values[0] { values.append(value) }
            }
            #expect(values == [1, 2, 3])
        }
    }

    /// Abandoning a stream must return or discard the connection rather than
    /// leaving it checked out — the pool here has exactly one, so a leak would
    /// hang the next query rather than merely waste something.
    @Test("abandoning a stream does not strand the connection")
    func abandonedStreamReleases() async throws {
        try await withConnection { connection in
            let executor = connection.executor
            for try await _ in try await executor.stream(
                sql: "SELECT generate_series(1, 10000) AS n"
            ) {
                break
            }
            // A connection stranded by the abandoned stream would make this hang
            // until the acquisition timeout rather than answer.
            let rows = try await executor.execute(sql: "SELECT 1", bindings: [])
            #expect(rows.count == 1)
        }
    }

    /// The count lives in the command tag and nowhere else. Draining rows and
    /// counting them — which is what the borrowed driver forced — returns zero
    /// for every `UPDATE` and `DELETE`, because they send none.
    @Test("an update reports the rows it actually changed")
    func updateReportsAffectedRows() async throws {
        try await withConnection { connection in
            let executor = connection.executor
            _ = try await executor.execute(
                sql: "CREATE TEMP TABLE stream_counts (id int)", bindings: []
            )
            _ = try await executor.execute(
                sql: "INSERT INTO stream_counts SELECT generate_series(1, 7)", bindings: []
            )

            let updated = try await executor.executeUpdate(
                sql: "UPDATE stream_counts SET id = id + 1", bindings: []
            )
            #expect(updated == 7)

            let deleted = try await executor.executeUpdate(
                sql: "DELETE FROM stream_counts WHERE id > $1", bindings: [.int(5)]
            )
            #expect(deleted == 3)

            // A command Postgres reports no count for is zero, not a guess.
            let ddl = try await executor.executeUpdate(
                sql: "CREATE TEMP TABLE stream_counts2 (id int)", bindings: []
            )
            #expect(ddl == 0)
        }
    }

    /// Bound queries go through the extended protocol, where the column metadata
    /// arrives only because the portal is described. Without that every one of
    /// these comes back as text — silently.
    @Test("bound queries decode to their real types, not text")
    func boundQueriesKeepTheirTypes() async throws {
        try await withConnection { connection in
            let rows = try await connection.executor.execute(
                sql: "SELECT $1::bigint AS n, $2::bool AS flag, $3::float8 AS ratio",
                bindings: [.int(42), .bool(true), .double(1.5)]
            )
            #expect(rows.first?.values == [.int(42), .bool(true), .double(1.5)])
        }
    }
}

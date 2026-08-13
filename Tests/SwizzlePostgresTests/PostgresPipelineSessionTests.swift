import NIOCore
import NIOPosix
import SwizzleCore
import SwizzlePostgresDriver
import Testing

/// The one shape `Flush` exists for: statements that see each other's results
/// while still being atomic together.
///
/// `Sync` both pushes results out and commits; `Flush` pushes them out and leaves
/// the implicit transaction open. Every other path in the driver ends with
/// `Sync`, which is why `Flush` had no caller until this.
@Suite(
    "Postgres pipeline session", .serialized,
    .enabled(if: PostgresTestServer.isAvailable, PostgresTestServer.skipReason)
)
struct PostgresPipelineSessionTests {

    static let url = PostgresTestServer.url

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
        let table = "sess_\(UInt32.random(in: 0..<UInt32.max))"
        _ = try await connection.query(
            "CREATE TABLE \(table) (id serial PRIMARY KEY, note text)"
        )
        defer { Task { _ = try? await connection.query("DROP TABLE IF EXISTS \(table)") } }
        try await body(connection, table)
    }

    func count(_ connection: PostgresConnection, _ table: String) async throws -> Int64 {
        let rows = try await connection.query("SELECT count(*) FROM \(table)").rows
        guard case .int(let value) = rows[0][0] else { return -1 }
        return value
    }

    /// The capability itself: statement two uses statement one's result, which a
    /// batch pipeline cannot express because it sends everything before reading
    /// anything.
    @Test("a later statement can use an earlier statement's result")
    func dependentStatements() async throws {
        try await withTable { connection, table in
            try await connection.withPipelineSession { session in
                let inserted = try await session.execute(
                    "INSERT INTO \(table) (note) VALUES ($1) RETURNING id", [.text("first")]
                )
                guard case .int(let id) = inserted.rows[0][0] else {
                    Issue.record("expected an id"); return
                }
                try await session.execute(
                    "INSERT INTO \(table) (note) VALUES ($1)", [.text("child of \(id)")]
                )
            }

            let rows = try await connection.query(
                "SELECT note FROM \(table) ORDER BY id"
            ).rows
            #expect(rows.count == 2)
            #expect(rows[1][0] == .text("child of 1"))
        }
    }

    /// **The `Sync` at the end is what commits.** Without it the block would stay
    /// open and the work would be invisible to anyone else.
    @Test("the session commits when the block returns")
    func commits() async throws {
        try await withTable { connection, table in
            try await connection.withPipelineSession { session in
                try await session.execute("INSERT INTO \(table) (note) VALUES ('a')")
                try await session.execute("INSERT INTO \(table) (note) VALUES ('b')")
            }
            let total = try await count(connection, table)
            #expect(total == 2)

            // Committed, so a *different* connection sees it.
            let other = try await Self.open()
            defer { other.closeImmediately() }
            let seen = try await other.query("SELECT count(*) FROM \(table)").rows
            #expect(seen[0][0] == .int(2))
        }
    }

    /// It is one implicit transaction, so a failure takes the earlier statements
    /// with it — the same rule as the batch pipeline, reached a different way.
    @Test("a failure rolls back everything in the session")
    func failureRollsBack() async throws {
        try await withTable { connection, table in
            await #expect(throws: (any Error).self) {
                try await connection.withPipelineSession { session in
                    try await session.execute("INSERT INTO \(table) (note) VALUES ('a')")
                    try await session.execute("SELECT nonexistent_column")
                }
            }
            let total = try await count(connection, table)
            #expect(total == 0)
        }
    }

    /// After a failure the server discards everything until `Sync`, so a second
    /// statement would wait for a reply that is never coming. The session refuses
    /// rather than hanging.
    @Test("a session refuses further statements after a failure")
    func refusesAfterFailure() async throws {
        try await withTable { connection, table in
            await #expect(throws: (any Error).self) {
                try await connection.withPipelineSession { session in
                    _ = try? await session.execute("SELECT nonexistent_column")
                    // This must throw immediately rather than block.
                    try await session.execute("SELECT 1")
                }
            }
        }
    }

    /// The `Sync` is sent on the failure path too — it is what clears the aborted
    /// state. Skipping it would leave the connection wedged for the next
    /// borrower, which with a pooled connection means somebody else's request.
    @Test("the connection is usable after a failed session")
    func recovers() async throws {
        try await withTable { connection, table in
            _ = try? await connection.withPipelineSession { session in
                try await session.execute("SELECT nonexistent_column")
            }

            let status = try await connection.transactionStatus
            #expect(status == .idle)
            let rows = try await connection.query("SELECT 42").rows
            #expect(rows[0][0] == .int(42))
        }
    }

    @Test("an empty session is a no-op")
    func emptySession() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }
        try await connection.withPipelineSession { _ in }
        let rows = try await connection.query("SELECT 1").rows
        #expect(rows[0][0] == .int(1))
    }
}

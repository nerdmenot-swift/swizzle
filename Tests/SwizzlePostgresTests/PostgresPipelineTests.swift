import NIOCore
import NIOPosix
import SwizzleCore
import SwizzlePostgresDriver
import Testing

/// Pipelining, parameter type hints, and driven `Close`.
@Suite(
    "Postgres pipelining", .serialized,
    .enabled(if: PostgresTestServer.isAvailable, PostgresTestServer.skipReason)
)
struct PostgresPipelineTests {

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
        let table = "pipe_\(UInt32.random(in: 0..<UInt32.max))"
        _ = try await connection.query("CREATE TEMP TABLE \(table) (id int, name text)")
        try await body(connection, table)
    }

    // MARK: - The happy path

    @Test("a pipeline returns one result per statement, in order")
    func resultsInOrder() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        let results = try await connection.pipeline([
            "SELECT 1", "SELECT 2", "SELECT 3",
        ])
        #expect(results.count == 3)
        #expect(results.map { $0.rows[0][0] } == [.int(1), .int(2), .int(3)])
    }

    /// Each statement's replies end with its own `CommandComplete`, which is the
    /// only thing separating them — there is no per-statement marker beyond it.
    /// A result set of a different width on each side is what would expose a
    /// boundary read wrong.
    @Test("statements of different shapes stay separate")
    func differentShapes() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        let results = try await connection.pipeline([
            PostgresPipelineStatement(sql: "SELECT 1 AS a"),
            PostgresPipelineStatement(sql: "SELECT 'x'::text AS b, 'y'::text AS c"),
            PostgresPipelineStatement(sql: "SELECT g FROM generate_series(1,3) g"),
        ])

        #expect(results[0].columns.map(\.name) == ["a"])
        #expect(results[0].rows.count == 1)
        #expect(results[1].columns.map(\.name) == ["b", "c"])
        #expect(results[1].rows[0] == [.text("x"), .text("y")])
        #expect(results[2].rows.count == 3)
    }

    @Test("writes report their own affected-row counts")
    func affectedRows() async throws {
        try await withTable { connection, table in
            let results = try await connection.pipeline([
                "INSERT INTO \(table) VALUES (1,'a'), (2,'b')",
                "UPDATE \(table) SET name = 'z'",
                "DELETE FROM \(table) WHERE id = 1",
            ])
            #expect(results.map(\.affectedRows) == [2, 2, 1])
        }
    }

    /// The batch-insert shape: one statement, many bindings, one round trip.
    @Test("the same statement pipelines with different bindings")
    func repeatedStatement() async throws {
        try await withTable { connection, table in
            let results = try await connection.pipeline(
                "INSERT INTO \(table) VALUES ($1, $2)",
                bindings: (1...20).map { [.int(Int64($0)), .text("n\($0)")] }
            )
            #expect(results.count == 20)
            #expect(results.allSatisfy { $0.affectedRows == 1 })

            let count = try await connection.query("SELECT count(*) FROM \(table)").rows
            #expect(count[0][0] == .int(20))
        }
    }

    // MARK: - The failure rule

    /// **A pipeline is an implicit transaction, and that is not obvious.**
    ///
    /// Statements between two `Sync`s form an implicit transaction block, so one
    /// bad statement rolls back the whole batch — including the ones that had
    /// already succeeded. I documented the opposite first, on the reasonable-
    /// sounding reading that "several statements" means several transactions;
    /// this test is what corrected it.
    ///
    /// The error still has to name *which* statement failed, because the server
    /// reports the failure and not the statement.
    @Test("a mid-pipeline failure names the index, and the whole batch rolls back")
    func failureRollsBackTheBatch() async throws {
        try await withTable { connection, table in
            do {
                _ = try await connection.pipeline([
                    "INSERT INTO \(table) VALUES (1,'a')",
                    "INSERT INTO \(table) VALUES (2,'b')",
                    "INSERT INTO \(table) VALUES ('not-an-int','c')",
                    "INSERT INTO \(table) VALUES (4,'d')",
                ])
                Issue.record("expected the pipeline to fail")
            } catch let error as PostgresPipelineError {
                #expect(error.statementIndex == 2)
                #expect(error.completed.count == 2)
                #expect(error.completed.allSatisfy { $0.affectedRows == 1 })
                #expect(error.sql.contains("not-an-int"))
            }

            // Nothing survived: the first two produced results and were rolled
            // back with the rest, and the fourth never ran at all.
            let ids = try await connection.query(
                "SELECT id FROM \(table) ORDER BY id"
            ).rows
            #expect(ids.isEmpty)
        }
    }

    /// A successful pipeline *does* commit — the `Sync` is what commits the
    /// implicit block, so atomicity is not the same as never persisting.
    @Test("a successful pipeline commits")
    func successCommits() async throws {
        try await withTable { connection, table in
            _ = try await connection.pipeline([
                "INSERT INTO \(table) VALUES (1,'a')",
                "INSERT INTO \(table) VALUES (2,'b')",
            ])
            let count = try await connection.query("SELECT count(*) FROM \(table)").rows
            #expect(count[0][0] == .int(2))
        }
    }

    /// Wrapping it in an explicit transaction changes nothing about atomicity —
    /// it was already atomic. Kept because the *combination* is what a caller will
    /// write, and it must not double-`BEGIN` or otherwise misbehave.
    @Test("a pipeline inside an explicit transaction still rolls back")
    func atomicInsideTransaction() async throws {
        try await withTable { connection, table in
            _ = try? await connection.withTransaction { db in
                _ = try await db.pipeline([
                    "INSERT INTO \(table) VALUES (1,'a')",
                    "INSERT INTO \(table) VALUES ('bad','b')",
                ])
            }

            let count = try await connection.query("SELECT count(*) FROM \(table)").rows
            #expect(count[0][0] == .int(0))
        }
    }

    @Test("the connection is usable after a failed pipeline")
    func recoversAfterFailure() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        _ = try? await connection.pipeline(["SELECT 1", "SELECT nonexistent_column"])
        let rows = try await connection.query("SELECT 42").rows
        #expect(rows[0][0] == .int(42))
    }

    @Test("an empty pipeline is a no-op rather than a hang")
    func emptyPipeline() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }
        let results = try await connection.pipeline([String]())
        #expect(results.isEmpty)
    }

    // MARK: - Parameter type hints

    /// Without a hint, a bare `$1` resolves to `text` — the server does not fail,
    /// it just picks the default, so the value comes back as a string. The hint is
    /// what makes it the type the caller meant.
    ///
    /// This also caught a real bug: **the statement cache was keyed on SQL
    /// alone**, so the hinted query reused the statement parsed *without* hints
    /// and the hint did nothing. Same text, different declared parameter types,
    /// genuinely two prepared statements.
    @Test("a type hint changes the type the server infers")
    func typeHintResolvesAmbiguity() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        // Unhinted: the server defaults `$1` to text.
        let untyped = try await connection.query("SELECT $1", [.int(7)]).rows
        #expect(untyped[0][0] == .text("7"))

        // Hinted: an actual bigint, and only because the cache key includes the
        // hints.
        let typed = try await connection.query(
            "SELECT $1", [.int(7)], parameterTypes: [.int8]
        ).rows
        #expect(typed[0][0] == .int(7))

        // And the order does not matter — the hinted form works first too.
        let fresh = try await Self.open()
        defer { fresh.closeImmediately() }
        let first = try await fresh.query(
            "SELECT $1", [.int(7)], parameterTypes: [.int8]
        ).rows
        #expect(first[0][0] == .int(7))
    }

    /// A hint that disagrees with the statement is an error from the server rather
    /// than a silent coercion, which is the right way round.
    @Test("a wrong hint is rejected rather than coerced")
    func wrongHintIsRejected() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        await #expect(throws: (any Error).self) {
            _ = try await connection.query(
                "SELECT $1::int + 1", [.text("abc")], parameterTypes: [.uuid]
            )
        }
        // And the connection survives it.
        let rows = try await connection.query("SELECT 1").rows
        #expect(rows[0][0] == .int(1))
    }

    // MARK: - Close

    @Test("a named statement can be closed")
    func closeNamedStatement() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        _ = try await connection.query("PREPARE swizzle_named AS SELECT 1")
        let before = try await connection.query(
            "SELECT count(*) FROM pg_prepared_statements WHERE name = 'swizzle_named'"
        ).rows
        #expect(before[0][0] == .int(1))

        try await connection.closeStatement(named: "swizzle_named")

        let after = try await connection.query(
            "SELECT count(*) FROM pg_prepared_statements WHERE name = 'swizzle_named'"
        ).rows
        #expect(after[0][0] == .int(0))
    }

    /// Closing something that is not there is not an error in the protocol — the
    /// goal was for it to be gone, and it is.
    @Test("closing an absent statement is not fatal")
    func closeAbsent() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        try await connection.closeStatement(named: "never_existed")
        let rows = try await connection.query("SELECT 1").rows
        #expect(rows[0][0] == .int(1))
    }
}

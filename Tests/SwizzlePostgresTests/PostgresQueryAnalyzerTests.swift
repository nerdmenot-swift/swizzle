import SwizzleCore
import SwizzleMigrate
import SwizzlePostgres
import Testing

/// The analyzer, against a real server.
///
/// This is the file postgres-nio made impossible: `Describe` was unreachable and
/// `ParameterDescription.dataTypes` was discarded, so neither half of a signature
/// could be obtained at all.
@Suite(
    "Postgres query analyzer", .serialized,
    .enabled(if: PostgresTestServer.isAvailable, PostgresTestServer.skipReason)
)
struct PostgresQueryAnalyzerTests {

    static let url = PostgresTestServer.url

    /// Fixtures live in their own schema so they cannot collide with the
    /// migration suite's tables, and so dropping them is one statement.
    static let setup = """
        DROP SCHEMA IF EXISTS analyzer_fixture CASCADE;
        CREATE SCHEMA analyzer_fixture;
        SET search_path TO analyzer_fixture, public;
        CREATE TABLE users (
            id bigint PRIMARY KEY,
            email text NOT NULL,
            nickname text,
            balance numeric(10,2) NOT NULL,
            tags text[],
            created_at timestamptz NOT NULL
        );
        CREATE TABLE orders (
            id bigint PRIMARY KEY,
            user_id bigint NOT NULL REFERENCES users(id),
            total numeric(10,2) NOT NULL
        );
        CREATE DOMAIN postcode AS text;
        CREATE TABLE addresses (id bigint PRIMARY KEY, code postcode NOT NULL);
        """

    func withAnalyzer(
        _ body: (any QueryAnalyzer) async throws -> Void
    ) async throws {
        let connection = try await PostgresEngine.connect(url: Self.url)
        defer { connection.close() }

        for statement in SQLStatementSplitter(syntax: .postgres).split(Self.setup) {
            _ = try await connection.executor.execute(sql: statement, bindings: [])
        }
        // The fixtures are unqualified in the queries below, so the analyzer's own
        // session has to resolve them the same way — which is the reason it holds
        // one connection for the run rather than borrowing per statement.
        _ = try await connection.executor.execute(
            sql: "SET search_path TO analyzer_fixture, public", bindings: []
        )

        guard let analyzer = connection.analyzer else {
            Issue.record("the Postgres engine should offer an analyzer"); return
        }
        do {
            try await body(analyzer)
            await analyzer.finish()
        } catch {
            await analyzer.finish()
            throw error
        }
    }

    // MARK: - Columns and nullability

    /// **Nullability is not on the wire.** `RowDescription` has no null flag —
    /// for any client in any language — so it comes from `pg_attribute`, keyed on
    /// the `(table OID, attribute number)` the describe does carry.
    @Test("base columns get their real nullability")
    func baseColumnNullability() async throws {
        try await withAnalyzer { analyzer in
            let signature = try await analyzer.analyze(
                "SELECT id, email, nickname FROM users"
            )
            #expect(signature.columns.map(\.name) == ["id", "email", "nickname"])
            #expect(signature.columns.map(\.isOptional) == [false, false, true])
            #expect(
                signature.columns.map(\.nullability) == [
                    .baseColumnNotNull, .baseColumnNotNull, .baseColumnNullable,
                ]
            )
        }
    }

    /// The origin is the **base** column, not the projected name — `SELECT email
    /// AS e` describes a column called `e`, and an origin saying `e` traces to
    /// nothing.
    @Test("an aliased column still traces to its base column")
    func aliasedColumnOrigin() async throws {
        try await withAnalyzer { analyzer in
            let signature = try await analyzer.analyze("SELECT email AS e FROM users")
            #expect(signature.columns.first?.name == "e")
            #expect(signature.columns.first?.origin?.column == "email")
            #expect(signature.columns.first?.origin?.table == "users")
            #expect(signature.columns.first?.origin?.schema == "analyzer_fixture")
        }
    }

    /// `pg_attribute` describes the *column*, not the projection. A `NOT NULL`
    /// column reached through a `LEFT JOIN` really can arrive null, and unlike
    /// MySQL the server does not account for that — so everything widens.
    @Test("an outer join widens what would otherwise be non-optional")
    func outerJoinWidens() async throws {
        try await withAnalyzer { analyzer in
            let signature = try await analyzer.analyze(
                """
                SELECT u.id, o.total FROM users u
                LEFT JOIN orders o ON o.user_id = u.id
                """
            )
            #expect(signature.hasOuterJoin)
            #expect(signature.columns.allSatisfy { $0.isOptional })
            #expect(signature.columns.allSatisfy { $0.nullability == .outerJoinWidened })
        }
    }

    /// An expression has no table OID at all, so there is nothing to trace and
    /// nothing to claim about it.
    @Test("expressions are optional with no origin")
    func expressions() async throws {
        try await withAnalyzer { analyzer in
            let signature = try await analyzer.analyze(
                "SELECT count(*) AS total, 1 + 1 AS two FROM users"
            )
            #expect(signature.columns.allSatisfy { $0.origin == nil })
            #expect(signature.columns.allSatisfy { $0.nullability == .expression })
        }
    }

    // MARK: - Types

    @Test("column types map to their Swift equivalents")
    func columnTypes() async throws {
        try await withAnalyzer { analyzer in
            let signature = try await analyzer.analyze(
                "SELECT id, email, balance, tags, created_at FROM users"
            )
            let byName = Dictionary(
                uniqueKeysWithValues: signature.columns.map { ($0.name, $0) }
            )
            #expect(byName["id"]?.swiftType == .int64)
            #expect(byName["email"]?.swiftType == .string)
            // Never `Double`. An exact numeric through binary floating point
            // loses the cents, which is the whole reason the type exists.
            #expect(byName["balance"]?.swiftType == .decimalString)
            #expect(byName["balance"]?.sqlType == "numeric")
            #expect(byName["tags"]?.swiftType == .array(.string))
            #expect(byName["created_at"]?.swiftType == .date)
        }
    }

    /// A domain is its base type with a constraint bolted on. The constraint is
    /// the server's business; the *type* is what has to be emitted, so the chain
    /// is followed rather than degrading to `dynamic`.
    @Test("a domain resolves to its base type")
    func domains() async throws {
        try await withAnalyzer { analyzer in
            let signature = try await analyzer.analyze("SELECT code FROM addresses")
            #expect(signature.columns.first?.sqlType == "postcode")
            #expect(signature.columns.first?.swiftType == .string)
            #expect(signature.columns.first?.isOptional == false)
        }
    }

    // MARK: - Parameters, the half Postgres alone gets right

    /// MySQL reports every placeholder as `VAR_STRING` and SQLite has no concept
    /// of a parameter type. Postgres infers them and sends real OIDs, so these
    /// are `verified` rather than merely `declared`.
    @Test("parameters carry real inferred types")
    func parameterTypes() async throws {
        try await withAnalyzer { analyzer in
            let signature = try await analyzer.analyze(
                "SELECT id FROM users WHERE id = $1 AND email = $2"
            )
            #expect(signature.parameters.map(\.ordinal) == [1, 2])
            #expect(signature.parameters.map(\.sqlType) == ["int8", "text"])
            #expect(signature.parameters.map(\.swiftType) == [.int64, .string])
            #expect(signature.parameters.allSatisfy { $0.source == .verified })
        }
    }

    @Test("a statement with no parameters reports none")
    func noParameters() async throws {
        try await withAnalyzer { analyzer in
            let signature = try await analyzer.analyze("SELECT id FROM users")
            #expect(signature.parameters.isEmpty)
        }
    }

    // MARK: - Statements that return nothing

    /// The reason a describe must never execute: a generator that ran the
    /// statements it analysed would delete rows to find out what `DELETE` returns.
    @Test("describing a DELETE does not delete anything")
    func describeDoesNotExecute() async throws {
        let connection = try await PostgresEngine.connect(url: Self.url)
        defer { connection.close() }

        for statement in SQLStatementSplitter(syntax: .postgres).split(Self.setup) {
            _ = try await connection.executor.execute(sql: statement, bindings: [])
        }
        _ = try await connection.executor.execute(
            sql: "SET search_path TO analyzer_fixture, public", bindings: []
        )
        _ = try await connection.executor.execute(
            sql: """
                INSERT INTO users (id, email, nickname, balance, tags, created_at)
                VALUES (1, 'a@example.com', NULL, 0, NULL, now())
                """,
            bindings: []
        )

        guard let analyzer = connection.analyzer else {
            Issue.record("expected an analyzer"); return
        }
        let signature = try await analyzer.analyze("DELETE FROM analyzer_fixture.users")
        await analyzer.finish()

        #expect(signature.columns.isEmpty)

        let rows = try await connection.executor.execute(
            sql: "SELECT count(*) FROM analyzer_fixture.users", bindings: []
        )
        #expect(rows.first?.values.first == .int(1))
    }

    @Test("RETURNING gives a DELETE a result set")
    func deleteReturning() async throws {
        try await withAnalyzer { analyzer in
            let signature = try await analyzer.analyze(
                "DELETE FROM users WHERE id = $1 RETURNING id, email"
            )
            #expect(signature.columns.map(\.name) == ["id", "email"])
            #expect(signature.columns.map(\.isOptional) == [false, false])
            #expect(signature.parameters.map(\.swiftType) == [.int64])
        }
    }

    // MARK: - Failures

    /// The server's own words, which for a syntax error name the offending token.
    @Test("a bad statement reports the server's message")
    func badStatement() async throws {
        try await withAnalyzer { analyzer in
            await #expect(throws: QueryAnalysisError.self) {
                _ = try await analyzer.analyze("SELECT nope FROM users")
            }
        }
    }

    /// A failed describe must leave the session usable — the server resynchronises
    /// at `ReadyForQuery`, and an analyzer that gave up after one bad query would
    /// report only the first of a file's mistakes.
    @Test("analysis continues after a failure")
    func continuesAfterFailure() async throws {
        try await withAnalyzer { analyzer in
            _ = try? await analyzer.analyze("SELECT nope FROM users")
            let signature = try await analyzer.analyze("SELECT id FROM users")
            #expect(signature.columns.map(\.name) == ["id"])
        }
    }
}

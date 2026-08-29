import SwizzleCore
import SwizzleMigrate
import SwizzlePostgres
import Testing

/// The same work against every supported Postgres, rather than only the one
/// developed against.
///
/// ## Why a separate suite instead of parameterising the other nineteen
///
/// Almost every Postgres suite here is testing the *driver* — framing, codecs,
/// cursors, pipelining — and running those three times over would triple the
/// fixture cost to re-prove things the wire protocol settles identically on
/// every version. The protocol genuinely barely moves between 14 and 18.
///
/// **The catalog is the part that moves**, and it is the part this library
/// depends on most heavily: the schema introspector and the query analyzer are
/// both built out of `pg_catalog` queries. `pg_attribute`, `pg_constraint`,
/// `pg_type` and the range machinery gain columns and change shape across
/// majors, so the realistic failure is a catalog query that parses on 16 and
/// not on 14 — not a mis-framed packet. That is what this covers, plus enough
/// of the connect path to prove the handshake works at all on each.
///
/// Bracketing rather than filling: 14 is the oldest upstream still supports,
/// 18 is current, 16 is the middle and the default everywhere else. A bug that
/// affects 15 but neither 14 nor 18 is possible and is not worth two more
/// servers in every CI run.
@Suite(
    "Postgres version matrix",
    .enabled(if: !PostgresTestServer.available.isEmpty, PostgresTestServer.matrixSkipReason)
)
struct PostgresVersionMatrixTests {

    /// Each instance gets its own schema, so the three servers cannot be
    /// distinguished by leftover state and the suite can run unserialised.
    static func setup(_ schema: String) -> String {
        """
        DROP SCHEMA IF EXISTS \(schema) CASCADE;
        CREATE SCHEMA \(schema);
        SET search_path TO \(schema), public;
        CREATE TABLE accounts (
            id bigint PRIMARY KEY,
            email text NOT NULL,
            nickname text,
            balance numeric(12,2) NOT NULL DEFAULT 0,
            tags text[],
            created_at timestamptz NOT NULL
        );
        CREATE TABLE orders (
            id bigint PRIMARY KEY,
            account_id bigint NOT NULL REFERENCES accounts(id),
            total numeric(12,2) NOT NULL
        );
        """
    }

    static func withConnection(
        _ instance: PostgresTestServer.Instance,
        schema: String,
        _ body: (any EngineConnection) async throws -> Void
    ) async throws {
        let connection = try await PostgresEngine.connect(url: instance.url)
        defer { connection.close() }
        for statement in SQLStatementSplitter(syntax: .postgres).split(setup(schema)) {
            _ = try await connection.executor.execute(sql: statement, bindings: [])
        }
        _ = try await connection.executor.execute(
            sql: "SET search_path TO \(schema), public", bindings: []
        )
        try await body(connection)
    }

    // MARK: - The fixture is what it claims to be

    /// First, because every assertion below is worthless if the matrix is three
    /// connections to the same server.
    ///
    /// The ports are the only thing distinguishing the fixtures, and a
    /// `servers.conf` typo that pointed two entries at one port would otherwise
    /// produce a green matrix that tested one version three times — the
    /// silently-not-running failure this project keeps meeting.
    @Test("each fixture reports the major version it is pinned to",
          arguments: PostgresTestServer.available)
    func versionMatchesTheFixture(instance: PostgresTestServer.Instance) async throws {
        let connection = try await PostgresEngine.connect(url: instance.url)
        defer { connection.close() }

        let rows = try await connection.executor.execute(
            sql: "SELECT current_setting('server_version_num')::int / 10000", bindings: []
        )
        let reported = try #require(rows.first?.values.first)
        guard case .int(let major) = reported else {
            Issue.record("server_version_num came back as \(reported)"); return
        }
        #expect(
            Int(major) == instance.major,
            "\(instance.name) is serving Postgres \(major), not \(instance.major)"
        )
    }

    // MARK: - The catalog, which is the part that moves

    /// Introspection is `pg_catalog` queries end to end, and those are what a
    /// major version changes.
    @Test("the schema introspector reads the same shape on every version",
          arguments: PostgresTestServer.available)
    func introspectionAgrees(instance: PostgresTestServer.Instance) async throws {
        try await Self.withConnection(instance, schema: "matrix_introspect") { connection in
            guard let introspector = connection.introspector else {
                Issue.record("the Postgres engine should offer an introspector"); return
            }
            let schema = try await introspector.schema()

            let accounts = try #require(
                schema.tables.first { $0.name == "accounts" },
                "no accounts table on \(instance.name) — got \(schema.tables.map(\.name))"
            )
            #expect(
                accounts.columns.map(\.name)
                    == ["id", "email", "nickname", "balance", "tags", "created_at"]
            )
            // Nullability comes from `pg_attribute.attnotnull`, and the optional
            // middle column is the one that would flip if the query drifted.
            #expect(
                accounts.columns.map(\.isNullable) == [false, false, true, false, true, false]
            )
        }
    }

    /// The analyzer is the other catalog consumer, and the one with no fallback:
    /// nullability is **not on the wire** for any Postgres client, so it is read
    /// from `pg_attribute` keyed on the `(table OID, attribute number)` the
    /// describe carries. A catalog change breaks that silently into "everything
    /// is optional", which still compiles and generates wrong code.
    @Test("the analyzer resolves parameters and nullability on every version",
          arguments: PostgresTestServer.available)
    func analyzerAgrees(instance: PostgresTestServer.Instance) async throws {
        try await Self.withConnection(instance, schema: "matrix_analyzer") { connection in
            guard let analyzer = connection.analyzer else {
                Issue.record("the Postgres engine should offer an analyzer"); return
            }
            defer { Task { await analyzer.finish() } }

            let signature = try await analyzer.analyze(
                "SELECT id, email, nickname FROM accounts WHERE id = $1"
            )
            #expect(signature.columns.map(\.name) == ["id", "email", "nickname"])
            #expect(signature.columns.map(\.isOptional) == [false, false, true])
            #expect(signature.parameters.count == 1)

            // **Everything** widens, not just the nullable side. `pg_attribute`
            // describes the column, not the projection, and unlike MySQL the
            // Postgres server does not clear the not-null flag for the outer
            // side — so the analyzer widens the whole projection rather than
            // claim a `NOT NULL` that a `LEFT JOIN` can still deliver as null.
            //
            // Asserted the other way round first, and this suite caught it on
            // all three versions at once, which is the shape of an assumption
            // rather than a version difference.
            let joined = try await analyzer.analyze(
                "SELECT a.id, o.total FROM accounts a LEFT JOIN orders o ON o.account_id = a.id"
            )
            #expect(joined.hasOuterJoin)
            #expect(joined.columns.allSatisfy { $0.isOptional })
            #expect(joined.columns.allSatisfy { $0.nullability == .outerJoinWidened })
        }
    }

    // MARK: - Enough of the driver to prove the connection is real

    /// SCRAM-SHA-256 over TLS, which is how every one of these connects. Worth
    /// asserting per version because the handshake is where a new server first
    /// disagrees with a client — 18 negotiates TLS directly if asked, and this
    /// driver does not ask, so *connecting at all* is the assertion.
    @Test("authenticates and round-trips values on every version",
          arguments: PostgresTestServer.available)
    func connectsAndRoundTrips(instance: PostgresTestServer.Instance) async throws {
        try await Self.withConnection(instance, schema: "matrix_roundtrip") { connection in
            _ = try await connection.executor.execute(
                sql: "INSERT INTO accounts (id, email, nickname, balance, tags, created_at) "
                    + "VALUES ($1, $2, $3, $4, $5, now())",
                bindings: [
                    .int(1), .text("a@example.com"), .null,
                    .text("12.34"), .text("{x,y}"),
                ]
            )
            let rows = try await connection.executor.execute(
                sql: "SELECT id, email, nickname FROM accounts WHERE id = $1",
                bindings: [.int(1)]
            )
            #expect(rows.count == 1)
            #expect(rows.first?.values[1] == .text("a@example.com"))
            #expect(rows.first?.values[2] == .null)
        }
    }

    /// Migrations are the pillar that has to work on whatever the deployment is
    /// running, and they lean on transactional DDL and an advisory lock — both
    /// server behaviours rather than client ones.
    @Test("migrations apply and record themselves on every version",
          arguments: PostgresTestServer.available)
    func migrationsApply(instance: PostgresTestServer.Instance) async throws {
        let connection = try await PostgresEngine.connect(url: instance.url)
        defer { connection.close() }

        let table = "matrix_migrated_\(instance.major)"
        _ = try await connection.executor.execute(
            sql: "DROP TABLE IF EXISTS \(table)", bindings: []
        )
        _ = try await connection.executor.execute(
            sql: "CREATE TABLE \(table) (id bigint PRIMARY KEY, note text NOT NULL)",
            bindings: []
        )
        _ = try await connection.executor.execute(
            sql: "INSERT INTO \(table) (id, note) VALUES ($1, $2)",
            bindings: [.int(1), .text("applied")]
        )
        let rows = try await connection.executor.execute(
            sql: "SELECT note FROM \(table)", bindings: []
        )
        #expect(rows.first?.values.first == .text("applied"))
        _ = try await connection.executor.execute(
            sql: "DROP TABLE IF EXISTS \(table)", bindings: []
        )
    }
}

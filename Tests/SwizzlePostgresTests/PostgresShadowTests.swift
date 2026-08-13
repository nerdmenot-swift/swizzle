import SwizzleCore
import SwizzleMigrate
import SwizzlePostgres
import Testing

@Suite(
    "Postgres shadow database", .serialized,
    .enabled(if: PostgresTestServer.isAvailable, PostgresTestServer.skipReason)
)
struct PostgresShadowTests {

    static let url = "postgres://swizzle:swizzlepass@127.0.0.1:5432/swizzle_test?sslmode=require"

    // MARK: - Naming, which is the guard rail

    /// A label is a directory name or a test name, so it cannot be assumed to be
    /// a valid identifier already.
    @Test("a label becomes a safe identifier")
    func naming() {
        #expect(PostgresEngine.shadowName("codegen") == "swizzle_shadow_codegen")
        #expect(PostgresEngine.shadowName("My Queries!") == "swizzle_shadow_my_queries_")
        #expect(PostgresEngine.shadowName("a-b.c") == "swizzle_shadow_a_b_c")
    }

    /// Postgres truncates identifiers at 63 bytes **silently**. Two shadows whose
    /// names differ only past the limit would be the same database, so the trim
    /// happens where it can be seen.
    @Test("names are trimmed to what Postgres will actually store")
    func nameLength() {
        let name = PostgresEngine.shadowName(String(repeating: "x", count: 200))
        #expect(name.count == 63)
        #expect(PostgresEngine.isShadowName(name))
    }

    /// `destroy()` drops a database. The prefix check is the thing standing
    /// between a mangled label and someone's real data.
    @Test("only prefixed names are recognised as shadows")
    func prefixGuard() {
        #expect(PostgresEngine.isShadowName("swizzle_shadow_x"))
        #expect(!PostgresEngine.isShadowName("swizzle_shadow_"))
        #expect(!PostgresEngine.isShadowName("production"))
        #expect(!PostgresEngine.isShadowName("my_swizzle_shadow_x"))
    }

    @Test("an identifier with a quote in it is escaped, not injected")
    func quoting() {
        #expect(PostgresEngine.quoteIdentifier("a\"b") == "\"a\"\"b\"")
    }

    // MARK: - Against a real server

    @Test("a shadow is created, usable, and dropped")
    func lifecycle() async throws {
        let shadow = try await PostgresEngine.makeShadow(url: Self.url, label: "lifecycle")
        let name = PostgresEngine.shadowName("lifecycle")

        // It is a real database, and it is empty — which is the point: it stands
        // in for production's *schema*, not its data.
        _ = try await shadow.connection.executor.execute(
            sql: "CREATE TABLE probe (id bigint PRIMARY KEY)", bindings: []
        )
        let rows = try await shadow.connection.executor.execute(
            sql: "SELECT current_database()", bindings: []
        )
        #expect(rows.first?.values.first == .text(name))

        await shadow.destroy()

        // And it is gone. Checked from a connection that was never part of it.
        let outside = try await PostgresEngine.connect(url: Self.url)
        defer { outside.close() }
        let remaining = try await outside.executor.execute(
            sql: "SELECT count(*) FROM pg_database WHERE datname = $1", bindings: [.text(name)]
        )
        #expect(remaining.first?.values.first == .int(0))
    }

    /// The runner destroys on both the success and the failure path, so this has
    /// to be idempotent rather than merely tolerable.
    @Test("destroying twice is safe")
    func destroyTwice() async throws {
        let shadow = try await PostgresEngine.makeShadow(url: Self.url, label: "twice")
        await shadow.destroy()
        await shadow.destroy()
    }

    /// A previous run that died before its cleanup must not block the next one —
    /// otherwise one interrupted generate poisons the workspace until somebody
    /// drops the database by hand.
    @Test("a leftover shadow from a dead run is replaced")
    func replacesLeftover() async throws {
        let first = try await PostgresEngine.makeShadow(url: Self.url, label: "leftover")
        // Close the connection *without* destroying, which is what a killed
        // process leaves behind.
        first.connection.close()

        let second = try await PostgresEngine.makeShadow(url: Self.url, label: "leftover")
        _ = try await second.connection.executor.execute(
            sql: "CREATE TABLE probe (id bigint)", bindings: []
        )
        await second.destroy()
        await first.destroy()
    }

    /// The whole reason the shadow exists: migrations run into it, and the
    /// analyzer describes against the schema they produced — without touching the
    /// database the URL points at.
    @Test("migrations apply into the shadow and the analyzer sees them")
    func migratedShadowIsAnalyzable() async throws {
        let shadow = try await PostgresEngine.makeShadow(url: Self.url, label: "migrated")
        defer { Task { await shadow.destroy() } }

        _ = try await shadow.connection.executor.execute(
            sql: """
                CREATE TABLE accounts (
                    id bigint PRIMARY KEY,
                    email text NOT NULL,
                    nickname text
                )
                """,
            bindings: []
        )

        guard let analyzer = shadow.connection.analyzer else {
            Issue.record("the shadow connection should offer an analyzer"); return
        }
        let signature = try await analyzer.analyze(
            "SELECT id, email, nickname FROM accounts WHERE id = $1"
        )
        await analyzer.finish()

        #expect(signature.columns.map(\.isOptional) == [false, false, true])
        #expect(signature.parameters.map(\.swiftType) == [.int64])

        // And the real database never grew the table.
        let outside = try await PostgresEngine.connect(url: Self.url)
        defer { outside.close() }
        let present = try await outside.executor.execute(
            sql: "SELECT to_regclass('public.accounts') IS NOT NULL", bindings: []
        )
        #expect(present.first?.values.first == .bool(false))
    }
}

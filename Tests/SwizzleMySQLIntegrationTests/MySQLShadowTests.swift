import SwizzleCore
import SwizzleMigrate
import SwizzleMySQL
import SwizzleMySQLEngine
import Testing

@Suite(
    "MySQL shadow database", .serialized,
    .enabled(if: TestServers.isAvailable, "Integration servers not reachable")
)
struct MySQLShadowTests {

    /// The fixture's general-purpose user. Creating and dropping a database needs
    /// `CREATE`/`DROP` at the server level, which the fixtures grant it.
    static var url: String {
        let server = TestServers.mariadb114
        let user = server.primaryUser
        return "mysql://\(user.name):\(user.password)@\(TestServers.host):\(server.port)"
            + "/\(TestServers.database)?tls=require&allow_public_key_retrieval=true"
    }

    // MARK: - Naming, which is the guard rail

    @Test("a label becomes a safe identifier")
    func naming() {
        #expect(MySQLEngine.shadowName("codegen") == "swizzle_shadow_codegen")
        #expect(MySQLEngine.shadowName("My Queries!") == "swizzle_shadow_my_queries_")
    }

    /// MySQL's identifier limit is 64 and Postgres's is 63. Trimmed to 63 on both
    /// so a project generating against the two engines cannot end up with names
    /// that agree on one and collide on the other.
    @Test("names are trimmed to the shorter of the two engines' limits")
    func nameLength() {
        #expect(MySQLEngine.shadowName(String(repeating: "x", count: 200)).count == 63)
    }

    /// `destroy()` drops a database. The prefix check is what stands between a
    /// mangled label and someone's real data.
    @Test("only prefixed names are recognised as shadows")
    func prefixGuard() {
        #expect(MySQLEngine.isShadowName("swizzle_shadow_x"))
        #expect(!MySQLEngine.isShadowName("swizzle_shadow_"))
        #expect(!MySQLEngine.isShadowName("production"))
    }

    /// Backticks, doubled to escape — MySQL's own rule.
    @Test("an identifier with a backtick in it is escaped, not injected")
    func quoting() {
        #expect(MySQLEngine.quoteIdentifier("a`b") == "`a``b`")
        #expect(
            MySQLEngine.quoteIdentifier("x`; DROP DATABASE prod; --") == "`x``; DROP DATABASE prod; --`"
        )
    }

    // MARK: - Against a real server

    @Test("a shadow is created, usable, and dropped")
    func lifecycle() async throws {
        let shadow = try await MySQLEngine.makeShadow(url: Self.url, label: "lifecycle")
        let name = MySQLEngine.shadowName("lifecycle")

        _ = try await shadow.connection.executor.execute(
            sql: "CREATE TABLE probe (id BIGINT PRIMARY KEY)", bindings: []
        )
        let current = try await shadow.connection.executor.execute(
            sql: "SELECT DATABASE()", bindings: []
        )
        #expect(current.first?.values.first == .text(name))

        await shadow.destroy()

        let outside = try await MySQLEngine.connect(url: Self.url)
        defer { outside.close() }
        let remaining = try await outside.executor.execute(
            sql: "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = ?",
            bindings: [.text(name)]
        )
        #expect(remaining.first?.values.first == .int(0))
    }

    @Test("destroying twice is safe")
    func destroyTwice() async throws {
        let shadow = try await MySQLEngine.makeShadow(url: Self.url, label: "twice")
        await shadow.destroy()
        await shadow.destroy()
    }

    /// A run that died before its cleanup must not block the next one.
    @Test("a leftover shadow from a dead run is replaced")
    func replacesLeftover() async throws {
        let first = try await MySQLEngine.makeShadow(url: Self.url, label: "leftover")
        first.connection.close()

        let second = try await MySQLEngine.makeShadow(url: Self.url, label: "leftover")
        _ = try await second.connection.executor.execute(
            sql: "CREATE TABLE probe (id BIGINT)", bindings: []
        )
        await second.destroy()
        await first.destroy()
    }

    /// **The reason this is a separate connection rather than a `USE`.**
    ///
    /// A prepared statement resolves its unqualified table names against the
    /// database that was current when it was *prepared*, and the driver caches
    /// prepared statements per session. After a `USE`, the cache would still hold
    /// statements bound to the old schema — so half an analysis run would describe
    /// the shadow and half production, with nothing to say which.
    ///
    /// A fresh session has an empty cache by construction. This test proves the
    /// analyzer sees the shadow's schema and only the shadow's.
    @Test("the analyzer describes against the shadow, not the URL's database")
    func analyzerSeesTheShadow() async throws {
        let shadow = try await MySQLEngine.makeShadow(url: Self.url, label: "analyzed")
        defer { Task { await shadow.destroy() } }

        _ = try await shadow.connection.executor.execute(
            sql: """
                CREATE TABLE shadow_only (
                    id BIGINT PRIMARY KEY,
                    email VARCHAR(255) NOT NULL,
                    nickname VARCHAR(255)
                )
                """,
            bindings: []
        )

        guard let analyzer = shadow.connection.analyzer else {
            Issue.record("the shadow connection should offer an analyzer"); return
        }
        let signature = try await analyzer.analyze(
            "SELECT id, email, nickname FROM shadow_only WHERE id = ?"
        )
        await analyzer.finish()

        #expect(signature.columns.map(\.name) == ["id", "email", "nickname"])
        // MySQL computes NOT_NULL for the projected expression, so this is the
        // engine's own answer rather than a base-column lookup.
        #expect(signature.columns.map(\.isOptional) == [false, false, true])
        #expect(signature.parameters.count == 1)

        // And the table exists nowhere but the shadow.
        let outside = try await MySQLEngine.connect(url: Self.url)
        defer { outside.close() }
        let present = try await outside.executor.execute(
            sql: """
                SELECT COUNT(*) FROM information_schema.tables
                WHERE table_schema = ? AND table_name = 'shadow_only'
                """,
            bindings: [.text(TestServers.database)]
        )
        #expect(present.first?.values.first == .int(0))
    }
}

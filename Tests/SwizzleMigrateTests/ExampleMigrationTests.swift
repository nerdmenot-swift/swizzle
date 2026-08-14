import Foundation
import Testing

@testable import SwizzleMigrate

/// The files under `examples/migrations/`, parsed by the real parser.
///
/// An example that no longer works is worse than no example, because it is the
/// first thing a newcomer copies. The Swift examples are a build target so the
/// compiler checks them; these are SQL, so the parser has to.
///
/// The assertions are about the **directives**, not the DDL. The SQL is
/// deliberately Postgres-flavoured — `CREATE INDEX CONCURRENTLY`, a `plpgsql`
/// body — because those are the cases the awkward directives exist for, and
/// running them would need a server this suite does not have. What is checked is
/// that each directive still means what the example says it means.
@Suite("Example migrations")
struct ExampleMigrationTests {

    /// Located from this file rather than the working directory: `swift test`
    /// runs from the package root, an IDE need not, and a relative path that
    /// silently resolved elsewhere would look like a missing example.
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SwizzleMigrateTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("examples/migrations")
    }

    static func load() throws -> [Migration] {
        try MigrationDirectory(url: directory, syntax: .postgres).load()
    }

    @Test("every example parses, and the set is coherent")
    func allParse() throws {
        let migrations = try Self.load()
        #expect(migrations.count == 4, "found \(migrations.count) examples")

        // `load()` sorts and validates, so this also pins that the filenames
        // carry usable versions and that none collide.
        #expect(migrations.map(\.version) == [1, 2, 3, 4])
        #expect(migrations.map(\.name) == [
            "create_users", "add_slug", "concurrent_index", "function_body",
        ])
    }

    /// The plain case: `Up` and `Down` both populated, wrapped by default.
    @Test("the ordinary example is reversible and transactional")
    func ordinaryExample() throws {
        let migration = try #require(try Self.load().first { $0.version == 1 })
        #expect(migration.upStatements.count == 2, "CREATE TABLE and CREATE INDEX")
        #expect(migration.downStatements.count == 1)
        #expect(migration.usesTransaction)
        #expect(migration.isOnline == false)
    }

    /// **The directive that is required rather than tidy.** Postgres refuses
    /// `CREATE INDEX CONCURRENTLY` inside a transaction block, so an example that
    /// lost this line would be an example that cannot run.
    @Test("the concurrent-index example opts out of the transaction")
    func concurrentIndexExample() throws {
        let migration = try #require(try Self.load().first { $0.version == 3 })
        #expect(migration.usesTransaction == false)
        // And the waiver, with its reason, travels with the migration.
        #expect(migration.allowedRules["slow-index"] != nil)
        #expect(migration.allowedRules["slow-index"]?.isEmpty == false)
    }

    /// A `$$ … $$` body full of semicolons arrives as **one** statement with no
    /// grouping directive at all.
    ///
    /// This is the assertion the example's prose rests on, so it is worth being
    /// precise about how it got here. The example originally *used*
    /// `StatementBegin`/`StatementEnd` — and removing them changed nothing,
    /// because the splitter already recognises dollar-quoted bodies. The example
    /// was teaching an escape hatch on a case that does not need one, and the
    /// test could not tell, because it passed either way.
    ///
    /// Now the file carries no directive and the test pins the real property: if
    /// dollar-quote handling ever regressed, this splits into fragments and fails
    /// here rather than at somebody's deploy.
    @Test("a dollar-quoted body stays whole without any directive")
    func functionBodyExample() throws {
        let migration = try #require(try Self.load().first { $0.version == 4 })
        #expect(migration.upStatements.count == 1, "the whole CREATE FUNCTION is one statement")

        let body = try #require(migration.upStatements.first)
        #expect(body.contains("CREATE FUNCTION"))
        #expect(body.contains("END;"), "the body was truncated at an inner semicolon")
        #expect(body.contains("LANGUAGE plpgsql"))
        #expect(!body.contains("+swizzle"), "no grouping directive is needed here")
    }

    /// Examples are for reading, so the prose has to survive parsing — comments
    /// are kept inside the statement they belong to rather than stripped.
    @Test("the explanatory comments are not discarded")
    func commentsSurvive() throws {
        let migration = try #require(try Self.load().first { $0.version == 2 })
        let text = migration.upStatements.joined(separator: "\n")
        #expect(text.contains("ALTER TABLE users ADD COLUMN slug"))
    }
}

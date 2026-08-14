import Foundation
import SwizzleCore
import SwizzleExamples
import SwizzleMigrate
import SwizzleSQLite
import Testing

@testable import SwizzleGenerate
// `SQLite.createLockTable` is internal to the engine: SQLite has no advisory
// lock, so its migration lock is a table, and `SQLiteEngine.connect` is what
// creates it. These tests need a bare connection for `Queries` — which is
// generic over a concrete `SQLiteExecutor`, not the erased one `EngineConnection`
// exposes — so they create it themselves.
@testable import SwizzleSQLiteEngine

/// `examples/codegen`, regenerated and run.
///
/// The example exists to be read, and three separate things have to be true for
/// reading it to be worth anything:
///
/// 1. **It compiles.** `Generated/Queries.swift` is in the `SwizzleExamples`
///    target, so `swift build` covers this one — and it earned its place
///    immediately, catching the emitter writing `some AsyncSequence<Row, any
///    Error>`, whose second parameter needs macOS 15 against a package floor of
///    14. The only test until then compared the emitter's output to a string,
///    which is a test that the emitter agrees with itself.
/// 2. **It is current.** Committed generated code drifts the moment the emitter
///    changes, and generated code that no longer matches its generator is worse
///    than none — it is the version everyone copies.
/// 3. **It works.** Compiling proves the shapes are well formed, not that the
///    functions return the right rows.
///
/// This suite does 2 and 3. It needs no server: SQLite in memory is the shadow
/// database, which is why the generator was built here first.
// test-hygiene: no server — SQLite in memory
@Suite("Codegen example")
struct CodegenGoldenTests {

    /// `examples/codegen`, found from this file rather than from the working
    /// directory — `swift test` does not promise one.
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SwizzleGenerateTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("examples/codegen")
    }

    static var generatedFile: URL {
        root.appendingPathComponent("Generated/Queries.swift")
    }

    static var lockfile: URL {
        root.appendingPathComponent("swizzle.lock.json")
    }

    /// The migrations, as a source the migrator can run and as values the
    /// fingerprint can be taken over.
    static var migrationSource: MigrationDirectory {
        MigrationDirectory(url: root.appendingPathComponent("migrations"), syntax: .sqlite)
    }

    static var queryDirectory: QueryDirectory {
        QueryDirectory(url: root.appendingPathComponent("queries"), syntax: .sqlite)
    }

    /// Everything the CLI would do, minus the CLI.
    static func generate() async throws -> (source: String, lock: Lockfile) {
        let parsed = try queryDirectory.load()
        let migrations = try migrationSource.load()
        let fingerprint = Lockfile.fingerprint(of: migrations)

        return try await ShadowRunner.withMigratedShadow(
            engine: SQLiteEngine.self,
            url: "sqlite::memory:",
            migrations: Self.migrationSource
        ) { connection in
            let analyzer = try #require(connection.analyzer)
            let resolved = try await QueryGenerator(analyzer: analyzer).resolve(parsed)
            let source = QueryEmitter(options: .init(dialect: "SQLite")).emit(resolved)

            let lock = Lockfile(
                engine: "sqlite", schemaFingerprint: fingerprint,
                queries: zip(parsed, resolved).map { declaration, resolved in
                    Lockfile.Entry(
                        name: declaration.name, file: declaration.file,
                        key: Lockfile.key(
                            for: declaration, engine: "sqlite",
                            schemaFingerprint: fingerprint,
                            generatorVersion: Lockfile.generatorVersion
                        ),
                        signature: resolved.signature
                    )
                }
            )
            return (source, lock)
        }
    }

    // MARK: - Still current

    @Test("the committed Swift is what the generator produces today")
    func generatedFileIsCurrent() async throws {
        let (source, _) = try await Self.generate()
        let committed = try String(contentsOf: Self.generatedFile, encoding: .utf8)
        #expect(
            source == committed,
            """
            examples/codegen/Generated/Queries.swift is stale.

            Regenerate it:
              swift build --product swizzle
              cd examples/codegen && ../../.build/debug/swizzle generate queries \
            --url sqlite:notes.db -q queries -d migrations \
            -o Generated/Queries.swift --lockfile swizzle.lock.json
            """
        )
    }

    @Test("the committed lockfile is what the generator produces today")
    func lockfileIsCurrent() async throws {
        let (_, lock) = try await Self.generate()
        let committed = try String(contentsOf: Self.lockfile, encoding: .utf8)
        #expect(String(decoding: try lock.encoded(), as: UTF8.self) == committed)
    }

    /// The check CI would run, against the committed files, with no database.
    @Test("--verify passes against the committed tree")
    func verifyIsClean() throws {
        let lock = try Lockfile.read(from: Self.lockfile.path)
        let parsed = try Self.queryDirectory.load()
        let migrations = try Self.migrationSource.load()

        let result = lock.verify(against: parsed, migrations: migrations, engine: "sqlite")
        #expect(result.isClean, "\(result.report)")
    }

    /// And that it is not clean for the wrong reason — a `verify` that passes on
    /// anything would pass here too.
    @Test("--verify fails when a query is edited without regenerating")
    func verifyCatchesAnEdit() throws {
        let lock = try Lockfile.read(from: Self.lockfile.path)
        let migrations = try Self.migrationSource.load()
        var parsed = try Self.queryDirectory.load()
        parsed[0].sql += " LIMIT 1"

        let result = lock.verify(against: parsed, migrations: migrations, engine: "sqlite")
        #expect(!result.isClean)
    }

    // MARK: - And it works

    /// The generated functions, called.
    ///
    /// Compiling proves the shapes are well formed. It does not prove
    /// `row.values[2]` is the column the struct says it is, that a `LEFT JOIN`
    /// row with no match decodes, or that `:exec` counts what it claims.
    @Test("the generated functions run against a real database")
    func generatedCodeRuns() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }

        let migrator = Migrator(
            executor: connection.executor.erased,
            dialect: AnyMigrationDialect(SQLite.self),
            source: Self.migrationSource
        )
        _ = try await connection.query(SQLite.createLockTable())
        _ = try await migrator.up()

        _ = try await connection.query("INSERT INTO authors VALUES (1, 'Ada')")
        _ = try await connection.query(
            "INSERT INTO notes VALUES (1, 1, 'First', 'a body')"
        )
        // A second note with a null body, so the optional column is exercised as
        // something other than "always present".
        _ = try await connection.query("INSERT INTO notes VALUES (2, 1, 'Second', NULL)")

        let queries = Queries(connection.executor)

        // `:one`, and the nullability the database reported rather than anyone
        // declared.
        let first = try #require(try await queries.getNote(id: 1))
        #expect(first.id == 1)
        #expect(first.title == "First")
        #expect(first.body == "a body")
        #expect(try await queries.getNote(id: 2)?.body == nil)
        // A `:one` with no matching row is nil rather than an error.
        #expect(try await queries.getNote(id: 99) == nil)

        // `:many`.
        #expect(try await queries.listByAuthor(authorID: 1).map(\.title) == ["First", "Second"])

        // The `Type` directive, all the way through: SQLite could not type this
        // column, the file said `Int64`, and this is `Int64`.
        #expect(try await queries.countNotes() == 2)

        // The `NotNull` directive, and the widening it corrects. `name` stays
        // optional because it is on the right of the outer join.
        let joined = try await queries.notesWithAuthor()
        #expect(joined.map(\.title) == ["First", "Second"])
        #expect(joined.allSatisfy { $0.name == "Ada" })

        // `:stream`.
        var streamed: [String] = []
        for try await title in try await queries.streamTitles() { streamed.append(title) }
        #expect(streamed == ["First", "Second"])

        // `:exec` returns rows affected, not a drained row count.
        #expect(try await queries.deleteNote(id: 2) == 1)
        #expect(try await queries.deleteNote(id: 2) == 0)
        #expect(try await queries.countNotes() == 1)
    }

    /// The outer-join row the widening exists for, which the data above never
    /// produces: `notes.author_id` is `NOT NULL` and references a real author, so
    /// `name` is always there and an always-present column would not distinguish
    /// `String?` from a decoder that ignores null.
    @Test("a LEFT JOIN with no match decodes as nil rather than throwing")
    func outerJoinMissRow() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }

        _ = try await connection.query(SQLite.createLockTable())
        _ = try await Migrator(
            executor: connection.executor.erased,
            dialect: AnyMigrationDialect(SQLite.self),
            source: Self.migrationSource
        ).up()

        // SQLite does not enforce foreign keys by default — but this driver turns
        // them on for every connection (`SQLiteConnection.swift:68`), so writing
        // an orphan takes switching them off for the one statement. Worth knowing
        // that it is the driver and not SQLite doing this; the first version of
        // this test assumed the default and failed with constraint 787.
        _ = try await connection.query("PRAGMA foreign_keys = OFF")
        _ = try await connection.query("INSERT INTO notes VALUES (1, 404, 'Orphan', NULL)")
        _ = try await connection.query("PRAGMA foreign_keys = ON")

        let row = try #require(try await Queries(connection.executor).notesWithAuthor().first)
        #expect(row.title == "Orphan")
        #expect(row.name == nil)
    }
}

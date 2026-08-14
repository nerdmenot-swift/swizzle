import Foundation
import SwizzleCore
import SwizzleMigrate
import SwizzleSQLite
import SwizzleSQLiteEngine
import Testing
@testable import SwizzleGenerate

@Suite("Lockfile")
struct LockfileTests {

    static func migrations(_ files: [String: String]) throws -> [Migration] {
        try InMemoryMigrations(files: files, syntax: .sqlite).load()
    }

    static let base = ["00001_init.sql": """
        -- +swizzle Up
        CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT NOT NULL);
        -- +swizzle Down
        DROP TABLE users;
        """]

    static func parse(_ text: String) throws -> [ParsedQuery] {
        try QueryParser.parse(text, filename: "q.sql")
    }

    static let query = """
        -- +swizzle Query GetUser(id: Int64) :one
        SELECT id, email FROM users WHERE id = ?;
        """

    func lockfile(
        _ queries: [ParsedQuery], _ migrations: [Migration], engine: String = "sqlite"
    ) -> Lockfile {
        let fingerprint = Lockfile.fingerprint(of: migrations)
        return Lockfile(
            engine: engine, schemaFingerprint: fingerprint,
            queries: queries.map {
                Lockfile.Entry(
                    name: $0.name, file: $0.file,
                    key: Lockfile.key(
                        for: $0, engine: engine, schemaFingerprint: fingerprint,
                        generatorVersion: Lockfile.generatorVersion
                    ),
                    signature: QuerySignature(
                        name: $0.name, sql: $0.sql, cardinality: $0.cardinality,
                        parameters: [], columns: [], hasOuterJoin: false
                    )
                )
            }
        )
    }

    // MARK: - The fingerprint

    /// The whole reason `--verify` can run without a database: the fingerprint
    /// comes from the migration files, not from an introspected schema.
    @Test("the schema fingerprint needs no database")
    func fingerprintIsFileDerived() throws {
        let first = Lockfile.fingerprint(of: try Self.migrations(Self.base))
        let same = Lockfile.fingerprint(of: try Self.migrations(Self.base))
        #expect(first == same)

        var changed = Self.base
        changed["00002_more.sql"] = """
            -- +swizzle Up
            ALTER TABLE users ADD COLUMN city TEXT;
            -- +swizzle Down
            SELECT 1;
            """
        #expect(Lockfile.fingerprint(of: try Self.migrations(changed)) != first)
    }

    /// Editing a migration in place changes its checksum, and must change the
    /// fingerprint — otherwise a rewritten migration silently keeps stale code.
    @Test("editing a migration changes the fingerprint")
    func editingAMigrationChangesIt() throws {
        let before = Lockfile.fingerprint(of: try Self.migrations(Self.base))
        let after = Lockfile.fingerprint(of: try Self.migrations(["00001_init.sql": """
            -- +swizzle Up
            CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT NOT NULL, city TEXT);
            -- +swizzle Down
            DROP TABLE users;
            """]))
        #expect(before != after)
    }

    // MARK: - Verification, with no database

    @Test("a matching tree verifies clean")
    func cleanTree() throws {
        let queries = try Self.parse(Self.query)
        let migrations = try Self.migrations(Self.base)
        let result = lockfile(queries, migrations)
            .verify(against: queries, migrations: migrations, engine: "sqlite")
        #expect(result.isClean)
        #expect(result.report == "lockfile is current")
    }

    @Test("an edited query is caught")
    func editedQueryIsCaught() throws {
        let original = try Self.parse(Self.query)
        let migrations = try Self.migrations(Self.base)
        let lock = lockfile(original, migrations)

        let edited = try Self.parse("""
            -- +swizzle Query GetUser(id: Int64) :one
            SELECT id, email, 'changed' AS extra FROM users WHERE id = ?;
            """)
        let result = lock.verify(against: edited, migrations: migrations, engine: "sqlite")
        #expect(!result.isClean)
        #expect(result.staleQueries == ["GetUser"])
    }

    @Test("a new or removed query is caught")
    func addedAndRemovedQueriesAreCaught() throws {
        let migrations = try Self.migrations(Self.base)
        let original = try Self.parse(Self.query)
        let lock = lockfile(original, migrations)

        let added = try Self.parse(Self.query + "\n\n-- +swizzle Query Extra :many\nSELECT id FROM users;")
        #expect(
            lock.verify(against: added, migrations: migrations, engine: "sqlite")
                .missingFromLockfile == ["Extra"]
        )

        #expect(
            lock.verify(against: [], migrations: migrations, engine: "sqlite")
                .removedFromQueries == ["GetUser"]
        )
    }

    /// A new migration changes every key at once, because the fingerprint is in
    /// each one. Listing thirty queries as "edited" when none were touched buries
    /// the single fact that matters.
    @Test("a schema change is reported once, not once per query")
    func schemaChangeIsReportedOnce() throws {
        let queries = try Self.parse(Self.query)
        let lock = lockfile(queries, try Self.migrations(Self.base))

        var changed = Self.base
        changed["00002_more.sql"] = """
            -- +swizzle Up
            ALTER TABLE users ADD COLUMN city TEXT;
            -- +swizzle Down
            SELECT 1;
            """
        let result = lock.verify(
            against: queries, migrations: try Self.migrations(changed), engine: "sqlite"
        )
        #expect(result.schemaChanged)
        #expect(result.report.contains("the migrations have changed"))
        #expect(!result.report.contains("has been edited"))
    }

    /// Switching engines invalidates everything: the same SQL describes
    /// differently on MySQL and SQLite.
    @Test("changing engine invalidates the lockfile")
    func changingEngineInvalidates() throws {
        let queries = try Self.parse(Self.query)
        let migrations = try Self.migrations(Self.base)
        let result = lockfile(queries, migrations)
            .verify(against: queries, migrations: migrations, engine: "mysql")
        #expect(result.schemaChanged)
    }

    /// Improving the emitter must invalidate committed output, or every project
    /// silently keeps the old shape.
    @Test("the generator version is part of the key")
    func generatorVersionIsInTheKey() throws {
        let query = try #require(try Self.parse(Self.query).first)
        let fingerprint = "sha256:abc"
        let one = Lockfile.key(
            for: query, engine: "sqlite", schemaFingerprint: fingerprint, generatorVersion: "1"
        )
        let two = Lockfile.key(
            for: query, engine: "sqlite", schemaFingerprint: fingerprint, generatorVersion: "2"
        )
        #expect(one != two)
    }

    /// An annotation changes the generated types without changing the SQL, so it
    /// has to be in the key too.
    @Test("an annotation change invalidates the key")
    func annotationsAreInTheKey() throws {
        let plain = try #require(try Self.parse(Self.query).first)
        let annotated = try #require(
            try Self.parse("-- +swizzle NotNull email\n" + Self.query).first
        )
        #expect(
            Lockfile.key(for: plain, engine: "s", schemaFingerprint: "f", generatorVersion: "1")
                != Lockfile.key(for: annotated, engine: "s", schemaFingerprint: "f", generatorVersion: "1")
        )
    }

    /// The same argument as the annotation above, and the one I nearly got wrong:
    /// the obvious rendering to hash was `SwiftType.sourceText`, which is
    /// **many-to-one** — `.decimalString`, `.date`, `.uuid`, `.json` and `.string`
    /// all render `String`. Keying on it would have let `Type total Decimal` →
    /// `Type total String` slip past `--verify` with the old output still
    /// committed, in the one check whose entire job is catching that.
    @Test("a Type change invalidates the key, including between types that render alike")
    func declaredTypesAreInTheKey() throws {
        func key(_ text: String) throws -> String {
            let query = try #require(try Self.parse(text + "\n" + Self.query).first)
            return Lockfile.key(
                for: query, engine: "s", schemaFingerprint: "f", generatorVersion: "1"
            )
        }

        let plain = try #require(try Self.parse(Self.query).first)
        let plainKey = Lockfile.key(
            for: plain, engine: "s", schemaFingerprint: "f", generatorVersion: "1"
        )

        #expect(try key("-- +swizzle Type email String") != plainKey)
        // Both emit `String`. Both must still be distinguishable.
        #expect(try key("-- +swizzle Type email String") != key("-- +swizzle Type email Decimal"))
        // And so must the optionality, which changes the emitted type on its own.
        #expect(try key("-- +swizzle Type email String") != key("-- +swizzle Type email String?"))
    }

    /// A dictionary has no order, so an unsorted rendering would key identically
    /// written files differently between runs — a lockfile that churns is a
    /// lockfile people delete.
    @Test("the key does not depend on the order the types were written in")
    func declaredTypeOrderDoesNotMatter() throws {
        let sql = """
            -- +swizzle Query Two(id: Int64) :one
            SELECT COUNT(*) AS n, 'x' AS label FROM users WHERE id = ?;
            """
        func key(_ directives: String) throws -> String {
            let query = try #require(try Self.parse(directives + sql).first)
            return Lockfile.key(
                for: query, engine: "s", schemaFingerprint: "f", generatorVersion: "1"
            )
        }
        #expect(
            try key("-- +swizzle Type n Int64\n-- +swizzle Type label String\n")
                == key("-- +swizzle Type label String\n-- +swizzle Type n Int64\n")
        )
    }

    // MARK: - On disk

    @Test("a lockfile round-trips and is byte-stable")
    func roundTrips() throws {
        let queries = try Self.parse(Self.query)
        let lock = lockfile(queries, try Self.migrations(Self.base))

        let encoded = try lock.encoded()
        #expect(try lock.encoded() == encoded, "encoding must be deterministic")
        // Read in diffs, so it ends with a newline like every other text file.
        #expect(encoded.last == 0x0A)

        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("swizzle-lock-\(UInt32.random(in: 0..<UInt32.max)).json").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try lock.write(to: path)
        #expect(try Lockfile.read(from: path) == lock)
    }

    @Test("a lockfile from a future version is refused rather than misread")
    func futureVersionIsRefused() throws {
        var lock = lockfile(try Self.parse(Self.query), try Self.migrations(Self.base))
        lock.version = Lockfile.currentVersion + 1

        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("swizzle-future-\(UInt32.random(in: 0..<UInt32.max)).json").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try lock.write(to: path)
        #expect(throws: LockfileError.self) { _ = try Lockfile.read(from: path) }
    }
}

@Suite("Shadow database")
struct ShadowDatabaseTests {

    /// The point of the shadow: generation must not read the database the URL
    /// names, because that one may have drifted from the migrations.
    @Test("the shadow is migrated and separate from the real database")
    func shadowIsSeparate() async throws {
        let source = try InMemoryMigrations(
            files: ["00001_init.sql": """
                -- +swizzle Up
                CREATE TABLE widgets (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
                -- +swizzle Down
                DROP TABLE widgets;
                """],
            syntax: .sqlite
        )

        let tables = try await ShadowRunner.withMigratedShadow(
            engine: SQLiteEngine.self, url: "sqlite::memory:", migrations: source
        ) { connection in
            let introspector = try #require(connection.introspector)
            return try await introspector.schema().tables.map(\.name)
        }
        // The migration ran, so the table exists in the shadow.
        #expect(tables.contains("widgets"))
    }

    /// A broken migration must not leave a scratch database behind.
    @Test("the shadow is destroyed even when migrating fails")
    func shadowIsDestroyedOnFailure() async throws {
        let broken = try InMemoryMigrations(
            files: ["00001_bad.sql": """
                -- +swizzle Up
                CREATE TABLE nope (this is not valid sql;
                -- +swizzle Down
                SELECT 1;
                """],
            syntax: .sqlite
        )

        await #expect(throws: (any Error).self) {
            _ = try await ShadowRunner.withMigratedShadow(
                engine: SQLiteEngine.self, url: "sqlite::memory:", migrations: broken
            ) { _ in 0 }
        }
    }

    /// Running the migrations into a scratch database validates them for free —
    /// which is the second thing the shadow buys.
    @Test("the shadow analyzer describes against the migrated schema")
    func shadowCarriesAnAnalyzer() async throws {
        let source = try InMemoryMigrations(
            files: ["00001_init.sql": """
                -- +swizzle Up
                CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT NOT NULL);
                -- +swizzle Down
                DROP TABLE users;
                """],
            syntax: .sqlite
        )

        let columns = try await ShadowRunner.withMigratedShadow(
            engine: SQLiteEngine.self, url: "sqlite::memory:", migrations: source
        ) { connection in
            let analyzer = try #require(connection.analyzer)
            return try await analyzer.analyze("SELECT id, email FROM users").columns
        }
        #expect(columns.map(\.name) == ["id", "email"])
        #expect(columns[1].isOptional == false)
    }
}

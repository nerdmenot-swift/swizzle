import Foundation
import SwizzleCore
import Testing
@testable import SwizzleMigrate

@Suite("Migration file format")
struct MigrationParsingTests {

    static func parse(_ text: String, filename: String = "1_test.sql") throws -> Migration {
        let (kind, name) = try MigrationParser.parseFilename(filename)
        return try MigrationParser.parse(
            text, kind: kind, name: name, filename: filename, syntax: .mysql
        )
    }

    @Test("up and down sections are separated")
    func upAndDown() throws {
        let migration = try Self.parse("""
        -- +swizzle Up
        CREATE TABLE users (id INT PRIMARY KEY);
        CREATE INDEX i ON users (id);

        -- +swizzle Down
        DROP TABLE users;
        """)

        #expect(migration.upStatements.count == 2)
        #expect(migration.upStatements[0] == "CREATE TABLE users (id INT PRIMARY KEY)")
        #expect(migration.downStatements == ["DROP TABLE users"])
        #expect(migration.isReversible)
        #expect(migration.usesTransaction)
    }

    /// Not an error. Dropping a column cannot be undone once the data is gone,
    /// and a fake `Down` that pretends otherwise is worse than none.
    @Test("a migration with no Down is valid but not reversible")
    func irreversibleMigration() throws {
        let migration = try Self.parse("-- +swizzle Up\nDROP TABLE legacy;")
        #expect(migration.upStatements.count == 1)
        #expect(migration.downStatements.isEmpty)
        #expect(!migration.isReversible)
    }

    /// Anything before the first directive is a file header, not SQL.
    @Test("text before the first section is ignored")
    func preambleIgnored() throws {
        let migration = try Self.parse("""
        -- Adds the users table.
        -- Ticket: PROJ-123

        -- +swizzle Up
        CREATE TABLE users (id INT);
        """)
        #expect(migration.upStatements == ["CREATE TABLE users (id INT)"])
    }

    @Test("a file with no Up section is refused")
    func missingUpIsRefused() {
        #expect(throws: MigrationParseError.self) {
            try Self.parse("CREATE TABLE users (id INT);")
        }
        #expect(throws: MigrationParseError.self) {
            try Self.parse("-- +swizzle Up\n\n-- +swizzle Down\nDROP TABLE users;")
        }
    }

    // MARK: - Literal blocks

    /// A `BEGIN … END` body has its own semicolons and no dollar-quoting to
    /// mark it, so it cannot be split correctly without being told.
    @Test("StatementBegin keeps a trigger body whole")
    func literalBlock() throws {
        let migration = try Self.parse("""
        -- +swizzle Up
        -- +swizzle StatementBegin
        CREATE TRIGGER t BEFORE INSERT ON users FOR EACH ROW
        BEGIN
          SET NEW.created_at = NOW();
          SET NEW.updated_at = NOW();
        END
        -- +swizzle StatementEnd
        CREATE INDEX i ON users (id);
        """)

        #expect(migration.upStatements.count == 2, "the trigger is one statement, not three")
        #expect(migration.upStatements[0].contains("SET NEW.created_at"))
        #expect(migration.upStatements[0].contains("SET NEW.updated_at"))
        #expect(migration.upStatements[1] == "CREATE INDEX i ON users (id)")
    }

    /// Free-form SQL before a literal block must keep its place in the order.
    @Test("statements around a literal block stay in order")
    func orderingAroundLiteralBlock() throws {
        let migration = try Self.parse("""
        -- +swizzle Up
        CREATE TABLE users (id INT);
        -- +swizzle StatementBegin
        CREATE PROCEDURE p() BEGIN SELECT 1; END
        -- +swizzle StatementEnd
        CREATE INDEX i ON users (id);
        """)
        #expect(migration.upStatements.count == 3)
        #expect(migration.upStatements[0].hasPrefix("CREATE TABLE"))
        #expect(migration.upStatements[1].hasPrefix("CREATE PROCEDURE"))
        #expect(migration.upStatements[2].hasPrefix("CREATE INDEX"))
    }

    @Test("an unbalanced literal block is refused")
    func unbalancedLiteralBlock() {
        #expect(throws: MigrationParseError.self) {
            try Self.parse("-- +swizzle Up\n-- +swizzle StatementBegin\nSELECT 1;")
        }
        #expect(throws: MigrationParseError.self) {
            try Self.parse("-- +swizzle Up\nSELECT 1;\n-- +swizzle StatementEnd")
        }
    }

    // MARK: - Directives

    @Test("NoTransaction is recorded")
    func noTransaction() throws {
        let migration = try Self.parse("""
        -- +swizzle NoTransaction
        -- +swizzle Up
        CREATE INDEX CONCURRENTLY i ON users (id);
        """)
        #expect(!migration.usesTransaction)
    }

    /// A typo in a directive must not be read as a comment and silently ignored
    /// — that is how a `Down` section quietly stops existing.
    @Test("an unknown directive is refused")
    func unknownDirectiveRefused() {
        #expect(throws: MigrationParseError.self) {
            try Self.parse("-- +swizzle Upp\nSELECT 1;")
        }
    }

    /// Only a line that *starts* with the marker is a directive, so the string
    /// appearing inside SQL is left alone.
    @Test("a directive-looking string inside SQL is not a directive")
    func directiveInsideSQL() throws {
        let migration = try Self.parse("""
        -- +swizzle Up
        INSERT INTO notes (body) VALUES ('-- +swizzle Down');
        """)
        #expect(migration.upStatements.count == 1)
        #expect(migration.downStatements.isEmpty)
    }

    // MARK: - Filenames

    @Test(arguments: [
        ("001_initial.sql", Int64(1), "initial"),
        ("20240615120000_add_users.sql", 20_240_615_120_000, "add_users"),
        ("7_x.sql", 7, "x"),
    ])
    func filenamesParse(filename: String, version: Int64, name: String) throws {
        let parsed = try MigrationParser.parseFilename(filename)
        #expect(parsed.kind == .versioned(version))
        #expect(parsed.name == name)
    }

    /// Rejected rather than skipped. A migration silently ignored because it was
    /// misnamed is a failure that only shows up in production.
    @Test(arguments: [
        "initial.sql", "abc_initial.sql", "_initial.sql", "1_.sql", "0_zero.sql", "-1_neg.sql",
    ])
    func malformedFilenamesAreRefused(filename: String) {
        #expect(throws: MigrationParseError.self) {
            try MigrationParser.parseFilename(filename)
        }
    }

    // MARK: - Checksums

    @Test("the checksum changes when the file does")
    func checksumTracksContent() throws {
        let a = try Self.parse("-- +swizzle Up\nSELECT 1;")
        let b = try Self.parse("-- +swizzle Up\nSELECT 1;")
        let c = try Self.parse("-- +swizzle Up\nSELECT 2;")

        #expect(a.checksum == b.checksum)
        #expect(a.checksum != c.checksum)
        #expect(a.checksum.hasPrefix("sha256:"))
    }

    /// Even a whitespace-only edit changes the checksum. That is deliberate: the
    /// point is to notice that the file is not what was applied, not to judge
    /// whether the change was meaningful.
    @Test("whitespace changes the checksum")
    func whitespaceChangesChecksum() throws {
        let a = try Self.parse("-- +swizzle Up\nSELECT 1;")
        let b = try Self.parse("-- +swizzle Up\nSELECT  1;")
        #expect(a.checksum != b.checksum)
    }
}

@Suite("Migration sources")
struct MigrationSourceTests {

    @Test("a directory loads in version order")
    func directoryLoadsInOrder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swizzle-migrate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Written out of order, and with a name that sorts before "2" as text.
        for (filename, body) in [
            ("10_third.sql", "-- +swizzle Up\nSELECT 3;"),
            ("2_second.sql", "-- +swizzle Up\nSELECT 2;"),
            ("1_first.sql", "-- +swizzle Up\nSELECT 1;"),
            ("notes.txt", "not a migration"),
            (".hidden.sql", "-- +swizzle Up\nSELECT 0;"),
        ] {
            try body.write(
                to: directory.appendingPathComponent(filename), atomically: true, encoding: .utf8
            )
        }

        let loaded = try MigrationDirectory(url: directory, syntax: .mysql).load()
        #expect(loaded.compactMap(\.version) == [1, 2, 10], "ordered numerically, not as text")
        #expect(loaded.map(\.name) == ["first", "second", "third"])
    }

    /// Two files claiming one version is ambiguous — whichever runs first
    /// decides the schema, and directory order is not a decision. Usually a
    /// branch merge that duplicated a number.
    @Test("duplicate versions are refused")
    func duplicateVersionsRefused() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swizzle-migrate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for filename in ["3_alpha.sql", "3_beta.sql"] {
            try "-- +swizzle Up\nSELECT 1;".write(
                to: directory.appendingPathComponent(filename), atomically: true, encoding: .utf8
            )
        }
        #expect(throws: MigrationParseError.self) {
            try MigrationDirectory(url: directory, syntax: .mysql).load()
        }
    }

    @Test("a missing directory is an error, not an empty set")
    func missingDirectory() {
        #expect(throws: MigrationParseError.self) {
            try MigrationDirectory(path: "/nonexistent/swizzle", syntax: .mysql).load()
        }
    }

    @Test("in-memory migrations parse and sort")
    func inMemorySource() throws {
        let source = try InMemoryMigrations(
            files: [
                "2_second.sql": "-- +swizzle Up\nSELECT 2;",
                "1_first.sql": "-- +swizzle Up\nSELECT 1;\n-- +swizzle Down\nSELECT 0;",
            ],
            syntax: .mysql
        )
        let loaded = try source.load()
        #expect(loaded.compactMap(\.version) == [1, 2])
        #expect(loaded[0].isReversible)
        #expect(!loaded[1].isReversible)
    }
}

/// Repeatable migrations — Flyway's `R__`, borrowed because it is the feature
/// most worth borrowing.
@Suite("Repeatable migrations")
struct RepeatableMigrationTests {

    static func parse(_ text: String, filename: String) throws -> Migration {
        let (kind, name) = try MigrationParser.parseFilename(filename)
        return try MigrationParser.parse(
            text, kind: kind, name: name, filename: filename, syntax: .mysql
        )
    }

    @Test("R__ names a repeatable migration with no version")
    func repeatableFilename() throws {
        let parsed = try MigrationParser.parseFilename("R__user_summary.sql")
        #expect(parsed.kind == .repeatable)
        #expect(parsed.name == "user_summary")

        let migration = try Self.parse(
            "-- +swizzle Up\nCREATE OR REPLACE VIEW v AS SELECT 1;", filename: "R__v.sql"
        )
        #expect(migration.isRepeatable)
        #expect(migration.version == nil)
        #expect(migration.identifier == "R__v")
    }

    @Test("R__ with no name is refused")
    func repeatableNeedsAName() {
        #expect(throws: MigrationParseError.self) {
            try MigrationParser.parseFilename("R__.sql")
        }
    }

    /// A repeatable migration re-runs whenever it changes, so a Down section has
    /// no moment at which it could run.
    @Test("a repeatable migration cannot declare a Down section")
    func repeatableRejectsDown() {
        #expect(throws: MigrationParseError.self) {
            try Self.parse(
                "-- +swizzle Up\nCREATE VIEW v AS SELECT 1;\n-- +swizzle Down\nDROP VIEW v;",
                filename: "R__v.sql"
            )
        }
    }

    /// Repeatable last is load-bearing: a view almost always depends on tables a
    /// versioned migration just created, so running it first would fail.
    @Test("repeatable migrations sort after every versioned one")
    func orderingPutsRepeatableLast() throws {
        let source = try InMemoryMigrations(
            files: [
                "R__zebra.sql": "-- +swizzle Up\nCREATE VIEW z AS SELECT 1;",
                "R__alpha.sql": "-- +swizzle Up\nCREATE VIEW a AS SELECT 1;",
                "2_second.sql": "-- +swizzle Up\nSELECT 2;",
                "1_first.sql": "-- +swizzle Up\nSELECT 1;",
            ],
            syntax: .mysql
        )
        let loaded = try source.load()
        #expect(loaded.map(\.identifier) == ["1", "2", "R__alpha", "R__zebra"])
    }

    /// A repeatable and a versioned migration can share a name without clashing,
    /// because the journal keys on the identifier rather than the name.
    @Test("identifiers do not collide across kinds")
    func identifiersDoNotCollide() throws {
        let versioned = try Self.parse("-- +swizzle Up\nSELECT 1;", filename: "1_views.sql")
        let repeatable = try Self.parse("-- +swizzle Up\nSELECT 1;", filename: "R__views.sql")
        #expect(versioned.identifier != repeatable.identifier)
    }
}

/// The key-column guard on `batches(over:)`.
///
/// Paging on the wrong column is silent — wrong rows, possibly forever — so the
/// mistake is caught at the call rather than diagnosed later from bad data.
@Suite("Batch key checking")
struct BatchKeyTests {

    @Test(arguments: [
        ("id, title", "id"),
        ("  id ,title", "id"),
        ("posts.id, title", "id"),
        ("id, title", "posts.id"),
        ("ID, title", "id"),
    ])
    func acceptsTheKeyFirst(columns: String, key: String) throws {
        try MigrationContextChecks.checkKeyIsFirst(columns, key)
    }

    /// Cases the string cannot settle, which must not produce false alarms.
    @Test(arguments: [
        ("*", "id"),
        ("COUNT(id), title", "id"),
        ("title AS id, x", "id"),
        ("", "id"),
    ])
    func staysQuietWhenItCannotTell(columns: String, key: String) throws {
        try MigrationContextChecks.checkKeyIsFirst(columns, key)
    }

    /// The mismatch is refused — and refused by *throwing*, so a migration that
    /// names the wrong column fails the migration rather than trapping the host
    /// process.
    @Test("a key that is not first is refused, not trapped")
    func mismatchThrows() {
        #expect(throws: MigrationContextError.self) {
            try MigrationContextChecks.checkKeyIsFirst("title, id", "id")
        }
    }
}

/// Reaches the internal check without needing a database.
enum MigrationContextChecks {
    static func checkKeyIsFirst(_ columns: String, _ key: String) throws {
        try NoopContext.checkKeyIsFirst(columns, key)
    }
}

struct NoopContext: MigrationContext {
    func execute(_ sql: String, _ bindings: [SQLValue]) async throws -> [SQLRow] { [] }
    func executeUpdate(_ sql: String, _ bindings: [SQLValue]) async throws -> Int { 0 }
}

/// Two migrations claiming one version, whichever source they came from.
///
/// The journal keys on the identifier, so the first records it and the second
/// then looks *already applied* — it never runs and never shows as pending.
/// The check used to live only in `MigrationDirectory`, so embedding the same
/// pair into an `InMemoryMigrations` slipped past it.
@Suite("Duplicate versions")
struct DuplicateVersionTests {

    @Test("in-memory migrations refuse a duplicate version")
    func inMemoryRefuses() {
        #expect(throws: MigrationParseError.self) {
            try InMemoryMigrations(files: [
                "3_alpha.sql": "-- +swizzle Up\nSELECT 1;",
                "3_beta.sql": "-- +swizzle Up\nSELECT 2;",
            ], syntax: .mysql)
        }
    }

    @Test("distinct versions are fine")
    func distinctIsFine() throws {
        let source = try InMemoryMigrations(files: [
            "3_alpha.sql": "-- +swizzle Up\nSELECT 1;",
            "4_beta.sql": "-- +swizzle Up\nSELECT 2;",
        ], syntax: .mysql)
        #expect(try source.load().count == 2)
    }

    /// A repeatable and a versioned migration may share a *name*, because the
    /// identifier is what the journal keys on.
    @Test("the two kinds do not collide")
    func kindsDoNotCollide() throws {
        let source = try InMemoryMigrations(files: [
            "3_views.sql": "-- +swizzle Up\nSELECT 1;",
            "R__views.sql": "-- +swizzle Up\nSELECT 2;",
        ], syntax: .mysql)
        #expect(try source.load().count == 2)
    }
}

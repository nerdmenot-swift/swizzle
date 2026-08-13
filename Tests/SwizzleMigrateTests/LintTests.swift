import SwizzleCore
import Testing
@testable import SwizzleMigrate

/// The statement recogniser.
///
/// Not a SQL parser and not trying to be — every rule keys off leading keywords
/// and a table name. These pin the shapes people actually write, including the
/// ones that look like a column operation and are not.
@Suite("Statement recognition")
struct ParsedStatementTests {

    @Test(arguments: [
        ("CREATE TABLE users (id INT)", "users"),
        ("CREATE TABLE IF NOT EXISTS `users` (id INT)", "users"),
        ("create table users (id int)", "users"),
    ])
    func recognisesCreateTable(sql: String, table: String) {
        #expect(ParsedStatement.parse(sql).operation == .createTable(table: table))
    }

    @Test(arguments: [
        "DROP TABLE users", "DROP TABLE IF EXISTS `users`", "drop table users",
    ])
    func recognisesDropTable(sql: String) {
        #expect(ParsedStatement.parse(sql).operation == .dropTable(table: "users"))
    }

    @Test("recognises a column drop")
    func recognisesDropColumn() {
        #expect(
            ParsedStatement.parse("ALTER TABLE users DROP COLUMN email").operation
                == .dropColumn(table: "users", column: "email")
        )
        #expect(
            ParsedStatement.parse("ALTER TABLE `users` DROP `email`").operation
                == .dropColumn(table: "users", column: "email")
        )
    }

    /// `DROP INDEX` and `DROP FOREIGN KEY` are not column drops, and treating
    /// them as such would fire the most severe rule on a harmless statement.
    @Test(arguments: [
        "ALTER TABLE users DROP INDEX idx_email",
        "ALTER TABLE users DROP KEY idx_email",
        "ALTER TABLE users DROP PRIMARY KEY",
        "ALTER TABLE users DROP FOREIGN KEY fk_org",
    ])
    func indexDropsAreNotColumnDrops(sql: String) {
        let parsed = ParsedStatement.parse(sql)
        if case .dropColumn = parsed.operation {
            Issue.record("\(sql) was read as a column drop")
        }
    }

    @Test("recognises added columns and their nullability")
    func recognisesAddColumn() {
        #expect(
            ParsedStatement.parse("ALTER TABLE users ADD COLUMN age INT NOT NULL").operation
                == .addColumn(table: "users", column: "age", nullable: false, hasDefault: false)
        )
        #expect(
            ParsedStatement.parse("ALTER TABLE users ADD COLUMN age INT NOT NULL DEFAULT 0")
                .operation
                == .addColumn(table: "users", column: "age", nullable: false, hasDefault: true)
        )
        #expect(
            ParsedStatement.parse("ALTER TABLE users ADD age INT").operation
                == .addColumn(table: "users", column: "age", nullable: true, hasDefault: false)
        )
    }

    /// `ADD INDEX` shares the `ADD` prefix with a column and must not be read as
    /// adding a column called "INDEX".
    @Test(arguments: [
        "ALTER TABLE users ADD INDEX idx (email)",
        "ALTER TABLE users ADD UNIQUE KEY u (email)",
        "ALTER TABLE users ADD CONSTRAINT fk FOREIGN KEY (org) REFERENCES orgs(id)",
    ])
    func addIndexIsNotAddColumn(sql: String) {
        if case .addColumn = ParsedStatement.parse(sql).operation {
            Issue.record("\(sql) was read as a column add")
        }
    }

    @Test("recognises CREATE INDEX and its table")
    func recognisesCreateIndex() {
        #expect(
            ParsedStatement.parse("CREATE INDEX idx ON users (email)").operation
                == .addIndex(table: "users", unique: false)
        )
        #expect(
            ParsedStatement.parse("CREATE UNIQUE INDEX idx ON `users` (email)").operation
                == .addIndex(table: "users", unique: true)
        )
    }

    @Test("recognises type changes and renames")
    func recognisesModifyAndRename() {
        #expect(
            ParsedStatement.parse("ALTER TABLE users MODIFY COLUMN age BIGINT").operation
                == .modifyColumn(table: "users", column: "age")
        )
        #expect(
            ParsedStatement.parse("ALTER TABLE users RENAME COLUMN a TO b").operation
                == .renameColumn(table: "users", from: "a")
        )
    }

    /// Comments and layout must not change what is recognised — a migration is
    /// usually written across several lines with a comment above it.
    @Test("comments and line breaks are ignored")
    func normalisation() {
        let sql = """
            -- why we are doing this
            ALTER TABLE users
                DROP COLUMN /* the old one */ email
            """
        #expect(
            ParsedStatement.parse(sql).operation == .dropColumn(table: "users", column: "email")
        )
    }

    @Test("a plain query is not DDL")
    func selectIsNotDDL() {
        #expect(ParsedStatement.parse("SELECT * FROM users").operation == .other)
    }
}

@Suite("Lint rules")
struct LintRuleTests {

    static func migration(_ statements: [String], name: String = "test") -> Migration {
        Migration(
            kind: .versioned(1), name: name, up: .sql(statements), down: nil, checksum: "x"
        )
    }

    static func schema(rows: Int64, table: String = "users") -> DatabaseSchema {
        DatabaseSchema(tables: [
            TableSchema(
                name: table,
                columns: [ColumnSchema(
                    name: "id", type: "int", isNullable: false,
                    hasDefault: false, isAutoIncrement: true
                )],
                indexes: [IndexSchema(
                    name: "PRIMARY", columns: ["id"], isUnique: true, isPrimary: true
                )],
                estimatedRows: rows
            )
        ])
    }

    static func findings(
        _ statements: [String], schema: DatabaseSchema? = nil
    ) -> [LintFinding] {
        Linter().lint([migration(statements)], schema: schema)
    }

    // MARK: Destructive

    @Test("dropping a populated table is an error; an empty one is a warning")
    func dropTableSeverity() {
        let populated = Self.findings(["DROP TABLE users"], schema: Self.schema(rows: 5000))
        #expect(populated.first?.severity == .error)
        #expect(populated.first?.rule == "destructive-table")

        let empty = Self.findings(["DROP TABLE users"], schema: Self.schema(rows: 0))
        #expect(empty.first?.severity == .warning, "an empty table is cleanup, not data loss")
    }

    @Test("dropping a column is flagged")
    func dropColumn() {
        let found = Self.findings(
            ["ALTER TABLE users DROP COLUMN email"], schema: Self.schema(rows: 5000))
        #expect(found.count == 1)
        #expect(found[0].severity == .error)
        #expect(found[0].remedy.contains("stops writing it first"))
    }

    @Test("TRUNCATE is always an error")
    func truncate() {
        #expect(Self.findings(["TRUNCATE TABLE users"]).first?.severity == .error)
    }

    // MARK: Breaking

    @Test("NOT NULL with no default is an error on a populated table")
    func notNullNoDefault() {
        let found = Self.findings(
            ["ALTER TABLE users ADD COLUMN age INT NOT NULL"], schema: Self.schema(rows: 1000))
        #expect(found.first?.rule == "not-null-no-default")
        #expect(found.first?.severity == .error)
    }

    /// The reason the schema is worth fetching: on a new empty table this is
    /// completely fine, and firing an error there would train people to ignore
    /// the linter.
    @Test("NOT NULL with no default is only a warning on an empty table")
    func notNullOnEmptyTable() {
        let found = Self.findings(
            ["ALTER TABLE users ADD COLUMN age INT NOT NULL"], schema: Self.schema(rows: 0))
        #expect(found.first?.severity == .warning)
    }

    @Test("a default makes it fine")
    func notNullWithDefaultIsFine() {
        #expect(
            Self.findings(
                ["ALTER TABLE users ADD COLUMN age INT NOT NULL DEFAULT 0"],
                schema: Self.schema(rows: 1000)
            ).isEmpty
        )
    }

    @Test("renaming a column is an error")
    func renameColumn() {
        let found = Self.findings(["ALTER TABLE users RENAME COLUMN a TO b"])
        #expect(found.first?.rule == "rename-column")
        #expect(found.first?.remedy.contains("Add the new column") == true)
    }

    // MARK: Locking

    @Test("indexing a large table warns; a small one does not")
    func blockingIndex() {
        #expect(
            Self.findings(
                ["CREATE INDEX i ON users (email)"], schema: Self.schema(rows: 5_000_000)
            ).first?.rule == "blocking-index"
        )
        #expect(
            Self.findings(
                ["CREATE INDEX i ON users (email)"], schema: Self.schema(rows: 100)
            ).isEmpty,
            "a small table finishes fast enough not to matter"
        )
    }

    /// Without a database the size is unknowable, and warning on every index
    /// would make the linter noise.
    @Test("size-dependent rules stay quiet with no schema")
    func quietWithoutSchema() {
        #expect(Self.findings(["CREATE INDEX i ON users (email)"]).isEmpty)
    }

    @Test("a table with no primary key warns")
    func missingPrimaryKey() {
        #expect(
            Self.findings(["CREATE TABLE events (id INT, body TEXT)"]).first?.rule
                == "no-primary-key"
        )
        #expect(Self.findings(["CREATE TABLE events (id INT PRIMARY KEY)"]).isEmpty)
        #expect(Self.findings(["CREATE TABLE events (id INT AUTO_INCREMENT)"]).isEmpty)
    }

    // MARK: Machinery

    @Test("a rule can be turned off by name")
    func rulesCanBeDisabled() {
        let linter = Linter(disabled: ["destructive-table"])
        #expect(
            linter.lint([Self.migration(["DROP TABLE users"])], schema: Self.schema(rows: 5))
                .isEmpty
        )
    }

    @Test("every finding carries a remedy")
    func everyFindingHasARemedy() {
        let statements = [
            "DROP TABLE users", "ALTER TABLE users DROP COLUMN email",
            "ALTER TABLE users ADD COLUMN age INT NOT NULL",
            "ALTER TABLE users RENAME COLUMN a TO b",
            "CREATE INDEX i ON users (email)", "ALTER TABLE users MODIFY COLUMN age BIGINT",
            "CREATE TABLE events (id INT)", "TRUNCATE TABLE users",
        ]
        let found = Self.findings(statements, schema: Self.schema(rows: 5_000_000))
        #expect(found.count >= 7)
        // A linter that only says "no" gets turned off.
        #expect(found.allSatisfy { !$0.remedy.isEmpty })
        #expect(found.allSatisfy { !$0.message.isEmpty })
        #expect(found.allSatisfy { !$0.rule.isEmpty })
    }

    /// A Swift migration's body is a closure, so there is nothing to lint.
    @Test("a Swift migration produces no findings")
    func swiftMigrationsAreOpaque() {
        let swift = Migration(
            kind: .versioned(1), name: "code", up: .swift { _ in }, down: nil, checksum: "x"
        )
        #expect(Linter().lint([swift], schema: Self.schema(rows: 5_000_000)).isEmpty)
    }

    @Test("ordinary DDL produces nothing")
    func cleanMigrationIsQuiet() {
        #expect(
            Self.findings([
                "CREATE TABLE users (id INT AUTO_INCREMENT PRIMARY KEY, email VARCHAR(255))",
                "ALTER TABLE users ADD COLUMN nickname VARCHAR(64)",
            ]).isEmpty
        )
    }
}

/// Per-migration suppression.
///
/// Every escape hatch used to be a CLI flag, which turns a rule off for the
/// whole run and every migration in it — so the only way past one intentional
/// `DROP TABLE` was to stop checking drops entirely, forever. That is precisely
/// how a linter gets switched off.
@Suite("Allow directive")
struct AllowDirectiveTests {

    static func parse(_ text: String) throws -> Migration {
        try MigrationParser.parse(
            text, kind: .versioned(1), name: "t", filename: "1_t.sql", syntax: .mysql
        )
    }

    @Test("an allowance silences that rule for this migration only")
    func scopedToOneMigration() throws {
        let allowed = try Self.parse("""
            -- +swizzle Allow destructive-table shadow-written for two releases
            -- +swizzle Up
            DROP TABLE legacy_sessions;
            """)
        let other = try MigrationParser.parse(
            "-- +swizzle Up\nDROP TABLE something_else;",
            kind: .versioned(2), name: "u", filename: "2_u.sql", syntax: .mysql
        )

        let schema = DatabaseSchema(tables: [
            TableSchema(name: "legacy_sessions", columns: [], indexes: [], estimatedRows: 9000),
            TableSchema(name: "something_else", columns: [], indexes: [], estimatedRows: 9000),
        ])
        let findings = Linter().lint([allowed, other], schema: schema)

        // The second migration is untouched — that is the whole point.
        #expect(findings.count == 1)
        #expect(findings.first?.migration == "2_u.sql")
    }

    /// A suppression nobody has to justify is one nobody reviews.
    @Test("a reason is mandatory")
    func reasonRequired() {
        #expect(throws: MigrationParseError.self) {
            try Self.parse("-- +swizzle Allow destructive-table\n-- +swizzle Up\nDROP TABLE x;")
        }
        #expect(throws: MigrationParseError.self) {
            try Self.parse("-- +swizzle Allow\n-- +swizzle Up\nDROP TABLE x;")
        }
    }

    @Test("the reason is kept, so it can be shown")
    func reasonIsRecorded() throws {
        let migration = try Self.parse("""
            -- +swizzle Allow destructive-table replaced by events, verified empty in staging
            -- +swizzle Up
            DROP TABLE old;
            """)
        #expect(
            migration.allowedRules["destructive-table"]
                == "replaced by events, verified empty in staging"
        )
        let listed = Linter().suppressions([migration])
        #expect(listed.count == 1)
        #expect(listed[0].rule == "destructive-table")
    }

    @Test("several rules can be allowed")
    func severalRules() throws {
        let migration = try Self.parse("""
            -- +swizzle Allow destructive-column column unused since v4
            -- +swizzle Allow rename-column single-writer service, coordinated deploy
            -- +swizzle Up
            ALTER TABLE users DROP COLUMN old_flag;
            ALTER TABLE users RENAME COLUMN a TO b;
            """)
        #expect(migration.allowedRules.count == 2)
        #expect(Linter().lint([migration]).isEmpty)
    }

    /// An allowance names one rule. It must not become a blanket exemption.
    @Test("allowing one rule does not silence the others")
    func doesNotSilenceEverything() throws {
        let migration = try Self.parse("""
            -- +swizzle Allow destructive-table deliberate
            -- +swizzle Up
            DROP TABLE gone;
            ALTER TABLE users RENAME COLUMN a TO b;
            """)
        let findings = Linter().lint([migration])
        #expect(findings.count == 1)
        #expect(findings.first?.rule == "rename-column")
    }
}

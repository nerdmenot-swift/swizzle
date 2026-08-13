import Testing
@testable import SwizzleMigrate

/// Statement splitting, which is the part a naive implementation gets wrong.
///
/// Every case here is a semicolon that must **not** end a statement. The failure
/// mode if one slips through is not a clean error: the first half runs, and on
/// MySQL DDL cannot be rolled back, so the database is left in a state no
/// migration describes.
@Suite("Statement splitting")
struct SplitterTests {

    static func mysql(_ script: String) -> [String] {
        SQLStatementSplitter(syntax: .mysql).split(script)
    }
    static func postgres(_ script: String) -> [String] {
        SQLStatementSplitter(syntax: .postgres).split(script)
    }

    @Test("plain statements split on semicolons")
    func plainStatements() {
        let parts = Self.mysql("CREATE TABLE a (id INT); DROP TABLE b;")
        #expect(parts == ["CREATE TABLE a (id INT)", "DROP TABLE b"])
    }

    @Test("a trailing semicolon does not produce an empty statement")
    func trailingSemicolon() {
        #expect(Self.mysql("SELECT 1;").count == 1)
        #expect(Self.mysql("SELECT 1;\n\n").count == 1)
        #expect(Self.mysql("SELECT 1").count == 1, "the last statement need not be terminated")
    }

    @Test("an empty or comment-only script yields nothing")
    func emptyScript() {
        #expect(Self.mysql("").isEmpty)
        #expect(Self.mysql("   \n\t ").isEmpty)
        #expect(Self.mysql("-- just a comment\n").isEmpty)
        #expect(Self.mysql("/* block */\n").isEmpty)
        #expect(Self.mysql(";;;").isEmpty)
    }

    // MARK: - Semicolons that are not boundaries

    @Test("a semicolon inside a string literal is data")
    func semicolonInString() {
        let parts = Self.mysql("INSERT INTO t VALUES ('a;b'); SELECT 1;")
        #expect(parts.count == 2)
        #expect(parts[0] == "INSERT INTO t VALUES ('a;b')")
    }

    @Test("a doubled quote does not end the string")
    func doubledQuote() {
        let parts = Self.mysql("INSERT INTO t VALUES ('it''s; fine'); SELECT 1;")
        #expect(parts.count == 2)
        #expect(parts[0].contains("it''s; fine"))
    }

    /// MySQL treats `\'` as an escaped quote; standard SQL treats the backslash
    /// as an ordinary character, so the string ends one quote earlier.
    ///
    /// The two dialects therefore split the *same text* at different places, and
    /// this asserts where rather than merely how many — a count would pass by
    /// coincidence.
    @Test("backslash escapes are honoured only where the dialect has them")
    func backslashEscapes() {
        let script = "INSERT INTO t VALUES ('a\\'; b'); SELECT 1;"

        // MySQL: `\'` is escaped, so the literal runs to the second quote and
        // the whole INSERT survives intact.
        let mysqlParts = Self.mysql(script)
        #expect(mysqlParts.count == 2)
        #expect(mysqlParts[0] == "INSERT INTO t VALUES ('a\\'; b')")

        // Postgres: the backslash is literal, so the string is `'a\'` and the
        // very next `;` is a boundary — cutting the statement in a place MySQL
        // does not. Applying MySQL's rule here would run past the true end of
        // the literal and swallow the rest of the file.
        let postgresParts = Self.postgres(script)
        #expect(postgresParts[0] == "INSERT INTO t VALUES ('a\\'")
        #expect(postgresParts[0] != mysqlParts[0], "the dialects must disagree here")
    }

    @Test("a semicolon inside a line comment is ignored")
    func semicolonInLineComment() {
        let parts = Self.mysql("SELECT 1; -- trailing; comment\nSELECT 2;")
        #expect(parts.count == 2)
    }

    @Test("a semicolon inside a block comment is ignored")
    func semicolonInBlockComment() {
        let parts = Self.mysql("SELECT 1 /* a; b */; SELECT 2;")
        #expect(parts.count == 2)
        #expect(parts[0].contains("/* a; b */"))
    }

    @Test("MySQL hash comments are comments")
    func hashComments() {
        #expect(Self.mysql("SELECT 1; # a; b\nSELECT 2;").count == 2)
        // Postgres has no `#` comment, so there the `;` is real.
        #expect(Self.postgres("SELECT 1; # a; b\nSELECT 2;").count == 3)
    }

    @Test("a semicolon inside a quoted identifier is ignored")
    func semicolonInIdentifier() {
        #expect(Self.mysql("CREATE TABLE `we;ird` (id INT); SELECT 1;").count == 2)
        #expect(Self.postgres("CREATE TABLE \"we;ird\" (id INT); SELECT 1;").count == 2)
    }

    /// Postgres function bodies are dollar-quoted and full of semicolons. This
    /// is the single most common way a splitter breaks in the wild.
    @Test("a dollar-quoted body is one statement")
    func dollarQuotedBody() {
        let script = """
        CREATE FUNCTION bump() RETURNS trigger AS $$
        BEGIN
          NEW.updated_at = now();
          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
        SELECT 1;
        """
        let parts = Self.postgres(script)
        #expect(parts.count == 2, "got \(parts.count): \(parts)")
        #expect(parts[0].contains("RETURN NEW;"))
    }

    @Test("a tagged dollar quote is matched by its tag")
    func taggedDollarQuote() {
        let script = "SELECT $tag$ a; $$ still inside $tag$; SELECT 2;"
        let parts = Self.postgres(script)
        #expect(parts.count == 2, "got \(parts)")
    }

    /// `$1` is a placeholder and must not start a dollar quote, or everything
    /// after it would be swallowed.
    @Test("a numeric placeholder is not a dollar quote")
    func placeholderIsNotADollarQuote() {
        let parts = Self.postgres("SELECT * FROM t WHERE a = $1; SELECT 2;")
        #expect(parts.count == 2, "got \(parts)")
    }

    @Test("dollar quoting is off for dialects that lack it")
    func dollarQuotingIsDialectSpecific() {
        // MySQL has no dollar quoting, so these are ordinary characters and both
        // semicolons are boundaries.
        #expect(Self.mysql("SELECT $$; SELECT 2;").count == 2)
    }

    // MARK: - Robustness

    /// An unterminated construct must not hang or crash. The server gives a far
    /// better syntax error than anything invented here, so the text is passed
    /// through whole.
    @Test(arguments: [
        "SELECT 'unterminated",
        "SELECT /* unterminated",
        "SELECT `unterminated",
        "SELECT $$ unterminated",
    ])
    func unterminatedConstructsAreSurvivable(script: String) {
        let parts = SQLStatementSplitter(syntax: .mysql).split(script)
        #expect(parts.count <= 1)
        let pg = SQLStatementSplitter(syntax: .postgres).split(script)
        #expect(pg.count <= 1)
    }

    @Test("comments are kept with their statement")
    func commentsArePreserved() {
        let parts = Self.mysql("-- why this exists\nCREATE TABLE a (id INT);")
        #expect(parts.count == 1)
        #expect(parts[0].contains("why this exists"), "a migration's comments are worth keeping")
    }

    @Test("statements are trimmed of surrounding whitespace and the terminator")
    func statementsAreTrimmed() {
        let parts = Self.mysql("\n\n   SELECT 1   ;\n\n   SELECT 2 ;")
        #expect(parts == ["SELECT 1", "SELECT 2"])
    }
}

/// `BEGIN … END` bodies, recognised without a directive.
///
/// `-- +swizzle StatementBegin` used to be mandatory for every trigger and
/// stored procedure, and forgetting it silently cut the body into fragments —
/// the exact corruption the splitter exists to prevent. Flyway detects these;
/// goose does not, and following goose here was the wrong call.
///
/// The directive still works, and is still the answer for anything the detector
/// cannot see.
@Suite("Compound statement bodies")
struct CompoundBodyTests {

    static func mysql(_ script: String) -> [String] {
        SQLStatementSplitter(syntax: .mysql).split(script)
    }

    @Test("a trigger body is one statement with no directive")
    func triggerBody() {
        let parts = Self.mysql("""
            CREATE TRIGGER posts_touch BEFORE UPDATE ON posts FOR EACH ROW
            BEGIN
                SET NEW.updated_at = NOW();
                SET NEW.rev = NEW.rev + 1;
            END;
            CREATE INDEX i ON posts (id);
            """)
        #expect(parts.count == 2, "got \(parts.count): \(parts)")
        #expect(parts[0].contains("SET NEW.rev"))
        #expect(parts[1].hasPrefix("CREATE INDEX"))
    }

    @Test("a stored procedure body is one statement")
    func procedureBody() {
        let parts = Self.mysql("""
            CREATE PROCEDURE tidy()
            BEGIN
                DELETE FROM sessions WHERE expires_at < NOW();
                DELETE FROM tokens WHERE used = 1;
            END;
            SELECT 1;
            """)
        #expect(parts.count == 2, "got \(parts)")
    }

    /// Nesting means a depth counter, not a flag.
    @Test("nested blocks close in the right place")
    func nestedBlocks() {
        let parts = Self.mysql("""
            CREATE PROCEDURE outer_proc()
            BEGIN
                BEGIN
                    SET @a = 1;
                END;
                SET @b = 2;
            END;
            SELECT 1;
            """)
        #expect(parts.count == 2, "got \(parts.count): \(parts)")
        #expect(parts[0].contains("SET @b = 2"))
    }

    /// `END IF` and friends contain `END` and close nothing. Treating them as
    /// block ends would terminate the body early and split the rest.
    @Test(arguments: [
        ("IF x THEN SET @a = 1; END IF;", "END IF"),
        ("WHILE x DO SET @a = 1; END WHILE;", "END WHILE"),
        ("LOOP SET @a = 1; END LOOP;", "END LOOP"),
        ("CASE x WHEN 1 THEN SET @a = 1; END CASE;", "END CASE"),
        ("REPEAT SET @a = 1; UNTIL x END REPEAT;", "END REPEAT"),
    ])
    func controlStructuresDoNotCloseTheBody(inner: String, label: String) {
        let parts = Self.mysql("""
            CREATE PROCEDURE p()
            BEGIN
                \(inner)
                SET @after = 1;
            END;
            SELECT 1;
            """)
        #expect(parts.count == 2, "\(label) ended the body early: \(parts)")
        #expect(parts[0].contains("SET @after"), "\(label) truncated the body")
    }

    /// Outside a routine, `BEGIN` starts a transaction. Counting it would
    /// swallow the rest of the file.
    @Test("a bare BEGIN is a transaction, not a block")
    func bareBeginIsATransaction() {
        let parts = Self.mysql("BEGIN; UPDATE t SET a = 1; COMMIT;")
        #expect(parts.count == 3, "got \(parts)")
    }

    /// Only a definition has a body. `DROP TRIGGER` must not arm the detector.
    @Test("dropping a routine does not open a body")
    func dropDoesNotOpenABody() {
        let parts = Self.mysql("DROP TRIGGER posts_touch; SELECT 1; SELECT 2;")
        #expect(parts.count == 3, "got \(parts)")
    }

    /// A trigger body need not be compound at all, and then the first semicolon
    /// really is the terminator.
    @Test("a single-statement body ends at its semicolon")
    func singleStatementBody() {
        let parts = Self.mysql("""
            CREATE TRIGGER t BEFORE INSERT ON x FOR EACH ROW SET NEW.a = 1;
            SELECT 1;
            """)
        #expect(parts.count == 2, "got \(parts)")
    }

    @Test("a labelled block closes on its label")
    func labelledBlock() {
        let parts = Self.mysql("""
            CREATE PROCEDURE p()
            outer_block: BEGIN
                SET @a = 1;
            END outer_block;
            SELECT 1;
            """)
        #expect(parts.count == 2, "got \(parts.count): \(parts)")
    }

    /// Detection is per statement, so a routine does not leak into what follows.
    @Test("the body does not leak into later statements")
    func doesNotLeak() {
        let parts = Self.mysql("""
            CREATE PROCEDURE p() BEGIN SET @a = 1; END;
            INSERT INTO t VALUES (1);
            INSERT INTO t VALUES (2);
            """)
        #expect(parts.count == 3, "got \(parts)")
    }

    /// The directive still works, and is still needed for anything the detector
    /// cannot see.
    @Test("StatementBegin still overrides")
    func directiveStillWorks() throws {
        let migration = try MigrationParser.parse(
            """
            -- +swizzle Up
            -- +swizzle StatementBegin
            CREATE TRIGGER t BEFORE INSERT ON x FOR EACH ROW
            BEGIN
              SET NEW.a = 1;
            END
            -- +swizzle StatementEnd
            SELECT 1;
            """,
            kind: .versioned(1), name: "t", filename: "1_t.sql", syntax: .mysql
        )
        #expect(migration.upStatements.count == 2)
        #expect(migration.upStatements[0].contains("SET NEW.a"))
    }

    /// Postgres bodies are dollar-quoted, so detection is off there — and a
    /// bare `BEGIN` really is a transaction.
    @Test("Postgres is unaffected")
    func postgresUnaffected() {
        let parts = SQLStatementSplitter(syntax: .postgres)
            .split("BEGIN; UPDATE t SET a = 1; COMMIT;")
        #expect(parts.count == 3)
    }
}

/// The cases auto-detection does *not* cover, and the directive that does.
///
/// Recorded as tests rather than left implicit: knowing exactly where a
/// heuristic stops is the difference between an escape hatch and a mystery.
@Suite("Where detection stops")
struct DetectionLimitsTests {

    static func mysql(_ script: String) -> [String] {
        SQLStatementSplitter(syntax: .mysql).split(script)
    }

    /// MariaDB's anonymous compound block. Recognised, because `BEGIN NOT
    /// ATOMIC` is unambiguous — a transaction is never written that way.
    @Test("BEGIN NOT ATOMIC is recognised")
    func beginNotAtomic() {
        let parts = Self.mysql("BEGIN NOT ATOMIC SELECT 1; SELECT 2; END; SELECT 3;")
        #expect(parts.count == 2, "got \(parts.count): \(parts)")
    }

    /// A bare `BEGIN` is still a transaction — the `NOT ATOMIC` lookahead must
    /// not arm on anything else.
    @Test("a plain BEGIN is still a transaction")
    func plainBeginUnaffected() {
        #expect(Self.mysql("BEGIN; UPDATE t SET a = 1; COMMIT;").count == 3)
        #expect(Self.mysql("BEGIN WORK; UPDATE t SET a = 1; COMMIT;").count == 3)
    }

    /// A routine body need not be a block: any single compound statement is
    /// legal. This splits wrongly, and the directive is the answer.
    ///
    /// Not fixed by extending the counter, because `IF` is also a function and
    /// `CASE … END` an expression — counting them as openers would swallow
    /// migrations that work today, which is a worse failure than needing a
    /// directive here.
    @Test(arguments: [
        "CREATE PROCEDURE p() IF @x THEN SELECT 1; END IF;",
        "CREATE PROCEDURE p() CASE @x WHEN 1 THEN SELECT 1; END CASE;",
        "CREATE PROCEDURE p() WHILE @x DO SELECT 1; END WHILE;",
    ])
    func bareControlStructureBodiesAreNotDetected(script: String) {
        // Documented behaviour, not aspiration: this is what actually happens.
        #expect(Self.mysql(script + "\nSELECT 2;").count == 3)
    }

    /// And the directive handles exactly that case.
    @Test("the directive covers what detection misses")
    func directiveCoversTheGap() throws {
        let migration = try MigrationParser.parse(
            """
            -- +swizzle Up
            -- +swizzle StatementBegin
            CREATE PROCEDURE p() IF @x THEN SELECT 1; END IF
            -- +swizzle StatementEnd
            SELECT 2;
            """,
            kind: .versioned(1), name: "p", filename: "1_p.sql", syntax: .mysql
        )
        #expect(migration.upStatements.count == 2)
        #expect(migration.upStatements[0].contains("END IF"))
    }
}

import SwizzleCore
import SwizzleMigrate
import Testing
@testable import SwizzleSQLite

/// The code generator's analysis layer, exercised against a real database.
///
/// No server, no fixture, no skipping — an in-memory SQLite connection is both
/// the database and the shadow database. This is why SQLite went first: the whole
/// prepare-and-describe design gets shaken out here at zero setup cost, before
/// MySQL needs a server and Postgres needs a patched driver.
@Suite("SQLite query analysis")
struct SQLiteAnalyzerTests {

    static func schema() async throws -> SQLiteConnection {
        let connection = try SQLiteConnection.inMemory()
        _ = try await connection.query(
            """
            CREATE TABLE users (
                id       INTEGER PRIMARY KEY,
                email    TEXT NOT NULL,
                nickname TEXT,
                balance  DECIMAL(10,2) NOT NULL,
                active   BOOLEAN NOT NULL DEFAULT 1
            )
            """
        )
        _ = try await connection.query(
            """
            CREATE TABLE orders (
                id      INTEGER PRIMARY KEY,
                user_id INTEGER NOT NULL,
                total   DECIMAL(10,2) NOT NULL
            )
            """
        )
        return connection
    }

    // MARK: - Describing

    @Test("a plain select reports names, origins and nullability")
    func plainSelect() async throws {
        let connection = try await Self.schema()
        defer { connection.close() }

        let signature = try await SQLiteQueryAnalyzer(connection)
            .analyze("SELECT id, email, nickname FROM users WHERE id = ?")

        #expect(signature.columns.map(\.name) == ["id", "email", "nickname"])
        #expect(signature.parameters.count == 1)

        // NOT NULL base columns, in a statement with no outer join.
        #expect(signature.columns[0].isOptional == false)
        #expect(signature.columns[0].nullability == .baseColumnNotNull)
        #expect(signature.columns[1].isOptional == false)

        // Declared without NOT NULL.
        #expect(signature.columns[2].isOptional)
        #expect(signature.columns[2].nullability == .baseColumnNullable)

        // Origins trace back to the base table even though the query aliased nothing.
        #expect(signature.columns[1].origin == ColumnOrigin(table: "users", column: "email"))
    }

    /// An alias changes the label but not where the column came from — which is
    /// what makes nullability resolvable at all.
    @Test("an alias renames the column without losing its origin")
    func aliasKeepsOrigin() async throws {
        let connection = try await Self.schema()
        defer { connection.close() }

        let signature = try await SQLiteQueryAnalyzer(connection)
            .analyze("SELECT email AS contact FROM users")

        #expect(signature.columns[0].name == "contact")
        #expect(signature.columns[0].origin?.column == "email")
        #expect(signature.columns[0].isOptional == false)
    }

    /// The honest limit of a dynamically typed database: `decltype` returns null
    /// for anything that is not a plain column, so there is nothing to report.
    @Test("expressions have no type and no origin, and are pessimistic")
    func expressionsArePessimistic() async throws {
        let connection = try await Self.schema()
        defer { connection.close() }

        let signature = try await SQLiteQueryAnalyzer(connection)
            .analyze("SELECT COUNT(*) AS n, email || '!' AS shouty FROM users")

        for column in signature.columns {
            #expect(column.origin == nil)
            #expect(column.nullability == .expression)
            #expect(column.nullability.isPessimistic)
            #expect(column.isOptional)
            #expect(column.swiftType == .dynamic)
        }
    }

    /// The heuristic in action: a NOT NULL column on the nullable side of a join
    /// really can arrive as null, and SQLite will not say which side it was on.
    @Test("an outer join widens columns that would otherwise be non-optional")
    func outerJoinWidens() async throws {
        let connection = try await Self.schema()
        defer { connection.close() }
        let analyzer = SQLiteQueryAnalyzer(connection)

        let inner = try await analyzer.analyze(
            "SELECT u.id, o.total FROM users u JOIN orders o ON o.user_id = u.id"
        )
        #expect(inner.hasOuterJoin == false)
        #expect(inner.columns.allSatisfy { !$0.isOptional })

        let outer = try await analyzer.analyze(
            "SELECT u.id, o.total FROM users u LEFT JOIN orders o ON o.user_id = u.id"
        )
        #expect(outer.hasOuterJoin)
        #expect(outer.columns.allSatisfy { $0.isOptional })
        #expect(outer.columns.allSatisfy { $0.nullability == .outerJoinWidened })

        // The reason is the point: both are `Int64?`, and only the reason says why.
        #expect(outer.columns[0].origin == ColumnOrigin(table: "users", column: "id"))
    }

    @Test("named parameters are recovered, bare ones are numbered")
    func parameterNames() async throws {
        let connection = try await Self.schema()
        defer { connection.close() }
        let analyzer = SQLiteQueryAnalyzer(connection)

        let named = try await analyzer.analyze(
            "SELECT id FROM users WHERE email = :email AND active = :active"
        )
        #expect(named.parameters.map(\.name) == ["email", "active"])

        let bare = try await analyzer.analyze("SELECT id FROM users WHERE id = ? AND active = ?")
        #expect(bare.parameters.map(\.name) == ["p1", "p2"])

        // SQLite has no parameter types at all, so every one is declared rather
        // than discovered — and says so.
        #expect(bare.parameters.allSatisfy { $0.swiftType == .unresolved })
        #expect(bare.parameters.allSatisfy { $0.source == .declared })
        #expect(bare.parameters.allSatisfy { $0.sqlType == nil })
    }

    @Test("a statement with no parameters reports none")
    func noParameters() async throws {
        let connection = try await Self.schema()
        defer { connection.close() }
        let signature = try await SQLiteQueryAnalyzer(connection).analyze("SELECT id FROM users")
        #expect(signature.parameters.isEmpty)
    }

    /// Describing must not run the statement. A generator that executed what it
    /// analysed would delete rows to find out what `DELETE` returns.
    @Test("describing a destructive statement changes nothing")
    func describeDoesNotExecute() async throws {
        let connection = try await Self.schema()
        defer { connection.close() }
        _ = try await connection.query("INSERT INTO users (id, email, balance) VALUES (1,'a',0)")

        _ = try await SQLiteQueryAnalyzer(connection).analyze("DELETE FROM users")
        _ = try await SQLiteQueryAnalyzer(connection).analyze("UPDATE users SET email = 'x'")

        let rows = try await connection.query("SELECT email FROM users")
        #expect(rows.count == 1)
        #expect(rows.first?.values.first == .text("a"))
    }

    @Test("a statement that will not compile is reported, not crashed on")
    func badSQLIsReported() async throws {
        let connection = try await Self.schema()
        defer { connection.close() }
        await #expect(throws: QueryAnalysisError.self) {
            _ = try await SQLiteQueryAnalyzer(connection).analyze("SELECT nope FROM users")
        }
    }

    // MARK: - Type mapping

    /// SQLite derives affinity from the declared type by substring, in a
    /// documented order, and the order matters.
    @Test("declared types map through SQLite's own affinity rules")
    func typeMapping() {
        #expect(SQLiteTypeMap.swiftType(for: "INTEGER") == .int64)
        #expect(SQLiteTypeMap.swiftType(for: "BIGINT") == .int64)
        #expect(SQLiteTypeMap.swiftType(for: "VARYING CHARACTER(255)") == .string)
        #expect(SQLiteTypeMap.swiftType(for: "TEXT") == .string)
        #expect(SQLiteTypeMap.swiftType(for: "BLOB") == .bytes)
        #expect(SQLiteTypeMap.swiftType(for: "DOUBLE PRECISION") == .double)
        #expect(SQLiteTypeMap.swiftType(for: "REAL") == .double)

        // Exact numerics stay text. SQLite's own rules would send these to REAL,
        // which loses the cents — the same contract the table declarations make.
        #expect(SQLiteTypeMap.swiftType(for: "DECIMAL(10,2)") == .decimalString)
        #expect(SQLiteTypeMap.swiftType(for: "NUMERIC") == .decimalString)

        // No declared type is an expression column.
        #expect(SQLiteTypeMap.swiftType(for: nil) == .dynamic)
        #expect(SQLiteTypeMap.swiftType(for: "") == .dynamic)
    }

    /// `INT` has to be tested before `TEXT`, or `POINT` matches the wrong rule.
    @Test("the affinity rules are applied in the documented order")
    func affinityOrderMatters() {
        #expect(SQLiteTypeMap.swiftType(for: "POINT") == .int64)
        #expect(SQLiteTypeMap.swiftType(for: "CLOB") == .string)
    }

    @Test("a real DECIMAL column round-trips as a decimal string")
    func decimalColumnIsText() async throws {
        let connection = try await Self.schema()
        defer { connection.close() }

        let signature = try await SQLiteQueryAnalyzer(connection)
            .analyze("SELECT balance FROM users")
        #expect(signature.columns[0].swiftType == .decimalString)
        #expect(signature.columns[0].isOptional == false)
    }

    // MARK: - The outer-join scan

    @Test("outer joins are found in code and ignored everywhere else")
    func outerJoinScan() {
        #expect(SQLStatementFacts.hasOuterJoin("SELECT 1 FROM a LEFT JOIN b ON x", syntax: .sqlite))
        #expect(SQLStatementFacts.hasOuterJoin("SELECT 1 FROM a left outer join b ON x", syntax: .sqlite))
        #expect(SQLStatementFacts.hasOuterJoin("SELECT 1 FROM a NATURAL FULL JOIN b", syntax: .sqlite))
        #expect(SQLStatementFacts.hasOuterJoin("SELECT 1 FROM a RIGHT JOIN b ON x", syntax: .sqlite))

        #expect(!SQLStatementFacts.hasOuterJoin("SELECT 1 FROM a JOIN b ON x", syntax: .sqlite))
        #expect(!SQLStatementFacts.hasOuterJoin("SELECT 1 FROM a INNER JOIN b ON x", syntax: .sqlite))

        // The words must not count inside a string, an identifier or a comment —
        // the reason this is a scan over regions rather than a substring search.
        #expect(!SQLStatementFacts.hasOuterJoin("SELECT 'LEFT JOIN' FROM a", syntax: .sqlite))
        #expect(!SQLStatementFacts.hasOuterJoin("SELECT \"left join\" FROM a", syntax: .sqlite))
        #expect(!SQLStatementFacts.hasOuterJoin("SELECT 1 -- LEFT JOIN b\nFROM a", syntax: .sqlite))
        #expect(!SQLStatementFacts.hasOuterJoin("SELECT 1 /* LEFT JOIN b */ FROM a", syntax: .sqlite))

        // And a column named after one is not one.
        #expect(!SQLStatementFacts.hasOuterJoin("SELECT left_join_count FROM a", syntax: .sqlite))
    }

    @Test("the scan honours each dialect's own quoting")
    func scanIsDialectAware() {
        // Backticks are identifiers on MySQL and not on Postgres.
        #expect(!SQLStatementFacts.hasOuterJoin("SELECT `left join` FROM a", syntax: .mysql))
        // `#` is a comment on MySQL only.
        #expect(!SQLStatementFacts.hasOuterJoin("SELECT 1 # LEFT JOIN b\nFROM a", syntax: .mysql))
        #expect(SQLStatementFacts.hasOuterJoin("SELECT 1 # x\nFROM a LEFT JOIN b", syntax: .mysql))
        // Dollar quoting is Postgres only.
        #expect(!SQLStatementFacts.hasOuterJoin(
            "CREATE FUNCTION f() AS $$ SELECT 1 FROM a LEFT JOIN b $$", syntax: .postgres
        ))
    }

    /// The engine hook: the generator finds the analyzer through
    /// `EngineConnection`, never by knowing which database it is.
    @Test("the engine exposes an analyzer")
    func engineExposesAnalyzer() async throws {
        let connection = try await SQLiteEngine.connect(url: "sqlite::memory:")
        defer { connection.close() }
        let analyzer = try #require(connection.analyzer)
        // And it works through the erased seam, not just as a concrete type.
        let signature = try await analyzer.analyze("SELECT 1 AS n")
        #expect(signature.columns.map(\.name) == ["n"])
    }
}

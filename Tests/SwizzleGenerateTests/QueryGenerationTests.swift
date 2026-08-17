import Foundation
import SwizzleCore
import SwizzleSQLite
import SwizzleSQLiteEngine
import Testing
@testable import SwizzleGenerate

@Suite("Query file parsing")
struct QueryParserTests {

    @Test("a query's name, parameters and cardinality come from its directive")
    func headerIsParsed() throws {
        let queries = try QueryParser.parse(
            """
            -- +swizzle Query GetUser(id: Int64) :one
            SELECT id FROM users WHERE id = ?;
            """,
            filename: "users.sql"
        )
        #expect(queries.count == 1)
        #expect(queries[0].name == "GetUser")
        #expect(queries[0].cardinality == .one)
        #expect(queries[0].parameters == [DeclaredParameter(name: "id", type: "Int64")])
        // The trailing semicolon is what keeps the file runnable by hand, and is
        // dropped on the way to the server.
        #expect(queries[0].sql == "SELECT id FROM users WHERE id = ?")
    }

    @Test("every cardinality is understood")
    func cardinalities() throws {
        for (text, expected) in [
            ("one", QuerySignature.Cardinality.one), ("many", .many),
            ("stream", .stream), ("exec", .exec),
        ] {
            let parsed = try QueryParser.parse(
                "-- +swizzle Query Q :\(text)\nSELECT 1;", filename: "q.sql"
            )
            #expect(parsed[0].cardinality == expected)
        }
    }

    @Test("a query with no parameters needs no parentheses")
    func noParameters() throws {
        let queries = try QueryParser.parse(
            "-- +swizzle Query All :many\nSELECT id FROM users;", filename: "q.sql"
        )
        #expect(queries[0].parameters.isEmpty)
        #expect(queries[0].name == "All")
    }

    @Test("several queries in one file are separated by their directives")
    func severalQueries() throws {
        let queries = try QueryParser.parse(
            """
            -- +swizzle Query A :many
            SELECT 1;

            -- an ordinary comment, not a directive
            -- +swizzle Query B(x: String) :exec
            DELETE FROM t WHERE k = ?;
            """,
            filename: "q.sql"
        )
        #expect(queries.map(\.name) == ["A", "B"])
        #expect(queries[1].sql == "DELETE FROM t WHERE k = ?")

        // The ordinary comment belongs to neither, and this assertion is the
        // point of the test.
        //
        // It used to read `#expect(queries[0].sql.contains("SELECT 1"))`, which
        // passed while A's SQL was the whole rest of the file — statement,
        // semicolon and prose. A `contains` check cannot tell "the right SQL"
        // from "the right SQL and four lines of commentary", so it did not, and
        // the generated code shipped the commentary to the server.
        #expect(queries[0].sql == "SELECT 1")
    }

    /// The general form of the bug above: whatever an author writes after a
    /// query, up to the next directive, is not part of that query.
    @Test("prose written after a query does not become part of it")
    func trailingProseIsNotSQL() throws {
        let queries = try QueryParser.parse(
            """
            -- +swizzle Query A(id: Int64) :one
            SELECT id FROM users WHERE id = ?;

            -- Why this query exists, at length, with a semicolon; and a ? too.
            /* and a block comment
               over several lines */
            """,
            filename: "q.sql"
        )
        #expect(queries[0].sql == "SELECT id FROM users WHERE id = ?")
    }

    /// One directive generates one function, so a body holding two statements
    /// has to be an error — otherwise it silently generates a function that
    /// sends both.
    @Test("two statements under one directive are refused")
    func twoStatementsRefused() {
        do {
            _ = try QueryParser.parse(
                "-- +swizzle Query A :exec\nDELETE FROM t;\nDELETE FROM u;",
                filename: "q.sql"
            )
            Issue.record("expected a parse error")
        } catch let error as QueryParseError {
            #expect(error.reason.contains("2 statements"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("overrides attach to the query that follows them")
    func overridesAttach() throws {
        let queries = try QueryParser.parse(
            """
            -- +swizzle NotNull total
            -- +swizzle Nullable note
            -- +swizzle Query A :many
            SELECT 1;

            -- +swizzle Query B :many
            SELECT 2;
            """,
            filename: "q.sql"
        )
        #expect(queries[0].notNull == ["total"])
        #expect(queries[0].nullable == ["note"])
        // And do not leak to the next one.
        #expect(queries[1].notNull.isEmpty)
        #expect(queries[1].nullable.isEmpty)
    }

    @Test("malformed directives are refused with the file and line")
    func malformedDirectives() {
        #expect(throws: QueryParseError.self) {
            try QueryParser.parse("-- +swizzle Query NoCardinality\nSELECT 1;", filename: "q.sql")
        }
        #expect(throws: QueryParseError.self) {
            try QueryParser.parse("-- +swizzle Query Q :sometimes\nSELECT 1;", filename: "q.sql")
        }
        #expect(throws: QueryParseError.self) {
            try QueryParser.parse("-- +swizzle Query Q(id) :one\nSELECT 1;", filename: "q.sql")
        }
        #expect(throws: QueryParseError.self) {
            try QueryParser.parse("-- +swizzle Query Q :one\n", filename: "q.sql")
        }
        #expect(throws: QueryParseError.self) {
            try QueryParser.parse("-- +swizzle Wat something\nSELECT 1;", filename: "q.sql")
        }
    }

    /// Two queries with one name would generate two functions with one name.
    /// Caught here so the message names the file, not the generated output.
    @Test("a Type directive is parsed, with and without its optionality")
    func typeDirective() throws {
        let queries = try QueryParser.parse(
            """
            -- +swizzle Type n Int64
            -- +swizzle Type label String?
            -- +swizzle Query Q :one
            SELECT COUNT(*) AS n, 'x' AS label FROM users;
            """,
            filename: "q.sql"
        )
        #expect(queries[0].types["n"] == DeclaredColumnType(type: .int64, isOptional: false))
        #expect(queries[0].types["label"] == DeclaredColumnType(type: .string, isOptional: true))
    }

    /// `Int` is what an author reaches for first, and `unknown type 'Int'` would
    /// be a pointlessly hostile welcome. It generates as `Int64`, which is what
    /// the emitted code says.
    @Test("Int is accepted as a spelling of Int64")
    func intIsAccepted() throws {
        let queries = try QueryParser.parse(
            "-- +swizzle Type n Int\n-- +swizzle Query Q :one\nSELECT COUNT(*) AS n FROM users;",
            filename: "q.sql"
        )
        #expect(queries[0].types["n"]?.type == .int64)
    }

    @Test("a type nothing can emit is refused, and the message lists what can")
    func unknownTypeIsRefused() {
        do {
            _ = try QueryParser.parse(
                "-- +swizzle Type n BigDecimal\n-- +swizzle Query Q :one\nSELECT 1 AS n;",
                filename: "q.sql"
            )
            Issue.record("expected a parse error")
        } catch let error as QueryParseError {
            #expect(error.reason.contains("BigDecimal"))
            #expect(error.reason.contains("Int64"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("two different types for one column are refused rather than silently resolved")
    func contradictoryTypes() {
        #expect(throws: QueryParseError.self) {
            _ = try QueryParser.parse(
                """
                -- +swizzle Type n Int64
                -- +swizzle Type n String
                -- +swizzle Query Q :one
                SELECT 1 AS n;
                """,
                filename: "q.sql"
            )
        }
    }

    @Test("a Type with no query after it is refused")
    func danglingType() {
        #expect(throws: QueryParseError.self) {
            _ = try QueryParser.parse(
                "-- +swizzle Query Q :one\nSELECT 1;\n-- +swizzle Type n Int64\n",
                filename: "q.sql"
            )
        }
    }

    @Test("a duplicate name is refused")
    func duplicateNames() {
        #expect(throws: QueryParseError.self) {
            try QueryParser.parse(
                "-- +swizzle Query A :many\nSELECT 1;\n-- +swizzle Query A :many\nSELECT 2;",
                filename: "q.sql"
            )
        }
    }

    /// An override at the end of the file applies to nothing, which is always a
    /// mistake and is silent otherwise.
    @Test("a dangling override is refused")
    func danglingOverride() {
        #expect(throws: QueryParseError.self) {
            try QueryParser.parse(
                "-- +swizzle Query A :many\nSELECT 1;\n-- +swizzle NotNull x\n",
                filename: "q.sql"
            )
        }
    }
}

@Suite("Query generation")
struct QueryGenerationTests {

    static func connection() async throws -> SQLiteConnection {
        let connection = try SQLiteConnection.inMemory()
        _ = try await connection.query(
            """
            CREATE TABLE users (
                id INTEGER PRIMARY KEY, email TEXT NOT NULL, nickname TEXT
            )
            """
        )
        _ = try await connection.query(
            "CREATE TABLE orders (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL, total DECIMAL(10,2) NOT NULL)"
        )
        return connection
    }

    func resolve(_ text: String, _ connection: SQLiteConnection) async throws -> [ResolvedQuery] {
        let parsed = try QueryParser.parse(text, filename: "q.sql")
        return try await QueryGenerator(analyzer: SQLiteQueryAnalyzer(connection)).resolve(parsed)
    }

    @Test("the database supplies the columns, the file supplies everything else")
    func declarationAndDiscoveryAreJoined() async throws {
        let connection = try await Self.connection()
        defer { connection.close() }

        let resolved = try await resolve(
            "-- +swizzle Query GetUser(id: Int64) :one\nSELECT id, email, nickname FROM users WHERE id = ?;",
            connection
        )
        let signature = resolved[0].signature

        // From the file.
        #expect(signature.name == "GetUser")
        #expect(signature.cardinality == .one)
        #expect(signature.parameters.map(\.name) == ["id"])

        // From the database.
        #expect(signature.columns.map(\.name) == ["id", "email", "nickname"])
        #expect(signature.columns[2].isOptional)
        #expect(signature.columns[1].isOptional == false)
    }

    /// A declared parameter count that disagrees with the SQL produces a server
    /// error about placeholder counts at runtime. Turning it into a
    /// generation-time error naming the file is most of the value.
    @Test("a parameter count mismatch is refused at generation time")
    func parameterCountMismatch() async throws {
        let connection = try await Self.connection()
        defer { connection.close() }

        await #expect(throws: QueryParseError.self) {
            _ = try await resolve(
                "-- +swizzle Query Q(a: Int64, b: Int64) :one\nSELECT id FROM users WHERE id = ?;",
                connection
            )
        }
    }

    @Test("an override narrows what the engine had to widen")
    func overrideNarrows() async throws {
        let connection = try await Self.connection()
        defer { connection.close() }
        let sql = "SELECT u.id, o.total FROM users u LEFT JOIN orders o ON o.user_id = u.id"

        let widened = try await resolve("-- +swizzle Query Q :many\n\(sql);", connection)
        #expect(widened[0].signature.columns.allSatisfy { $0.isOptional })
        #expect(widened[0].signature.columns[1].nullability == .outerJoinWidened)

        let narrowed = try await resolve(
            "-- +swizzle NotNull total\n-- +swizzle Query Q :many\n\(sql);", connection
        )
        #expect(narrowed[0].signature.columns[1].isOptional == false)
        #expect(narrowed[0].signature.columns[1].nullability == .annotationNotNull)
    }

    /// A typo in an override is silent otherwise: the column keeps whatever the
    /// engine said and the author believes they fixed it.
    @Test("an override naming no column is refused, and says which columns exist")
    func overrideMustNameAColumn() async throws {
        let connection = try await Self.connection()
        defer { connection.close() }

        do {
            _ = try await resolve(
                "-- +swizzle NotNull totl\n-- +swizzle Query Q :many\nSELECT id, email FROM users;",
                connection
            )
            Issue.record("expected a parse error")
        } catch let error as QueryParseError {
            #expect(error.reason.contains("totl"))
            #expect(error.reason.contains("'email'"))
        }
    }

    // MARK: - `Type`

    /// The gap this closed, stated as the query that exposed it.
    ///
    /// `SELECT COUNT(*)` is the most ordinary query anybody writes, and on SQLite
    /// it generated as `SQLValue` with no way to say otherwise: `decltype` is null
    /// for every expression, `NotNull` fixed only the optionality, and the type
    /// half had no directive at all. Found by running the CLI end to end rather
    /// than by reading it — the unit tests all used base columns, which are
    /// exactly the case SQLite *can* type.
    @Test("a declared type replaces the one the engine could not report")
    func typeOverrideNamesWhatSQLiteCannot() async throws {
        let connection = try await Self.connection()
        defer { connection.close() }

        let unaided = try await resolve(
            "-- +swizzle Query Q :one\nSELECT COUNT(*) AS n FROM users;", connection
        )
        #expect(unaided[0].signature.columns[0].swiftType == .dynamic)
        #expect(unaided[0].signature.columns[0].isOptional)

        let declared = try await resolve(
            "-- +swizzle Type n Int64\n-- +swizzle Query Q :one\nSELECT COUNT(*) AS n FROM users;",
            connection
        )
        #expect(declared[0].signature.columns[0].swiftType == .int64)
        // Not optional, because the author wrote `Int64` and not `Int64?`.
        #expect(declared[0].signature.columns[0].isOptional == false)
        #expect(declared[0].signature.columns[0].nullability == .annotationNotNull)
    }

    /// The whole reason optionality rides on the spelling: one directive, and the
    /// vocabulary is Swift's rather than ours.
    @Test("a trailing ? makes the declared type optional")
    func optionalSpelling() async throws {
        let connection = try await Self.connection()
        defer { connection.close() }

        let resolved = try await resolve(
            "-- +swizzle Type label String?\n-- +swizzle Query Q :many\n"
                + "SELECT nickname || '!' AS label FROM users;",
            connection
        )
        #expect(resolved[0].signature.columns[0].swiftType == .string)
        #expect(resolved[0].signature.columns[0].isOptional)
        #expect(resolved[0].signature.columns[0].nullability == .annotationNullable)
    }

    /// Applied in that order deliberately, so a `Type` can name the type while a
    /// separate `NotNull` corrects the optionality.
    @Test("NotNull still wins over the optionality a Type implied")
    func notNullBeatsDeclaredOptionality() async throws {
        let connection = try await Self.connection()
        defer { connection.close() }

        let resolved = try await resolve(
            "-- +swizzle Type n Int64?\n-- +swizzle NotNull n\n"
                + "-- +swizzle Query Q :one\nSELECT COUNT(*) AS n FROM users;",
            connection
        )
        #expect(resolved[0].signature.columns[0].swiftType == .int64)
        #expect(resolved[0].signature.columns[0].isOptional == false)
    }

    /// The same protection `NotNull` has: a typo that names nothing is otherwise
    /// silent, and the author believes they fixed it.
    @Test("a Type naming no column is refused")
    func typeMustNameAColumn() async throws {
        let connection = try await Self.connection()
        defer { connection.close() }

        do {
            _ = try await resolve(
                "-- +swizzle Type totl Int64\n-- +swizzle Query Q :many\nSELECT id FROM users;",
                connection
            )
            Issue.record("expected a parse error")
        } catch let error as QueryParseError {
            #expect(error.reason.contains("totl"))
            #expect(error.reason.contains("'id'"))
        }
    }

    @Test("a declared type actually reaches the generated source")
    func typeReachesTheEmitter() async throws {
        let connection = try await Self.connection()
        defer { connection.close() }

        let source = QueryEmitter(options: .init(dialect: "SQLite")).emit(
            try await resolve(
                "-- +swizzle Type n Int64\n-- +swizzle Query CountUsers :one\n"
                    + "SELECT COUNT(*) AS n FROM users;",
                connection
            )
        )
        // A single non-optional column is returned bare, so the whole signature
        // is visible in one line — and it is `Int64?` rather than `SQLValue?`,
        // where the `?` is "at most one row" and not the column.
        #expect(source.contains("func countUsers() async throws -> Int64?"))
        #expect(source.contains("try Int64(sqlValue: row.values[0])"))
        // `[SQLValue]` is the bindings array every function carries, so the
        // absence being asserted is of `SQLValue` as the *decoded* type.
        #expect(!source.contains("try SQLValue("))
    }

    @Test("a column cannot be both NotNull and Nullable")
    func contradictoryOverrides() async throws {
        let connection = try await Self.connection()
        defer { connection.close() }
        await #expect(throws: QueryParseError.self) {
            _ = try await resolve(
                "-- +swizzle NotNull email\n-- +swizzle Nullable email\n"
                    + "-- +swizzle Query Q :many\nSELECT email FROM users;",
                connection
            )
        }
    }

    /// The analysis error alone says "cannot describe query", which is useless in
    /// a directory of thirty.
    @Test("a query the database rejects names its file and line")
    func badQueryNamesItsFile() async throws {
        let connection = try await Self.connection()
        defer { connection.close() }
        do {
            _ = try await resolve("-- +swizzle Query Broken :many\nSELECT nope FROM users;", connection)
            Issue.record("expected a parse error")
        } catch let error as QueryParseError {
            #expect(error.file == "q.sql")
            #expect(error.reason.contains("Broken"))
        }
    }

    // MARK: - Emission

    func emit(_ text: String, _ connection: SQLiteConnection) async throws -> String {
        let resolved = try await resolve(text, connection)
        return QueryEmitter(options: .init(dialect: "SQLite")).emit(resolved)
    }

    @Test("row structs carry the column names and their optionality")
    func rowStructShape() async throws {
        let connection = try await Self.connection()
        defer { connection.close() }
        let source = try await emit(
            "-- +swizzle Query GetUser(id: Int64) :one\nSELECT id, email, nickname FROM users WHERE id = ?;",
            connection
        )

        #expect(source.contains("public struct GetUserRow: Sendable"))
        #expect(source.contains("public let email: String\n"))
        #expect(source.contains("public let nickname: String?\n"))
        #expect(source.contains("public func getUser(id: Int64) async throws -> GetUserRow?"))
    }

    /// `count()` beats `count()?.total`. The non-optional part is load-bearing:
    /// for an optional column a bare `T?` would collapse "no row" and "a row
    /// holding null" into one value.
    @Test("a single non-optional column is returned bare")
    func singleColumnIsBare() async throws {
        let connection = try await Self.connection()
        defer { connection.close() }

        let bare = try await emit(
            "-- +swizzle NotNull email\n-- +swizzle Query FirstEmail :one\nSELECT email FROM users;",
            connection
        )
        #expect(bare.contains("func firstEmail() async throws -> String?"))
        #expect(!bare.contains("struct FirstEmailRow"))

        // An optional column keeps its struct, so the two nils stay distinct.
        let wrapped = try await emit(
            "-- +swizzle Query Nick :one\nSELECT nickname FROM users;", connection
        )
        #expect(wrapped.contains("struct NickRow"))
        #expect(wrapped.contains("func nick() async throws -> NickRow?"))
    }

    @Test("each cardinality emits the right shape")
    func cardinalityShapes() async throws {
        let connection = try await Self.connection()
        defer { connection.close() }

        let many = try await emit("-- +swizzle Query Q :many\nSELECT id, email FROM users;", connection)
        #expect(many.contains("async throws -> [QRow]"))

        let exec = try await emit(
            "-- +swizzle Query Q(id: Int64) :exec\nDELETE FROM users WHERE id = ?;", connection
        )
        #expect(exec.contains("async throws -> Int"))
        #expect(exec.contains("executeUpdate"))
        #expect(!exec.contains("struct QRow"))
    }

    /// Streaming needs more of an executor than running does, so a `:stream`
    /// query must not exist at all on a backend that cannot stream.
    @Test("streaming queries live behind the streaming constraint")
    func streamingIsGated() async throws {
        let connection = try await Self.connection()
        defer { connection.close() }
        let source = try await emit("-- +swizzle Query S :stream\nSELECT id, email FROM users;", connection)

        #expect(source.contains("extension Queries where Executor: SQLStreamingExecutor"))
        #expect(source.contains("AsyncThrowingMapSequence<Executor.RowSequence, SRow>"))
    }

    /// The limit of every assertion above, stated once.
    ///
    /// They compare the emitter's output to strings, which cannot tell valid
    /// Swift from a plausible-looking sequence of characters. The return type for
    /// `:stream` read `some AsyncSequence<SRow, any Error>` and matched its
    /// assertion exactly while not compiling at all below macOS 15 — the second
    /// parameter is the typed-throws `Failure`, and this package targets 14.
    ///
    /// `CodegenGoldenTests` is the answer: `examples/codegen/Generated` is a
    /// build target, so the compiler sees generated code for every cardinality,
    /// this one included. Left here as a pointer, because the next person to add
    /// an emitter test will reach for `contains` first — as I did.
    @Test("string assertions are not a compiler, and the golden example is")
    func stringAssertionsAreNotACompiler() {
        #expect(
            FileManager.default.fileExists(
                atPath: CodegenGoldenTests.generatedFile.path
            ),
            "examples/codegen/Generated/Queries.swift is what compiles the emitter's output. If it has moved, the emitter is unchecked again."
        )
    }

    /// The generated container is pinned to the dialect it was analysed against,
    /// so handing it another engine's connection is a compile error.
    @Test("the container is pinned to its dialect")
    func containerIsPinned() async throws {
        let connection = try await Self.connection()
        defer { connection.close() }
        let source = try await emit("-- +swizzle Query Q :many\nSELECT id FROM users;", connection)
        #expect(source.contains("where Executor.Dialect == SQLite"))
    }

    @Test("generating twice produces identical bytes")
    func emissionIsDeterministic() async throws {
        let connection = try await Self.connection()
        defer { connection.close() }
        let text = """
            -- +swizzle Query A(id: Int64) :one
            SELECT id, email FROM users WHERE id = ?;
            -- +swizzle Query B :stream
            SELECT nickname FROM users;
            """
        #expect(try await emit(text, connection) == (try await emit(text, connection)))
    }
}

/// A test-only shim, because every suite in this module writes SQLite.
///
/// Deliberately not a default on the real API: a query file's dialect decides
/// where its statements end, and a wrong guess is silent — a Postgres `$$ … $$`
/// body reads as ordinary text to every other scanner. Tests that care about a
/// different dialect name it, and `PostgresQuerySyntaxTests` below is one.
extension QueryParser {
    static func parse(_ text: String, filename: String) throws -> [ParsedQuery] {
        try parse(text, filename: filename, syntax: .sqlite)
    }
}

/// The dialect actually reaching the parser.
///
/// Threading a syntax through is only worth anything if it is used, and the case
/// that proves it is a body the SQLite scanner would misread.
// test-hygiene: no server — pure parsing
@Suite("Query file dialects")
struct PostgresQuerySyntaxTests {

    /// A dollar-quoted body holding a semicolon is one statement to Postgres and
    /// two to a scanner that does not know the quoting form.
    @Test("a dollar-quoted body is one statement, not two")
    func dollarQuoting() throws {
        let text = """
            -- +swizzle Query Greet(name: String) :one
            SELECT format($fmt$hello, %s; and welcome$fmt$, $1) AS greeting;
            """
        let postgres = try QueryParser.parse(text, filename: "q.sql", syntax: .postgres)
        #expect(postgres.count == 1)
        #expect(postgres[0].sql.contains("and welcome"))

        // The same text under SQLite's rules splits at the semicolon inside the
        // body — which is exactly the failure the parameter exists to prevent.
        #expect(throws: QueryParseError.self) {
            _ = try QueryParser.parse(text, filename: "q.sql", syntax: .sqlite)
        }
    }

    /// MySQL's `#` comment, which no other dialect has.
    @Test("a MySQL hash comment after a query is not part of it")
    func hashComment() throws {
        let queries = try QueryParser.parse(
            "-- +swizzle Query All :many\nSELECT id FROM users;\n# a note\n",
            filename: "q.sql", syntax: .mysql
        )
        #expect(queries[0].sql == "SELECT id FROM users")
    }
}

/// Gaps found by `Scripts/mutation-sweep.sh`, each one a line that could be
/// wrong with the whole suite still green.
///
/// The sweep breaks a comparison and checks whether anything notices. Six
/// survivors in `SwizzleGenerate` were real, and five of them are here — the
/// naming rules especially, because generated identifiers **are** the API a
/// user sees, and getting `httpURL` or `user2Name` wrong is not a detail.
// test-hygiene: no server — pure naming and type mapping
@Suite("Generator edges")
struct GeneratorEdgeTests {

    /// `words(in:)` splits on `_`, `-`, space and `.`, and only `_` was covered.
    /// Mutating either of the other three to `&&` — which can never be true, so
    /// no split happens — left the suite green.
    @Test("every separator a database uses splits a name")
    func allSeparatorsSplit() {
        #expect(SwiftNames.memberName("created_at") == "createdAt")
        #expect(SwiftNames.memberName("created-at") == "createdAt")
        #expect(SwiftNames.memberName("created at") == "createdAt")
        #expect(SwiftNames.memberName("created.at") == "createdAt")
        // And in combination, since a real schema mixes them.
        #expect(SwiftNames.memberName("order-line_item count") == "orderLineItemCount")
    }

    /// A digit counts as "lower" for the case-change split, so `user2Name` breaks
    /// at the `N` rather than running together. Mutating `isLowercase ||
    /// isNumber` to `&&` — never true — was invisible.
    @Test("a digit does not swallow the next case change")
    func digitsAreWordCharacters() {
        #expect(SwiftNames.memberName("user2Name") == "user2Name")
        #expect(SwiftNames.memberName("address2Line") == "address2Line")
        // The whole reason the rule exists: without it `2` resets the boundary
        // and `Name` joins the previous word.
        #expect(SwiftNames.memberName("http2Server") == "http2Server")
    }

    /// The initialism table existed and nothing read from it in a test, so
    /// inverting the lookup changed nothing anyone checked.
    @Test("initialisms are shouted where Swift shouts them")
    func initialismsAreHonoured() {
        // Leading: stays lowercase in a member name — `id`, not `iD`.
        #expect(SwiftNames.memberName("id") == "id")
        #expect(SwiftNames.memberName("url") == "url")
        // Trailing: capitalised as the initialism, not as `Id`.
        #expect(SwiftNames.memberName("user_id") == "userID")
        #expect(SwiftNames.memberName("avatar_url") == "avatarURL")
        #expect(SwiftNames.memberName("payload_json") == "payloadJSON")
        #expect(SwiftNames.memberName("remote_ip") == "remoteIP")
        // A word that merely contains an initialism is not one.
        #expect(SwiftNames.memberName("idea") == "idea")
        #expect(SwiftNames.memberName("valid_ideas") == "validIdeas")
    }

    /// `tinyint(1)` is MySQL's boolean and `tinyint` on its own is not. The
    /// mapping distinguished them and no test did, so inverting the check was
    /// free.
    @Test("tinyint(1) is Bool and tinyint(4) is not")
    func tinyintOneIsBoolean() {
        #expect(ColumnTypeName.parse("tinyint(1)", dialect: "mysql").swiftType == .bool)
        #expect(ColumnTypeName.parse("tinyint(4)", dialect: "mysql").swiftType == .int16)
        #expect(ColumnTypeName.parse("tinyint", dialect: "mysql").swiftType == .int16)
        // The spellings that are unconditionally boolean.
        #expect(ColumnTypeName.parse("boolean", dialect: "postgres").swiftType == .bool)
    }
}

/// The two parsing survivors, in their own suite because they need a directory.
// test-hygiene: no server — filesystem only
@Suite("Query directory edges")
struct QueryDirectoryEdgeTests {

    /// A directive with a keyword and no argument reaches
    /// `let rest = parts.count > 1 ? String(parts[1]) : ""`, and nothing did.
    /// Mutating `>` to `>=` indexes past the end of a one-element array — a
    /// crash, not a wrong answer — and the suite stayed green because no test
    /// ever wrote a bare directive.
    @Test("a directive with no argument is refused, not crashed on")
    func bareDirective() {
        for text in [
            "-- +swizzle NotNull\nSELECT 1;",
            "-- +swizzle Nullable\nSELECT 1;",
            "-- +swizzle Type\nSELECT 1;",
            "-- +swizzle Query\nSELECT 1;",
        ] {
            #expect(throws: QueryParseError.self) {
                _ = try QueryParser.parse(text, filename: "q.sql")
            }
        }
    }

    /// `filter { $0.hasSuffix(".sql") && !$0.hasPrefix(".") }` — swapping the
    /// `&&` for `||` reads every file in the directory, and no test had put
    /// anything else there to notice.
    @Test("only .sql files are read, and dotfiles are not")
    func directoryIgnoresEverythingElse() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swizzle-qdir-\(UInt32.random(in: 0..<UInt32.max))")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        func write(_ name: String, _ contents: String) throws {
            try contents.write(
                to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8
            )
        }

        try write("users.sql", "-- +swizzle Query GetUser :one\nSELECT 1;")
        // A README is ordinary in a queries directory and is not SQL.
        try write("README.md", "# these are the queries")
        // An editor backup, which is exactly the file that would otherwise be
        // parsed as a duplicate of the real one.
        try write("users.sql.bak", "-- +swizzle Query GetUser :one\nSELECT 2;")
        // `.hasPrefix(".")` is the other half: a dotfile ending in .sql, which
        // `hasSuffix` alone would happily read.
        try write(".hidden.sql", "-- +swizzle Query Ghost :one\nSELECT 3;")

        let queries = try QueryDirectory(url: directory, syntax: .sqlite).load()
        #expect(queries.map(\.name) == ["GetUser"], "read \(queries.map(\.name))")
    }
}

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
        // The ordinary comment belongs to A's body, not to B.
        #expect(queries[0].sql.contains("SELECT 1"))
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
        #expect(source.contains("some AsyncSequence<SRow, any Error>"))
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

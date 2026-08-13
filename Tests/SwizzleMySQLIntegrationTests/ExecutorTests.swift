import NIOCore
import NIOPosix
import SwizzleCore
import SwizzleQuery
import Testing
@testable import SwizzleMySQL

/// End to end: a query written with the builder, rendered, executed on a real
/// server, and decoded back into the projection's tuple type.
///
/// Until this existed the builder and the driver were two halves that had never
/// met — the builder was verified by rendering SQL to a string, the driver by
/// hand-written SQL. Neither proved the generated SQL was *executable*.
/// Serialised on purpose: `SQLTable.tableName` is a **static** property, so
/// every case in this suite shares one fixture table name and parallel cases on
/// the same server race to create and drop it. Randomising per case is not
/// possible without making the table name non-static, which would weaken the
/// builder's API for the sake of a test.
@Suite(
    "Executor",
    .serialized,
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct ExecutorTests {

    struct Users: SQLTable {
        static let tableName = "exec_users"
        var tableAlias: String?

        var id: SQLExpression<Int64> { column("id") }
        var name: SQLExpression<String> { column("name") }
        var score: SQLExpression<Int64> { column("score") }
    }

    static func connect(_ server: MySQLTestServer) async throws -> MySQLConnection {
        let user = server.primaryUser
        return try await MySQLConnection.connect(
            configuration: .init(
                address: .hostname(TestServers.host, port: server.port),
                username: user.name, password: user.password,
                database: TestServers.database, tls: .disable
            ),
            on: TestServers.group.next()
        )
    }

    /// Creates the fixture table under the real name the `SQLTable` declares.
    static func seed(_ connection: MySQLConnection) async throws {
        _ = try await connection.query("DROP TABLE IF EXISTS \(Users.tableName)")
        _ = try await connection.query(
            """
            CREATE TABLE \(Users.tableName) (
                id INT PRIMARY KEY, name VARCHAR(64) NOT NULL, score BIGINT NOT NULL
            )
            """
        )
        _ = try await connection.query(
            """
            INSERT INTO \(Users.tableName) VALUES
            (1,'ada',100),(2,'grace',250),(3,'alan',175),(4,'edsger',50)
            """
        )
    }

    // MARK: - Fetch

    @Test("a built query executes and decodes", arguments: TestServers.all)
    func fetchDecodesTuples(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        try await Self.seed(connection)
        // No cleanup here on purpose. `prepare()` drops and recreates the table, so
        // every test starts from a known state regardless of order — whereas a
        // `defer { Task { DROP … } }` is *detached*, which escapes the suite's
        // `.serialized` ordering and can land after the next test has already
        // created and populated the same shared table. That race made
        // "a failed transaction rolls back the built writes" fail intermittently.

        let rows = try await runFetch(connection, server: server)
        #expect(rows.count == 4)
        #expect(rows.map(\.1).sorted() == ["ada", "alan", "edsger", "grace"])
    }

    /// The dialect is a compile-time type, so the query has to be written
    /// against the flavour actually connected to. This picks the right one and
    /// runs the same query through both paths.
    func runFetch(
        _ connection: MySQLConnection, server: MySQLTestServer
    ) async throws -> [(Int64, String)] {
        let u = Users()
        if server.flavor == .mariaDB {
            let db = try connection.executor(MariaDB.self)
            return try await db.select(u.id, u.name).from(u).fetch(on: db)
        } else {
            let db = try connection.executor(MySQL.self)
            return try await db.select(u.id, u.name).from(u).fetch(on: db)
        }
    }

    @Test("predicates and bindings round-trip", arguments: TestServers.all)
    func predicatesBind(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        try await Self.seed(connection)
        

        let u = Users()
        let rows: [(String, Int64)]
        if server.flavor == .mariaDB {
            let db = try connection.executor(MariaDB.self)
            rows = try await db.select(u.name, u.score).from(u).where(u.score > 100).fetch(on: db)
        } else {
            let db = try connection.executor(MySQL.self)
            rows = try await db.select(u.name, u.score).from(u).where(u.score > 100).fetch(on: db)
        }

        #expect(rows.count == 2)
        #expect(Set(rows.map(\.0)) == ["grace", "alan"])
        // The comparison value travelled as a bound parameter, not interpolated
        // text — which is what makes the builder injection-safe.
        #expect(rows.allSatisfy { $0.1 > 100 })
    }

    @Test("fetchFirst returns nil on no match", arguments: [TestServers.latest])
    func fetchFirstNil(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        try await Self.seed(connection)
        

        let u = Users()
        let db = try connection.executor(MariaDB.self)
        let hit = try await db.select(u.id, u.name).from(u).where(u.name == "ada").fetchFirst(on: db)
        #expect(hit?.0 == 1)

        let miss = try await db.select(u.id, u.name).from(u).where(u.name == "nobody")
            .fetchFirst(on: db)
        #expect(miss == nil)
    }

    /// The driver's backpressure reaching the builder: rows decode lazily into
    /// the projection tuple as they arrive.
    @Test("streaming decodes lazily into tuples", arguments: [TestServers.latest])
    func streamDecodes(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        try await Self.seed(connection)
        

        let u = Users()
        let db = try connection.executor(MariaDB.self)
        var names: [String] = []
        try await db.select(u.id, u.name).from(u).forEach(on: db) { _, name in
            names.append(name)
        }
        #expect(names.sorted() == ["ada", "alan", "edsger", "grace"])

        // The untyped escape hatch iterates as an ordinary AsyncSequence.
        var count = 0
        for try await _ in try await db.select(u.id).from(u).streamRows(on: db) { count += 1 }
        #expect(count == 4)
    }

    /// Streaming a query that has a `WHERE` clause — which is to say, almost
    /// every real query.
    ///
    /// This used to be refused outright: the executor's streaming path took no
    /// bindings, so anything parameterised threw. The connection had supported
    /// it the whole time through a prepared statement and the binary protocol;
    /// only the bridge was missing. Refusing was the right call over
    /// interpolating the values into the SQL, but it left the builder unable to
    /// stream anything selective.
    @Test("a parameterised query streams", arguments: [TestServers.latest])
    func parameterisedStreamDecodes(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        try await Self.seed(connection)
        

        let u = Users()
        let db = try connection.executor(MariaDB.self)

        var names: [String] = []
        try await db.select(u.id, u.name).from(u).where(u.name == "ada").forEach(on: db) { _, name in
            names.append(name)
        }
        #expect(names == ["ada"])

        // And through the untyped sequence, so both paths carry the bindings.
        var count = 0
        for try await _ in try await db.select(u.id).from(u).where(u.id > 1).streamRows(on: db) {
            count += 1
        }
        #expect(count == 3)
    }

    // MARK: - Dialect safety

    /// The check that makes the compile-time dialect typing honest: asking for
    /// the wrong dialect must fail, or a `MariaDB`-typed query using `RETURNING`
    /// would compile and then fail at runtime on MySQL — exactly what the
    /// capability protocols exist to prevent.
    @Test("asking for the wrong dialect is refused", arguments: TestServers.all)
    func wrongDialectRefused(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        if server.flavor == .mariaDB {
            #expect(throws: (any Error).self) { _ = try connection.executor(MySQL.self) }
            _ = try connection.executor(MariaDB.self)
        } else {
            #expect(throws: (any Error).self) { _ = try connection.executor(MariaDB.self) }
            _ = try connection.executor(MySQL.self)
        }
    }

    @Test("anyExecutor picks the server's own dialect", arguments: TestServers.all)
    func anyExecutorMatchesServer(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        try await Self.seed(connection)
        

        let rows = try await connection.anyExecutor.execute(
            sql: "SELECT name FROM \(Users.tableName) ORDER BY id", bindings: []
        )
        #expect(rows.count == 4)
        #expect(rows[0].values[0] == .text("ada"))
    }

    // MARK: - Value bridging

    /// Every `SQLValue` case has to survive the round trip through bind
    /// parameters and back out as a result value.
    @Test("all value kinds round-trip through bindings", arguments: [TestServers.latest])
    func valueRoundTrip(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        let db = try connection.executor(MariaDB.self)

        // Through real columns, not bare `SELECT ?`. For a bare parameter the
        // *server* decides the result column's type and reports a bound byte
        // string as text — so `SELECT ?` cannot distinguish blob from text no
        // matter what the client does. A declared BLOB column can, and that is
        // the case that actually matters.
        let table = "exec_values_\(UInt32.random(in: 0..<UInt32.max))"
        _ = try await db.executeUpdate(
            sql: """
            CREATE TEMPORARY TABLE \(table) (
                i BIGINT, d DOUBLE, t VARCHAR(32), b BLOB, n INT NULL
            )
            """,
            bindings: []
        )
        _ = try await db.executeUpdate(
            sql: "INSERT INTO \(table) VALUES (?, ?, ?, ?, ?)",
            bindings: [.int(42), .double(1.5), .text("hello"), .blob([1, 2, 3]), .null]
        )

        let rows = try await db.execute(sql: "SELECT i, d, t, b, n FROM \(table)", bindings: [])
        let values = rows[0].values
        #expect(values[0] == .int(42))
        #expect(values[1] == .double(1.5))
        #expect(values[2] == .text("hello"))
        // The one the column metadata is needed for: these bytes are valid
        // UTF-8, so guessing from the bytes alone yields `.text`.
        #expect(values[3] == .blob([1, 2, 3]))
        #expect(values[4] == .null)
    }

    /// MySQL has no boolean type — `BOOL` is an alias for `TINYINT(1)` — so a
    /// bound `.bool` comes back as an integer. Pinned so the asymmetry is a
    /// recorded decision rather than a surprise.
    @Test("bool binds as an integer", arguments: [TestServers.latest])
    func boolBindsAsInteger(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        let db = try connection.executor(MariaDB.self)

        let rows = try await db.execute(sql: "SELECT ?, ?", bindings: [.bool(true), .bool(false)])
        #expect(rows[0].values[0] == .int(1))
        #expect(rows[0].values[1] == .int(0))
    }

    @Test("executeUpdate reports affected rows", arguments: [TestServers.latest])
    func updateReportsAffected(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        try await Self.seed(connection)
        

        let db = try connection.executor(MariaDB.self)
        let changed = try await db.executeUpdate(
            sql: "UPDATE \(Users.tableName) SET score = score + 1 WHERE score > ?",
            bindings: [.int(100)]
        )
        #expect(changed == 2)
    }
}

/// INSERT through the builder, plus the pool and transaction surfaces an
/// application actually uses.
///
/// Serialised for the same reason as `ExecutorTests`: `SQLTable.tableName` is
/// static, so the fixture table is shared.
@Suite(
    "Executor writes",
    .serialized,
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct ExecutorWriteTests {

    /// A **distinct** table from `ExecutorTests.Users`.
    ///
    /// `.serialized` orders cases *within* a suite but not between suites, so
    /// two suites sharing one static `tableName` still race to create and drop
    /// it — which is exactly what happened: green in isolation, green on Linux
    /// where integration tests skip, and failing only in a full macOS run.
    struct Users: SQLTable {
        static let tableName = "exec_write_users"
        var tableAlias: String?

        var id: SQLExpression<Int64> { column("id") }
        var name: SQLExpression<String> { column("name") }
        var score: SQLExpression<Int64> { column("score") }
    }

    static func prepare(_ connection: MySQLConnection) async throws {
        _ = try await connection.query("DROP TABLE IF EXISTS \(Users.tableName)")
        _ = try await connection.query(
            """
            CREATE TABLE \(Users.tableName) (
                id INT PRIMARY KEY, name VARCHAR(64) NOT NULL, score BIGINT NOT NULL
            )
            """
        )
    }

    @Test("a built INSERT executes", arguments: TestServers.mariaDB)
    func insertExecutes(server: MySQLTestServer) async throws {
        let connection = try await ExecutorTests.connect(server)
        defer { connection.closeImmediately() }
        try await Self.prepare(connection)
        

        let db = try connection.executor(MariaDB.self)
        let affected = try await InsertQuery<MariaDB, Users>(into: Users())
            .values([("id", .int(1)), ("name", .text("ada")), ("score", .int(100))])
            .values([("id", .int(2)), ("name", .text("grace")), ("score", .int(250))])
            .execute(on: db)

        #expect(affected == 2)

        let u = Users()
        let rows = try await db.select(u.id, u.name).from(u).fetch(on: db)
        #expect(rows.count == 2)
        #expect(rows.map(\.1).sorted() == ["ada", "grace"])
    }

    /// `ON DUPLICATE KEY UPDATE` is MySQL-family only, and reachable *only*
    /// because the dialect conforms to `SupportsOnDuplicateKeyUpdate`. On
    /// Postgres this call site would not compile.
    @Test("ON DUPLICATE KEY UPDATE renders and runs", arguments: TestServers.mariaDB)
    func onDuplicateKeyUpdate(server: MySQLTestServer) async throws {
        let connection = try await ExecutorTests.connect(server)
        defer { connection.closeImmediately() }
        try await Self.prepare(connection)
        

        let db = try connection.executor(MariaDB.self)
        _ = try await InsertQuery<MariaDB, Users>(into: Users())
            .values([("id", .int(1)), ("name", .text("ada")), ("score", .int(100))])
            .execute(on: db)

        // Same primary key, new score.
        _ = try await InsertQuery<MariaDB, Users>(into: Users())
            .values([("id", .int(1)), ("name", .text("ada")), ("score", .int(999))])
            .onDuplicateKeyUpdate { $0.set(Users().score, to: $0.values(Users().score)) }
            .execute(on: db)

        let u = Users()
        let rows = try await db.select(u.id, u.score).from(u).fetch(on: db)
        #expect(rows.count == 1, "the upsert inserted a second row instead of updating")
        #expect(rows[0].1 == 999)
    }

    /// `INSERT IGNORE`, gated on `SupportsInsertIgnore`.
    @Test("INSERT IGNORE skips duplicates", arguments: TestServers.mariaDB)
    func insertIgnore(server: MySQLTestServer) async throws {
        let connection = try await ExecutorTests.connect(server)
        defer { connection.closeImmediately() }
        try await Self.prepare(connection)
        

        let db = try connection.executor(MariaDB.self)
        _ = try await InsertQuery<MariaDB, Users>(into: Users())
            .values([("id", .int(1)), ("name", .text("ada")), ("score", .int(1))])
            .execute(on: db)

        // Without IGNORE this would be a duplicate-key error.
        let affected = try await InsertQuery<MariaDB, Users>(into: Users())
            .values([("id", .int(1)), ("name", .text("other")), ("score", .int(2))])
            .orIgnore()
            .execute(on: db)
        #expect(affected == 0)

        let u = Users()
        // A single-column projection decodes to the bare value, not a 1-tuple:
        // a one-element parameter pack collapses.
        let rows = try await db.select(u.name).from(u).fetch(on: db)
        #expect(rows == ["ada"])
    }

    /// `RETURNING` on an INSERT — MariaDB has it, MySQL does not, and the
    /// difference is enforced at compile time by `SupportsReturning`.
    @Test("RETURNING decodes inserted rows", arguments: TestServers.mariaDB)
    func insertReturning(server: MySQLTestServer) async throws {
        let connection = try await ExecutorTests.connect(server)
        defer { connection.closeImmediately() }
        try await Self.prepare(connection)
        

        let db = try connection.executor(MariaDB.self)
        let u = Users()
        let returned = try await InsertQuery<MariaDB, Users>(into: Users())
            .values([("id", .int(7)), ("name", .text("edsger")), ("score", .int(42))])
            .returning(u.id, u.name)
            .execute(on: db)

        #expect(returned.count == 1)
        #expect(returned[0].0 == 7)
        #expect(returned[0].1 == "edsger")
    }

    // MARK: - Pool and transactions

    @Test("the pool hands out typed executors", arguments: [TestServers.latest])
    func poolExecutor(server: MySQLTestServer) async throws {
        let setup = try await ExecutorTests.connect(server)
        try await Self.prepare(setup)
        setup.closeImmediately()
        // No detached cleanup here, for the reason this suite already learned
        // once and this test was missed by: a `defer { Task { DROP … } }` escapes
        // `.serialized`, so it lands whenever it lands — including after a *later*
        // test has prepared the same shared table, which then vanishes mid-test
        // with "Table 'swizzle_test.exec_write_users' doesn't exist".
        //
        // This one was worse than the thirteen already removed, because it opens
        // its own connection first and so lands later still. It stayed hidden
        // while few tests followed it and surfaced at roughly one run in ten once
        // eight more were added after it. `prepare()` drops and recreates, so
        // every test starts from a known state without any cleanup at all.

        let user = server.primaryUser
        let client = MySQLClient(
            configuration: .init(
                connection: .init(
                    address: .hostname(TestServers.host, port: server.port),
                    username: user.name, password: user.password,
                    database: TestServers.database, tls: .disable
                ),
                minimumConnections: 0,
                maximumConnections: 4
            ),
            eventLoopGroup: TestServers.group
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }

            _ = try await client.withExecutor(MariaDB.self) { db in
                try await InsertQuery<MariaDB, Users>(into: Users())
                    .values([("id", .int(1)), ("name", .text("pooled")), ("score", .int(5))])
                    .execute(on: db)
            }

            let names = try await client.withExecutor(MariaDB.self) { db in
                let u = Users()
                return try await db.select(u.name).from(u).fetch(on: db)
            }
            #expect(names == ["pooled"])

            group.cancelAll()
        }
    }

    /// A transaction that throws must leave nothing behind.
    @Test("a failed transaction rolls back the built writes", arguments: [TestServers.latest])
    func transactionRollsBack(server: MySQLTestServer) async throws {
        let connection = try await ExecutorTests.connect(server)
        defer { connection.closeImmediately() }
        try await Self.prepare(connection)
        

        let db = try connection.executor(MariaDB.self)
        struct Deliberate: Error {}

        await #expect(throws: Deliberate.self) {
            try await db.withTransaction { tx in
                _ = try await InsertQuery<MariaDB, Users>(into: Users())
                    .values([("id", .int(1)), ("name", .text("doomed")), ("score", .int(1))])
                    .execute(on: tx)
                throw Deliberate()
            }
        }

        let u = Users()
        let rows = try await db.select(u.id).from(u).fetch(on: db)
        #expect(rows.isEmpty, "the rolled-back insert is still there")
    }

    @Test("a committed transaction persists", arguments: [TestServers.latest])
    func transactionCommits(server: MySQLTestServer) async throws {
        let connection = try await ExecutorTests.connect(server)
        defer { connection.closeImmediately() }
        try await Self.prepare(connection)
        

        let db = try connection.executor(MariaDB.self)
        try await db.withTransaction { tx in
            _ = try await InsertQuery<MariaDB, Users>(into: Users())
                .values([("id", .int(1)), ("name", .text("kept")), ("score", .int(1))])
                .execute(on: tx)
        }

        let u = Users()
        let rows = try await db.select(u.name).from(u).fetch(on: db)
        #expect(rows == ["kept"])
    }

    // MARK: - UPDATE and DELETE against a real server

    /// The write fixture, populated. `prepare` leaves the table empty.
    static func seedRows(_ connection: MySQLConnection) async throws {
        try await prepare(connection)
        _ = try await connection.query(
            """
            INSERT INTO \(Users.tableName) VALUES
            (1,'ada',100),(2,'grace',250),(3,'alan',175),(4,'edsger',50)
            """
        )
    }

    /// Rendering the right string is not the same as the server accepting it.
    @Test("a built UPDATE reaches the right rows", arguments: TestServers.mariaDB)
    func builtUpdateApplies(server: MySQLTestServer) async throws {
        let connection = try await ExecutorTests.connect(server)
        defer { connection.closeImmediately() }
        try await Self.seedRows(connection)
        let db = try connection.executor(MariaDB.self)
        let u = Users()

        let affected = try await QueryBuilder<MariaDB>()
            .update(u)
            .set(u.name, to: "ada lovelace")
            .where(u.id == 1)
            .execute(on: db)
        #expect(affected == 1)

        let rows = try await db.select(u.name).from(u).where(u.id == 1).fetch(on: db)
        #expect(rows.first == "ada lovelace")
    }

    /// `views = views + 1` is the assignment builders usually cannot express, so
    /// it is worth proving against a server rather than against a string.
    @Test("an expression assignment is evaluated by the server", arguments: TestServers.mariaDB)
    func expressionAssignmentApplies(server: MySQLTestServer) async throws {
        let connection = try await ExecutorTests.connect(server)
        defer { connection.closeImmediately() }
        try await Self.seedRows(connection)
        let db = try connection.executor(MariaDB.self)
        let u = Users()

        _ = try await QueryBuilder<MariaDB>()
            .update(u)
            .set(u.score, to: u.score + 5)
            .where(u.id == 1)
            .execute(on: db)

        let rows = try await db.select(u.score).from(u).where(u.id == 1).fetch(on: db)
        #expect(rows.first == 105)
    }

    @Test("a built DELETE removes only the matching rows", arguments: TestServers.mariaDB)
    func builtDeleteApplies(server: MySQLTestServer) async throws {
        let connection = try await ExecutorTests.connect(server)
        defer { connection.closeImmediately() }
        try await Self.seedRows(connection)
        let db = try connection.executor(MariaDB.self)
        let u = Users()

        let removed = try await QueryBuilder<MariaDB>()
            .delete(from: u)
            .where(u.score < 120)
            .execute(on: db)
        #expect(removed == 2)

        let remaining = try await db.select(u.id).from(u).fetch(on: db)
        #expect(remaining.count == 2)
    }

    /// `DELETE … ORDER BY … LIMIT` is the batched-drain shape, and it is gated to
    /// the MySQL family precisely because Postgres cannot run it.
    @Test("DELETE with ORDER BY and LIMIT drains in batches", arguments: TestServers.mariaDB)
    func deleteWithLimitDrains(server: MySQLTestServer) async throws {
        let connection = try await ExecutorTests.connect(server)
        defer { connection.closeImmediately() }
        try await Self.seedRows(connection)
        let db = try connection.executor(MariaDB.self)
        let u = Users()

        var drained = 0
        while true {
            let batch = try await QueryBuilder<MariaDB>()
                .delete(from: u)
                .orderBy(u.id.asc)
                .limit(3)
                .execute(on: db)
            if batch == 0 { break }
            drained += batch
        }
        #expect(drained == 4)
    }

    /// A raw statement routed through the builder still binds, and the server
    /// still has to accept what comes out.
    @Test("a raw statement binds and executes", arguments: TestServers.mariaDB)
    func rawStatementExecutes(server: MySQLTestServer) async throws {
        let connection = try await ExecutorTests.connect(server)
        defer { connection.closeImmediately() }
        try await Self.seedRows(connection)
        let db = try connection.executor(MariaDB.self)

        let rows = try await QueryBuilder<MariaDB>()
            .raw("SELECT name, score FROM \(identifier: Users.tableName) WHERE score > \(120) ORDER BY score")
            .fetch((String, Int64).self, on: db)

        #expect(rows.map(\.0) == ["alan", "grace"])
    }


    // MARK: - The bound path: db appears once

    /// The whole point of binding: no `on:` anywhere in the chain.
    @Test("a bound write runs without being handed the connection back", arguments: TestServers.mariaDB)
    func boundWriteNeedsNoOn(server: MySQLTestServer) async throws {
        let connection = try await ExecutorTests.connect(server)
        defer { connection.closeImmediately() }
        try await Self.seedRows(connection)
        let db = try connection.executor(MariaDB.self)
        let u = Users()

        let affected = try await db.update(u)
            .set(u.name, to: "ada lovelace")
            .where(u.id == 1)
            .execute()
        #expect(affected == 1)

        let name = try await db.select(u.name).from(u).where(u.id == 1).fetchFirst()
        #expect(name == "ada lovelace")

        let removed = try await db.delete(from: u).where(u.score < 60).execute()
        #expect(removed == 1)
    }

    /// Red line 6: streaming should read like fetching. Both are `for … in` over
    /// typed rows, and this runs the same query through each.
    @Test("stream and fetch return the same rows in the same shape", arguments: TestServers.mariaDB)
    func streamMatchesFetch(server: MySQLTestServer) async throws {
        let connection = try await ExecutorTests.connect(server)
        defer { connection.closeImmediately() }
        try await Self.seedRows(connection)
        let db = try connection.executor(MariaDB.self)
        let u = Users()

        var fetched: [String] = []
        for (_, name) in try await db.select(u.id, u.name).from(u).fetch() {
            fetched.append(name)
        }

        var streamed: [String] = []
        for try await row in try await db.select(u.id, u.name).from(u).stream() {
            let (_, name) = row.values
            streamed.append(name)
        }

        #expect(fetched.sorted() == streamed.sorted())
        #expect(streamed.count == 4)
    }

    /// Abandoning a bound stream part-way must still release the connection —
    /// the erasure forwards `next()` rather than buffering, so the driver's
    /// existing cancellation path is untouched.
    @Test("an abandoned bound stream leaves the connection usable", arguments: TestServers.mariaDB)
    func abandonedBoundStreamReleases(server: MySQLTestServer) async throws {
        let connection = try await ExecutorTests.connect(server)
        defer { connection.closeImmediately() }
        try await Self.seedRows(connection)
        let db = try connection.executor(MariaDB.self)
        let u = Users()

        for try await _ in try await db.select(u.id, u.name).from(u).stream() { break }

        let remaining = try await db.select(u.id).from(u).fetch()
        #expect(remaining.count == 4)
    }

    /// Red line 4, against a real server: SQL with `?` placeholders, unmodified.
    @Test("a bound raw statement with ? placeholders runs", arguments: TestServers.mariaDB)
    func boundRawWithPlaceholders(server: MySQLTestServer) async throws {
        let connection = try await ExecutorTests.connect(server)
        defer { connection.closeImmediately() }
        try await Self.seedRows(connection)
        let db = try connection.executor(MariaDB.self)

        let rows = try await db
            .raw("SELECT name, score FROM \(Users.tableName) WHERE score > ? ORDER BY score", [.int(120)])
            .fetch((String, Int64).self)

        #expect(rows.map(\.0) == ["alan", "grace"])
    }

    /// Conditional building against a real server, both branches.
    @Test("conditional clauses change the statement that runs", arguments: TestServers.mariaDB)
    func conditionalClausesRun(server: MySQLTestServer) async throws {
        let connection = try await ExecutorTests.connect(server)
        defer { connection.closeImmediately() }
        try await Self.seedRows(connection)
        let db = try connection.executor(MariaDB.self)
        let u = Users()

        func load(minimumScore: Int64?) async throws -> [Int64] {
            try await db.select(u.id).from(u)
                .ifLet(minimumScore) { $0.where(u.score >= $1) }
                .fetch()
        }

        #expect(try await load(minimumScore: nil).count == 4)
        #expect(try await load(minimumScore: 150).count == 2)
    }

    /// A CTE and a UNION, executed rather than just rendered.
    @Test("CTEs and set operations execute", arguments: TestServers.mariaDB)
    func ctesAndUnionsExecute(server: MySQLTestServer) async throws {
        let connection = try await ExecutorTests.connect(server)
        defer { connection.closeImmediately() }
        try await Self.seedRows(connection)
        let db = try connection.executor(MariaDB.self)
        let u = Users()

        let high = QueryBuilder<MariaDB>().select(u.id).from(u).where(u.score > 150)
        // Columns are projected from a table aliased to the CTE's name, so the
        // qualifiers match the FROM. See `from(cte:)`.
        let h = Users(tableAlias: "high")
        let viaCTE = try await db.query
            .with("high", as: high)
            .select(h.id)
            .from(cte: "high")
            .fetch()
        #expect(viaCTE.count == 2)

        let low = QueryBuilder<MariaDB>().select(u.id).from(u).where(u.score < 60)
        let combined = try await db.select(u.id).from(u).where(u.score > 150)
            .unionAll(low)
            .fetch()
        #expect(combined.count == 3)
    }


    // MARK: - Constructs that used to require a full raw rewrite

    /// `FOR UPDATE SKIP LOCKED` is the queue-worker pattern, and it has to be
    /// proven against a server: the syntax is accepted in more places than the
    /// semantics actually work.
    @Test("SELECT … FOR UPDATE SKIP LOCKED runs", arguments: TestServers.mariaDB)
    func lockingRuns(server: MySQLTestServer) async throws {
        let connection = try await ExecutorTests.connect(server)
        defer { connection.closeImmediately() }
        try await Self.seedRows(connection)
        let db = try connection.executor(MariaDB.self)
        let u = Users()

        try await connection.query("BEGIN")
        let locked = try await db.select(u.id).from(u)
            .where(u.score > 100)
            .orderBy(u.id.asc)
            .limit(1)
            .forUpdate(.skipLocked)
            .fetch()
        #expect(locked.count == 1)
        try await connection.query("COMMIT")
    }

    /// `INSERT … SELECT` — the backfill shape.
    @Test("INSERT … SELECT copies rows", arguments: TestServers.mariaDB)
    func insertFromSelectRuns(server: MySQLTestServer) async throws {
        let connection = try await ExecutorTests.connect(server)
        defer { connection.closeImmediately() }
        try await Self.seedRows(connection)
        let db = try connection.executor(MariaDB.self)
        let u = Users()

        _ = try await connection.query(
            "CREATE TEMPORARY TABLE \(Users.tableName)_copy LIKE \(Users.tableName)"
        )

        let copied = try await db.insert(into: ArchiveUsers())
            .columns(ArchiveUsers().id, ArchiveUsers().name, ArchiveUsers().score)
            .select(QueryBuilder<MariaDB>().select(u.id, u.name, u.score).from(u).where(u.score > 100))
            .execute()
        #expect(copied == 2)
    }

    /// The general escape: a clause the builder does not model, appended without
    /// giving up the rest of the query.
    @Test("an appended fragment reaches the server intact", arguments: TestServers.mariaDB)
    func appendedFragmentRuns(server: MySQLTestServer) async throws {
        let connection = try await ExecutorTests.connect(server)
        defer { connection.closeImmediately() }
        try await Self.seedRows(connection)
        let db = try connection.executor(MariaDB.self)
        let u = Users()

        let rows = try await db.select(u.id).from(u)
            .where(u.score > 0)
            // `\(inline:)`, not plain interpolation: a comment cannot hold a
            // parameter. Plain interpolation there is now refused before the
            // statement leaves the process — see the assertion below.
            .appending("/* swizzle tenant \(inline: 7) */")
            .fetch()
        #expect(rows.count == 4)

        // The trap this test originally fell into, now caught locally rather
        // than by the server replying "statement expects 1 parameters, got 2".
        await #expect(throws: SQLBindingInDeadPosition.self) {
            _ = try await db.select(u.id).from(u).appending("/* tenant \(7) */").fetch()
        }
    }

    /// The temporary table `INSERT … SELECT` writes into.
    struct ArchiveUsers: SQLTable {
        static let tableName = "exec_write_users_copy"
        var tableAlias: String?
        var id: SQLColumn<Int64> { bigInt("id") }
        var name: SQLColumn<String> { varchar("name", 64) }
        var score: SQLColumn<Int64> { bigInt("score") }
    }

}

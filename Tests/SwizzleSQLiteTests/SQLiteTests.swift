import Foundation
import SwizzleCore
import SwizzleMigrate
import SwizzleQuery
import Testing
@testable import SwizzleSQLite
@testable import SwizzleSQLiteEngine

/// SQLite needs no server, so unlike MySQL and Postgres these are ordinary unit
/// tests: `swift test` exercises a real database on every machine, with no
/// fixture to start and nothing to skip.
@Suite("SQLite")
struct SQLiteTests {

    struct Users: SQLTable {
        static let tableName = "users"
        var tableAlias: String?
        var id: SQLColumn<Int64> { bigInt("id") }
        var name: SQLColumn<String> { varchar("name", 64) }
        var score: SQLColumn<Int64> { int("score") }
        var nickname: SQLColumn<String?> { varchar("nickname", 64) }
    }

    static func seeded() async throws -> SQLiteConnection {
        let connection = try SQLiteConnection.inMemory()
        _ = try await connection.query(
            """
            CREATE TABLE users (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                score INTEGER NOT NULL DEFAULT 0,
                nickname TEXT
            )
            """
        )
        _ = try await connection.query(
            "INSERT INTO users (id, name, score) VALUES (1,'ada',100),(2,'grace',250),(3,'alan',175)"
        )
        return connection
    }

    // MARK: - The builder, unchanged

    @Test("a built query runs and decodes")
    func builtQueryRuns() async throws {
        let connection = try await Self.seeded()
        defer { connection.close() }
        let db = connection.executor
        let u = Users()

        let rows = try await db.select(u.id, u.name).from(u).where(u.score > 120).fetch()
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.1)) == ["grace", "alan"])
    }

    /// The value round-trip is where SQLite differs most: it has no boolean, no
    /// fixed column types, and stores whatever it is given.
    @Test("every value kind round-trips")
    func valuesRoundTrip() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }
        _ = try await connection.query("CREATE TABLE t (i INTEGER, d REAL, s TEXT, b BLOB, n TEXT)")
        _ = try await connection.query(
            "INSERT INTO t VALUES (?1, ?2, ?3, ?4, ?5)",
            [.int(42), .double(1.5), .text("O'Brien"), .blob([0xDE, 0xAD]), .null]
        )

        let row = try #require(try await connection.query("SELECT * FROM t").first)
        #expect(row.values[0] == .int(42))
        #expect(row.values[1] == .double(1.5))
        #expect(row.values[2] == .text("O'Brien"))
        #expect(row.values[3] == .blob([0xDE, 0xAD]))
        #expect(row.values[4] == .null)
    }

    /// SQLite has no boolean type; `true` goes in as 1 and comes back as an
    /// integer, which is the documented convention rather than a lossy cast.
    @Test("booleans bind as 0 and 1")
    func booleansBindAsIntegers() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }
        _ = try await connection.query("CREATE TABLE t (flag INTEGER)")
        _ = try await connection.query("INSERT INTO t VALUES (?1)", [.bool(true)])
        let row = try #require(try await connection.query("SELECT flag FROM t").first)
        #expect(row.values[0] == .int(1))
        #expect(try Bool(sqlValue: row.values[0]))
    }

    @Test("affected rows are reported")
    func affectedRowsReported() async throws {
        let connection = try await Self.seeded()
        defer { connection.close() }
        let db = connection.executor
        let u = Users()

        // The thing the Postgres executor still cannot do.
        let updated = try await db.update(u).set(u.score, to: 0).where(u.score > 120).execute()
        #expect(updated == 2)

        let deleted = try await db.delete(from: u).where(u.id == 1).execute()
        #expect(deleted == 1)
    }

    // MARK: - Capability gates, from the side that lacks things

    /// SQLite is the first engine that genuinely *lacks* a capability the others
    /// have, so it is the real test of whether the gates describe reality.
    ///
    /// `.forUpdate()` does not compile here — SQLite's locking is whole-database,
    /// so there is no row-level lock to ask for. `.onDuplicateKeyUpdate` does not
    /// compile either. Both are asserted by `Scripts/negative-tests.sh`, which
    /// checks that the code *fails* to build, since a passing test cannot.
    @Test("the capabilities SQLite does have work")
    func supportedCapabilitiesWork() async throws {
        let connection = try await Self.seeded()
        defer { connection.close() }
        let db = connection.executor
        let u = Users()

        // RETURNING — SQLite has had it since 3.35.
        let returned = try await db.insert(into: u)
            .values { $0.set(u.id, to: 9); $0.set(u.name, to: "edsger"); $0.set(u.score, to: 50) }
            .returning(u.id, u.name)
            .execute()
        #expect(returned.first?.1 == "edsger")

        // ON CONFLICT — the Postgres spelling, which SQLite shares.
        _ = try await db.insert(into: u)
            .values { $0.set(u.id, to: 9); $0.set(u.name, to: "dijkstra"); $0.set(u.score, to: 1) }
            .onConflict(u.id)
            .doUpdate { $0.set(u.name, to: $0.excluded(u.name)) }
            .execute()

        let name = try await db.select(u.name).from(u).where(u.id == 9).fetchFirst()
        #expect(name == "dijkstra")

        // INSERT OR IGNORE — spelled differently from MySQL's INSERT IGNORE, and
        // the renderer already knew that.
        let ignored = try await db.insert(into: u)
            .orIgnore()
            .values { $0.set(u.id, to: 9); $0.set(u.name, to: "x"); $0.set(u.score, to: 0) }
            .execute()
        #expect(ignored == 0)
    }

    // MARK: - Streaming

    /// Written down as the engine that "cannot stream". It streams natively:
    /// `sqlite3_step` produces one row per call and does no work until asked.
    @Test("streaming yields the same rows as fetching")
    func streamingMatchesFetching() async throws {
        let connection = try await Self.seeded()
        defer { connection.close() }
        let db = connection.executor
        let u = Users()

        var streamed: [String] = []
        for try await row in try await db.select(u.id, u.name).from(u).stream() {
            streamed.append(row.values.1)
        }
        let fetched = try await db.select(u.id, u.name).from(u).fetch().map(\.1)
        #expect(streamed.sorted() == fetched.sorted())
    }

    /// Abandoning a stream must end the walk and finalise the statement, or the
    /// connection is left with a live statement — the bug this project already
    /// paid for once in the MySQL driver.
    @Test("an abandoned stream leaves the connection usable")
    func abandonedStreamReleases() async throws {
        let connection = try await Self.seeded()
        defer { connection.close() }
        let db = connection.executor
        let u = Users()

        for try await _ in try await db.select(u.id, u.name).from(u).stream() { break }

        let after = try await db.select(u.id).from(u).fetch()
        #expect(after.count == 3)
    }

    /// Backpressure, proven rather than asserted.
    ///
    /// A `bufferingOldest(1)` stream passed the "same rows" test only by luck of
    /// row count; what it could never do is stop reading. This inserts far more
    /// rows than any buffer would hold, takes three, and stops — then checks that
    /// the walk actually stopped by confirming the connection is immediately
    /// usable for another statement rather than still stepping the last one.
    /// Proves ordering and that `break` works — **not** laziness. An
    /// implementation that materialised all 50,000 rows and handed them out one
    /// at a time would pass this identically, because the consumer only reads
    /// three either way. `SQLiteLazinessTests` is what actually pins that, by
    /// streaming a query with no last row.
    @Test("a stream reads only as far as it is asked to")
    func streamingStopsWhenTheConsumerDoes() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }
        _ = try await connection.query("CREATE TABLE big (n INTEGER)")
        _ = try await connection.query(
            """
            WITH RECURSIVE series(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM series WHERE n < 50000)
            INSERT INTO big SELECT n FROM series
            """
        )

        var seen: [Int64] = []
        for try await row in try await connection.executor.stream(sql: "SELECT n FROM big ORDER BY n", bindings: []) {
            seen.append(row.values[0].intValue ?? -1)
            if seen.count == 3 { break }
        }

        // Exactly three, not three-plus-whatever-a-buffer-held.
        #expect(seen == [1, 2, 3])

        let total = try await connection.query("SELECT COUNT(*) FROM big")
        #expect(total.first?.values.first == .int(50_000))
    }

    /// The bound path has to reach SQLite's *streaming* witness, not the plain
    /// `SQLExecutor` one.
    ///
    /// This is the exact shape of a bug already shipped once: `erased` resolved
    /// statically to the non-streaming overload, so a bound query silently lost
    /// the ability to stream on a driver that had it. Making `erased` a protocol
    /// requirement fixed it — and a second engine conforming to both protocols is
    /// the thing that proves the fix rather than assuming it.
    @Test("a bound query streams through the erased executor")
    func boundStreamingReachesTheStreamingWitness() async throws {
        let connection = try await Self.seeded()
        defer { connection.close() }
        let db = connection.executor
        let u = Users()

        #expect(db.erased.canStream, "the erased SQLite executor must keep its streaming path")

        var names: [String] = []
        for try await row in try await db.select(u.id, u.name).from(u).stream() {
            names.append(row.values.1)
        }
        #expect(names.sorted() == ["ada", "alan", "grace"])
    }

    /// An empty blob is not null, and must not become one.
    @Test("an empty blob round-trips as an empty blob")
    func emptyBlobRoundTrips() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }
        _ = try await connection.query("CREATE TABLE t (b BLOB, n BLOB)")
        _ = try await connection.query("INSERT INTO t VALUES (?1, ?2)", [.blob([]), .null])

        let row = try #require(try await connection.query("SELECT b, n FROM t").first)
        #expect(row.values[0] == .blob([]))
        #expect(row.values[1] == .null)
    }

    // MARK: - Introspection

    @Test("the introspector reads columns, keys and indexes")
    func introspectionReadsSchema() async throws {
        let connection = try await Self.seeded()
        defer { connection.close() }
        _ = try await connection.query("CREATE UNIQUE INDEX users_name ON users (name)")

        let schema = try await SQLiteIntrospector(connection).schema()
        let table = try #require(schema.table(named: "users"))

        #expect(table.estimatedRows == 3)
        #expect(table.column(named: "name")?.isNullable == false)
        #expect(table.column(named: "nickname")?.isNullable == true)
        #expect(table.column(named: "score")?.hasDefault == true)

        // A single INTEGER PRIMARY KEY *is* the rowid, whether or not
        // AUTOINCREMENT was written.
        #expect(table.column(named: "id")?.isAutoIncrement == true)
        #expect(table.primaryKey?.columns == ["id"])
        #expect(table.indexes.contains { $0.name == "users_name" && $0.isUnique })
    }

    // MARK: - URLs

    @Test("URLs resolve the way people write them")
    func urlsResolve() throws {
        #expect(try SQLiteURL.path(from: "sqlite:app.db") == "app.db")
        #expect(try SQLiteURL.path(from: "sqlite:./app.db") == "./app.db")
        #expect(try SQLiteURL.path(from: "sqlite:/var/db/app.db") == "/var/db/app.db")
        #expect(try SQLiteURL.path(from: "sqlite:///var/db/app.db") == "/var/db/app.db")
        #expect(try SQLiteURL.path(from: "sqlite::memory:") == ":memory:")
        // `file:` is SQLite's own URI form — handed over untouched so its query
        // parameters keep working.
        #expect(try SQLiteURL.path(from: "file:app.db?mode=ro") == "file:app.db?mode=ro")
    }

    /// `sqlite://app.db` names a *host*, not a path. Reading it as a relative
    /// path would open the wrong file — and opening the wrong SQLite path creates
    /// an empty database, which looks exactly like data loss.
    @Test("a two-slash URL is refused rather than guessed at")
    func twoSlashURLIsRefused() {
        #expect(throws: SQLiteURLError.self) { _ = try SQLiteURL.path(from: "sqlite://app.db") }
    }

    // MARK: - Migrations

    @Test("migrations apply, and the journal survives a second run")
    func migrationsApply() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swizzle-sqlite-\(UInt32.random(in: 0..<UInt32.max))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try """
        -- +swizzle Up
        CREATE TABLE widgets (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
        -- +swizzle Down
        DROP TABLE widgets;
        """.write(
            to: directory.appendingPathComponent("00001_widgets.sql"),
            atomically: true, encoding: .utf8
        )

        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }
        _ = try await connection.query(SQLite.createLockTable())

        let migrator = Migrator(
            executor: connection.executor.erased,
            dialect: AnyMigrationDialect(SQLite.self),
            source: MigrationDirectory(url: directory, syntax: SQLite.migrationSyntax)
        )

        let applied = try await migrator.up()
        #expect(applied.count == 1)

        // Idempotent: the journal is read, not guessed at.
        #expect(try await migrator.up().isEmpty)

        _ = try await connection.query("INSERT INTO widgets (id, name) VALUES (1, 'x')")
        let rows = try await connection.query("SELECT COUNT(*) FROM widgets")
        #expect(rows.first?.values.first == .int(1))
    }

    /// The lock is a row rather than an advisory lock, so the stale-entry rule is
    /// what keeps a crashed migrator from wedging the next deploy.
    @Test("a stale migration lock is taken over")
    func staleLockIsTakenOver() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }
        _ = try await connection.query(SQLite.createLockTable())

        // Someone took the lock and never released it, an hour ago.
        _ = try await connection.query(
            "INSERT INTO \(SQLite.lockTable) (name, acquired_at) VALUES (?1, strftime('%s','now') - 3600)",
            [.text("swizzle")]
        )

        let (sql, bindings) = SQLite.acquireLock(named: "swizzle", timeoutSeconds: 30)
        let rows = try await connection.query(sql, bindings)
        #expect(rows.first?.values.first == .int(1), "a lock older than the timeout should be taken over")
    }

    @Test("a fresh migration lock is not stolen")
    func freshLockIsHeld() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }
        _ = try await connection.query(SQLite.createLockTable())

        let (sql, bindings) = SQLite.acquireLock(named: "swizzle", timeoutSeconds: 30)
        #expect(try await connection.query(sql, bindings).first?.values.first == .int(1))

        // Immediately again: still held. `RETURNING` emits a row only for a row
        // actually written, so "not acquired" is **no rows** rather than a zero —
        // which is what the migrator's `?? false` reads it as.
        #expect(try await connection.query(sql, bindings).isEmpty)

        let (release, releaseBindings) = SQLite.releaseLock(named: "swizzle")
        _ = try await connection.query(release, releaseBindings)
        #expect(try await connection.query(sql, bindings).first?.values.first == .int(1))
    }

    // MARK: - Errors

    @Test("a bad statement reports what SQLite said")
    func errorsCarryContext() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }
        await #expect(throws: SQLiteError.self) {
            _ = try await connection.query("SELECT * FROM nope")
        }
    }

    @Test("a parameter-count mismatch is caught before stepping")
    func parameterCountChecked() async throws {
        let connection = try await Self.seeded()
        defer { connection.close() }
        await #expect(throws: SQLiteError.self) {
            _ = try await connection.query("SELECT * FROM users WHERE id = ?1", [])
        }
    }

    @Test("a closed connection refuses work rather than crashing")
    func closedConnectionRefuses() async throws {
        let connection = try SQLiteConnection.inMemory()
        connection.close()
        await #expect(throws: SQLiteError.self) { _ = try await connection.query("SELECT 1") }
    }
}

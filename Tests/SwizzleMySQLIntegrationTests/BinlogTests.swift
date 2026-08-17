import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing
@testable import SwizzleMySQL

/// Binlog streaming against real MariaDB.
///
/// Every test here uses `.nonBlocking` and a position captured *before* the
/// changes it makes. A blocking dump never ends, so a test that forgot that
/// would hang rather than fail — which is why the bounded form is the default
/// throughout and the one blocking test has an explicit escape.
@Suite(
    "Binlog",
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct BinlogTests {

    /// Server ids for replica connections, distinct per test so concurrent runs
    /// cannot evict each other. A collision makes the primary drop the *other*
    /// replica, which surfaces as an unrelated test failing.
    static let serverIDs = ManagedAtomicCounter(start: 90_000)

    static func connect(_ server: MySQLTestServer) async throws -> MySQLConnection {
        let user = server.primaryUser
        var config = MySQLConnectionConfiguration(
            address: .hostname(TestServers.host, port: server.port),
            username: user.name,
            password: user.password,
            database: TestServers.database,
            tls: .disable,
            serverPublicKey: .requestFromServer
        )
        config.maxAllowedPacket = 16 * 1024 * 1024
        return try await MySQLConnection.connect(configuration: config, on: TestServers.group.next())
    }

    /// Every event from `position` to the end of the log.
    ///
    /// ## The silent cap that made three suites flaky
    ///
    /// This used to stop at `limit` events and **return what it had**:
    ///
    /// ```swift
    /// if events.count >= limit { break }
    /// ```
    ///
    /// A binlog is server-wide, not table-wide, so everything every other test
    /// writes to this server lands between `position` and the rows the caller is
    /// looking for. Run a suite alone and there are 27 events; run the whole
    /// suite and the concurrent binlog, column-type and JSON tests push foreign
    /// events in front of yours by the hundred. Past 500 the caller's own rows
    /// were never reached, and the helper reported success with a short array.
    ///
    /// It presented as a Linux-only failure for months — `rows.count → 4` where 5
    /// were expected — and it is not platform-specific at all. It reproduces on
    /// macOS in one test: 300 unrelated inserts before five real ones yields
    /// `events=500, rows=0`. Linux differs only in how much interleaving its
    /// scheduling produces, which is why the count moved run to run (4 of 5, 3 of
    /// 5, 11 of 12, 4 of 12) and why the failing suite moved with it.
    ///
    /// The dump is non-blocking, so it ends at the end of the log on its own and
    /// no cap is needed to terminate it. `limit` is now a runaway guard that
    /// **throws** — a test that silently examines half its data is worse than one
    /// that stops and says so.
    /// - Parameter prefix: stop after this many events **on purpose**, for a
    ///   caller that genuinely wants only the head of the dump. Distinct from
    ///   `limit`, and the distinction is the whole fix: one is a caller saying
    ///   "four is all I want", the other is "something has gone wrong". They were
    ///   the same parameter, so the second silently behaved like the first.
    static func collect(
        _ server: MySQLTestServer,
        from position: (filename: String, position: UInt32),
        prefix: Int? = nil,
        limit: Int = 200_000
    ) async throws -> [MySQLBinlogEvent] {
        let replica = try await connect(server)
        defer { replica.closeImmediately() }

        let stream = try await replica.startBinlogStream(
            serverID: UInt32(serverIDs.next()),
            from: .file(name: position.filename, position: position.position),
            flags: .nonBlocking
        )

        var events: [MySQLBinlogEvent] = []
        for try await event in stream {
            events.append(event)
            if let prefix, events.count >= prefix { break }
            if events.count >= limit { throw BinlogCollectionOverflow(limit: limit) }
        }
        return events
    }

    static func makeTable(_ connection: MySQLConnection) async throws -> String {
        let name = "binlog_\(UInt32.random(in: 0..<UInt32.max))"
        // Not TEMPORARY: temporary tables are not row-logged, so a temp table
        // would produce no row events at all and every assertion here would
        // vacuously find nothing.
        _ = try await connection.query(
            "CREATE TABLE \(name) (id INT PRIMARY KEY, label VARCHAR(64), score BIGINT)"
        )
        return name
    }

    // MARK: - Stream basics

    @Test("reports a binlog position", arguments: TestServers.all)
    func reportsPosition(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let position = try await connection.binlogPosition()
        #expect(!position.filename.isEmpty)
        #expect(position.position >= 4)
    }

    /// The first two events of any dump are a fake ROTATE naming the file and a
    /// FORMAT_DESCRIPTION announcing the checksum algorithm. Everything after
    /// depends on the latter having been read correctly.
    @Test("a dump opens with ROTATE then FORMAT_DESCRIPTION", arguments: TestServers.all)
    func dumpPreamble(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        let start = try await connection.binlogPosition()

        let events = try await Self.collect(server, from: start, prefix: 4)
        let types = events.map(\.eventType)
        #expect(types.first == .rotate, "got \(String(describing: types))")
        #expect(types.dropFirst().first == .formatDescription)

        guard case .formatDescription(let fde) = events[1].payload else {
            Issue.record("expected a format description"); return
        }
        // The fixtures run with binlog_checksum=CRC32; if this were misread the
        // checksum verification in every later event would fail.
        #expect(fde.checksum == .crc32)
        #expect(!fde.serverVersion.isEmpty)
    }

    // MARK: - Row events

    @Test("captures INSERT as a write row event", arguments: TestServers.all)
    func capturesInsert(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        let start = try await connection.binlogPosition()
        _ = try await connection.query(
            "INSERT INTO \(table) (id, label, score) VALUES (1, 'alpha', 100)"
        )

        let events = try await Self.collect(server, from: start)
        let writes = events.compactMap { event -> MySQLRowsEvent? in
            guard case .rows(let rows) = event.payload, rows.kind == .write,
                  rows.table.table == table else { return nil }
            return rows
        }

        let write = try #require(writes.first, "no write row event for \(table)")
        #expect(write.table.schema == TestServers.database)
        #expect(write.rows.count == 1)
        #expect(write.rows[0][0].int == 1)
        #expect(write.rows[0][1].string == "alpha")
        #expect(write.rows[0][2].int == 100)
    }

    /// An UPDATE carries *both* images. Decoding only one is a common bug, and
    /// it stays invisible until a consumer needs the previous value.
    @Test("captures UPDATE with before and after images", arguments: TestServers.all)
    func capturesUpdate(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        _ = try await connection.query(
            "INSERT INTO \(table) (id, label, score) VALUES (7, 'before', 1)"
        )
        let start = try await connection.binlogPosition()
        _ = try await connection.query("UPDATE \(table) SET label = 'after', score = 2 WHERE id = 7")

        let events = try await Self.collect(server, from: start)
        let updates = events.compactMap { event -> MySQLRowsEvent? in
            guard case .rows(let rows) = event.payload, rows.kind == .update,
                  rows.table.table == table else { return nil }
            return rows
        }

        let update = try #require(updates.first, "no update row event")
        #expect(update.rows.count == 1)
        #expect(update.updatedRows.count == 1)
        #expect(update.rows[0][1].string == "before")
        #expect(update.updatedRows[0][1].string == "after")
        #expect(update.rows[0][2].int == 1)
        #expect(update.updatedRows[0][2].int == 2)
    }

    @Test("captures DELETE with the removed row", arguments: TestServers.all)
    func capturesDelete(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        _ = try await connection.query(
            "INSERT INTO \(table) (id, label, score) VALUES (9, 'doomed', 42)"
        )
        let start = try await connection.binlogPosition()
        _ = try await connection.query("DELETE FROM \(table) WHERE id = 9")

        let events = try await Self.collect(server, from: start)
        let deletes = events.compactMap { event -> MySQLRowsEvent? in
            guard case .rows(let rows) = event.payload, rows.kind == .delete,
                  rows.table.table == table else { return nil }
            return rows
        }

        let delete = try #require(deletes.first, "no delete row event")
        #expect(delete.rows[0][0].int == 9)
        #expect(delete.rows[0][1].string == "doomed")
    }

    /// A multi-row statement produces one event carrying every row, not one
    /// event per row.
    @Test("a multi-row INSERT yields one event with every row", arguments: [TestServers.latest])
    func multiRowInsert(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        let start = try await connection.binlogPosition()
        _ = try await connection.query(
            """
            INSERT INTO \(table) (id, label, score) VALUES
            (1,'a',1),(2,'b',2),(3,'c',3),(4,'d',4),(5,'e',5)
            """
        )

        let events = try await Self.collect(server, from: start)
        let writes = events.compactMap { event -> MySQLRowsEvent? in
            guard case .rows(let rows) = event.payload, rows.kind == .write,
                  rows.table.table == table else { return nil }
            return rows
        }
        let total = writes.reduce(0) { $0 + $1.rows.count }
        #expect(total == 5, "expected 5 rows across \(writes.count) event(s)")
        #expect(writes.first?.rows.map { $0[0].int } == [1, 2, 3, 4, 5])
    }

    /// NULLs live in a per-row bitmap sized to the *present* columns, not the
    /// table's column count — the classic place to get row decoding wrong.
    @Test("decodes NULL columns", arguments: [TestServers.latest])
    func decodesNulls(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        let start = try await connection.binlogPosition()
        _ = try await connection.query(
            "INSERT INTO \(table) (id, label, score) VALUES (1, NULL, NULL), (2, 'set', 5)"
        )

        let events = try await Self.collect(server, from: start)
        let write = try #require(events.compactMap { event -> MySQLRowsEvent? in
            guard case .rows(let rows) = event.payload, rows.kind == .write,
                  rows.table.table == table else { return nil }
            return rows
        }.first)

        #expect(write.rows[0][1].isNull)
        #expect(write.rows[0][2].isNull)
        #expect(write.rows[1][1].string == "set")
        #expect(write.rows[1][2].int == 5)
    }

    // MARK: - Metadata and transactions

    @Test("TABLE_MAP names the schema and table", arguments: [TestServers.latest])
    func tableMapMetadata(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        let start = try await connection.binlogPosition()
        _ = try await connection.query("INSERT INTO \(table) (id, label, score) VALUES (1,'x',1)")

        let events = try await Self.collect(server, from: start)
        let map = try #require(events.compactMap { event -> MySQLTableMapEvent? in
            guard case .tableMap(let map) = event.payload, map.table == table else { return nil }
            return map
        }.first)

        #expect(map.schema == TestServers.database)
        #expect(map.columnCount == 3)
        // id is NOT NULL (primary key); the other two are nullable.
        #expect(map.nullableColumns[0] == false)
        #expect(map.nullableColumns[1] == true)
    }

    /// A committed transaction is bracketed by a BEGIN query event and an XID.
    @Test("a transaction is bracketed by BEGIN and XID", arguments: [TestServers.latest])
    func transactionBrackets(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        let start = try await connection.binlogPosition()
        try await connection.withTransaction { db in
            _ = try await db.query("INSERT INTO \(table) (id, label, score) VALUES (1,'t',1)")
            _ = try await db.query("INSERT INTO \(table) (id, label, score) VALUES (2,'t',2)")
        }

        let events = try await Self.collect(server, from: start)
        let hasBegin = events.contains { event in
            guard case .query(let query) = event.payload else { return false }
            return query.query.uppercased().hasPrefix("BEGIN")
        }
        let hasXid = events.contains { if case .xid = $0.payload { return true } else { return false } }

        #expect(hasBegin, "no BEGIN query event")
        #expect(hasXid, "no XID commit event")
    }

    /// DDL is logged as a statement, not as rows, whatever `binlog_format` says.
    @Test("DDL appears as a query event", arguments: [TestServers.latest])
    func ddlIsAQueryEvent(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let start = try await connection.binlogPosition()
        let table = try await Self.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        // Matched on this test's own table name: the suite runs in parallel, so
        // "the first CREATE TABLE" is whichever test happened to get there first.
        let events = try await Self.collect(server, from: start)
        let create = events.compactMap { event -> MySQLQueryEvent? in
            guard case .query(let query) = event.payload,
                  query.query.contains(table) else { return nil }
            return query
        }.first
        let found = try #require(create, "no CREATE TABLE query event for \(table)")
        #expect(found.query.uppercased().contains("CREATE TABLE"))
        #expect(found.schema == TestServers.database)
    }

    // MARK: - Positioning and lifecycle

    /// The point of a position: resuming from one must not replay what came
    /// before it.
    @Test("resuming from a position skips earlier events", arguments: [TestServers.latest])
    func resumeSkipsEarlierEvents(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        let table = try await Self.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        _ = try await connection.query("INSERT INTO \(table) (id, label, score) VALUES (1,'first',1)")
        let middle = try await connection.binlogPosition()
        _ = try await connection.query("INSERT INTO \(table) (id, label, score) VALUES (2,'second',2)")

        let events = try await Self.collect(server, from: middle)
        let labels = events.flatMap { event -> [String] in
            guard case .rows(let rows) = event.payload, rows.table.table == table else { return [] }
            return rows.rows.compactMap { $0[1].string }
        }

        #expect(labels.contains("second"))
        #expect(!labels.contains("first"), "resume replayed an event before the position")
    }

    /// A blocking dump has no end, so the consumer's `break` is the only thing
    /// that stops it — and it must actually stop, not hang.
    @Test("a blocking stream stops when the consumer breaks", arguments: [TestServers.latest])
    func blockingStreamStopsOnBreak(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }
        let start = try await connection.binlogPosition()

        let replica = try await Self.connect(server)
        defer { replica.closeImmediately() }

        let stream = try await replica.startBinlogStream(
            serverID: UInt32(Self.serverIDs.next()),
            from: .file(name: start.filename, position: start.position)
        )

        // Generate something to read so the stream is not merely idle.
        let table = try await Self.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }
        _ = try await connection.query("INSERT INTO \(table) (id, label, score) VALUES (1,'x',1)")

        var seen = 0
        for try await _ in stream {
            seen += 1
            if seen >= 3 { break }
        }
        #expect(seen == 3)
    }

    /// A dump from an impossible position must surface the server's error
    /// rather than hanging or yielding nonsense.
    @Test("an invalid position fails with the server's error", arguments: [TestServers.latest])
    func invalidPositionFails(server: MySQLTestServer) async throws {
        let replica = try await Self.connect(server)
        defer { replica.closeImmediately() }

        await #expect(throws: (any Error).self) {
            let stream = try await replica.startBinlogStream(
                serverID: UInt32(Self.serverIDs.next()),
                from: .file(name: "definitely-not-a-binlog.000001", position: 4),
                flags: .nonBlocking
            )
            for try await _ in stream {}
        }
    }
}

/// Hands out distinct replica server ids without a shared mutable global.
final class ManagedAtomicCounter: @unchecked Sendable {
    private let lock = NIOLock()
    private var value: Int

    init(start: Int) { self.value = start }

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

/// MariaDB's compressed binlog events (`log_bin_compress=ON`).
///
/// This suite exists because these were briefly written off as a deferrable
/// nicety, and they are not. With compression enabled, a client that cannot
/// decode `MARIADB_*_COMPRESSED` events receives **zero row changes and no
/// error** — events keep flowing, nothing fails, and every change is silently
/// lost. For a CDC consumer that is the worst possible failure mode.
///
/// The fixture at :3306 runs with compression on permanently; the other two run
/// without it, so both paths are always covered.
@Suite(
    "Binlog compression",
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct BinlogCompressionTests {

    /// The fixture configured with `log_bin_compress=ON`.
    static let compressedServer = TestServers.mariadb114

    @Test("the fixture really is compressing")
    func fixtureIsCompressed() async throws {
        let connection = try await BinlogTests.connect(Self.compressedServer)
        defer { connection.closeImmediately() }
        let result = try await connection.query("SELECT @@log_bin_compress")
        #expect(result.rows[0][0].int == 1, "this suite proves nothing unless compression is on")
    }

    @Test("decodes compressed write row events")
    func decodesCompressedWrites() async throws {
        let connection = try await BinlogTests.connect(Self.compressedServer)
        defer { connection.closeImmediately() }
        let table = try await BinlogTests.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        let start = try await connection.binlogPosition()
        // Padded well past log_bin_compress_min_len and highly compressible, so
        // the server definitely takes the compressed path.
        let padding = String(repeating: "compressible-", count: 4)
        for i in 1...5 {
            _ = try await connection.query(
                "INSERT INTO \(table) (id, label, score) VALUES (\(i), '\(padding)', \(i * 10))"
            )
        }

        let events = try await BinlogTests.collect(Self.compressedServer, from: start)

        // Nothing may fall through as an undecoded compressed event.
        let undecoded = events.compactMap { event -> UInt8? in
            guard case .other(let raw) = event.payload else { return nil }
            return (165...171).contains(raw.header.rawEventType) ? raw.header.rawEventType : nil
        }
        #expect(undecoded.isEmpty, "compressed events left undecoded: \(undecoded)")

        let rows = events.flatMap { event -> [[MySQLValue]] in
            guard case .rows(let r) = event.payload, r.table.table == table,
                  r.kind == .write else { return [] }
            return r.rows
        }
        #expect(rows.count == 5, "expected 5 rows, decoded \(rows.count)")
        #expect(rows.map { $0[0].int } == [1, 2, 3, 4, 5])
        #expect(rows.allSatisfy { $0[1].string == padding })
        #expect(rows.map { $0[2].int } == [10, 20, 30, 40, 50])
    }

    @Test("decodes compressed update and delete events")
    func decodesCompressedUpdatesAndDeletes() async throws {
        let connection = try await BinlogTests.connect(Self.compressedServer)
        defer { connection.closeImmediately() }
        let table = try await BinlogTests.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        let padding = String(repeating: "compressible-", count: 4)
        _ = try await connection.query(
            "INSERT INTO \(table) (id, label, score) VALUES (1, '\(padding)', 1)"
        )
        let start = try await connection.binlogPosition()
        _ = try await connection.query(
            "UPDATE \(table) SET label = '\(padding)x', score = 2 WHERE id = 1"
        )
        _ = try await connection.query("DELETE FROM \(table) WHERE id = 1")

        let events = try await BinlogTests.collect(Self.compressedServer, from: start)
        let ours = events.compactMap { event -> MySQLRowsEvent? in
            guard case .rows(let r) = event.payload, r.table.table == table else { return nil }
            return r
        }

        let update = try #require(ours.first { $0.kind == .update }, "no compressed update")
        #expect(update.rows[0][2].int == 1, "before image")
        #expect(update.updatedRows[0][2].int == 2, "after image")

        let delete = try #require(ours.first { $0.kind == .delete }, "no compressed delete")
        #expect(delete.rows[0][0].int == 1)
    }

    /// DDL is logged as a `QUERY` event, which has its own compressed variant
    /// with a different layout — the statement text is deflated but everything
    /// before it is not.
    @Test("decodes compressed query events")
    func decodesCompressedQueries() async throws {
        let connection = try await BinlogTests.connect(Self.compressedServer)
        defer { connection.closeImmediately() }

        let start = try await connection.binlogPosition()
        let table = try await BinlogTests.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        let events = try await BinlogTests.collect(Self.compressedServer, from: start)
        let statement = events.compactMap { event -> MySQLQueryEvent? in
            guard case .query(let q) = event.payload, q.query.contains(table) else { return nil }
            return q
        }.first

        let found = try #require(statement, "no query event for \(table)")
        #expect(found.query.uppercased().contains("CREATE TABLE"))
        #expect(found.schema == TestServers.database)
    }

    /// A payload large enough that the compressed-event length field needs more
    /// than one byte.
    ///
    /// The regression test for a real bug: MariaDB writes that field
    /// **big-endian** while nearly everything else in the protocol is
    /// little-endian. Reading it the wrong way round is invisible for any
    /// payload under 256 bytes — the field is a single byte, where endianness
    /// cannot show — and reverses the length on the first larger one. Every
    /// compressed-event test passed until a 70 KB document appeared.
    @Test("a large compressed event decodes")
    func largeCompressedEvent() async throws {
        let connection = try await BinlogTests.connect(Self.compressedServer)
        defer { connection.closeImmediately() }

        let table = "binlog_big_\(UInt32.random(in: 0..<UInt32.max))"
        _ = try await connection.query(
            "CREATE TABLE \(table) (id INT PRIMARY KEY, payload LONGTEXT)"
        )
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        let start = try await connection.binlogPosition()
        // Well past 65 535 so the length field needs three bytes, and highly
        // compressible so the server definitely takes the compressed path.
        let payload = String(repeating: "compressible-", count: 6_000)   // ~78 KB
        _ = try await connection.query(
            "INSERT INTO \(table) VALUES (1, ?)", [.bytes(Array(payload.utf8))]
        )

        let events = try await BinlogTests.collect(Self.compressedServer, from: start)
        let rows = events.flatMap { event -> [[MySQLValue]] in
            guard case .rows(let r) = event.payload, r.table.table == table else { return [] }
            return r.rows
        }
        let row = try #require(rows.first, "no row event for a large compressed payload")
        #expect(row[1].string?.count == payload.count)
        #expect(row[1].string == payload)
    }
}

/// MySQL's compressed transactions (`binlog_transaction_compression=ON`).
///
/// This suite exists because the feature was written off as deferred, and then
/// measured: with it enabled, a stream yielded **zero row changes and no error**.
/// A whole transaction — table maps, row events, the XID — arrives as one
/// zstd-compressed `TRANSACTION_PAYLOAD_EVENT`, so a client that does not
/// expand the container sees a transaction happen and none of its contents.
///
/// The setting is toggled per-connection rather than baked into the fixture, so
/// the default (uncompressed) path stays covered by every other binlog test.
@Suite(
    "Binlog transaction payload",
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct BinlogTransactionPayloadTests {

    @Test("expands a compressed transaction into its events", arguments: TestServers.mysql)
    func expandsCompressedTransaction(server: MySQLTestServer) async throws {
        let connection = try await BinlogTests.connect(server)
        defer { connection.closeImmediately() }
        let table = try await BinlogTests.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        _ = try await connection.query("SET SESSION binlog_transaction_compression = ON")
        defer { Task { try? await connection.query("SET SESSION binlog_transaction_compression = OFF") } }

        let start = try await connection.binlogPosition()
        // One transaction, several rows, padded so the server actually
        // compresses. Sized to fit VARCHAR(64) — the payload is compressible
        // because the same string repeats across ten rows, not because any one
        // value is long.
        let padding = String(repeating: "compress-", count: 4)
        try await connection.withTransaction { db in
            for i in 1...10 {
                _ = try await db.query(
                    "INSERT INTO \(table) (id, label, score) VALUES (\(i), '\(padding)', \(i * 10))"
                )
            }
        }

        let events = try await BinlogTests.collect(server, from: start)

        // Nothing may remain as an unexpanded container.
        let containers = events.filter { $0.eventType == .transactionPayload }
        #expect(containers.isEmpty, "transaction payload was not expanded")

        let rows = events.flatMap { event -> [[MySQLValue]] in
            guard case .rows(let r) = event.payload, r.table.table == table,
                  r.kind == .write else { return [] }
            return r.rows
        }
        #expect(rows.count == 10, "expected 10 rows out of the container, got \(rows.count)")
        #expect(rows.map { $0[0].int } == Array(1...10).map(Int64.init))
        #expect(rows.allSatisfy { $0[1].string == padding })

        // The container also carries the table map and the commit; without those
        // the rows could not have been decoded at all.
        #expect(events.contains { if case .tableMap = $0.payload { return true }; return false })
        #expect(events.contains { if case .xid = $0.payload { return true }; return false })
    }

    /// The uncompressed path must keep working with the same code — the
    /// container is only present when the server chooses to compress.
    @Test("uncompressed transactions are unaffected", arguments: TestServers.mysql)
    func uncompressedStillWorks(server: MySQLTestServer) async throws {
        let connection = try await BinlogTests.connect(server)
        defer { connection.closeImmediately() }
        let table = try await BinlogTests.makeTable(connection)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        _ = try await connection.query("SET SESSION binlog_transaction_compression = OFF")
        let start = try await connection.binlogPosition()
        try await connection.withTransaction { db in
            _ = try await db.query("INSERT INTO \(table) (id, label, score) VALUES (1,'x',1)")
        }

        let events = try await BinlogTests.collect(server, from: start)
        let rows = events.flatMap { event -> [[MySQLValue]] in
            guard case .rows(let r) = event.payload, r.table.table == table else { return [] }
            return r.rows
        }
        #expect(rows.count == 1)
        #expect(rows[0][0].int == 1)
    }
}
/// The runaway guard in `BinlogTests.collect` tripping.
///
/// An error rather than a truncated array, because the truncation was the bug:
/// a helper that quietly returns half the log makes every assertion downstream
/// meaningless while still looking like a real failure of the thing under test.
struct BinlogCollectionOverflow: Error, CustomStringConvertible {
    let limit: Int
    var description: String {
        "binlog collection exceeded \(limit) events without reaching the end of the log"
    }
}

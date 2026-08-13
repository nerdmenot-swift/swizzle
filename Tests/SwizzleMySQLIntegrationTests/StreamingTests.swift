import NIOCore
import Testing
@testable import SwizzleMySQL

/// Streaming with backpressure — the capability this driver exists for.
@Suite(
    "Streaming",
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct StreamingTests {

    static func connect(_ server: MySQLTestServer) async throws -> MySQLConnection {
        let user = server.primaryUser
        return try await MySQLConnection.connect(
            configuration: MySQLConnectionConfiguration(
                address: .hostname(TestServers.host, port: server.port),
                username: user.name,
                password: user.password,
                database: TestServers.database,
                tls: .disable,
                serverPublicKey: .requestFromServer
            ),
            on: TestServers.group.next()
        )
    }

    /// Creates a table containing exactly `n = 0 ..< count`.
    ///
    /// Filtered with `WHERE`, not `LIMIT`: a cross join has no defined order, so
    /// `LIMIT count` yields an arbitrary slice rather than the first `count`
    /// values. Supports up to 10,000 rows.
    static func makeRows(
        _ connection: MySQLConnection, table: String, count: Int
    ) async throws {
        precondition(count <= 10_000)
        try await connection.query("DROP TABLE IF EXISTS \(table)")
        try await connection.query("CREATE TABLE \(table) (n INT, pad VARCHAR(64))")
        let digits = "(SELECT 0 i UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 "
            + "UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9)"
        try await connection.query(
            """
            INSERT INTO \(table) (n, pad)
            SELECT v, REPEAT('x', 32) FROM (
              SELECT a.i + b.i * 10 + c.i * 100 + d.i * 1000 AS v
              FROM \(digits) a, \(digits) b, \(digits) c, \(digits) d
            ) g WHERE v < \(count)
            """
        )
    }

    // MARK: - Basics

    @Test("streams every row in order", arguments: TestServers.all)
    func streamsAllRows(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "stream_basic_\(server.name)"
        try await Self.makeRows(connection, table: table, count: 500)

        let rows = try await connection.stream("SELECT n FROM \(table) ORDER BY n")
        var seen: [Int64] = []
        for try await row in rows {
            seen.append(row[0].int ?? -1)
        }
        #expect(seen.count == 500)
        #expect(seen == Array(0..<500).map(Int64.init))

        try await connection.query("DROP TABLE \(table)")
    }

    /// Column metadata is available before the first row is read.
    @Test("columns are known before any row arrives", arguments: TestServers.all)
    func columnsAvailableUpFront(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let rows = try await connection.stream("SELECT 1 AS alpha, 'x' AS beta")
        #expect(rows.columns.map(\.name) == ["alpha", "beta"])
        _ = try await rows.collect()
    }

    @Test("an empty result set streams zero rows", arguments: TestServers.all)
    func emptyResultSet(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let rows = try await connection.stream("SELECT 1 AS n WHERE 1 = 0")
        let collected = try await rows.collect()
        #expect(collected.isEmpty)

        // The connection is still usable.
        let after = try await connection.query("SELECT 5 AS five")
        #expect(after.rows[0][0].int == 5)
    }

    /// A non-SELECT still resolves rather than leaving the caller waiting on a
    /// promise nobody fulfils.
    @Test("a non-SELECT resolves as an empty stream", arguments: TestServers.all)
    func nonSelectResolves(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "stream_ddl_\(server.name)"
        try await connection.query("DROP TABLE IF EXISTS \(table)")
        try await connection.query("CREATE TABLE \(table) (n INT)")

        let rows = try await connection.stream("INSERT INTO \(table) VALUES (1)")
        let collected = try await rows.collect()
        #expect(collected.isEmpty)

        try await connection.query("DROP TABLE \(table)")
    }

    // MARK: - Prepared / binary streaming

    @Test("prepared statements stream binary rows", arguments: TestServers.all)
    func streamsBinaryRows(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "stream_bin_\(server.name)"
        try await Self.makeRows(connection, table: table, count: 300)

        let rows = try await connection.stream(
            "SELECT n FROM \(table) WHERE n < ? ORDER BY n", [.int(100)]
        )
        var count = 0
        for try await row in rows {
            #expect(row[0].int != nil)
            count += 1
        }
        #expect(count == 100)

        try await connection.query("DROP TABLE \(table)")
    }

    // MARK: - Early termination

    /// Abandoning a stream must leave the connection usable. MySQL cannot abort
    /// a result set mid-flight, so the remainder is drained rather than left
    /// queued for the next command.
    @Test("breaking early leaves the connection usable", arguments: TestServers.all)
    func earlyBreakDrains(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "stream_break_\(server.name)"
        try await Self.makeRows(connection, table: table, count: 2000)

        let rows = try await connection.stream("SELECT n, pad FROM \(table) ORDER BY n")
        var seen = 0
        for try await _ in rows {
            seen += 1
            if seen == 10 { break }
        }
        #expect(seen == 10)

        // The drain runs in the background. Poll for the connection becoming
        // usable rather than sleeping a guessed interval: if the drain never
        // completes this fails clearly, and on a slow machine it just takes a
        // few more polls.
        try await eventually("the abandoned stream to finish draining") {
            guard let after = try? await connection.query("SELECT 99 AS answer") else {
                return false
            }
            // A stale row from the abandoned stream would show up here instead.
            return after.rows.count == 1 && after.rows[0][0].int == 99
        }

        try await connection.query("DROP TABLE \(table)")
    }

    // MARK: - Backpressure

    /// The point of the whole exercise: a slow consumer must not cause unbounded
    /// buffering. With a large result set and a deliberately slow reader, memory
    /// stays flat because rows are only read as they are taken.
    @Test("a slow consumer applies backpressure")
    func slowConsumerIsBounded() async throws {
        let server = TestServers.latest
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "stream_bp_\(server.name)"
        try await Self.makeRows(connection, table: table, count: 5000)

        let rows = try await connection.stream("SELECT n, pad FROM \(table) ORDER BY n")
        var seen = 0
        for try await row in rows {
            seen += 1
            // Yield often enough that the producer would race far ahead if
            // nothing were holding it back.
            if seen % 100 == 0 { await Task.yield() }
            #expect(row[0].int != nil)
        }
        #expect(seen == 5000)

        try await connection.query("DROP TABLE \(table)")
    }

    /// The load-bearing proof that backpressure is real.
    ///
    /// With a large result set and **zero** consumption, the producer must stall
    /// at its window rather than draining the socket. If it ran away, all rows
    /// would buffer, the stream would complete, the connection would go idle,
    /// and the concurrent command below would succeed. That it is still rejected
    /// after a deliberate delay is the evidence — and it is not a race, because
    /// nothing has been consumed to move the window.
    @Test("an unconsumed stream stalls instead of buffering everything")
    func unconsumedStreamStalls() async throws {
        let server = TestServers.latest
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "stream_stall_\(server.name)"
        try await Self.makeRows(connection, table: table, count: 10000)

        let rows = try await connection.stream("SELECT n, pad FROM \(table)")
        var iterator = rows.makeAsyncIterator()

        // The one deliberate sleep in the suite, and it cannot be replaced by
        // polling: this is a *negative* assertion — that the producer does NOT
        // run ahead — and there is no event to wait for when the correct
        // behaviour is inaction. Elapsed time is the mechanism being tested.
        //
        // 750ms is far longer than an unbounded producer needs to read 10k
        // small rows over loopback (the same query streams end to end in a few
        // milliseconds elsewhere in this suite), so a failure here means
        // backpressure is genuinely gone, not that the machine was slow.
        try await Task.sleep(for: .milliseconds(750))

        await #expect(throws: (any Error).self) {
            _ = try await connection.query("SELECT 1")
        }

        // And no rows were lost while it was stalled.
        var drained = 0
        while try await iterator.next() != nil { drained += 1 }
        #expect(drained == 10000)

        try await connection.query("DROP TABLE \(table)")
    }

    /// A result set well beyond a single packet, streamed end to end.
    @Test("large result sets stream completely")
    func largeResultSet() async throws {
        let server = TestServers.latest
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "stream_large_\(server.name)"
        try await Self.makeRows(connection, table: table, count: 10000)

        let rows = try await connection.stream("SELECT n, pad FROM \(table)")
        var count = 0
        var checksum: Int64 = 0
        for try await row in rows {
            count += 1
            checksum &+= row[0].int ?? 0
        }
        #expect(count == 10000)
        #expect(checksum == (0..<10000).reduce(Int64(0)) { $0 &+ Int64($1) })

        try await connection.query("DROP TABLE \(table)")
    }

    // MARK: - Serial connection semantics

    /// A connection with a live stream cannot accept another command — MySQL
    /// has no pipelining, and allowing it would interleave two result sets.
    @Test("a second command during a stream is rejected", arguments: TestServers.all)
    func concurrentCommandRejected(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "stream_serial_\(server.name)"
        // Comfortably more than the initial 256-row window, so backpressure
        // stalls the producer and the stream is provably still open.
        try await Self.makeRows(connection, table: table, count: 5000)

        let rows = try await connection.stream("SELECT n FROM \(table) ORDER BY n")
        var iterator = rows.makeAsyncIterator()

        // Deliberately consume nothing first: taking a row can let a small
        // result set finish, which would legitimately free the connection and
        // make this assertion racy.
        await #expect(throws: (any Error).self) {
            _ = try await connection.query("SELECT 1")
        }

        // Drain so the connection is left clean.
        var drained = 0
        while try await iterator.next() != nil { drained += 1 }
        #expect(drained == 5000)

        try await connection.query("DROP TABLE \(table)")
    }

    // MARK: - Errors

    @Test("a SQL error surfaces from the stream", arguments: TestServers.all)
    func errorSurfaces(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        await #expect(throws: (any Error).self) {
            let rows = try await connection.stream("SELECT * FROM no_such_table_at_all")
            _ = try await rows.collect()
        }

        let after = try await connection.query("SELECT 3 AS three")
        #expect(after.rows[0][0].int == 3)
    }
}

// test-hygiene: no server — the strategy is pure arithmetic
@Suite("Adaptive backpressure strategy")
struct AdaptiveRowBufferTests {

    /// Yielding never resumes production on its own — only consumption does.
    /// That is what makes delivery demand-driven rather than a race between the
    /// socket and the consumer.
    @Test func yieldingAloneNeverAsksForMore() {
        var strategy = MySQLAdaptiveRowBuffer()
        let small = strategy.didYield(bufferDepth: 1)
        let large = strategy.didYield(bufferDepth: 1000)
        #expect(small == false)
        #expect(large == false)
    }

    /// Draining to empty doubles the target so a fast consumer stops paying a
    /// round trip per batch.
    @Test func drainingGrowsTheWindow() {
        var strategy = MySQLAdaptiveRowBuffer(minimum: 1, maximum: 1024, target: 4)
        let grew = strategy.didConsume(bufferDepth: 0)   // target 4 -> 8
        let stillBelow = strategy.didConsume(bufferDepth: 5)   // 5 < 8
        #expect(grew)
        #expect(stillBelow)
    }

    @Test func targetIsClampedToMaximum() {
        var strategy = MySQLAdaptiveRowBuffer(minimum: 1, maximum: 4, target: 4)
        for _ in 0..<10 { _ = strategy.didConsume(bufferDepth: 0) }
        // Never grows past the maximum, so a depth at the ceiling stops production.
        let atCeiling = strategy.didConsume(bufferDepth: 4)
        #expect(atCeiling == false)
    }

    /// Overshooting shrinks the target, but only once a yield has been seen
    /// since the last growth — a single burst cannot collapse the window.
    @Test func aSingleBurstDoesNotCollapseTheWindow() {
        var strategy = MySQLAdaptiveRowBuffer(minimum: 1, maximum: 1024, target: 8)
        _ = strategy.didConsume(bufferDepth: 0)          // grow, canShrink = false
        _ = strategy.didYield(bufferDepth: 100)          // first yield cannot shrink
        _ = strategy.didYield(bufferDepth: 100)          // now it can
        let stillProduces = strategy.didConsume(bufferDepth: 0)
        #expect(stillProduces)
    }
}

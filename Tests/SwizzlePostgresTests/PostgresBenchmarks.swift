import Foundation
import NIOCore
import NIOPosix
import SwizzleCore
import SwizzlePostgresDriver
import Testing

/// Measurements, not assertions.
///
/// Opt-in with `SWIZZLE_BENCH=1` — these take seconds and measure a local
/// server, so they have no business in the ordinary suite. What they exist for is
/// the questions a feature list cannot answer: is the statement cache worth its
/// complexity, does pipelining actually save what it claims, and is streaming
/// paying for its backpressure.
///
/// Numbers from a loopback connection to Postgres 16 on an M-series Mac. Absolute
/// values are meaningless off this machine; **ratios** are the point.
@Suite("Postgres benchmarks", .serialized, .enabled(if: ProcessInfo.processInfo.environment["SWIZZLE_BENCH"] != nil))
struct PostgresBenchmarks {

    static let url = "postgres://swizzle:swizzlepass@127.0.0.1:5432/swizzle_test?sslmode=require"

    static func open() async throws -> PostgresConnection {
        try await PostgresConnection.connect(
            configuration: PostgresConnectionConfiguration(swizzleURL: url),
            on: MultiThreadedEventLoopGroup.singleton.next()
        )
    }

    /// Runs `body` `iterations` times and reports the rate.
    @discardableResult
    static func measure(
        _ name: String, iterations: Int, unit: String = "op",
        _ body: () async throws -> Void
    ) async rethrows -> Double {
        // A warm-up pass, because the first execution of anything pays for the
        // statement cache miss, the type registry, and the connection's first
        // read. Measuring that would measure setup rather than steady state.
        try await body()

        let start = ContinuousClock().now
        for _ in 0..<iterations { try await body() }
        let elapsed = ContinuousClock().now - start

        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        let rate = Double(iterations) / seconds
        let padded = name.padding(toLength: max(name.count, 40), withPad: " ", startingAt: 0)
        print(String(format: "BENCH %@ %10.0f %@/s  (%.3fs)", padded, rate, unit, seconds))
        return rate
    }

    // MARK: - Round trips

    @Test("round-trip rate, simple vs extended protocol")
    func roundTrips() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        // No bindings takes the simple protocol: one message out, one round trip.
        let simple = try await Self.measure("simple protocol SELECT 1", iterations: 2000) {
            _ = try await connection.query("SELECT 1")
        }

        // Bindings take the extended protocol: Parse/Bind/Describe/Execute/Sync.
        let extended = try await Self.measure(
            "extended protocol SELECT \\$1", iterations: 2000
        ) {
            _ = try await connection.query("SELECT $1::int", [.int(1)])
        }

        // The extended path sends four more messages in the same round trip, so
        // it should be close — not half.
        print(String(format: "BENCH   extended/simple ratio %.2f", extended / simple))
    }

    /// **Is the statement cache worth it?** A cache hit skips the `Parse`, which
    /// is server-side planning work rather than bytes.
    @Test("statement cache hit vs miss")
    func statementCache() async throws {
        let cached = try await PostgresConnection.connect(
            configuration: PostgresConnectionConfiguration(swizzleURL: Self.url),
            on: MultiThreadedEventLoopGroup.singleton.next()
        )
        defer { cached.closeImmediately() }

        var uncachedConfiguration = try PostgresConnectionConfiguration(swizzleURL: Self.url)
        uncachedConfiguration.statementCacheCapacity = 0
        let uncached = try await PostgresConnection.connect(
            configuration: uncachedConfiguration,
            on: MultiThreadedEventLoopGroup.singleton.next()
        )
        defer { uncached.closeImmediately() }

        let sql = """
            SELECT u.g, u.g * 2 FROM generate_series(1, 10) u(g)
            WHERE u.g > $1 ORDER BY u.g
            """

        let hit = try await Self.measure("cached statement", iterations: 2000) {
            _ = try await cached.query(sql, [.int(0)])
        }
        let miss = try await Self.measure("uncached statement", iterations: 2000) {
            _ = try await uncached.query(sql, [.int(0)])
        }
        print(String(format: "BENCH   cache speedup %.2fx", hit / miss))
    }

    // MARK: - Rows

    /// Decode throughput, which is where a driver spends its time on a real
    /// result set.
    @Test("row decode throughput")
    func rowDecoding() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        for (label, sql) in [
            ("10k int rows", "SELECT g FROM generate_series(1, 10000) g"),
            (
                "10k wide rows (6 cols)",
                """
                SELECT g, g::text, g::float8, g::numeric, now(), g % 2 = 0
                FROM generate_series(1, 10000) g
                """
            ),
        ] {
            var rows = 0
            _ = try await Self.measure(label, iterations: 20, unit: "query") {
                let result = try await connection.query(sql)
                rows = result.rows.count
            }
            print("BENCH   (\(rows) rows per query)")
        }
    }

    /// Streaming should not cost much against collecting — the backpressure
    /// machinery is per batch, not per row. If this ratio is bad, the read gate is
    /// waking too often.
    @Test("streaming vs collecting")
    func streaming() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }
        let sql = "SELECT g FROM generate_series(1, 50000) g"

        let collected = try await Self.measure("collect 50k rows", iterations: 10, unit: "query") {
            _ = try await connection.query(sql)
        }
        let streamed = try await Self.measure("stream 50k rows", iterations: 10, unit: "query") {
            var count = 0
            for try await _ in try await connection.stream(sql) { count += 1 }
        }
        print(String(format: "BENCH   stream/collect ratio %.2f", streamed / collected))
    }

    // MARK: - The headline claims

    /// **Does pipelining save what it claims?** Serially, N statements cost N
    /// round trips; pipelined they cost one. On loopback the latency is tiny, so
    /// this is the *conservative* measurement — over a real network the gap is far
    /// wider.
    @Test("pipeline vs serial")
    func pipelining() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }
        let statements = (1...50).map { "SELECT \($0)" }

        let serial = try await Self.measure("50 statements serially", iterations: 20, unit: "batch") {
            for sql in statements { _ = try await connection.query(sql) }
        }
        let pipelined = try await Self.measure("50 statements pipelined", iterations: 20, unit: "batch") {
            _ = try await connection.pipeline(statements)
        }
        print(String(format: "BENCH   pipeline speedup %.2fx", pipelined / serial))
    }

    /// **Does COPY earn its place?** This is the claim that bulk load is a
    /// different order of magnitude, not a percentage.
    @Test("COPY vs INSERT vs pipelined INSERT")
    func bulkLoad() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }
        let table = "bench_load"
        _ = try await connection.query("DROP TABLE IF EXISTS \(table)")
        _ = try await connection.query("CREATE TABLE \(table) (id int, name text)")
        defer { Task { _ = try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        let rowCount = 5000

        _ = try await Self.measure("5k rows, INSERT per row", iterations: 3, unit: "load") {
            _ = try await connection.query("TRUNCATE \(table)")
            for index in 1...rowCount {
                _ = try await connection.query(
                    "INSERT INTO \(table) VALUES ($1, $2)",
                    [.int(Int64(index)), .text("n\(index)")]
                )
            }
        }

        _ = try await Self.measure("5k rows, pipelined INSERT", iterations: 3, unit: "load") {
            _ = try await connection.query("TRUNCATE \(table)")
            _ = try await connection.pipeline(
                "INSERT INTO \(table) VALUES ($1, $2)",
                bindings: (1...rowCount).map { [.int(Int64($0)), .text("n\($0)")] }
            )
        }

        _ = try await Self.measure("5k rows, COPY", iterations: 3, unit: "load") {
            _ = try await connection.query("TRUNCATE \(table)")
            _ = try await connection.copyIn("COPY \(table) FROM STDIN") { writer in
                for index in 1...rowCount {
                    try await writer.writeTextRow(["\(index)", "n\(index)"])
                }
            }
        }
    }

    /// The cursor trades a round trip per batch for a server that is idle between
    /// them. Worth knowing what that costs when the consumer is *not* slow, since
    /// that is when it is the wrong choice.
    @Test("cursor batching overhead")
    func cursor() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }
        let sql = "SELECT g FROM generate_series(1, 10000) g"

        let streamed = try await Self.measure("stream 10k", iterations: 20, unit: "query") {
            for try await _ in try await connection.stream(sql) {}
        }
        for batchSize in [100, 1000] {
            let rate = try await Self.measure(
                "cursor 10k, batch \(batchSize)", iterations: 20, unit: "query"
            ) {
                try await connection.withTransaction { db in
                    let cursor = try await db.cursor(sql, batchSize: batchSize)
                    while !(try await cursor.next()).isEmpty {}
                }
            }
            print(String(format: "BENCH   cursor/stream ratio %.2f", rate / streamed))
        }
    }
}

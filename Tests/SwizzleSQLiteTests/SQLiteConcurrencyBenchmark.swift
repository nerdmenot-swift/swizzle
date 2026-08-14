import Foundation
import SwizzleCore
@testable import SwizzleSQLite
@testable import SwizzleSQLiteEngine
import Testing

/// The measurement `SQLiteReaderPool` exists because of.
///
/// Opt-in with `SWIZZLE_BENCH=1`, like the other benchmark suites: this is a
/// measurement, not an assertion, and a wall-clock ratio has no business gating
/// a test run on a loaded machine.
///
/// The question it answers is the one that decided whether to build the pool at
/// all: a `SQLiteConnection` serialises every call through one queue, so how much
/// is that costing when several tasks read at once? Numbers from an M-series Mac
/// — absolute values are meaningless elsewhere, the **ratio** is the point.
@Suite(
    "SQLite concurrency benchmark", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["SWIZZLE_BENCH"] != nil)
)
struct SQLiteConcurrencyBenchmark {

    static let concurrency = 8
    static let queriesPerTask = 6
    static let rows = 20_000

    static func report(_ name: String, _ elapsed: Duration) -> Double {
        let milliseconds = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        let padded = name.padding(toLength: max(name.count, 34), withPad: " ", startingAt: 0)
        print(String(format: "BENCH %@ %8.1f ms", padded, milliseconds))
        return milliseconds
    }

    /// Work heavy enough that the serialisation shows: a scan the query planner
    /// cannot shortcut. A trivial `SELECT 1` would measure the queue hop and
    /// nothing else, and the queue hop is not what the pool is for.
    static func scan(_ connection: SQLiteConnection) async throws {
        for _ in 0..<queriesPerTask {
            _ = try await connection.query(
                "SELECT count(*) FROM t WHERE name LIKE '%7%' AND id % 3 = 0"
            )
        }
    }

    static func seed(_ path: String) async throws {
        let connection = try SQLiteConnection(path: path)
        defer { connection.close() }
        _ = try await connection.query("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
        _ = try await connection.query("BEGIN")
        for id in 1...rows {
            _ = try await connection.query(
                "INSERT INTO t (id, name) VALUES (?1, ?2)", [.int(Int64(id)), .text("name-\(id)")]
            )
        }
        _ = try await connection.query("COMMIT")
    }

    @Test("one shared connection against a reader pool")
    func sharedVersusPooled() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swizzle-bench-\(UInt32.random(in: 0..<UInt32.max))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("bench.db").path
        try await Self.seed(path)

        // One connection, shared. Every query queues behind every other.
        let shared = try SQLiteConnection(path: path)
        try await Self.scan(shared)  // warm the page cache before the clock starts
        var start = ContinuousClock().now
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<Self.concurrency { group.addTask { try await Self.scan(shared) } }
            try await group.waitForAll()
        }
        let sharedMilliseconds = Self.report("one shared connection", ContinuousClock().now - start)
        shared.close()

        // The pool: one read-only connection per task, so the scans overlap.
        let pool = try SQLiteReaderPool(path: path, readers: Self.concurrency)
        defer { pool.close() }
        try await pool.withReader { try await Self.scan($0) }
        start = ContinuousClock().now
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<Self.concurrency {
                group.addTask { try await pool.withReader { try await Self.scan($0) } }
            }
            try await group.waitForAll()
        }
        let pooledMilliseconds = Self.report("reader pool", ContinuousClock().now - start)

        print(String(format: "BENCH speed-up %.1fx", sharedMilliseconds / pooledMilliseconds))
    }

    /// The other half of the decision: pooling is normally about avoiding the
    /// cost of *opening*, and for SQLite that cost is almost nothing. This is the
    /// number that says the pool is for parallelism and not for reuse — and if it
    /// ever stops being tiny, the pool's design should be revisited.
    @Test("what opening a connection costs")
    func openCost() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swizzle-bench-\(UInt32.random(in: 0..<UInt32.max))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("open.db").path
        try await Self.seed(path)

        // Held open for the duration: the `-shm` file has to exist for a
        // read-only connection to attach to the WAL, and it is the writer that
        // creates it.
        let keeper = try SQLiteConnection(path: path)
        defer { keeper.close() }

        let iterations = 1_000
        let start = ContinuousClock().now
        for _ in 0..<iterations {
            let connection = try SQLiteConnection(path: path, readOnly: true)
            connection.close()
        }
        let elapsed = ContinuousClock().now - start
        let microseconds =
            (Double(elapsed.components.seconds) * 1e6
                + Double(elapsed.components.attoseconds) / 1e12) / Double(iterations)
        print(String(format: "BENCH open + close, read-only          %8.1f µs", microseconds))
    }
}


/// Whether a prepared-statement cache would pay for itself here.
///
/// Both the other drivers cache prepared statements and `rusqlite` has
/// `prepare_cached`, so its absence is a real difference from the references. For
/// MySQL and Postgres the case is obvious — a prepare is a network round trip.
/// For SQLite it is a local parse, so the answer has to be measured.
///
/// The measurement has to account for this driver's shape: every call hops to the
/// connection's serial queue, and `query` does prepare, bind, step and finalise
/// **inside one hop**. A cache would save part of what happens within a hop, so
/// the question is how the prepare compares to the hop — not to zero.
@Suite(
    "SQLite prepare cost", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["SWIZZLE_BENCH"] != nil)
)
struct SQLitePrepareCostBenchmark {

    static func micros(_ elapsed: Duration, over iterations: Int) -> Double {
        (Double(elapsed.components.seconds) * 1e6
            + Double(elapsed.components.attoseconds) / 1e12) / Double(iterations)
    }

    @Test("what a prepare costs against what a queue hop costs")
    func prepareAgainstHop() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }
        _ = try await connection.query("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
        for id in 1...1_000 {
            _ = try await connection.query(
                "INSERT INTO t VALUES (?1, ?2)", [.int(Int64(id)), .text("row-\(id)")]
            )
        }

        let iterations = 20_000
        let sql = "SELECT v FROM t WHERE id = ?1"
        _ = try await connection.query(sql, [.int(1)])   // warm

        // One hop: prepare, bind, step, finalise.
        var start = ContinuousClock().now
        for index in 0..<iterations {
            _ = try await connection.query(sql, [.int(Int64(index % 1_000 + 1))])
        }
        let whole = Self.micros(ContinuousClock().now - start, over: iterations)
        print(String(format: "BENCH query: hop + prepare + bind + step  %6.2f µs", whole))

        // Two hops and no prepare: step, then reset. If a prepare were expensive
        // this would be the faster of the two — it does strictly less work per
        // iteration, and pays one extra hop for the privilege.
        let statement = try await connection.prepareStatement(sql, [.int(1)])
        start = ContinuousClock().now
        for _ in 0..<iterations {
            _ = try await connection.stepStatement(statement)
            try await connection.resetStatement(statement)
        }
        let reuse = Self.micros(ContinuousClock().now - start, over: iterations)
        connection.finalizeStatement(statement)
        print(String(format: "BENCH reuse: 2 hops + step + reset        %6.2f µs", reuse))

        // The floor, for scale: the cheapest statement there is, still one hop.
        start = ContinuousClock().now
        for _ in 0..<iterations { _ = try await connection.query("SELECT 1") }
        let trivial = Self.micros(ContinuousClock().now - start, over: iterations)
        print(String(format: "BENCH floor: hop + trivial statement      %6.2f µs", trivial))

        // Stated carefully, because the numbers do not isolate a prepare: the
        // floor *includes* one. What they do show is that the fixed per-call cost
        // — hop plus async machinery plus a minimal statement — is most of a
        // query, and that the extra parsing for a real statement over a trivial
        // one is a small part of the rest. A cache would compete for that part.
        print(
            String(
                format: "BENCH hop ~%.2f µs; fixed cost ~%.2f µs of a %.2f µs query, "
                    + "leaving ~%.2f µs of parsing for a cache to compete for",
                reuse - whole, trivial, whole, whole - trivial
            )
        )
    }
}

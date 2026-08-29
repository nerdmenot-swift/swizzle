import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import SwizzleMySQL

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Throughput and memory measurements for the driver's hot paths.
///
/// **Opt-in**: set `SWIZZLE_BENCH=1`. These take seconds and their numbers are
/// machine-dependent, so they are not part of the ordinary suite — but they are
/// checked in, because "is this fast enough?" should be answerable with a
/// command rather than an opinion.
///
/// Every figure below is throughput against a real server over loopback, so it
/// includes the server's own work. That is the honest number for a driver: what
/// a caller actually gets. Where a pure-decode figure is wanted, the value and
/// binlog benchmarks measure decoding alone.
@Suite(
    "Benchmarks",
    .serialized,
    .enabled(
        if: TestServers.isAvailable && ProcessInfo.processInfo.environment["SWIZZLE_BENCH"] != nil,
        "Set SWIZZLE_BENCH=1 to run benchmarks"
    )
)
struct BenchmarkTests {

    static func connect(_ server: MySQLTestServer) async throws -> MySQLConnection {
        var config = TestServers.configuration(for: server)
        config.maxAllowedPacket = 64 * 1024 * 1024
        return try await MySQLConnection.connect(
            configuration: config, on: TestServers.group.next()
        )
    }

    /// Resident set size, for detecting growth that never comes back.
    static func residentBytes() -> Int {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
        #else
        // /proc/self/statm reports pages; field 2 is resident.
        guard let text = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8),
              let field = text.split(separator: " ").dropFirst().first,
              let pages = Int(field) else { return 0 }
        return pages * 4096
        #endif
    }

    static func report(_ label: String, rows: Int, seconds: Double) {
        let perSecond = Double(rows) / seconds
        let padded = label.padding(toLength: max(label.count, 38), withPad: " ", startingAt: 0)
        print("BENCH \(padded) \(String(format: "%10.0f", perSecond)) rows/s"
              + "  (\(rows) in \(String(format: "%.3f", seconds))s)")
    }

    static func seed(_ connection: MySQLConnection, table: String, rows: Int) async throws {
        _ = try await connection.query("DROP TABLE IF EXISTS \(table)")
        _ = try await connection.query(
            """
            CREATE TABLE \(table) (
                id INT PRIMARY KEY, name VARCHAR(64), score BIGINT,
                ratio DOUBLE, note VARCHAR(128)
            )
            """
        )
        var batch = 0
        while batch < rows {
            let upper = min(batch + 1000, rows)
            let values = (batch..<upper).map {
                "(\($0),'name-\($0)',\($0 * 7),\(Double($0) * 1.5),'note-\($0)')"
            }.joined(separator: ",")
            _ = try await connection.query("INSERT INTO \(table) VALUES \(values)")
            batch = upper
        }
    }

    // MARK: - Result sets

    @Test("buffered text-protocol result set")
    func textProtocolThroughput() async throws {
        let connection = try await Self.connect(TestServers.latest)
        defer { connection.closeImmediately() }
        let table = "bench_text"
        try await Self.seed(connection, table: table, rows: 50_000)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        _ = try await connection.query("SELECT * FROM \(table) LIMIT 100")   // warm

        let start = DispatchTime.now().uptimeNanoseconds
        let result = try await connection.query("SELECT * FROM \(table)")
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9

        #expect(result.rows.count == 50_000)
        Self.report("text protocol, buffered", rows: result.rows.count, seconds: seconds)
    }

    @Test("binary-protocol (prepared) result set")
    func binaryProtocolThroughput() async throws {
        let connection = try await Self.connect(TestServers.latest)
        defer { connection.closeImmediately() }
        let table = "bench_bin"
        try await Self.seed(connection, table: table, rows: 50_000)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        _ = try await connection.query("SELECT * FROM \(table) WHERE id < ?", [.int(100)])

        let start = DispatchTime.now().uptimeNanoseconds
        let result = try await connection.query(
            "SELECT * FROM \(table) WHERE id < ?", [.int(1_000_000)]
        )
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9

        #expect(result.rows.count == 50_000)
        Self.report("binary protocol, buffered", rows: result.rows.count, seconds: seconds)
    }

    @Test("streaming with backpressure")
    func streamingThroughput() async throws {
        let connection = try await Self.connect(TestServers.latest)
        defer { connection.closeImmediately() }
        let table = "bench_stream"
        try await Self.seed(connection, table: table, rows: 50_000)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        let start = DispatchTime.now().uptimeNanoseconds
        var count = 0
        var checksum: Int64 = 0
        for try await row in try await connection.stream("SELECT * FROM \(table)") {
            count += 1
            checksum &+= row[0].int ?? 0
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9

        #expect(count == 50_000)
        #expect(checksum > 0)
        Self.report("streaming", rows: count, seconds: seconds)
    }

    /// Column access by *name*, which is what most callers actually write.
    @Test("row access by column name")
    func nameLookupThroughput() async throws {
        let connection = try await Self.connect(TestServers.latest)
        defer { connection.closeImmediately() }
        let table = "bench_name"
        try await Self.seed(connection, table: table, rows: 20_000)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        let result = try await connection.query("SELECT * FROM \(table)")

        let start = DispatchTime.now().uptimeNanoseconds
        var total: Int64 = 0
        for row in result.rows {
            // The last column, so the linear scan runs to the end.
            total &+= Int64(row["note"]?.string?.count ?? 0)
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9

        #expect(total > 0)
        Self.report("lookup by name (decode excluded)", rows: result.rows.count, seconds: seconds)
    }

    /// The same access on a **wide** table, which is where a linear scan over
    /// column names would actually cost something. Five columns hides it; sixty
    /// does not.
    @Test("row access by column name, wide table")
    func wideNameLookupThroughput() async throws {
        let connection = try await Self.connect(TestServers.latest)
        defer { connection.closeImmediately() }
        let table = "bench_wide"
        let columns = 60

        _ = try await connection.query("DROP TABLE IF EXISTS \(table)")
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }
        let definitions = (0..<columns).map { "c\($0) INT" }.joined(separator: ",")
        _ = try await connection.query("CREATE TABLE \(table) (\(definitions))")
        for batch in 0..<20 {
            let row = "(" + (0..<columns).map(String.init).joined(separator: ",") + ")"
            let values = Array(repeating: row, count: 500).joined(separator: ",")
            _ = try await connection.query("INSERT INTO \(table) VALUES \(values)")
            _ = batch
        }

        let result = try await connection.query("SELECT * FROM \(table)")
        #expect(result.rows.count == 10_000)

        // The last column, so a scan runs the full width.
        let last = "c\(columns - 1)"
        var start = DispatchTime.now().uptimeNanoseconds
        var total: Int64 = 0
        for row in result.rows { total &+= row[last]?.int ?? 0 }
        var seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        Self.report("lookup by name, \(columns) columns", rows: result.rows.count, seconds: seconds)

        // Reading *every* column by name is what mapping a row to a model
        // actually does — and with a per-lookup scan that is quadratic in the
        // width of the table, not linear.
        let names = (0..<columns).map { "c\($0)" }
        start = DispatchTime.now().uptimeNanoseconds
        for row in result.rows {
            for name in names { total &+= row[name]?.int ?? 0 }
        }
        seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9

        #expect(total >= 0)
        Self.report("full row by name, \(columns) columns", rows: result.rows.count, seconds: seconds)
    }

    // MARK: - Pure decode

    @Test("binlog event decoding")
    func binlogDecodeThroughput() async throws {
        let connection = try await Self.connect(TestServers.latest)
        defer { connection.closeImmediately() }
        let table = "bench_binlog"
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        _ = try await connection.query("DROP TABLE IF EXISTS \(table)")
        _ = try await connection.query(
            "CREATE TABLE \(table) (id INT PRIMARY KEY, name VARCHAR(64), score BIGINT)"
        )
        let start = try await connection.binlogPosition()
        for batch in 0..<20 {
            let values = (0..<500).map { "(\(batch * 500 + $0),'n\($0)',\($0))" }
                .joined(separator: ",")
            _ = try await connection.query("INSERT INTO \(table) VALUES \(values)")
        }

        let began = DispatchTime.now().uptimeNanoseconds
        let events = try await BinlogTests.collect(TestServers.latest, from: start)
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9

        let rows = events.reduce(0) { total, event in
            guard case .rows(let r) = event.payload else { return total }
            return total + r.rows.count
        }
        #expect(rows >= 10_000)
        Self.report("binlog row decoding", rows: rows, seconds: seconds)
    }

    // MARK: - Memory

    /// Runs the same query many times and watches resident memory.
    ///
    /// A driver that leaks per query shows up here as steady growth; ordinary
    /// allocator behaviour shows up as a rise that then flattens.
    @Test("repeated queries do not grow memory without bound")
    func queryMemoryStability() async throws {
        let connection = try await Self.connect(TestServers.latest)
        defer { connection.closeImmediately() }
        let table = "bench_mem"
        try await Self.seed(connection, table: table, rows: 2_000)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        // Warm up so one-off allocations are not counted as growth.
        for _ in 0..<20 { _ = try await connection.query("SELECT * FROM \(table)") }
        let baseline = Self.residentBytes()

        for _ in 0..<200 { _ = try await connection.query("SELECT * FROM \(table)") }
        let after = Self.residentBytes()

        let growthMB = Double(after - baseline) / 1_048_576
        print(String(format: "BENCH memory after 200 x 2k-row queries: %+.1f MB", growthMB))
        #expect(growthMB < 64, "resident memory grew \(growthMB) MB across 200 queries")
    }

    /// Streaming a result set far larger than memory must stay flat.
    ///
    /// The backpressure tests prove the *mechanism* — an unconsumed stream
    /// stalls rather than draining the socket. This proves the consequence, which
    /// is the thing a caller actually cares about and which nothing measured
    /// before: that reading a result set bigger than RAM does not accumulate it.
    ///
    /// The payload is sized so that buffering everything would be unmistakable.
    /// 400,000 rows at ~256 bytes is ~100 MB on the wire, and rather more once
    /// decoded into values; the assertion is an order of magnitude below that,
    /// so it fails on a genuine regression without being sensitive to allocator
    /// behaviour.
    @Test("a large stream does not accumulate")
    func streamingMemoryIsBounded() async throws {
        let connection = try await Self.connect(TestServers.latest)
        defer { connection.closeImmediately() }
        let table = "bench_stream_mem"
        let rows = 400_000

        _ = try await connection.query("DROP TABLE IF EXISTS \(table)")
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }
        _ = try await connection.query(
            "CREATE TABLE \(table) (id INT PRIMARY KEY, pad VARCHAR(255))"
        )
        let pad = String(repeating: "x", count: 240)
        var batch = 0
        while batch < rows {
            let upper = min(batch + 2000, rows)
            let values = (batch..<upper).map { "(\($0),'\(pad)')" }.joined(separator: ",")
            _ = try await connection.query("INSERT INTO \(table) VALUES \(values)")
            batch = upper
        }

        let baseline = Self.residentBytes()
        var peak = baseline
        var seen = 0
        var checksum: Int64 = 0

        let start = DispatchTime.now().uptimeNanoseconds
        for try await row in try await connection.stream("SELECT id, pad FROM \(table)") {
            // Consume and discard. Holding a reference to any row would defeat
            // the measurement — and would be the caller's own doing, not the
            // driver's.
            checksum &+= row[0].int ?? 0
            seen += 1
            if seen % 20_000 == 0 { peak = max(peak, Self.residentBytes()) }
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9

        #expect(seen == rows)
        #expect(checksum > 0)
        let growthMB = Double(peak - baseline) / 1_048_576
        Self.report("streaming \(rows) x 240B rows", rows: seen, seconds: seconds)
        print(String(format: "BENCH peak memory over a ~100 MB stream: %+.1f MB", growthMB))
        #expect(
            growthMB < 32,
            "streaming grew \(growthMB) MB — rows are accumulating instead of flowing"
        )
    }

    /// The statement cache is bounded, so preparing many distinct statements
    /// must not grow without limit.
    @Test("the statement cache stays bounded")
    func statementCacheBounded() async throws {
        let connection = try await Self.connect(TestServers.latest)
        defer { connection.closeImmediately() }

        let baseline = Self.residentBytes()
        // Far more distinct statements than the cache holds.
        for i in 0..<2_000 {
            _ = try await connection.query("SELECT ? + \(i) AS n", [.int(1)])
        }
        let growthMB = Double(Self.residentBytes() - baseline) / 1_048_576
        print(String(format: "BENCH memory after 2000 distinct statements: %+.1f MB", growthMB))
        #expect(growthMB < 64, "statement cache grew \(growthMB) MB")
    }
}

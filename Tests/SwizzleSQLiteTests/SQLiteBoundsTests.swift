import Foundation
import SwizzleCore
import Testing
@testable import SwizzleSQLite

/// Numbers the driver does not choose, at the edges of what they can be.
///
/// ## Why this suite looks different from the MySQL and Postgres ones
///
/// Those hunt bytes a *peer* sent: a length off the wire used to index or
/// allocate, where the threat is a hostile or desynchronised server. SQLite has
/// no wire and no peer. Its `sqlite3_*` calls return the library's own numbers,
/// which are internally consistent and already validated — auditing them found
/// nothing, and would have been theatre.
///
/// The untrusted input here is the **caller**. Every number that reaches the C
/// API from outside this module is one an application supplies: a timeout, a
/// reader count, the size of a value being bound. The failure mode is the same
/// as the other two drivers — a narrowing conversion that traps, or an
/// allocation sized by something unbounded — but it arrives through the front
/// door rather than the socket.
///
/// ## What that missed
///
/// `busyTimeout` is a `TimeInterval` with a default of five seconds, and
/// `Int32(busyTimeout * 1000)` traps on anything non-finite or past about 24.8
/// days. `SQLiteConnection(path:, busyTimeout: .infinity)` — which is how a
/// person naturally writes "wait as long as it takes" — killed the process on
/// open. The existing tests passed `0.1` and nothing else, which is why it
/// survived.
@Suite("SQLite bounds")
struct SQLiteBoundsTests {

    // MARK: - The busy timeout

    /// **The crash, pinned.** Every value a caller can plausibly mean, including
    /// the two that are not finite.
    @Test("every busy timeout a caller can express opens without trapping",
          arguments: [
            5.0, 0.0, 0.1, -1.0, -0.0,
            .infinity, -.infinity, .nan,
            .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
            .leastNonzeroMagnitude,
            3_000_000.0,                       // past Int32 milliseconds
            2_147_483.0,                       // just under
            2_147_484.0,                       // just over
          ] as [TimeInterval])
    func busyTimeoutExtremes(timeout: TimeInterval) async throws {
        let connection = try SQLiteConnection(path: ":memory:", busyTimeout: timeout)
        defer { connection.close() }
        // And the connection is usable afterwards, so clamping did not leave it
        // in some half-configured state.
        _ = try await connection.query("CREATE TABLE t (id INTEGER)")
    }

    /// The pool takes the same parameter and hands it straight down, so it had
    /// the identical crash through a second door.
    @Test("the reader pool accepts the same range of busy timeouts")
    func poolBusyTimeoutExtremes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swizzle-bounds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for timeout: TimeInterval in [.infinity, .nan, -1, 3_000_000] {
            let path = directory.appendingPathComponent("\(UUID().uuidString).db").path
            let pool = try SQLiteReaderPool(path: path, readers: 1, busyTimeout: timeout)
            pool.close()
        }
    }

    // MARK: - Values at their limits

    /// The extremes of every numeric kind, through a real round trip.
    ///
    /// `Int64.min` is the one worth naming: any implementation that takes a
    /// magnitude by negating traps on it, which is exactly the bug the MySQL and
    /// Postgres passes each found in their own temporal decoders.
    @Test("integers round-trip at both ends of Int64")
    func integerExtremes() async throws {
        let connection = try SQLiteConnection(path: ":memory:")
        defer { connection.close() }
        _ = try await connection.query("CREATE TABLE t (v INTEGER)")

        for value in [Int64.min, .min + 1, -1, 0, 1, .max - 1, .max] {
            _ = try await connection.query("DELETE FROM t")
            _ = try await connection.query("INSERT INTO t VALUES (?)", [.int(value)])
            let rows = try await connection.query("SELECT v FROM t")
            #expect(rows.first?.values.first == .int(value), "\(value)")
        }
    }

    /// Doubles including the ones that are not numbers. SQLite stores NaN as
    /// NULL — its own documented behaviour, not a driver decision — and the
    /// point here is that nothing traps on the way in or out.
    @Test("every double a caller can bind survives the round trip")
    func doubleExtremes() async throws {
        let connection = try SQLiteConnection(path: ":memory:")
        defer { connection.close() }
        _ = try await connection.query("CREATE TABLE t (v REAL)")

        for value in [0.0, -0.0, 1.5, -1.5, .infinity, -.infinity, .nan,
                      .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
                      .leastNonzeroMagnitude] as [Double] {
            _ = try await connection.query("DELETE FROM t")
            _ = try await connection.query("INSERT INTO t VALUES (?)", [.double(value)])
            let rows = try await connection.query("SELECT v FROM t")
            let read = rows.first?.values.first
            if value.isNaN {
                #expect(read == .null, "SQLite stores NaN as NULL: got \(read as Any)")
            } else {
                #expect(read == .double(value), "\(value)")
            }
        }
    }

    /// Values large enough to exercise the length handling without needing the
    /// 2 GiB that would reach the `Int32` ceiling itself.
    ///
    /// That ceiling **is** guarded now — a blob over `Int32.max` used to trap in
    /// the narrowing conversion where a string of the same size threw a clean
    /// `SQLITE_TOOBIG` — but exercising it would mean allocating two gigabytes
    /// in every CI job, so it is stated here rather than tested. The asymmetry
    /// was the finding; the ceiling itself is SQLite's.
    @Test("large text and blobs round-trip by length")
    func largeValues() async throws {
        let connection = try SQLiteConnection(path: ":memory:")
        defer { connection.close() }
        _ = try await connection.query("CREATE TABLE t (v BLOB)")

        for size in [0, 1, 255, 256, 65_535, 65_536, 1_000_000] {
            _ = try await connection.query("DELETE FROM t")
            let bytes = [UInt8](repeating: 0xAB, count: size)
            _ = try await connection.query("INSERT INTO t VALUES (?)", [.blob(bytes)])
            let rows = try await connection.query("SELECT v FROM t")
            #expect(rows.first?.values.first == .blob(bytes), "\(size) bytes")
        }
    }

    /// Text of the same sizes, since it takes a different bind call and a
    /// different read path.
    @Test("large text round-trips by length")
    func largeText() async throws {
        let connection = try SQLiteConnection(path: ":memory:")
        defer { connection.close() }
        _ = try await connection.query("CREATE TABLE t (v TEXT)")

        for size in [0, 1, 65_535, 65_536, 1_000_000] {
            _ = try await connection.query("DELETE FROM t")
            let text = String(repeating: "é", count: size)   // multi-byte, so bytes != count
            _ = try await connection.query("INSERT INTO t VALUES (?)", [.text(text)])
            let rows = try await connection.query("SELECT v FROM t")
            #expect(rows.first?.values.first == .text(text), "\(size) characters")
        }
    }

    // MARK: - SQL the caller supplies

    /// Statements with nothing executable in them. Each is a plausible thing to
    /// generate from a template, and each has to produce an error or an empty
    /// result rather than stepping a statement that was never compiled.
    @Test("SQL with nothing to run is handled rather than stepped")
    func emptyStatements() async throws {
        let connection = try SQLiteConnection(path: ":memory:")
        defer { connection.close() }

        for sql in ["", " ", "\n\t ", "-- just a comment", "/* block */", ";", ";;"] {
            // Either outcome is defensible; trapping is not.
            _ = try? await connection.query(sql)
            _ = try? await connection.execute(sql)
        }
    }

    /// A parameter count the statement does not agree with, in both directions,
    /// caught before anything is stepped.
    @Test("a parameter count mismatch is refused in both directions")
    func parameterCountMismatch() async throws {
        let connection = try SQLiteConnection(path: ":memory:")
        defer { connection.close() }
        _ = try await connection.query("CREATE TABLE t (a INTEGER, b INTEGER)")

        await #expect(throws: (any Error).self, "too few") {
            _ = try await connection.query("INSERT INTO t VALUES (?, ?)", [.int(1)])
        }
        await #expect(throws: (any Error).self, "too many") {
            _ = try await connection.query("INSERT INTO t VALUES (?)", [.int(1), .int(2)])
        }
        await #expect(throws: (any Error).self, "bindings for a statement with none") {
            _ = try await connection.query("SELECT 1", [.int(1)])
        }
        // And the table is untouched by any of them.
        let rows = try await connection.query("SELECT COUNT(*) FROM t")
        #expect(rows.first?.values.first == .int(0))
    }
}

import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import SwizzleMySQL

/// Guards the *complexity* of result-set decoding, not its correctness.
///
/// This exists because the driver spent its whole life so far being quadratic in
/// result-set size and every correctness test passed throughout. A 50,000-row
/// query that the `mysql` CLI answers in 0.04 s took **10.2 s**; doubling the
/// rows quadrupled the time (3.79×, 3.95×, 4.07×).
///
/// The cause was copy-on-write. The per-command accumulator was a `struct` held
/// inside the `activity` enum and pulled out with `case .buffering(var state)`,
/// mutated, and written back. The enum kept its own reference to the same row
/// array, so every `append` saw a refcount above one and copied the entire array
/// — O(n) per row, O(n²) per query. Making the accumulators classes removed the
/// second reference and the copies with it.
///
/// A throughput threshold would be machine-dependent and flaky. The *shape* is
/// not: doubling the input of a linear algorithm should roughly double the time,
/// and a quadratic one quadruples it. This asserts the shape.
@Suite(
    "Result-set scaling",
    .serialized,
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct ResultSetScalingTests {

    @Test("decoding is linear in row count, not quadratic")
    func decodingIsLinear() async throws {
        let connection = try await BenchmarkTests.connect(TestServers.latest)
        defer { connection.closeImmediately() }

        let table = "scale_\(UInt32.random(in: 0..<UInt32.max))"
        try await BenchmarkTests.seed(connection, table: table, rows: 40_000)
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }

        // Warm: first-call costs would otherwise land on the smallest sample and
        // flatter the ratios.
        _ = try await connection.query("SELECT * FROM \(table) LIMIT 1000")

        func seconds(rows: Int) async throws -> Double {
            // Best of three: this runs alongside other suites, and a single
            // sample picks up whatever else the machine was doing.
            var best = Double.greatestFiniteMagnitude
            for _ in 0..<3 {
                let start = DispatchTime.now().uptimeNanoseconds
                let result = try await connection.query(
                    "SELECT * FROM \(table) WHERE id < \(rows)"
                )
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
                #expect(result.rows.count == rows)
                best = min(best, elapsed)
            }
            return best
        }

        let small = try await seconds(rows: 10_000)
        let large = try await seconds(rows: 40_000)

        // Four times the rows. Linear predicts ~4x, quadratic ~16x. The bound is
        // deliberately loose — it is there to catch a return to quadratic, not
        // to police constant factors.
        let ratio = large / small
        print(String(format: "SCALE 10k=%.4fs 40k=%.4fs ratio=%.2f (linear ≈ 4, quadratic ≈ 16)",
                     small, large, ratio))
        #expect(
            ratio < 8.0,
            "decoding scaled \(ratio)x for 4x the rows — quadratic behaviour is back"
        )
    }
}

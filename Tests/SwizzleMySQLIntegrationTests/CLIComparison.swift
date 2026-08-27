import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import SwizzleMySQL

/// Head-to-head against the `mysql`/`mariadb` command-line client.
///
/// Opt-in via `SWIZZLE_BENCH=1`, and it reads the `clibench` table that
/// `Scripts/cli-comparison.sh` creates.
@Suite("CLI comparison", .serialized,
       .enabled(if: TestServers.isAvailable
                && ProcessInfo.processInfo.environment["SWIZZLE_BENCH"] != nil,
                "Set SWIZZLE_BENCH=1 to run benchmarks"))
struct CLIComparison {
    @Test func measure() async throws {
        let server = TestServers.mariaDB.first { $0.name == "mariadb123" }!
        let user = server.primaryUser
        let config = MySQLConnectionConfiguration(
            address: .hostname(TestServers.host, port: server.port),
            username: user.name, password: user.password,
            database: TestServers.database, tls: .disable,
            serverPublicKey: .requestFromServer
        )

        func best(_ label: String, _ n: Int = 7, _ body: () async throws -> Int) async rethrows {
            var times: [Double] = []
            for _ in 0..<n {
                let t = DispatchTime.now().uptimeNanoseconds
                let count = try await body()
                times.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e9)
                #expect(count == 50_000 || count == 1)
            }
            times.sort()
            let padded = label.padding(toLength: max(label.count, 44), withPad: " ", startingAt: 0)
            print("SWIZZLE \(padded) "
                  + String(format: "min %.4f s   median %.4f s", times[0], times[times.count / 2]))
        }

        // Fixed overhead: connect + auth, the CLI's fork/exec excluded since a
        // library has none.
        try await best("connect + auth") {
            let c = try await MySQLConnection.connect(configuration: config,
                                                      on: TestServers.group.next())
            defer { c.closeImmediately() }
            return 1
        }

        let connection = try await MySQLConnection.connect(configuration: config,
                                                           on: TestServers.group.next())
        defer { connection.closeImmediately() }
        _ = try await connection.query("SELECT * FROM clibench LIMIT 100")   // warm

        try await best("buffered, decoded into typed values") {
            try await connection.query("SELECT * FROM clibench").rows.count
        }
        try await best("streaming (comparable to --quick)") {
            var n = 0
            for try await _ in try await connection.stream("SELECT * FROM clibench") { n += 1 }
            return n
        }
    }
}

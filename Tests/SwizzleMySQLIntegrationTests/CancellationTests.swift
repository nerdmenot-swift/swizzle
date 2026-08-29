import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import SwizzleMySQL

/// What task cancellation does, and does not, do to a command in flight.
///
/// MySQL has no way to abort a running command on the same connection: there is
/// no cancel message, and the reply must be read to completion or the next
/// command reads the previous one's packets. `KILL QUERY` exists but needs a
/// *second* connection, which a driver cannot conjure on its own.
///
/// So the two halves of the API behave differently, and the difference is a
/// consequence of the protocol rather than an oversight:
///
/// - **Streaming** honours cancellation. The consumer stops pulling, the
///   sequence terminates, and the remaining rows are drained in the background.
/// - **A buffered command** does not. It runs to completion because the reply
///   has to be read anyway; cancelling the waiting task early would only hand
///   the caller a connection that is still busy.
///
/// These tests pin that down, because it is exactly the kind of behaviour a
/// caller will otherwise discover in production.
@Suite(
    "Cancellation",
    .serialized,
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct CancellationTests {

    static func connect(_ server: MySQLTestServer) async throws -> MySQLConnection {
        try await TestServers.connect(server)
    }

    /// A cancelled buffered query still completes, and — the part that actually
    /// matters — the connection is left usable rather than desynchronised.
    @Test("cancelling a buffered query leaves the connection usable")
    func cancelledQueryLeavesConnectionUsable() async throws {
        let connection = try await Self.connect(TestServers.latest)
        defer { connection.closeImmediately() }

        let task = Task {
            try await connection.query("SELECT SLEEP(0.5) AS slept")
        }
        // Cancel while it is certainly still running on the server.
        task.cancel()
        let result = try await task.value

        #expect(result.rows.count == 1, "the command ran to completion despite cancellation")

        // The real assertion: whatever cancellation did or did not do, the
        // connection is not left mid-result-set.
        let after = try await connection.query("SELECT 42 AS n")
        #expect(after.rows.first?[0].int == 42)
    }

    /// Streaming is the half that *can* respond, because the consumer controls
    /// the pace. Cancelling the consuming task ends the sequence, and the
    /// connection recovers once the rest is drained.
    @Test("cancelling a stream ends it and the connection recovers")
    func cancelledStreamRecovers() async throws {
        let connection = try await Self.connect(TestServers.latest)
        defer { connection.closeImmediately() }

        let table = "cancel_\(UInt32.random(in: 0..<UInt32.max))"
        _ = try await connection.query("CREATE TABLE \(table) (n INT PRIMARY KEY, pad VARCHAR(255))")
        defer { Task { try? await connection.query("DROP TABLE IF EXISTS \(table)") } }
        let pad = String(repeating: "p", count: 200)
        let values = (0..<20_000).map { "(\($0),'\(pad)')" }.joined(separator: ",")
        _ = try await connection.query("INSERT INTO \(table) VALUES \(values)")

        let started = Barrier(count: 2)
        let task = Task { () -> Int in
            var seen = 0
            for try await _ in try await connection.stream("SELECT n, pad FROM \(table)") {
                seen += 1
                if seen == 1 { await started.arriveAndWait() }
            }
            return seen
        }

        // Cancel only once rows are genuinely flowing, so this tests
        // cancellation rather than a race with the query starting.
        await started.arriveAndWait()
        task.cancel()
        let seen = try? await task.value
        #expect((seen ?? 0) < 20_000, "cancellation should have stopped it early")

        // The abandoned rows drain in the background; the connection comes back.
        try await eventually(within: .seconds(10), "the connection to become usable again") {
            (try? await connection.query("SELECT 1")) != nil
        }
    }
}

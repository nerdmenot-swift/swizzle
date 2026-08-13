import NIOCore
import NIOPosix
import SwizzleCore
import SwizzlePostgresDriver
import Testing

/// The pool's keep-alive, called directly.
///
/// The pool invokes it on a timer measured in tens of seconds, so no test's
/// lifetime reaches it — which is why a sweep found nothing calling it. That is
/// not a reason to leave it unproven: a keep-alive that throws marks a healthy
/// connection dead, and one that hangs takes the pool's maintenance loop with it.
@Suite(
    "Postgres keep-alive", .serialized,
    .enabled(if: PostgresTestServer.isAvailable, PostgresTestServer.skipReason)
)
struct PostgresKeepAliveTests {

    static let url = "postgres://swizzle:swizzlepass@127.0.0.1:5432/swizzle_test?sslmode=require"

    static func open() async throws -> PostgresConnection {
        try await PostgresConnection.connect(
            configuration: PostgresConnectionConfiguration(swizzleURL: url),
            on: MultiThreadedEventLoopGroup.singleton.next()
        )
    }

    @Test("the keep-alive succeeds on a live connection and leaves it usable")
    func succeedsOnLiveConnection() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        let behavior = PostgresKeepAliveBehavior()
        try await behavior.runKeepAlive(for: connection)

        // Twice, because a keep-alive that leaves the session mid-anything would
        // work once and then wedge.
        try await behavior.runKeepAlive(for: connection)

        let rows = try await connection.query("SELECT 1").rows
        #expect(rows[0][0] == .int(1))
    }

    /// It must *throw* on a dead connection rather than hanging — that is how the
    /// pool learns to discard it. Hanging here would stall the maintenance loop
    /// for every other connection too.
    @Test("the keep-alive fails on a dead connection rather than hanging")
    func failsOnDeadConnection() async throws {
        let connection = try await Self.open()
        try await connection.shutdown()

        let behavior = PostgresKeepAliveBehavior()
        await #expect(throws: (any Error).self) {
            try await behavior.runKeepAlive(for: connection)
        }
    }

    /// Nil frequency disables it. Worth pinning because "never fires" and
    /// "fires and does nothing" are the same from outside.
    @Test("the frequency is configurable and can be switched off")
    func frequency() {
        #expect(PostgresKeepAliveBehavior().keepAliveFrequency == .seconds(30))
        #expect(PostgresKeepAliveBehavior(frequency: nil).keepAliveFrequency == nil)
        #expect(
            PostgresKeepAliveBehavior(frequency: .seconds(5)).keepAliveFrequency == .seconds(5)
        )
    }
}

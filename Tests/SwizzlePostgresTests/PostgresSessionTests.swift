import NIOCore
import NIOPosix
import SwizzleCore
import SwizzlePostgresDriver
import Testing

/// The connection-level features, against a real server.
///
/// Every one of these was marked done on the strength of a handler-level unit
/// test. That is exactly the standard that let `Describe` ship broken earlier
/// today — the machine was fed a `RowDescription` it proved it could decode,
/// while the server was never asked to send one.
@Suite(
    "Postgres session features", .serialized,
    .enabled(if: PostgresTestServer.isAvailable, PostgresTestServer.skipReason)
)
struct PostgresSessionTests {

    static let url = "postgres://swizzle:swizzlepass@127.0.0.1:5432/swizzle_test?sslmode=require"

    static func open() async throws -> PostgresConnection {
        try await PostgresConnection.connect(
            configuration: PostgresConnectionConfiguration(swizzleURL: url),
            on: MultiThreadedEventLoopGroup.singleton.next()
        )
    }

    // MARK: - Goodbye

    /// `Terminate` lets the server log a clean disconnect rather than a lost
    /// connection, and closing must be prompt — NIOSSL's default would wait five
    /// seconds for a `close_notify` Postgres does not send.
    @Test("shutdown says goodbye and closes promptly")
    func shutdown() async throws {
        let connection = try await Self.open()
        let start = ContinuousClock().now
        try await connection.shutdown()
        let elapsed = ContinuousClock().now - start

        #expect(!connection.isActive)
        // Three seconds, and the number is a choice rather than a round figure:
        // a correct close takes about **0.25 s** (the `tlsShutdownTimeout`) and
        // the bug this guards against took **5.0 s** — NIOSSL waiting for a
        // `close_notify` that never comes. Anything between the two
        // discriminates, so the bound sits well clear of the expected value
        // while still failing if the five-second wait returns.
        //
        // Two seconds was the original, and a sibling bound calibrated the same
        // way failed at 2.95 s the first time it ran in a container. The bound
        // was measuring the machine.
        #expect(elapsed < .seconds(3), "shutdown took \(elapsed)")
    }

    @Test("shutting down twice is safe")
    func shutdownTwice() async throws {
        let connection = try await Self.open()
        try await connection.shutdown()
        try await connection.shutdown()
    }

    /// **This used to crash the process, not throw.**
    ///
    /// Each entry point made its promise and *then* sent; the send throws when
    /// the connection is already closed, and a promise created but never
    /// fulfilled trips NIO's `fatalError` — "leaking promise created at …". It
    /// surfaced roughly once in six full test runs, which is exactly often enough
    /// to be dismissed as a flake.
    @Test("using a closed connection throws rather than crashing")
    func useAfterClose() async throws {
        let connection = try await Self.open()
        try await connection.shutdown()

        await #expect(throws: PostgresConnectionError.self) {
            _ = try await connection.query("SELECT 1")
        }
        // The bound path builds its request differently, so it gets its own check.
        await #expect(throws: PostgresConnectionError.self) {
            _ = try await connection.query("SELECT $1::int", [.int(1)])
        }
        await #expect(throws: PostgresConnectionError.self) {
            _ = try await connection.describe("SELECT 1")
        }
        await #expect(throws: PostgresConnectionError.self) {
            _ = try await connection.stream("SELECT 1")
        }
    }

    // MARK: - Keep-alive

    /// An empty query, not `SELECT 1`: the server answers `EmptyQueryResponse`
    /// without planning anything. Worth an integration test because a statement
    /// that returns *no* result set is precisely the shape that hung the
    /// streaming path earlier today.
    @Test("ping round-trips on an empty query")
    func ping() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        try await connection.ping()
        // And the connection is still usable afterwards — an empty query must
        // not leave the session mid-anything.
        let rows = try await connection.query("SELECT 1").rows
        #expect(rows.first?.first == .int(1))
    }

    // MARK: - Session reset

    /// `DISCARD ALL` is what stops one borrower's session state reaching the
    /// next. The case that matters most is an **open transaction**: a connection
    /// returned mid-transaction would enrol the next borrower in one it never
    /// opened, holding locks it cannot see.
    @Test("resetting rolls back an open transaction")
    func resetRollsBack() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        _ = try await connection.query("CREATE TEMP TABLE reset_probe (id int)")
        _ = try await connection.query("BEGIN")
        _ = try await connection.query("INSERT INTO reset_probe VALUES (1)")

        try await connection.resetSession()

        // Out of the transaction…
        let status = try await connection.query("SELECT 1").rows
        #expect(status.first?.first == .int(1))
        // …and the temp table went with `DISCARD ALL`, which is the point.
        let exists = try await connection.query(
            "SELECT to_regclass('pg_temp.reset_probe') IS NOT NULL"
        ).rows
        #expect(exists.first?.first == .bool(false))
    }

    /// `DISCARD ALL` deallocates every prepared statement. If the driver's cache
    /// were not cleared with it, the next query would bind a name the server has
    /// just thrown away — failing with "prepared statement does not exist" on a
    /// connection that looks perfectly healthy.
    @Test("a cached statement still works after a reset")
    func resetClearsTheStatementCache() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        // Run it twice so it is definitely cached under a server-side name.
        for _ in 0..<2 {
            _ = try await connection.query("SELECT $1::bigint", [.int(7)])
        }

        try await connection.resetSession()

        // The server has forgotten the statement. If the driver had not, this is
        // where it would fail.
        let rows = try await connection.query("SELECT $1::bigint", [.int(7)]).rows
        #expect(rows.first?.first == .int(7))
    }

    /// A reset connection must still answer `SET` — the reset clears settings, it
    /// does not disable them.
    @Test("settings survive being set after a reset")
    func settingsAfterReset() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        _ = try await connection.query("SET application_name = 'before'")
        try await connection.resetSession()
        let cleared = try await connection.query("SHOW application_name").rows
        #expect(cleared.first?.first != .text("before"))

        _ = try await connection.query("SET application_name = 'after'")
        let set = try await connection.query("SHOW application_name").rows
        #expect(set.first?.first == .text("after"))
    }

    // MARK: - LISTEN / NOTIFY

    /// **The trap this feature has.** With `autoRead` off an idle connection reads
    /// nothing, because nothing asks — so a `LISTEN` would register successfully
    /// and then deliver nothing at all. The handler test proved the read gate
    /// opens; this proves a real server's notification actually arrives.
    @Test("a notification from another connection arrives")
    func listenReceives() async throws {
        let listener = try await Self.open()
        defer { listener.closeImmediately() }
        let sender = try await Self.open()
        defer { sender.closeImmediately() }

        let stream = try await listener.listen(to: "swizzle_test_channel")
        try await sender.notify(channel: "swizzle_test_channel", payload: "hello")

        let received = try await withThrowingTaskGroup(of: PostgresNotification?.self) { group in
            group.addTask {
                for await notification in stream { return notification }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }

        #expect(received?.channel == "swizzle_test_channel")
        #expect(received?.payload == "hello")
    }

    /// A channel name is an identifier and cannot be a bound parameter, so it is
    /// quoted. Postgres folds unquoted identifiers to lower case and preserves
    /// quoted ones — which means a mixed-case channel only works *because* it is
    /// quoted on both sides.
    @Test("a mixed-case channel name round-trips")
    func mixedCaseChannel() async throws {
        let listener = try await Self.open()
        defer { listener.closeImmediately() }
        let sender = try await Self.open()
        defer { sender.closeImmediately() }

        let stream = try await listener.listen(to: "SwizzleMixedCase")
        try await sender.notify(channel: "SwizzleMixedCase", payload: "x")

        let received = try await withThrowingTaskGroup(of: PostgresNotification?.self) { group in
            group.addTask {
                for await notification in stream { return notification }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
        #expect(received?.payload == "x")
    }

    @Test("unlisten stops delivery")
    func unlisten() async throws {
        let listener = try await Self.open()
        defer { listener.closeImmediately() }

        _ = try await listener.listen(to: "swizzle_unlisten")
        try await listener.unlisten(from: "swizzle_unlisten")

        // The registration is gone as far as the server is concerned.
        let rows = try await listener.query(
            "SELECT count(*) FROM pg_listening_channels() AS c WHERE c = $1",
            [.text("swizzle_unlisten")]
        ).rows
        #expect(rows.first?.first == .int(0))
    }

    // MARK: - Cancellation

    /// Cancellation needs a **second** connection: the one running the query is
    /// busy producing results and will not read anything until it is done, which
    /// is precisely when cancelling matters. The server raises `57014`, which the
    /// taxonomy maps to `.timeout`.
    @Test("a running query can be cancelled from another connection")
    func cancelRunningQuery() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }
        #expect(connection.backendKey != nil)

        let configuration = try PostgresConnectionConfiguration(swizzleURL: Self.url)

        async let running: Void = {
            do {
                _ = try await connection.query("SELECT pg_sleep(30)")
                Issue.record("the sleep should not have completed")
            } catch let error as PostgresConnectionError {
                #expect(error.sqlState == "57014")
                #expect(error.sqlKind == .timeout)
                // Cancelled, therefore rolled back — nothing applied.
                #expect(!error.mayHaveApplied)
            }
        }()

        // Give the statement time to actually be running; cancelling a query the
        // server has not started yet is a no-op it will not report.
        try await Task.sleep(for: .milliseconds(300))
        try await connection.cancelRunningQuery(configuration: configuration)

        try await running
    }

    /// And the connection survives it. A cancel is not a disconnect — the server
    /// resynchronises at `ReadyForQuery`, which is why a server error does not
    /// cost the pool a connection.
    @Test("a cancelled connection is still usable")
    func connectionSurvivesCancellation() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }
        let configuration = try PostgresConnectionConfiguration(swizzleURL: Self.url)

        async let running: Void = { _ = try? await connection.query("SELECT pg_sleep(30)") }()
        try await Task.sleep(for: .milliseconds(300))
        try await connection.cancelRunningQuery(configuration: configuration)
        await running

        let rows = try await connection.query("SELECT 42").rows
        #expect(rows.first?.first == .int(42))
    }
}

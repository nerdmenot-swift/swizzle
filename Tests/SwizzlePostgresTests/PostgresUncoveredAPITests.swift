import NIOCore
import NIOPosix
import SwizzleCore
import SwizzlePostgresDriver
import Testing

/// The public API a sweep found nothing calling.
///
/// Not a category of bug so much as a category of *unknown*: `COM_QUIT` was
/// ticked for a year on the strength of an enum case nothing sent, and the only
/// way to tell that apart from working code is to call it.
@Suite(
    "Postgres uncovered API", .serialized,
    .enabled(if: PostgresTestServer.isAvailable, PostgresTestServer.skipReason)
)
struct PostgresUncoveredAPITests {

    static let url = "postgres://swizzle:swizzlepass@127.0.0.1:5432/swizzle_test?sslmode=require"

    static func open() async throws -> PostgresConnection {
        try await PostgresConnection.connect(
            configuration: PostgresConnectionConfiguration(swizzleURL: url),
            on: MultiThreadedEventLoopGroup.singleton.next()
        )
    }

    // MARK: - closePortal

    /// A portal is protocol-level, and the driver only ever uses the unnamed one
    /// — which is why nothing called this. `DECLARE … CURSOR` is how a *named*
    /// portal comes into existence from SQL, and `pg_cursors` is where it shows
    /// up, so the close is observable rather than merely not-an-error.
    ///
    /// It matters because a suspended portal holds server resources until its
    /// transaction ends: a long transaction that opens cursors and abandons them
    /// leaks for as long as it runs.
    @Test("closePortal closes a named portal")
    func closePortal() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        try await connection.withTransaction { db in
            _ = try await db.query(
                "DECLARE swizzle_probe CURSOR FOR SELECT g FROM generate_series(1, 100) g"
            )
            let before = try await db.query(
                "SELECT count(*) FROM pg_cursors WHERE name = 'swizzle_probe'"
            ).rows
            #expect(before[0][0] == .int(1))

            try await db.closePortal(named: "swizzle_probe")

            let after = try await db.query(
                "SELECT count(*) FROM pg_cursors WHERE name = 'swizzle_probe'"
            ).rows
            #expect(after[0][0] == .int(0))
        }
    }

    /// Closing a portal that is not there is not an error in the protocol — the
    /// goal was for it to be gone, and it is.
    @Test("closing an absent portal is not fatal")
    func closeAbsentPortal() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        try await connection.closePortal(named: "never_declared")
        let rows = try await connection.query("SELECT 1").rows
        #expect(rows[0][0] == .int(1))
    }

    // MARK: - The explicit savepoint trio

    /// `withSavepoint` was tested; these three were not.
    ///
    /// They exist for the case the scoped form cannot express: a savepoint whose
    /// lifetime is decided by logic rather than by a Swift scope — retry loops
    /// and interpreters, where the decision to roll back is made somewhere other
    /// than where the savepoint was taken.
    @Test("an explicit savepoint rolls back only its own work")
    func explicitSavepoint() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        try await connection.withTransaction { db in
            _ = try await db.query("CREATE TEMP TABLE sp (id int)")
            _ = try await db.query("INSERT INTO sp VALUES (1)")

            try await db.savepoint("mark")
            _ = try await db.query("INSERT INTO sp VALUES (2)")
            try await db.rollbackToSavepoint("mark")

            _ = try await db.query("INSERT INTO sp VALUES (3)")
            try await db.releaseSavepoint("mark")

            let rows = try await db.query("SELECT id FROM sp ORDER BY id").rows
            #expect(rows.map { $0[0] } == [.int(1), .int(3)])
        }
    }

    /// Rolling back to a savepoint is the only way out of the aborted state
    /// without discarding the whole transaction — `25P02` otherwise rejects
    /// everything until a rollback.
    @Test("an explicit rollback clears the aborted state")
    func explicitSavepointClearsAbort() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        try await connection.withTransaction { db in
            _ = try await db.query("CREATE TEMP TABLE sp2 (id int)")
            try await db.savepoint("before_failure")

            _ = try? await db.query("SELECT nonexistent_column")
            var status = try await db.transactionStatus
            #expect(status == .failed)

            try await db.rollbackToSavepoint("before_failure")
            status = try await db.transactionStatus
            #expect(status == .inTransaction)

            // Usable again, which is the whole point.
            _ = try await db.query("INSERT INTO sp2 VALUES (1)")
            let rows = try await db.query("SELECT count(*) FROM sp2").rows
            #expect(rows[0][0] == .int(1))
        }
    }

    /// The name is an identifier spliced into SQL — Postgres takes no placeholder
    /// there — so the explicit forms must quote it exactly as the scoped one does.
    @Test("an awkward savepoint name survives the explicit forms")
    func awkwardSavepointName() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        let name = #"we"ird name"#
        try await connection.withTransaction { db in
            try await db.savepoint(name)
            try await db.rollbackToSavepoint(name)
            try await db.releaseSavepoint(name)
        }
    }

    // MARK: - Pool metrics

    /// The delegate methods are called by the pool rather than by us, so the
    /// sweep reported them as untested. Asserting the *statistics move* covers
    /// them where it matters: a counter that never advances is indistinguishable
    /// from a delegate nobody installed.
    @Test("pool statistics move as connections are opened and used")
    func poolStatistics() async throws {
        let configuration = PostgresClient.Configuration(
            connection: try PostgresConnectionConfiguration(swizzleURL: Self.url),
            maximumConnections: 2
        )
        let client = PostgresClient(configuration: configuration)
        let running = Task { await client.run() }
        defer { running.cancel() }

        #expect(client.statistics.openConnections == 0)
        #expect(client.statistics.succeededConnects == 0)

        _ = try await client.query("SELECT 1")

        #expect(client.statistics.succeededConnects >= 1)
        #expect(client.statistics.openConnections >= 1)
        // Nothing failed, so the failure counter must still be zero — otherwise
        // "it moved" would be satisfied by any counter moving at all.
        #expect(client.statistics.failedConnects == 0)
    }

    /// A pool that cannot connect must report failures rather than staying silent
    /// — a queue depth rising against zero open connections is the signature of
    /// an outage, and it is only visible if the failures are counted.
    @Test("failed connections are counted")
    func failedConnectionsCounted() async throws {
        var connection = try PostgresConnectionConfiguration(swizzleURL: Self.url)
        connection.password = "definitely-not-the-password"
        connection.username = "swizzle_scram"
        connection.tlsMode = .disable

        let client = PostgresClient(
            configuration: .init(
                connection: connection,
                maximumConnections: 1,
                connectionAcquisitionTimeout: .seconds(3)
            )
        )
        let running = Task { await client.run() }
        defer { running.cancel() }

        _ = try? await client.query("SELECT 1")
        #expect(client.statistics.failedConnects >= 1)
        #expect(client.statistics.succeededConnects == 0)
    }
}

import NIOCore
import ServiceLifecycle
import Testing
@testable import SwizzleMySQL

/// Pooling and session hygiene.
@Suite(
    "Pool",
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct PoolTests {

    static func configuration(
        _ server: MySQLTestServer,
        maximumConnections: Int = 4,
        resetOnRelease: Bool = true
    ) -> MySQLClient.Configuration {
        let user = server.primaryUser
        return MySQLClient.Configuration(
            connection: MySQLConnectionConfiguration(
                address: .hostname(TestServers.host, port: server.port),
                username: user.name,
                password: user.password,
                database: TestServers.database,
                tls: .disable,
                serverPublicKey: .requestFromServer
            ),
            maximumConnections: maximumConnections,
            resetOnRelease: resetOnRelease
        )
    }

    /// Runs `body` with the pool's `run()` loop active, then shuts it down.
    static func withClient<Result: Sendable>(
        _ configuration: MySQLClient.Configuration,
        _ body: @Sendable @escaping (MySQLClient) async throws -> Result
    ) async throws -> Result {
        let client = MySQLClient(configuration: configuration)
        return try await withThrowingTaskGroup(of: Result?.self) { group in
            group.addTask {
                await client.run()
                return nil
            }
            group.addTask {
                try await body(client)
            }
            var result: Result?
            while let next = try await group.next() {
                if let next { result = next; break }
            }
            group.cancelAll()
            return result!
        }
    }

    // MARK: - Basics

    @Test("pooled queries work", arguments: TestServers.all)
    func pooledQuery(server: MySQLTestServer) async throws {
        let value = try await Self.withClient(Self.configuration(server)) { client in
            let result = try await client.query("SELECT 42 AS answer")
            return result.rows[0][0].int ?? -1
        }
        #expect(value == 42)
    }

    @Test("connections are reused across calls", arguments: TestServers.all)
    func connectionsAreReused(server: MySQLTestServer) async throws {
        let ids = try await Self.withClient(
            Self.configuration(server, maximumConnections: 1)
        ) { client in
            var seen: [Int64] = []
            for _ in 0..<5 {
                let result = try await client.query("SELECT CONNECTION_ID() AS id")
                seen.append(result.rows[0][0].int ?? -1)
            }
            return seen
        }
        // With one connection allowed, every query must land on the same session.
        #expect(Set(ids).count == 1, "expected one connection, saw \(Set(ids))")
    }

    @Test("concurrent work uses several connections", arguments: TestServers.all)
    func concurrencyUsesMultipleConnections(server: MySQLTestServer) async throws {
        let ids = try await Self.withClient(
            Self.configuration(server, maximumConnections: 4)
        ) { client in
            // Every task holds its connection until all four have one. A sleep
            // would only *probably* overlap them; this guarantees it, so the
            // test cannot flake under load.
            let barrier = Barrier(count: 4)
            return try await withThrowingTaskGroup(of: Int64.self) { group in
                for _ in 0..<4 {
                    group.addTask {
                        try await client.withConnection { connection in
                            let result = try await connection.query(
                                "SELECT CONNECTION_ID() AS id"
                            )
                            await barrier.arriveAndWait()
                            return result.rows[0][0].int ?? -1
                        }
                    }
                }
                var seen: [Int64] = []
                for try await id in group { seen.append(id) }
                return seen
            }
        }
        #expect(ids.count == 4)
        // Four connections held simultaneously must be four distinct sessions.
        #expect(Set(ids).count == 4, "expected four distinct connections, saw \(Set(ids))")
    }

    @Test("the connection ceiling is respected", arguments: TestServers.all)
    func maximumConnectionsRespected(server: MySQLTestServer) async throws {
        let ids = try await Self.withClient(
            Self.configuration(server, maximumConnections: 2)
        ) { client in
            try await withThrowingTaskGroup(of: Int64.self) { group in
                // Only two connections are permitted, so eight tasks cannot all
                // hold one at once — a barrier across all eight would deadlock.
                // Pairs are enough to keep both slots occupied concurrently.
                let barrier = Barrier(count: 2)
                for _ in 0..<8 {
                    group.addTask {
                        try await client.withConnection { connection in
                            let result = try await connection.query(
                                "SELECT CONNECTION_ID() AS id"
                            )
                            await barrier.arriveAndWait()
                            return result.rows[0][0].int ?? -1
                        }
                    }
                }
                var seen: [Int64] = []
                for try await id in group { seen.append(id) }
                return seen
            }
        }
        #expect(ids.count == 8)
        #expect(Set(ids).count <= 2, "pool exceeded its ceiling: \(Set(ids))")
    }

    // MARK: - Session hygiene

    /// The reason `COM_RESET_CONNECTION` runs on release.
    ///
    /// Without it a user variable set by one borrower is still visible to the
    /// next — cross-talk that surfaces as impossible behaviour in unrelated
    /// code rather than as an error.
    @Test("session state does not leak between borrowers", arguments: TestServers.all)
    func sessionStateIsReset(server: MySQLTestServer) async throws {
        let leaked = try await Self.withClient(
            Self.configuration(server, maximumConnections: 1, resetOnRelease: true)
        ) { client in
            try await client.query("SET @swizzle_probe = 'leaked'")
            let result = try await client.query("SELECT @swizzle_probe AS probe")
            return result.rows[0][0].isNull == false
        }
        #expect(leaked == false, "user variable survived the reset")
    }

    /// The same scenario with resetting disabled, to show the reset is what does
    /// the work rather than the pool happening to open a fresh connection.
    @Test("without reset, state does leak", arguments: TestServers.all)
    func withoutResetStateLeaks(server: MySQLTestServer) async throws {
        let leaked = try await Self.withClient(
            Self.configuration(server, maximumConnections: 1, resetOnRelease: false)
        ) { client in
            try await client.query("SET @swizzle_probe = 'leaked'")
            let result = try await client.query("SELECT @swizzle_probe AS probe")
            return result.rows[0][0].string == "leaked"
        }
        #expect(leaked, "expected the variable to survive when reset is disabled")
    }

    /// Temporary tables are session-scoped and are exactly what leaks without a
    /// reset.
    @Test("temporary tables do not leak between borrowers", arguments: TestServers.all)
    func temporaryTablesAreReset(server: MySQLTestServer) async throws {
        let survived = try await Self.withClient(
            Self.configuration(server, maximumConnections: 1, resetOnRelease: true)
        ) { client in
            try await client.query("CREATE TEMPORARY TABLE swizzle_tmp (n INT)")
            do {
                _ = try await client.query("SELECT * FROM swizzle_tmp")
                return true
            } catch {
                return false
            }
        }
        #expect(survived == false, "temporary table survived the reset")
    }

    // MARK: - Failure handling

    /// An application error must not poison the connection — it is still clean,
    /// so it goes back to the pool.
    @Test("an application error still returns the connection", arguments: TestServers.all)
    func applicationErrorReturnsConnection(server: MySQLTestServer) async throws {
        struct Marker: Error {}

        let value = try await Self.withClient(
            Self.configuration(server, maximumConnections: 1)
        ) { client in
            do {
                _ = try await client.withConnection { _ -> Int in throw Marker() }
            } catch is Marker {
                // expected
            }
            // The pool must still be able to serve work.
            let result = try await client.query("SELECT 7 AS seven")
            return result.rows[0][0].int ?? -1
        }
        #expect(value == 7)
    }

    @Test("a SQL error leaves the pool usable", arguments: TestServers.all)
    func sqlErrorLeavesPoolUsable(server: MySQLTestServer) async throws {
        let value = try await Self.withClient(
            Self.configuration(server, maximumConnections: 2)
        ) { client in
            _ = try? await client.query("SELECT * FROM no_such_table_in_pool")
            let result = try await client.query("SELECT 11 AS eleven")
            return result.rows[0][0].int ?? -1
        }
        #expect(value == 11)
    }

    // MARK: - Keep-alive

    /// `COM_PING` keeps an idle connection from being reaped by the server's
    /// `wait_timeout`, which is minutes rather than hours behind many proxies.
    @Test("keep-alive holds an idle connection open")
    func keepAliveHoldsConnection() async throws {
        var configuration = Self.configuration(TestServers.latest, maximumConnections: 1)
        configuration.minimumConnections = 1
        configuration.keepAliveFrequency = .milliseconds(200)

        let value = try await Self.withClient(configuration) { client in
            _ = try await client.query("SELECT 1")
            // Wait for keep-alives to have actually run, rather than sleeping a
            // guessed multiple of the interval. Ties the wait to the event being
            // tested and fails loudly if keep-alive never fires at all.
            try await eventually("keep-alive to run at least twice") {
                client.statistics.keepAlivesSucceeded >= 2
            }
            let result = try await client.query("SELECT 5 AS five")
            return result.rows[0][0].int ?? -1
        }
        #expect(value == 5)
    }

    // MARK: - Observability

    /// Statistics are asserted directly rather than inferred from a metrics
    /// backend, which is what makes them testable at all.
    @Test("pool statistics track connection lifecycle", arguments: TestServers.all)
    func statisticsTrackLifecycle(server: MySQLTestServer) async throws {
        let client = MySQLClient(
            configuration: Self.configuration(server, maximumConnections: 2)
        )
        let stats = try await withThrowingTaskGroup(of: MySQLPoolStatistics?.self) { group in
            group.addTask {
                await client.run()
                return nil
            }
            group.addTask {
                _ = try await client.query("SELECT 1")
                _ = try await client.query("SELECT 2")
                return client.statistics
            }
            var result: MySQLPoolStatistics?
            while let next = try await group.next() {
                if let next { result = next; break }
            }
            group.cancelAll()
            return result!
        }

        #expect(stats.succeededConnects >= 1)
        #expect(stats.failedConnects == 0)
        #expect(stats.openConnections >= 1)
        #expect(stats.connecting == 0, "no connection attempt should still be in flight")
    }

    /// Connection failures must be counted, not swallowed.
    @Test("failed connections are counted")
    func failedConnectionsAreCounted() async throws {
        var connection = MySQLConnectionConfiguration(
            address: .hostname(TestServers.host, port: TestServers.latest.port),
            username: "no_such_user_for_metrics",
            password: "wrong",
            tls: .disable,
            serverPublicKey: .requestFromServer
        )
        connection.connectTimeout = .seconds(1)

        let client = MySQLClient(
            configuration: MySQLClient.Configuration(
                connection: connection,
                maximumConnections: 1,
                // Bounded, or this waits on the pool's retry backoff — which is
                // exactly the production hang the timeout exists to prevent.
                connectionAcquisitionTimeout: .seconds(3)
            )
        )

        let stats = try await withThrowingTaskGroup(of: MySQLPoolStatistics?.self) { group in
            group.addTask {
                await client.run()
                return nil
            }
            group.addTask {
                _ = try? await client.query("SELECT 1")
                // Waited for, not sampled once. `query` returns when the
                // *acquisition* deadline expires and the pool records a failed
                // connect on its own timeline, so the two are ordered only by
                // luck. This passed here on every run, loaded or idle, and
                // failed on Linux CI with `failedConnects == 0` — the attempt
                // was still in flight when the waiter gave up, which the pool
                // reports as `connecting` rather than as a failure.
                //
                // The assertion is not weakened: a pool that never counts the
                // failure still fails, five seconds later. What goes away is the
                // assumption that an attempt has *finished* by the time the
                // caller is told it cannot have a connection.
                try await eventually(within: .seconds(5), "a failed connect to be recorded") {
                    client.statistics.failedConnects >= 1
                }
                return client.statistics
            }
            var result: MySQLPoolStatistics?
            while let next = try await group.next() {
                if let next { result = next; break }
            }
            group.cancelAll()
            return result!
        }

        #expect(stats.failedConnects >= 1)
        #expect(stats.succeededConnects == 0)
    }

    /// Without a bounded wait, a database outage hangs every caller instead of
    /// failing them — the pool keeps retrying and the waiter stays queued.
    @Test("acquisition times out instead of hanging",
          .enabled(if: timingTestsEnabled, Comment(rawValue: timingTestsReason)))
    func acquisitionTimesOut() async throws {
        var connection = MySQLConnectionConfiguration(
            address: .hostname(TestServers.host, port: TestServers.latest.port),
            username: "no_such_user_for_timeout",
            password: "wrong",
            tls: .disable,
            serverPublicKey: .requestFromServer
        )
        connection.connectTimeout = .seconds(1)

        let client = MySQLClient(
            configuration: MySQLClient.Configuration(
                connection: connection,
                maximumConnections: 1,
                connectionAcquisitionTimeout: .seconds(2)
            )
        )

        let elapsed = try await withThrowingTaskGroup(of: Duration?.self) { group in
            group.addTask {
                await client.run()
                return nil
            }
            group.addTask {
                let clock = ContinuousClock()
                let start = clock.now
                do {
                    _ = try await client.query("SELECT 1")
                    Issue.record("expected the acquisition to time out")
                } catch let error as MySQLPoolError {
                    #expect(error == .connectionAcquisitionTimeout(.seconds(2)))
                } catch {
                    // Some servers reject fast enough that the connect error
                    // surfaces first, which is also an acceptable failure.
                }
                return clock.now - start
            }
            var result: Duration?
            while let next = try await group.next() {
                if let next { result = next; break }
            }
            group.cancelAll()
            return result!
        }

        // Comfortably bounded — the unbounded version took over a minute.
        #expect(elapsed < .seconds(10), "acquisition took \(elapsed)")
    }

    /// Keep-alive activity is observable, so a silently failing keep-alive
    /// cannot masquerade as a healthy pool.
    @Test("keep-alive activity is recorded")
    func keepAliveIsRecorded() async throws {
        var configuration = Self.configuration(TestServers.latest, maximumConnections: 1)
        configuration.minimumConnections = 1
        configuration.keepAliveFrequency = .milliseconds(150)

        let client = MySQLClient(configuration: configuration)
        let stats = try await withThrowingTaskGroup(of: MySQLPoolStatistics?.self) { group in
            group.addTask {
                await client.run()
                return nil
            }
            group.addTask {
                _ = try await client.query("SELECT 1")
                try await eventually("keep-alive to be recorded") {
                    client.statistics.keepAlivesTriggered >= 1
                }
                return client.statistics
            }
            var result: MySQLPoolStatistics?
            while let next = try await group.next() {
                if let next { result = next; break }
            }
            group.cancelAll()
            return result!
        }

        #expect(stats.keepAlivesTriggered >= 1, "expected keep-alive to have run")
        #expect(stats.keepAlivesFailed == 0)
    }

    // MARK: - Prepared statements through the pool

    /// A reset deallocates every server-side statement, so the per-connection
    /// cache must be dropped with it — otherwise a pooled connection hands out
    /// statement ids the server has forgotten.
    @Test("prepared statements survive pooling", arguments: TestServers.all)
    func preparedStatementsThroughPool(server: MySQLTestServer) async throws {
        let value = try await Self.withClient(
            Self.configuration(server, maximumConnections: 1)
        ) { client in
            var last: Int64 = -1
            for index in 0..<5 {
                let result = try await client.query(
                    "SELECT ? AS n", [.int(Int64(index))]
                )
                last = result.rows[0][0].int ?? -1
            }
            return last
        }
        #expect(value == 4)
    }
}

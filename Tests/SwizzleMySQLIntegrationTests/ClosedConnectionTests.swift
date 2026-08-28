import NIOCore
import NIOPosix
import SwizzleMySQL
import Testing

/// What a dead connection does when you use it.
///
/// ## Why this suite exists
///
/// `send` wrote its command with `promise: nil`. On a closed channel the write
/// failed, the failure was discarded, the request never reached the command
/// handler — and so **nothing ever fulfilled the command promise**. The caller's
/// `await` waited forever.
///
/// That is worse than it sounds. A pooled connection that died between being
/// handed out and being used would hang the request rather than fail it, with no
/// timeout underneath and nothing in a log to say why. It was found by a shadow
/// database calling `destroy()` twice; it would have been found in production by
/// a request that never came back.
@Suite(
    "MySQL closed connections", .serialized,
    .enabled(if: TestServers.isAvailable, "Integration servers not reachable")
)
struct ClosedConnectionTests {

    static func connect(_ server: MySQLTestServer) async throws -> MySQLConnection {
        let user = server.primaryUser
        var configuration = try MySQLConnectionConfiguration(
            url: "mysql://\(user.name):\(user.password)@\(TestServers.host):\(server.port)"
                + "/\(TestServers.database)?allow_public_key_retrieval=true&tls=require"
        )
        configuration.database = TestServers.database
        return try await MySQLConnection.connect(
            configuration: configuration, on: MultiThreadedEventLoopGroup.singleton.next()
        )
    }

    @Test("a query on a closed connection throws instead of hanging")
    func queryAfterClose() async throws {
        let connection = try await Self.connect(TestServers.mariadb114)
        try await connection.close()
        #expect(!connection.isActive)

        await #expect(throws: MySQLProtocolError.self) {
            _ = try await connection.query("SELECT 1")
        }
    }

    /// The error has to say *why*, not just that.
    ///
    /// `send` refuses to write to an inactive channel, and for a long time said
    /// only "the connection is closed". That is true and it is the least useful
    /// thing it could say: two binlog tests failed on a contended macOS runner
    /// with exactly that message and it named neither what closed the connection
    /// nor which side did it, so there was nothing to investigate from.
    ///
    /// These assert the message rather than the type. Every other test in this
    /// file checks `MySQLProtocolError.self`, which passes just as happily when
    /// the cause has been dropped on the floor — so without these the diagnosis
    /// would rot the first time somebody refactored the close path.
    @Test("a client-side close says the client closed it")
    func closeReasonNamesTheClient() async throws {
        let connection = try await Self.connect(TestServers.mariadb114)
        connection.closeImmediately()

        // Not `close()`: this is the abrupt path, and it must not claim the peer
        // hung up when the caller did.
        await #expect { try await connection.ping() } throws: { error in
            let text = "\(error)"
            return text.contains("closed by the client") && !text.contains("peer")
        }
    }

    /// The other side of it, and the one that matters when diagnosing a real
    /// failure: the server went away without being asked.
    ///
    /// `KILL` from a second connection is a genuine server-initiated close, so
    /// this exercises `channelInactive` rather than the local path — the two
    /// were indistinguishable before, both arriving as "the connection is
    /// closed".
    @Test("a server-side kill says the peer closed it")
    func closeReasonNamesThePeer() async throws {
        let victim = try await Self.connect(TestServers.mariadb114)
        defer { victim.closeImmediately() }
        let killer = try await Self.connect(TestServers.mariadb114)
        defer { killer.closeImmediately() }

        _ = try await killer.query("KILL \(victim.metadata.connectionID)")

        // The kill lands asynchronously; the connection is dead once the channel
        // notices, which is what is being waited for rather than a fixed delay.
        var text = ""
        for _ in 0..<200 {
            do {
                _ = try await victim.query("SELECT 1")
            } catch {
                text = "\(error)"
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        // What a kill looks like is up to the server and the timing, and both
        // shapes are correct: MariaDB usually sends an error packet first, so the
        // victim's next command fails with `.server(code: 1927, "Connection was
        // killed")`; if the socket is gone before that arrives, it surfaces as
        // the close diagnosis instead. The first version of this asserted the
        // second shape and passed on macOS, passed on Linux once, and failed on
        // Linux in the next run of the same job — it was asserting a race.
        //
        // The invariant that actually matters, and the one this test exists for,
        // is narrower and holds in both shapes: **a close we did not initiate is
        // never reported as one we did.** Misattributing a server-side kill to
        // the caller is precisely the wrong turn that would send someone looking
        // through their own code for a close they never made.
        #expect(!text.isEmpty, "the killed connection kept answering")
        #expect(
            !text.contains("closed by the client"),
            "a server-side kill was blamed on the client: \(text)"
        )
    }

    /// `closeImmediately` is the abrupt path — the one a pool takes when it
    /// decides a connection is not worth keeping — so it has to leave the
    /// connection in the same well-behaved state.
    @Test("the same holds after an abrupt close")
    func queryAfterImmediateClose() async throws {
        let connection = try await Self.connect(TestServers.mariadb114)
        connection.closeImmediately()
        // The close is asynchronous, so this waits on the connection's own
        // close notification rather than polling — no sleep, and no window where
        // the test could race ahead of the thing it is testing.
        await withCheckedContinuation { continuation in
            connection.onClose { _ in continuation.resume() }
        }

        await #expect(throws: MySQLProtocolError.self) {
            _ = try await connection.query("SELECT 1")
        }
    }

    /// Closing a TLS connection must not take five seconds.
    ///
    /// NIOSSL's graceful close sends `close_notify` and waits for the peer's,
    /// defaulting to five seconds. MySQL never sends one — it answers `COM_QUIT`
    /// by closing the socket — so that default was five seconds of held socket,
    /// held server session and held pool slot for every finished connection. A
    /// `close()` that returns in five seconds is indistinguishable from a hang,
    /// which is exactly how this was found.
    ///
    /// The bound is generous on purpose: this is guarding against *seconds*, and
    /// a tight assertion would flake on a loaded machine without catching
    /// anything a loose one misses.
    @Test("closing a TLS connection is prompt")
    func tlsCloseIsPrompt() async throws {
        let connection = try await Self.connect(TestServers.mariadb114)
        // The fixture negotiates TLS by default; if that ever changes, this test
        // would pass for the wrong reason.
        #expect(connection.metadata.isTLSActive)

        let start = ContinuousClock().now
        try await connection.close()
        let elapsed = ContinuousClock().now - start

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
        #expect(elapsed < .seconds(3), "close took \(elapsed)")
    }

    /// Every command goes through the same `send`, so the fix has to hold for
    /// more than `query` — `ping` in particular is what a pool's keep-alive runs,
    /// and a keep-alive that hangs takes the pool's maintenance loop with it.
    @Test("ping and prepare fail the same way")
    func otherCommandsAfterClose() async throws {
        let connection = try await Self.connect(TestServers.mariadb114)
        try await connection.close()

        await #expect(throws: MySQLProtocolError.self) { try await connection.ping() }
        await #expect(throws: MySQLProtocolError.self) {
            _ = try await connection.prepare("SELECT 1")
        }
    }
}

import Foundation
import NIOCore
import NIOPosix
import SwizzlePostgres
import SwizzlePostgresDriver
import Testing

/// The connect timeout, which this driver had no way to set.
///
/// `libpq` spells it `connect_timeout`, `tokio-postgres` exposes it as
/// `Config::connect_timeout`, and our own MySQL driver has had one since it was
/// written — the Postgres side never grew one.
///
/// Measured rather than assumed: with the setting removed, a black-holed host
/// fails in **10.003 s**, because NIO's `ClientBootstrap` applies its own
/// ten-second default. So connections were never unbounded, and the gap was
/// configurability — a service that would rather fail over in 500 ms could not
/// ask for that, and `connect_timeout` in a URL was rejected outright.
@Suite(
    "Postgres connect timeout",
    .enabled(if: PostgresTestServer.isAvailable, PostgresTestServer.skipReason)
)
struct PostgresConnectTimeoutTests {

    /// `192.0.2.0/24` is TEST-NET-1, reserved by RFC 5737 for documentation and
    /// guaranteed not to be routed. A connection there does not get refused — it
    /// gets *nothing*, which is precisely the case a timeout exists for and the
    /// case an unreachable-but-responding host would not reproduce.
    static let blackHole = "192.0.2.1"

    @Test("a black-holed host fails within the timeout rather than hanging")
    func timesOut() async throws {
        var configuration = PostgresConnectionConfiguration(
            address: .tcp(host: Self.blackHole, port: 5432),
            username: "swizzle"
        )
        configuration.connectTimeout = .milliseconds(300)

        let start = ContinuousClock().now
        await #expect(throws: (any Error).self) {
            let connection = try await PostgresConnection.connect(
                configuration: configuration,
                on: MultiThreadedEventLoopGroup.singleton.next()
            )
            connection.closeImmediately()
        }
        let elapsed = ContinuousClock().now - start

        // Five seconds is the discriminating threshold, not a precision claim:
        // the setting asks for 300 ms and NIO's default is 10 s, so anything in
        // between separates "our value was applied" from "the default was".
        #expect(
            elapsed < .seconds(5),
            "took \(elapsed) — the configured connect timeout did not apply"
        )
    }

    /// A timeout that also broke *working* connections would be worse than none.
    @Test("the timeout does not interfere with a reachable server")
    func reachableServerStillConnects() async throws {
        var configuration = try PostgresConnectionConfiguration(
            swizzleURL: PostgresTestServer.url
        )
        configuration.connectTimeout = .seconds(5)

        let connection = try await PostgresConnection.connect(
            configuration: configuration,
            on: MultiThreadedEventLoopGroup.singleton.next()
        )
        defer { connection.closeImmediately() }
        #expect(try await connection.query("SELECT 1").rows[0][0] == .int(1))
    }

    // MARK: - The URL parameter

    @Test("connect_timeout is read from the URL, in libpq's unit")
    func urlParameter() throws {
        let configuration = try PostgresConnectionConfiguration(
            swizzleURL: "postgres://u:p@h:5432/d?connect_timeout=3"
        )
        #expect(configuration.connectTimeout == .seconds(3))
    }

    /// libpq treats a non-positive `connect_timeout` as "wait indefinitely", and
    /// so does this — expressed as a very long wait rather than as a special case
    /// that has to be checked everywhere else.
    @Test("zero means no timeout, as libpq says")
    func zeroMeansUnbounded() throws {
        let configuration = try PostgresConnectionConfiguration(
            swizzleURL: "postgres://u:p@h:5432/d?connect_timeout=0"
        )
        #expect(configuration.connectTimeout == .hours(24))
    }

    @Test("a non-numeric connect_timeout is refused")
    func nonNumericIsRefused() {
        #expect(throws: PostgresURLError.self) {
            _ = try PostgresConnectionConfiguration(
                swizzleURL: "postgres://u:p@h:5432/d?connect_timeout=soon"
            )
        }
    }

    /// The default is present and finite. A default of "forever" would make the
    /// option look implemented while leaving the hang in place for everyone who
    /// did not set it.
    @Test("the default is finite")
    func defaultIsFinite() {
        let configuration = PostgresConnectionConfiguration(
            address: .tcp(host: "localhost", port: 5432), username: "u"
        )
        #expect(configuration.connectTimeout == .seconds(10))
    }
}

/// The default TLS mode, on both paths.
///
/// Its own suite because it caught a real defect: the initialiser defaulted to
/// `verify-full`, the documentation said `verify-full`, and the **URL parser** —
/// the path nearly every caller takes — set `prefer`. The comment claiming
/// otherwise sat directly above the line that contradicted it, so the advertised
/// secure default applied to almost nobody.
// test-hygiene: no server — pure configuration parsing
@Suite("Postgres TLS default")
struct PostgresTLSDefaultTests {

    @Test("the initialiser defaults to verify-full")
    func initialiserDefault() {
        let configuration = PostgresConnectionConfiguration(
            address: .tcp(host: "db.example.com", port: 5432), username: "u"
        )
        #expect(configuration.tlsMode == .verifyFull)
    }

    /// The one that was wrong.
    @Test("a URL with no sslmode defaults to verify-full too")
    func urlDefault() throws {
        let configuration = try PostgresConnectionConfiguration(
            swizzleURL: "postgres://u:p@db.example.com/app"
        )
        #expect(
            configuration.tlsMode == .verifyFull,
            "the URL path must not be weaker than the initialiser"
        )
    }

    /// And a URL that names a mode still gets exactly that mode — the default
    /// must not override an explicit choice.
    @Test("an explicit sslmode still wins")
    func explicitModeWins() throws {
        for (spelling, expected) in [
            ("disable", PostgresTLSMode.disable),
            ("prefer", .prefer),
            ("require", .require),
            ("verify-ca", .verifyCA),
            ("verify-full", .verifyFull),
        ] {
            let configuration = try PostgresConnectionConfiguration(
                swizzleURL: "postgres://u:p@h/d?sslmode=\(spelling)"
            )
            #expect(configuration.tlsMode == expected, "sslmode=\(spelling)")
        }
    }
}

/// Trust roots and client certificates from the URL.
///
/// **The gap the `verify-full` default created.** With verification on by default
/// and no way to name a CA in a URL, a `DATABASE_URL` pointing at a private-CA
/// server could not be made to work at all without abandoning the URL and
/// building a `TLSConfiguration` in code — and `DATABASE_URL` is how most
/// deployments are configured. `libpq` has had `sslrootcert` all along;
/// `tokio-postgres` does not, so this is one place we go past the reference
/// because our own default made it necessary.
// test-hygiene: no server — the one test that connects carries its own gate
@Suite("Postgres URL trust roots")
struct PostgresURLTrustRootTests {

    static var fixtureCertificate: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // SwizzlePostgresTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // package root
            .appendingPathComponent(
                ".testservers/data-\(PostgresTestServer.platformTag)/postgres16/server.crt"
            ).path
    }

    /// End to end: the same server `verify-ca` refuses on trust grounds is
    /// accepted once the URL names the certificate that signed it.
    ///
    /// The fixture's certificate is self-signed, so it is its own CA — which is
    /// exactly the private-CA shape this parameter exists for.
    @Test(
        "sslrootcert makes verify-ca succeed against the fixture",
        .enabled(if: PostgresTestServer.isAvailable, PostgresTestServer.skipReason)
    )
    func trustRootFromURL() async throws {
        let certificate = Self.fixtureCertificate
        guard FileManager.default.fileExists(atPath: certificate) else {
            Issue.record("fixture has no certificate at \(certificate)"); return
        }
        // Without the query string, because this test appends its own `sslmode`
        // and certificate parameters.
        let base = PostgresTestServer.baseURL

        // The control. Without it a permissive `verify-ca` would make the next
        // assertion pass for the wrong reason.
        await #expect(throws: (any Error).self) {
            let connection = try await PostgresConnection.connect(
                configuration: try PostgresConnectionConfiguration(
                    swizzleURL: "\(base)?sslmode=verify-ca"
                ),
                on: MultiThreadedEventLoopGroup.singleton.next()
            )
            connection.closeImmediately()
        }

        let connection = try await PostgresConnection.connect(
            configuration: try PostgresConnectionConfiguration(
                swizzleURL: "\(base)?sslmode=verify-ca&sslrootcert=\(certificate)"
            ),
            on: MultiThreadedEventLoopGroup.singleton.next()
        )
        defer { connection.closeImmediately() }
        #expect(try await connection.query("SELECT 1").rows[0][0] == .int(1))
    }

    /// A path that is not there fails **where it was written**, not three layers
    /// down in a handshake.
    @Test("a missing or invalid certificate path fails at parse time")
    func badPaths() throws {
        #expect(throws: PostgresURLError.self) {
            _ = try PostgresConnectionConfiguration(
                swizzleURL: "postgres://u:p@h/d?sslrootcert=/nope/ca.pem"
            )
        }
        // Half a client identity is not an identity.
        #expect(throws: PostgresURLError.self) {
            _ = try PostgresConnectionConfiguration(
                swizzleURL: "postgres://u:p@h/d?sslcert=/tmp/c.pem"
            )
        }
        #expect(throws: PostgresURLError.self) {
            _ = try PostgresConnectionConfiguration(
                swizzleURL: "postgres://u:p@h/d?sslkey=/tmp/k.pem"
            )
        }
    }

    /// Existence is not enough — a file that is present but is not a certificate
    /// would otherwise fail at the first connection instead of at the URL.
    @Test("a file that is not a certificate is refused")
    func notACertificate() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("swizzle-pgnotacert-\(UInt32.random(in: 0..<UInt32.max)).pem")
        try "not a certificate".write(to: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: path) }

        #expect(throws: PostgresURLError.self) {
            _ = try PostgresConnectionConfiguration(
                swizzleURL: "postgres://u:p@h/d?sslrootcert=\(path.path)"
            )
        }
    }

    /// An error must not carry the URL, which holds the password — error strings
    /// are exactly what ends up in logs.
    @Test("the error does not leak the password")
    func errorDoesNotLeakCredentials() {
        do {
            _ = try PostgresConnectionConfiguration(
                swizzleURL: "postgres://u:hunter2@h/d?sslrootcert=/nope/ca.pem"
            )
            Issue.record("expected a refusal")
        } catch {
            #expect(!"\(error)".contains("hunter2"))
        }
    }
}

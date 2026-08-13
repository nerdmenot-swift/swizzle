import NIOCore
import NIOPosix
import NIOSSL
import SwizzleCore
import SwizzlePostgresDriver
import Testing

/// SCRAM-SHA-256-PLUS, against a real TLS connection.
///
/// The fixture had no TLS at all until this suite, which meant the driver's whole
/// TLS path against Postgres — and the `-PLUS` mechanism entirely — had never
/// run. That is the same gap that let SCRAM itself ship broken under
/// `--auth=trust`, so it is closed rather than reasoned around.
@Suite(
    "Postgres channel binding", .serialized,
    .enabled(if: PostgresTestServer.isAvailable, PostgresTestServer.skipReason)
)
struct PostgresChannelBindingIntegrationTests {

    static func configuration(
        user: String, password: String?, tls: PostgresTLSMode,
        binding: PostgresChannelBindingMode = .preferred
    ) -> PostgresConnectionConfiguration {
        var configuration = PostgresConnectionConfiguration(
            address: .tcp(host: "127.0.0.1", port: 5432),
            username: user, password: password, database: "swizzle_test",
            tlsMode: tls
        )
        // The fixture's certificate is self-signed, so verification would fail
        // for a reason that has nothing to do with what is under test.
        configuration.tlsMode = tls
        configuration.channelBinding = binding
        return configuration
    }

    static func connect(
        _ configuration: PostgresConnectionConfiguration
    ) async throws -> PostgresConnection {
        try await PostgresConnection.connect(
            configuration: configuration, on: MultiThreadedEventLoopGroup.singleton.next()
        )
    }

    /// **The end-to-end proof.** TLS is up, the server offers `-PLUS`, and the
    /// certificate hash goes into the signature — which the server recomputes
    /// from its own certificate and checks. A wrong hash fails authentication, so
    /// a successful connection *is* the verification.
    @Test("SCRAM-SHA-256-PLUS authenticates over TLS")
    func channelBindingWorks() async throws {
        let connection = try await Self.connect(
            Self.configuration(user: "swizzle_cb", password: "cbpass", tls: .require)
        )
        defer { connection.closeImmediately() }

        #expect(connection.metadata.isTLSActive)
        #expect(connection.metadata.saslMechanism == "SCRAM-SHA-256-PLUS")

        let rows = try await connection.query("SELECT current_user").rows
        #expect(rows[0][0] == .text("swizzle_cb"))
    }

    /// Without TLS there is no certificate, so no binding — and the connection
    /// takes a different `pg_hba` rule entirely.
    ///
    /// The fixture ends with a catch-all `trust` line, so a plaintext connection
    /// as this user succeeds *without SASL at all* rather than being rejected.
    /// Asserting `saslMechanism == nil` is what makes that visible: the point is
    /// that `-PLUS` above was negotiated because TLS was up, not because the user
    /// forces it.
    @Test("without TLS there is no SASL and no binding")
    func withoutTLS() async throws {
        let connection = try await Self.connect(
            Self.configuration(user: "swizzle_cb", password: "cbpass", tls: .disable)
        )
        defer { connection.closeImmediately() }

        #expect(!connection.metadata.isTLSActive)
        #expect(connection.metadata.saslMechanism == nil)
    }

    /// With binding switched off the client asks for the plain mechanism, and the
    /// server — which does not *require* binding — accepts it. This is what
    /// proves the `-PLUS` above was a real negotiation rather than the only
    /// option.
    @Test("binding can be turned off, and the plain mechanism still works")
    func bindingDisabled() async throws {
        let connection = try await Self.connect(
            Self.configuration(
                user: "swizzle_cb", password: "cbpass", tls: .require, binding: .disabled
            )
        )
        defer { connection.closeImmediately() }

        #expect(connection.metadata.isTLSActive)
        #expect(connection.metadata.saslMechanism == "SCRAM-SHA-256")
    }

    /// A wrong password must still fail with binding in play — otherwise the
    /// mechanism would be proving something other than the password.
    @Test("channel binding does not weaken the password check")
    func wrongPasswordStillFails() async throws {
        await #expect(throws: (any Error).self) {
            let connection = try await Self.connect(
                Self.configuration(user: "swizzle_cb", password: "wrong", tls: .require)
            )
            connection.closeImmediately()
        }
    }

    /// And the ordinary TLS path works too — the first time it has been exercised
    /// against Postgres at all.
    @Test("a plain TLS connection still authenticates and queries")
    func tlsWorksGenerally() async throws {
        let connection = try await Self.connect(
            Self.configuration(user: "swizzle_scram", password: "scrampass", tls: .require)
        )
        defer { connection.closeImmediately() }

        #expect(connection.metadata.isTLSActive)
        let rows = try await connection.query("SELECT $1::int", [.int(7)]).rows
        #expect(rows[0][0] == .int(7))
    }
}

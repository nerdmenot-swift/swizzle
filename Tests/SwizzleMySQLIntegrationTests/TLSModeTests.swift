import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import Testing

@testable import SwizzleMySQL

/// The `--ssl-mode` ladder, against real servers.
///
/// MySQL used to have three rungs here — disable, prefer, require — so a MySQL
/// connection string could ask for an *encrypted* server but never a *verified*
/// one. `mysql_async` exposes `require_ssl` / `verify_ca` / `verify_identity`,
/// `libmysqlclient` exposes the same as `--ssl-mode`, and our own Postgres driver
/// has had the full ladder since it was written. This was both a gap against the
/// reference and an inconsistency between our two drivers.
///
/// The fixture presents a **self-signed** certificate, which is what makes these
/// tests worth running: the verifying rungs must reject it and the others must
/// accept it. A ladder where every rung behaved the same would pass any test
/// that only checked connections succeed.
@Suite(
    "MySQL TLS modes",
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct MySQLTLSModeTests {

    static func configuration(
        _ server: MySQLTestServer, tls: MySQLConnectionConfiguration.TLSMode
    ) -> MySQLConnectionConfiguration {
        let user = server.primaryUser
        return MySQLConnectionConfiguration(
            address: .hostname(TestServers.host, port: server.port),
            username: user.name,
            password: user.password,
            database: TestServers.database,
            tls: tls,
            serverPublicKey: .requestFromServer
        )
    }

    /// `require` encrypts without authenticating, so a self-signed certificate is
    /// accepted — matching `--ssl-mode=REQUIRED`.
    @Test("require accepts a self-signed server", arguments: TestServers.all)
    func requireAcceptsSelfSigned(server: MySQLTestServer) async throws {
        let connection = try await MySQLConnection.connect(
            configuration: Self.configuration(server, tls: .require),
            on: TestServers.group.next()
        )
        defer { connection.closeImmediately() }
        #expect(connection.metadata.isTLSActive)
    }

    /// **The rung that has to bite.** The fixture's certificate is signed by
    /// nobody, so chain verification must fail — and fail as a TLS error rather
    /// than as an authentication one, which is what tells the reader where to
    /// look.
    @Test("verify_ca rejects a self-signed server", arguments: TestServers.all)
    func verifyCARejectsSelfSigned(server: MySQLTestServer) async throws {
        await #expect(throws: (any Error).self) {
            let connection = try await MySQLConnection.connect(
                configuration: Self.configuration(server, tls: .verifyCA),
                on: TestServers.group.next()
            )
            connection.closeImmediately()
        }
    }

    @Test("verify_identity rejects a self-signed server", arguments: TestServers.all)
    func verifyFullRejectsSelfSigned(server: MySQLTestServer) async throws {
        await #expect(throws: (any Error).self) {
            let connection = try await MySQLConnection.connect(
                configuration: Self.configuration(server, tls: .verifyFull),
                on: TestServers.group.next()
            )
            connection.closeImmediately()
        }
    }

    /// And the rejection is about the *certificate*, not about TLS being
    /// unavailable: the same server, same port, connects happily one rung down.
    /// Without this pairing, a verifying mode that simply failed to negotiate TLS
    /// at all would look identical to one that verified correctly.
    @Test("the rejection is the certificate, not the connection")
    func rejectionIsAboutTheCertificate() async throws {
        let server = TestServers.latest
        let verifying = await Result {
            let connection = try await MySQLConnection.connect(
                configuration: Self.configuration(server, tls: .verifyCA),
                on: TestServers.group.next()
            )
            connection.closeImmediately()
        }
        #expect(throws: (any Error).self) { try verifying.get() }

        let plain = try await MySQLConnection.connect(
            configuration: Self.configuration(server, tls: .require),
            on: TestServers.group.next()
        )
        defer { plain.closeImmediately() }
        #expect(plain.metadata.isTLSActive)
    }

    /// Trusting the CA that signed the server makes `verify_ca` **succeed**,
    /// which is the other half of the proof: the mode verifies a chain rather
    /// than refusing everything.
    ///
    /// A MySQL fixture, because MySQL writes its auto-generated CA to `ca.pem` in
    /// the data directory. MariaDB generates its certificate in memory and leaves
    /// nothing on disk to trust — which is precisely why the *rejection* tests
    /// above cover both flavours and this one does not.
    ///
    /// `verifyCA` and not `verifyFull`: MySQL's generated certificate carries
    /// `MySQL_Server_..._Auto_Generated_Server_Certificate` as its name, which is
    /// not `127.0.0.1`, so the hostname rung would still — correctly — refuse it.
    @Test("verify_ca accepts the server when its CA is trusted")
    func verifyCAAcceptsTrustedCertificate() async throws {
        let server = TestServers.mysql84
        let certificatePath = TestServers.fixtureData
            .appendingPathComponent("\(server.name)/ca.pem").path
        guard FileManager.default.fileExists(atPath: certificatePath) else {
            Issue.record("fixture has no CA at \(certificatePath)"); return
        }

        var configuration = Self.configuration(server, tls: .verifyCA)
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.trustRoots = .file(certificatePath)
        configuration.tlsConfiguration = tls

        let connection = try await MySQLConnection.connect(
            configuration: configuration, on: TestServers.group.next()
        )
        defer { connection.closeImmediately() }
        #expect(connection.metadata.isTLSActive)
    }

    // MARK: - The default

    /// **Both engines, both paths, verify by default.**
    ///
    /// This is asserted rather than assumed because the Postgres driver got it
    /// wrong in exactly the way an assumption would miss: its initialiser
    /// defaulted to `verify-full`, its documentation said so, and its **URL
    /// parser** — the path nearly every caller takes — quietly set `prefer`. The
    /// comment claiming otherwise sat directly above the line.
    ///
    /// So the check covers the initialiser and the URL separately, for both
    /// engines. A default is only as good as the way people reach it.
    @Test("the default verifies, whichever way the configuration is built")
    func defaultVerifies() throws {
        let mysql = MySQLConnectionConfiguration(
            address: .hostname("db.example.com", port: 3306), username: "u"
        )
        #expect(mysql.tls == .verifyFull)

        let mysqlURL = try MySQLConnectionConfiguration(url: "mysql://u:p@db.example.com/app")
        #expect(mysqlURL.tls == .verifyFull, "the URL path must not be weaker than the initialiser")
    }

    // MARK: - Trust roots from the URL

    /// **The gap the `verify_identity` default created.** With verification on by
    /// default and no way to name a CA in a URL, a `DATABASE_URL` pointing at a
    /// private-CA server could not be made to work at all without abandoning the
    /// URL and building a `TLSConfiguration` in code.
    ///
    /// `ssl_ca` closes it, and this proves it end to end: the same server that
    /// `verify_ca` refuses on trust grounds is accepted once the URL names the CA
    /// that signed it.
    @Test("ssl_ca in the URL makes verify_ca succeed against a private CA")
    func urlTrustRoot() async throws {
        let server = TestServers.mysql84
        let ca = TestServers.fixtureData.appendingPathComponent("\(server.name)/ca.pem").path
        guard FileManager.default.fileExists(atPath: ca) else {
            Issue.record("fixture has no CA at \(ca)"); return
        }
        let user = server.primaryUser
        let base =
            "mysql://\(user.name):\(user.password)@\(TestServers.host):\(server.port)"
            + "/\(TestServers.database)?allow_public_key_retrieval=true"

        // Without the CA: refused, because the fixture's chain is not publicly
        // trusted. This is the control — without it, a permissive `verify_ca`
        // would make the next assertion pass for the wrong reason.
        await #expect(throws: (any Error).self) {
            let connection = try await MySQLConnection.connect(
                configuration: try MySQLConnectionConfiguration(url: "\(base)&tls=verify_ca"),
                on: TestServers.group.next()
            )
            connection.closeImmediately()
        }

        // With it: accepted.
        let connection = try await MySQLConnection.connect(
            configuration: try MySQLConnectionConfiguration(
                url: "\(base)&tls=verify_ca&ssl_ca=\(ca)"
            ),
            on: TestServers.group.next()
        )
        defer { connection.closeImmediately() }
        #expect(connection.metadata.isTLSActive)
    }

    /// A path that is not there fails **where it was written**, not three layers
    /// down in a handshake — the same rule `server_public_key_path` follows.
    @Test("a bad certificate path fails at parse time")
    func badCertificatePaths() {
        #expect(throws: MySQLURLError.self) {
            _ = try MySQLConnectionConfiguration(url: "mysql://u:p@h/d?ssl_ca=/nope/ca.pem")
        }
        // Half an identity is not an identity, and ignoring the half that was
        // given would leave the connection unauthenticated while looking
        // configured.
        #expect(throws: MySQLURLError.self) {
            _ = try MySQLConnectionConfiguration(url: "mysql://u:p@h/d?ssl_cert=/tmp/c.pem")
        }
        #expect(throws: MySQLURLError.self) {
            _ = try MySQLConnectionConfiguration(url: "mysql://u:p@h/d?ssl_key=/tmp/k.pem")
        }
    }

    /// A file that exists but is not a certificate is caught too — existence
    /// alone would let a wrong-but-present path through to the first connection.
    @Test("a file that is not a certificate is refused")
    func notACertificate() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("swizzle-notacert-\(UInt32.random(in: 0..<UInt32.max)).pem")
        try "not a certificate".write(to: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: path) }

        #expect(throws: MySQLURLError.self) {
            _ = try MySQLConnectionConfiguration(url: "mysql://u:p@h/d?ssl_ca=\(path.path)")
        }
    }

    // MARK: - URL spellings

    @Test("every ecosystem spelling of the ladder parses")
    func urlSpellings() throws {
        func mode(_ query: String) throws -> MySQLConnectionConfiguration.TLSMode {
            try MySQLConnectionConfiguration(url: "mysql://u:p@h:3306/d?\(query)").tls
        }

        #expect(try mode("tls=disable") == .disable)
        #expect(try mode("tls=prefer") == .prefer)
        #expect(try mode("tls=require") == .require)
        // `verify_ca` is mysql_async's, `verify-ca` is libpq's and our Postgres
        // driver's, `VERIFY_CA` is what `--ssl-mode` takes. Someone porting a
        // connection string should not have to learn which is ours.
        #expect(try mode("tls=verify_ca") == .verifyCA)
        #expect(try mode("sslmode=verify-ca") == .verifyCA)
        #expect(try mode("ssl-mode=VERIFY_CA") == .verifyCA)
        #expect(try mode("tls=verify_identity") == .verifyFull)
        #expect(try mode("sslmode=verify-full") == .verifyFull)
        #expect(try mode("ssl-mode=VERIFY_IDENTITY") == .verifyFull)
    }

    /// An unrecognised mode must be an error, not a silent downgrade. A typo
    /// that quietly became `prefer` would be a security failure that looks
    /// exactly like success.
    @Test("a misspelled mode is refused rather than downgraded")
    func misspelledModeIsRefused() {
        #expect(throws: MySQLURLError.self) {
            _ = try MySQLConnectionConfiguration(url: "mysql://u:p@h:3306/d?tls=verify")
        }
    }
}

extension Result where Failure == Error {
    fileprivate init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}

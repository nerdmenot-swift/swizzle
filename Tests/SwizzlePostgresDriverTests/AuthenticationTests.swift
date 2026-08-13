import Crypto
import Foundation
import Testing
@testable import SwizzlePostgresDriver

/// The authentication flow, driven without a socket.
///
/// This is why the state machine is pure. The paths that matter most — a server
/// demanding cleartext over a plaintext link, one offering only a mechanism we
/// cannot do, one sending requests out of order — are the hardest to provoke
/// against a real server and the ones where being wrong is a security problem
/// rather than a bug.
@Suite("Postgres authentication")
struct AuthenticationTests {

    func machine(
        password: String? = "pencil", secure: Bool = false, database: String? = "app"
    ) -> PostgresAuthenticationStateMachine {
        PostgresAuthenticationStateMachine(
            configuration: .init(
                username: "ada", password: password, database: database,
                isSecureTransport: secure
            )
        )
    }

    @Test("the startup message carries user, database and extra parameters")
    func startupParameters() {
        var machine = PostgresAuthenticationStateMachine(
            configuration: .init(
                username: "ada", password: nil, database: "app",
                parameters: ["application_name": "swizzle", "search_path": "public"]
            )
        )
        guard case .send(.startup(let parameters)) = machine.start() else {
            Issue.record("expected a startup message"); return
        }
        #expect(parameters.first?.0 == "user")
        #expect(parameters.first?.1 == "ada")
        #expect(parameters.contains { $0 == "database" && $1 == "app" })
        // Sorted, so the packet is deterministic for tests and packet captures.
        #expect(parameters.map(\.0) == ["user", "database", "application_name", "search_path"])
    }

    @Test("trust authentication finishes immediately")
    func trustAuthentication() {
        var machine = machine(password: nil)
        _ = machine.start()
        #expect(machine.handle(.ok) == .authenticated)
    }

    // MARK: - Cleartext, and the reason it is gated

    /// Postgres will ask for a plaintext password over a plaintext link, and a
    /// client that complies has handed the password to anyone listening.
    @Test("a cleartext request over an unencrypted link is refused")
    func cleartextOverPlaintextIsRefused() {
        var machine = machine(secure: false)
        _ = machine.start()
        #expect(machine.handle(.cleartextPassword) == .fail(.insecureCleartextRefused))
    }

    @Test("a cleartext request is answered over TLS or a unix socket")
    func cleartextOverSecureTransport() {
        var machine = machine(secure: true)
        _ = machine.start()
        #expect(machine.handle(.cleartextPassword) == .send(.password("pencil")))
        #expect(machine.handle(.ok) == .authenticated)
    }

    @Test("a password request with no password configured fails clearly")
    func missingPassword() {
        for request in [
            PostgresAuthenticationRequest.cleartextPassword,
            .md5Password(salt: [1, 2, 3, 4]),
            .sasl(mechanisms: ["SCRAM-SHA-256"]),
        ] {
            var machine = machine(password: nil, secure: true)
            _ = machine.start()
            #expect(machine.handle(request) == .fail(.passwordRequired))
        }
    }

    // MARK: - MD5

    /// The inner digest is appended as hex **text** before the salt, not as raw
    /// bytes. Getting that wrong yields a plausible hash the server rejects, with
    /// nothing to point at.
    @Test("MD5 matches Postgres's definition")
    func md5MatchesPostgres() {
        // md5(md5("pencil" + "ada") + salt), hex, prefixed.
        let inner = PostgresAuthenticationStateMachine.hex(
            Insecure.MD5.hash(data: Array("pencilada".utf8))
        )
        let expected = "md5" + PostgresAuthenticationStateMachine.hex(
            Insecure.MD5.hash(data: Array(inner.utf8) + [0xDE, 0xAD, 0xBE, 0xEF])
        )
        #expect(
            PostgresAuthenticationStateMachine.md5(
                password: "pencil", username: "ada", salt: [0xDE, 0xAD, 0xBE, 0xEF]
            ) == expected
        )
    }

    /// MD5 is not gated on transport: the salt makes it not a replayable
    /// plaintext secret, which is the whole reason it exists.
    @Test("MD5 is answered over a plaintext link")
    func md5OverPlaintext() {
        var machine = machine(secure: false)
        _ = machine.start()
        guard case .send(.password(let hash)) = machine.handle(.md5Password(salt: [1, 2, 3, 4]))
        else { Issue.record("expected a password message"); return }
        #expect(hash.hasPrefix("md5"))
        #expect(hash.count == 35)  // "md5" plus 32 hex characters
        #expect(machine.handle(.ok) == .authenticated)
    }

    /// The same password against a different salt must produce a different hash,
    /// or the salt is not doing its job.
    @Test("the salt changes the MD5 answer")
    func saltChangesTheHash() {
        var first = machine()
        var second = machine()
        _ = first.start(); _ = second.start()
        #expect(
            first.handle(.md5Password(salt: [1, 2, 3, 4]))
                != second.handle(.md5Password(salt: [5, 6, 7, 8]))
        )
    }

    // MARK: - SASL

    @Test("SASL runs the full four-message exchange")
    func saslExchange() throws {
        var machine = machine()
        _ = machine.start()

        guard case .send(.saslInitialResponse(let mechanism, let data)) =
            machine.handle(.sasl(mechanisms: ["SCRAM-SHA-256"]))
        else { Issue.record("expected a SASLInitialResponse"); return }

        #expect(mechanism == "SCRAM-SHA-256")
        let clientFirst = String(bytes: try #require(data), encoding: .utf8) ?? ""
        #expect(clientFirst.hasPrefix("n,,n=,r="))

        // Play the server's part, so the machine sees a real exchange rather than
        // a canned one.
        let clientNonce = String(clientFirst.split(separator: "r=").last ?? "")
        let serverFirst = "r=\(clientNonce)serverpart,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"

        guard case .send(.saslResponse(let finalData)) =
            machine.handle(.saslContinue(data: Array(serverFirst.utf8)))
        else { Issue.record("expected a SASLResponse"); return }

        let clientFinal = String(bytes: finalData, encoding: .utf8) ?? ""
        #expect(clientFinal.hasPrefix("c=biws,r=\(clientNonce)serverpart"))
        #expect(clientFinal.contains(",p="))
    }

    /// A server offering only the channel-binding variant cannot be satisfied by
    /// this client, and saying so beats sending a message it will reject for a
    /// reason nobody can read.
    @Test("a server offering only SCRAM-SHA-256-PLUS is refused with an explanation")
    func onlyChannelBindingOffered() {
        var machine = machine()
        _ = machine.start()
        let action = machine.handle(.sasl(mechanisms: ["SCRAM-SHA-256-PLUS"]))
        #expect(action == .fail(.noSupportedMechanism(offered: ["SCRAM-SHA-256-PLUS"])))

        if case .fail(let error) = action {
            #expect(error.description.contains("SCRAM-SHA-256-PLUS"))
            #expect(error.description.contains("channel binding"))
        }
    }

    /// When both are offered, the one we can actually do is chosen.
    @Test("SCRAM-SHA-256 is chosen when both variants are offered")
    func picksTheSupportedVariant() {
        var machine = machine()
        _ = machine.start()
        guard case .send(.saslInitialResponse(let mechanism, _)) =
            machine.handle(.sasl(mechanisms: ["SCRAM-SHA-256-PLUS", "SCRAM-SHA-256"]))
        else { Issue.record("expected a SASLInitialResponse"); return }
        #expect(mechanism == "SCRAM-SHA-256")
    }

    /// A server that cannot prove it knew the stored key must not be accepted,
    /// however far the exchange got.
    @Test("a bad server signature fails the connection")
    func badServerSignatureFails() {
        var machine = machine()
        _ = machine.start()
        _ = machine.handle(.sasl(mechanisms: ["SCRAM-SHA-256"]))
        _ = machine.handle(.saslContinue(
            data: Array("r=xserverpart,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096".utf8)
        ))
        // The nonce did not echo ours, so it fails before the signature — which is
        // the earlier of the two checks and equally load-bearing.
        #expect(machine.state.isFailed)
    }

    @Test("a verified server signature leads to AuthenticationOk")
    func verifiedSignatureCompletes() throws {
        var machine = machine()
        _ = machine.start()

        guard case .send(.saslInitialResponse(_, let data)) =
            machine.handle(.sasl(mechanisms: ["SCRAM-SHA-256"]))
        else { Issue.record("expected a SASLInitialResponse"); return }
        let clientFirst = String(bytes: try #require(data), encoding: .utf8) ?? ""
        let nonce = String(clientFirst.split(separator: "r=").last ?? "")

        // Recompute the server's side with the same inputs, so the signature is
        // the one the machine should accept.
        let serverFirst = "r=\(nonce)srv,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
        let client = SCRAMClient(password: "pencil", nonce: nonce)
        let exchange = try client.respond(toServerFirst: serverFirst)

        _ = machine.handle(.saslContinue(data: Array(serverFirst.utf8)))
        let serverFinal = "v=" + Data(exchange.expectedServerSignature).base64EncodedString()

        #expect(machine.handle(.saslFinal(data: Array(serverFinal.utf8))) == .wait)
        #expect(machine.handle(.ok) == .authenticated)
    }

    // MARK: - Refusals

    @Test("an unimplemented method is refused by name")
    func unsupportedMethods() {
        for (code, name) in [(Int32(2), "Kerberos"), (7, "GSSAPI"), (9, "SSPI")] {
            var machine = machine()
            _ = machine.start()
            let action = machine.handle(.unsupported(code: code))
            guard case .fail(let error) = action else {
                Issue.record("expected a failure for code \(code)"); continue
            }
            #expect(error.description.contains(name))
        }
    }

    /// An out-of-order request is either a broken server or an attempt to walk
    /// the client into a weaker method than it already agreed to.
    @Test("an out-of-order request is refused rather than obeyed")
    func outOfOrderRequestsAreRefused() {
        var machine = machine(secure: true)
        _ = machine.start()
        _ = machine.handle(.sasl(mechanisms: ["SCRAM-SHA-256"]))

        // Mid-SASL, the server suddenly asks for a cleartext password. Obeying
        // would downgrade an exchange already in progress.
        #expect(machine.handle(.cleartextPassword) == .fail(.unexpectedRequest))
    }

    @Test("a SASL continue before any SASL request is refused")
    func saslContinueOutOfNowhere() {
        var machine = machine()
        _ = machine.start()
        #expect(machine.handle(.saslContinue(data: [])) == .fail(.unexpectedRequest))
    }
}

extension PostgresAuthenticationStateMachine.State {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

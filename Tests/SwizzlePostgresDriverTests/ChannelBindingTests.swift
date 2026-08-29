import Crypto
import Foundation
import Testing
@testable import SwizzlePostgresDriver

@Suite("SCRAM channel binding")
struct ChannelBindingTests {

    // MARK: - The gs2 header

    /// Three headers, three meanings, and the middle one is the security-relevant
    /// case rather than a formality.

    // MARK: - The DER length parser

    /// Boundaries in `readHeader`, which the mutation sweep found nothing was
    /// checking: `<= becomes <` and `> becomes >=` both survived on the guard
    /// that validates a long-form length.
    ///
    /// This parser reads a **server-supplied certificate** — untrusted input on
    /// the authentication path — so its boundaries are worth pinning. The whole
    /// suite only ever fed it well-formed certificates, which exercise the happy
    /// path of that guard and none of its edges.
    ///
    /// `readHeader` is reached through `@testable`; that is deliberate. Driving
    /// these cases through a real certificate would mean hand-forging DER with a
    /// four-byte length and a truncated tail, which is a worse test of the same
    /// three comparisons.
    @Test("a long-form length of zero bytes is refused")
    func indefiniteLengthIsRefused() {
        // `0x80` is the indefinite form: valid in BER, forbidden in DER, and the
        // `byteCount > 0` arm is what rejects it. Relaxing that to `>= 0` accepts
        // it and returns a length of zero, which a caller reads as an empty
        // element rather than as malformed input.
        var index = 0
        #expect(PostgresChannelBinding.readHeader([0x30, 0x80], &index, expecting: 0x30) == nil)
    }

    /// The upper end of the same guard. Four length bytes is the most this
    /// accepts, so it has to be accepted — `<= 4` narrowed to `< 4` rejects a
    /// legitimate certificate rather than a malformed one, which is the more
    /// expensive direction to be wrong in.
    @Test("a four-byte length is accepted, a five-byte one is not")
    func fourByteLengthIsTheCeiling() {
        var index = 0
        let fourBytes: [UInt8] = [0x30, 0x84, 0x00, 0x01, 0x00, 0x00]
        #expect(PostgresChannelBinding.readHeader(fourBytes, &index, expecting: 0x30) == 65536)

        index = 0
        let fiveBytes: [UInt8] = [0x30, 0x85, 0x00, 0x00, 0x00, 0x01, 0x00]
        #expect(PostgresChannelBinding.readHeader(fiveBytes, &index, expecting: 0x30) == nil)
    }

    /// The truncation guard. The length bytes may reach exactly the end of the
    /// buffer and no further, so `index + byteCount <= der.count` has to admit
    /// equality — tightening it to `<` rejects a length that ends flush with the
    /// input, and loosening it reads past the end.
    @Test("length bytes may end flush with the buffer but not run past it")
    func truncatedLengthIsRefused() {
        // Two length bytes, and exactly two remain: the boundary case.
        var index = 0
        #expect(PostgresChannelBinding.readHeader([0x30, 0x82, 0x01, 0x00], &index, expecting: 0x30) == 256)

        // Two length bytes promised, one supplied.
        index = 0
        #expect(PostgresChannelBinding.readHeader([0x30, 0x82, 0x01], &index, expecting: 0x30) == nil)
    }

    /// The short form still has to work — it is the branch taken before the
    /// long-form guard is reached at all.
    @Test("a short-form length is read directly")
    func shortFormLength() {
        var index = 0
        #expect(PostgresChannelBinding.readHeader([0x30, 0x05], &index, expecting: 0x30) == 5)
        #expect(index == 2)
    }

    @Test("each binding state produces its own gs2 header")
    func headers() {
        #expect(SCRAMClient.ChannelBinding.none.header == "n,,")
        #expect(SCRAMClient.ChannelBinding.supportedButServerDidNot.header == "y,,")
        #expect(
            SCRAMClient.ChannelBinding.tlsServerEndPoint(certificateHash: [1, 2, 3]).header
                == "p=tls-server-end-point,,"
        )
    }

    @Test("only the bound state asks for the PLUS mechanism")
    func mechanisms() {
        #expect(SCRAMClient.ChannelBinding.none.mechanism == "SCRAM-SHA-256")
        #expect(
            SCRAMClient.ChannelBinding.supportedButServerDidNot.mechanism == "SCRAM-SHA-256"
        )
        #expect(
            SCRAMClient.ChannelBinding.tlsServerEndPoint(certificateHash: []).mechanism
                == "SCRAM-SHA-256-PLUS"
        )
    }

    // MARK: - c= carries the binding data

    /// RFC 5802: `c=` is base64 of the gs2 header **followed by the binding
    /// data**. Because `c=` is inside the AuthMessage, the certificate hash is
    /// inside every signature — which is the entire mechanism.
    @Test("the certificate hash lands inside the client-final message")
    func bindingDataIsInTheProof() throws {
        let hash: [UInt8] = Array(repeating: 0xAB, count: 32)
        let bound = SCRAMClient(
            password: "pencil", username: "user", nonce: "fyko+d2lbbFgONRv9qkxdawL",
            channelBinding: .tlsServerEndPoint(certificateHash: hash)
        )
        let serverFirst =
            "r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,"
            + "s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"

        let exchange = try bound.respond(toServerFirst: serverFirst)
        let expected = Data(Array("p=tls-server-end-point,,".utf8) + hash)
            .base64EncodedString()
        #expect(exchange.clientFinalMessage.hasPrefix("c=\(expected),"))
    }

    /// A different certificate produces a different proof — which is what a man
    /// in the middle cannot get around. Same password, same nonce, same salt: only
    /// the certificate differs.
    @Test("a different certificate produces a different proof")
    func differentCertificateDifferentProof() throws {
        let serverFirst =
            "r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,"
            + "s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"

        func proof(certificate: [UInt8]) throws -> String {
            let client = SCRAMClient(
                password: "pencil", username: "user", nonce: "fyko+d2lbbFgONRv9qkxdawL",
                channelBinding: .tlsServerEndPoint(certificateHash: certificate)
            )
            return try client.respond(toServerFirst: serverFirst).clientFinalMessage
        }

        let real = try proof(certificate: Array(repeating: 0xAA, count: 32))
        let relay = try proof(certificate: Array(repeating: 0xBB, count: 32))
        #expect(real != relay)
    }

    /// The unbound cases keep their existing behaviour exactly — `c=biws` is
    /// base64 of `n,,` and appears in every SCRAM trace ever captured.
    @Test("the unbound header is unchanged")
    func unboundIsUnchanged() throws {
        let serverFirst =
            "r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,"
            + "s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
        let client = SCRAMClient(
            password: "pencil", username: "user", nonce: "fyko+d2lbbFgONRv9qkxdawL"
        )
        #expect(try client.respond(toServerFirst: serverFirst).clientFinalMessage
            .hasPrefix("c=biws,"))

        // `y,,` is `eSws`.
        let downgraded = SCRAMClient(
            password: "pencil", username: "user", nonce: "fyko+d2lbbFgONRv9qkxdawL",
            channelBinding: .supportedButServerDidNot
        )
        #expect(try downgraded.respond(toServerFirst: serverFirst).clientFinalMessage
            .hasPrefix("c=eSws,"))
    }

    // MARK: - Mechanism selection and the downgrade tripwire

    func machine(
        binding: [UInt8]?, mechanisms: [String]
    ) -> PostgresAuthenticationStateMachine.Action {
        var machine = PostgresAuthenticationStateMachine(
            configuration: .init(
                username: "u", password: "p", isSecureTransport: true,
                channelBindingData: { binding }
            )
        )
        _ = machine.start()
        return machine.handle(.sasl(mechanisms: mechanisms))
    }

    @Test("PLUS is chosen when both sides can do it")
    func choosesPLUS() {
        let action = machine(
            binding: Array(repeating: 0xAA, count: 32),
            mechanisms: ["SCRAM-SHA-256", "SCRAM-SHA-256-PLUS"]
        )
        guard case .send(.saslInitialResponse(let mechanism, let data)) = action else {
            Issue.record("expected a SASL response, got \(action)"); return
        }
        #expect(mechanism == "SCRAM-SHA-256-PLUS")
        #expect(String(decoding: data ?? [], as: UTF8.self).hasPrefix("p=tls-server-end-point,,"))
    }

    /// **The downgrade tripwire.** If a man in the middle strips `-PLUS` from the
    /// mechanism list to force the weaker exchange, the `y` reaches a server that
    /// knows it *does* support binding, and the server aborts. Sending `n` here
    /// would make that attack silent.
    @Test("a stripped mechanism list is reported to the server with y")
    func downgradeTripwire() {
        let action = machine(
            binding: Array(repeating: 0xAA, count: 32),
            mechanisms: ["SCRAM-SHA-256"]
        )
        guard case .send(.saslInitialResponse(let mechanism, let data)) = action else {
            Issue.record("expected a SASL response, got \(action)"); return
        }
        #expect(mechanism == "SCRAM-SHA-256")
        // `y`, not `n` — that single character is the whole detection.
        #expect(String(decoding: data ?? [], as: UTF8.self).hasPrefix("y,,"))
    }

    /// Without TLS there is nothing to bind to, so `n` is the truth rather than a
    /// downgrade — claiming `y` would make a plaintext connection look like a
    /// stripped one and fail against a binding-capable server.
    @Test("a plaintext connection says n, not y")
    func plaintextSaysNo() {
        let action = machine(binding: nil, mechanisms: ["SCRAM-SHA-256"])
        guard case .send(.saslInitialResponse(_, let data)) = action else {
            Issue.record("expected a SASL response, got \(action)"); return
        }
        #expect(String(decoding: data ?? [], as: UTF8.self).hasPrefix("n,,"))
    }

    /// A server offering only `-PLUS` to a client that cannot bind is a real
    /// configuration — `scram_channel_binding=require` — and has to fail with a
    /// reason rather than a mechanism the server will reject.
    @Test("a PLUS-only server is refused when binding is impossible")
    func plusOnlyWithoutBinding() {
        let action = machine(binding: nil, mechanisms: ["SCRAM-SHA-256-PLUS"])
        guard case .fail(.noSupportedMechanism(let offered)) = action else {
            Issue.record("expected a refusal, got \(action)"); return
        }
        #expect(offered == ["SCRAM-SHA-256-PLUS"])
    }

    // MARK: - Which hash the certificate gets

    /// RFC 5929 §4: the certificate's **own signature hash**, not SHA-256
    /// unconditionally. A SHA-384 certificate hashed with SHA-256 produces a value
    /// the server will not agree with — an authentication failure with nothing in
    /// the message to suggest why.
    ///
    /// `NIOSSLCertificate` does not expose the algorithm, so it is read out of the
    /// DER. These are hand-built headers rather than real certificates, which is
    /// what makes each branch reachable.
    func certificate(signatureOID: [UInt8]) -> [UInt8] {
        // Certificate ::= SEQUENCE { tbsCertificate SEQUENCE {…}, signatureAlgorithm … }
        let tbs: [UInt8] = [0x30, 0x03, 0x02, 0x01, 0x00]
        let algorithm: [UInt8] = [0x30, UInt8(signatureOID.count)] + signatureOID
        let body = tbs + algorithm
        return [0x30, UInt8(body.count)] + body
    }

    @Test("the signature algorithm selects the hash")
    func signatureAlgorithmSelectsHash() {
        let rsa: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01]
        let ecdsa: [UInt8] = [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03]

        #expect(
            PostgresChannelBinding.signatureHash(der: certificate(signatureOID: rsa + [0x0B]))
                == .sha256
        )
        #expect(
            PostgresChannelBinding.signatureHash(der: certificate(signatureOID: rsa + [0x0C]))
                == .sha384
        )
        #expect(
            PostgresChannelBinding.signatureHash(der: certificate(signatureOID: rsa + [0x0D]))
                == .sha512
        )
        #expect(
            PostgresChannelBinding.signatureHash(der: certificate(signatureOID: ecdsa + [0x02]))
                == .sha256
        )
        #expect(
            PostgresChannelBinding.signatureHash(der: certificate(signatureOID: ecdsa + [0x03]))
                == .sha384
        )
        #expect(
            PostgresChannelBinding.signatureHash(der: certificate(signatureOID: ecdsa + [0x04]))
                == .sha512
        )
    }

    /// MD5 and SHA-1 are **upgraded** to SHA-256 rather than used: binding to a
    /// broken hash would let an attacker with a collision substitute a certificate
    /// that binds identically.
    @Test("weak signature algorithms are upgraded, not inherited")
    func weakAlgorithmsUpgrade() {
        let rsa: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01]
        // md5WithRSA (0x04) and sha1WithRSA (0x05).
        #expect(
            PostgresChannelBinding.signatureHash(der: certificate(signatureOID: rsa + [0x04]))
                == .sha256
        )
        #expect(
            PostgresChannelBinding.signatureHash(der: certificate(signatureOID: rsa + [0x05]))
                == .sha256
        )
    }

    /// The hash is over the whole DER, and the chosen algorithm actually changes
    /// the output — otherwise the selection above would be decorative.
    @Test("the selected algorithm is the one applied")
    func hashUsesTheSelectedAlgorithm() {
        let rsa: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01]
        let sha256Certificate = certificate(signatureOID: rsa + [0x0B])
        let sha512Certificate = certificate(signatureOID: rsa + [0x0D])

        #expect(PostgresChannelBinding.hash(der: sha256Certificate).count == 32)
        #expect(PostgresChannelBinding.hash(der: sha512Certificate).count == 64)
        #expect(
            PostgresChannelBinding.hash(der: sha256Certificate)
                == [UInt8](SHA256.hash(data: sha256Certificate))
        )
    }

    /// Real certificates are long enough to need the long-form length, so a
    /// parser that only handled the short form would fail on every one of them.
    @Test("long-form DER lengths are handled")
    func longFormLengths() {
        let rsa: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0D]
        // A tbsCertificate of 300 bytes forces a two-byte length.
        let tbsBody = [UInt8](repeating: 0x00, count: 300)
        let tbs: [UInt8] = [0x30, 0x82, 0x01, 0x2C] + tbsBody
        let algorithm: [UInt8] = [0x30, UInt8(rsa.count)] + rsa
        let body = tbs + algorithm
        let der: [UInt8] = [0x30, 0x82] + [UInt8(body.count >> 8), UInt8(body.count & 0xFF)] + body

        #expect(PostgresChannelBinding.signatureHash(der: der) == .sha512)
    }

    /// Garbage must not crash or read out of bounds — this parser sees whatever
    /// the peer sent.
    @Test("malformed DER falls back rather than crashing")
    func malformedDER() {
        #expect(PostgresChannelBinding.signatureHash(der: []) == .sha256)
        #expect(PostgresChannelBinding.signatureHash(der: [0x30]) == .sha256)
        #expect(PostgresChannelBinding.signatureHash(der: [0x30, 0xFF]) == .sha256)
        #expect(PostgresChannelBinding.signatureHash(der: [0x30, 0x84, 0x7F, 0xFF]) == .sha256)
        #expect(
            PostgresChannelBinding.signatureHash(der: Array(repeating: 0x30, count: 64))
                == .sha256
        )
    }
}

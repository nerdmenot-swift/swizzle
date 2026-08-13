import Foundation
import Testing
@testable import SwizzlePostgresDriver

/// SCRAM by known answer, not by round-trip.
///
/// A client that talks only to itself agrees with itself whatever it computes —
/// swap `Client Key` and `Server Key` and every round-trip test still passes. The
/// vectors below come from RFC 7677, so they fail if any step is wrong.
@Suite("SCRAM-SHA-256")
struct SCRAMTests {

    /// RFC 7677 §3, the worked example for SCRAM-SHA-256.
    ///
    ///     username: user     password: pencil
    ///     client nonce: rOprNGfwEbeRWgbNEkqO
    enum RFC7677 {
        static let clientNonce = "rOprNGfwEbeRWgbNEkqO"
        static let serverFirst =
            "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,"
            + "s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
        static let expectedProof = "dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ="
        static let serverFinal = "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="
    }

    @Test("the client's first message has the shape RFC 5802 requires")
    func clientFirstMessage() {
        let rfc = SCRAMClient(password: "pencil", username: "user", nonce: RFC7677.clientNonce)
        #expect(rfc.clientFirstMessage == "n,,n=user,r=\(RFC7677.clientNonce)")

        // Postgres's own convention: the username travels in the startup message,
        // so `n=` is empty here.
        let postgres = SCRAMClient(password: "pencil", nonce: RFC7677.clientNonce)
        #expect(postgres.clientFirstMessage == "n,,n=,r=\(RFC7677.clientNonce)")
    }

    /// `=` and `,` delimit attributes, so a username containing either would be
    /// read by the server as extra attributes.
    @Test("a username with delimiters is escaped")
    func usernameEscaping() {
        #expect(SCRAMClient.escape("a,b") == "a=2Cb")
        #expect(SCRAMClient.escape("a=b") == "a=3Db")
        // The `=` rule runs first, or it would re-escape the `=` the comma rule
        // introduces and produce `a=3D2Cb`.
        #expect(SCRAMClient.escape("a=,b") == "a=3D=2Cb")
    }

    /// The proof is the whole handshake in one value: get the salted password,
    /// the client key, the stored key or the auth message wrong and it differs.
    @Test("the client proof matches RFC 7677")
    func clientProofMatchesRFC() throws {
        let client = SCRAMClient(password: "pencil", username: "user", nonce: RFC7677.clientNonce)
        let exchange = try client.respond(toServerFirst: RFC7677.serverFirst)

        #expect(exchange.clientFinalMessage.hasSuffix("p=\(RFC7677.expectedProof)"))
        // `biws` is base64 of "n,," — the channel-binding attribute.
        #expect(exchange.clientFinalMessage.hasPrefix("c=biws,r=rOprNGfwEbeRWgbNEkqO"))
    }

    /// Verifying the server's final message is what makes this mutual
    /// authentication rather than a password being posted into the void.
    @Test("the server's signature is verified against RFC 7677")
    func serverSignatureIsVerified() throws {
        let client = SCRAMClient(password: "pencil", username: "user", nonce: RFC7677.clientNonce)
        let exchange = try client.respond(toServerFirst: RFC7677.serverFirst)
        try client.verify(serverFinal: RFC7677.serverFinal, against: exchange)
    }

    @Test("a wrong server signature is rejected")
    func wrongServerSignatureIsRejected() throws {
        let client = SCRAMClient(password: "pencil", username: "user", nonce: RFC7677.clientNonce)
        let exchange = try client.respond(toServerFirst: RFC7677.serverFirst)

        #expect(throws: SCRAMError.self) {
            try client.verify(
                serverFinal: "v=" + Data(repeating: 0, count: 32).base64EncodedString(),
                against: exchange
            )
        }
    }

    /// A server that does not echo our nonce is replaying somebody else's
    /// exchange, or is not the server it claims to be.
    @Test("a server that does not echo the client nonce is refused")
    func nonceMustBeEchoed() {
        let client = SCRAMClient(password: "pencil", username: "user", nonce: RFC7677.clientNonce)
        #expect(throws: SCRAMError.nonceMismatch) {
            _ = try client.respond(
                toServerFirst: "r=somebodyElsesNonce,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
            )
        }
    }

    /// The iteration count arrives from the server and drives a PBKDF2 loop, so
    /// an unbounded value is a denial of service that needs no credentials.
    /// pgjdbc capped this for CVE-2026-42198 and the reference followed.
    @Test("an absurd iteration count is refused rather than performed")
    func iterationCountIsCapped() {
        let client = SCRAMClient(password: "pencil", username: "user", nonce: RFC7677.clientNonce)

        #expect(throws: SCRAMError.self) {
            _ = try client.respond(
                toServerFirst: "r=\(RFC7677.clientNonce)x,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=999999999"
            )
        }

        // The cap is generous — 24× Postgres's own default — so a server using a
        // hardened count still works.
        #expect(SCRAMClient.maximumIterationCount == 100_000)
        #expect(throws: Never.self) {
            _ = try client.respond(
                toServerFirst: "r=\(RFC7677.clientNonce)x,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=100000"
            )
        }
    }

    @Test("a nonsensical iteration count is refused")
    func nonPositiveIterationCount() {
        let client = SCRAMClient(password: "pencil", username: "user", nonce: RFC7677.clientNonce)
        for count in ["0", "-1"] {
            #expect(throws: SCRAMError.self) {
                _ = try client.respond(
                    toServerFirst: "r=\(RFC7677.clientNonce)x,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=\(count)"
                )
            }
        }
    }

    @Test("a malformed server-first is refused")
    func malformedServerFirst() {
        let client = SCRAMClient(password: "pencil", username: "user", nonce: RFC7677.clientNonce)
        for message in [
            "s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096",                    // no nonce
            "r=\(RFC7677.clientNonce)x,i=4096",                      // no salt
            "r=\(RFC7677.clientNonce)x,s=W22ZaJ0SNY7soEsUEjb6gQ==",  // no iterations
            "r=\(RFC7677.clientNonce)x,s=not base64!,i=4096",
        ] {
            #expect(throws: SCRAMError.self) {
                _ = try client.respond(toServerFirst: message)
            }
        }
    }

    /// A server may report failure in the final message instead of a signature.
    @Test("a server error in the final message surfaces")
    func serverErrorInFinalMessage() throws {
        let client = SCRAMClient(password: "pencil", username: "user", nonce: RFC7677.clientNonce)
        let exchange = try client.respond(toServerFirst: RFC7677.serverFirst)
        #expect(throws: SCRAMError.serverRejected("invalid-proof")) {
            try client.verify(serverFinal: "e=invalid-proof", against: exchange)
        }
    }

    /// A base64 salt routinely ends in `=` padding. Splitting on every `=` rather
    /// than the first would silently truncate it, and the proof would be wrong for
    /// a reason nothing points at.
    @Test("attribute parsing keeps base64 padding intact")
    func parsingKeepsPadding() throws {
        let attributes = try SCRAMClient.parse("s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096")
        #expect(attributes["s"] == "W22ZaJ0SNY7soEsUEjb6gQ==")
        #expect(attributes["i"] == "4096")
    }

    /// The delimiters are `,` and `=`; a nonce containing either would be parsed
    /// by the server as two attributes.
    @Test("generated nonces cannot break the attribute syntax")
    func noncesAreSafe() {
        for _ in 0..<200 {
            let nonce = SCRAMClient.makeNonce()
            #expect(nonce.count == 24)
            #expect(!nonce.contains(","))
            #expect(!nonce.contains("="))
        }
        // And they differ, or the exchange offers no replay protection at all.
        #expect(Set((0..<50).map { _ in SCRAMClient.makeNonce() }).count == 50)
    }

    @Test("an ASCII password is passed through untouched")
    func asciiPasswordsAreUnchanged() {
        #expect(SCRAMClient.normalize("pencil") == Array("pencil".utf8))
        #expect(SCRAMClient.normalize("p@ssw0rd!") == Array("p@ssw0rd!".utf8))
    }

    /// Constant time is the point; this only checks it still answers correctly.
    @Test("the MAC comparison is correct as well as constant-time")
    func constantTimeComparison() {
        #expect(SCRAMClient.constantTimeEquals([1, 2, 3], [1, 2, 3]))
        #expect(!SCRAMClient.constantTimeEquals([1, 2, 3], [1, 2, 4]))
        #expect(!SCRAMClient.constantTimeEquals([1, 2, 3], [1, 2]))
        #expect(SCRAMClient.constantTimeEquals([], []))
    }
}

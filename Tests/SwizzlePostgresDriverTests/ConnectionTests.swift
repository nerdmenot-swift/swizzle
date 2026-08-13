import Foundation
import NIOCore
import NIOEmbedded
import Testing
@testable import SwizzlePostgresDriver

@Suite("Postgres message decoding over a channel")
struct MessageDecoderTests {

    func channel() throws -> EmbeddedChannel {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(PostgresMessageDecoder())
        )
        return channel
    }

    func framed(_ tag: Character, _ body: (inout ByteBuffer) -> Void) -> ByteBuffer {
        var payload = ByteBufferAllocator().buffer(capacity: 32)
        body(&payload)
        var buffer = ByteBufferAllocator().buffer(capacity: payload.readableBytes + 5)
        buffer.writeInteger(tag.asciiValue!)
        buffer.writeInteger(Int32(payload.readableBytes + 4))
        buffer.writeImmutableBuffer(payload)
        return buffer
    }

    /// A handshake arrives as a burst, so several messages in one read must all
    /// be delivered rather than one per read.
    @Test("several messages in one read are all delivered")
    func burstIsFullyDelivered() throws {
        let channel = try channel()
        var buffer = framed("1") { _ in }
        buffer.writeImmutableBuffer(framed("2") { _ in })
        buffer.writeImmutableBuffer(framed("Z") { $0.writeInteger(UInt8(ascii: "I")) })

        try channel.writeInbound(buffer)
        #expect(try channel.readInbound(as: PostgresBackendMessage.self) == .parseComplete)
        #expect(try channel.readInbound(as: PostgresBackendMessage.self) == .bindComplete)
        #expect(try channel.readInbound(as: PostgresBackendMessage.self) == .readyForQuery(.idle))
        _ = try channel.finish()
    }

    /// One message split across every possible boundary must still arrive exactly
    /// once — which is the whole reason the decoder holds partial state.
    @Test("a message split byte by byte still arrives once")
    func messageSplitAcrossReads() throws {
        let complete = framed("S") { $0.writeCString("TimeZone"); $0.writeCString("UTC") }

        for split in 1..<complete.readableBytes {
            let channel = try channel()
            var first = complete
            var second = first.readSlice(length: split)!
            swap(&first, &second)

            try channel.writeInbound(first)
            #expect(try channel.readInbound(as: PostgresBackendMessage.self) == nil)
            try channel.writeInbound(second)
            #expect(
                try channel.readInbound(as: PostgresBackendMessage.self)
                    == .parameterStatus(name: "TimeZone", value: "UTC")
            )
            _ = try? channel.finish()
        }
    }

    /// Postgres has no equivalent of MySQL's 16 MiB chunking: one message
    /// declares one length. So a hostile server can declare four gigabytes and
    /// watch the client reserve it — the exact hole the MySQL audit found, closed
    /// here from the first commit.
    @Test("an absurd declared length is refused before anything is reserved")
    func oversizedMessageIsRefused() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(PostgresMessageDecoder(maximumMessageSize: 1024))
        )

        var buffer = ByteBufferAllocator().buffer(capacity: 8)
        buffer.writeInteger(UInt8(ascii: "D"))
        buffer.writeInteger(Int32(2_000_000_000))

        #expect(throws: (any Error).self) { try channel.writeInbound(buffer) }
        _ = try? channel.finish()
    }

    @Test("a length below the minimum is refused")
    func impossibleLengthIsRefused() throws {
        let channel = try channel()
        var buffer = ByteBufferAllocator().buffer(capacity: 8)
        buffer.writeInteger(UInt8(ascii: "Z"))
        buffer.writeInteger(Int32(1))

        #expect(throws: (any Error).self) { try channel.writeInbound(buffer) }
        _ = try? channel.finish()
    }

    /// "The connection closed" and "the connection closed mid-message" are
    /// different problems, and only one of them is the server's fault.
    @Test("a truncated message at EOF is reported rather than discarded")
    func truncatedAtEOF() throws {
        let channel = try channel()
        var buffer = framed("S") { $0.writeCString("TimeZone"); $0.writeCString("UTC") }
        buffer.moveWriterIndex(to: buffer.writerIndex - 3)

        try channel.writeInbound(buffer)
        #expect(throws: (any Error).self) { try channel.finish() }
    }

    @Test("frontend messages encode through the pipeline")
    func encoderRoundTrip() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            MessageToByteHandler(PostgresMessageEncoder())
        )
        try channel.writeOutbound(PostgresFrontendMessage.sync)

        var written = try #require(try channel.readOutbound(as: ByteBuffer.self))
        #expect(written.readInteger(as: UInt8.self) == UInt8(ascii: "S"))
        #expect(written.readInteger(as: Int32.self) == 4)
        _ = try channel.finish()
    }
}

@Suite("Postgres connection handshake")
struct ConnectionStateMachineTests {

    func machine(secure: Bool = false) -> PostgresConnectionStateMachine {
        PostgresConnectionStateMachine(
            configuration: .init(
                username: "ada", password: "pencil", database: "app",
                isSecureTransport: secure
            )
        )
    }

    @Test("the handshake ends at ReadyForQuery, not at AuthenticationOk")
    func handshakeEndsAtReadyForQuery() {
        var machine = machine()
        #expect(machine.start() != .wait)

        // Authenticated, but not yet usable: the parameters and the cancellation
        // key still have to arrive.
        #expect(machine.handle(.authentication(.ok)) == .wait)
        #expect(machine.handle(.parameterStatus(name: "server_version", value: "16.2")) == .wait)
        #expect(machine.handle(.backendKeyData(processID: 1234, secretKey: 5678)) == .wait)
        #expect(machine.handle(.readyForQuery(.idle)) == .ready)
    }

    /// These change how values decode, so they are kept rather than logged.
    @Test("server parameters are retained")
    func parametersAreRetained() {
        var machine = machine()
        _ = machine.start()
        _ = machine.handle(.authentication(.ok))
        _ = machine.handle(.parameterStatus(name: "integer_datetimes", value: "on"))
        _ = machine.handle(.parameterStatus(name: "DateStyle", value: "ISO, MDY"))
        _ = machine.handle(.readyForQuery(.idle))

        #expect(machine.parameters["integer_datetimes"] == "on")
        #expect(machine.parameters["DateStyle"] == "ISO, MDY")
    }

    /// `SET` makes the server push a fresh `ParameterStatus` mid-session, so a
    /// machine that only collected them during the handshake would go stale.
    @Test("parameters pushed after the handshake are picked up")
    func parametersUpdateMidSession() {
        var machine = machine()
        _ = machine.start()
        _ = machine.handle(.authentication(.ok))
        _ = machine.handle(.parameterStatus(name: "TimeZone", value: "UTC"))
        _ = machine.handle(.readyForQuery(.idle))

        _ = machine.handle(.parameterStatus(name: "TimeZone", value: "Europe/London"))
        #expect(machine.parameters["TimeZone"] == "Europe/London")
    }

    /// Cancelling a query needs a second connection quoting this pair. Dropping
    /// it makes cancellation impossible, quietly.
    @Test("the cancellation key is kept")
    func cancellationKeyIsKept() {
        var machine = machine()
        _ = machine.start()
        _ = machine.handle(.authentication(.ok))
        _ = machine.handle(.backendKeyData(processID: 4242, secretKey: 99))
        _ = machine.handle(.readyForQuery(.idle))

        #expect(machine.backendKey?.processID == 4242)
        #expect(machine.backendKey?.secretKey == 99)
    }

    /// The `E` status is how a client knows a transaction is poisoned. Without it,
    /// every statement after the first failure reports its own error and the
    /// original cause is twelve messages back.
    @Test("the transaction status is tracked")
    func transactionStatusIsTracked() {
        var machine = machine()
        _ = machine.start()
        _ = machine.handle(.authentication(.ok))
        _ = machine.handle(.readyForQuery(.idle))
        #expect(machine.transactionStatus == .idle)

        _ = machine.handle(.readyForQuery(.inTransaction))
        #expect(machine.transactionStatus == .inTransaction)

        _ = machine.handle(.readyForQuery(.failed))
        #expect(machine.transactionStatus == .failed)
    }

    /// `NOTICE` is how Postgres says "this column will be dropped". Swallowing it
    /// loses the only warning anybody gets.
    @Test("notices are delivered, not swallowed")
    func noticesAreKept() {
        var machine = machine()
        _ = machine.start()
        let notice = PostgresServerMessage(fields: [
            0x53: "NOTICE", 0x4D: "identifier will be truncated",
        ])
        #expect(machine.handle(.notice(notice)) == .wait)
        #expect(machine.notices.count == 1)
        #expect(machine.notices.first?.message == "identifier will be truncated")
    }

    /// A failed login is the most common connection error there is, so its message
    /// has to carry the server's own words.
    @Test("an authentication failure reports the server's message")
    func serverErrorDuringHandshake() {
        var machine = machine()
        _ = machine.start()

        let action = machine.handle(.error(PostgresServerMessage(fields: [
            0x53: "FATAL", 0x43: "28P01",
            0x4D: "password authentication failed for user \"ada\"",
        ])))

        guard case .fail(let error) = action else {
            Issue.record("expected a failure"); return
        }
        #expect(error.description.contains("password authentication failed"))
        #expect(error.description.contains("28P01"))
    }

    /// Postgres puts the useful half in `hint` — the message is often just
    /// "syntax error at or near …".
    @Test("detail and hint are included in the rendered error")
    func detailAndHintAreRendered() {
        let message = PostgresServerMessage(fields: [
            0x53: "ERROR", 0x43: "42P01", 0x4D: "relation \"user\" does not exist",
            0x48: "Perhaps you meant \"users\".",
        ])
        let rendered = PostgresConnectionError.render(message)
        #expect(rendered.contains("Perhaps you meant"))
        #expect(rendered.contains("42P01"))
    }

    /// Carrying on after a version rejection fails later with something that looks
    /// unrelated.
    @Test("a protocol version rejection is reported rather than ignored")
    func protocolVersionRejection() {
        var machine = machine()
        _ = machine.start()
        let action = machine.handle(
            .negotiateProtocolVersion(newest: 0x0003_0000, unsupported: ["_pq_.some_option"])
        )
        guard case .fail(let error) = action else {
            Issue.record("expected a failure"); return
        }
        #expect(error.description.contains("3.0"))
    }

    @Test("a full SCRAM handshake reaches ready")
    func scramHandshakeToReady() throws {
        var machine = machine()
        _ = machine.start()

        guard case .send(.saslInitialResponse(_, let data)) =
            machine.handle(.authentication(.sasl(mechanisms: ["SCRAM-SHA-256"])))
        else { Issue.record("expected a SASLInitialResponse"); return }

        let clientFirst = String(bytes: try #require(data), encoding: .utf8) ?? ""
        let nonce = String(clientFirst.split(separator: "r=").last ?? "")
        let serverFirst = "r=\(nonce)srv,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"

        let client = SCRAMClient(password: "pencil", nonce: nonce)
        let exchange = try client.respond(toServerFirst: serverFirst)

        guard case .send(.saslResponse) =
            machine.handle(.authentication(.saslContinue(data: Array(serverFirst.utf8))))
        else { Issue.record("expected a SASLResponse"); return }

        let serverFinal = "v=" + Data(exchange.expectedServerSignature).base64EncodedString()
        #expect(machine.handle(.authentication(.saslFinal(data: Array(serverFinal.utf8)))) == .wait)
        #expect(machine.handle(.authentication(.ok)) == .wait)
        #expect(machine.handle(.readyForQuery(.idle)) == .ready)
    }
}

@Suite("Postgres TLS modes")
struct TLSModeTests {

    /// `prefer` is libpq's default and provides no guarantee at all: a network
    /// attacker strips the offer and the client carries on in the clear. This
    /// driver does not default to it, and the flags say why.
    @Test("prefer attempts TLS but does not require it")
    func preferIsWeak() {
        #expect(PostgresTLSMode.prefer.attemptsTLS)
        #expect(!PostgresTLSMode.prefer.requiresTLS)
        #expect(!PostgresTLSMode.prefer.isPrivate)
    }

    @Test("only verify-full checks the hostname")
    func verificationLadder() {
        #expect(!PostgresTLSMode.require.verifiesCertificate)
        #expect(PostgresTLSMode.verifyCA.verifiesCertificate)
        #expect(!PostgresTLSMode.verifyCA.verifiesHostname)
        #expect(PostgresTLSMode.verifyFull.verifiesHostname)
    }

    /// A cleartext password needs the link to be private. `require` counts even
    /// though it does not authenticate the server: encryption alone stops the
    /// eavesdropper this protects against.
    @Test("cleartext passwords are allowed only on an encrypted link")
    func privacyGate() {
        #expect(!PostgresTLSMode.disable.isPrivate)
        #expect(!PostgresTLSMode.prefer.isPrivate)
        #expect(PostgresTLSMode.require.isPrivate)
        #expect(PostgresTLSMode.verifyFull.isPrivate)
    }

    @Test("the server's one-byte answer is understood")
    func negotiationByte() {
        #expect(PostgresTLSNegotiation(byte: UInt8(ascii: "S")) == .accepted)
        #expect(PostgresTLSNegotiation(byte: UInt8(ascii: "N")) == .refused)
        #expect(PostgresTLSNegotiation(byte: 0x00) == nil)
    }

    @Test("every mode parses from its libpq spelling")
    func spellings() {
        #expect(PostgresTLSMode(rawValue: "verify-full") == .verifyFull)
        #expect(PostgresTLSMode(rawValue: "verify-ca") == .verifyCA)
        #expect(PostgresTLSMode(rawValue: "prefer") == .prefer)
        #expect(PostgresTLSMode.allCases.count == 5)
    }
}

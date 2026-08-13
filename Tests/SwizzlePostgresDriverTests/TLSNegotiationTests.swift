import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOSSL
import Testing
@testable import SwizzlePostgresDriver

@Suite("Postgres TLS negotiation")
struct TLSNegotiationTests {

    /// A channel with just the negotiation handler, plus a counter so a test can
    /// tell whether a TLS handler was ever built.
    final class Harness {
        let channel = EmbeddedChannel()
        let promise: EventLoopPromise<PostgresTLSNegotiation>
        let handler: PostgresTLSNegotiationHandler
        private let built = NIOLockedValueBox(0)

        var tlsHandlersBuilt: Int { built.withLockedValue { $0 } }

        init(mode: PostgresTLSMode, tlsFails: Bool = false) {
            promise = channel.eventLoop.makePromise(of: PostgresTLSNegotiation.self)
            let counter = built
            handler = PostgresTLSNegotiationHandler(mode: mode, negotiated: promise) {
                counter.withLockedValue { $0 += 1 }
                if tlsFails { throw PostgresTLSError.malformedResponse(0) }
                let context = try NIOSSLContext(configuration: .makeClientConfiguration())
                return try NIOSSLClientHandler(context: context, serverHostname: "example.com")
            }
        }

        func start() throws {
            try channel.pipeline.syncOperations.addHandler(handler)
            try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 5432)).wait()
        }

        /// What the client sent, as raw bytes.
        func readOutbound() throws -> [UInt8]? {
            guard var buffer = try channel.readOutbound(as: ByteBuffer.self) else { return nil }
            return buffer.readBytes(length: buffer.readableBytes)
        }

        func send(_ bytes: [UInt8]) throws {
            try channel.writeInbound(ByteBuffer(bytes: bytes))
        }

        func outcome() throws -> PostgresTLSNegotiation {
            try promise.futureResult.wait()
        }
    }

    // MARK: - The exchange

    /// The `SSLRequest` is untagged and fixed: length 8, then the magic code
    /// 80877103. It goes out in the clear, which is fine — it carries no secrets.
    @Test("connecting sends an SSLRequest and nothing else")
    func sendsSSLRequest() throws {
        let harness = Harness(mode: .require)
        try harness.start()

        let sent = try #require(try harness.readOutbound())
        #expect(sent == [0, 0, 0, 8, 0x04, 0xD2, 0x16, 0x2F])
        #expect(try harness.readOutbound() == nil)
    }

    @Test("an accepting server gets a TLS handler at the head of the pipeline")
    func serverAccepts() throws {
        let harness = Harness(mode: .verifyFull)
        try harness.start()
        _ = try harness.readOutbound()

        try harness.send([UInt8(ascii: "S")])

        #expect(try harness.outcome() == .accepted)
        #expect(harness.tlsHandlersBuilt == 1)
        // And the negotiator is gone: it speaks raw bytes for exactly one
        // exchange, and leaving it in would corrupt the framed stream that
        // follows.
        #expect(throws: (any Error).self) {
            try harness.channel.pipeline.syncOperations.context(handler: harness.handler)
        }
    }

    // MARK: - CVE-2021-23222

    /// **Nothing may follow the one-byte answer.**
    ///
    /// After answering, the server waits — for our ClientHello if it said `S`,
    /// for our StartupMessage if it said `N`. It has nothing to send, so further
    /// bytes did not come from the server's protocol state machine. They were
    /// injected, to be processed as though they had arrived over the TLS session
    /// about to be established.
    @Test("bytes injected behind the accept are refused, not processed")
    func injectionAfterAcceptIsRefused() throws {
        let harness = Harness(mode: .verifyFull)
        try harness.start()
        _ = try harness.readOutbound()

        // 'S', then a plausible-looking ErrorResponse the attacker would like the
        // client to treat as authenticated server output.
        try harness.send([UInt8(ascii: "S")] + Array("Efake".utf8))

        #expect(throws: PostgresTLSError.unexpectedDataAfterNegotiation(5)) {
            try harness.outcome()
        }
        // The TLS session was never even started — the connection is refused
        // before there is anything for the injected bytes to hide inside.
        #expect(harness.tlsHandlersBuilt == 0)
    }

    /// The same rule on the plaintext side: after `N` the server is waiting for a
    /// StartupMessage and has nothing to say.
    @Test("bytes injected behind the refusal are refused too")
    func injectionAfterRefusalIsRefused() throws {
        let harness = Harness(mode: .prefer)
        try harness.start()
        _ = try harness.readOutbound()

        try harness.send([UInt8(ascii: "N"), 0x45, 0x00])

        #expect(throws: PostgresTLSError.unexpectedDataAfterNegotiation(2)) {
            try harness.outcome()
        }
    }

    // MARK: - Refusal

    /// `prefer` exists to carry on regardless, and that is exactly why it is not
    /// this driver's default: an attacker who strips the offer gets a plaintext
    /// session and the client never notices.
    @Test("prefer continues in the clear when the server refuses")
    func preferFallsBack() throws {
        let harness = Harness(mode: .prefer)
        try harness.start()
        _ = try harness.readOutbound()

        try harness.send([UInt8(ascii: "N")])

        #expect(try harness.outcome() == .refused)
        #expect(harness.tlsHandlersBuilt == 0)
        #expect(harness.channel.isActive)
    }

    @Test("every mode that requires TLS refuses to continue without it")
    func requiringModesFail() throws {
        for mode in [PostgresTLSMode.require, .verifyCA, .verifyFull] {
            let harness = Harness(mode: mode)
            try harness.start()
            _ = try harness.readOutbound()
            try harness.send([UInt8(ascii: "N")])

            #expect(throws: PostgresTLSError.serverRefusedTLS(mode: mode)) {
                try harness.outcome()
            }
            #expect(!harness.channel.isActive)
        }
    }

    // MARK: - Malformed and interrupted

    /// The answer is one raw byte with no framing, so a wrong byte has to be
    /// caught here — the frame decoder would read it as a message tag and then
    /// wait forever for a length that is never coming.
    @Test("a byte that is neither S nor N is rejected")
    func malformedAnswer() throws {
        let harness = Harness(mode: .require)
        try harness.start()
        _ = try harness.readOutbound()

        try harness.send([UInt8(ascii: "E")])

        #expect(throws: PostgresTLSError.malformedResponse(UInt8(ascii: "E"))) {
            try harness.outcome()
        }
    }

    @Test("a connection that dies mid-negotiation reports that, not a hang")
    func closedDuringNegotiation() throws {
        let harness = Harness(mode: .require)
        try harness.start()
        _ = try harness.readOutbound()

        _ = try? harness.channel.finish()

        #expect(throws: PostgresTLSError.connectionClosedDuringNegotiation) {
            try harness.outcome()
        }
    }

    /// A failure building the TLS context — a bad CA file, say — must surface as
    /// itself rather than as a stalled connection.
    @Test("a TLS handler that cannot be built fails the connection")
    func tlsConstructionFailure() throws {
        let harness = Harness(mode: .verifyFull, tlsFails: true)
        try harness.start()
        _ = try harness.readOutbound()

        try harness.send([UInt8(ascii: "S")])

        #expect(throws: (any Error).self) { try harness.outcome() }
        #expect(!harness.channel.isActive)
    }
}

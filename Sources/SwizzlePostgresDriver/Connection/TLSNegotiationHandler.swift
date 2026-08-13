import NIOCore
import NIOSSL

/// Performs Postgres's TLS negotiation, then takes itself out of the pipeline.
///
/// ## Why this is a separate handler
///
/// Postgres negotiates TLS *before* message framing begins. The client writes an
/// untagged 8-byte `SSLRequest` and the server answers with **one raw byte** —
/// `S` or `N` — that is not a protocol message and has no length prefix. The
/// frame decoder would read that byte as a message tag and then block forever
/// waiting for a length that is never coming.
///
/// So this sits ahead of the decoder, speaks raw bytes for exactly one exchange,
/// and removes itself. MySQL needs no equivalent: there the SSLRequest is an
/// ordinary packet and the switch happens inside the normal framing.
final class PostgresTLSNegotiationHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let mode: PostgresTLSMode
    private let makeTLSHandler: @Sendable () throws -> NIOSSLClientHandler
    /// Resolved once the outcome is known, so the connection can proceed or fail.
    private let negotiated: EventLoopPromise<PostgresTLSNegotiation>
    private var isResolved = false

    init(
        mode: PostgresTLSMode,
        negotiated: EventLoopPromise<PostgresTLSNegotiation>,
        makeTLSHandler: @escaping @Sendable () throws -> NIOSSLClientHandler
    ) {
        self.mode = mode
        self.negotiated = negotiated
        self.makeTLSHandler = makeTLSHandler
    }

    func channelActive(context: ChannelHandlerContext) {
        // The SSLRequest goes out in the clear, which is fine — it carries no
        // secrets, only the fixed request code.
        var buffer = context.channel.allocator.buffer(capacity: 8)
        PostgresFrontendMessage.sslRequest.encode(into: &buffer)
        // Raw bytes rather than a `PostgresFrontendMessage`: the encoder sits
        // *behind* this handler in the pipeline, so a message written from here
        // would never reach it. Writing the eight bytes directly is also the
        // honest description of what SSLRequest is — a pre-protocol handshake.
        context.writeAndFlush(NIOAny(buffer), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let byte = buffer.readInteger(as: UInt8.self) else { return }

        guard let answer = PostgresTLSNegotiation(byte: byte) else {
            fail(PostgresTLSError.malformedResponse(byte), context: context)
            return
        }

        // ── CVE-2021-23222 ──────────────────────────────────────────────────
        // Nothing may follow that byte.
        //
        // After answering, the server waits: for our ClientHello if it said `S`,
        // for our StartupMessage if it said `N`. It has nothing to send, so any
        // further bytes in this read did not come from the server's protocol
        // state machine — they were injected by whoever sits in the middle, to be
        // processed *as though they had arrived over the TLS session about to be
        // established*.
        //
        // libpq drains and rejects here for exactly this reason. Trusting the
        // buffer is what the CVE was.
        guard buffer.readableBytes == 0 else {
            fail(PostgresTLSError.unexpectedDataAfterNegotiation(buffer.readableBytes),
                 context: context)
            return
        }

        switch answer {
        case .refused:
            guard !mode.requiresTLS else {
                fail(PostgresTLSError.serverRefusedTLS(mode: mode), context: context)
                return
            }
            // `prefer`, carrying on in the clear — which is the whole reason
            // `prefer` is not this driver's default.
            resolve(.refused)
            remove(context: context)

        case .accepted:
            do {
                let handler = try makeTLSHandler()
                // Inserted at the head: from here everything on the wire is
                // ciphertext and must be decrypted before it reaches the framer.
                try context.pipeline.syncOperations.addHandler(handler, position: .first)
            } catch {
                fail(error, context: context)
                return
            }
            resolve(.accepted)
            remove(context: context)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(PostgresTLSError.connectionClosedDuringNegotiation, context: context)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        fail(error, context: context)
    }

    private func remove(context: ChannelHandlerContext) {
        context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
    }

    private func resolve(_ outcome: PostgresTLSNegotiation) {
        guard !isResolved else { return }
        isResolved = true
        negotiated.succeed(outcome)
    }

    private func fail(_ error: any Error, context: ChannelHandlerContext) {
        guard !isResolved else { return }
        isResolved = true
        negotiated.fail(error)
        context.close(promise: nil)
    }
}

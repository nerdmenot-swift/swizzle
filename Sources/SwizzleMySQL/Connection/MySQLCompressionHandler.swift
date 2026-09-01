import NIOCore

/// Shared on/off switch for the two compression handlers.
///
/// The handlers are installed in the pipeline at connect time but stay
/// pass-through until authentication finishes, because the entire handshake —
/// including the final OK packet — travels uncompressed. Flipping a flag is far
/// less delicate than splicing handlers into a live pipeline at exactly the
/// right position, and it makes the TLS ordering fall out for free: TLS is
/// inserted at the head later, which lands it outside compression, which is
/// where it belongs.
///
/// Event-loop confined; every access is on the channel's loop.
public final class MySQLCompressionState: @unchecked Sendable {
    public private(set) var isEnabled = false
    public private(set) var level: Int32 = MySQLCompression.defaultLevel
    /// Which algorithm the peer agreed to. Both use the same 7-byte frame
    /// header; only the payload codec differs.
    public private(set) var usesZstd = false

    public init() {}

    public func enable(level: Int32, zstd: Bool = false) {
        self.isEnabled = true
        self.level = level
        self.usesZstd = zstd
    }
}

/// Inbound half of the compressed protocol: compressed frames → plain bytes.
///
/// The property that matters most here is that compression wraps the **byte
/// stream**, not individual packets. One frame may carry several plain packets,
/// and one plain packet may span several frames. Treating it as a
/// packet-to-packet mapping works for small queries and then fails the first
/// time a result set crosses a frame boundary.
///
/// Emitting `ByteBuffer` rather than `MySQLPacket` is what keeps that honest:
/// this sits directly in front of `MySQLPacketDecoder`, which then frames
/// exactly as it does on an uncompressed connection.
public struct MySQLCompressedFrameDecoder: ByteToMessageDecoder {
    public typealias InboundOut = ByteBuffer

    /// Bound on a single frame's inflated size, mirroring the packet decoder's.
    /// Without it a peer can advertise a 16 MiB inflation per frame and stream
    /// them indefinitely.
    public var maxAllowedPacket: Int
    public let state: MySQLCompressionState

    /// Tracked for diagnostics only.
    ///
    /// Deliberately **not** enforced. The server may send an error packet — most
    /// often 1153, packet bigger than `max_allowed_packet` — before it has read
    /// everything we sent, which legitimately leaves its sequence behind ours.
    /// go-sql-driver documents this and notes that neither libmariadb nor
    /// libmysqlclient checks it either; only the server checks.
    public private(set) var sequenceID: UInt8 = 0

    public init(
        state: MySQLCompressionState,
        maxAllowedPacket: Int = MySQLPacketDecoder.defaultMaxAllowedPacket
    ) {
        self.state = state
        self.maxAllowedPacket = maxAllowedPacket
    }

    public mutating func decode(
        context: ChannelHandlerContext, buffer: inout ByteBuffer
    ) throws -> DecodingState {
        guard state.isEnabled else {
            // Pass-through during the handshake.
            guard buffer.readableBytes > 0 else { return .needMoreData }
            let all = buffer.readSlice(length: buffer.readableBytes)!
            context.fireChannelRead(wrapInboundOut(all))
            return .continue
        }

        let save = buffer.readerIndex

        guard let header = MySQLCompressedPacketHeader.parse(&buffer) else {
            return .needMoreData
        }

        let inflatedSize = header.isStored ? header.compressedLength : header.uncompressedLength
        guard inflatedSize <= maxAllowedPacket else {
            throw MySQLProtocolError.packetTooLarge(
                attempted: inflatedSize, limit: maxAllowedPacket
            )
        }

        let total = MySQLCompressedPacketHeader.byteCount + header.compressedLength
        guard buffer.readableBytes >= total else {
            buffer.moveReaderIndex(to: save)
            return .needMoreData
        }

        buffer.moveReaderIndex(forwardBy: MySQLCompressedPacketHeader.byteCount)
        guard let payload = buffer.readBytes(length: header.compressedLength) else {
            buffer.moveReaderIndex(to: save)
            return .needMoreData
        }

        sequenceID = header.sequenceID &+ 1

        let plain: [UInt8]
        if header.isStored {
            plain = payload
        } else if state.usesZstd {
            plain = try MySQLCompression.decompressZstd(
                payload, expectedCount: header.uncompressedLength
            )
        } else {
            plain = try MySQLCompression.decompress(
                payload, expectedCount: header.uncompressedLength
            )
        }

        var out = context.channel.allocator.buffer(capacity: plain.count)
        out.writeBytes(plain)
        context.fireChannelRead(wrapInboundOut(out))
        return .continue
    }

    public mutating func decodeLast(
        context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool
    ) throws -> DecodingState {
        // A partial frame at EOF is a truncated stream, not a decodable message.
        if state.isEnabled { return .needMoreData }
        return try decode(context: context, buffer: &buffer)
    }
}

/// Outbound half: plain bytes → compressed frames.
///
/// Sits behind the packet encoder, so what arrives is already-framed packet
/// bytes. Those are chunked at the 16 MiB payload limit and each chunk is
/// deflated — or stored verbatim when deflating would not pay for itself.
public final class MySQLCompressedFrameEncoder: ChannelOutboundHandler {
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    private var sequenceID: UInt8 = 0
    private let state: MySQLCompressionState

    public init(state: MySQLCompressionState) {
        self.state = state
    }

    /// The compression sequence after the last frame written.
    public var currentSequence: UInt8 { sequenceID }

    public func write(
        context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?
    ) {
        var input = unwrapOutboundIn(data)
        guard state.isEnabled, input.readableBytes > 0 else {
            context.write(data, promise: promise)
            return
        }

        // Both counters reset together at the start of a command, as MySQL's
        // `net_clear()` does. What arrives here is already-framed packet bytes,
        // so byte 3 is the plain sequence ID — a zero there *is* the
        // start-of-command signal, which avoids plumbing a reset call through
        // from the command handler.
        //
        // We never generate the plain sequence ourselves (replies are numbered
        // from the packet we received), so the `net_flush()` rule that forces
        // `pkt_nr = compress_pkt_nr` has nothing to act on here. That rule is for
        // clients that track the plain sequence independently and would drift
        // once the frame count and packet count diverge.
        if input.getInteger(at: input.readerIndex + 3, as: UInt8.self) == 0 {
            sequenceID = 0
        }

        var out = context.channel.allocator.buffer(capacity: input.readableBytes + 16)

        while input.readableBytes > 0 {
            let chunkSize = min(MySQLPacketFraming.maxPayloadSize, input.readableBytes)
            guard let chunk = input.readBytes(length: chunkSize) else { break }

            var body = chunk
            var uncompressedLength = 0

            if chunk.count >= MySQLCompression.minimumCompressLength {
                // Deflating can *grow* incompressible data. Falling back to
                // stored keeps that from costing bandwidth, and a stored frame
                // is always legal.
                let deflated = state.usesZstd
                    ? try? MySQLCompression.compressZstd(chunk, level: state.level)
                    : try? MySQLCompression.compress(chunk, level: state.level)
                // Strictly-smaller rather than not-larger. The two differ only
                // when deflate returns exactly the input size, which is not
                // practically constructible and puts the same number of bytes
                // on the wire either way — so no test kills a mutation of it.
                if let deflated, deflated.count < chunk.count {
                    body = deflated
                    uncompressedLength = chunk.count
                }
            }

            MySQLCompressedPacketHeader(
                compressedLength: body.count,
                sequenceID: sequenceID,
                uncompressedLength: uncompressedLength
            ).serialize(into: &out)
            out.writeBytes(body)

            sequenceID &+= 1
        }

        context.write(wrapOutboundOut(out), promise: promise)
    }
}

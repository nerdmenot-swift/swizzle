import NIOCore

/// A reassembled protocol packet.
///
/// `payload` is the logical body with split-packet framing already removed, so
/// consumers never see the 16 MiB boundary.
public struct MySQLPacket: Sendable {
    public var sequenceID: UInt8
    public var payload: ByteBuffer

    public init(sequenceID: UInt8, payload: ByteBuffer) {
        self.sequenceID = sequenceID
        self.payload = payload
    }

    /// A packet body is `0xFF` for ERR, `0x00` for OK, `0xFE` for EOF — but the
    /// last two are ambiguous with ordinary row data, so callers must interpret
    /// them in context rather than trusting a first-byte check alone.
    public var firstByte: UInt8? { payload.getInteger(at: payload.readerIndex, as: UInt8.self) }
}

/// Header is 3-byte little-endian payload length + 1-byte sequence ID.
public enum MySQLPacketFraming {
    public static let headerSize = 4
    /// A payload of exactly this length signals that another packet follows and
    /// the two must be concatenated. This is the single easiest thing in the
    /// protocol to get wrong, so it is isolated here and tested directly.
    public static let maxPayloadSize = 0xFF_FFFF
}

/// Reassembles wire bytes into logical packets, joining split payloads.
public struct MySQLPacketDecoder: ByteToMessageDecoder {
    public typealias InboundOut = MySQLPacket

    /// Upper bound on a single reassembled payload.
    ///
    /// Without this a peer can stream unbounded 16 MiB continuation chunks and
    /// we buffer all of them — an OOM with no error. Default matches
    /// rust-mysql-common's `DEFAULT_MAX_ALLOWED_PACKET`; raise it from the
    /// server's reported `max_allowed_packet` once the handshake completes.
    public var maxAllowedPacket: Int

    /// Accumulated payload for a split packet still being reassembled.
    private var pending: ByteBuffer?
    /// Sequence ID of the most recent chunk.
    ///
    /// For a reassembled packet this must be the **last** chunk's ID, not the
    /// first: the peer expects our next packet to continue from where the split
    /// packet ended. Reporting the first chunk's ID desynchronises the sequence
    /// on every payload over 16 MiB.
    private var lastSequenceID: UInt8 = 0

    public static let defaultMaxAllowedPacket = 4 * 1024 * 1024

    public init(maxAllowedPacket: Int = MySQLPacketDecoder.defaultMaxAllowedPacket) {
        self.maxAllowedPacket = maxAllowedPacket
    }

    public mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let save = buffer.readerIndex

        guard buffer.readableBytes >= MySQLPacketFraming.headerSize else {
            return .needMoreData
        }

        // 3-byte little-endian length.
        guard let l0 = buffer.readInteger(endianness: .little, as: UInt8.self),
              let l1 = buffer.readInteger(endianness: .little, as: UInt8.self),
              let l2 = buffer.readInteger(endianness: .little, as: UInt8.self),
              let sequenceID = buffer.readInteger(endianness: .little, as: UInt8.self)
        else {
            buffer.moveReaderIndex(to: save)
            return .needMoreData
        }

        let length = Int(l0) | (Int(l1) << 8) | (Int(l2) << 16)

        let accumulatedSoFar = pending?.readableBytes ?? 0
        guard accumulatedSoFar + length <= maxAllowedPacket else {
            pending = nil
            throw MySQLProtocolError.packetTooLarge(
                attempted: accumulatedSoFar + length, limit: maxAllowedPacket
            )
        }

        guard var chunk = buffer.readSlice(length: length) else {
            buffer.moveReaderIndex(to: save)
            return .needMoreData
        }

        // Always the most recent chunk's ID — see `lastSequenceID`.
        lastSequenceID = sequenceID

        if var accumulated = pending {
            accumulated.writeBuffer(&chunk)
            pending = accumulated
        } else {
            pending = chunk
        }

        // Exactly-max length means the logical payload continues in the next
        // packet. An empty chunk always terminates, which is what makes a
        // payload that is an exact multiple of the max size decodable at all.
        if length == MySQLPacketFraming.maxPayloadSize {
            return .continue
        }

        let payload = pending ?? ByteBuffer()
        pending = nil
        context.fireChannelRead(wrapInboundOut(MySQLPacket(sequenceID: lastSequenceID, payload: payload)))
        return .continue
    }

    public mutating func decodeLast(
        context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool
    ) throws -> DecodingState {
        // A half-reassembled packet at EOF is a truncated response, not a packet.
        if pending != nil {
            pending = nil
            throw MySQLProtocolError.truncatedPacket
        }
        return try decode(context: context, buffer: &buffer)
    }
}

/// Splits oversized payloads back into wire packets.
public struct MySQLPacketEncoder: MessageToByteEncoder {
    public typealias OutboundIn = MySQLPacket

    public init() {}

    public func encode(data: MySQLPacket, out: inout ByteBuffer) throws {
        var payload = data.payload
        var sequenceID = data.sequenceID

        repeat {
            let chunkSize = min(payload.readableBytes, MySQLPacketFraming.maxPayloadSize)
            out.writeInteger(UInt8(chunkSize & 0xFF), endianness: .little)
            out.writeInteger(UInt8((chunkSize >> 8) & 0xFF), endianness: .little)
            out.writeInteger(UInt8((chunkSize >> 16) & 0xFF), endianness: .little)
            out.writeInteger(sequenceID, endianness: .little)

            if var chunk = payload.readSlice(length: chunkSize) {
                out.writeBuffer(&chunk)
            }
            sequenceID &+= 1

            // A payload that is an exact multiple of the max size needs a
            // trailing empty packet, otherwise the peer keeps waiting.
            if chunkSize < MySQLPacketFraming.maxPayloadSize { break }
        } while true
    }
}

public enum MySQLProtocolError: Error, Sendable, Equatable {
    case truncatedPacket
    case packetTooLarge(attempted: Int, limit: Int)
    case malformedPacket(String)
    case unexpectedPacket(String)
    case repeatedAuthSwitch
    case insecureAuthRefused(String)
    case tlsNotSupportedByServer
    case connectionClosed(String)
    case malformedHandshake(String)
    case unsupportedProtocolVersion(UInt8)
    case unsupportedAuthPlugin(String)
    case compressionFailed(String)
    case localInfileRefused(String)
    case server(code: UInt16, sqlState: String, message: String)
}

import NIOCore

/// Turns the byte stream into messages.
///
/// A `ByteToMessageDecoder` rather than a hand-rolled buffer walk, because NIO's
/// version already solves the part that is easy to get subtly wrong: holding a
/// partial message across reads without copying it repeatedly, and re-entering
/// cleanly when the rest arrives.
///
/// The bound is the interesting part. Postgres's framing has no equivalent of
/// MySQL's 16 MiB chunking — one message declares one length and that is all — so
/// a hostile or broken server can declare a four-gigabyte message and watch the
/// client reserve it. The MySQL driver shipped with exactly that hole and it was
/// found in the audit; here it is bounded from the first commit.
public struct PostgresMessageDecoder: ByteToMessageDecoder {
    public typealias InboundOut = PostgresBackendMessage

    /// The largest single message this client will accumulate.
    ///
    /// Generous enough for any real result row — a row containing a 200 MB blob
    /// arrives as one `DataRow` — and far below the four gigabytes the length
    /// field can express. A server needing more than this is either broken or
    /// hostile, and either way the connection should fail rather than swell.
    public var maximumMessageSize: Int

    public static let defaultMaximumMessageSize = 512 * 1024 * 1024

    public init(maximumMessageSize: Int = PostgresMessageDecoder.defaultMaximumMessageSize) {
        self.maximumMessageSize = maximumMessageSize
    }

    public mutating func decode(
        context: ChannelHandlerContext, buffer: inout ByteBuffer
    ) throws -> DecodingState {
        // Peek the length before letting the decoder reserve anything for it.
        if buffer.readableBytes >= 5 {
            let declared: Int32 = buffer.getInteger(at: buffer.readerIndex + 1)!
            guard declared >= 4 else {
                throw PostgresWireError.malformed(
                    "message length \(declared) is below the minimum of 4"
                )
            }
            guard Int(declared) <= maximumMessageSize else {
                throw PostgresWireError.messageTooLarge(
                    declared: Int(declared), maximum: maximumMessageSize
                )
            }
        }

        guard let message = try PostgresBackendMessage.decode(from: &buffer) else {
            return .needMoreData
        }
        context.fireChannelRead(wrapInboundOut(message))
        // `.continue` so several messages in one read are all delivered — a
        // handshake arrives as a burst, and returning `.needMoreData` here would
        // stall until the next packet.
        return .continue
    }

    public mutating func decodeLast(
        context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool
    ) throws -> DecodingState {
        // Anything left at EOF is a truncated message. Reporting it beats silently
        // discarding it, because "the connection closed" and "the connection
        // closed mid-message" are different problems.
        guard buffer.readableBytes > 0 else { return .needMoreData }
        throw PostgresWireError.malformed(
            "connection closed with \(buffer.readableBytes) bytes of an incomplete message"
        )
    }
}

/// Writes frontend messages.
public struct PostgresMessageEncoder: MessageToByteEncoder {
    public typealias OutboundIn = PostgresFrontendMessage

    public init() {}

    public func encode(data: PostgresFrontendMessage, out: inout ByteBuffer) throws {
        data.encode(into: &out)
    }
}

extension PostgresWireError {
    /// A message larger than this client will accumulate.
    public static func messageTooLarge(declared: Int, maximum: Int) -> PostgresWireError {
        .malformed(
            "server declared a \(declared)-byte message, above the \(maximum)-byte limit"
        )
    }
}

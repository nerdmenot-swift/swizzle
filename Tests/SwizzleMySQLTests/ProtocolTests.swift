import NIOCore
import NIOEmbedded
import Testing
@testable import SwizzleMySQL

@Suite("Length-encoded primitives")
struct LengthEncodedTests {

    @Test("integers round-trip across every width boundary", arguments: [
        0, 1, 250,                    // 1-byte form
        251, 252, 0xFFFF,             // 0xFC 2-byte form
        0x1_0000, 0xFF_FFFF,          // 0xFD 3-byte form
        0x100_0000, UInt64.max,       // 0xFE 8-byte form
    ] as [UInt64])
    func integerRoundTrip(value: UInt64) {
        var buffer = ByteBuffer()
        buffer.writeLengthEncodedInteger(value)
        #expect(buffer.readLengthEncodedInteger() == value)
        #expect(buffer.readableBytes == 0)
    }

    /// The width boundaries are exactly where off-by-one errors live.
    @Test func integersUseTheNarrowestEncoding() {
        func width(_ value: UInt64) -> Int {
            var buffer = ByteBuffer()
            buffer.writeLengthEncodedInteger(value)
            return buffer.readableBytes
        }
        #expect(width(250) == 1)
        #expect(width(251) == 3)          // 0xFC + 2
        #expect(width(0xFFFF) == 3)
        #expect(width(0x1_0000) == 4)     // 0xFD + 3
        #expect(width(0xFF_FFFF) == 4)
        #expect(width(0x100_0000) == 9)   // 0xFE + 8
    }

    /// A truncated read must not advance the reader index, so it can be retried
    /// when the rest of the packet arrives.
    @Test func truncatedIntegerLeavesReaderIndexUntouched() {
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt8(0xFD), endianness: .little)
        buffer.writeInteger(UInt8(0x01), endianness: .little)  // 2 of 3 bytes
        let before = buffer.readerIndex
        #expect(buffer.readLengthEncodedInteger() == nil)
        #expect(buffer.readerIndex == before)
    }

    /// 0xFB is NULL, which is distinct from "not enough bytes".
    @Test func nullIsDistinguishableFromTruncation() {
        var nullBuffer = ByteBuffer()
        nullBuffer.writeInteger(UInt8(0xFB), endianness: .little)
        let nullResult = nullBuffer.readLengthEncodedIntegerOrNull()
        #expect(nullResult != nil)          // a value was decoded
        #expect(nullResult! == nil)         // and that value is NULL

        var emptyBuffer = ByteBuffer()
        #expect(emptyBuffer.readLengthEncodedIntegerOrNull() == nil)  // truncated
    }

    @Test func stringsRoundTrip() {
        var buffer = ByteBuffer()
        buffer.writeLengthEncodedString("hello")
        buffer.writeLengthEncodedString("")
        buffer.writeLengthEncodedString("Ünïcødé 🎉")

        #expect(buffer.readLengthEncodedString() == "hello")
        #expect(buffer.readLengthEncodedString() == "")
        #expect(buffer.readLengthEncodedString() == "Ünïcødé 🎉")
        #expect(buffer.readableBytes == 0)
    }

    @Test func nullTerminatedStringsRoundTrip() {
        var buffer = ByteBuffer()
        buffer.writeNullTerminatedString("8.4.0")
        buffer.writeNullTerminatedString("caching_sha2_password")

        #expect(buffer.readNullTerminatedString() == "8.4.0")
        #expect(buffer.readNullTerminatedString() == "caching_sha2_password")
        #expect(buffer.readableBytes == 0)
    }

    /// Without a terminator we must report failure rather than return a short string.
    @Test func unterminatedStringReturnsNil() {
        var buffer = ByteBuffer()
        buffer.writeString("no terminator")
        #expect(buffer.readNullTerminatedString() == nil)
    }
}

@Suite("Packet framing")
struct PacketFramingTests {

    private func decode(
        _ bytes: [UInt8], maxAllowedPacket: Int = 64 * 1024 * 1024
    ) throws -> [MySQLPacket] {
        let channel = EmbeddedChannel(
            handler: ByteToMessageHandler(MySQLPacketDecoder(maxAllowedPacket: maxAllowedPacket))
        )
        var buffer = ByteBuffer()
        buffer.writeBytes(bytes)
        try channel.writeInbound(buffer)

        var packets: [MySQLPacket] = []
        while let packet = try channel.readInbound(as: MySQLPacket.self) {
            packets.append(packet)
        }
        _ = try? channel.finish()
        return packets
    }

    @Test func decodesASinglePacket() throws {
        // length=3, seq=0, payload=[1,2,3]
        let packets = try decode([0x03, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03])
        #expect(packets.count == 1)
        #expect(packets[0].sequenceID == 0)
        #expect(packets[0].payload.getBytes(at: 0, length: 3) == [0x01, 0x02, 0x03])
    }

    @Test func decodesBackToBackPackets() throws {
        let packets = try decode([
            0x01, 0x00, 0x00, 0x00, 0xAA,
            0x02, 0x00, 0x00, 0x01, 0xBB, 0xCC,
        ])
        #expect(packets.count == 2)
        #expect(packets[0].sequenceID == 0)
        #expect(packets[1].sequenceID == 1)
        #expect(packets[1].payload.getBytes(at: 0, length: 2) == [0xBB, 0xCC])
    }

    @Test func emptyPayloadIsAValidPacket() throws {
        let packets = try decode([0x00, 0x00, 0x00, 0x05])
        #expect(packets.count == 1)
        #expect(packets[0].payload.readableBytes == 0)
        #expect(packets[0].sequenceID == 5)
    }

    /// A header split across two reads must not be misparsed.
    @Test func handlesHeaderSplitAcrossReads() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(MySQLPacketDecoder()))
        var first = ByteBuffer()
        first.writeBytes([0x03, 0x00])            // half a header
        try channel.writeInbound(first)
        #expect(try channel.readInbound(as: MySQLPacket.self) == nil)

        var second = ByteBuffer()
        second.writeBytes([0x00, 0x07, 0x01, 0x02, 0x03])
        try channel.writeInbound(second)

        let packet = try channel.readInbound(as: MySQLPacket.self)
        #expect(packet?.sequenceID == 7)
        #expect(packet?.payload.readableBytes == 3)
        _ = try? channel.finish()
    }

    /// The 16 MiB split rule: a payload of exactly 0xFFFFFF means another packet
    /// follows and the two must be joined. This is the single easiest thing in
    /// the protocol to get wrong.
    @Test func reassemblesSplitPayloads() throws {
        let maxSize = MySQLPacketFraming.maxPayloadSize
        var bytes: [UInt8] = [0xFF, 0xFF, 0xFF, 0x00]
        bytes += [UInt8](repeating: 0xAB, count: maxSize)
        bytes += [0x02, 0x00, 0x00, 0x01, 0xCD, 0xEF]

        let packets = try decode(bytes)
        #expect(packets.count == 1)
        #expect(packets[0].payload.readableBytes == maxSize + 2)
        #expect(packets[0].payload.getBytes(at: maxSize, length: 2) == [0xCD, 0xEF])
    }

    /// A payload that is an exact multiple of the max size needs a trailing
    /// empty packet, or the peer waits forever.
    @Test func encoderEmitsTrailingEmptyPacketOnExactMultiple() throws {
        let maxSize = MySQLPacketFraming.maxPayloadSize
        var payload = ByteBuffer()
        payload.writeBytes([UInt8](repeating: 0x5A, count: maxSize))

        var out = ByteBuffer()
        try MySQLPacketEncoder().encode(data: MySQLPacket(sequenceID: 0, payload: payload), out: &out)

        // header + maxSize + a second, empty header
        #expect(out.readableBytes == 4 + maxSize + 4)
        #expect(out.getBytes(at: 4 + maxSize, length: 4) == [0x00, 0x00, 0x00, 0x01])
    }

    /// A reassembled packet must report the **last** chunk's sequence ID. The
    /// peer expects our next packet to continue from where the split one ended,
    /// so reporting the first chunk's ID desynchronises every payload > 16 MiB.
    /// Verified against rust-mysql-common's `ChunkInfo::Last(seq_id)`.
    @Test func reassembledPacketReportsLastChunkSequenceID() throws {
        let maxSize = MySQLPacketFraming.maxPayloadSize
        var bytes: [UInt8] = [0xFF, 0xFF, 0xFF, 0x07]      // first chunk, seq 7
        bytes += [UInt8](repeating: 0xAB, count: maxSize)
        bytes += [0x02, 0x00, 0x00, 0x08, 0xCD, 0xEF]      // final chunk, seq 8

        let packets = try decode(bytes)
        #expect(packets.count == 1)
        #expect(packets[0].sequenceID == 8)
    }

    /// Without a bound, a peer can stream endless 16 MiB continuation chunks and
    /// we buffer all of them — an OOM with no error raised.
    @Test func rejectsPayloadOverMaxAllowedPacket() throws {
        var bytes: [UInt8] = [0x00, 0x00, 0x10, 0x00]      // 0x100000 = 1 MiB
        bytes += [UInt8](repeating: 0x00, count: 0x10_0000)

        #expect(throws: MySQLProtocolError.self) {
            _ = try decode(bytes, maxAllowedPacket: 64 * 1024)
        }
    }

    /// The limit applies to the *accumulated* payload, not each chunk, or a
    /// split packet slips past it one 16 MiB chunk at a time.
    @Test func maxAllowedPacketAppliesToAccumulatedLength() throws {
        let maxSize = MySQLPacketFraming.maxPayloadSize
        var bytes: [UInt8] = [0xFF, 0xFF, 0xFF, 0x00]
        bytes += [UInt8](repeating: 0xAB, count: maxSize)
        bytes += [0xFF, 0xFF, 0xFF, 0x01]
        bytes += [UInt8](repeating: 0xAB, count: maxSize)

        // Each chunk alone is within the limit; together they are not.
        #expect(throws: MySQLProtocolError.self) {
            _ = try decode(bytes, maxAllowedPacket: maxSize + 1024)
        }
    }

    @Test func defaultMaxAllowedPacketMatchesReference() {
        // rust-mysql-common DEFAULT_MAX_ALLOWED_PACKET = 4 * 1024 * 1024
        #expect(MySQLPacketDecoder.defaultMaxAllowedPacket == 4 * 1024 * 1024)
    }

    @Test func encoderRoundTripsThroughDecoder() throws {
        var payload = ByteBuffer()
        payload.writeString("SELECT 1")

        var out = ByteBuffer()
        try MySQLPacketEncoder().encode(data: MySQLPacket(sequenceID: 3, payload: payload), out: &out)

        let packets = try decode(out.getBytes(at: 0, length: out.readableBytes)!)
        #expect(packets.count == 1)
        #expect(packets[0].sequenceID == 3)
        #expect(packets[0].payload.getString(at: 0, length: 8) == "SELECT 1")
    }
}

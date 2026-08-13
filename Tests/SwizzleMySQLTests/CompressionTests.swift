import NIOCore
import NIOEmbedded
import Testing
@testable import SwizzleMySQL

@Suite("Compressed protocol")
struct CompressedProtocolTests {

    // MARK: - Frame header

    @Test func headerRoundTrips() {
        let original = MySQLCompressedPacketHeader(
            compressedLength: 0x1234, sequenceID: 7, uncompressedLength: 0xABCDEF
        )
        var buffer = ByteBuffer()
        original.serialize(into: &buffer)

        #expect(buffer.readableBytes == MySQLCompressedPacketHeader.byteCount)
        let parsed = MySQLCompressedPacketHeader.parse(&buffer)
        #expect(parsed == original)
    }

    /// Both lengths are 3-byte little-endian, so the top of the range is where a
    /// 16-bit read would silently truncate.
    @Test func headerHandlesMaximumLengths() {
        let original = MySQLCompressedPacketHeader(
            compressedLength: 0xFF_FFFF, sequenceID: 255, uncompressedLength: 0xFF_FFFF
        )
        var buffer = ByteBuffer()
        original.serialize(into: &buffer)
        #expect(MySQLCompressedPacketHeader.parse(&buffer) == original)
    }

    @Test func headerParseNeedsSevenBytes() {
        var buffer = ByteBuffer()
        buffer.writeBytes([UInt8](repeating: 0, count: 6))
        #expect(MySQLCompressedPacketHeader.parse(&buffer) == nil)
    }

    /// Zero means "stored", not "empty" — the single easiest thing to misread in
    /// this header.
    @Test func zeroUncompressedLengthMeansStored() {
        let header = MySQLCompressedPacketHeader(
            compressedLength: 100, sequenceID: 0, uncompressedLength: 0
        )
        #expect(header.isStored)
    }

    // MARK: - zlib

    @Test func zlibRoundTrips() throws {
        let original = [UInt8](repeating: 0x41, count: 10_000)
        let deflated = try MySQLCompression.compress(original)
        #expect(deflated.count < original.count)

        let inflated = try MySQLCompression.decompress(deflated, expectedCount: original.count)
        #expect(inflated == original)
    }

    @Test func zlibRoundTripsBinaryData() throws {
        let original = (0..<5000).map { UInt8($0 % 256) }
        let deflated = try MySQLCompression.compress(original)
        let inflated = try MySQLCompression.decompress(deflated, expectedCount: original.count)
        #expect(inflated == original)
    }

    /// A length that disagrees with the header is corruption or an attack, not
    /// something to accommodate by growing a buffer.
    @Test func decompressRejectsAWrongExpectedLength() throws {
        let deflated = try MySQLCompression.compress([UInt8](repeating: 0x42, count: 1000))
        #expect(throws: (any Error).self) {
            _ = try MySQLCompression.decompress(deflated, expectedCount: 999)
        }
    }

    @Test func decompressRejectsGarbage() {
        #expect(throws: (any Error).self) {
            _ = try MySQLCompression.decompress([1, 2, 3, 4, 5], expectedCount: 100)
        }
    }

    // MARK: - Pipeline round trip

    /// Builds the two halves around an `EmbeddedChannel` so a frame written by
    /// the encoder is read back by the decoder — the same pairing the wire uses.
    static func roundTrip(_ payload: [UInt8], enabled: Bool = true) throws -> [UInt8] {
        let state = MySQLCompressionState()
        if enabled { state.enable(level: MySQLCompression.defaultLevel) }

        let writer = EmbeddedChannel()
        try writer.pipeline.syncOperations.addHandler(MySQLCompressedFrameEncoder(state: state))

        var input = ByteBuffer()
        input.writeBytes(payload)
        try writer.writeOutbound(input)

        var wire = ByteBuffer()
        while let framed = try writer.readOutbound(as: ByteBuffer.self) {
            var framed = framed
            wire.writeBuffer(&framed)
        }

        let reader = EmbeddedChannel()
        try reader.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(MySQLCompressedFrameDecoder(state: state))
        )
        try reader.writeInbound(wire)

        var out = [UInt8]()
        while let chunk = try reader.readInbound(as: ByteBuffer.self) {
            out += chunk.getBytes(at: chunk.readerIndex, length: chunk.readableBytes) ?? []
        }
        _ = try? writer.finish()
        _ = try? reader.finish()
        return out
    }

    /// A realistic packet: 4-byte header with sequence 0, then a body.
    static func packet(sequence: UInt8 = 0, body: [UInt8]) -> [UInt8] {
        let length = body.count
        return [
            UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF), UInt8((length >> 16) & 0xFF),
            sequence,
        ] + body
    }

    @Test func compressiblePayloadRoundTripsThroughThePipeline() throws {
        let payload = Self.packet(body: [UInt8](repeating: 0x61, count: 5000))
        #expect(try Self.roundTrip(payload) == payload)
    }

    /// Below the threshold the frame is stored. This is the path every short
    /// query takes, so it matters more than the compressed one.
    @Test func shortPayloadIsStoredButStillRoundTrips() throws {
        let payload = Self.packet(body: Array("SELECT 1".utf8))
        #expect(payload.count < MySQLCompression.minimumCompressLength)
        #expect(try Self.roundTrip(payload) == payload)
    }

    @Test func incompressiblePayloadRoundTrips() throws {
        // A counter pattern deflates poorly enough to exercise the stored
        // fallback without depending on randomness.
        let body = (0..<4000).map { UInt8(($0 &* 2_654_435_761) % 256) }
        let payload = Self.packet(body: body)
        #expect(try Self.roundTrip(payload) == payload)
    }

    @Test func passesThroughUntouchedWhenDisabled() throws {
        let payload = Self.packet(body: [UInt8](repeating: 0x61, count: 5000))
        #expect(try Self.roundTrip(payload, enabled: false) == payload)
    }

    /// A short payload sent under the threshold produces a *stored* frame, which
    /// must be flagged as such in the header.
    @Test func shortPayloadProducesAStoredFrame() throws {
        let state = MySQLCompressionState()
        state.enable(level: MySQLCompression.defaultLevel)

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(MySQLCompressedFrameEncoder(state: state))

        var input = ByteBuffer()
        input.writeBytes(Self.packet(body: Array("SELECT 1".utf8)))
        try channel.writeOutbound(input)

        var framed = try #require(try channel.readOutbound(as: ByteBuffer.self))
        let header = try #require(MySQLCompressedPacketHeader.parse(&framed))
        #expect(header.isStored)
        #expect(header.sequenceID == 0)
        _ = try? channel.finish()
    }

    @Test func longCompressiblePayloadProducesADeflatedFrame() throws {
        let state = MySQLCompressionState()
        state.enable(level: MySQLCompression.defaultLevel)

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(MySQLCompressedFrameEncoder(state: state))

        let body = [UInt8](repeating: 0x61, count: 5000)
        var input = ByteBuffer()
        input.writeBytes(Self.packet(body: body))
        try channel.writeOutbound(input)

        var framed = try #require(try channel.readOutbound(as: ByteBuffer.self))
        let header = try #require(MySQLCompressedPacketHeader.parse(&framed))
        #expect(!header.isStored)
        #expect(header.uncompressedLength == body.count + 4)
        #expect(header.compressedLength < header.uncompressedLength)
        _ = try? channel.finish()
    }

    // MARK: - Stream behaviour

    /// The property the whole design turns on: compression wraps the byte
    /// stream, so a frame arriving in arbitrary fragments must still decode.
    /// Feeding one byte at a time is the harshest version of that.
    @Test func decoderReassemblesFramesSplitAcrossReads() throws {
        let state = MySQLCompressionState()
        state.enable(level: MySQLCompression.defaultLevel)

        let payload = Self.packet(body: [UInt8](repeating: 0x62, count: 3000))

        let writer = EmbeddedChannel()
        try writer.pipeline.syncOperations.addHandler(MySQLCompressedFrameEncoder(state: state))
        var input = ByteBuffer()
        input.writeBytes(payload)
        try writer.writeOutbound(input)
        let framed = try #require(try writer.readOutbound(as: ByteBuffer.self))
        let wireBytes = framed.getBytes(at: framed.readerIndex, length: framed.readableBytes)!
        _ = try? writer.finish()

        let reader = EmbeddedChannel()
        try reader.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(MySQLCompressedFrameDecoder(state: state))
        )
        for byte in wireBytes {
            var one = ByteBuffer()
            one.writeInteger(byte)
            try reader.writeInbound(one)
        }

        var out = [UInt8]()
        while let chunk = try reader.readInbound(as: ByteBuffer.self) {
            out += chunk.getBytes(at: chunk.readerIndex, length: chunk.readableBytes) ?? []
        }
        #expect(out == payload)
        _ = try? reader.finish()
    }

    /// Several frames in a single read must all be surfaced — one compressed
    /// frame does not mean one plain packet.
    @Test func decoderHandlesSeveralFramesInOneRead() throws {
        let state = MySQLCompressionState()
        state.enable(level: MySQLCompression.defaultLevel)

        let writer = EmbeddedChannel()
        try writer.pipeline.syncOperations.addHandler(MySQLCompressedFrameEncoder(state: state))

        var wire = ByteBuffer()
        var expected = [UInt8]()
        for i in 0..<3 {
            let payload = Self.packet(
                sequence: UInt8(i), body: [UInt8](repeating: UInt8(0x41 + i), count: 2000)
            )
            expected += payload
            var input = ByteBuffer()
            input.writeBytes(payload)
            try writer.writeOutbound(input)
            while var framed = try writer.readOutbound(as: ByteBuffer.self) {
                wire.writeBuffer(&framed)
            }
        }
        _ = try? writer.finish()

        let reader = EmbeddedChannel()
        try reader.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(MySQLCompressedFrameDecoder(state: state))
        )
        try reader.writeInbound(wire)

        var out = [UInt8]()
        while let chunk = try reader.readInbound(as: ByteBuffer.self) {
            out += chunk.getBytes(at: chunk.readerIndex, length: chunk.readableBytes) ?? []
        }
        #expect(out == expected)
        _ = try? reader.finish()
    }

    /// The compression counter restarts with each command, keyed off a plain
    /// packet sequence of zero. Without this the server rejects a frame once the
    /// counters diverge.
    @Test func sequenceResetsAtTheStartOfEachCommand() throws {
        let state = MySQLCompressionState()
        state.enable(level: MySQLCompression.defaultLevel)

        let encoder = MySQLCompressedFrameEncoder(state: state)
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(encoder)

        func send(sequence: UInt8) throws -> UInt8 {
            var input = ByteBuffer()
            input.writeBytes(Self.packet(sequence: sequence, body: Array("SELECT 1".utf8)))
            try channel.writeOutbound(input)
            var framed = try #require(try channel.readOutbound(as: ByteBuffer.self))
            return try #require(MySQLCompressedPacketHeader.parse(&framed)).sequenceID
        }

        #expect(try send(sequence: 0) == 0)
        #expect(try send(sequence: 1) == 1)   // same command, counter advances
        #expect(try send(sequence: 0) == 0)   // new command, counter restarts
        _ = try? channel.finish()
    }

    /// A frame claiming to inflate beyond the limit must be refused before the
    /// allocation, not after.
    @Test func decoderRejectsAnOversizedFrame() throws {
        let state = MySQLCompressionState()
        state.enable(level: MySQLCompression.defaultLevel)

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(
                MySQLCompressedFrameDecoder(state: state, maxAllowedPacket: 1024)
            )
        )

        var wire = ByteBuffer()
        MySQLCompressedPacketHeader(
            compressedLength: 10, sequenceID: 0, uncompressedLength: 1_000_000
        ).serialize(into: &wire)
        wire.writeBytes([UInt8](repeating: 0, count: 10))

        #expect(throws: (any Error).self) {
            try channel.writeInbound(wire)
        }
        _ = try? channel.finish()
    }
}

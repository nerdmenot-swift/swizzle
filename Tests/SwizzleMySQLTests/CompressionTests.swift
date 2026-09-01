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

    // MARK: - The size the frame claims

    /// A compressed frame states its inflated size in its own header, and that
    /// number sizes the destination buffer. It is therefore **the peer choosing
    /// an allocation** — the classic decompression-bomb shape, where a few
    /// kilobytes on the wire ask for a gigabyte of memory.
    ///
    /// The limit is `max_allowed_packet`, which is what the server itself would
    /// enforce in the other direction. Nothing tested it, so the mutation sweep
    /// left the comparison alive.
    @Test("a frame claiming more than max_allowed_packet is refused before inflating")
    func oversizedClaimIsRefused() throws {
        let state = MySQLCompressionState()
        state.enable(level: MySQLCompression.defaultLevel)

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(MySQLCompressedFrameDecoder(state: state, maxAllowedPacket: 1024))
        )

        // A tiny frame that claims to inflate to 16 MiB.
        var wire = ByteBuffer()
        wire.writeInteger(UInt16(8), endianness: .little)      // compressed length, low
        wire.writeInteger(UInt8(0))                            // compressed length, high
        wire.writeInteger(UInt8(0))                            // sequence
        wire.writeInteger(UInt16(0xFFFF), endianness: .little) // uncompressed, low
        wire.writeInteger(UInt8(0xFF))                         // uncompressed, high
        wire.writeBytes([UInt8](repeating: 0, count: 8))

        #expect(throws: MySQLProtocolError.self) {
            try channel.writeInbound(wire)
        }
        _ = try? channel.finish()
    }

    /// The same guard applies to a **stored** frame, where the compressed
    /// length is the inflated length — a different field, so a check written
    /// against only one of them would miss it.
    @Test("an oversized stored frame is refused too")
    func oversizedStoredFrameIsRefused() throws {
        let state = MySQLCompressionState()
        state.enable(level: MySQLCompression.defaultLevel)

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(MySQLCompressedFrameDecoder(state: state, maxAllowedPacket: 1024))
        )

        var wire = ByteBuffer()
        wire.writeInteger(UInt16(0xFFFF), endianness: .little)
        wire.writeInteger(UInt8(0xFF))                         // compressed length: 16 MiB
        wire.writeInteger(UInt8(0))
        wire.writeInteger(UInt16(0), endianness: .little)      // uncompressed 0: stored
        wire.writeInteger(UInt8(0))

        #expect(throws: MySQLProtocolError.self) {
            try channel.writeInbound(wire)
        }
        _ = try? channel.finish()
    }

    /// A frame exactly at the limit is allowed, so the guard is a limit and not
    /// an off-by-one that rejects the largest legal packet.
    @Test("a frame exactly at max_allowed_packet is allowed through")
    func frameAtTheLimitIsAllowed() throws {
        let payload = [UInt8](repeating: 0x41, count: 512)
        let state = MySQLCompressionState()
        state.enable(level: MySQLCompression.defaultLevel)

        let writer = EmbeddedChannel()
        try writer.pipeline.syncOperations.addHandler(MySQLCompressedFrameEncoder(state: state))
        var input = ByteBuffer()
        input.writeBytes(payload)
        try writer.writeOutbound(input)
        var wire = ByteBuffer()
        while var framed = try writer.readOutbound(as: ByteBuffer.self) {
            wire.writeBuffer(&framed)
        }

        let reader = EmbeddedChannel()
        try reader.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(
                MySQLCompressedFrameDecoder(state: state, maxAllowedPacket: payload.count)
            )
        )
        try reader.writeInbound(wire)
        var out = [UInt8]()
        while let chunk = try reader.readInbound(as: ByteBuffer.self) {
            out += chunk.getBytes(at: chunk.readerIndex, length: chunk.readableBytes) ?? []
        }
        #expect(out == payload, "a packet of exactly the limit is legal")
        _ = try? writer.finish()
        _ = try? reader.finish()
    }

    // MARK: - Stored versus deflated

    /// Below `minimumCompressLength` a payload is stored verbatim, because
    /// deflating it costs CPU and usually bytes. At and above it, deflation is
    /// attempted — and *still* falls back to stored if the result is not
    /// smaller, since deflate can grow incompressible data.
    ///
    /// Both decisions are boundaries and both were unexercised at the turnover.
    @Test("the stored/deflated decision turns over at the minimum length")
    func storedDecisionBoundary() throws {
        func isStored(_ count: Int) throws -> Bool {
            let state = MySQLCompressionState()
            state.enable(level: MySQLCompression.defaultLevel)
            let channel = EmbeddedChannel()
            try channel.pipeline.syncOperations.addHandler(
                MySQLCompressedFrameEncoder(state: state)
            )
            var input = ByteBuffer()
            // Highly compressible, so the only reason to store it is the length.
            input.writeBytes([UInt8](repeating: 0x41, count: count))
            try channel.writeOutbound(input)
            var framed = try #require(try channel.readOutbound(as: ByteBuffer.self))
            let header = try #require(MySQLCompressedPacketHeader.parse(&framed))
            _ = try? channel.finish()
            return header.isStored
        }

        let minimum = MySQLCompression.minimumCompressLength
        #expect(try isStored(minimum - 1), "one byte below the minimum is stored")
        #expect(try !isStored(minimum), "at the minimum, deflation is attempted")
        #expect(try !isStored(minimum + 1))
    }

    /// Incompressible data at or above the minimum still comes out stored,
    /// because deflating it produced something no smaller. That is the second
    /// decision, and it is the one that keeps compression from costing
    /// bandwidth on binary columns.
    @Test("incompressible data falls back to a stored frame")
    func incompressibleFallsBackToStored() throws {
        let state = MySQLCompressionState()
        state.enable(level: MySQLCompression.defaultLevel)
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(MySQLCompressedFrameEncoder(state: state))

        // Deterministic but incompressible: a counter through a multiplier.
        var value: UInt64 = 0x9E3779B97F4A7C15
        let noise = (0..<4096).map { _ -> UInt8 in
            value = value &* 6_364_136_223_846_793_005 &+ 1
            return UInt8(truncatingIfNeeded: value >> 33)
        }
        var input = ByteBuffer()
        input.writeBytes(noise)
        try channel.writeOutbound(input)
        var framed = try #require(try channel.readOutbound(as: ByteBuffer.self))
        let header = try #require(MySQLCompressedPacketHeader.parse(&framed))
        #expect(header.isStored, "deflate grew it, so the frame is stored")
        _ = try? channel.finish()
    }

    // MARK: - zstd

    /// The zstd path had no coverage at all — every test above exercises zlib,
    /// which is a different library reached through a different branch.
    @Test("zstd round-trips through the pipeline")
    func zstdRoundTrips() throws {
        let payload = Array("SELECT * FROM users WHERE id = 1".utf8) + [UInt8](repeating: 0x20, count: 512)
        let deflated = try MySQLCompression.compressZstd(payload, level: 3)
        #expect(deflated.count < payload.count, "this payload should compress")
        let inflated = try MySQLCompression.decompressZstd(deflated, expectedCount: payload.count)
        #expect(inflated == payload)
    }

    /// A zstd frame records its own content size, so it can be checked against
    /// the packet header rather than trusted. A frame that disagrees with its
    /// envelope is corrupt or hostile — and sizing the buffer from the envelope
    /// alone is exactly how a small claim inflates into a large write.
    @Test("a zstd frame disagreeing with the packet header is refused")
    func zstdFrameSizeMustMatchTheHeader() throws {
        let payload = [UInt8](repeating: 0x41, count: 1024)
        let deflated = try MySQLCompression.compressZstd(payload, level: 3)
        #expect(throws: MySQLProtocolError.self, "the frame says 1024, the header says 64") {
            _ = try MySQLCompression.decompressZstd(deflated, expectedCount: 64)
        }
        #expect(throws: MySQLProtocolError.self) {
            _ = try MySQLCompression.decompressZstd(deflated, expectedCount: 4096)
        }
    }

    @Test("zstd garbage is refused rather than inflated")
    func zstdGarbage() {
        #expect(throws: MySQLProtocolError.self) {
            _ = try MySQLCompression.decompressZstd([1, 2, 3, 4, 5, 6, 7, 8], expectedCount: 100)
        }
    }

    /// An expected count of zero means a stored frame, which both decoders
    /// short-circuit rather than handing an empty buffer to the library.
    @Test("an expected count of zero yields nothing, for both algorithms")
    func zeroExpectedCount() throws {
        #expect(try MySQLCompression.decompress([1, 2, 3], expectedCount: 0).isEmpty)
        #expect(try MySQLCompression.decompressZstd([1, 2, 3], expectedCount: 0).isEmpty)
        // And with a *valid* frame, which is the case that distinguishes
        // "nothing to inflate" from "inflate and check the size": the frame
        // records 1024 bytes, and a zero expectation must short-circuit rather
        // than reject it for disagreeing.
        let frame = try MySQLCompression.compressZstd(
            [UInt8](repeating: 0x41, count: 1024), level: 3
        )
        #expect(try MySQLCompression.decompressZstd(frame, expectedCount: 0).isEmpty)
    }

    /// And compressing nothing produces nothing rather than a minimal frame.
    @Test("compressing an empty payload produces nothing")
    func emptyInput() throws {
        #expect(try MySQLCompression.compressZstd([], level: 3).isEmpty)
    }

    /// Random bytes into both decompressors, seeded. A corrupt frame must
    /// produce an error rather than a trap or an over-long write.
    @Test("no random frame traps either decompressor", arguments: [UInt64](1...8))
    func randomFramesAreSafe(seed: UInt64) {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1
        func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        for _ in 0..<120 {
            let count = Int(next() % 64)
            let bytes = (0..<count).map { _ in UInt8(next() % 256) }
            let expected = Int(next() % 4096)
            _ = try? MySQLCompression.decompress(bytes, expectedCount: expected)
            _ = try? MySQLCompression.decompressZstd(bytes, expectedCount: expected)
        }
    }
}

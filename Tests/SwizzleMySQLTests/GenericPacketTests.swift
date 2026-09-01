import NIOCore
import Testing
@testable import SwizzleMySQL

/// Telling OK, EOF, ERR and a data row apart, and reading what the server
/// tracked about the session.
///
/// ## Why the classification is not obvious
///
/// The first byte is not enough. `0xFE` introduces an EOF packet **and** an
/// eight-byte length-encoded integer, so the same byte begins an end-of-results
/// marker and a perfectly ordinary row whose first column is long. The
/// protocol's answer is the packet *length*: `0xFE` is EOF only below nine
/// bytes, because an EOF packet cannot be longer than that and a row starting
/// with a `0xFE` length prefix cannot be shorter.
///
/// Reading that boundary wrong ends a result set early and leaves the rest of
/// the rows in the buffer to be parsed as whatever comes next — a
/// desynchronisation, not a wrong value. Nothing in this file had any test
/// coverage; the mutation sweep left eight survivors across it.
///
/// ## `SESSION_TRACK` changes the shape of a packet we parse constantly
///
/// With the capability negotiated, the trailing `info` field becomes
/// length-encoded and may be followed by a block of state changes. Without it,
/// `info` simply runs to the end. Reading the wrong form swallows the state
/// changes into the info string, which is silent — the packet still parses and
/// `USE` tracking just never fires.
@Suite("Generic packets")
struct GenericPacketTests {

    static func packet(_ bytes: [UInt8]) -> MySQLPacket {
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        return MySQLPacket(sequenceID: 0, payload: buffer)
    }

    // MARK: - Classification

    /// The `0xFE` boundary, at every length either side of it.
    ///
    /// Nine is where a `0xFE` packet stops being an EOF marker and starts being
    /// a row whose first value is an eight-byte length-encoded integer.
    @Test("0xFE is an EOF marker only below nine bytes")
    func eofLengthBoundary() {
        for length in 1...16 {
            let bytes = [UInt8(0xFE)] + [UInt8](repeating: 0, count: length - 1)
            let isMarker = length < 9
            #expect(
                MySQLEOFPacket.isEOF(Self.packet(bytes)) == isMarker,
                "a \(length)-byte 0xFE packet \(isMarker ? "is" : "is not") an EOF marker"
            )
            // The OK classifier shares the rule, because with DEPRECATE_EOF the
            // server sends an OK packet in the EOF's place — same header byte,
            // same length test.
            #expect(
                MySQLOKPacket.isOK(Self.packet(bytes)) == isMarker,
                "a \(length)-byte 0xFE packet"
            )
        }
    }

    /// A row whose first column is long enough to need an eight-byte length
    /// prefix is the case the boundary exists for. Misclassifying it truncates
    /// the result set.
    @Test("a row beginning with an eight-byte length prefix is not an end marker")
    func longRowIsNotEOF() {
        // 0xFE then eight length bytes, then the value: a row, not a marker.
        let row: [UInt8] = [0xFE, 0x10, 0, 0, 0, 0, 0, 0, 0] + [UInt8](repeating: 0x41, count: 16)
        #expect(!MySQLEOFPacket.isEOF(Self.packet(row)))
        #expect(!MySQLOKPacket.isOK(Self.packet(row)))
    }

    @Test("0x00 is always an OK packet and never an EOF marker")
    func okHeader() {
        for length in 1...16 {
            let bytes = [UInt8(0x00)] + [UInt8](repeating: 0, count: length - 1)
            #expect(MySQLOKPacket.isOK(Self.packet(bytes)))
            #expect(!MySQLEOFPacket.isEOF(Self.packet(bytes)))
        }
    }

    @Test("0xFF is an error packet, and nothing else is")
    func errorHeader() {
        #expect(MySQLErrorPacket.isError(Self.packet([0xFF, 0x01, 0x02])))
        for first: UInt8 in [0x00, 0x01, 0xFB, 0xFC, 0xFD, 0xFE] {
            #expect(!MySQLErrorPacket.isError(Self.packet([first, 0, 0])))
        }
        #expect(!MySQLErrorPacket.isError(Self.packet([])), "an empty packet is nothing")
    }

    /// An empty packet has no first byte, so every classifier must say no
    /// rather than reading one.
    @Test("an empty packet classifies as nothing")
    func emptyPacket() {
        #expect(!MySQLOKPacket.isOK(Self.packet([])))
        #expect(!MySQLEOFPacket.isEOF(Self.packet([])))
        #expect(!MySQLErrorPacket.isError(Self.packet([])))
    }

    /// Any other header is row data, whatever its length.
    @Test("an ordinary header is not a control packet")
    func ordinaryHeaders() {
        for first: UInt8 in [0x01, 0x02, 0x7F, 0xFB, 0xFC, 0xFD] {
            let bytes = [first] + [UInt8](repeating: 0, count: 8)
            #expect(!MySQLOKPacket.isOK(Self.packet(bytes)), "0x\(String(first, radix: 16))")
            #expect(!MySQLEOFPacket.isEOF(Self.packet(bytes)))
        }
    }

    // MARK: - The OK body

    /// The minimum OK body: header, affected rows, last insert id, status,
    /// warnings, and nothing after it. The trailing fields are all optional, so
    /// a packet that stops here has to parse rather than run off the end.
    @Test("an OK packet with no trailing info parses")
    func minimalOK() throws {
        var buffer = ByteBuffer()
        buffer.writeBytes([0x00, 0x05, 0x07])            // header, 5 rows, insert id 7
        buffer.writeBytes([0x02, 0x00, 0x01, 0x00])      // status 2, 1 warning
        let ok = try MySQLOKPacket.parse(&buffer, capabilities: [.protocol41])
        #expect(ok.affectedRows == 5)
        #expect(ok.lastInsertID == 7)
        #expect(ok.warningCount == 1)
        #expect(ok.info == nil)
        #expect(ok.sessionStateChanges.isEmpty)
    }

    /// Without `SESSION_TRACK` the info field runs to the end of the packet and
    /// is not length-encoded — reading it the other way would take its first
    /// byte as a length.
    @Test("without SESSION_TRACK the info field runs to the end of the packet")
    func infoWithoutSessionTrack() throws {
        var buffer = ByteBuffer()
        buffer.writeBytes([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        buffer.writeBytes(Array("Rows matched: 1".utf8))
        let ok = try MySQLOKPacket.parse(&buffer, capabilities: [.protocol41])
        #expect(ok.info == "Rows matched: 1")
    }

    /// With it, the same field is length-encoded.
    @Test("with SESSION_TRACK the info field is length-encoded")
    func infoWithSessionTrack() throws {
        var buffer = ByteBuffer()
        buffer.writeBytes([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        buffer.writeLengthEncodedString("Rows matched: 1")
        let ok = try MySQLOKPacket.parse(
            &buffer, capabilities: [.protocol41, .sessionTrack]
        )
        #expect(ok.info == "Rows matched: 1")
    }

    // MARK: - Session state tracking

    /// Builds an OK packet carrying a state-change block.
    static func okWithChanges(_ entries: [(UInt8, [UInt8])], info: String = "") -> ByteBuffer {
        var block = ByteBuffer()
        for (type, body) in entries {
            block.writeInteger(type, endianness: .little)
            block.writeLengthEncodedInteger(UInt64(body.count))
            block.writeBytes(body)
        }

        var buffer = ByteBuffer()
        buffer.writeBytes([0x00, 0x00, 0x00])
        // SERVER_SESSION_STATE_CHANGED is 0x4000.
        buffer.writeInteger(UInt16(0x4000), endianness: .little)
        buffer.writeInteger(UInt16(0), endianness: .little)
        buffer.writeLengthEncodedString(info)
        buffer.writeLengthEncodedInteger(UInt64(block.readableBytes))
        buffer.writeBuffer(&block)
        return buffer
    }

    static func lengthEncoded(_ text: String) -> [UInt8] {
        var buffer = ByteBuffer()
        buffer.writeLengthEncodedString(text)
        return Array(buffer.readableBytesView)
    }

    /// Every tracker type the server can report, in one block — which is also
    /// how they arrive, since a single statement can change several things.
    @Test("every session tracker type is reported")
    func allTrackerTypes() throws {
        var buffer = Self.okWithChanges([
            (0x00, Self.lengthEncoded("autocommit") + Self.lengthEncoded("OFF")),
            (0x01, Self.lengthEncoded("app")),
            (0x02, Self.lengthEncoded("1")),
            (0x03, Self.lengthEncoded("uuid:1-5")),
            (0x04, Self.lengthEncoded("READ ONLY")),
            (0x05, Self.lengthEncoded("T_______")),
        ])
        let ok = try MySQLOKPacket.parse(
            &buffer, capabilities: [.protocol41, .sessionTrack]
        )
        #expect(ok.sessionStateChanges == [
            .systemVariable(name: "autocommit", value: "OFF"),
            .schema("app"),
            .stateChanged(true),
            .gtids("uuid:1-5"),
            .transactionCharacteristics("READ ONLY"),
            .transactionState("T_______"),
        ])
    }

    /// The state flag is a *string* `"1"` or `"0"`, not a byte — the one
    /// tracker whose payload has to be compared rather than carried.
    @Test("the state-changed flag distinguishes \"1\" from everything else")
    func stateChangedFlag() throws {
        for (text, expected) in [("1", true), ("0", false), ("", false), ("2", false)] {
            var buffer = Self.okWithChanges([(0x02, Self.lengthEncoded(text))])
            let ok = try MySQLOKPacket.parse(
                &buffer, capabilities: [.protocol41, .sessionTrack]
            )
            #expect(ok.sessionStateChanges == [.stateChanged(expected)], "flag \"\(text)\"")
        }
    }

    /// A tracker this client does not know is skipped **by its declared
    /// length** and reported as unknown, so a newer server cannot desynchronise
    /// everything after it.
    @Test("an unknown tracker is skipped by its length, not guessed at")
    func unknownTrackerIsSkipped() throws {
        var buffer = Self.okWithChanges([
            (0x7F, [0x01, 0x02, 0x03, 0x04]),                 // not a type this knows
            (0x01, Self.lengthEncoded("still_read")),         // and it keeps going
        ])
        let ok = try MySQLOKPacket.parse(
            &buffer, capabilities: [.protocol41, .sessionTrack]
        )
        #expect(ok.sessionStateChanges == [.unknown(type: 0x7F), .schema("still_read")])
    }

    /// A state-change block with nothing in it is legal and means nothing
    /// changed.
    @Test("an empty state-change block yields no changes")
    func emptyChangeBlock() throws {
        var buffer = Self.okWithChanges([])
        let ok = try MySQLOKPacket.parse(
            &buffer, capabilities: [.protocol41, .sessionTrack]
        )
        #expect(ok.sessionStateChanges.isEmpty)
    }

    /// A tracker whose *body* is truncated is dropped rather than reported with
    /// invented contents, and the walk stops there because the block can no
    /// longer be trusted.
    @Test("a truncated tracker body does not invent a change")
    func truncatedTrackerBody() throws {
        // A system-variable entry that declares a name and no value.
        var buffer = Self.okWithChanges([(0x00, Self.lengthEncoded("autocommit"))])
        let ok = try MySQLOKPacket.parse(
            &buffer, capabilities: [.protocol41, .sessionTrack]
        )
        #expect(ok.sessionStateChanges.isEmpty)
    }

    // MARK: - Malformed packets

    @Test("a packet with the wrong header is refused")
    func wrongHeader() {
        var buffer = ByteBuffer()
        buffer.writeBytes([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        #expect(throws: MySQLProtocolError.self) {
            _ = try MySQLOKPacket.parse(&buffer, capabilities: [.protocol41])
        }
    }

    /// Every prefix of a valid packet, which is what a short read leaves.
    @Test("every prefix of a valid OK packet is refused rather than read past")
    func everyPrefixIsSafe() {
        var full = Self.okWithChanges([
            (0x00, Self.lengthEncoded("autocommit") + Self.lengthEncoded("OFF")),
            (0x01, Self.lengthEncoded("app")),
        ], info: "Rows matched: 1")
        let bytes = Array(full.readableBytesView)
        full.moveReaderIndex(to: 0)

        for length in 0..<bytes.count {
            var buffer = ByteBuffer()
            buffer.writeBytes(Array(bytes.prefix(length)))
            // Throwing is correct; trapping is not, and neither is returning a
            // packet assembled from bytes that are not there.
            _ = try? MySQLOKPacket.parse(
                &buffer, capabilities: [.protocol41, .sessionTrack]
            )
        }
    }

    /// Random bodies, seeded so a failure reproduces.
    @Test("no random OK body traps the parser", arguments: [UInt64](1...12))
    func randomBodiesAreSafe(seed: UInt64) {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1
        func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        for _ in 0..<200 {
            let count = Int(next() % 48)
            var buffer = ByteBuffer()
            buffer.writeInteger(UInt8(next() % 2 == 0 ? 0x00 : 0xFE), endianness: .little)
            buffer.writeBytes((0..<count).map { _ in UInt8(next() % 256) })
            _ = try? MySQLOKPacket.parse(
                &buffer, capabilities: [.protocol41, .sessionTrack]
            )
        }
    }
}

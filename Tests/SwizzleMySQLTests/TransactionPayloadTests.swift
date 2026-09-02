import NIOCore
import Testing
@testable import SwizzleMySQL

/// Splitting a `TRANSACTION_PAYLOAD_EVENT` back into the events inside it, and
/// the position tracking that decides where a stream resumes.
///
/// ## Why the splitting has to be defensive
///
/// MySQL 8 wraps whole transactions in one compressed event, so the events a
/// consumer actually cares about arrive **inside** another event's payload,
/// concatenated with nothing between them but each one's own header. Where the
/// next begins is read from the current one's declared size.
///
/// That size is a peer's number. Too small and the walk reads a header out of
/// the middle of the previous event; too large and it runs past the buffer. The
/// loop therefore checks three things — enough bytes left for a header, a size
/// at least as large as a header, and a size within what remains — and none of
/// them was reached by any test, because a real server's payload satisfies all
/// three on every iteration.
///
/// Stopping is the right answer rather than throwing: the container's checksum
/// already passed, so a malformed interior is a bug in this parser or a
/// truncation, and the events already read are still good.
@Suite("Binlog transaction payloads")
struct TransactionPayloadTests {

    // MARK: - Building

    static func event(
        type: MySQLBinlogEventType, body: [UInt8], logPosition: UInt32 = 100
    ) -> [UInt8] {
        var out: [UInt8] = []
        func le32(_ value: UInt32) { for i in 0..<4 { out.append(UInt8((value >> (8 * i)) & 0xFF)) } }
        le32(1_700_000_000)                                    // timestamp
        out.append(type.rawValue)
        le32(1)                                                // server id
        le32(UInt32(MySQLBinlogEventHeader.byteCount + body.count))
        le32(logPosition)
        out += [0x00, 0x00]                                    // flags
        out += body
        return out
    }

    /// An XID event, which decodes from eight bytes and needs no table map.
    static func xid(_ value: UInt64, logPosition: UInt32 = 100) -> [UInt8] {
        event(
            type: .xid,
            body: (0..<8).map { UInt8((value >> (8 * $0)) & 0xFF) },
            logPosition: logPosition
        )
    }

    /// Wraps bytes in an uncompressed transaction payload.
    ///
    /// The header is a TLV run: field 2 is the algorithm, and 255 means the
    /// payload is stored rather than compressed. Field 0 ends the header.
    static func payload(_ inner: [UInt8]) -> ByteBuffer {
        // The algorithm field is omitted: absent means uncompressed, which is
        // what the parser defaults to. Writing it would mean encoding 255 as a
        // length-encoded integer, and 0xFF is not a valid lenenc prefix — the
        // first attempt at this did exactly that, the header parse bailed, and
        // every event came back off by one byte.
        var body: [UInt8] = []
        body += [0x00]                                         // end of header
        body += inner

        var buffer = ByteBuffer()
        buffer.writeBytes(Self.event(type: .transactionPayload, body: body))
        return buffer
    }

    static func decoder() -> MySQLBinlogEventDecoder { MySQLBinlogEventDecoder() }

    // MARK: - Splitting

    @Test("every event inside a payload is decoded")
    func splitsSeveralEvents() throws {
        var decoder = Self.decoder()
        let events = try decoder.decode(
            intoEvents: Self.payload(Self.xid(1) + Self.xid(2) + Self.xid(3))
        )
        #expect(events.count == 3)
        #expect(events.compactMap { if case .xid(let v) = $0.payload { v } else { nil } } == [1, 2, 3] as [UInt64])
    }

    /// A payload holding exactly one event, whose bytes are exactly a header
    /// plus its body — the boundary the outer `while` tests.
    @Test("a payload holding a single event is decoded")
    func singleEvent() throws {
        var decoder = Self.decoder()
        let events = try decoder.decode(intoEvents: Self.payload(Self.xid(7)))
        #expect(events.count == 1)
        guard case .xid(let value) = events.first?.payload else {
            Issue.record("expected an XID"); return
        }
        #expect(value == 7)
    }

    /// Trailing bytes too few to be a header end the walk rather than being
    /// read as one. Every length below a full header, so the boundary is
    /// covered from both sides.
    @Test("a trailing fragment shorter than a header is not read as one")
    func trailingFragment() throws {
        for extra in 0..<MySQLBinlogEventHeader.byteCount {
            var decoder = Self.decoder()
            let events = try decoder.decode(
                intoEvents: Self.payload(
                    Self.xid(1) + [UInt8](repeating: 0xAB, count: extra)
                )
            )
            #expect(events.count == 1, "\(extra) trailing bytes")
        }
    }

    /// An event declaring a size **smaller than a header** cannot be walked
    /// past — advancing by it would read the next header from inside this one,
    /// and advancing by zero would not terminate at all.
    @Test("an event smaller than its own header stops the walk")
    func undersizedEventStops() throws {
        for claimed in [UInt32(0), 1, 18] {
            var bad = Self.xid(1)
            for i in 0..<4 { bad[9 + i] = UInt8((claimed >> (8 * i)) & 0xFF) }

            var decoder = Self.decoder()
            let events = try decoder.decode(intoEvents: Self.payload(Self.xid(5) + bad))
            #expect(events.count == 1, "size \(claimed): the good event survives, the bad one stops it")
        }
    }

    /// An event exactly the size of a header is legal — a body-less event — so
    /// the bound is inclusive.
    @Test("an event exactly the size of a header is accepted")
    func headerSizedEventIsAccepted() throws {
        var decoder = Self.decoder()
        // A heartbeat with no body: the header alone.
        let events = try decoder.decode(intoEvents: Self.payload(Self.event(type: .heartbeat, body: [])))
        #expect(events.count == 1, "19 bytes is a whole event, not a fragment")
    }

    /// An event declaring more bytes than remain stops the walk rather than
    /// reading past the buffer.
    @Test("an event larger than the remaining bytes stops the walk")
    func oversizedEventStops() throws {
        var bad = Self.xid(1)
        let huge = UInt32(100_000)
        for i in 0..<4 { bad[9 + i] = UInt8((huge >> (8 * i)) & 0xFF) }

        var decoder = Self.decoder()
        let events = try decoder.decode(intoEvents: Self.payload(Self.xid(5) + bad))
        #expect(events.count == 1, "the good event is kept; the walk stops at the lie")
    }

    /// A payload with nothing in it yields nothing rather than looping.
    @Test("an empty payload yields no events")
    func emptyPayload() throws {
        var decoder = Self.decoder()
        #expect(try decoder.decode(intoEvents: Self.payload([])).isEmpty)
    }

    /// An event that is *not* a transaction payload goes through the ordinary
    /// path, which is what the peek at the type byte decides.
    @Test("a plain event is not treated as a payload")
    func plainEventIsNotUnwrapped() throws {
        var buffer = ByteBuffer()
        buffer.writeBytes(Self.xid(42))
        var decoder = Self.decoder()
        let events = try decoder.decode(intoEvents: buffer)
        #expect(events.count == 1)
        guard case .xid(let value) = events.first?.payload else {
            Issue.record("expected an XID"); return
        }
        #expect(value == 42)
    }

    /// Every prefix of a valid payload, which is what a truncated read leaves.
    @Test("every prefix of a payload is refused rather than read past")
    func everyPrefixIsSafe() {
        var full = Self.payload(Self.xid(1) + Self.xid(2))
        let bytes = full.readBytes(length: full.readableBytes)!
        for length in 0..<bytes.count {
            var buffer = ByteBuffer()
            buffer.writeBytes(Array(bytes.prefix(length)))
            var decoder = Self.decoder()
            _ = try? decoder.decode(intoEvents: buffer)
        }
    }

    // MARK: - Where the stream resumes

    /// The decoder tracks a resume position, and two kinds of event must not
    /// advance it.
    ///
    /// A **heartbeat** is synthetic — the server sends one when the log is idle
    /// — and carries the position it *would* be at, not one that corresponds to
    /// delivered events. Advancing on it moves a resume position past events
    /// that were never sent, so a reconnect skips them silently.
    ///
    /// A **zero** log position is the fake `ROTATE` that opens every stream,
    /// which likewise describes nothing that was delivered.
    @Test("a heartbeat does not advance the resume position")
    func heartbeatDoesNotAdvance() throws {
        var decoder = Self.decoder()
        var real = ByteBuffer()
        real.writeBytes(Self.xid(1, logPosition: 500))
        _ = try decoder.decode(real)
        #expect(decoder.currentPosition == 500)

        var beat = ByteBuffer()
        beat.writeBytes(Self.event(type: .heartbeat, body: [], logPosition: 9999))
        _ = try? decoder.decode(beat)
        #expect(
            decoder.currentPosition == 500,
            "a heartbeat describes a position nothing was delivered at"
        )
    }

    @Test("a zero log position does not advance the resume position")
    func zeroPositionDoesNotAdvance() throws {
        var decoder = Self.decoder()
        var real = ByteBuffer()
        real.writeBytes(Self.xid(1, logPosition: 500))
        _ = try decoder.decode(real)
        #expect(decoder.currentPosition == 500)

        var zero = ByteBuffer()
        zero.writeBytes(Self.xid(2, logPosition: 0))
        _ = try decoder.decode(zero)
        #expect(decoder.currentPosition == 500, "zero is not a position")
    }

    @Test("an ordinary event advances the resume position")
    func ordinaryEventAdvances() throws {
        var decoder = Self.decoder()
        for position in [UInt32(100), 200, 1] {
            var buffer = ByteBuffer()
            buffer.writeBytes(Self.xid(1, logPosition: position))
            _ = try decoder.decode(buffer)
            #expect(decoder.currentPosition == position, "position \(position)")
        }
    }
}

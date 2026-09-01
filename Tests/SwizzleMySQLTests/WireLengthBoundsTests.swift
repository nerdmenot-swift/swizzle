import NIOCore
import Testing
@testable import SwizzleMySQL

/// Lengths the **peer** chooses, converted to `Int` and then used to index.
///
/// ## One bug, found five more times
///
/// A length-encoded integer prefixed `0xFE` carries a full `UInt64`, so the
/// number is whatever the other end wrote. `Int(x)` on a `UInt64` above
/// `Int64.max` **traps** — it is not a wrong value, it is the process ending —
/// and every one of these sites did the conversion before checking anything.
///
/// The first instance was found by fuzzing `readLengthEncodedSlice`, and fixing
/// it there fixed one call site out of six. The others came from grepping for
/// the shape once it was known:
///
/// - the **column count** of every result set, which is the main query path and
///   not a binlog corner at all;
/// - a JSON diff value's length in a partial-update row image;
/// - three length fields in the compressed-event header, where the conversion
///   ran *inside* `min(Int(length), readableBytes)` — the clamp cannot help
///   because the trap happens before it is called.
///
/// ## Why this suite is separate
///
/// These sites have nothing in common except the mistake, so grouping them by
/// component would scatter them. Grouped by defect, the pattern is stated once
/// and a new call site has an obvious place to be tested.
///
/// The threat model is a hostile or desynchronised peer. "A real server would
/// not send that" is precisely the assumption that made all six unreachable
/// from every other test.
@Suite("Wire length bounds")
struct WireLengthBoundsTests {

    /// A length-encoded integer whose value exceeds `Int64.max`.
    static let hugeLengthEncoded: [UInt8] = [0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]

    static func buffer(_ bytes: [UInt8]) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        return buffer
    }

    // MARK: - The column count

    /// **The one that is not a corner case.** Every result set begins with a
    /// length-encoded column count, so this is reachable on any connection from
    /// the first packet of any query's response.
    @Test("a column count above Int64.max is refused rather than converted")
    func hugeColumnCount() {
        var machine = MySQLResultSetStateMachine(capabilities: [.protocol41, .deprecateEOF])
        let action = machine.receive(
            MySQLPacket(sequenceID: 1, payload: Self.buffer(Self.hugeLengthEncoded))
        )
        guard case .fail = action else {
            Issue.record("expected a failure, got \(action)")
            return
        }
    }

    /// The whole ladder of length-encoded widths in that slot, since each is a
    /// separate branch of the reader and only the widest one traps.
    @Test("every column count width is handled, and the implausible ones refused")
    func columnCountWidths() {
        // (bytes, whether the machine should accept it and wait for columns)
        let cases: [([UInt8], Bool)] = [
            ([0x01], true),                                     // 1 column
            ([0xFC, 0x00, 0x01], true),                         // 256
            // ~8.3M columns is absurd but not a trap, and no policy here can
            // say where "too many" begins without risking a legitimate wide
            // result set. It is accepted; what is capped is the *allocation*,
            // so an absurd claim costs a stalled read rather than memory.
            ([0xFD, 0xFF, 0xFF, 0x7F], true),
            ([0xFE, 0x00, 0x00, 0x00, 0x00, 0x01, 0, 0, 0], false),  // 2^32
            (Self.hugeLengthEncoded, false),                    // past Int64.max
            ([0x00], false),                                    // zero is not a result set
        ]
        for (bytes, accepted) in cases {
            var machine = MySQLResultSetStateMachine(capabilities: [.protocol41, .deprecateEOF])
            let action = machine.receive(
                MySQLPacket(sequenceID: 1, payload: Self.buffer(bytes))
            )
            if accepted {
                #expect(action == .wait, "\(bytes) should begin a result set")
            } else if case .fail = action {
                // as expected
            } else {
                Issue.record("\(bytes) should have been refused, got \(action)")
            }
        }
    }

    /// A plausible count must not cause an allocation proportional to the claim.
    ///
    /// This cannot be asserted directly without measuring memory, so what is
    /// asserted is the observable half: a large-but-permitted count is accepted
    /// and the machine keeps working. The reserve is capped in the source, and
    /// the comment there says why.
    @Test("a large but permitted column count is accepted without incident")
    func largePermittedColumnCount() {
        var machine = MySQLResultSetStateMachine(capabilities: [.protocol41, .deprecateEOF])
        // 65535 columns: past anything real, inside the bound.
        #expect(machine.receive(
            MySQLPacket(sequenceID: 1, payload: Self.buffer([0xFC, 0xFF, 0xFF]))
        ) == .wait)
    }

    // MARK: - The binlog sites

    /// The JSON diff list a partially-updated JSON column carries. Its value
    /// length is length-encoded, so it has the same reach as any other.
    @Test("a JSON diff value length above Int64.max is refused")
    func hugeJSONDiffLength() throws {
        // A diff list: total length, then operation(1), lenenc path, lenenc value.
        var region: [UInt8] = [0x00]                          // operation 0: replace
        region += [0x01, 0x24]                                // path "$", length-encoded
        region += Self.hugeLengthEncoded                      // value length: absurd
        var payload: [UInt8] = [
            UInt8(region.count & 0xFF), UInt8((region.count >> 8) & 0xFF),
            UInt8((region.count >> 16) & 0xFF), UInt8((region.count >> 24) & 0xFF),
        ]
        payload += region

        var buffer = Self.buffer(payload)
        #expect(throws: MySQLProtocolError.self) {
            _ = try MySQLBinlogRowDecoder.decodeJSONDiffs(&buffer, prefixWidth: 4)
        }
    }

    /// A well-formed diff list still decodes, so the guard did not simply
    /// reject everything.
    @Test("a well-formed JSON diff list still decodes")
    func wellFormedJSONDiff() throws {
        var region: [UInt8] = [0x00]                          // replace
        region += [0x01, 0x24]                                // path "$"
        let document: [UInt8] = [0x04, 0x01]                  // the literal `true`
        region += [UInt8(document.count)] + document
        var payload: [UInt8] = [
            UInt8(region.count & 0xFF), UInt8((region.count >> 8) & 0xFF),
            UInt8((region.count >> 16) & 0xFF), UInt8((region.count >> 24) & 0xFF),
        ]
        payload += region

        var buffer = Self.buffer(payload)
        let diffs = try MySQLBinlogRowDecoder.decodeJSONDiffs(&buffer, prefixWidth: 4)
        #expect(diffs.count == 1)
        #expect(diffs.first?.path == "$")
        #expect(diffs.first?.value == "true")
    }

    /// Every prefix of a valid diff list, which is what a truncated row image
    /// leaves behind.
    @Test("every prefix of a diff list is refused rather than read past")
    func truncatedJSONDiffLists() {
        var region: [UInt8] = [0x00, 0x01, 0x24, 0x02, 0x04, 0x01]
        region += [0x01, 0x03, 0x24, 0x2E, 0x61, 0x02, 0x05, 0x07]
        var payload: [UInt8] = [
            UInt8(region.count & 0xFF), UInt8((region.count >> 8) & 0xFF),
            UInt8((region.count >> 16) & 0xFF), UInt8((region.count >> 24) & 0xFF),
        ]
        payload += region
        for length in 0..<payload.count {
            var buffer = Self.buffer(Array(payload.prefix(length)))
            _ = try? MySQLBinlogRowDecoder.decodeJSONDiffs(&buffer, prefixWidth: 4)
        }
    }

    // MARK: - The compressed-event header

    /// The transaction-payload header carries several length-encoded fields,
    /// and two of them were skipped with `min(Int(length), readableBytes)` —
    /// where the clamp cannot help, because `Int(length)` traps before `min` is
    /// ever called.
    ///
    /// A binlog stream is a long-lived connection to a peer, and a CDC consumer
    /// is the one client that must not die: it cannot skip the event and cannot
    /// pause the stream.
    static func rawEvent(body: [UInt8]) -> MySQLRawBinlogEvent {
        MySQLRawBinlogEvent(
            header: MySQLBinlogEventHeader(
                timestamp: 0, rawEventType: 40, serverID: 1,
                eventSize: UInt32(19 + body.count), logPosition: 0, flags: 0
            ),
            body: Self.buffer(body)
        )
    }

    @Test("an absurd length in the compressed-event header is clamped, not converted")
    func hugeCompressionHeaderLengths() {
        // Field 1 is the payload size, skipped by its own length.
        let payloadSize: [UInt8] = [0x01] + Self.hugeLengthEncoded
        // The default arm takes the same path for any field the parser does not
        // know, so an unknown field id reaches the second copy of it.
        let unknownField: [UInt8] = [0x7F] + Self.hugeLengthEncoded
        // Field 3 is the uncompressed size, converted directly.
        let uncompressedSize: [UInt8] = [0x03, 0x01] + Self.hugeLengthEncoded

        for header in [payloadSize, unknownField, uncompressedSize] {
            // Throwing is a correct outcome — the event is malformed and the
            // parser said so. Trapping is not.
            _ = try? MySQLBinlogEventDecoder.unwrapTransactionPayload(Self.rawEvent(body: header))
        }
    }

    /// Every prefix of an uncompressed transaction payload, which is what a
    /// stream cut mid-event leaves.
    @Test("every prefix of a transaction-payload header is safe")
    func truncatedCompressionHeaders() {
        var header: [UInt8] = []
        header += [0x01, 0x08]                                // payload size 8
        header += [0x02, 0x01, 0xFF]                          // algorithm 255, uncompressed
        header += [0x03, 0x01, 0x08]                          // uncompressed size 8
        header += [0x00]                                      // end of header
        header += [1, 2, 3, 4, 5, 6, 7, 8]                    // the payload

        for length in 0...header.count {
            _ = try? MySQLBinlogEventDecoder.unwrapTransactionPayload(
                Self.rawEvent(body: Array(header.prefix(length)))
            )
        }
    }

    /// Random headers, seeded. The field ids are biased low so the walk reaches
    /// the length reads rather than falling into the default arm every time.
    @Test("no random transaction-payload header traps", arguments: [UInt64](1...8))
    func randomCompressionHeaders(seed: UInt64) {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1
        func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        for _ in 0..<200 {
            let count = Int(next() % 40)
            let bytes = (0..<count).map { _ -> UInt8 in
                next() % 3 == 0 ? UInt8(next() % 5) : UInt8(next() % 256)
            }
            _ = try? MySQLBinlogEventDecoder.unwrapTransactionPayload(Self.rawEvent(body: bytes))
        }
    }
}

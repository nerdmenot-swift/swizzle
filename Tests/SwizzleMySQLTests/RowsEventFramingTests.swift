import NIOCore
import Testing
@testable import SwizzleMySQL

/// The rows-event header, whose shape depends on the event's *version*.
///
/// ## Why this is the framing that goes wrong
///
/// A rows event has no self-describing layout. Where its row data begins is
/// computed from the event type: the v2 events carry a two-byte extra-data
/// block that the v1 events do not, and `PARTIAL_UPDATE_ROWS` carries a
/// `value_options` field and a partial-JSON bitmap **before each after-image**
/// rather than once in the header.
///
/// Get the version test wrong and every value in the event is read two bytes
/// off. That does not fail loudly: the row still decodes, into plausible
/// garbage, and the stream stays out of step until something eventually cannot
/// be parsed at all — which in a live stream shows up as a hang rather than an
/// error, because the reader is waiting for bytes that will never make sense.
///
/// The integration suites decode real events, but a server emits one version,
/// so the *other* branch of the test is never taken. That is why the whole
/// version set survived the mutation sweep despite the events being exercised
/// constantly. Constructing them here reaches both.
@Suite("Binlog rows-event framing")
struct RowsEventFramingTests {

    // MARK: - Building events

    static func header(
        type: MySQLBinlogEventType, body: [UInt8], logPosition: UInt32 = 4
    ) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt32(1_700_000_000), endianness: .little)
        buffer.writeInteger(type.rawValue)
        buffer.writeInteger(UInt32(1), endianness: .little)
        buffer.writeInteger(
            UInt32(MySQLBinlogEventHeader.byteCount + body.count), endianness: .little
        )
        buffer.writeInteger(logPosition, endianness: .little)
        buffer.writeInteger(UInt16(0), endianness: .little)
        buffer.writeBytes(body)
        return buffer
    }

    static let tableID: UInt64 = 42

    /// Six bytes of table id — not eight, which is the mistake that shifts
    /// every field after it.
    static func tableIDBytes() -> [UInt8] {
        let low = UInt32(tableID & 0xFFFF_FFFF)
        let high = UInt16(tableID >> 32)
        return [
            UInt8(low & 0xFF), UInt8((low >> 8) & 0xFF),
            UInt8((low >> 16) & 0xFF), UInt8((low >> 24) & 0xFF),
            UInt8(high & 0xFF), UInt8((high >> 8) & 0xFF),
        ]
    }

    /// A table map for `test.t`, one nullable `INT` column.
    static func tableMapBody(types: [UInt8] = [MySQLColumnType.long.rawValue]) -> [UInt8] {
        var body = tableIDBytes()
        body += [0x00, 0x00]                                   // flags
        body += [4] + Array("test".utf8) + [0x00]              // schema, NUL-terminated
        body += [1] + Array("t".utf8) + [0x00]                 // table
        body += [UInt8(types.count)] + types                   // column count, then types
        body += [0x00]                                         // metadata length: INT has none
        body += [UInt8](repeating: 0xFF, count: (types.count + 7) / 8)  // all nullable
        return body
    }

    /// A rows event. The extra-data block is written only for the v2 types,
    /// which is the whole distinction under test.
    static func rowsBody(
        v2: Bool, columnCount: Int = 1, afterBitmap: Bool = false,
        extraData: [UInt8] = [], rows: [[UInt8]]
    ) -> [UInt8] {
        var body = tableIDBytes()
        body += [0x00, 0x00]                                   // flags
        if v2 {
            // The length counts itself, so an empty block is 2.
            let length = 2 + extraData.count
            body += [UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF)]
            body += extraData
        }
        let bitmapBytes = (columnCount + 7) / 8
        body += [UInt8(columnCount)]                           // length-encoded, small
        body += [UInt8](repeating: 0xFF, count: bitmapBytes)   // all columns present
        if afterBitmap {
            body += [UInt8](repeating: 0xFF, count: bitmapBytes)
        }
        for row in rows { body += row }
        return body
    }

    /// One row image: a null bitmap sized to the present columns, then values.
    static func intRow(_ value: Int32) -> [UInt8] {
        let raw = UInt32(bitPattern: value)
        return [0x00] + (0..<4).map { UInt8((raw >> (8 * $0)) & 0xFF) }
    }

    /// Feeds a table map and then the event, which is the order the wire
    /// guarantees — a rows event without its map is undecodable by design.
    static func decodeRows(
        type: MySQLBinlogEventType, body: [UInt8],
        types: [UInt8] = [MySQLColumnType.long.rawValue]
    ) throws -> MySQLRowsEvent {
        var decoder = MySQLBinlogEventDecoder()
        _ = try decoder.decode(Self.header(type: .tableMap, body: Self.tableMapBody(types: types)))
        let event = try decoder.decode(Self.header(type: type, body: body))
        guard case .rows(let rows) = event.payload else {
            throw MySQLProtocolError.unexpectedPacket("expected a rows event, got \(event.payload)")
        }
        return rows
    }

    // MARK: - The version distinction

    /// **The property the version set exists for.** The same logical row,
    /// framed as v1 and as v2, decodes to the same value — which it only can if
    /// the extra-data block is read for exactly the v2 types.
    @Test("a v1 and a v2 write event carrying the same row decode identically")
    func v1AndV2AgreeOnWrites() throws {
        let v1 = try Self.decodeRows(
            type: .writeRowsV1, body: Self.rowsBody(v2: false, rows: [Self.intRow(7)])
        )
        let v2 = try Self.decodeRows(
            type: .writeRows, body: Self.rowsBody(v2: true, rows: [Self.intRow(7)])
        )
        #expect(v1.rows.count == 1)
        #expect(v2.rows.count == 1)
        #expect(v1.rows.first?.first?.int == 7)
        #expect(
            v2.rows.first?.first?.int == 7,
            "the v2 extra-data block was not skipped, so the row read two bytes early"
        )
        #expect(v1.kind == .write)
        #expect(v2.kind == .write)
    }

    /// The same for deletes and updates, since each has its own pair of type
    /// constants and its own arm of the version test.
    @Test("every rows event kind agrees across its two versions")
    func everyKindAgreesAcrossVersions() throws {
        let cases: [(MySQLBinlogEventType, MySQLBinlogEventType, MySQLRowsEvent.Kind, Bool)] = [
            (.writeRowsV1, .writeRows, .write, false),
            (.deleteRowsV1, .deleteRows, .delete, false),
            (.updateRowsV1, .updateRows, .update, true),
        ]
        for (v1Type, v2Type, kind, hasAfter) in cases {
            let rows = hasAfter
                ? [Self.intRow(7), Self.intRow(8)]
                : [Self.intRow(7)]
            let v1 = try Self.decodeRows(
                type: v1Type,
                body: Self.rowsBody(v2: false, afterBitmap: hasAfter, rows: rows)
            )
            let v2 = try Self.decodeRows(
                type: v2Type,
                body: Self.rowsBody(v2: true, afterBitmap: hasAfter, rows: rows)
            )
            #expect(v1.kind == kind, "\(v1Type)")
            #expect(v2.kind == kind, "\(v2Type)")
            #expect(v1.rows.first?.first?.int == 7, "\(v1Type)")
            #expect(v2.rows.first?.first?.int == 7, "\(v2Type)")
            if hasAfter {
                #expect(v1.updatedRows.first?.first?.int == 8, "\(v1Type) after-image")
                #expect(v2.updatedRows.first?.first?.int == 8, "\(v2Type) after-image")
            }
        }
    }

    /// A non-empty extra-data block is skipped by its declared length, which is
    /// what lets MySQL add fields there without breaking older readers. The
    /// length counts itself, so the bytes to skip are two fewer than it says —
    /// an off-by-two that reads the column count out of the middle of the
    /// block.
    @Test("a non-empty extra-data block is skipped by its own length")
    func nonEmptyExtraData() throws {
        for extra in [[UInt8](), [0x01], [0x01, 0x02, 0x03], [UInt8](repeating: 0xAB, count: 32)] {
            let rows = try Self.decodeRows(
                type: .writeRows,
                body: Self.rowsBody(v2: true, extraData: extra, rows: [Self.intRow(7)])
            )
            #expect(
                rows.rows.first?.first?.int == 7,
                "\(extra.count) bytes of extra data"
            )
        }
    }

    /// An extra-data length longer than the event is clamped rather than
    /// skipping past the end.
    @Test("an extra-data length beyond the event does not read past it")
    func oversizedExtraDataLength() {
        var body = Self.tableIDBytes()
        body += [0x00, 0x00]
        body += [0xFF, 0xFF]                                   // claims 65535 bytes
        body += [0x01, 0xFF] + Self.intRow(7)
        // Throwing is correct — the event is malformed. Trapping is not.
        _ = try? Self.decodeRows(type: .writeRows, body: body)
    }

    // MARK: - Partial JSON updates

    /// `PARTIAL_UPDATE_ROWS` is v2-shaped **and** carries `value_options`
    /// before each after-image. When bit 0 is clear the after-image is an
    /// ordinary full row — MySQL falls back whenever a diff would not be
    /// smaller than the document — so reading a partial bitmap there consumes
    /// bytes that are row data.
    @Test("a partial-update event with the partial bit clear carries a full row")
    func partialUpdateWithoutPartialBit() throws {
        var body = Self.tableIDBytes()
        body += [0x00, 0x00]
        body += [0x02, 0x00]                                   // empty extra-data block
        body += [0x01]                                         // one column
        body += [0xFF]                                         // before bitmap
        body += [0xFF]                                         // after bitmap
        body += Self.intRow(7)                                 // before image
        body += [0x00]                                         // value_options: bit 0 clear
        body += Self.intRow(8)                                 // a full after image

        let rows = try Self.decodeRows(type: .partialUpdateRows, body: body)
        #expect(rows.kind == .update)
        #expect(rows.rows.first?.first?.int == 7)
        #expect(
            rows.updatedRows.first?.first?.int == 8,
            "no bitmap follows a clear partial bit, so the row starts immediately"
        )
    }

    /// And it is treated as v2: without the extra-data block the whole event is
    /// two bytes out.
    @Test("a partial-update event carries the v2 extra-data block")
    func partialUpdateIsV2Shaped() throws {
        var withBlock = Self.tableIDBytes()
        withBlock += [0x00, 0x00, 0x02, 0x00, 0x01, 0xFF, 0xFF]
        withBlock += Self.intRow(7) + [0x00] + Self.intRow(8)

        let rows = try Self.decodeRows(type: .partialUpdateRows, body: withBlock)
        #expect(rows.rows.first?.first?.int == 7)
        #expect(rows.updatedRows.first?.first?.int == 8)
    }

    // MARK: - Malformed events

    /// A rows event whose table map was never seen is reported rather than
    /// guessed at — which happens for real whenever a stream is resumed
    /// mid-transaction.
    @Test("a rows event with no table map is reported")
    func missingTableMap() {
        var decoder = MySQLBinlogEventDecoder()
        #expect(throws: MySQLProtocolError.self) {
            _ = try decoder.decode(
                Self.header(
                    type: .writeRows,
                    body: Self.rowsBody(v2: true, rows: [Self.intRow(7)])
                )
            )
        }
    }

    /// Every prefix of a valid rows event, which is what a truncated read
    /// leaves. Between them these reach every guard in the header walk.
    @Test("every prefix of a rows event is refused rather than read past")
    func everyPrefixIsSafe() throws {
        let body = Self.rowsBody(
            v2: true, afterBitmap: true, extraData: [0x01, 0x02],
            rows: [Self.intRow(7), Self.intRow(8)]
        )
        for length in 0..<body.count {
            var decoder = MySQLBinlogEventDecoder()
            _ = try? decoder.decode(
                Self.header(type: .tableMap, body: Self.tableMapBody())
            )
            _ = try? decoder.decode(
                Self.header(type: .updateRows, body: Array(body.prefix(length)))
            )
        }
        // And the whole thing still works, so the loop above was not vacuous.
        let rows = try Self.decodeRows(type: .updateRows, body: body)
        #expect(rows.rows.first?.first?.int == 7)
    }

    /// Every prefix of a table map, for the same reason.
    @Test("every prefix of a table map is refused rather than read past")
    func everyTableMapPrefixIsSafe() {
        let body = Self.tableMapBody(
            types: [MySQLColumnType.long.rawValue, MySQLColumnType.long.rawValue]
        )
        for length in 0..<body.count {
            var decoder = MySQLBinlogEventDecoder()
            _ = try? decoder.decode(
                Self.header(type: .tableMap, body: Array(body.prefix(length)))
            )
        }
    }

    /// Random bodies through both event types, seeded.
    @Test("no random rows event traps the decoder", arguments: [UInt64](1...8))
    func randomEventsAreSafe(seed: UInt64) {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1
        func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        let types: [MySQLBinlogEventType] = [
            .writeRows, .writeRowsV1, .updateRows, .updateRowsV1,
            .deleteRows, .deleteRowsV1, .partialUpdateRows, .tableMap,
        ]
        for _ in 0..<150 {
            var decoder = MySQLBinlogEventDecoder()
            _ = try? decoder.decode(
                Self.header(type: .tableMap, body: Self.tableMapBody())
            )
            let type = types[Int(next() % UInt64(types.count))]
            let count = Int(next() % 48)
            let bytes = (0..<count).map { _ in UInt8(next() % 256) }
            _ = try? decoder.decode(Self.header(type: type, body: bytes))
        }
    }

    // MARK: - Events that make no progress

    /// **The hang this suite found.**
    ///
    /// `decodeRows` walks its rows with `while body.readableBytes > 0`, and
    /// `decodeRow` legitimately consumes **nothing** when no column is present:
    /// a zero column count, or a present-bitmap with no bits set, makes the null
    /// bitmap zero bytes wide and the per-column loop empty. Both numbers come
    /// off the wire.
    ///
    /// So one malformed event span the loop forever, appending empty rows to an
    /// array that grew without bound — a hang *and* an unbounded allocation, on
    /// a replication consumer, which is the one client that cannot skip the
    /// event and cannot pause the stream.
    ///
    /// It surfaced while mutation-testing something else: the suite stopped
    /// finishing rather than failing, which is why it had never been noticed —
    /// a test that hangs looks like a slow machine.
    @Test("a rows event that consumes no bytes per row is refused, not looped on")
    func zeroWidthRowsAreRefused() {
        // Zero columns, with bytes still to read.
        var zeroColumns = Self.tableIDBytes()
        zeroColumns += [0x00, 0x00, 0x02, 0x00]                // flags, empty extra data
        zeroColumns += [0x00]                                  // column count: zero
        zeroColumns += [0xFF, 0xFF, 0xFF, 0xFF]                // trailing bytes
        #expect(throws: MySQLProtocolError.self) {
            _ = try Self.decodeRows(type: .writeRows, body: zeroColumns)
        }

        // A real column count, but no column present in the image.
        var nonePresent = Self.tableIDBytes()
        nonePresent += [0x00, 0x00, 0x02, 0x00]
        nonePresent += [0x01]                                  // one column
        nonePresent += [0x00]                                  // present bitmap: none
        nonePresent += [0xFF, 0xFF, 0xFF, 0xFF]
        #expect(throws: MySQLProtocolError.self) {
            _ = try Self.decodeRows(type: .writeRows, body: nonePresent)
        }
    }

    /// The same shape on the update path, which decodes two images per
    /// iteration and so has its own way of not advancing.
    @Test("an update event that consumes no bytes per row is refused")
    func zeroWidthUpdateRowsAreRefused() {
        var body = Self.tableIDBytes()
        body += [0x00, 0x00, 0x02, 0x00]
        body += [0x01]                                         // one column
        body += [0x00]                                         // before bitmap: none present
        body += [0x00]                                         // after bitmap: none present
        body += [0xFF, 0xFF, 0xFF, 0xFF]
        #expect(throws: MySQLProtocolError.self) {
            _ = try Self.decodeRows(type: .updateRows, body: body)
        }
    }

    /// And a well-formed event still decodes every row it carries, so the guard
    /// did not turn a legitimate multi-row event into an error.
    @Test("a multi-row event still decodes all of its rows")
    func multipleRowsStillDecode() throws {
        let rows = try Self.decodeRows(
            type: .writeRows,
            body: Self.rowsBody(
                v2: true,
                rows: [Self.intRow(1), Self.intRow(2), Self.intRow(3), Self.intRow(4)]
            )
        )
        #expect(rows.rows.count == 4)
        #expect(rows.rows.map { $0.first?.int } == [1, 2, 3, 4])
    }
}

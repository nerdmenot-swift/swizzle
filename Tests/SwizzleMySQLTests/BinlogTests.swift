import NIOCore
import Testing
@testable import SwizzleMySQL

@Suite("Binlog framing")
struct BinlogFramingTests {

    static func event(
        type: MySQLBinlogEventType,
        body: [UInt8],
        timestamp: UInt32 = 1_700_000_000,
        serverID: UInt32 = 1,
        logPosition: UInt32 = 4,
        flags: UInt16 = 0,
        checksum: MySQLBinlogChecksum = .none
    ) -> ByteBuffer {
        var buffer = ByteBuffer()
        let size = UInt32(MySQLBinlogEventHeader.byteCount + body.count + checksum.byteCount)
        buffer.writeInteger(timestamp, endianness: .little)
        buffer.writeInteger(type.rawValue)
        buffer.writeInteger(serverID, endianness: .little)
        buffer.writeInteger(size, endianness: .little)
        buffer.writeInteger(logPosition, endianness: .little)
        buffer.writeInteger(flags, endianness: .little)
        buffer.writeBytes(body)

        if checksum == .crc32 {
            let covered = buffer.getBytes(at: 0, length: buffer.readableBytes)!
            buffer.writeInteger(
                MySQLBinlogFraming.crc32Checksum(covered), endianness: .little
            )
        }
        return buffer
    }

    @Test func parsesAHeader() throws {
        let packet = Self.event(type: .xid, body: [UInt8](repeating: 0, count: 8))
        let raw = try MySQLBinlogFraming.parseEvent(packet, checksum: .none)

        #expect(raw.header.timestamp == 1_700_000_000)
        #expect(raw.eventType == .xid)
        #expect(raw.header.eventSize == 27)
        #expect(raw.body.readableBytes == 8)
    }

    /// The checksum covers the header and body but not itself. Getting that
    /// boundary wrong produces a mismatch on every event, so it is pinned.
    @Test func verifiesAValidChecksum() throws {
        let packet = Self.event(
            type: .xid, body: [1, 2, 3, 4, 5, 6, 7, 8], checksum: .crc32
        )
        let raw = try MySQLBinlogFraming.parseEvent(packet, checksum: .crc32)
        #expect(raw.body.readableBytes == 8)
        // The checksum is stripped, not handed on as data.
        #expect(raw.body.getBytes(at: 0, length: 8) == [1, 2, 3, 4, 5, 6, 7, 8])
    }

    @Test func rejectsACorruptedChecksum() throws {
        var packet = Self.event(type: .xid, body: [1, 2, 3, 4, 5, 6, 7, 8], checksum: .crc32)
        // Flip a bit in the body; the trailing checksum no longer matches.
        packet.setInteger(UInt8(0xFF), at: MySQLBinlogEventHeader.byteCount)

        #expect(throws: (any Error).self) {
            _ = try MySQLBinlogFraming.parseEvent(packet, checksum: .crc32)
        }
    }

    /// A truncated event must be refused rather than read past its end.
    @Test(arguments: [0, 5, 18])
    func rejectsATruncatedEvent(length: Int) {
        var packet = ByteBuffer()
        packet.writeBytes([UInt8](repeating: 0, count: length))
        #expect(throws: (any Error).self) {
            _ = try MySQLBinlogFraming.parseEvent(packet, checksum: .none)
        }
    }

    /// The artificial flag marks the synthetic ROTATE and FORMAT_DESCRIPTION a
    /// server emits when a dump opens. Treating those as real progress makes a
    /// stored resume position skip events.
    @Test func detectsArtificialEvents() throws {
        let packet = Self.event(type: .rotate, body: [UInt8](repeating: 0, count: 8), flags: 0x0020)
        let raw = try MySQLBinlogFraming.parseEvent(packet, checksum: .none)
        #expect(raw.header.isArtificial)
    }

    @Test func crc32MatchesKnownValues() {
        // Standard CRC-32 check vectors.
        #expect(MySQLBinlogFraming.crc32Checksum(Array("123456789".utf8)) == 0xCBF4_3926)
        #expect(MySQLBinlogFraming.crc32Checksum([]) == 0)
    }
}

@Suite("Binlog decoding")
struct BinlogDecodingTests {

    /// The bootstrap: the format-description event announces the checksum
    /// algorithm in its own last byte, so it must be parsed *without* stripping
    /// a checksum it has not yet declared.
    @Test func formatDescriptionBootstrapsTheChecksum() throws {
        var body = [UInt8]()
        body += [4, 0]                                        // binlog version
        var version = Array("11.4.0-MariaDB".utf8)
        version += [UInt8](repeating: 0, count: 50 - version.count)
        body += version
        body += [0, 0, 0, 0]                                  // create timestamp
        body += [19]                                          // header length
        body += [UInt8](repeating: 0, count: 40)              // post-header lengths
        body += [1]                                           // checksum = CRC32

        var packet = BinlogFramingTests.event(type: .formatDescription, body: body)
        // Append a real CRC32 the way a server would.
        let covered = packet.getBytes(at: 0, length: packet.readableBytes)!
        packet.writeInteger(MySQLBinlogFraming.crc32Checksum(covered), endianness: .little)
        packet.setInteger(
            UInt32(packet.readableBytes), at: 9, endianness: .little
        )

        var decoder = MySQLBinlogEventDecoder()
        #expect(decoder.checksum == .none)
        let event = try decoder.decode(packet)

        guard case .formatDescription(let fde) = event.payload else {
            Issue.record("expected a format description"); return
        }
        #expect(fde.serverVersion == "11.4.0-MariaDB")
        #expect(fde.checksum == .crc32)
        // And the decoder has adopted it for everything that follows.
        #expect(decoder.checksum == .crc32)
    }

    @Test func decodesRotateAndTracksTheFilename() throws {
        var body = [UInt8]()
        body += [4, 0, 0, 0, 0, 0, 0, 0]                      // position
        body += Array("binlog.000007".utf8)

        var decoder = MySQLBinlogEventDecoder()
        let event = try decoder.decode(BinlogFramingTests.event(type: .rotate, body: body))

        guard case .rotate(let rotate) = event.payload else {
            Issue.record("expected a rotate"); return
        }
        #expect(rotate.nextFilename == "binlog.000007")
        #expect(rotate.position == 4)
        #expect(decoder.currentFilename == "binlog.000007")
    }

    @Test func decodesXid() throws {
        var decoder = MySQLBinlogEventDecoder()
        let event = try decoder.decode(
            BinlogFramingTests.event(type: .xid, body: [0x2A, 0, 0, 0, 0, 0, 0, 0])
        )
        guard case .xid(let xid) = event.payload else {
            Issue.record("expected an XID"); return
        }
        #expect(xid == 42)
    }

    /// A heartbeat is synthetic. Advancing the resume position on one would push
    /// it past events that were never delivered.
    @Test func heartbeatsDoNotAdvanceThePosition() throws {
        var decoder = MySQLBinlogEventDecoder()
        _ = try decoder.decode(
            BinlogFramingTests.event(type: .xid, body: [UInt8](repeating: 0, count: 8),
                                     logPosition: 500)
        )
        #expect(decoder.currentPosition == 500)

        _ = try decoder.decode(
            BinlogFramingTests.event(type: .heartbeat, body: [], logPosition: 9_999)
        )
        #expect(decoder.currentPosition == 500, "a heartbeat moved the position")
    }

    /// A row event without its table map is undecodable. Reporting that beats
    /// emitting rows decoded against a guessed schema.
    @Test func rowsWithoutATableMapAreRefused() {
        var body = [UInt8]()
        body += [1, 0, 0, 0, 0, 0]                            // table id
        body += [0, 0]                                        // flags
        body += [2, 0]                                        // extra-data length
        body += [1]                                           // column count
        body += [0x01]                                        // present bitmap

        var decoder = MySQLBinlogEventDecoder()
        #expect(throws: (any Error).self) {
            _ = try decoder.decode(BinlogFramingTests.event(type: .writeRows, body: body))
        }
    }

    @Test func unrecognisedEventsAreSurfacedRaw() throws {
        var decoder = MySQLBinlogEventDecoder()
        let event = try decoder.decode(
            BinlogFramingTests.event(type: .incident, body: [1, 2, 3])
        )
        guard case .other(let raw) = event.payload else {
            Issue.record("expected a raw event"); return
        }
        #expect(raw.eventType == .incident)
        #expect(raw.body.readableBytes == 3)
    }

    @Test func formatsAUUID() {
        let bytes: [UInt8] = [
            0x3E, 0x11, 0xFA, 0x47, 0x71, 0xCA, 0x11, 0xE1,
            0x9E, 0x33, 0xC8, 0x0A, 0xA9, 0x42, 0x95, 0x62,
        ]
        #expect(
            MySQLBinlogEventDecoder.formatUUID(bytes)
                == "3e11fa47-71ca-11e1-9e33-c80aa9429562"
        )
    }
}

@Suite("Binlog GTID sets")
struct BinlogGtidTests {

    /// The wire format's interval end is **exclusive** where the text form's is
    /// inclusive. Getting it wrong silently skips or replays one transaction at
    /// every resume — the kind of bug that only shows up as drift.
    @Test func encodesAnInclusiveRangeAsExclusive() throws {
        let encoded = try MySQLGtidSet.encodeForDump(
            "3e11fa47-71ca-11e1-9e33-c80aa9429562:1-100"
        )
        // 8 (source count) + 16 (uuid) + 8 (interval count) + 16 (one interval)
        #expect(encoded.count == 48)

        func readUInt64(at offset: Int) -> UInt64 {
            var value: UInt64 = 0
            for i in 0..<8 { value |= UInt64(encoded[offset + i]) << (8 * i) }
            return value
        }
        #expect(readUInt64(at: 0) == 1)          // one source
        #expect(readUInt64(at: 24) == 1)         // one interval
        #expect(readUInt64(at: 32) == 1)         // start
        #expect(readUInt64(at: 40) == 101, "end bound must be exclusive")
    }

    @Test func encodesSeveralSources() throws {
        let encoded = try MySQLGtidSet.encodeForDump(
            "3e11fa47-71ca-11e1-9e33-c80aa9429562:1-5,"
            + "5a1b2c3d-71ca-11e1-9e33-c80aa9429562:1-3"
        )
        #expect(encoded.count == 8 + 2 * (16 + 8 + 16))
    }

    @Test func encodesASingleTransaction() throws {
        let encoded = try MySQLGtidSet.encodeForDump(
            "3e11fa47-71ca-11e1-9e33-c80aa9429562:7"
        )
        func readUInt64(at offset: Int) -> UInt64 {
            var value: UInt64 = 0
            for i in 0..<8 { value |= UInt64(encoded[offset + i]) << (8 * i) }
            return value
        }
        #expect(readUInt64(at: 32) == 7)
        #expect(readUInt64(at: 40) == 8)
    }

    @Test(arguments: ["not-a-uuid:1-5", "3e11fa47:1-5", "3e11fa47-71ca-11e1-9e33-c80aa9429562"])
    func rejectsMalformedSets(input: String) {
        #expect(throws: (any Error).self) {
            _ = try MySQLGtidSet.encodeForDump(input)
        }
    }

    /// An empty set is **valid**, not malformed: it is how a consumer with no
    /// prior state says "I have nothing, send everything you still have". It
    /// encodes as zero sources rather than erroring.
    @Test func anEmptySetEncodesAsZeroSources() throws {
        let encoded = try MySQLGtidSet.encodeForDump("")
        #expect(encoded == [UInt8](repeating: 0, count: 8))
    }

    @Test func gtidTextRoundTripsForBothDialects() {
        #expect(MySQLGtid.mariaDB(domainID: 0, serverID: 1, sequence: 100).text == "0-1-100")
        #expect(
            MySQLGtid.mysql(uuid: "3e11fa47-71ca-11e1-9e33-c80aa9429562", sequence: 5).text
                == "3e11fa47-71ca-11e1-9e33-c80aa9429562:5"
        )
    }
}

@Suite("Binlog row decoding")
struct BinlogRowDecodingTests {

    static func table(types: [UInt8], metadata: [UInt16]) -> MySQLTableMapEvent {
        MySQLTableMapEvent(
            tableID: 1,
            schema: "test",
            table: "t",
            columnTypes: types,
            columnMetadata: metadata,
            nullableColumns: [Bool](repeating: true, count: types.count)
        )
    }

    @Test func decodesIntegerWidths() throws {
        let map = Self.table(
            types: [
                MySQLColumnType.tiny.rawValue,
                MySQLColumnType.short.rawValue,
                MySQLColumnType.int24.rawValue,
                MySQLColumnType.long.rawValue,
                MySQLColumnType.longlong.rawValue,
            ],
            metadata: [0, 0, 0, 0, 0]
        )

        var buffer = ByteBuffer()
        buffer.writeBytes([0x00])                                  // null bitmap
        buffer.writeBytes([0xFF])                                  // tiny = -1
        buffer.writeBytes([0x00, 0x80])                            // short = -32768
        buffer.writeBytes([0xFF, 0xFF, 0x7F])                      // int24 = 8388607
        buffer.writeBytes([0x01, 0x00, 0x00, 0x00])                // long = 1
        buffer.writeBytes([0x02, 0, 0, 0, 0, 0, 0, 0])             // longlong = 2

        let values = try MySQLBinlogRowDecoder.decodeRow(
            &buffer, table: map, presentColumns: [0x1F], columnCount: 5
        )
        #expect(values[0].int == -1)
        #expect(values[1].int == -32_768)
        #expect(values[2].int == 8_388_607)
        #expect(values[3].int == 1)
        #expect(values[4].int == 2)
    }

    /// The null bitmap is sized to the number of *present* columns, not the
    /// table's column count — the difference only shows up on a partial image.
    @Test func nullBitmapIsSizedToPresentColumns() throws {
        let map = Self.table(
            types: [UInt8](repeating: MySQLColumnType.long.rawValue, count: 10),
            metadata: [UInt16](repeating: 0, count: 10)
        )

        var buffer = ByteBuffer()
        // Only columns 0 and 1 present, so the null bitmap is a single byte.
        buffer.writeBytes([0x02])                                  // column 1 is NULL
        buffer.writeBytes([0x07, 0x00, 0x00, 0x00])                // column 0 = 7

        let values = try MySQLBinlogRowDecoder.decodeRow(
            &buffer, table: map, presentColumns: [0x03, 0x00], columnCount: 10
        )
        #expect(values.count == 10)
        #expect(values[0].int == 7)
        #expect(values[1].isNull)
        // Absent columns report null; there is no third state.
        #expect(values[9].isNull)
        #expect(buffer.readableBytes == 0, "decoder over- or under-read the row")
    }

    @Test func decodesVariableLengthStrings() throws {
        let map = Self.table(
            types: [MySQLColumnType.varchar.rawValue, MySQLColumnType.varchar.rawValue],
            metadata: [10, 300]      // one-byte length, then two-byte length
        )

        var buffer = ByteBuffer()
        buffer.writeBytes([0x00])
        buffer.writeBytes([3])
        buffer.writeBytes(Array("abc".utf8))
        buffer.writeBytes([4, 0])
        buffer.writeBytes(Array("wxyz".utf8))

        let values = try MySQLBinlogRowDecoder.decodeRow(
            &buffer, table: map, presentColumns: [0x03], columnCount: 2
        )
        #expect(values[0].string == "abc")
        #expect(values[1].string == "wxyz")
    }

    /// The metadata byte on a BLOB is the width of its length prefix, not a
    /// length. Reading it as a length mis-frames every following column.
    @Test func blobMetadataIsALengthPrefixWidth() throws {
        let map = Self.table(types: [MySQLColumnType.blob.rawValue], metadata: [2])

        var buffer = ByteBuffer()
        buffer.writeBytes([0x00])
        buffer.writeBytes([5, 0])                                  // two-byte prefix
        buffer.writeBytes(Array("hello".utf8))

        let values = try MySQLBinlogRowDecoder.decodeRow(
            &buffer, table: map, presentColumns: [0x01], columnCount: 1
        )
        #expect(values[0].string == "hello")
        #expect(buffer.readableBytes == 0)
    }

    @Test func decodesFloatAndDouble() throws {
        let map = Self.table(
            types: [MySQLColumnType.float.rawValue, MySQLColumnType.double.rawValue],
            metadata: [4, 8]
        )

        var buffer = ByteBuffer()
        buffer.writeBytes([0x00])
        withUnsafeBytes(of: Float(1.5).bitPattern.littleEndian) { buffer.writeBytes($0) }
        withUnsafeBytes(of: Double(2.25).bitPattern.littleEndian) { buffer.writeBytes($0) }

        let values = try MySQLBinlogRowDecoder.decodeRow(
            &buffer, table: map, presentColumns: [0x03], columnCount: 2
        )
        #expect(values[0].double == 1.5)
        #expect(values[1].double == 2.25)
    }

    /// An unknown type has unknown width, so continuing would decode every later
    /// column from the wrong offset. Failing loudly is the only safe option.
    @Test func unknownColumnTypesAreRefused() {
        let map = Self.table(types: [200], metadata: [0])
        var buffer = ByteBuffer()
        buffer.writeBytes([0x00, 0x01, 0x02])

        #expect(throws: (any Error).self) {
            _ = try MySQLBinlogRowDecoder.decodeRow(
                &buffer, table: map, presentColumns: [0x01], columnCount: 1
            )
        }
    }

    /// DECIMAL packs nine digits per four bytes with partial groups at each end.
    @Test(arguments: [
        (10, 2, 5), (18, 9, 8), (5, 2, 3), (9, 0, 4), (1, 0, 1),
    ])
    func decimalWidths(precision: Int, scale: Int, expected: Int) {
        #expect(
            MySQLBinlogRowDecoder.decimalByteCount(precision: precision, scale: scale) == expected
        )
    }

    @Test(arguments: [(0, 0), (1, 1), (2, 1), (3, 2), (4, 2), (5, 3), (6, 3)])
    func fractionalSecondWidths(precision: Int, expected: Int) {
        #expect(MySQLBinlogRowDecoder.fractionalByteCount(precision) == expected)
    }

    // MARK: - When the table map and the row event disagree

    /// A row event carries **no schema** — it cites a table id, and the decoder
    /// looks up a map it cached from an earlier event. Nothing on the wire
    /// guarantees the two agree about how many columns there are: the server
    /// mints a new table id whenever a definition re-enters its cache, a stream
    /// can be resumed from a position that lands after the map, and a consumer
    /// can be fed a map from a different table entirely.
    ///
    /// So the decoder bounds-checks the map on every column rather than
    /// trusting the count. Those checks are unreachable while the two agree,
    /// which is why every one of them survived the mutation sweep.
    @Test("a row event citing more columns than the table map describes does not trap")
    func rowWiderThanTheTableMap() throws {
        // The map knows about one column; the event claims five.
        let map = Self.table(types: [MySQLColumnType.long.rawValue], metadata: [0])
        var buffer = ByteBuffer()
        buffer.writeBytes([0x00])                                  // null bitmap
        buffer.writeBytes([0x07, 0x00, 0x00, 0x00])                // the one real column
        buffer.writeBytes([UInt8](repeating: 0x41, count: 32))     // and then whatever

        // Throwing is a correct outcome — the image cannot be decoded. Trapping
        // on an out-of-range subscript is not.
        _ = try? MySQLBinlogRowDecoder.decodeRow(
            &buffer, table: map, presentColumns: [0x1F], columnCount: 5
        )
    }

    /// The same when only the *metadata* is short, which is a distinct array
    /// and a distinct bounds check.
    @Test("a table map with fewer metadata entries than types does not trap")
    func metadataShorterThanTypes() throws {
        let map = MySQLTableMapEvent(
            tableID: 1, schema: "test", table: "t",
            columnTypes: [UInt8](repeating: MySQLColumnType.varString.rawValue, count: 4),
            columnMetadata: [16],                                  // one entry for four columns
            nullableColumns: [Bool](repeating: true, count: 4)
        )
        var buffer = ByteBuffer()
        buffer.writeBytes([0x00])
        buffer.writeBytes([0x02, 0x61, 0x62])                      // "ab"
        buffer.writeBytes([UInt8](repeating: 0x00, count: 16))

        _ = try? MySQLBinlogRowDecoder.decodeRow(
            &buffer, table: map, presentColumns: [0x0F], columnCount: 4
        )
    }

    /// The partial-JSON bitmap is indexed by JSON-column ordinal, which is a
    /// different number from the column position — so it has its own length and
    /// its own check.
    @Test("a partial-JSON bitmap shorter than the JSON column count does not trap")
    func shortPartialJSONBitmap() throws {
        let map = Self.table(
            types: [UInt8](repeating: MySQLColumnType.json.rawValue, count: 20),
            metadata: [UInt16](repeating: 4, count: 20)
        )
        var buffer = ByteBuffer()
        buffer.writeBytes([0x00, 0x00, 0x00])                      // null bitmap
        buffer.writeBytes([UInt8](repeating: 0x00, count: 64))

        // Twenty JSON columns need three bitmap bytes; one is supplied.
        _ = try? MySQLBinlogRowDecoder.decodeRow(
            &buffer, table: map, presentColumns: [0xFF, 0xFF, 0x0F],
            columnCount: 20, partialJSONColumns: [0xFF]
        )
    }

    // MARK: - Metadata-driven widths

    /// A `VARCHAR` length prefix is **one byte below 256 and two at or above**,
    /// decided by the column's declared maximum rather than by anything in the
    /// row image. Get it wrong and the value is misread *and* every column after
    /// it is misaligned, so the sentinel is what actually catches it.
    @Test("the VARCHAR length prefix widens at exactly 256",
          arguments: [MySQLColumnType.varString, .varchar])
    func varcharLengthPrefixBoundary(type: MySQLColumnType) throws {
        let narrow = Self.table(types: [type.rawValue, MySQLColumnType.long.rawValue],
                                metadata: [255, 0])
        var narrowBuffer = ByteBuffer()
        narrowBuffer.writeBytes([0x00])
        narrowBuffer.writeBytes([0x03, 0x61, 0x62, 0x63])          // "abc"
        narrowBuffer.writeBytes([0x39, 0x30, 0x00, 0x00])          // sentinel 12345
        let narrowValues = try MySQLBinlogRowDecoder.decodeRow(
            &narrowBuffer, table: narrow, presentColumns: [0x03], columnCount: 2
        )
        #expect(narrowValues[0].string == "abc", "\(type) at 255")
        #expect(narrowValues[1].int == 12_345, "\(type) at 255 consumed the wrong width")

        // Declared maximum 256: two length bytes.
        let wide = Self.table(types: [type.rawValue, MySQLColumnType.long.rawValue],
                              metadata: [256, 0])
        var wideBuffer = ByteBuffer()
        wideBuffer.writeBytes([0x00])
        wideBuffer.writeBytes([0x03, 0x00, 0x61, 0x62, 0x63])      // "abc", two-byte length
        wideBuffer.writeBytes([0x39, 0x30, 0x00, 0x00])
        let wideValues = try MySQLBinlogRowDecoder.decodeRow(
            &wideBuffer, table: wide, presentColumns: [0x03], columnCount: 2
        )
        #expect(wideValues[0].string == "abc", "\(type) at 256")
        #expect(wideValues[1].int == 12_345, "\(type) at 256 consumed the wrong width")
    }


    /// A `CHAR` longer than 255 cannot say so in the metadata's low byte, and
    /// the high byte is already spoken for by the type overload. MySQL encodes
    /// the two extra length bits **into the type byte itself**, xored into the
    /// `0x30` mask — so the type byte of a wide CHAR is not a valid column type
    /// at all, and the decoder must recover the length from it rather than
    /// treating the column as an unknown type.
    ///
    /// `metadata = (0xFE ^ ((length & 0x300) >> 4)) << 8 | (length & 0xFF)`
    @Test("a CHAR longer than 255 recovers its length from the type byte")
    func wideCharLengthFromTypeByte() throws {
        for length in [256, 300, 511, 512, 767] {
            let typeByte = UInt16(MySQLColumnType.string.rawValue) ^ UInt16((length & 0x300) >> 4)
            let packed = typeByte << 8 | UInt16(length & 0xFF)
            let map = Self.table(
                types: [MySQLColumnType.string.rawValue, MySQLColumnType.long.rawValue],
                metadata: [packed, 0]
            )
            var buffer = ByteBuffer()
            buffer.writeBytes([0x00])
            buffer.writeBytes([0x03, 0x00, 0x61, 0x62, 0x63])      // "abc", two-byte length
            buffer.writeBytes([0x39, 0x30, 0x00, 0x00])            // sentinel
            let values = try MySQLBinlogRowDecoder.decodeRow(
                &buffer, table: map, presentColumns: [0x03], columnCount: 2
            )
            #expect(values[0].string == "abc", "CHAR(\(length))")
            #expect(
                values[1].int == 12_345,
                "CHAR(\(length)) read the wrong prefix width, so the next column moved"
            )
        }
    }

    /// `MYSQL_TYPE_STRING` is overloaded: for `ENUM`, `SET` and `CHAR` the real
    /// type is packed into the **high byte** of the metadata and the low byte
    /// carries the length. Read as a plain string it yields garbage for every
    /// ENUM column, which is a wrong value rather than an error.
    @Test("an ENUM arrives as a STRING with its real type packed into the metadata")
    func enumPackedIntoStringMetadata() throws {
        let packed = UInt16(MySQLColumnType.enumeration.rawValue) << 8 | 1
        let map = Self.table(
            types: [MySQLColumnType.string.rawValue, MySQLColumnType.long.rawValue],
            metadata: [packed, 0]
        )
        var buffer = ByteBuffer()
        buffer.writeBytes([0x00])
        buffer.writeBytes([0x02])                                  // the second ENUM member
        buffer.writeBytes([0x39, 0x30, 0x00, 0x00])                // sentinel
        let values = try MySQLBinlogRowDecoder.decodeRow(
            &buffer, table: map, presentColumns: [0x03], columnCount: 2
        )
        #expect(values[0].int == 2, "decoded as \(values[0]) rather than an ENUM index")
        #expect(values[1].int == 12_345, "the ENUM consumed the wrong number of bytes")
    }

    /// A metadata word below 256 means a plain `CHAR`, so the overload must not
    /// fire — the boundary between the two readings.
    @Test("a STRING with metadata below 256 stays a plain string")
    func stringMetadataBelowTheOverload() throws {
        let map = Self.table(types: [MySQLColumnType.string.rawValue], metadata: [255])
        var buffer = ByteBuffer()
        buffer.writeBytes([0x00])
        buffer.writeBytes([0x02, 0x68, 0x69])                      // "hi"
        let values = try MySQLBinlogRowDecoder.decodeRow(
            &buffer, table: map, presentColumns: [0x01], columnCount: 1
        )
        #expect(values[0].string == "hi")
    }


    /// The JSON-ordinal count walks *every earlier column* to work out which
    /// bit of the partial bitmap belongs to this one — so it indexes the type
    /// array with positions that may run past it when the map is short. That is
    /// a second bounds check on the same array, reached only when the row is
    /// wider than the map **and** a JSON column is flagged partial.
    @Test("counting JSON ordinals past the end of a short table map does not trap")
    func jsonOrdinalPastTheTableMap() throws {
        // Two columns described, five claimed, and a partial-JSON bitmap that
        // makes the ordinal walk run.
        let map = Self.table(
            types: [MySQLColumnType.json.rawValue, MySQLColumnType.json.rawValue],
            metadata: [4, 4]
        )
        var buffer = ByteBuffer()
        buffer.writeBytes([0x00])
        buffer.writeBytes([UInt8](repeating: 0x00, count: 48))

        _ = try? MySQLBinlogRowDecoder.decodeRow(
            &buffer, table: map, presentColumns: [0x1F], columnCount: 5,
            partialJSONColumns: [0xFF]
        )
    }

    /// The `MYSQL_TYPE_STRING` overload fires on a **non-zero high byte**, not
    /// on a length of 256 — the two coincide numerically and mean different
    /// things. A column whose metadata is exactly 256 has a real type packed
    /// into it and is not a 256-byte string.
    @Test("the STRING overload turns on the high byte, at exactly 256")
    func stringOverloadBoundary() throws {
        // 256 packs real type 1 with a low byte of zero. Whatever that decodes
        // as, it must not read the two-byte length prefix a 256-wide string
        // would — the sentinel is what says which reading happened.
        let map = Self.table(
            types: [MySQLColumnType.string.rawValue, MySQLColumnType.long.rawValue],
            metadata: [256, 0]
        )
        var buffer = ByteBuffer()
        buffer.writeBytes([0x00])
        buffer.writeBytes([0x07])                                  // one byte, not a prefix
        buffer.writeBytes([0x39, 0x30, 0x00, 0x00])                // sentinel 12345
        let values = try MySQLBinlogRowDecoder.decodeRow(
            &buffer, table: map, presentColumns: [0x03], columnCount: 2
        )
        #expect(
            values[1].int == 12_345,
            "metadata 256 was read as a string width rather than as a packed type"
        )
    }

    // MARK: - Truncated packed decimals

    /// The packed decimal reader stops at the end of its buffer rather than
    /// indexing past it. A row image can be short for the same reasons any other
    /// field can, and the width here is computed from the *declared* precision
    /// rather than from the bytes present.
    @Test("a packed decimal shorter than its precision implies does not read past the end")
    func truncatedPackedDecimal() {
        for precision in [10, 20, 38, 65] {
            for scale in [0, 2, 6, 9] where scale <= precision {
                let full = MySQLBinlogRowDecoder.decimalByteCount(
                    precision: precision, scale: scale
                )
                for supplied in 0...full {
                    // Any string is acceptable — the input is truncated and the
                    // value is meaningless. Returning one is the property.
                    _ = MySQLBinlogRowDecoder.decodeDecimal(
                        [UInt8](repeating: 0xFF, count: supplied),
                        precision: precision, scale: scale
                    )
                }
            }
        }
    }

    /// The pre-5.6 `TIME` format, whose three bytes are **signed**.
    ///
    /// The decoder assembled them as unsigned, which made its own `isNegative`
    /// test dead code — a negative time came back as a large positive one, so
    /// `-12:34:56` decoded as `69 09:56:00`. The mutation sweep found it by
    /// pointing at a comparison that could never be true.
    ///
    /// That the field is signed follows from its range. The largest legal
    /// `TIME`, `838:59:59`, packs to 8385959, just under 2^23 — headroom that
    /// only makes sense if the top bit is a sign. `rust-mysql-common` reads it
    /// unsigned and hardcodes the sign to false, so it carries the same defect;
    /// this is a deliberate divergence.
    ///
    /// The format only appears in binlogs written before 5.6, which no fixture
    /// here can produce, so it is exercised from constructed bytes rather than
    /// from a server.
    @Test(
        "the pre-5.6 TIME format carries a sign",
        arguments: [
            // bytes (little-endian 24-bit), negative, days, hours, minutes, seconds
            ([UInt8](arrayLiteral: 0x00, 0x00, 0x00), false, UInt32(0), UInt8(0), UInt8(0), UInt8(0)),
            ([0x40, 0xE2, 0x01], false, 0, 12, 34, 56),   //  123456 →  12:34:56
            ([0xC0, 0x1D, 0xFE], true, 0, 12, 34, 56),    // -123456 → -12:34:56
            ([0xA7, 0xF5, 0x7F], false, 34, 22, 59, 59),  //  838:59:59, the maximum
            ([0x59, 0x0A, 0x80], true, 34, 22, 59, 59),   // -838:59:59, the minimum
            ([0xFF, 0xFF, 0xFF], true, 0, 0, 0, 1),       // -1 → -00:00:01
        ]
    )
    func oldTimeFormatIsSigned(
        bytes: [UInt8], negative: Bool, days: UInt32, hours: UInt8,
        minutes: UInt8, seconds: UInt8
    ) throws {
        let map = Self.table(types: [MySQLColumnType.time.rawValue], metadata: [0])
        var buffer = ByteBuffer()
        buffer.writeBytes([0x00])                                  // null bitmap
        buffer.writeBytes(bytes)

        let values = try MySQLBinlogRowDecoder.decodeRow(
            &buffer, table: map, presentColumns: [0x01], columnCount: 1
        )
        guard case .time(let time) = values[0] else {
            Issue.record("expected a TIME, got \(values[0])")
            return
        }
        #expect(time.isNegative == negative)
        #expect(time.days == days)
        #expect(time.hours == hours)
        #expect(time.minutes == minutes)
        #expect(time.seconds == seconds)
    }

    /// No three-byte value may trap, whatever it means. The sign extension
    /// makes half the space negative, and the negation that follows is where an
    /// unguarded implementation would overflow.
    @Test("no three-byte TIME value traps the decoder")
    func everyOldTimeValueIsSafe() throws {
        let map = Self.table(types: [MySQLColumnType.time.rawValue], metadata: [0])
        // The whole 24-bit space is 16.7M decodes, which is too slow for every
        // run; this walks it in strides that land on both sides of the sign
        // boundary and on the extremes.
        for raw in stride(from: 0, to: 0x100_0000, by: 0x2AB) {
            var buffer = ByteBuffer()
            buffer.writeBytes([0x00])
            buffer.writeBytes([
                UInt8(raw & 0xFF), UInt8((raw >> 8) & 0xFF), UInt8((raw >> 16) & 0xFF),
            ])
            // Throwing is fine — the value may be out of MySQL's own range.
            // Trapping is not.
            _ = try? MySQLBinlogRowDecoder.decodeRow(
                &buffer, table: map, presentColumns: [0x01], columnCount: 1
            )
        }
    }
}

/// Lifetime of the decoder's table-map cache.
///
/// Row events carry no schema — they cite a table id and the decoder must
/// already hold the map. So the cache cannot be dropped eagerly. But a table id
/// is not stable either: the server mints a new one whenever a table definition
/// re-enters its cache, and nothing on the wire ever says an id is dead. Left
/// alone, a long-running CDC consumer accumulates dead maps forever.
@Suite("Binlog table-map cache")
struct BinlogTableMapCacheTests {

    /// A minimal one-column table map for a given id.
    static func tableMap(id: UInt64, table: String = "t") -> ByteBuffer {
        var body = [UInt8]()
        body += withUnsafeBytes(of: id.littleEndian) { Array($0.prefix(6)) }   // 6-byte id
        body += [0, 0]                                                        // flags
        body += [UInt8(2)] + Array("db".utf8) + [0]                           // schema
        body += [UInt8(table.utf8.count)] + Array(table.utf8) + [0]           // table
        body += [1]                                                           // column count
        body += [3]                                                           // MYSQL_TYPE_LONG
        body += [0]                                                           // metadata length
        body += [0]                                                           // null bitmap
        return BinlogFramingTests.event(type: .tableMap, body: body)
    }

    static func rotate(artificial: Bool) -> ByteBuffer {
        var body = [UInt8]()
        body += [4, 0, 0, 0, 0, 0, 0, 0]
        body += Array("binlog.000002".utf8)
        return BinlogFramingTests.event(
            type: .rotate, body: body, flags: artificial ? 0x0020 : 0
        )
    }

    @Test("the cache is bounded, and evicts oldest first")
    func boundedByInsertionOrder() throws {
        var decoder = MySQLBinlogEventDecoder()
        let limit = MySQLBinlogEventDecoder.tableMapLimit
        let excess = 100

        for id in 0..<UInt64(limit + excess) {
            _ = try decoder.decode(Self.tableMap(id: id))
        }

        #expect(decoder.tableMaps.count == limit)
        // The oldest went; the newest — the only ones a row event can still
        // cite — are all present.
        #expect(decoder.tableMaps[0] == nil)
        #expect(decoder.tableMaps[UInt64(excess - 1)] == nil)
        #expect(decoder.tableMaps[UInt64(excess)] != nil)
        #expect(decoder.tableMaps[UInt64(limit + excess - 1)] != nil)
    }

    /// Re-announcing a table must refresh it, not consume another slot —
    /// otherwise a steady stream of writes to one table would evict everything
    /// else even though only one map is live.
    @Test("re-announcing a table does not consume a new slot")
    func reannouncingDoesNotGrow() throws {
        var decoder = MySQLBinlogEventDecoder()
        for _ in 0..<(MySQLBinlogEventDecoder.tableMapLimit * 2) {
            _ = try decoder.decode(Self.tableMap(id: 7, table: "same"))
        }
        #expect(decoder.tableMaps.count == 1)

        // And a later map still evicts by *first* insertion order, so the
        // long-lived id 7 is not privileged into immortality by being refreshed.
        for id in 100..<UInt64(100 + MySQLBinlogEventDecoder.tableMapLimit) {
            _ = try decoder.decode(Self.tableMap(id: id))
        }
        #expect(decoder.tableMaps.count == MySQLBinlogEventDecoder.tableMapLimit)
        #expect(decoder.tableMaps[7] == nil)
    }

    @Test("a real rotate clears the cache; an artificial one does not")
    func rotateClears() throws {
        var decoder = MySQLBinlogEventDecoder()
        _ = try decoder.decode(Self.tableMap(id: 1))
        #expect(decoder.tableMaps.count == 1)

        // The artificial rotate a server synthesises when a dump starts says
        // where we are about to read, not that a file ended.
        _ = try decoder.decode(Self.rotate(artificial: true))
        #expect(decoder.tableMaps.count == 1, "an artificial rotate is not a boundary")

        _ = try decoder.decode(Self.rotate(artificial: false))
        #expect(decoder.tableMaps.isEmpty, "a real rotate ends the file and its maps")
    }
}

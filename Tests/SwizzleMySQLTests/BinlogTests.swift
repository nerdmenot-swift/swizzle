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

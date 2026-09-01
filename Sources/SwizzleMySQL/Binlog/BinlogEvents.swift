import NIOCore

// MARK: - Decoded events

public struct MySQLFormatDescriptionEvent: Sendable {
    public var binlogVersion: UInt16
    public var serverVersion: String
    public var createTimestamp: UInt32
    public var headerLength: UInt8
    public var checksum: MySQLBinlogChecksum
}

public struct MySQLRotateEvent: Sendable {
    public var position: UInt64
    public var nextFilename: String
}

public struct MySQLQueryEvent: Sendable {
    public var threadID: UInt32
    public var executionTime: UInt32
    public var errorCode: UInt16
    public var schema: String
    public var query: String
    /// The session context the statement ran under.
    public var statusVariables = MySQLQueryStatusVariables()
}

/// Session state recorded alongside a `QUERY_EVENT`.
///
/// A statement's text is not enough to replay it. `INSERT ... VALUES (NOW())`
/// means different things in different time zones; `'a' = 'A'` depends on the
/// collation; whether a zero date is accepted depends on `sql_mode`. The server
/// therefore writes the relevant session variables into every query event, and a
/// consumer that ignores them can reach a different result than the source did.
///
/// This used to be skipped wholesale, on the reasoning that a consumer replaying
/// DDL needs the text rather than the session state. That is true for DDL and
/// wrong for everything else — and ``timeZone`` in particular is the only thing
/// that says what a `TIMESTAMP` in the statement meant.
///
/// Only the variables that change how a statement behaves are surfaced; the rest
/// are walked past. Parsing has to know every key's length regardless, because
/// the block is a flat sequence with no per-entry framing — one unknown key and
/// everything after it is unreadable.
public struct MySQLQueryStatusVariables: Sendable, Equatable {
    /// `@@session.time_zone`, e.g. `+00:00` or `SYSTEM`.
    public var timeZone: String?
    /// `@@session.sql_mode` as its raw bit set.
    public var sqlMode: UInt64?
    /// `auto_increment_increment` and `auto_increment_offset`.
    public var autoIncrement: (increment: UInt16, offset: UInt16)?
    /// Client, connection and server collation ids.
    public var charset: (client: UInt16, connection: UInt16, server: UInt16)?
    /// The default collation for `utf8mb4`, which differs between MySQL 8 and
    /// earlier versions and changes how comparisons resolve.
    public var defaultCollationForUTF8MB4: UInt16?
    /// Databases the statement touched, when the server recorded them.
    public var updatedDatabases: [String] = []

    public init() {}

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.timeZone == rhs.timeZone && lhs.sqlMode == rhs.sqlMode
            && lhs.autoIncrement?.increment == rhs.autoIncrement?.increment
            && lhs.autoIncrement?.offset == rhs.autoIncrement?.offset
            && lhs.charset?.client == rhs.charset?.client
            && lhs.charset?.connection == rhs.charset?.connection
            && lhs.charset?.server == rhs.charset?.server
            && lhs.defaultCollationForUTF8MB4 == rhs.defaultCollationForUTF8MB4
            && lhs.updatedDatabases == rhs.updatedDatabases
    }

    /// Parses the status-variable block.
    ///
    /// Lengths are cross-checked against `rust-mysql-common`'s table. An
    /// unrecognised key stops parsing rather than guessing a length: the entries
    /// are packed end to end, so a wrong length silently misaligns every
    /// variable after it.
    static func parse(_ buffer: inout ByteBuffer) -> MySQLQueryStatusVariables {
        var result = MySQLQueryStatusVariables()

        func readVarString(extra: Int) -> String? {
            guard let length = buffer.readInteger(as: UInt8.self),
                  let text = buffer.readString(length: Int(length)) else { return nil }
            buffer.moveReaderIndex(forwardBy: min(extra, buffer.readableBytes))
            return text
        }

        loop: while let key = buffer.readInteger(as: UInt8.self) {
            switch key {
            case 0x00:                                            // FLAGS2
                guard buffer.readSlice(length: 4) != nil else { break loop }
            case 0x01:                                            // SQL_MODE
                guard let mode = buffer.readInteger(endianness: .little, as: UInt64.self)
                else { break loop }
                result.sqlMode = mode
            case 0x02:                                            // CATALOG (NUL-suffixed)
                guard readVarString(extra: 1) != nil else { break loop }
            case 0x03:                                            // AUTO_INCREMENT
                guard let increment = buffer.readInteger(endianness: .little, as: UInt16.self),
                      let offset = buffer.readInteger(endianness: .little, as: UInt16.self)
                else { break loop }
                result.autoIncrement = (increment, offset)
            case 0x04:                                            // CHARSET
                guard let client = buffer.readInteger(endianness: .little, as: UInt16.self),
                      let connection = buffer.readInteger(endianness: .little, as: UInt16.self),
                      let server = buffer.readInteger(endianness: .little, as: UInt16.self)
                else { break loop }
                result.charset = (client, connection, server)
            case 0x05:                                            // TIME_ZONE
                guard let zone = readVarString(extra: 0) else { break loop }
                result.timeZone = zone
            case 0x06:                                            // CATALOG_NZ
                guard readVarString(extra: 0) != nil else { break loop }
            case 0x07, 0x08:                                      // LC_TIME_NAMES, CHARSET_DB
                guard buffer.readSlice(length: 2) != nil else { break loop }
            case 0x09:                                            // TABLE_MAP_FOR_UPDATE
                guard buffer.readSlice(length: 8) != nil else { break loop }
            case 0x0A:                                            // MASTER_DATA_WRITTEN
                guard buffer.readSlice(length: 4) != nil else { break loop }
            case 0x0B:                                            // INVOKER: user then host
                guard readVarString(extra: 0) != nil,
                      readVarString(extra: 0) != nil else { break loop }
            case 0x0C:                                            // UPDATED_DB_NAMES
                guard let count = buffer.readInteger(as: UInt8.self) else { break loop }
                // A count of 254 is OVER_MAX_DBS_IN_EVENT_MTS: the server gave
                // up listing them, and no names follow.
                if count == 254 { break }
                for _ in 0..<count {
                    var name = ""
                    while let byte = buffer.readInteger(as: UInt8.self), byte != 0 {
                        name.append(Character(UnicodeScalar(byte)))
                    }
                    result.updatedDatabases.append(name)
                }
            case 0x0D:                                            // MICROSECONDS
                guard buffer.readSlice(length: 3) != nil else { break loop }
            case 0x0E, 0x0F:                                      // COMMIT_TS, COMMIT_TS2
                break
            case 0x10:                                            // EXPLICIT_DEFAULTS_FOR_TIMESTAMP
                guard buffer.readSlice(length: 1) != nil else { break loop }
            case 0x11:                                            // DDL_LOGGED_WITH_XID
                guard buffer.readSlice(length: 8) != nil else { break loop }
            case 0x12:                                            // DEFAULT_COLLATION_FOR_UTF8MB4
                guard let collation = buffer.readInteger(endianness: .little, as: UInt16.self)
                else { break loop }
                result.defaultCollationForUTF8MB4 = collation
            case 0x13, 0x14:                                      // REQUIRE_PK, TABLE_ENCRYPTION
                guard buffer.readSlice(length: 1) != nil else { break loop }
            default:
                break loop
            }
        }
        return result
    }
}

/// A GTID, in whichever dialect the server speaks.
///
/// The two families are genuinely different — MySQL identifies a source by UUID,
/// MariaDB by a numeric domain and server id — so flattening them into one
/// shape would lose information a consumer needs to resume correctly.
public enum MySQLGtid: Sendable {
    case mysql(uuid: String, sequence: UInt64)
    case mariaDB(domainID: UInt32, serverID: UInt32, sequence: UInt64)

    /// The form the server accepts when resuming a stream.
    public var text: String {
        switch self {
        case .mysql(let uuid, let sequence): "\(uuid):\(sequence)"
        case .mariaDB(let domain, let server, let sequence): "\(domain)-\(server)-\(sequence)"
        }
    }
}

/// `TABLE_MAP_EVENT` — the schema every subsequent row event refers to by id.
///
/// Row events carry no column names or types of their own; they cite a table id
/// and the decoder is expected to have remembered the map. Losing one makes the
/// following row events undecodable, so the decoder holds them well past the
/// transaction that introduced them — bounded as described on `tableMapOrder`.
public struct MySQLTableMapEvent: Sendable {
    public var tableID: UInt64
    public var schema: String
    public var table: String
    public var columnTypes: [UInt8]
    /// Per-column type metadata: lengths for strings, precision for decimals,
    /// fractional-second precision for temporals.
    public var columnMetadata: [UInt16]
    public var nullableColumns: [Bool]

    public var columnCount: Int { columnTypes.count }
}

/// A single change to one JSON document, from a partial update.
///
/// MySQL emits these instead of a full after-image when
/// `binlog_row_value_options=PARTIAL_JSON` is set: rewriting one field of a
/// large document then costs a diff rather than the whole document.
public struct MySQLJSONDiff: Sendable {
    public enum Operation: UInt8, Sendable {
        case replace = 0
        case insert = 1
        case remove = 2
    }

    public var operation: Operation
    /// A MySQL JSON path, e.g. `$.name` or `$.items[2]`.
    public var path: String
    /// The new value as JSON text. `nil` for `remove`.
    public var value: String?
}

public struct MySQLRowsEvent: Sendable {
    public enum Kind: Sendable { case write, update, delete }

    public var kind: Kind
    public var tableID: UInt64
    public var flags: UInt16
    /// Table map in force when this event was decoded, carried along so a
    /// consumer never has to correlate by id itself.
    public var table: MySQLTableMapEvent
    /// For `write` the inserted rows; for `delete` the removed rows; for
    /// `update` the *before* images.
    public var rows: [[MySQLValue]]
    /// `update` only: the *after* images, positionally paired with `rows`.
    public var updatedRows: [[MySQLValue]]

    /// Partial JSON updates, keyed by row index then column index.
    ///
    /// Present only for `PARTIAL_UPDATE_ROWS_EVENT`. Where a column has diffs,
    /// the corresponding entry in `updatedRows` is `.null` — the server sent a
    /// diff *instead of* a value, so there is no after-image to report.
    ///
    /// The diffs are surfaced rather than applied. Applying them needs a JSON
    /// path evaluator and a mutable document model, and a consumer that wants
    /// the resulting document can rebuild it from `rows` (the full before-image)
    /// plus these — whereas a consumer forwarding changes downstream usually
    /// wants the diffs themselves. Guessing wrong in the driver would discard
    /// information that cannot be recovered.
    public var jsonDiffs: [Int: [Int: [MySQLJSONDiff]]] = [:]

    /// Set on the last row event of a statement.
    public var isEndOfStatement: Bool { flags & 0x0001 != 0 }
}

/// One decoded event.
public struct MySQLBinlogEvent: Sendable {
    public var header: MySQLBinlogEventHeader
    public var payload: Payload

    public enum Payload: Sendable {
        case formatDescription(MySQLFormatDescriptionEvent)
        case rotate(MySQLRotateEvent)
        case query(MySQLQueryEvent)
        /// Transaction commit; the value is the XID.
        case xid(UInt64)
        case tableMap(MySQLTableMapEvent)
        case rows(MySQLRowsEvent)
        case gtid(MySQLGtid)
        /// Keep-alive. Carries no data and does not advance the log position.
        case heartbeat
        case stop
        /// Recognised on the wire but not decoded — see
        /// `MySQLBinlogEventDecoder` for what is deliberately left raw.
        case other(MySQLRawBinlogEvent)
    }

    public var eventType: MySQLBinlogEventType? { header.eventType }
}

// MARK: - Decoder

/// Turns event packets into decoded events, carrying the state that makes it
/// possible.
///
/// Three pieces of state, none optional:
///
/// - **the checksum algorithm**, which is not known until the
///   `FORMAT_DESCRIPTION_EVENT` arrives and can change at a `ROTATE`;
/// - **the table maps**, without which row events cannot be decoded at all;
/// - **the current filename and position**, so a consumer can record where to
///   resume.
public struct MySQLBinlogEventDecoder: Sendable {

    public private(set) var checksum: MySQLBinlogChecksum = .none
    public private(set) var tableMaps: [UInt64: MySQLTableMapEvent] = [:]
    public private(set) var currentFilename: String = ""
    public private(set) var currentPosition: UInt32 = 4

    /// Insertion order of `tableMaps`, so the oldest can be evicted.
    ///
    /// A table's ID is not stable: the server assigns it when the table
    /// definition enters its cache, so a table that gets evicted and reopened
    /// comes back under a *new* ID. A long-running CDC consumer against a server
    /// with definition-cache churn therefore accumulates dead entries forever —
    /// each holding the table's full column list. Nothing in the protocol ever
    /// tells us an ID is dead.
    ///
    /// The reference has the same problem and bounds it by clearing on rotate,
    /// with the comment *"we'll keep table map size within reasonable bounds —
    /// TODO: This value is arbitrary"*. We clear on rotate too, but a rotate is
    /// driven by `max_binlog_size` (1 GB by default), so on a low-traffic server
    /// with many tables it may be hours apart. The bound below is what actually
    /// makes the growth impossible.
    private var tableMapOrder: [UInt64] = []

    /// Eviction happens strictly by insertion order rather than by use, because
    /// the access pattern makes them equivalent: the server writes a `TABLE_MAP`
    /// immediately before the row events that need it, so the newest entries are
    /// exactly the live ones.
    ///
    /// Sized far above any real statement's needs — MySQL's own join limit is 61
    /// tables — so eviction can only ever reach maps no longer referenced.
    static let tableMapLimit = 1024

    public init() {}

    private mutating func remember(_ map: MySQLTableMapEvent) {
        if tableMaps.updateValue(map, forKey: map.tableID) == nil {
            tableMapOrder.append(map.tableID)
            if tableMapOrder.count > Self.tableMapLimit {
                tableMaps.removeValue(forKey: tableMapOrder.removeFirst())
            }
        }
    }

    private mutating func forgetTableMaps() {
        tableMaps.removeAll(keepingCapacity: false)
        tableMapOrder.removeAll(keepingCapacity: false)
    }

    /// Decodes one event packet into **one or more** events.
    ///
    /// Almost always one — but a `TRANSACTION_PAYLOAD_EVENT` is a container: an
    /// entire transaction (table maps, row events, the XID) compressed into a
    /// single event. Expanding it here rather than surfacing the container is
    /// what keeps a consumer from silently receiving no row changes at all when
    /// `binlog_transaction_compression` is on.
    public mutating func decode(intoEvents payload: ByteBuffer) throws -> [MySQLBinlogEvent] {
        let peeked = payload.getInteger(at: payload.readerIndex + 4, as: UInt8.self)
        guard peeked == MySQLBinlogEventType.transactionPayload.rawValue else {
            return [try decode(payload)]
        }

        let raw = try MySQLBinlogFraming.parseEvent(payload, checksum: checksum)
        let inner = try Self.unwrapTransactionPayload(raw)

        // The events inside carry no checksum of their own — the container's
        // covered them — so they are decoded with checksumming off regardless of
        // what the stream is using.
        let outerChecksum = checksum
        checksum = .none
        defer { checksum = outerChecksum }

        var events: [MySQLBinlogEvent] = []
        var buffer = inner
        while buffer.readableBytes >= MySQLBinlogEventHeader.byteCount {
            guard let size = buffer.getInteger(
                at: buffer.readerIndex + 9, endianness: .little, as: UInt32.self
            ), size >= UInt32(MySQLBinlogEventHeader.byteCount),
               buffer.readableBytes >= Int(size),
               let slice = buffer.readSlice(length: Int(size))
            else { break }
            events.append(try decode(slice))
        }
        return events
    }

    /// Reads the TLV header of a `TRANSACTION_PAYLOAD_EVENT` and returns the
    /// decompressed inner event stream.
    ///
    /// ```
    /// repeated: lenenc type, lenenc length, value   until type == 0
    ///   1 = payload size   2 = compression type   3 = uncompressed size
    /// then: the payload itself, to the end of the event
    /// ```
    ///
    /// Compression type 0 is zstd — the only one MySQL emits — and 255 is
    /// uncompressed.
    static func unwrapTransactionPayload(_ raw: MySQLRawBinlogEvent) throws -> ByteBuffer {
        var body = raw.body
        var algorithm: UInt64 = 255
        var uncompressedSize = 0

        loop: while body.readableBytes > 0 {
            guard let field = body.readLengthEncodedInteger() else { break }
            switch field {
            case 0:
                break loop                                    // header end mark
            case 1:
                guard let length = body.readLengthEncodedInteger() else { break loop }
                // The conversion has to happen after the clamp: Int() traps
                // above Int64.max and the peer chooses this length.
                body.moveReaderIndex(forwardBy: Int(min(length, UInt64(body.readableBytes))))
            case 2:
                guard body.readLengthEncodedInteger() != nil,
                      let value = body.readLengthEncodedInteger() else { break loop }
                algorithm = value
            case 3:
                guard body.readLengthEncodedInteger() != nil,
                      let value = body.readLengthEncodedInteger() else { break loop }
                guard value <= UInt64(Int32.max) else { break loop }
                uncompressedSize = Int(value)
            default:
                guard let length = body.readLengthEncodedInteger() else { break loop }
                // The conversion has to happen after the clamp: Int() traps
                // above Int64.max and the peer chooses this length.
                body.moveReaderIndex(forwardBy: Int(min(length, UInt64(body.readableBytes))))
            }
        }

        guard let payload = body.readBytes(length: body.readableBytes) else {
            throw MySQLProtocolError.malformedPacket("binlog: empty transaction payload")
        }

        switch algorithm {
        case 255:
            var out = ByteBuffer()
            out.writeBytes(payload)
            return out
        case 0:
            let plain = try MySQLCompression.decompressZstd(
                payload, expectedCount: uncompressedSize
            )
            var out = ByteBuffer()
            out.writeBytes(plain)
            return out
        default:
            throw MySQLProtocolError.malformedPacket(
                "binlog: unknown transaction payload compression \(algorithm)"
            )
        }
    }

    /// Decodes one event packet, whose leading `0x00` marker has been stripped.
    public mutating func decode(_ payload: ByteBuffer) throws -> MySQLBinlogEvent {
        // The format-description event announces the checksum algorithm in its
        // own body, so it cannot be parsed with a checksum already known — the
        // classic bootstrap. It is detected by peeking at the type byte before
        // any stripping happens.
        let peekedType = payload.getInteger(
            at: payload.readerIndex + 4, as: UInt8.self
        )
        let isFormatDescription = peekedType == MySQLBinlogEventType.formatDescription.rawValue

        let raw = try MySQLBinlogFraming.parseEvent(
            payload, checksum: isFormatDescription ? .none : checksum
        )

        // Heartbeats are synthetic and do not correspond to a real log offset,
        // so advancing on them would make a resume position drift forward past
        // events that were never delivered.
        if raw.header.logPosition > 0, raw.eventType != .heartbeat {
            currentPosition = raw.header.logPosition
        }

        switch raw.eventType {
        case .formatDescription:
            let event = try decodeFormatDescription(raw)
            checksum = event.checksum
            return MySQLBinlogEvent(header: raw.header, payload: .formatDescription(event))

        case .rotate:
            let event = try decodeRotate(raw)
            currentFilename = event.nextFilename
            currentPosition = UInt32(truncatingIfNeeded: event.position)
            // A real rotate means the next file opens with fresh table maps, so
            // everything held is dead. The artificial rotate a server synthesises
            // at the start of a dump is *not* a boundary — it describes where we
            // are about to start reading, and clearing there would be harmless
            // but is skipped for the same reason it is not counted as progress.
            if !raw.header.isArtificial { forgetTableMaps() }
            return MySQLBinlogEvent(header: raw.header, payload: .rotate(event))

        case .query:
            return MySQLBinlogEvent(header: raw.header, payload: .query(try decodeQuery(raw)))

        case .xid:
            var body = raw.body
            guard let xid = body.readInteger(endianness: .little, as: UInt64.self) else {
                throw MySQLProtocolError.malformedPacket("binlog: truncated XID event")
            }
            return MySQLBinlogEvent(header: raw.header, payload: .xid(xid))

        case .tableMap:
            let map = try decodeTableMap(raw)
            remember(map)
            return MySQLBinlogEvent(header: raw.header, payload: .tableMap(map))

        case .writeRows, .updateRows, .deleteRows,
             .writeRowsV1, .updateRowsV1, .deleteRowsV1, .partialUpdateRows,
             .mariaDBWriteRowsCompressedV1, .mariaDBUpdateRowsCompressedV1,
             .mariaDBDeleteRowsCompressedV1, .mariaDBWriteRowsCompressed,
             .mariaDBUpdateRowsCompressed, .mariaDBDeleteRowsCompressed:
            return MySQLBinlogEvent(header: raw.header, payload: .rows(try decodeRows(raw)))

        case .mariaDBQueryCompressed:
            return MySQLBinlogEvent(header: raw.header, payload: .query(try decodeQuery(raw)))

        case .gtid:
            return MySQLBinlogEvent(header: raw.header, payload: .gtid(try decodeMySQLGtid(raw)))

        case .mariaDBGtid:
            return MySQLBinlogEvent(header: raw.header, payload: .gtid(try decodeMariaDBGtid(raw)))

        case .transactionPayload:
            // Handled by `decode(intoEvents:)`; reaching here means a caller used
            // the single-event entry point, which cannot express one packet
            // expanding into many.
            return MySQLBinlogEvent(header: raw.header, payload: .other(raw))

        case .heartbeat:
            return MySQLBinlogEvent(header: raw.header, payload: .heartbeat)

        case .stop:
            return MySQLBinlogEvent(header: raw.header, payload: .stop)

        default:
            // Deliberately raw, with the header intact so a consumer can still
            // see type, timestamp and position:
            //   - JSON partial updates and `PARTIAL_UPDATE_ROWS_EVENT`
            //   - `TRANSACTION_PAYLOAD_EVENT` (compressed transactions)
            //   - the LOAD DATA family
            //   - MariaDB's compressed row events
            // Each is a self-contained addition; none blocks ordinary CDC.
            return MySQLBinlogEvent(header: raw.header, payload: .other(raw))
        }
    }

    // MARK: - Individual events

    private func decodeFormatDescription(
        _ raw: MySQLRawBinlogEvent
    ) throws -> MySQLFormatDescriptionEvent {
        var body = raw.body
        guard let binlogVersion = body.readInteger(endianness: .little, as: UInt16.self),
              let versionBytes = body.readBytes(length: 50),
              let createTimestamp = body.readInteger(endianness: .little, as: UInt32.self),
              let headerLength = body.readInteger(as: UInt8.self)
        else {
            throw MySQLProtocolError.malformedPacket("binlog: truncated format description")
        }

        let serverVersion = String(
            decoding: versionBytes.prefix { $0 != 0 }, as: UTF8.self
        )

        // The checksum algorithm is the byte immediately before the 4-byte
        // checksum, i.e. five from the end of the whole event. Servers older
        // than 5.6.1 have no such byte, in which case the remaining bytes are
        // all post-header lengths and checksums are off.
        var algorithm = MySQLBinlogChecksum.none
        if body.readableBytes >= 5 {
            let position = body.readerIndex + body.readableBytes - 5
            if let value = body.getInteger(at: position, as: UInt8.self),
               let parsed = MySQLBinlogChecksum(rawValue: value) {
                algorithm = parsed
            }
        }

        return MySQLFormatDescriptionEvent(
            binlogVersion: binlogVersion,
            serverVersion: serverVersion,
            createTimestamp: createTimestamp,
            headerLength: headerLength,
            checksum: algorithm
        )
    }

    private func decodeRotate(_ raw: MySQLRawBinlogEvent) throws -> MySQLRotateEvent {
        var body = raw.body
        guard let position = body.readInteger(endianness: .little, as: UInt64.self) else {
            throw MySQLProtocolError.malformedPacket("binlog: truncated rotate event")
        }
        let name = body.readString(length: body.readableBytes) ?? ""
        return MySQLRotateEvent(position: position, nextFilename: name)
    }

    /// MariaDB's compression header, used by `log_bin_compress=ON`.
    ///
    /// One byte whose top three bits are `100` (zlib — the only algorithm
    /// defined) and whose low three bits give the *width* of the
    /// uncompressed-length field that follows. Then that many **big-endian**
    /// bytes of length, then a zlib stream.
    ///
    /// Big-endian is the trap. Almost everything else in this protocol is
    /// little-endian, and MariaDB's own `binlog_get_uncompress_len` shifts the
    /// bytes down from the high end. Reading it little-endian works perfectly
    /// for any payload under 256 bytes — where the field is a single byte and
    /// endianness cannot show — and then silently reverses the length on the
    /// first larger one. A 70 KB JSON document is what exposed it.
    ///
    /// Only the variable-length tail is compressed. The event's post-header,
    /// column count and column bitmaps stay in the clear, which is why the
    /// callers below parse those first and only then hand the remainder here.
    static func decompressTail(_ buffer: inout ByteBuffer) throws -> ByteBuffer {
        guard let marker = buffer.readInteger(as: UInt8.self) else {
            throw MySQLProtocolError.malformedPacket("binlog: missing compression header")
        }
        guard marker & 0xE0 == 0x80 else {
            throw MySQLProtocolError.malformedPacket(
                "binlog: unknown compression algorithm 0x\(String(marker, radix: 16))"
            )
        }
        let widthOfLength = Int(marker & 0x07)
        guard widthOfLength >= 1, widthOfLength <= 4,
              let lengthBytes = buffer.readBytes(length: widthOfLength)
        else {
            throw MySQLProtocolError.malformedPacket("binlog: bad compressed length field")
        }
        var uncompressedLength = 0
        for byte in lengthBytes {
            uncompressedLength = (uncompressedLength << 8) | Int(byte)
        }

        guard let compressed = buffer.readBytes(length: buffer.readableBytes) else {
            throw MySQLProtocolError.malformedPacket("binlog: truncated compressed payload")
        }
        let plain = try MySQLCompression.decompress(
            compressed, expectedCount: uncompressedLength
        )

        var out = ByteBuffer()
        out.writeBytes(plain)
        return out
    }

    private func decodeQuery(_ raw: MySQLRawBinlogEvent) throws -> MySQLQueryEvent {
        var body = raw.body
        guard let threadID = body.readInteger(endianness: .little, as: UInt32.self),
              let executionTime = body.readInteger(endianness: .little, as: UInt32.self),
              let schemaLength = body.readInteger(as: UInt8.self),
              let errorCode = body.readInteger(endianness: .little, as: UInt16.self),
              let statusLength = body.readInteger(endianness: .little, as: UInt16.self)
        else {
            throw MySQLProtocolError.malformedPacket("binlog: truncated query event")
        }
        // Status variables carry the session context the statement ran under.
        // Parsed from an isolated slice so a malformed entry cannot run past the
        // block and eat the schema name after it.
        var statusVariables = MySQLQueryStatusVariables()
        let statusBytes = min(Int(statusLength), body.readableBytes)
        if var statusSlice = body.readSlice(length: statusBytes) {
            statusVariables = MySQLQueryStatusVariables.parse(&statusSlice)
        }

        let schema = body.readString(length: min(Int(schemaLength), body.readableBytes)) ?? ""
        body.moveReaderIndex(forwardBy: min(1, body.readableBytes))   // NUL terminator

        // Under `log_bin_compress` the statement text is deflated; everything
        // before it is not.
        if raw.eventType == .mariaDBQueryCompressed {
            body = try Self.decompressTail(&body)
        }
        let query = body.readString(length: body.readableBytes) ?? ""

        return MySQLQueryEvent(
            threadID: threadID,
            executionTime: executionTime,
            errorCode: errorCode,
            schema: schema,
            query: query,
            statusVariables: statusVariables
        )
    }

    private func decodeMySQLGtid(_ raw: MySQLRawBinlogEvent) throws -> MySQLGtid {
        var body = raw.body
        // flags(1) then a 16-byte UUID then an 8-byte sequence number.
        guard body.readableBytes >= 25,
              body.readInteger(as: UInt8.self) != nil,
              let uuid = body.readBytes(length: 16),
              let sequence = body.readInteger(endianness: .little, as: UInt64.self)
        else {
            throw MySQLProtocolError.malformedPacket("binlog: truncated GTID event")
        }
        return .mysql(uuid: Self.formatUUID(uuid), sequence: sequence)
    }

    private func decodeMariaDBGtid(_ raw: MySQLRawBinlogEvent) throws -> MySQLGtid {
        var body = raw.body
        guard let sequence = body.readInteger(endianness: .little, as: UInt64.self),
              let domain = body.readInteger(endianness: .little, as: UInt32.self)
        else {
            throw MySQLProtocolError.malformedPacket("binlog: truncated MariaDB GTID event")
        }
        // The server id is the event header's, not a body field.
        return .mariaDB(domainID: domain, serverID: raw.header.serverID, sequence: sequence)
    }

    static func formatUUID(_ bytes: [UInt8]) -> String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
        return groups.map { range in
            String(hex[hex.index(hex.startIndex, offsetBy: range.lowerBound)
                        ..< hex.index(hex.startIndex, offsetBy: range.upperBound)])
        }.joined(separator: "-")
    }

    private func decodeTableMap(_ raw: MySQLRawBinlogEvent) throws -> MySQLTableMapEvent {
        var body = raw.body
        // Table id is six bytes, not eight — one of the easier things to get
        // wrong, and it shifts every subsequent field.
        guard let low = body.readInteger(endianness: .little, as: UInt32.self),
              let high = body.readInteger(endianness: .little, as: UInt16.self),
              body.readInteger(endianness: .little, as: UInt16.self) != nil   // flags
        else {
            throw MySQLProtocolError.malformedPacket("binlog: truncated table map")
        }
        let tableID = UInt64(low) | (UInt64(high) << 32)

        guard let schemaLength = body.readInteger(as: UInt8.self),
              let schema = body.readString(length: Int(schemaLength)),
              body.readInteger(as: UInt8.self) != nil,                        // NUL
              let tableLength = body.readInteger(as: UInt8.self),
              let table = body.readString(length: Int(tableLength)),
              body.readInteger(as: UInt8.self) != nil                         // NUL
        else {
            throw MySQLProtocolError.malformedPacket("binlog: truncated table map names")
        }

        guard let columnCount = body.readLengthEncodedInteger(),
              let types = body.readBytes(length: Int(columnCount))
        else {
            throw MySQLProtocolError.malformedPacket("binlog: truncated table map columns")
        }

        guard let metadataLength = body.readLengthEncodedInteger(),
              var metadata = body.readSlice(length: Int(metadataLength))
        else {
            throw MySQLProtocolError.malformedPacket("binlog: truncated table map metadata")
        }
        let columnMetadata = try Self.parseColumnMetadata(&metadata, types: types)

        let bitmapBytes = (Int(columnCount) + 7) / 8
        guard let nullBitmap = body.readBytes(length: bitmapBytes) else {
            throw MySQLProtocolError.malformedPacket("binlog: truncated table map null bitmap")
        }
        let nullable = (0..<Int(columnCount)).map { index in
            nullBitmap[index / 8] & (1 << UInt8(index % 8)) != 0
        }

        // Anything after this is optional metadata (column names, enum values,
        // charsets) which MariaDB emits under `binlog_row_metadata=FULL`.
        // Left unparsed for now — it is additive and nothing above depends on it.

        return MySQLTableMapEvent(
            tableID: tableID,
            schema: schema,
            table: table,
            columnTypes: types,
            columnMetadata: columnMetadata,
            nullableColumns: nullable
        )
    }

    /// Per-column metadata is variable-width by type, which is why it cannot be
    /// read as a flat array.
    ///
    /// - Parameter isArray: set when the type came from a `MYSQL_TYPE_TYPED_ARRAY`
    ///   wrapper, where `VARCHAR` carries **three** metadata bytes rather than two.
    static func parseColumnMetadata(
        _ buffer: inout ByteBuffer, types: [UInt8], isArray: Bool = false
    ) throws -> [UInt16] {
        var result = [UInt16]()
        result.reserveCapacity(types.count)

        for type in types {
            guard let column = MySQLColumnType(rawValue: type) else {
                result.append(0)
                continue
            }
            switch column {
            case .string, .newdecimal, .enumeration, .set:
                // Two bytes, big-endian-ish packing for STRING (real type +
                // length); kept raw and interpreted at decode time.
                //
                // ENUM and SET share that layout and are listed for the same
                // reason rust-mysql-common lists them: in practice a server
                // writes them as STRING with the real type folded into the
                // metadata, but a *raw* ENUM here with no metadata read would
                // shift every following column's metadata by two bytes.
                let a = buffer.readInteger(as: UInt8.self) ?? 0
                let b = buffer.readInteger(as: UInt8.self) ?? 0
                result.append(UInt16(a) << 8 | UInt16(b))
            case .varchar, .varString, .bit:
                result.append(buffer.readInteger(endianness: .little, as: UInt16.self) ?? 0)
                // Inside a typed array a VARCHAR carries a third byte. Left out
                // of the value, since nothing decodes typed arrays; read so the
                // next column's metadata still starts where the server put it.
                if isArray, column == .varchar { _ = buffer.readInteger(as: UInt8.self) }
            case .float, .double, .blob, .tinyBlob, .mediumBlob, .longBlob,
                 .geometry, .json, .time2, .datetime2, .timestamp2, .vector:
                // `vector` is MySQL 9's, and it is metadata-carrying like a blob:
                // one byte giving the width of the length prefix. Omitting it
                // desynchronised every column after a VECTOR one.
                result.append(UInt16(buffer.readInteger(as: UInt8.self) ?? 0))
            case .typedArray:
                // A wrapper: one byte naming the element type, then that type's
                // own metadata. Nothing decodes typed array *values* — they are
                // replication-internal, for multi-valued indexes — but the bytes
                // still have to be consumed, or every column after one is read
                // from the wrong offset.
                let elementType = buffer.readInteger(as: UInt8.self) ?? 0
                let inner = try parseColumnMetadata(
                    &buffer, types: [elementType], isArray: true
                )
                result.append(inner.first ?? 0)
            default:
                result.append(0)
            }
        }
        return result
    }

    private func decodeRows(_ raw: MySQLRawBinlogEvent) throws -> MySQLRowsEvent {
        var body = raw.body

        guard let low = body.readInteger(endianness: .little, as: UInt32.self),
              let high = body.readInteger(endianness: .little, as: UInt16.self),
              let flags = body.readInteger(endianness: .little, as: UInt16.self)
        else {
            throw MySQLProtocolError.malformedPacket("binlog: truncated rows event")
        }
        let tableID = UInt64(low) | (UInt64(high) << 32)

        let type = raw.eventType
        let isCompressed: Bool
        switch type {
        case .mariaDBWriteRowsCompressedV1, .mariaDBUpdateRowsCompressedV1,
             .mariaDBDeleteRowsCompressedV1, .mariaDBWriteRowsCompressed,
             .mariaDBUpdateRowsCompressed, .mariaDBDeleteRowsCompressed:
            isCompressed = true
        default:
            isCompressed = false
        }

        // `PARTIAL_UPDATE_ROWS_EVENT` is v2-shaped: same extra-data block.
        //
        // The three MariaDB *compressed* constants here are the non-V1 forms,
        // and no fixture produces one: with `log_bin_compress` ON, MariaDB
        // 11.4–12.3 emit the **V1** variants, which are correctly excluded.
        // Measured, not assumed — removing the last disjunct leaves the whole
        // suite green, including the compressed-delete integration test. So no
        // test can kill a mutation of it, and the honest reason is that the
        // event does not occur here rather than that nothing looks.
        let isV2 = type == .writeRows || type == .updateRows || type == .deleteRows
            || type == .partialUpdateRows
            || type == .mariaDBWriteRowsCompressed || type == .mariaDBUpdateRowsCompressed
            || type == .mariaDBDeleteRowsCompressed
        if isV2 {
            // v2 adds an extra-data block the v1 events do not have. The length
            // counts itself, hence the −2.
            guard let extraLength = body.readInteger(endianness: .little, as: UInt16.self) else {
                throw MySQLProtocolError.malformedPacket("binlog: truncated rows extra data")
            }
            body.moveReaderIndex(forwardBy: min(max(Int(extraLength) - 2, 0), body.readableBytes))
        }

        guard let columnCount = body.readLengthEncodedInteger() else {
            throw MySQLProtocolError.malformedPacket("binlog: truncated rows column count")
        }
        let bitmapBytes = (Int(columnCount) + 7) / 8

        guard let beforeBitmap = body.readBytes(length: bitmapBytes) else {
            throw MySQLProtocolError.malformedPacket("binlog: truncated rows column bitmap")
        }

        let kind: MySQLRowsEvent.Kind
        var afterBitmap: [UInt8]?
        switch type {
        case .writeRows, .writeRowsV1,
             .mariaDBWriteRowsCompressedV1, .mariaDBWriteRowsCompressed:
            kind = .write
        case .deleteRows, .deleteRowsV1,
             .mariaDBDeleteRowsCompressedV1, .mariaDBDeleteRowsCompressed:
            kind = .delete
        case .updateRows, .updateRowsV1, .partialUpdateRows,
             .mariaDBUpdateRowsCompressedV1, .mariaDBUpdateRowsCompressed:
            kind = .update
            guard let second = body.readBytes(length: bitmapBytes) else {
                throw MySQLProtocolError.malformedPacket("binlog: truncated update after-bitmap")
            }
            afterBitmap = second
        default:
            throw MySQLProtocolError.unexpectedPacket("binlog: not a rows event")
        }

        guard let map = tableMaps[tableID] else {
            // Without the table map the bytes are undecodable. This happens if a
            // stream is resumed mid-transaction, so it is reported rather than
            // guessed at.
            throw MySQLProtocolError.malformedPacket(
                "binlog: no TABLE_MAP for table id \(tableID) — resumed mid-transaction?"
            )
        }

        // The rows section — and only that — is deflated. Doing this after the
        // bitmaps is what the wire layout requires: compressing them too would
        // have made the column count unreadable without first decompressing,
        // which is not how MariaDB frames it.
        if isCompressed {
            body = try Self.decompressTail(&body)
        }

        var rows: [[MySQLValue]] = []
        var updated: [[MySQLValue]] = []
        var diffs: [Int: [Int: [MySQLJSONDiff]]] = [:]

        // One bit per *JSON* column, not per column.
        let jsonColumnCount = map.columnTypes
            .filter { $0 == MySQLColumnType.json.rawValue }.count
        let partialBitmapBytes = (jsonColumnCount + 7) / 8

        while body.readableBytes > 0 {
            // **A row must consume bytes.** `decodeRow` legitimately reads
            // nothing when no column is present — a zero column count, or a
            // present-bitmap with no bits set, makes the null bitmap zero bytes
            // wide and the per-column loop empty. Both numbers come off the
            // wire, so a peer can choose them, and without this the loop spins
            // forever appending empty rows: a hang and an unbounded allocation
            // from one malformed event, on the one client that must not die.
            let progressMark = body.readerIndex
            let before = try MySQLBinlogRowDecoder.decodeRow(
                &body, table: map, presentColumns: beforeBitmap, columnCount: Int(columnCount)
            )
            let rowIndex = rows.count
            rows.append(before)

            if let afterBitmap {
                guard body.readableBytes > 0 else { break }

                // `value_options` and the partial bitmap precede **each**
                // after-image, not the event as a whole — established from the
                // wire, since no reference client parses this. Placing them in
                // the event header instead mis-frames the first row.
                var partialBits: [UInt8] = []
                if type == .partialUpdateRows {
                    guard let options = body.readLengthEncodedInteger() else {
                        throw MySQLProtocolError.malformedPacket(
                            "binlog: truncated value_options"
                        )
                    }
                    // Bit 0 is PARTIAL_JSON_UPDATES. When clear, the after-image
                    // is an ordinary full row even though the event type says
                    // partial — MySQL falls back whenever a diff would not be
                    // smaller than the document.
                    if options & 1 != 0, partialBitmapBytes > 0 {
                        guard let bits = body.readBytes(length: partialBitmapBytes) else {
                            throw MySQLProtocolError.malformedPacket(
                                "binlog: truncated partial-JSON bitmap"
                            )
                        }
                        partialBits = bits
                    }
                }

                let after = try MySQLBinlogRowDecoder.decodeRow(
                    &body, table: map, presentColumns: afterBitmap,
                    columnCount: Int(columnCount),
                    partialJSONColumns: partialBits,
                    onJSONDiff: { column, columnDiffs in
                        diffs[rowIndex, default: [:]][column] = columnDiffs
                    }
                )
                updated.append(after)
            }

            guard body.readerIndex > progressMark else {
                throw MySQLProtocolError.malformedPacket(
                    "binlog: rows event makes no progress — \(columnCount) columns, "
                        + "no column present in the image"
                )
            }
        }
        return MySQLRowsEvent(
            kind: kind,
            tableID: tableID,
            flags: flags,
            table: map,
            rows: rows,
            updatedRows: updated,
            jsonDiffs: diffs
        )
    }
}

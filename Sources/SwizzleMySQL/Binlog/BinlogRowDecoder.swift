import NIOCore

/// Decodes row images out of a row event.
///
/// This is a **third** value encoding, distinct from both the text protocol and
/// the prepared-statement binary protocol. It resembles the binary one, but
/// lengths come from the `TABLE_MAP`'s per-column metadata rather than from the
/// wire, because a row image has no column definitions of its own.
///
/// Two bitmaps govern the layout and are easy to conflate:
///
/// - **presentColumns** comes from the *event* and says which columns were
///   written at all — a partial row image omits the rest entirely.
/// - **the null bitmap** comes from the *row* and is sized to the number of
///   present columns, not the table's column count. Sizing it from the table is
///   the classic bug: it works until a partial image appears.
public enum MySQLBinlogRowDecoder {

    public static func decodeRow(
        _ buffer: inout ByteBuffer,
        table: MySQLTableMapEvent,
        presentColumns: [UInt8],
        columnCount: Int,
        partialJSONColumns: [UInt8] = [],
        onJSONDiff: ((Int, [MySQLJSONDiff]) -> Void)? = nil
    ) throws -> [MySQLValue] {
        let presentCount = (0..<columnCount).reduce(into: 0) { total, index in
            if presentColumns[index / 8] & (1 << UInt8(index % 8)) != 0 { total += 1 }
        }

        let nullBitmapBytes = (presentCount + 7) / 8
        guard let nullBitmap = buffer.readBytes(length: nullBitmapBytes) else {
            throw MySQLProtocolError.malformedPacket("binlog: truncated row null bitmap")
        }

        var values = [MySQLValue]()
        values.reserveCapacity(columnCount)
        var presentIndex = 0

        for column in 0..<columnCount {
            let isPresent = presentColumns[column / 8] & (1 << UInt8(column % 8)) != 0
            guard isPresent else {
                // Absent from the image entirely — not the same as SQL NULL, but
                // there is no third state in `MySQLValue`, so it reports as null.
                values.append(.null)
                continue
            }

            let isNull = nullBitmap[presentIndex / 8] & (1 << UInt8(presentIndex % 8)) != 0
            presentIndex += 1

            if isNull {
                values.append(.null)
                continue
            }

            let type = column < table.columnTypes.count ? table.columnTypes[column] : 0
            let metadata = column < table.columnMetadata.count ? table.columnMetadata[column] : 0

            // A JSON column flagged partial carries a *diff list* where its
            // document would be. The partial bitmap is indexed by JSON-column
            // ordinal, not by column position, so the two are counted apart.
            if type == MySQLColumnType.json.rawValue, !partialJSONColumns.isEmpty {
                let jsonOrdinal = (0..<column).reduce(into: 0) { total, earlier in
                    if earlier < table.columnTypes.count,
                       table.columnTypes[earlier] == MySQLColumnType.json.rawValue {
                        total += 1
                    }
                }
                let byteIndex = jsonOrdinal / 8
                if byteIndex < partialJSONColumns.count,
                   partialJSONColumns[byteIndex] & (1 << UInt8(jsonOrdinal % 8)) != 0 {
                    onJSONDiff?(
                        column,
                        try decodeJSONDiffs(&buffer, prefixWidth: max(Int(metadata), 1))
                    )
                    // No after-image for this column: the server sent a diff
                    // *instead of* a value, and inventing one would be a lie.
                    values.append(.null)
                    continue
                }
            }

            values.append(try decodeValue(&buffer, type: type, metadata: metadata))
        }

        return values
    }


    /// Narrows an integer, throwing rather than trapping when it does not fit.
    ///
    /// Every packed temporal field below is built from raw bytes the server
    /// sent, so its value is only as trustworthy as the stream. `UInt16(x)`
    /// **traps** when `x` is too large, and a trap in a binlog consumer takes the
    /// process down — the one thing a replication client must never do, because
    /// it is reading a stream it cannot pause and cannot skip.
    ///
    /// This was reachable: a `DATETIME` whose eight bytes are not a valid packed
    /// datetime — a desynchronised stream, or a column type resolved wrongly —
    /// gave `date / 10_000` far above `UInt16.max` and crashed. Found when an
    /// unrelated test suite began writing exotic column types and the binlog
    /// suites, reading the same server's log concurrently, met them.
    ///
    /// Throwing turns that into a decode error the caller already handles.
    static func narrow<Target: FixedWidthInteger, Source: BinaryInteger>(
        _ value: Source, _ field: String
    ) throws -> Target {
        guard let narrowed = Target(exactly: value) else {
            throw MySQLProtocolError.malformedPacket(
                "binlog: \(field) is \(value), which is not a valid value for this field — "
                + "the row event does not match the table map it was decoded against"
            )
        }
        return narrowed
    }

    static func decodeValue(
        _ buffer: inout ByteBuffer, type: UInt8, metadata: UInt16
    ) throws -> MySQLValue {
        var columnType = MySQLColumnType(rawValue: type)
        var length = Int(metadata)

        // MYSQL_TYPE_STRING is overloaded: for ENUM, SET and CHAR the *real*
        // type is packed into the high byte of the metadata and the low byte
        // carries the length. Decoding it as a plain string yields garbage for
        // every ENUM column.
        if columnType == .string, metadata >= 256 {
            let realType = UInt8(metadata >> 8)
            let lengthBits = UInt8(metadata & 0xFF)
            if let resolved = MySQLColumnType(rawValue: realType) {
                columnType = resolved
            }
            length = Int(lengthBits) | ((Int(realType) & 0x30) ^ 0x30) << 4
        }

        func need(_ count: Int) throws -> [UInt8] {
            guard let bytes = buffer.readBytes(length: count) else {
                throw MySQLProtocolError.malformedPacket(
                    "binlog: truncated value of \(count) bytes"
                )
            }
            return bytes
        }

        switch columnType {
        case .tiny:
            return .int(Int64(Int8(bitPattern: try need(1)[0])))

        case .short:
            let bytes = try need(2)
            let raw = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
            return .int(Int64(Int16(bitPattern: raw)))

        case .year:
            // **One** byte, not two. YEAR is a SMALLINT in a result set but a
            // single byte here, holding an offset from 1900 — reading two
            // consumes a byte belonging to the next column and misaligns the
            // rest of the row. Zero means the literal zero year, not 1900.
            let value = Int64(try need(1)[0])
            return .int(value == 0 ? 0 : value + 1900)

        case .int24:
            let bytes = try need(3)
            var raw = Int32(bytes[0]) | (Int32(bytes[1]) << 8) | (Int32(bytes[2]) << 16)
            if raw & 0x80_0000 != 0 { raw -= 0x100_0000 }      // sign-extend 24 bits
            return .int(Int64(raw))

        case .long:
            let bytes = try need(4)
            var raw: UInt32 = 0
            for (index, byte) in bytes.enumerated() { raw |= UInt32(byte) << (8 * index) }
            return .int(Int64(Int32(bitPattern: raw)))

        case .longlong:
            let bytes = try need(8)
            var raw: UInt64 = 0
            for (index, byte) in bytes.enumerated() { raw |= UInt64(byte) << (8 * index) }
            return .int(Int64(bitPattern: raw))

        case .float:
            let bytes = try need(4)
            var raw: UInt32 = 0
            for (index, byte) in bytes.enumerated() { raw |= UInt32(byte) << (8 * index) }
            return .float(Float(bitPattern: raw))

        case .double:
            let bytes = try need(8)
            var raw: UInt64 = 0
            for (index, byte) in bytes.enumerated() { raw |= UInt64(byte) << (8 * index) }
            return .double(Double(bitPattern: raw))

        case .varchar, .varString:
            // One or two length bytes depending on the declared maximum.
            let count: Int
            if length < 256 {
                count = Int(try need(1)[0])
            } else {
                let bytes = try need(2)
                count = Int(bytes[0]) | (Int(bytes[1]) << 8)
            }
            return .bytes(try need(count))

        case .string:
            let count: Int
            if length < 256 {
                count = Int(try need(1)[0])
            } else {
                let bytes = try need(2)
                count = Int(bytes[0]) | (Int(bytes[1]) << 8)
            }
            return .bytes(try need(count))

        // `vector` joins these because MySQL 9 frames it exactly like a blob: a
        // metadata byte giving the width of the length prefix, then that many
        // bytes of payload. Grouped the same way in rust-mysql-common.
        case .blob, .tinyBlob, .mediumBlob, .longBlob, .geometry, .json, .vector:
            // The metadata byte is the *width of the length prefix*, not a
            // length: 1 for TINYBLOB through 4 for LONGBLOB.
            let widthBytes = max(Int(metadata), 1)
            let prefix = try need(widthBytes)
            var count = 0
            for (index, byte) in prefix.enumerated() { count |= Int(byte) << (8 * index) }
            let payload = try need(count)

            // MySQL stores JSON in its binary form; MariaDB stores text. Both
            // report MYSQL_TYPE_JSON here, so the two are told apart by whether
            // the payload actually parses as JSONB — a text document starts with
            // `{`, `[` or a quote, none of which is a valid JSONB type byte
            // (0x00–0x0C, 0x0F).
            if columnType == .json, !payload.isEmpty,
               let text = try? MySQLJSONB.decode(payload) {
                return .bytes(Array(text.utf8))
            }
            return .bytes(payload)

        case .enumeration:
            // Stored as an index, one or two bytes by cardinality.
            let bytes = try need(length == 1 ? 1 : 2)
            var raw = 0
            for (index, byte) in bytes.enumerated() { raw |= Int(byte) << (8 * index) }
            return .int(Int64(raw))

        case .set:
            let bytes = try need(max(length, 1))
            var raw: UInt64 = 0
            for (index, byte) in bytes.enumerated() where index < 8 {
                raw |= UInt64(byte) << (8 * index)
            }
            return .uint(raw)

        case .bit:
            // Two metadata bytes, in this order on the wire: `bits % 8` first,
            // then `bits / 8` (MySQL's `Field_bit::do_save_field_metadata`).
            // Read little-endian, that puts the remainder in the **low** byte and
            // the whole-byte count in the high one.
            //
            // Getting these the wrong way round survives BIT(1) and BIT(8) — for
            // both, either reading yields one byte — and fails for every width in
            // between. BIT(12) is `bit_len = 4, bytes_in_rec = 1`: the correct
            // 1 × 8 + 4 = 12 bits is two bytes, the transposed 1 + 4 × 8 = 33 is
            // five, so the decoder eats three bytes belonging to the next column
            // and the rest of the row decodes as nonsense.
            let bits = Int(metadata >> 8) * 8 + Int(metadata & 0xFF)
            let bytes = try need((bits + 7) / 8)
            var raw: UInt64 = 0
            for byte in bytes { raw = (raw << 8) | UInt64(byte) }   // big-endian
            return .uint(raw)

        case .newdecimal:
            // Packed binary decimal, decoded to its exact digits as text.
            //
            // Never via Double: DECIMAL exists precisely because binary floating
            // point cannot represent these values, so converting would discard
            // the property the column was chosen for. `MySQLValue.string` on the
            // result is the exact decimal.
            let precision = Int(metadata >> 8)
            let scale = Int(metadata & 0xFF)
            let packed = try need(decimalByteCount(precision: precision, scale: scale))
            return .bytes(Array(decodeDecimal(packed, precision: precision, scale: scale).utf8))

        case .date:
            let bytes = try need(3)
            let packed = Int(bytes[0]) | (Int(bytes[1]) << 8) | (Int(bytes[2]) << 16)
            return .dateTime(MySQLDateTime(
                year: try narrow(packed / 16 / 32, "DATE year"),
                month: UInt8((packed / 32) % 16),
                day: UInt8(packed % 32),
                hour: 0, minute: 0, second: 0, microsecond: 0
            ))

        case .newdate:
            // Also three packed bytes, but a different packing from DATE: five
            // bits of day, four of month, the rest year. MySQL 5.0-era servers
            // and MariaDB can still emit it, and it used to fail the whole
            // stream rather than decode.
            let bytes = try need(3)
            let packed = Int(bytes[0]) | (Int(bytes[1]) << 8) | (Int(bytes[2]) << 16)
            return .dateTime(MySQLDateTime(
                year: try narrow(packed >> 9, "NEWDATE year"),
                month: UInt8((packed >> 5) & 15),
                day: UInt8(packed & 31),
                hour: 0, minute: 0, second: 0, microsecond: 0
            ))

        case .timestamp:
            let bytes = try need(4)
            var seconds: UInt32 = 0
            for (index, byte) in bytes.enumerated() { seconds |= UInt32(byte) << (8 * index) }
            return .uint(UInt64(seconds))

        case .timestamp2:
            // Big-endian seconds plus a fractional part whose width comes from
            // the metadata.
            let bytes = try need(4)
            var seconds: UInt32 = 0
            for byte in bytes { seconds = (seconds << 8) | UInt32(byte) }
            _ = try need(fractionalByteCount(Int(metadata)))
            return .uint(UInt64(seconds))

        case .datetime:
            let bytes = try need(8)
            var packed: UInt64 = 0
            for (index, byte) in bytes.enumerated() { packed |= UInt64(byte) << (8 * index) }
            let date = packed / 1_000_000
            let time = packed % 1_000_000
            return .dateTime(MySQLDateTime(
                year: try narrow(date / 10_000, "DATETIME year"),
                month: try narrow((date / 100) % 100, "DATETIME month"),
                day: try narrow(date % 100, "DATETIME day"),
                hour: try narrow(time / 10_000, "DATETIME hour"),
                minute: try narrow((time / 100) % 100, "DATETIME minute"),
                second: try narrow(time % 100, "DATETIME second"),
                microsecond: 0
            ))

        case .datetime2:
            // A 5-byte big-endian bit-packed field, then fractional seconds.
            let bytes = try need(5)
            var packed: UInt64 = 0
            for byte in bytes { packed = (packed << 8) | UInt64(byte) }
            packed -= 0x8000_000000                       // sign bias
            let yearMonth = (packed >> 22) & 0x1FFFF
            let fractional = try need(fractionalByteCount(Int(metadata)))
            return .dateTime(MySQLDateTime(
                year: try narrow(yearMonth / 13, "DATETIME2 year"),
                month: UInt8(yearMonth % 13),
                day: UInt8((packed >> 17) & 0x1F),
                hour: UInt8((packed >> 12) & 0x1F),
                minute: UInt8((packed >> 6) & 0x3F),
                second: UInt8(packed & 0x3F),
                microsecond: microseconds(fractional, precision: Int(metadata))
            ))

        // `MySQLTime.hours` is documented `0...23`, with `days` carrying the
        // overflow — which is how the wire protocol's own decoder builds it.
        // Both cases below stuffed the *total* hour count into that `UInt8` and
        // trapped above 255.
        //
        // That is not an edge case: MySQL's `TIME` range is
        // `-838:59:59 … 838:59:59`, so any value past `256:00:00` crashed the
        // binlog consumer — a legal column value taking down a replication
        // client, which is the one thing it must not do because it cannot skip
        // the row and cannot pause the stream.
        //
        // Found when an unrelated suite began writing `TIME(6)` columns and the
        // binlog suites, reading the same server's log concurrently, met one.
        case .time:
            let bytes = try need(3)
            // The field is **signed** 24-bit, and assembling it as unsigned made
            // the `isNegative` test below dead code: a negative TIME decoded as
            // a large positive one, so `-12:34:56` came back as `69 09:56:00`.
            //
            // That the field is signed is settled by its own range. The largest
            // legal TIME, `838:59:59`, packs to 8385959 — just under 2^23. If
            // the field were unsigned, that headroom would have no purpose; it
            // is there because the range is symmetric about zero, and MySQL
            // stores the negation of the magnitude for a negative time.
            //
            // `rust-mysql-common` reads it unsigned and hardcodes the sign to
            // false, so it carries the same defect. Recorded as a divergence in
            // docs/mysql-protocol-checklist.md.
            var packed = Int(bytes[0]) | (Int(bytes[1]) << 8) | (Int(bytes[2]) << 16)
            if packed >= 0x80_0000 { packed -= 0x100_0000 }
            let isNegative = packed < 0
            if isNegative { packed = -packed }
            let totalHours = packed / 10_000
            return .time(MySQLTime(
                isNegative: isNegative,
                days: try narrow(totalHours / 24, "TIME days"),
                hours: try narrow(totalHours % 24, "TIME hours"),
                minutes: try narrow((packed / 100) % 100, "TIME minutes"),
                seconds: try narrow(packed % 100, "TIME seconds"),
                microseconds: 0
            ))

        case .time2:
            let bytes = try need(3)
            var packed: UInt32 = 0
            for byte in bytes { packed = (packed << 8) | UInt32(byte) }
            packed &-= 0x800000                            // sign bias
            let fractional = try need(fractionalByteCount(Int(metadata)))
            // Ten bits of hours, so up to 1023 — well past what a `UInt8` holds.
            let totalHours = (packed >> 12) & 0x3FF
            return .time(MySQLTime(
                isNegative: false,
                days: try narrow(totalHours / 24, "TIME2 days"),
                hours: try narrow(totalHours % 24, "TIME2 hours"),
                minutes: try narrow((packed >> 6) & 0x3F, "TIME2 minutes"),
                seconds: try narrow(packed & 0x3F, "TIME2 seconds"),
                microseconds: microseconds(fractional, precision: Int(metadata))
            ))

        case .null:
            return .null

        default:
            // An unknown type cannot be skipped safely — its width is unknown,
            // so every subsequent column in the row would decode from the wrong
            // offset. Failing loudly beats emitting plausible nonsense.
            throw MySQLProtocolError.malformedPacket(
                "binlog: unsupported column type \(type) in row image"
            )
        }
    }

    /// Decodes MySQL's packed decimal into exact decimal text.
    ///
    /// The format stores nine digits per four big-endian bytes, with a partial
    /// group at each end, and flips the sign bit of the first byte so the
    /// encoding sorts correctly as raw bytes. For negatives every byte is
    /// complemented, which is why the whole buffer is normalised up front.
    static func decodeDecimal(_ packed: [UInt8], precision: Int, scale: Int) -> String {
        guard !packed.isEmpty else { return "0" }

        var bytes = packed
        let isNegative = (bytes[0] & 0x80) == 0
        bytes[0] ^= 0x80                                   // undo the sign-bit flip
        if isNegative { for i in bytes.indices { bytes[i] = ~bytes[i] } }

        let integerDigits = precision - scale
        let leftover = [0, 1, 1, 2, 2, 3, 3, 4, 4, 4]
        var offset = 0

        func take(_ count: Int) -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<count {
                guard offset < bytes.count else { break }
                value = (value << 8) | UInt32(bytes[offset])
                offset += 1
            }
            return value
        }

        var integerPart = ""
        let integerPartial = integerDigits % 9
        if integerPartial > 0 {
            integerPart += String(take(leftover[integerPartial]))
        }
        for _ in 0..<(integerDigits / 9) {
            let group = take(4)
            integerPart += integerPart.isEmpty
                ? String(group)
                : String(format: "%09u", group)
        }
        if integerPart.isEmpty { integerPart = "0" }
        // Strip leading zeros introduced by a partial first group.
        while integerPart.count > 1 && integerPart.hasPrefix("0") {
            integerPart.removeFirst()
        }

        var fractionPart = ""
        for _ in 0..<(scale / 9) {
            fractionPart += String(format: "%09u", take(4))
        }
        let fractionPartial = scale % 9
        if fractionPartial > 0 {
            let group = take(leftover[fractionPartial])
            fractionPart += String(
                format: "%0\(fractionPartial)u", group
            )
        }

        let sign = isNegative ? "-" : ""
        return scale > 0 ? "\(sign)\(integerPart).\(fractionPart)" : "\(sign)\(integerPart)"
    }

    /// Reads the diff list a partially-updated JSON column carries.
    ///
    /// ```
    /// int<prefixWidth>  byte length of the diff list
    /// repeated:
    ///   int<1>       operation: 0 replace, 1 insert, 2 remove
    ///   str<lenenc>  JSON path
    ///   str<lenenc>  JSONB value   (absent for remove)
    /// ```
    ///
    /// The outer length uses the **JSON column's own prefix width** — the same
    /// `metadata` byte that sizes a full document, normally 4 — not a
    /// length-encoded integer. Reading it as lenenc happens to work for diffs
    /// under 251 bytes and then silently mis-frames everything after.
    static func decodeJSONDiffs(
        _ buffer: inout ByteBuffer, prefixWidth: Int
    ) throws -> [MySQLJSONDiff] {
        guard let lengthBytes = buffer.readBytes(length: prefixWidth) else {
            throw MySQLProtocolError.malformedPacket("binlog: truncated JSON diff length")
        }
        var totalLength = 0
        for (index, byte) in lengthBytes.enumerated() {
            totalLength |= Int(byte) << (8 * index)
        }
        guard var region = buffer.readSlice(length: totalLength) else {
            throw MySQLProtocolError.malformedPacket("binlog: truncated JSON diff list")
        }

        var diffs: [MySQLJSONDiff] = []
        while region.readableBytes > 0 {
            guard let rawOperation = region.readInteger(as: UInt8.self),
                  let operation = MySQLJSONDiff.Operation(rawValue: rawOperation)
            else {
                throw MySQLProtocolError.malformedPacket("binlog: unknown JSON diff operation")
            }
            guard let path = region.readLengthEncodedString() else {
                throw MySQLProtocolError.malformedPacket("binlog: truncated JSON diff path")
            }

            var value: String?
            if operation != .remove {
                guard let length = region.readLengthEncodedInteger(),
                      let payload = region.readBytes(length: Int(length))
                else {
                    throw MySQLProtocolError.malformedPacket("binlog: truncated JSON diff value")
                }
                // The value is JSONB, the same binary form a whole document uses.
                value = (try? MySQLJSONB.decode(payload))
                    ?? String(decoding: payload, as: UTF8.self)
            }

            diffs.append(MySQLJSONDiff(operation: operation, path: path, value: value))
        }
        return diffs
    }

    /// DECIMAL packs nine digits into every four bytes, with a partial group at
    /// each end.
    static func decimalByteCount(precision: Int, scale: Int) -> Int {
        let integerDigits = precision - scale
        let integerGroups = integerDigits / 9
        let fractionalGroups = scale / 9
        let leftover = [0, 1, 1, 2, 2, 3, 3, 4, 4, 4]
        return integerGroups * 4 + leftover[integerDigits % 9]
            + fractionalGroups * 4 + leftover[scale % 9]
    }

    /// Fractional seconds occupy one byte per two digits of precision.
    static func fractionalByteCount(_ precision: Int) -> Int {
        (precision + 1) / 2
    }

    static func microseconds(_ bytes: [UInt8], precision: Int) -> UInt32 {
        guard !bytes.isEmpty else { return 0 }
        var raw: UInt32 = 0
        for byte in bytes { raw = (raw << 8) | UInt32(byte) }
        // Scale up to microseconds from however many digits were stored.
        let scale: [UInt32] = [1_000_000, 10_000, 10_000, 100, 100, 1, 1]
        return raw * scale[min(precision, 6)]
    }
}

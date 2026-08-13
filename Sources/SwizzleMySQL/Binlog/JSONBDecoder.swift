import Foundation
import NIOCore

/// Decodes MySQL's binary JSON (JSONB) into JSON text.
///
/// ## Why this is needed
///
/// The two flavours store `JSON` columns completely differently:
///
/// - **MariaDB** stores JSON as text — `JSON` is an alias for `LONGTEXT` with a
///   validity constraint — so a binlog row image already contains
///   `{"name":"ada"}` and nothing has to be done.
/// - **MySQL** stores a compact binary form. A row image contains a length-
///   prefixed tree with an offset table, not text.
///
/// Without this decoder every JSON column in a MySQL CDC stream yields
/// unreadable bytes — verified: a `{"name":"ada","n":42,"ok":true}` document
/// arrived as 37 non-printable bytes. That is the *default* configuration, not
/// a niche setting, which makes it a bigger gap than the partial-update events
/// it also unblocks.
///
/// ## The format
///
/// ```
/// value      ::= type(1) payload
/// object     ::= count size key-entry* value-entry* key* value*
/// array      ::= count size value-entry* value*
/// key-entry  ::= offset length
/// value-entry::= type(1) (offset | inlined-value)
/// ```
///
/// `count`, `size` and the offsets are 16-bit in the *small* variants and
/// 32-bit in the *large* ones — which is the whole reason the type byte
/// distinguishes them. Offsets are measured from the start of the containing
/// object, not the document, so nesting has to track its own base.
///
/// Small values are **inlined** into the value-entry rather than stored in the
/// value area, which is why an entry cannot simply be treated as a pointer.
public enum MySQLJSONB {

    enum ValueType: UInt8 {
        case smallObject = 0x00
        case largeObject = 0x01
        case smallArray  = 0x02
        case largeArray  = 0x03
        case literal     = 0x04
        case int16       = 0x05
        case uint16      = 0x06
        case int32       = 0x07
        case uint32      = 0x08
        case int64       = 0x09
        case uint64      = 0x0A
        case double      = 0x0B
        case string      = 0x0C
        case opaque      = 0x0F

        var isLarge: Bool { self == .largeObject || self == .largeArray }

        /// Whether a value of this type is stored *inside* its value-entry.
        ///
        /// Depends on the container's width: a 32-bit entry can inline a 32-bit
        /// integer, a 16-bit one cannot. Getting this wrong reads the payload as
        /// an offset and walks off into unrelated bytes.
        func isInlined(large: Bool) -> Bool {
            switch self {
            case .literal, .int16, .uint16: true
            case .int32, .uint32: large
            default: false
            }
        }
    }

    /// Decodes a JSONB document to its JSON text.
    public static func decode(_ bytes: [UInt8]) throws -> String {
        guard let first = bytes.first, let type = ValueType(rawValue: first) else {
            throw MySQLProtocolError.malformedPacket("jsonb: empty or unknown document")
        }
        var output = ""
        try render(type: type, bytes: bytes, at: 1, into: &output)
        return output
    }

    /// Renders the value of `type` whose payload begins at `offset`.
    private static func render(
        type: ValueType, bytes: [UInt8], at offset: Int, into output: inout String, depth: Int = 0
    ) throws {
        // A malformed or hostile document could otherwise recurse until the
        // stack runs out; JSON nesting that deep is not legitimate data.
        guard depth < 100 else {
            throw MySQLProtocolError.malformedPacket("jsonb: nesting deeper than 100")
        }

        switch type {
        case .smallObject, .largeObject:
            try renderObject(bytes: bytes, at: offset, large: type.isLarge,
                             into: &output, depth: depth)
        case .smallArray, .largeArray:
            try renderArray(bytes: bytes, at: offset, large: type.isLarge,
                            into: &output, depth: depth)
        case .literal:
            output += try literal(bytes, at: offset)
        case .int16:
            output += String(try readInt16(bytes, at: offset))
        case .uint16:
            output += String(try readUInt16(bytes, at: offset))
        case .int32:
            output += String(try readInt32(bytes, at: offset))
        case .uint32:
            output += String(try readUInt32(bytes, at: offset))
        case .int64:
            output += String(Int64(bitPattern: try readUInt64(bytes, at: offset)))
        case .uint64:
            output += String(try readUInt64(bytes, at: offset))
        case .double:
            output += formatDouble(Double(bitPattern: try readUInt64(bytes, at: offset)))
        case .string:
            var cursor = offset
            let length = try readVariableLength(bytes, at: &cursor)
            try require(bytes, cursor + length)
            output += escaped(String(decoding: bytes[cursor..<(cursor + length)], as: UTF8.self))
        case .opaque:
            output += try renderOpaque(bytes, at: offset)
        }
    }

    private static func renderObject(
        bytes: [UInt8], at base: Int, large: Bool, into output: inout String, depth: Int
    ) throws {
        let width = large ? 4 : 2
        let count = try readSize(bytes, at: base, large: large)
        try require(bytes, base + width * 2)

        // Key entries: offset then a 16-bit length — the length is two bytes
        // even in a large object, which is easy to miss.
        let keyEntrySize = width + 2
        let valueEntrySize = width + 1
        let keyEntriesStart = base + width * 2
        let valueEntriesStart = keyEntriesStart + count * keyEntrySize

        output += "{"
        for index in 0..<count {
            if index > 0 { output += "," }

            let keyEntry = keyEntriesStart + index * keyEntrySize
            let keyOffset = try readSize(bytes, at: keyEntry, large: large)
            let keyLength = Int(try readUInt16(bytes, at: keyEntry + width))
            // Offsets are relative to the containing object, not the document.
            let keyStart = base + keyOffset
            try require(bytes, keyStart + keyLength)
            output += escaped(String(decoding: bytes[keyStart..<(keyStart + keyLength)], as: UTF8.self))
            output += ":"

            try renderValueEntry(
                bytes: bytes, base: base, entry: valueEntriesStart + index * valueEntrySize,
                large: large, into: &output, depth: depth
            )
        }
        output += "}"
    }

    private static func renderArray(
        bytes: [UInt8], at base: Int, large: Bool, into output: inout String, depth: Int
    ) throws {
        let width = large ? 4 : 2
        let count = try readSize(bytes, at: base, large: large)
        let valueEntrySize = width + 1
        let valueEntriesStart = base + width * 2

        output += "["
        for index in 0..<count {
            if index > 0 { output += "," }
            try renderValueEntry(
                bytes: bytes, base: base, entry: valueEntriesStart + index * valueEntrySize,
                large: large, into: &output, depth: depth
            )
        }
        output += "]"
    }

    /// A value-entry is either an inlined value or an offset into the value
    /// area — decided by the type byte together with the container's width.
    private static func renderValueEntry(
        bytes: [UInt8], base: Int, entry: Int, large: Bool,
        into output: inout String, depth: Int
    ) throws {
        try require(bytes, entry + 1)
        guard let type = ValueType(rawValue: bytes[entry]) else {
            throw MySQLProtocolError.malformedPacket("jsonb: unknown value type \(bytes[entry])")
        }

        if type.isInlined(large: large) {
            try render(type: type, bytes: bytes, at: entry + 1, into: &output, depth: depth + 1)
        } else {
            let offset = try readSize(bytes, at: entry + 1, large: large)
            try render(type: type, bytes: bytes, at: base + offset, into: &output, depth: depth + 1)
        }
    }

    /// `OPAQUE` wraps a value MySQL has no JSON type for — DECIMAL, DATE,
    /// DATETIME, TIME and so on — as its column type plus the raw stored bytes.
    ///
    /// Rendered as a JSON string rather than decoded per type: the exact
    /// representation is MySQL-internal, and a consumer that needs the typed
    /// value is better served reading the column directly than trusting a
    /// re-encoding here.
    private static func renderOpaque(_ bytes: [UInt8], at offset: Int) throws -> String {
        try require(bytes, offset + 1)
        let columnType = bytes[offset]
        var cursor = offset + 1
        let length = try readVariableLength(bytes, at: &cursor)
        try require(bytes, cursor + length)
        let payload = Array(bytes[cursor..<(cursor + length)])

        // Temporals are stored as MySQL's packed 64-bit representation, not as
        // text. Decoding them by type is the only correct way to read them —
        // and the reason the previous "does it look like ASCII?" heuristic had
        // to go: the eight bytes of a packed datetime can perfectly well all be
        // printable, in which case it rendered as convincing garbage.
        if let type = MySQLColumnType(rawValue: columnType), payload.count == 8 {
            let packed = payload.withUnsafeBytes {
                Int64(littleEndian: $0.loadUnaligned(as: Int64.self))
            }
            switch type {
            case .datetime, .datetime2, .timestamp, .timestamp2:
                return escaped(MySQLValue.render(unpackDateTime(packed)))
            case .date, .newdate:
                let value = unpackDateTime(packed)
                return escaped(
                    String(format: "%04d-%02d-%02d", value.year, value.month, value.day)
                )
            case .time, .time2:
                return escaped(MySQLValue.render(unpackTime(packed)))
            default:
                break
            }
        }

        // Character-set types genuinely hold text.
        if let type = MySQLColumnType(rawValue: columnType),
           type == .varString || type == .varchar || type == .string,
           let text = String(bytes: payload, encoding: .utf8) {
            return escaped(text)
        }

        // Everything else — DECIMAL's packed form, BIT, BLOB, GEOMETRY — keeps
        // MySQL's own `base64:typeN:` convention rather than being guessed at.
        // A wrong guess here is silent data corruption inside a document that
        // still parses as valid JSON.
        return escaped("base64:type\(columnType):" + Data(payload).base64EncodedString())
    }

    /// MySQL's packed datetime: `((ymd << 17) | hms) << 24 | microseconds`,
    /// where `ymd = ((year * 13 + month) << 5) | day` and
    /// `hms = (hour << 12) | (minute << 6) | second`.
    private static func unpackDateTime(_ packed: Int64) -> MySQLDateTime {
        let magnitude = packed < 0 ? -packed : packed
        let fraction = magnitude % (1 << 24)
        let ymdhms = magnitude >> 24
        let ymd = ymdhms >> 17
        let ym = ymd >> 5
        let hms = ymdhms % (1 << 17)

        return MySQLDateTime(
            year: UInt16(truncatingIfNeeded: ym / 13),
            month: UInt8(truncatingIfNeeded: ym % 13),
            day: UInt8(truncatingIfNeeded: ymd % (1 << 5)),
            hour: UInt8(truncatingIfNeeded: hms >> 12),
            minute: UInt8(truncatingIfNeeded: (hms >> 6) % (1 << 6)),
            second: UInt8(truncatingIfNeeded: hms % (1 << 6)),
            microsecond: UInt32(truncatingIfNeeded: fraction)
        )
    }

    /// MySQL's packed time. The hour field is ten bits, because `TIME` is a
    /// duration and runs past 24.
    private static func unpackTime(_ packed: Int64) -> MySQLTime {
        let isNegative = packed < 0
        let magnitude = isNegative ? -packed : packed
        let fraction = magnitude % (1 << 24)
        let hms = magnitude >> 24
        let totalHours = UInt32(truncatingIfNeeded: (hms >> 12) % (1 << 10))

        return MySQLTime(
            isNegative: isNegative,
            days: totalHours / 24,
            hours: UInt8(totalHours % 24),
            minutes: UInt8(truncatingIfNeeded: (hms >> 6) % (1 << 6)),
            seconds: UInt8(truncatingIfNeeded: hms % (1 << 6)),
            microseconds: UInt32(truncatingIfNeeded: fraction)
        )
    }

    // MARK: - Primitives

    private static func literal(_ bytes: [UInt8], at offset: Int) throws -> String {
        try require(bytes, offset + 1)
        switch bytes[offset] {
        case 0x00: return "null"
        case 0x01: return "true"
        case 0x02: return "false"
        default:
            throw MySQLProtocolError.malformedPacket("jsonb: unknown literal \(bytes[offset])")
        }
    }

    /// Counts, sizes and offsets are 16-bit in small containers, 32-bit in large.
    private static func readSize(_ bytes: [UInt8], at offset: Int, large: Bool) throws -> Int {
        large ? Int(try readUInt32(bytes, at: offset)) : Int(try readUInt16(bytes, at: offset))
    }

    /// String and opaque lengths use a 7-bits-per-byte encoding with the high
    /// bit marking continuation — *not* the protocol's length-encoded integer,
    /// which is a different scheme entirely.
    static func readVariableLength(_ bytes: [UInt8], at cursor: inout Int) throws -> Int {
        var value = 0
        var shift = 0
        while true {
            try require(bytes, cursor + 1)
            let byte = bytes[cursor]
            cursor += 1
            value |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            guard shift <= 28 else {
                throw MySQLProtocolError.malformedPacket("jsonb: length field too long")
            }
        }
        return value
    }

    private static func require(_ bytes: [UInt8], _ end: Int) throws {
        guard end <= bytes.count, end >= 0 else {
            throw MySQLProtocolError.malformedPacket(
                "jsonb: document truncated — needed \(end) of \(bytes.count) bytes"
            )
        }
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) throws -> UInt16 {
        try require(bytes, offset + 2)
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readInt16(_ bytes: [UInt8], at offset: Int) throws -> Int16 {
        Int16(bitPattern: try readUInt16(bytes, at: offset))
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) throws -> UInt32 {
        try require(bytes, offset + 4)
        var value: UInt32 = 0
        for i in 0..<4 { value |= UInt32(bytes[offset + i]) << (8 * i) }
        return value
    }

    private static func readInt32(_ bytes: [UInt8], at offset: Int) throws -> Int32 {
        Int32(bitPattern: try readUInt32(bytes, at: offset))
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int) throws -> UInt64 {
        try require(bytes, offset + 8)
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(bytes[offset + i]) << (8 * i) }
        return value
    }

    /// Renders a double the way JSON expects: `1` not `1.0`, and no exponent
    /// for values that do not need one.
    static func formatDouble(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    /// Minimal JSON string escaping.
    static func escaped(_ text: String) -> String {
        var out = "\""
        for character in text.unicodeScalars {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if character.value < 0x20 {
                    out += String(format: "\\u%04x", character.value)
                } else {
                    out.unicodeScalars.append(character)
                }
            }
        }
        return out + "\""
    }
}

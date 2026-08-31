import Foundation
import NIOCore
import SwizzleCore

/// The type OIDs this driver understands.
///
/// Postgres identifies types by OID, and the built-in ones are fixed — they are
/// baked into every installation, so a table of the ones that matter is stable in
/// a way that user-defined OIDs are not. Anything unrecognised degrades to bytes
/// rather than failing the result set: a new server type should not break a query
/// that never touches it.
public enum PostgresOID: UInt32, Sendable, CaseIterable {
    case bool = 16
    case bytea = 17
    case char = 18
    case name = 19
    case int8 = 20
    case int2 = 21
    case int4 = 23
    case text = 25
    case oid = 26
    case json = 114
    case xml = 142
    case float4 = 700
    case float8 = 701
    /// What the server calls a literal whose type it could not infer.
    case unknown = 705
    case bpchar = 1042
    case varchar = 1043
    case date = 1082
    case time = 1083
    case timestamp = 1114
    case timestamptz = 1184
    case interval = 1186
    case timetz = 1266
    case numeric = 1700
    case uuid = 2950
    case jsonb = 3802

    // Found by diffing this table against `postgres-types/src/type_gen.rs`.
    // Every one of these used to arrive as an opaque `.blob`, because an
    // unrecognised OID falls back to raw bytes and binary `inet` is not text.
    case tid = 27
    case xid = 28
    case cid = 29
    case point = 600
    case lseg = 601
    case path = 602
    case box = 603
    case polygon = 604
    case line = 628
    case cidr = 650
    case circle = 718
    case macaddr8 = 774
    case money = 790
    case macaddr = 829
    case inet = 869
    case bit = 1560
    case varbit = 1562
    case pgLSN = 3220
    // The `reg*` family. Binary is the OID; text is the name — see `swiftType`.
    case regproc = 24
    case regprocedure = 2202
    case regoper = 2203
    case regoperator = 2204
    case regclass = 2205
    case regtype = 2206
    case regconfig = 3734
    case regdictionary = 3769
    case regnamespace = 4089
    case regrole = 4096
    /// Postgres 13+, and the one `reg*` this table was missing.
    case regcollation = 4191
    case tsvector = 3614
    case tsquery = 3615
    case jsonpath = 4072
    case int4Range = 3904
    case numRange = 3906
    case tsRange = 3908
    case tstzRange = 3910
    case dateRange = 3912
    case int8Range = 3926

    // Multiranges — Postgres 14 gave every range type one, and a column of
    // `int4multirange` is as ordinary as `int4range`. Without these the value
    // arrived as opaque bytes.
    case int4Multirange = 4451
    case numMultirange = 4532
    case tsMultirange = 4533
    case tstzMultirange = 4534
    case dateMultirange = 4535
    case int8Multirange = 4536

    // System catalog types. Nobody defines a column of these, and everybody
    // meets them the moment they `SELECT * FROM pg_index` or read a `relacl` —
    // which is exactly when an opaque blob is least welcome.
    case int2Vector = 22
    case oidVector = 30
    case aclitem = 1033
    case gtsvector = 3642
    /// The 64-bit transaction id, Postgres 13+. `xid` wraps around; this does not.
    case xid8 = 5069
    /// `pg_snapshot`'s older name, still what `txid_current_snapshot()` returns.
    case txidSnapshot = 2970
    /// A cursor name returned by a function. Text on the wire.
    case refcursor = 1790
    /// A C string. Only reachable through a pseudo-typed function, but the OID is
    /// real and the alternative is raw bytes.
    case cstring = 2275

    // Arrays. Postgres gives every type an array companion, and these are the
    // ones a real schema actually uses.
    case boolArray = 1000
    case int2Array = 1005
    case int4Array = 1007
    case textArray = 1009
    case varcharArray = 1015
    case int8Array = 1016
    case float4Array = 1021
    case float8Array = 1022
    case timestampArray = 1115
    case timestamptzArray = 1185
    case numericArray = 1231
    case uuidArray = 2951
    case jsonbArray = 3807

    /// The element type, for the array OIDs.
    public var elementType: PostgresOID? {
        switch self {
        case .boolArray: .bool
        case .int2Array: .int2
        case .int4Array: .int4
        case .textArray: .text
        case .varcharArray: .varchar
        case .int8Array: .int8
        case .float4Array: .float4
        case .float8Array: .float8
        case .timestampArray: .timestamp
        case .timestamptzArray: .timestamptz
        case .numericArray: .numeric
        case .uuidArray: .uuid
        case .jsonbArray: .jsonb
        default: nil
        }
    }

    /// The element a range spans, which the wire does *not* carry.
    ///
    /// Unlike an array — whose binary form names its element OID — a range's
    /// bounds are just length-prefixed bytes, so the element type has to come
    /// from the range type itself.
    public var rangeElement: PostgresOID? {
        switch self {
        case .int4Range, .int4Multirange: .int4
        case .int8Range, .int8Multirange: .int8
        case .numRange, .numMultirange: .numeric
        case .tsRange, .tsMultirange: .timestamp
        case .tstzRange, .tstzMultirange: .timestamptz
        case .dateRange, .dateMultirange: .date
        default: nil
        }
    }

    /// The Swift type the code generator should emit for a column of this type.
    public var swiftType: SwiftType {
        // Explicit returns throughout: the default arm has a statement before its
        // result, and Swift will not mix implicit and explicit returns in one
        // switch.
        switch self {
        case .bool: return .bool
        case .int2: return .int16
        case .int4: return .int32
        case .int8, .oid: return .int64
        case .float4: return .float
        case .float8: return .double
        // Exact numerics stay text. Routing them through binary floating point is
        // how the cents go missing, and it is the same contract MySQL's DECIMAL
        // and SQLite's NUMERIC already make.
        case .numeric: return .decimalString
        case .bytea: return .bytes
        case .uuid: return .uuid
        case .json, .jsonb: return .json
        case .date, .time, .timetz, .timestamp, .timestamptz, .interval: return .date
        case .text, .varchar, .bpchar, .char, .name, .xml, .unknown: return .string
        // Exact money, like `numeric`: a currency amount through binary floating
        // point is the classic way to lose a cent per row.
        case .money: return .decimalString
        case .xid, .cid: return .int64
        // The one family where binary and text *cannot* agree: the wire carries an
        // OID and the text form carries the name it resolves to. Decoding the OID
        // is honest and useful; resolving the name would need a catalogue lookup
        // per value, and `::text` is the documented way to ask for it.
        case .regproc, .regprocedure, .regoper, .regoperator, .regclass, .regtype,
             .regconfig, .regdictionary, .regnamespace, .regrole, .regcollation:
            return .int64
        // `xid8` is 64-bit and unsigned; `Int64` covers every value a real server
        // will ever produce, and the decoder falls back to text rather than
        // wrapping if one ever does not.
        case .xid8: return .int64
        case .refcursor, .cstring: return .string
        // Everything else renders to the text Postgres itself prints. A range,
        // an `inet` prefix and a geometric path have no Swift equivalent worth
        // inventing, and the server's spelling is the one every other tool round
        // trips.
        case .tsvector, .tsquery, .jsonpath: return .string
        case .inet, .cidr, .macaddr, .macaddr8, .bit, .varbit, .tid, .pgLSN,
             .point, .lseg, .path, .box, .polygon, .line, .circle,
             .int4Range, .int8Range, .numRange, .tsRange, .tstzRange, .dateRange,
             .int4Multirange, .int8Multirange, .numMultirange,
             .tsMultirange, .tstzMultirange, .dateMultirange,
             .int2Vector, .oidVector, .aclitem, .gtsvector, .txidSnapshot:
            return .string
        default:
            if let element = elementType { return .array(element.swiftType) }
            return .dynamic
        }
    }

    /// The name the lockfile records.
    ///
    /// A *name*, never the OID: OIDs for user types are per-database and the
    /// shadow database is recreated on every run, so storing them would churn the
    /// lockfile on every generate.
    public var name: String { String(describing: self) }
}

/// Turns a wire value into a `SQLValue`.
public enum PostgresValueDecoder {

    /// Postgres counts time from **2000-01-01**, not 1970. Thirty years and
    /// change, and a classic silent error: the value looks like a plausible date.
    static let postgresEpoch = Date(timeIntervalSince1970: 946_684_800)

    /// Decodes one column.
    ///
    /// - Parameter format: 0 for text, 1 for binary. The extended-query protocol
    ///   defaults to text unless the client asks otherwise, so both are real.
    /// - Parameter hasIntegerDatetimes: from the session's `integer_datetimes`.
    ///   False only on a server older than 10 that was built without it, where
    ///   timestamps arrive as `float8` seconds in the same eight bytes.
    public static func decode(
        _ bytes: [UInt8]?, oid: UInt32, format: Int16,
        hasIntegerDatetimes: Bool = true
    ) -> SQLValue {
        guard let bytes else { return .null }
        guard let type = PostgresOID(rawValue: oid) else {
            // An unrecognised type is handed back rather than dropped: text if it
            // is valid UTF-8, bytes otherwise.
            return String(bytes: bytes, encoding: .utf8).map { SQLValue.text($0) } ?? .blob(bytes)
        }
        return format == 1
            ? decodeBinary(bytes, type: type, hasIntegerDatetimes: hasIntegerDatetimes)
            : decodeText(bytes, type: type)
    }

    static func decodeText(_ bytes: [UInt8], type: PostgresOID) -> SQLValue {
        guard let text = String(bytes: bytes, encoding: .utf8) else { return .blob(bytes) }
        switch type {
        case .bool: return .bool(text == "t" || text == "true")
        // `xid`, `cid` and `xid8` are listed because `decodeBinary` returns them
        // as `.int`, and the two formats have to agree: a query with a bound
        // parameter takes the extended protocol and gets binary, the same query
        // written as a literal takes the simple protocol and gets text. Leaving
        // them out meant `row[0].int` was non-nil or nil depending on which — a
        // difference nothing in the query itself suggests.
        //
        // The `reg*` family is here too, and is the one place the formats
        // genuinely cannot agree: binary carries the OID, text carries the name
        // it resolves to. `Int64(text)` is what picks the right one — digits
        // become an int, a name stays a name.
        case .int2, .int4, .int8, .oid, .xid, .cid, .xid8,
             .regproc, .regprocedure, .regoper, .regoperator, .regclass, .regtype,
             .regconfig, .regdictionary, .regnamespace, .regrole, .regcollation:
            return Int64(text).map { .int($0) } ?? .text(text)
        case .float4, .float8: return Double(text).map { .double($0) } ?? .text(text)
        case .bytea:
            // Text-format bytea is `\x` followed by hex.
            guard text.hasPrefix("\\x") else { return .text(text) }
            return .blob(hexBytes(text.dropFirst(2)))
        default:
            // Numerics, temporals, uuid and json all stay as the server rendered
            // them — the server's rendering is canonical and reparsing would only
            // add a way to be wrong.
            return .text(text)
        }
    }

    static func decodeBinary(
        _ bytes: [UInt8], type: PostgresOID, hasIntegerDatetimes: Bool = true
    ) -> SQLValue {
        var buffer = ByteBuffer(bytes: bytes)
        switch type {
        case .bool:
            return .bool(bytes.first == 1)
        case .int2:
            return buffer.readInteger(as: Int16.self).map { .int(Int64($0)) } ?? .null
        case .int4:
            return buffer.readInteger(as: Int32.self).map { .int(Int64($0)) } ?? .null
        case .int8:
            return buffer.readInteger(as: Int64.self).map { .int($0) } ?? .null
        case .oid:
            return buffer.readInteger(as: UInt32.self).map { .int(Int64($0)) } ?? .null
        case .float4:
            return buffer.readInteger(as: UInt32.self)
                .map { .double(Double(Float(bitPattern: $0))) } ?? .null
        case .float8:
            return buffer.readInteger(as: UInt64.self)
                .map { .double(Double(bitPattern: $0)) } ?? .null

        case .numeric:
            return decodeNumeric(&buffer).map { .text($0) } ?? .null

        case .bytea:
            return .blob(bytes)

        case .uuid:
            guard bytes.count == 16 else { return .blob(bytes) }
            return .text(formatUUID(bytes))

        case .jsonb:
            // A leading version byte, which is always 1 and is not part of the
            // document. `json` has no such byte, which is the only difference
            // between the two on the wire.
            guard bytes.first == 1 else { return .blob(bytes) }
            return String(bytes: bytes.dropFirst(), encoding: .utf8).map { .text($0) }
                ?? .blob(bytes)

        case .timestamp, .timestamptz:
            // Microseconds since 2000-01-01 when `integer_datetimes` is on —
            // the default since 8.4, and not switchable at all since 10. A server
            // old enough to have it off sends `float8` *seconds* instead, and
            // reading those eight bytes as an integer yields a date around the
            // year 6 million rather than an error.
            //
            // Eight bytes either way, so nothing but the session's own
            // `integer_datetimes` can tell the two apart — which is why it is
            // threaded in rather than assumed.
            guard let raw = buffer.readInteger(as: Int64.self) else { return .null }
            let seconds = hasIntegerDatetimes
                ? Double(raw) / 1_000_000
                : Double(bitPattern: UInt64(bitPattern: raw))
            return .text(formatTimestamp(postgresEpoch.addingTimeInterval(seconds)))

        case .date:
            guard let days = buffer.readInteger(as: Int32.self) else { return .null }
            let date = postgresEpoch.addingTimeInterval(Double(days) * 86_400)
            return .text(String(formatTimestamp(date).prefix(10)))

        case .interval:
            return PostgresExtendedTypes.decodeInterval(&buffer) ?? .blob(bytes)

        case .text, .varchar, .bpchar, .char, .name, .xml, .json, .unknown:
            return String(bytes: bytes, encoding: .utf8).map { .text($0) } ?? .blob(bytes)

        case .inet, .cidr:
            return PostgresExtendedTypes.decodeInet(&buffer, isCIDR: type == .cidr) ?? .blob(bytes)
        case .macaddr:
            return PostgresExtendedTypes.decodeMACAddress(bytes, width: 6) ?? .blob(bytes)
        case .macaddr8:
            return PostgresExtendedTypes.decodeMACAddress(bytes, width: 8) ?? .blob(bytes)
        case .money:
            return PostgresExtendedTypes.decodeMoney(&buffer) ?? .blob(bytes)
        case .bit, .varbit:
            return PostgresExtendedTypes.decodeBits(&buffer) ?? .blob(bytes)
        case .pgLSN:
            return PostgresExtendedTypes.decodeLSN(&buffer) ?? .blob(bytes)
        case .tsvector:
            return PostgresExtendedTypes.decodeTSVector(&buffer) ?? .blob(bytes)
        case .tsquery:
            return PostgresExtendedTypes.decodeTSQuery(&buffer) ?? .blob(bytes)
        case .jsonpath:
            return PostgresExtendedTypes.decodeJSONPath(bytes) ?? .blob(bytes)
        case .tid:
            return PostgresExtendedTypes.decodeTID(&buffer) ?? .blob(bytes)
        case .xid, .cid,
             .regproc, .regprocedure, .regoper, .regoperator, .regclass, .regtype,
             .regconfig, .regdictionary, .regnamespace, .regrole, .regcollation:
            return buffer.readInteger(as: UInt32.self).map { .int(Int64($0)) } ?? .null
        case .xid8:
            // Eight bytes, not four — the whole point of `xid8` is that it does
            // *not* wrap, and reading it as a `UInt32` would silently take half.
            //
            // `SQLValue` has no unsigned case, so a value past `Int64.max` is
            // rendered as text rather than wrapped into a negative. Unreachable
            // in practice — the counter would need centuries — but a silent wrap
            // is precisely the failure this type exists to avoid, and the check
            // costs one comparison.
            guard let value = buffer.readInteger(as: UInt64.self) else { return .null }
            return value <= UInt64(Int64.max) ? .int(Int64(value)) : .text(String(value))
        case .refcursor, .cstring:
            // Both are plain text on the wire; only the OID differs.
            return .text(String(decoding: bytes, as: UTF8.self))
        case .int2Vector, .oidVector:
            return PostgresExtendedTypes.decodeIntVector(bytes) ?? .blob(bytes)
        case .point, .lseg, .path, .box, .polygon, .line, .circle:
            return PostgresExtendedTypes.decodeGeometry(&buffer, type: type) ?? .blob(bytes)
        case .int4Range, .int8Range, .numRange, .tsRange, .tstzRange, .dateRange:
            return PostgresExtendedTypes.decodeRange(
                &buffer, elementOID: type.rangeElement?.rawValue ?? 0
            ) ?? .blob(bytes)
        case .int4Multirange, .int8Multirange, .numMultirange,
             .tsMultirange, .tstzMultirange, .dateMultirange:
            return PostgresExtendedTypes.decodeMultirange(
                &buffer, elementOID: type.rangeElement?.rawValue ?? 0
            ) ?? .blob(bytes)

        default:
            // Arrays land here, and they decode. The neutral `SQLValue` has no
            // array case — and should not gain one, since only one of the three
            // engines can carry it — so an array becomes the text Postgres itself
            // would print. That keeps binary and text formats agreeing, which is
            // the same contract `numeric` and the temporals keep, and
            // `PostgresRow.array(at:)` is there for callers that want elements.
            if type.elementType != nil,
               let array = PostgresArrayDecoder.decodeBinary(bytes) {
                return .text(array.textRepresentation)
            }
            // Intervals and times keep their bytes rather than being guessed at.
            // Better an honest blob than a plausible lie.
            return .blob(bytes)
        }
    }

    /// Postgres's binary `numeric`, rendered back to its decimal text.
    ///
    /// ## Why this is worth the trouble
    ///
    /// `numeric` is the money type. Decoding it through `Double` loses cents, so
    /// the value has to survive as text — and in binary format the server does not
    /// send text, it sends base-10000 digits. Getting this wrong does not fail; it
    /// produces a number that is merely incorrect.
    ///
    /// The layout is four `Int16` headers — digit count, weight, sign, display
    /// scale — then that many base-10000 groups. `weight` is the power of 10000 of
    /// the *first* group, so it places the decimal point. Confirmed against
    /// `pgtype/numeric.go`.
    static func decodeNumeric(_ buffer: inout ByteBuffer) -> String? {
        guard let digitCount: Int16 = buffer.readInteger(),
              let weight: Int16 = buffer.readInteger(),
              let sign: UInt16 = buffer.readInteger(),
              let displayScale: Int16 = buffer.readInteger()
        else { return nil }

        // The three special signs carry no digits.
        switch sign {
        case 0xC000: return "NaN"
        case 0xD000: return "Infinity"
        case 0xF000: return "-Infinity"
        default: break
        }

        var groups: [Int16] = []
        groups.reserveCapacity(Int(max(digitCount, 0)))
        for _ in 0..<max(digitCount, 0) {
            guard let group: Int16 = buffer.readInteger() else { return nil }
            groups.append(group)
        }

        // Integer part: groups at or before the decimal point, zero-padded when
        // the weight implies groups the server did not bother to send.
        var integerText = ""
        if weight >= 0 {
            for index in 0...Int(weight) {
                let group = index < groups.count ? groups[index] : 0
                integerText += index == 0
                    ? String(group)
                    : String(format: "%04d", group)
            }
        } else {
            integerText = "0"
        }

        // Fractional part: everything after, padded to the display scale, which is
        // what makes `1.10` come back as `1.10` rather than `1.1`.
        var fractionText = ""
        var index = Int(weight) + 1
        // The mutation sweep relaxes this to `<=` and nothing can catch it: the
        // extra pass appends four more digits and the `prefix(displayScale)`
        // below discards them, so no input distinguishes the two. Recorded rather
        // than chased — the bound that is actually load-bearing is the truncation.
        while fractionText.count < Int(displayScale) {
            let group = index >= 0 && index < groups.count ? groups[index] : 0
            fractionText += String(format: "%04d", group)
            index += 1
        }
        fractionText = String(fractionText.prefix(Int(max(displayScale, 0))))

        let negative = sign == 0x4000 ? "-" : ""
        return displayScale > 0
            ? "\(negative)\(integerText).\(fractionText)"
            : "\(negative)\(integerText)"
    }

    static func formatUUID(_ bytes: [UInt8]) -> String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let groups = [8, 4, 4, 4, 12]
        var index = hex.startIndex
        var parts: [String] = []
        for length in groups {
            let end = hex.index(index, offsetBy: length)
            parts.append(String(hex[index..<end]))
            index = end
        }
        return parts.joined(separator: "-")
    }

    /// ISO-8601-ish, matching what the server would have sent in text format, so a
    /// value decodes the same whichever format it arrived in.
    static func formatTimestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date
        )
        let base = String(
            format: "%04d-%02d-%02d %02d:%02d:%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
        let micros = (parts.nanosecond ?? 0) / 1000
        return micros > 0 ? base + String(format: ".%06d", micros) : base
    }

    static func hexBytes(_ text: some StringProtocol) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex, text.index(after: index) < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            if let byte = UInt8(text[index..<next], radix: 16) { bytes.append(byte) }
            index = next
        }
        return bytes
    }
}

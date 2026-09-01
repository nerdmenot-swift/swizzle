import NIOCore
import SwizzleCore

/// A date/time as MySQL represents it.
///
/// Deliberately not `Foundation.Date`: MySQL permits values `Date` cannot hold —
/// the zero date `0000-00-00`, and days/months of 0 — and converting eagerly
/// would either throw on legal data or silently invent a value.
public struct MySQLDateTime: Sendable, Equatable {
    public var year: UInt16
    public var month: UInt8
    public var day: UInt8
    public var hour: UInt8
    public var minute: UInt8
    public var second: UInt8
    public var microsecond: UInt32

    public init(
        year: UInt16 = 0, month: UInt8 = 0, day: UInt8 = 0,
        hour: UInt8 = 0, minute: UInt8 = 0, second: UInt8 = 0, microsecond: UInt32 = 0
    ) {
        self.year = year; self.month = month; self.day = day
        self.hour = hour; self.minute = minute; self.second = second
        self.microsecond = microsecond
    }

    /// MySQL's "zero date", which a real column can legitimately contain.
    public var isZero: Bool {
        year == 0 && month == 0 && day == 0
            && hour == 0 && minute == 0 && second == 0 && microsecond == 0
    }
}

/// A MySQL `TIME`, which is a signed *duration*, not a clock time.
///
/// The range is -838:59:59 to 838:59:59, so it does not fit a clock and cannot
/// be represented as an hour-of-day. The binary protocol splits it into whole
/// days plus an hour remainder; the text protocol writes total hours.
public struct MySQLTime: Sendable, Equatable {
    public var isNegative: Bool
    public var days: UInt32
    /// 0...23. Use `totalHours` for the value as text renders it.
    public var hours: UInt8
    public var minutes: UInt8
    public var seconds: UInt8
    public var microseconds: UInt32

    public init(
        isNegative: Bool = false, days: UInt32 = 0, hours: UInt8 = 0,
        minutes: UInt8 = 0, seconds: UInt8 = 0, microseconds: UInt32 = 0
    ) {
        self.isNegative = isNegative; self.days = days; self.hours = hours
        self.minutes = minutes; self.seconds = seconds; self.microseconds = microseconds
    }

    public var totalHours: UInt32 { days * 24 + UInt32(hours) }
}

/// A decoded column value.
public enum MySQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case uint(UInt64)
    case float(Float)
    case double(Double)
    /// Strings, blobs, JSON, geometry, BIT, vectors — and DECIMAL, which stays
    /// textual so it never loses precision.
    case bytes([UInt8])
    case dateTime(MySQLDateTime)
    case time(MySQLTime)

    public var isNull: Bool { self == .null }

    public var string: String? {
        switch self {
        case .null: return nil
        case .bytes(let bytes): return String(bytes: bytes, encoding: .utf8)
        case .int(let value): return String(value)
        case .uint(let value): return String(value)
        case .float(let value): return String(value)
        case .double(let value): return String(value)
        // Rendered rather than nil: a DATETIME read back over the binary
        // protocol should stringify the same way it does over the text one.
        case .dateTime(let value): return MySQLValue.render(value)
        case .time(let value): return MySQLValue.render(value)
        }
    }

    public var int: Int64? {
        switch self {
        case .int(let value): return value
        case .uint(let value): return Int64(exactly: value)
        case .bytes(let bytes): return Int64(String(decoding: bytes, as: UTF8.self))
        default: return nil
        }
    }

    public var double: Double? {
        switch self {
        case .double(let value): return value
        case .float(let value): return Double(value)
        case .int(let value): return Double(value)
        case .uint(let value): return Double(value)
        case .bytes(let bytes): return Double(String(decoding: bytes, as: UTF8.self))
        default: return nil
        }
    }

    /// Bridges into `SwizzleCore`'s dialect-neutral value type.
    ///
    /// Temporals and exact numerics cross as text rather than being coerced:
    /// a DECIMAL turned into a `Double` here would defeat the point of keeping
    /// it textual on the wire.
    public var sqlValue: SQLValue {
        switch self {
        case .null: return .null
        case .int(let value): return .int(value)
        case .uint(let value): return Int64(exactly: value).map { .int($0) } ?? .text(String(value))
        case .float(let value): return .double(Double(value))
        case .double(let value): return .double(value)
        case .bytes(let bytes):
            return String(bytes: bytes, encoding: .utf8).map { SQLValue.text($0) } ?? .blob(bytes)
        case .dateTime(let value): return .text(MySQLValue.render(value))
        case .time(let value): return .text(MySQLValue.render(value))
        }
    }
}

// MARK: - Text protocol decoding

extension MySQLValue {
    /// Decodes a value from the text protocol, where everything arrives as an
    /// ASCII string.
    ///
    /// Everything here reads the bytes in place and allocates only when the
    /// result genuinely is bytes.
    ///
    /// The obvious shape — copy into `[UInt8]`, build a `String`, parse that —
    /// costs two heap allocations for every value that is *not* a string, and
    /// then discards both. Worse, the temporal parsers built on `split` paid for
    /// an array of `Substring`s per field. Measured on this path before the
    /// rewrite: an integer took 44 ns, a string 32 ns, and a `DATETIME`
    /// **907 ns** — so a single datetime column accounted for roughly 70% of the
    /// time to decode a five-column row.
    ///
    /// None of that needed C or arithmetic tricks; it needed not allocating.
    public static func decodeText(
        _ buffer: ByteBuffer, type: MySQLColumnType, flags: MySQLColumnFlags
    ) -> MySQLValue {
        // Exact numerics and anything byte-shaped stay as raw bytes, which is
        // the one case that has to allocate anyway.
        // `isExactNumeric` is presently a subset of `isBinaryEncodedAsBytes`,
        // so this reads as redundant and no test can kill dropping it — the
        // default arm below returns the same bytes. It stays because "DECIMAL
        // never becomes a Double" is an invariant of its own, and should not
        // rest on decimal happening to appear in another predicate's list.
        if type.isExactNumeric || type.isBinaryEncodedAsBytes {
            return .bytes(buffer.rawBytes)
        }
        if case .null = type { return .null }

        return buffer.withUnsafeReadableBytes { raw -> MySQLValue in
            switch type {
            case .tiny, .short, .int24, .long, .longlong, .year:
                if flags.contains(.unsigned) {
                    guard let value = parseUnsigned(raw) else { return .bytes(buffer.rawBytes) }
                    return .uint(value)
                }
                guard let value = parseSigned(raw) else { return .bytes(buffer.rawBytes) }
                return .int(value)

            // Floating point is left to the standard library. Correct decimal-to
            // -binary conversion is genuinely hard — it has to round to nearest
            // across the whole exponent range — and `Double.init(String:)` is
            // exact. A short numeric literal fits in a small string, so this
            // does not heap-allocate either.
            case .float:
                guard let value = Float(String(decoding: raw, as: UTF8.self)) else {
                    return .bytes(buffer.rawBytes)
                }
                return .float(value)
            case .double:
                guard let value = Double(String(decoding: raw, as: UTF8.self)) else {
                    return .bytes(buffer.rawBytes)
                }
                return .double(value)

            case .date, .datetime, .timestamp, .datetime2, .timestamp2:
                guard let value = parseDateTime(raw) else { return .bytes(buffer.rawBytes) }
                return .dateTime(value)
            case .time, .time2:
                guard let value = parseTime(raw) else { return .bytes(buffer.rawBytes) }
                return .time(value)

            default:
                return .bytes(buffer.rawBytes)
            }
        }
    }

    // MARK: Byte-level parsing
    //
    // These read ASCII directly out of the packet. Every one of them used to go
    // through `String` and `split`, which is where the text protocol spent most
    // of its time — see `decodeText`.
    //
    // They are stricter than their predecessors in one respect: trailing junk is
    // now rejected rather than partially ignored. `12:34:56.9z` used to decode
    // as 12:34:56 with the microseconds silently zeroed. Refusing it instead
    // means `decodeText` falls back to `.bytes`, so the caller receives the
    // server's literal text rather than a value that is quietly wrong.

    /// A cursor over ASCII bytes. Non-allocating and non-escaping.
    private struct Scanner {
        let bytes: UnsafeRawBufferPointer
        var index: Int = 0

        var isAtEnd: Bool { index >= bytes.count }

        /// Consumes `byte` if it is next.
        mutating func take(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        /// Consumes a run of digits. Nil if there are none, or if the value
        /// exceeds `limit` — which is how a field too large for its type is
        /// rejected rather than wrapped.
        mutating func digits(limit: UInt64) -> UInt64? {
            let start = index
            var value: UInt64 = 0
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                let (multiplied, overflowA) = value.multipliedReportingOverflow(by: 10)
                guard !overflowA else { return nil }
                let (added, overflowB) = multiplied.addingReportingOverflow(
                    UInt64(bytes[index] - 0x30)
                )
                guard !overflowB else { return nil }
                value = added
                index += 1
            }
            guard index > start, value <= limit else { return nil }
            return value
        }

        /// `.ffffff` — MySQL writes 1–6 digits and they scale to microseconds,
        /// so `.5` is 500000 rather than 5. Digits past the sixth are dropped,
        /// matching the server's own precision cap.
        mutating func fraction() -> UInt32? {
            guard take(0x2E) else { return 0 }   // '.'
            let start = index
            var value: UInt32 = 0
            var count = 0
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                if count < 6 {
                    value = value * 10 + UInt32(bytes[index] - 0x30)
                    count += 1
                }
                index += 1
            }
            guard index > start else { return nil }
            let scale: [UInt32] = [1_000_000, 100_000, 10_000, 1_000, 100, 10, 1]
            return value * scale[count]
        }
    }

    /// `YYYY-MM-DD[ HH:MM:SS[.ffffff]]`
    static func parseDateTime(_ raw: UnsafeRawBufferPointer) -> MySQLDateTime? {
        var scanner = Scanner(bytes: raw)
        guard let year = scanner.digits(limit: UInt64(UInt16.max)), scanner.take(0x2D),
              let month = scanner.digits(limit: UInt64(UInt8.max)), scanner.take(0x2D),
              let day = scanner.digits(limit: UInt64(UInt8.max))
        else { return nil }

        var result = MySQLDateTime(
            year: UInt16(year), month: UInt8(month), day: UInt8(day)
        )
        // A DATE column stops here; a DATETIME carries a clock as well.
        if scanner.isAtEnd { return result }

        guard scanner.take(0x20),                                        // ' '
              let hour = scanner.digits(limit: UInt64(UInt8.max)), scanner.take(0x3A),
              let minute = scanner.digits(limit: UInt64(UInt8.max)), scanner.take(0x3A),
              let second = scanner.digits(limit: UInt64(UInt8.max)),
              let micro = scanner.fraction(),
              scanner.isAtEnd
        else { return nil }

        result.hour = UInt8(hour)
        result.minute = UInt8(minute)
        result.second = UInt8(second)
        result.microsecond = micro
        return result
    }

    /// `[-]HHH:MM:SS[.ffffff]` — hours can exceed 24 and carry a sign, because
    /// TIME is a duration rather than a clock reading.
    static func parseTime(_ raw: UnsafeRawBufferPointer) -> MySQLTime? {
        var scanner = Scanner(bytes: raw)
        let isNegative = scanner.take(0x2D)                              // '-'

        guard let totalHours = scanner.digits(limit: UInt64(UInt32.max)), scanner.take(0x3A),
              let minutes = scanner.digits(limit: UInt64(UInt8.max)), scanner.take(0x3A),
              let seconds = scanner.digits(limit: UInt64(UInt8.max)),
              let micro = scanner.fraction(),
              scanner.isAtEnd
        else { return nil }

        return MySQLTime(
            isNegative: isNegative,
            days: UInt32(totalHours) / 24,
            hours: UInt8(UInt32(totalHours) % 24),
            minutes: UInt8(minutes),
            seconds: UInt8(seconds),
            microseconds: micro
        )
    }

    /// A signed decimal integer, with the optional sign MySQL may emit.
    static func parseSigned(_ raw: UnsafeRawBufferPointer) -> Int64? {
        var scanner = Scanner(bytes: raw)
        let isNegative = scanner.take(0x2D)
        if !isNegative { _ = scanner.take(0x2B) }                        // '+'
        // Int64.min has no positive counterpart, so a negative value is allowed
        // one more than `Int64.max` before it overflows.
        let limit = isNegative ? UInt64(Int64.max) + 1 : UInt64(Int64.max)
        guard let magnitude = scanner.digits(limit: limit), scanner.isAtEnd else { return nil }
        if isNegative {
            return magnitude == UInt64(Int64.max) + 1 ? Int64.min : -Int64(magnitude)
        }
        return Int64(magnitude)
    }

    static func parseUnsigned(_ raw: UnsafeRawBufferPointer) -> UInt64? {
        var scanner = Scanner(bytes: raw)
        _ = scanner.take(0x2B)
        guard let value = scanner.digits(limit: UInt64.max), scanner.isAtEnd else { return nil }
        return value
    }

    static func render(_ value: MySQLDateTime) -> String {
        func pad(_ number: some BinaryInteger, _ width: Int) -> String {
            String(repeating: "0", count: Swift.max(0, width - String(number).count)) + String(number)
        }
        var text = "\(pad(value.year, 4))-\(pad(value.month, 2))-\(pad(value.day, 2))"
        text += " \(pad(value.hour, 2)):\(pad(value.minute, 2)):\(pad(value.second, 2))"
        if value.microsecond > 0 { text += ".\(pad(value.microsecond, 6))" }
        return text
    }

    static func render(_ value: MySQLTime) -> String {
        func pad(_ number: some BinaryInteger, _ width: Int) -> String {
            String(repeating: "0", count: Swift.max(0, width - String(number).count)) + String(number)
        }
        var text = value.isNegative ? "-" : ""
        text += "\(pad(value.totalHours, 2)):\(pad(value.minutes, 2)):\(pad(value.seconds, 2))"
        if value.microseconds > 0 { text += ".\(pad(value.microseconds, 6))" }
        return text
    }
}

// MARK: - Binary protocol decoding

extension MySQLValue {
    /// Decodes one value from the binary protocol, advancing `buffer`.
    ///
    /// Layouts verified against rust-mysql-common's `read_bin_value`.
    public static func decodeBinary(
        _ buffer: inout ByteBuffer, type: MySQLColumnType, flags: MySQLColumnFlags
    ) throws -> MySQLValue {
        let unsigned = flags.contains(.unsigned)

        if type.isBinaryEncodedAsBytes {
            guard var slice = buffer.readLengthEncodedSlice(),
                  let bytes = slice.readBytes(length: slice.readableBytes)
            else {
                throw MySQLProtocolError.malformedPacket("binary value: truncated \(type)")
            }
            return .bytes(bytes)
        }

        switch type {
        case .tiny:
            guard let raw = buffer.readInteger(endianness: .little, as: UInt8.self) else {
                throw MySQLProtocolError.malformedPacket("binary value: truncated TINY")
            }
            return unsigned ? .uint(UInt64(raw)) : .int(Int64(Int8(bitPattern: raw)))

        case .short, .year:
            guard let raw = buffer.readInteger(endianness: .little, as: UInt16.self) else {
                throw MySQLProtocolError.malformedPacket("binary value: truncated SHORT")
            }
            return unsigned ? .uint(UInt64(raw)) : .int(Int64(Int16(bitPattern: raw)))

        // INT24 travels in 4 bytes on the wire despite being a 3-byte type.
        case .long, .int24:
            guard let raw = buffer.readInteger(endianness: .little, as: UInt32.self) else {
                throw MySQLProtocolError.malformedPacket("binary value: truncated LONG")
            }
            return unsigned ? .uint(UInt64(raw)) : .int(Int64(Int32(bitPattern: raw)))

        case .longlong:
            guard let raw = buffer.readInteger(endianness: .little, as: UInt64.self) else {
                throw MySQLProtocolError.malformedPacket("binary value: truncated LONGLONG")
            }
            return unsigned ? .uint(raw) : .int(Int64(bitPattern: raw))

        case .float:
            guard let raw = buffer.readInteger(endianness: .little, as: UInt32.self) else {
                throw MySQLProtocolError.malformedPacket("binary value: truncated FLOAT")
            }
            return .float(Float(bitPattern: raw))

        case .double:
            guard let raw = buffer.readInteger(endianness: .little, as: UInt64.self) else {
                throw MySQLProtocolError.malformedPacket("binary value: truncated DOUBLE")
            }
            return .double(Double(bitPattern: raw))

        case .date, .datetime, .timestamp, .datetime2, .timestamp2:
            return .dateTime(try decodeBinaryDateTime(&buffer))

        case .time, .time2:
            return .time(try decodeBinaryTime(&buffer))

        case .null:
            return .null

        default:
            throw MySQLProtocolError.malformedPacket("binary value: unhandled type \(type)")
        }
    }

    /// Length-prefixed and variable: 0, 4, 7 or 11 bytes by precision.
    ///
    /// The payload is consumed as a fixed-size slice so an unfamiliar length
    /// cannot desynchronise the rest of the row.
    static func decodeBinaryDateTime(_ buffer: inout ByteBuffer) throws -> MySQLDateTime {
        guard let length = buffer.readInteger(endianness: .little, as: UInt8.self),
              var body = buffer.readSlice(length: Int(length))
        else {
            throw MySQLProtocolError.malformedPacket("binary DATETIME: truncated")
        }

        var value = MySQLDateTime()
        if length >= 4 {
            value.year = body.readInteger(endianness: .little, as: UInt16.self) ?? 0
            value.month = body.readInteger(endianness: .little, as: UInt8.self) ?? 0
            value.day = body.readInteger(endianness: .little, as: UInt8.self) ?? 0
        }
        if length >= 7 {
            value.hour = body.readInteger(endianness: .little, as: UInt8.self) ?? 0
            value.minute = body.readInteger(endianness: .little, as: UInt8.self) ?? 0
            value.second = body.readInteger(endianness: .little, as: UInt8.self) ?? 0
        }
        if length >= 11 {
            value.microsecond = body.readInteger(endianness: .little, as: UInt32.self) ?? 0
        }
        return value
    }

    /// Length-prefixed: 0, 8 or 12 bytes — **not** the 7/11 of DATETIME, and it
    /// carries a sign and a whole-days field.
    static func decodeBinaryTime(_ buffer: inout ByteBuffer) throws -> MySQLTime {
        guard let length = buffer.readInteger(endianness: .little, as: UInt8.self),
              var body = buffer.readSlice(length: Int(length))
        else {
            throw MySQLProtocolError.malformedPacket("binary TIME: truncated")
        }

        var value = MySQLTime()
        if length >= 8 {
            value.isNegative = (body.readInteger(endianness: .little, as: UInt8.self) ?? 0) == 1
            value.days = body.readInteger(endianness: .little, as: UInt32.self) ?? 0
            value.hours = body.readInteger(endianness: .little, as: UInt8.self) ?? 0
            value.minutes = body.readInteger(endianness: .little, as: UInt8.self) ?? 0
            value.seconds = body.readInteger(endianness: .little, as: UInt8.self) ?? 0
        }
        if length >= 12 {
            value.microseconds = body.readInteger(endianness: .little, as: UInt32.self) ?? 0
        }
        return value
    }
}

extension ByteBuffer {
    /// All readable bytes as an array, without disturbing the reader index.
    var rawBytes: [UInt8] {
        getBytes(at: readerIndex, length: readableBytes) ?? []
    }
}

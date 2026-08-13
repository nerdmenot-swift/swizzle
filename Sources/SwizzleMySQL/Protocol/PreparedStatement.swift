import NIOCore

/// `COM_STMT_PREPARE_OK` — the 12-byte header of a prepare response.
public struct MySQLPrepareOK: Sendable, Equatable {
    public var statementID: UInt32
    public var columnCount: UInt16
    public var parameterCount: UInt16
    public var warningCount: UInt16

    public static func parse(_ buffer: inout ByteBuffer) throws -> MySQLPrepareOK {
        guard let status = buffer.readInteger(endianness: .little, as: UInt8.self),
              status == 0x00,
              let statementID = buffer.readInteger(endianness: .little, as: UInt32.self),
              let columnCount = buffer.readInteger(endianness: .little, as: UInt16.self),
              let parameterCount = buffer.readInteger(endianness: .little, as: UInt16.self)
        else {
            throw MySQLProtocolError.malformedPacket("malformed COM_STMT_PREPARE response")
        }
        _ = buffer.readInteger(endianness: .little, as: UInt8.self)   // reserved
        let warningCount = buffer.readInteger(endianness: .little, as: UInt16.self) ?? 0

        return MySQLPrepareOK(
            statementID: statementID,
            columnCount: columnCount,
            parameterCount: parameterCount,
            warningCount: warningCount
        )
    }
}

/// A statement prepared on the server.
///
/// Holds a server-side resource: until `COM_STMT_CLOSE` is sent, the server
/// keeps the statement allocated. That is what makes cache eviction a protocol
/// concern rather than just a memory one.
public struct MySQLPreparedStatement: Sendable, Equatable {
    public let id: UInt32
    public let query: String
    public let parameters: [MySQLColumnDefinition]
    public let columns: [MySQLColumnDefinition]

    public var parameterCount: Int { parameters.count }
}

/// Cursor mode for `COM_STMT_EXECUTE`.
public struct MySQLCursorType: OptionSet, Sendable {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let none      = MySQLCursorType([])
    /// Makes the server hold the result set and hand it over via
    /// `COM_STMT_FETCH` — the row-bounded streaming mode (Phase 5).
    public static let readOnly  = MySQLCursorType(rawValue: 0x01)
    public static let forUpdate = MySQLCursorType(rawValue: 0x02)
    public static let scrollable = MySQLCursorType(rawValue: 0x04)
}

public enum MySQLStatementCommands {
    /// Whole-request size above which parameters must be sent separately via
    /// `COM_STMT_SEND_LONG_DATA` rather than inline.
    public static let maxInlineRequestSize = MySQLPacketFraming.maxPayloadSize

    public static func prepare(_ query: String) -> ByteBuffer {
        .mysqlCommand(.stmtPrepare, argument: query)
    }

    public static func close(statementID: UInt32) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeInteger(MySQLCommand.stmtClose.rawValue, endianness: .little)
        buffer.writeInteger(statementID, endianness: .little)
        return buffer
    }

    public static func reset(statementID: UInt32) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeInteger(MySQLCommand.stmtReset.rawValue, endianness: .little)
        buffer.writeInteger(statementID, endianness: .little)
        return buffer
    }

    public static func fetch(statementID: UInt32, rows: UInt32) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeInteger(MySQLCommand.stmtFetch.rawValue, endianness: .little)
        buffer.writeInteger(statementID, endianness: .little)
        buffer.writeInteger(rows, endianness: .little)
        return buffer
    }

    public static func sendLongData(
        statementID: UInt32, parameterIndex: UInt16, chunk: [UInt8]
    ) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeInteger(MySQLCommand.stmtSendLongData.rawValue, endianness: .little)
        buffer.writeInteger(statementID, endianness: .little)
        buffer.writeInteger(parameterIndex, endianness: .little)
        buffer.writeBytes(chunk)
        return buffer
    }

    /// Builds `COM_STMT_EXECUTE`.
    ///
    /// Layout: command(1) + statement id(4) + flags(1) + iteration count(4) —
    /// 10 bytes — then, when there are parameters, the NULL bitmap, the
    /// `NEW_PARAMS_BOUND` byte, two type bytes per parameter, and finally the
    /// values.
    ///
    /// The NULL bitmap here is **client side**, so bit offset 0 — unlike the
    /// result rows the server sends back, which are offset 2.
    ///
    /// Returns `requiresLongData` when the assembled request would exceed one
    /// packet; the caller must then ship byte parameters with
    /// `COM_STMT_SEND_LONG_DATA` first and re-encode with `omittingByteValues`.
    public static func execute(
        statementID: UInt32,
        parameters: [MySQLValue],
        cursor: MySQLCursorType = .none,
        omittingByteValues: Bool = false
    ) -> (buffer: ByteBuffer, requiresLongData: Bool) {
        var buffer = ByteBuffer()
        buffer.writeInteger(MySQLCommand.stmtExecute.rawValue, endianness: .little)
        buffer.writeInteger(statementID, endianness: .little)
        buffer.writeInteger(cursor.rawValue, endianness: .little)
        buffer.writeInteger(UInt32(1), endianness: .little)   // iteration count is always 1

        guard !parameters.isEmpty else { return (buffer, false) }

        var bitmap = MySQLNullBitmap(columnCount: parameters.count, side: .client)
        var dataLength = 0
        for (index, parameter) in parameters.enumerated() {
            if parameter.isNull {
                bitmap.setNull(index)
            } else {
                dataLength += binaryLength(parameter)
            }
        }

        let totalLength = 10 + bitmap.bytes.count + 1 + parameters.count * 2 + dataLength
        let requiresLongData = totalLength > maxInlineRequestSize

        buffer.writeBytes(bitmap.bytes)
        buffer.writeInteger(UInt8(1), endianness: .little)   // NEW_PARAMS_BOUND

        for parameter in parameters {
            let (type, flags) = parameterType(parameter)
            buffer.writeInteger(type.rawValue, endianness: .little)
            buffer.writeInteger(flags, endianness: .little)
        }

        for parameter in parameters {
            if parameter.isNull { continue }
            if case .bytes = parameter, omittingByteValues { continue }
            encodeBinary(parameter, into: &buffer)
        }

        return (buffer, requiresLongData)
    }

    /// The type byte and flag byte a parameter is bound as.
    ///
    /// Integers always bind as `LONGLONG` regardless of magnitude — the server
    /// narrows them — and the `UNSIGNED` flag (0x80) is what keeps a large
    /// unsigned value from being read as negative.
    static func parameterType(_ value: MySQLValue) -> (MySQLColumnType, UInt8) {
        switch value {
        case .null: return (.null, 0)
        case .bytes: return (.varString, 0)
        case .int: return (.longlong, 0)
        case .uint: return (.longlong, 0x80)
        case .float: return (.float, 0)
        case .double: return (.double, 0)
        case .dateTime: return (.datetime, 0)
        case .time: return (.time, 0)
        }
    }

    static func binaryLength(_ value: MySQLValue) -> Int {
        switch value {
        case .null: return 0
        case .int, .uint, .double: return 8
        case .float: return 4
        case .bytes(let bytes):
            return lengthEncodedIntegerSize(UInt64(bytes.count)) + bytes.count
        case .dateTime(let value):
            if value.microsecond > 0 { return 12 }        // length byte + 11
            if value.hour == 0 && value.minute == 0 && value.second == 0 {
                return value.isZero ? 1 : 5               // length byte + 0 or 4
            }
            return 8                                      // length byte + 7
        case .time(let value):
            if value.microseconds > 0 { return 13 }       // length byte + 12
            let isZero = value.days == 0 && value.hours == 0
                && value.minutes == 0 && value.seconds == 0
            return isZero ? 1 : 9                         // length byte + 0 or 8
        }
    }

    static func lengthEncodedIntegerSize(_ value: UInt64) -> Int {
        switch value {
        case ..<0xFB: return 1
        case ..<0x1_0000: return 3
        case ..<0x100_0000: return 4
        default: return 9
        }
    }

    /// Writes a parameter in the binary protocol, mirroring `decodeBinary`.
    static func encodeBinary(_ value: MySQLValue, into buffer: inout ByteBuffer) {
        switch value {
        case .null:
            break
        case .int(let raw):
            buffer.writeInteger(raw, endianness: .little)
        case .uint(let raw):
            buffer.writeInteger(raw, endianness: .little)
        case .float(let raw):
            buffer.writeInteger(raw.bitPattern, endianness: .little)
        case .double(let raw):
            buffer.writeInteger(raw.bitPattern, endianness: .little)
        case .bytes(let bytes):
            buffer.writeLengthEncodedInteger(UInt64(bytes.count))
            buffer.writeBytes(bytes)
        case .dateTime(let value):
            encodeDateTime(value, into: &buffer)
        case .time(let value):
            encodeTime(value, into: &buffer)
        }
    }

    /// Only as many bytes as the value needs: 0, 4, 7 or 11 after the length.
    static func encodeDateTime(_ value: MySQLDateTime, into buffer: inout ByteBuffer) {
        if value.isZero {
            buffer.writeInteger(UInt8(0), endianness: .little)
            return
        }
        let hasTime = value.hour != 0 || value.minute != 0 || value.second != 0
        let hasMicros = value.microsecond > 0
        let length: UInt8 = hasMicros ? 11 : (hasTime ? 7 : 4)

        buffer.writeInteger(length, endianness: .little)
        buffer.writeInteger(value.year, endianness: .little)
        buffer.writeInteger(value.month, endianness: .little)
        buffer.writeInteger(value.day, endianness: .little)
        guard length >= 7 else { return }
        buffer.writeInteger(value.hour, endianness: .little)
        buffer.writeInteger(value.minute, endianness: .little)
        buffer.writeInteger(value.second, endianness: .little)
        guard length >= 11 else { return }
        buffer.writeInteger(value.microsecond, endianness: .little)
    }

    /// TIME uses 8/12-byte bodies, not DATETIME's 7/11.
    static func encodeTime(_ value: MySQLTime, into buffer: inout ByteBuffer) {
        let isZero = value.days == 0 && value.hours == 0
            && value.minutes == 0 && value.seconds == 0 && value.microseconds == 0
        if isZero {
            buffer.writeInteger(UInt8(0), endianness: .little)
            return
        }
        let length: UInt8 = value.microseconds > 0 ? 12 : 8
        buffer.writeInteger(length, endianness: .little)
        buffer.writeInteger(UInt8(value.isNegative ? 1 : 0), endianness: .little)
        buffer.writeInteger(value.days, endianness: .little)
        buffer.writeInteger(value.hours, endianness: .little)
        buffer.writeInteger(value.minutes, endianness: .little)
        buffer.writeInteger(value.seconds, endianness: .little)
        guard length >= 12 else { return }
        buffer.writeInteger(value.microseconds, endianness: .little)
    }
}

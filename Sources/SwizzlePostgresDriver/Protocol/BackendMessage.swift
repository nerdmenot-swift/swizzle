import NIOCore

/// Messages the server sends.
///
/// Decoding is the defensive half: every length and count comes off the wire and
/// is attacker-influenced in the sense that matters — a malformed or hostile
/// server must produce an error, never a crash and never a silent
/// misinterpretation. So every read is bounds-checked and a short buffer means
/// "wait for more", not "read whatever is there".
public enum PostgresBackendMessage: Sendable, Equatable {
    case authentication(PostgresAuthenticationRequest)
    case backendKeyData(processID: Int32, secretKey: Int32)
    case bindComplete
    case closeComplete
    case commandComplete(tag: String)
    case copyData([UInt8])
    case copyDone
    case copyInResponse(PostgresCopyResponse)
    case copyOutResponse(PostgresCopyResponse)
    case copyBothResponse(PostgresCopyResponse)
    case dataRow([[UInt8]?])
    case emptyQueryResponse
    case error(PostgresServerMessage)
    case noData
    case notice(PostgresServerMessage)
    case notification(processID: Int32, channel: String, payload: String)
    case negotiateProtocolVersion(newest: Int32, unsupported: [String])
    case parameterDescription([UInt32])
    case parameterStatus(name: String, value: String)
    case parseComplete
    case portalSuspended
    case readyForQuery(PostgresTransactionStatus)
    case rowDescription([PostgresColumnDescription])
}

/// What the server is asking for, in the `Authentication*` family.
public enum PostgresAuthenticationRequest: Sendable, Equatable {
    case ok
    case cleartextPassword
    case md5Password(salt: [UInt8])
    case sasl(mechanisms: [String])
    case saslContinue(data: [UInt8])
    case saslFinal(data: [UInt8])
    /// Kerberos and friends, which this driver does not implement — carried so
    /// the error can name what the server wanted.
    case unsupported(code: Int32)
}

/// The `ReadyForQuery` status byte.
///
/// The `failed` case is how a client knows a transaction is poisoned: every
/// statement after the first failure is rejected until rollback, and reporting
/// "syntax error" for the *next* twelve statements is how that turns into a
/// confusing bug report.
public enum PostgresTransactionStatus: UInt8, Sendable, Equatable {
    case idle = 0x49          // 'I'
    case inTransaction = 0x54 // 'T'
    case failed = 0x45        // 'E'
}

public struct PostgresCopyResponse: Sendable, Equatable {
    /// 0 for text, 1 for binary.
    public var format: Int8
    public var columnFormats: [Int16]
}

public struct PostgresColumnDescription: Sendable, Equatable {
    public var name: String
    /// 0 when the column is not a plain table column — an expression or a
    /// literal. The code generator leans on exactly this.
    public var tableOID: UInt32
    public var columnAttributeNumber: Int16
    public var dataTypeOID: UInt32
    public var dataTypeSize: Int16
    public var dataTypeModifier: Int32
    public var format: Int16
}

/// An `ErrorResponse` or `NoticeResponse`, field by field.
///
/// Kept as the whole field set rather than flattened to a message string: the
/// severity, the SQLSTATE, and the position within the statement are what turn a
/// failure into something a caller can act on, and throwing them away at the
/// protocol layer means nothing above can get them back.
public struct PostgresServerMessage: Sendable, Equatable {
    public var fields: [UInt8: String]

    public var severity: String { fields[0x53] ?? fields[0x56] ?? "ERROR" }  // 'S', 'V'
    public var sqlState: String { fields[0x43] ?? "" }                        // 'C'
    public var message: String { fields[0x4D] ?? "" }                         // 'M'
    public var detail: String? { fields[0x44] }                               // 'D'
    public var hint: String? { fields[0x48] }                                 // 'H'
    /// One-based index into the statement, when the server can point at the
    /// offending token.
    public var position: Int? { fields[0x50].flatMap(Int.init) }              // 'P'
    public var schemaName: String? { fields[0x73] }                           // 's'
    public var tableName: String? { fields[0x74] }                            // 't'
    public var columnName: String? { fields[0x63] }                           // 'c'
    public var constraintName: String? { fields[0x6E] }                       // 'n'
}

/// The wire said something that cannot be read.
public enum PostgresWireError: Error, Sendable, Equatable {
    case malformed(String)
    case unknownMessage(tag: UInt8)
}

extension PostgresBackendMessage {
    /// Reads one message, or returns nil when the buffer does not hold a whole
    /// one yet.
    ///
    /// Only consumes from `buffer` when a complete message is decoded, so a
    /// partial read leaves the buffer exactly as it was and the caller can simply
    /// try again after more bytes arrive.
    public static func decode(from buffer: inout ByteBuffer) throws -> PostgresBackendMessage? {
        // Tag plus length.
        guard buffer.readableBytes >= 5 else { return nil }

        let tag: UInt8 = buffer.getInteger(at: buffer.readerIndex)!
        let length: Int32 = buffer.getInteger(at: buffer.readerIndex + 1)!

        // The length counts itself, so anything under 4 is nonsense and would
        // make the body length negative.
        guard length >= 4 else {
            throw PostgresWireError.malformed("message length \(length) is below the minimum of 4")
        }

        let bodyLength = Int(length) - 4
        guard buffer.readableBytes >= 5 + bodyLength else { return nil }

        buffer.moveReaderIndex(forwardBy: 5)
        // Sliced so a message that under-reads its body cannot run into the next
        // one — the failure mode that turns one malformed message into a
        // desynchronised stream.
        var body = buffer.readSlice(length: bodyLength)!
        return try decode(tag: tag, body: &body)
    }

    static func decode(tag: UInt8, body: inout ByteBuffer) throws -> PostgresBackendMessage {
        switch tag {
        case UInt8(ascii: "R"): return .authentication(try decodeAuthentication(&body))
        case UInt8(ascii: "K"):
            return .backendKeyData(
                processID: try body.requireInteger("BackendKeyData.processID"),
                secretKey: try body.requireInteger("BackendKeyData.secretKey")
            )
        case UInt8(ascii: "2"): return .bindComplete
        case UInt8(ascii: "3"): return .closeComplete
        case UInt8(ascii: "C"): return .commandComplete(tag: try body.requireCString("CommandComplete"))
        case UInt8(ascii: "d"): return .copyData(body.readBytes(length: body.readableBytes) ?? [])
        case UInt8(ascii: "c"): return .copyDone
        case UInt8(ascii: "G"): return .copyInResponse(try decodeCopy(&body))
        case UInt8(ascii: "H"): return .copyOutResponse(try decodeCopy(&body))
        case UInt8(ascii: "W"): return .copyBothResponse(try decodeCopy(&body))
        case UInt8(ascii: "D"): return .dataRow(try decodeDataRow(&body))
        case UInt8(ascii: "I"): return .emptyQueryResponse
        case UInt8(ascii: "E"): return .error(try decodeServerMessage(&body))
        case UInt8(ascii: "n"): return .noData
        case UInt8(ascii: "N"): return .notice(try decodeServerMessage(&body))
        case UInt8(ascii: "A"):
            return .notification(
                processID: try body.requireInteger("NotificationResponse.processID"),
                channel: try body.requireCString("NotificationResponse.channel"),
                payload: try body.requireCString("NotificationResponse.payload")
            )
        case UInt8(ascii: "v"): return try decodeNegotiate(&body)
        case UInt8(ascii: "t"): return .parameterDescription(try decodeParameterDescription(&body))
        case UInt8(ascii: "S"):
            return .parameterStatus(
                name: try body.requireCString("ParameterStatus.name"),
                value: try body.requireCString("ParameterStatus.value")
            )
        case UInt8(ascii: "1"): return .parseComplete
        case UInt8(ascii: "s"): return .portalSuspended
        case UInt8(ascii: "Z"):
            let raw: UInt8 = try body.requireInteger("ReadyForQuery.status")
            guard let status = PostgresTransactionStatus(rawValue: raw) else {
                throw PostgresWireError.malformed(
                    "unknown transaction status '\(Character(UnicodeScalar(raw)))'"
                )
            }
            return .readyForQuery(status)
        case UInt8(ascii: "T"): return .rowDescription(try decodeRowDescription(&body))
        default:
            throw PostgresWireError.unknownMessage(tag: tag)
        }
    }

    static func decodeAuthentication(
        _ body: inout ByteBuffer
    ) throws -> PostgresAuthenticationRequest {
        let code: Int32 = try body.requireInteger("Authentication.code")
        switch code {
        case 0: return .ok
        case 3: return .cleartextPassword
        case 5:
            guard let salt = body.readBytes(length: 4) else {
                throw PostgresWireError.malformed("AuthenticationMD5Password needs a 4-byte salt")
            }
            return .md5Password(salt: salt)
        case 10:
            // A NUL-terminated list of mechanism names, ended by an empty one.
            var mechanisms: [String] = []
            while let name = try? body.requireCString("SASL mechanism"), !name.isEmpty {
                mechanisms.append(name)
            }
            return .sasl(mechanisms: mechanisms)
        case 11: return .saslContinue(data: body.readBytes(length: body.readableBytes) ?? [])
        case 12: return .saslFinal(data: body.readBytes(length: body.readableBytes) ?? [])
        default:
            // Kerberos (2), SCM credentials (6), GSS (7/8), SSPI (9). Carried
            // rather than thrown so the connection error can say which.
            return .unsupported(code: code)
        }
    }

    static func decodeCopy(_ body: inout ByteBuffer) throws -> PostgresCopyResponse {
        let format: Int8 = try body.requireInteger("CopyResponse.format")
        let count: Int16 = try body.requireInteger("CopyResponse.columnCount")
        var formats: [Int16] = []
        formats.reserveCapacity(Int(max(count, 0)))
        for _ in 0..<max(count, 0) {
            formats.append(try body.requireInteger("CopyResponse.columnFormat"))
        }
        return PostgresCopyResponse(format: format, columnFormats: formats)
    }

    static func decodeDataRow(_ body: inout ByteBuffer) throws -> [[UInt8]?] {
        let count: Int16 = try body.requireInteger("DataRow.columnCount")
        var values: [[UInt8]?] = []
        values.reserveCapacity(Int(max(count, 0)))
        for _ in 0..<max(count, 0) {
            let length: Int32 = try body.requireInteger("DataRow.valueLength")
            if length < 0 {
                // -1 is null, and is not the same as a zero-length value.
                values.append(nil)
                continue
            }
            guard let bytes = body.readBytes(length: Int(length)) else {
                throw PostgresWireError.malformed(
                    "DataRow claims a \(length)-byte value with \(body.readableBytes) left"
                )
            }
            values.append(bytes)
        }
        return values
    }

    static func decodeServerMessage(_ body: inout ByteBuffer) throws -> PostgresServerMessage {
        var fields: [UInt8: String] = [:]
        while let code: UInt8 = body.readInteger(), code != 0 {
            fields[code] = try body.requireCString("ErrorResponse field")
        }
        return PostgresServerMessage(fields: fields)
    }

    static func decodeNegotiate(_ body: inout ByteBuffer) throws -> PostgresBackendMessage {
        let newest: Int32 = try body.requireInteger("NegotiateProtocolVersion.newest")
        let count: Int32 = try body.requireInteger("NegotiateProtocolVersion.count")
        var unsupported: [String] = []
        for _ in 0..<max(count, 0) {
            unsupported.append(try body.requireCString("NegotiateProtocolVersion.option"))
        }
        return .negotiateProtocolVersion(newest: newest, unsupported: unsupported)
    }

    static func decodeParameterDescription(_ body: inout ByteBuffer) throws -> [UInt32] {
        let count: Int16 = try body.requireInteger("ParameterDescription.count")
        var oids: [UInt32] = []
        oids.reserveCapacity(Int(max(count, 0)))
        for _ in 0..<max(count, 0) {
            oids.append(try body.requireInteger("ParameterDescription.oid"))
        }
        return oids
    }

    static func decodeRowDescription(
        _ body: inout ByteBuffer
    ) throws -> [PostgresColumnDescription] {
        let count: Int16 = try body.requireInteger("RowDescription.fieldCount")
        var columns: [PostgresColumnDescription] = []
        columns.reserveCapacity(Int(max(count, 0)))
        for _ in 0..<max(count, 0) {
            columns.append(
                PostgresColumnDescription(
                    name: try body.requireCString("RowDescription.name"),
                    tableOID: try body.requireInteger("RowDescription.tableOID"),
                    columnAttributeNumber: try body.requireInteger("RowDescription.attnum"),
                    dataTypeOID: try body.requireInteger("RowDescription.typeOID"),
                    dataTypeSize: try body.requireInteger("RowDescription.typeSize"),
                    dataTypeModifier: try body.requireInteger("RowDescription.typeModifier"),
                    format: try body.requireInteger("RowDescription.format")
                )
            )
        }
        return columns
    }
}

extension ByteBuffer {
    /// Reads an integer, or says which field ran out of bytes.
    ///
    /// The field name is the point: "not enough bytes" from a protocol decoder is
    /// almost useless, while "RowDescription.typeOID needs 4 bytes, 1 available"
    /// says where the stream went wrong.
    mutating func requireInteger<T: FixedWidthInteger>(_ field: String) throws -> T {
        guard let value: T = readInteger() else {
            throw PostgresWireError.malformed(
                "\(field) needs \(MemoryLayout<T>.size) bytes, \(readableBytes) available"
            )
        }
        return value
    }

    mutating func requireCString(_ field: String) throws -> String {
        guard let index = readableBytesView.firstIndex(of: 0) else {
            throw PostgresWireError.malformed("\(field) is not NUL-terminated")
        }
        let length = index - readableBytesView.startIndex
        let value = readString(length: length) ?? ""
        moveReaderIndex(forwardBy: 1)
        return value
    }
}

import NIOCore

/// Command bytes. Only the ones we actually issue are listed; the full set is
/// in `docs/mysql-protocol-checklist.md §3`.
public enum MySQLCommand: UInt8, Sendable {
    case quit = 0x01
    case initDB = 0x02
    case query = 0x03
    case ping = 0x0E
    case changeUser = 0x11
    /// Replication: announce this connection as a replica.
    case registerSlave = 0x15
    case stmtPrepare = 0x16
    case stmtExecute = 0x17
    case stmtSendLongData = 0x18
    case stmtClose = 0x19
    case stmtReset = 0x1A
    case setOption = 0x1B
    case stmtFetch = 0x1C
    case resetConnection = 0x1F
    /// Replication: stream binlog events from a file and position.
    case binlogDump = 0x12
    /// Replication: stream binlog events from a GTID set. MySQL only —
    /// MariaDB uses `binlogDump` with `@slave_connect_state`.
    case binlogDumpGTID = 0x1E
    /// MariaDB only, 10.2+. Many parameter sets in one round trip.
    case stmtBulkExecute = 0xFA
}

extension ByteBuffer {
    /// A command packet is the command byte followed by its argument.
    ///
    /// Commands always restart the packet sequence at 0 — unlike the handshake,
    /// where the client continues the server's numbering.
    public static func mysqlCommand(_ command: MySQLCommand, argument: String? = nil) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeInteger(command.rawValue, endianness: .little)
        if let argument { buffer.writeString(argument) }
        return buffer
    }
}

/// Column flags from a `ColumnDefinition41`.
public struct MySQLColumnFlags: OptionSet, Sendable, Hashable {
    public var rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let notNull        = MySQLColumnFlags(rawValue: 1)
    public static let primaryKey     = MySQLColumnFlags(rawValue: 2)
    public static let uniqueKey      = MySQLColumnFlags(rawValue: 4)
    public static let multipleKey    = MySQLColumnFlags(rawValue: 8)
    public static let blob           = MySQLColumnFlags(rawValue: 16)
    /// Decides whether an integer column decodes as signed or unsigned — the
    /// column type alone does not say.
    public static let unsigned       = MySQLColumnFlags(rawValue: 32)
    public static let zerofill       = MySQLColumnFlags(rawValue: 64)
    public static let binary         = MySQLColumnFlags(rawValue: 128)
    public static let enumeration    = MySQLColumnFlags(rawValue: 256)
    public static let autoIncrement  = MySQLColumnFlags(rawValue: 512)
    public static let timestamp      = MySQLColumnFlags(rawValue: 1024)
    public static let set            = MySQLColumnFlags(rawValue: 2048)
    public static let noDefaultValue = MySQLColumnFlags(rawValue: 4096)
    public static let onUpdateNow    = MySQLColumnFlags(rawValue: 8192)
    public static let partKey        = MySQLColumnFlags(rawValue: 16384)
    public static let num            = MySQLColumnFlags(rawValue: 32768)
}

/// A `ColumnDefinition41` packet.
///
/// Field order verified against rust-mysql-common's `MyDeserialize for Column`.
/// Note their *serializer* writes `column_length` before `character_set`, the
/// reverse of their parser and of the MySQL documentation — the parser is the
/// authoritative one for a client, so that ordering is what we follow.
public struct MySQLColumnDefinition: Sendable, Equatable {
    /// Always "def" in practice.
    public var catalog: String
    public var schema: String
    /// Table alias as used in the query.
    public var table: String
    /// Physical table name.
    public var originalTable: String
    /// Column alias as used in the query.
    public var name: String
    /// Physical column name.
    public var originalName: String
    public var characterSet: UInt16
    public var columnLength: UInt32
    public var type: UInt8
    public var flags: MySQLColumnFlags
    public var decimals: UInt8

    /// Character set 63 is `binary`; it is how a BLOB is told from a TEXT and
    /// a VARBINARY from a VARCHAR, since both share a column type.
    public static let binaryCharacterSet: UInt16 = 63

    public var isBinary: Bool { characterSet == Self.binaryCharacterSet }
    public var isUnsigned: Bool { flags.contains(.unsigned) }

    public static func parse(_ buffer: inout ByteBuffer) throws -> MySQLColumnDefinition {
        func lenencString(_ field: String) throws -> String {
            guard let value = buffer.readLengthEncodedString() else {
                throw MySQLProtocolError.malformedPacket("column definition: truncated \(field)")
            }
            return value
        }

        let catalog = try lenencString("catalog")
        let schema = try lenencString("schema")
        let table = try lenencString("table")
        let originalTable = try lenencString("org_table")
        let name = try lenencString("name")
        let originalName = try lenencString("org_name")

        // Length of the fixed-length block that follows; always 0x0c.
        guard buffer.readLengthEncodedInteger() != nil else {
            throw MySQLProtocolError.malformedPacket("column definition: missing fixed-length marker")
        }
        guard let characterSet = buffer.readInteger(endianness: .little, as: UInt16.self),
              let columnLength = buffer.readInteger(endianness: .little, as: UInt32.self),
              let type = buffer.readInteger(endianness: .little, as: UInt8.self),
              let rawFlags = buffer.readInteger(endianness: .little, as: UInt16.self),
              let decimals = buffer.readInteger(endianness: .little, as: UInt8.self)
        else {
            throw MySQLProtocolError.malformedPacket("column definition: truncated fixed-length block")
        }
        // 2 filler bytes; absent on some MariaDB extended-metadata paths, so a
        // short read here is tolerated rather than fatal.
        _ = buffer.readBytes(length: min(2, buffer.readableBytes))

        return MySQLColumnDefinition(
            catalog: catalog,
            schema: schema,
            table: table,
            originalTable: originalTable,
            name: name,
            originalName: originalName,
            characterSet: characterSet,
            columnLength: columnLength,
            type: type,
            flags: MySQLColumnFlags(rawValue: rawFlags),
            decimals: decimals
        )
    }
}

// Row parsing lives in Row.swift — one `MySQLRow` type covering both the text
// and binary wire formats, decoded as it is parsed.

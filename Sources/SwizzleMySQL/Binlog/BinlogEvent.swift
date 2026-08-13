import CZlib
import NIOCore

/// Binlog event types.
///
/// The numbering is MySQL's, and MariaDB adds its own block from 160 upward
/// rather than extending MySQL's — which is why the two families are listed
/// separately below instead of interleaved.
public enum MySQLBinlogEventType: UInt8, Sendable {
    case unknown = 0x00
    case startV3 = 0x01
    case query = 0x02
    case stop = 0x03
    case rotate = 0x04
    case intvar = 0x05
    case load = 0x06
    case slave = 0x07
    case createFile = 0x08
    case appendBlock = 0x09
    case execLoad = 0x0A
    case deleteFile = 0x0B
    case newLoad = 0x0C
    case rand = 0x0D
    case userVar = 0x0E
    case formatDescription = 0x0F
    case xid = 0x10
    case beginLoadQuery = 0x11
    case executeLoadQuery = 0x12
    case tableMap = 0x13
    case preGAWriteRows = 0x14
    case preGAUpdateRows = 0x15
    case preGADeleteRows = 0x16
    /// The v1 row events. MariaDB still emits these; MySQL 5.6+ emits v2.
    case writeRowsV1 = 0x17
    case updateRowsV1 = 0x18
    case deleteRowsV1 = 0x19
    case incident = 0x1A
    case heartbeat = 0x1B
    case ignorable = 0x1C
    case rowsQuery = 0x1D
    case writeRows = 0x1E
    case updateRows = 0x1F
    case deleteRows = 0x20
    case gtid = 0x21
    case anonymousGtid = 0x22
    case previousGtids = 0x23
    case transactionContext = 0x24
    case viewChange = 0x25
    case xaPrepareLog = 0x26
    case partialUpdateRows = 0x27
    case transactionPayload = 0x28
    case heartbeatV2 = 0x29
    /// MySQL 8.4+. A GTID carrying a user-defined tag alongside the UUID, so
    /// one server can maintain several independent GTID sequences.
    case gtidTaggedLog = 0x2A

    // MariaDB's own block. Deliberately distinct numbers, not an extension of
    // the above — a MySQL event 160 does not exist.
    case mariaDBAnnotateRows = 160
    case mariaDBBinlogCheckpoint = 161
    case mariaDBGtid = 162
    case mariaDBGtidList = 163
    case mariaDBStartEncryption = 164
    case mariaDBQueryCompressed = 165
    case mariaDBWriteRowsCompressedV1 = 166
    case mariaDBUpdateRowsCompressedV1 = 167
    case mariaDBDeleteRowsCompressedV1 = 168
    case mariaDBWriteRowsCompressed = 169
    case mariaDBUpdateRowsCompressed = 170
    case mariaDBDeleteRowsCompressed = 171

    /// Whether this event carries row images that need a preceding `TABLE_MAP`.
    public var isRowEvent: Bool {
        switch self {
        case .writeRows, .updateRows, .deleteRows,
             .writeRowsV1, .updateRowsV1, .deleteRowsV1,
             .partialUpdateRows:
            true
        default:
            false
        }
    }
}

/// The 19-byte header every event carries.
public struct MySQLBinlogEventHeader: Sendable, Equatable {
    public static let byteCount = 19

    /// Seconds since the Unix epoch. Zero on artificial events such as the
    /// fake `ROTATE` the server sends when a stream starts.
    public var timestamp: UInt32
    /// Raw type byte, kept alongside the parsed enum so an unrecognised event
    /// can still be reported and skipped by size.
    public var rawEventType: UInt8
    public var serverID: UInt32
    /// Total event length including this header and any checksum.
    public var eventSize: UInt32
    /// Offset of the *next* event in the binlog file.
    public var logPosition: UInt32
    public var flags: UInt16

    public var eventType: MySQLBinlogEventType? {
        MySQLBinlogEventType(rawValue: rawEventType)
    }

    /// Set on the fake `ROTATE` and `FORMAT_DESCRIPTION` a server synthesises at
    /// the start of a dump. Those do not correspond to real file contents, so a
    /// consumer tracking position must not treat them as progress.
    public var isArtificial: Bool { flags & 0x0020 != 0 }

    public static func parse(_ buffer: inout ByteBuffer) throws -> MySQLBinlogEventHeader {
        guard buffer.readableBytes >= byteCount else {
            throw MySQLProtocolError.malformedPacket("binlog: truncated event header")
        }
        return MySQLBinlogEventHeader(
            timestamp: buffer.readInteger(endianness: .little, as: UInt32.self)!,
            rawEventType: buffer.readInteger(as: UInt8.self)!,
            serverID: buffer.readInteger(endianness: .little, as: UInt32.self)!,
            eventSize: buffer.readInteger(endianness: .little, as: UInt32.self)!,
            logPosition: buffer.readInteger(endianness: .little, as: UInt32.self)!,
            flags: buffer.readInteger(endianness: .little, as: UInt16.self)!
        )
    }
}

/// Trailing-checksum algorithm, announced by `FORMAT_DESCRIPTION_EVENT`.
public enum MySQLBinlogChecksum: UInt8, Sendable {
    case none = 0
    case crc32 = 1

    public var byteCount: Int { self == .crc32 ? 4 : 0 }
}

/// A raw event: header plus undecoded body, with the checksum already verified
/// and stripped.
public struct MySQLRawBinlogEvent: Sendable {
    public var header: MySQLBinlogEventHeader
    /// Body only — no header, no checksum.
    public var body: ByteBuffer

    public var eventType: MySQLBinlogEventType? { header.eventType }
}

public enum MySQLBinlogFraming {

    /// Splits one event packet into header and body, verifying the checksum.
    ///
    /// The checksum covers the header *and* body but not itself, so it has to be
    /// computed before the header is consumed — hence the slice taken up front.
    ///
    /// `checksum` comes from the `FORMAT_DESCRIPTION_EVENT` that opens every
    /// stream, and is genuinely dynamic: the same server can be reconfigured
    /// between binlog files, and the format-description event itself is a
    /// special case (see `formatDescriptionChecksum`).
    public static func parseEvent(
        _ payload: ByteBuffer, checksum: MySQLBinlogChecksum
    ) throws -> MySQLRawBinlogEvent {
        var buffer = payload
        let total = buffer.readableBytes

        guard total >= MySQLBinlogEventHeader.byteCount + checksum.byteCount else {
            throw MySQLProtocolError.malformedPacket(
                "binlog: event of \(total) bytes is too short"
            )
        }

        if checksum == .crc32 {
            let covered = total - 4
            let data = buffer.getBytes(at: buffer.readerIndex, length: covered)!
            let expected = buffer.getInteger(
                at: buffer.readerIndex + covered, endianness: .little, as: UInt32.self
            )!
            let actual = crc32Checksum(data)
            guard actual == expected else {
                throw MySQLProtocolError.malformedPacket(
                    "binlog: CRC32 mismatch — expected \(expected), computed \(actual)"
                )
            }
        }

        let header = try MySQLBinlogEventHeader.parse(&buffer)
        let bodyLength = total - MySQLBinlogEventHeader.byteCount - checksum.byteCount
        guard let body = buffer.readSlice(length: bodyLength) else {
            throw MySQLProtocolError.malformedPacket("binlog: truncated event body")
        }
        return MySQLRawBinlogEvent(header: header, body: body)
    }

    /// zlib's `crc32`, which is the same polynomial and convention the server
    /// uses. Reusing it avoids a hand-written table — and zlib is already linked
    /// for the compressed protocol.
    public static func crc32Checksum(_ bytes: [UInt8]) -> UInt32 {
        bytes.withUnsafeBufferPointer { pointer in
            UInt32(crc32(0, pointer.baseAddress, uInt(pointer.count)))
        }
    }
}

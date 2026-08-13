import NIOCore

/// Where a binlog stream should start.
public enum MySQLBinlogPosition: Sendable {
    /// A filename and offset, as `SHOW BINARY LOGS` / `SHOW MASTER STATUS`
    /// report them. An empty filename asks for the oldest binlog the server
    /// still has.
    case file(name: String, position: UInt32)
    /// A GTID set, e.g. MariaDB's `0-1-100` or MySQL's
    /// `uuid:1-100`. Resumes from the first transaction *not* in the set, which
    /// is what makes exactly-once handoff possible after a restart.
    case gtid(String)
    /// From the beginning of the oldest retained binlog.
    case earliest
}

public struct MySQLBinlogDumpFlags: OptionSet, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// Return EOF instead of blocking once the end of the binlog is reached.
    /// Useful for a bounded read; the default is to block and stream forever.
    public static let nonBlocking = MySQLBinlogDumpFlags(rawValue: 0x01)
}

public enum MySQLBinlogCommands {

    /// `COM_REGISTER_SLAVE`.
    ///
    /// Announces this connection as a replica. The host, user, password and port
    /// fields exist so a primary can display replicas in `SHOW SLAVE HOSTS`;
    /// real clients leave them empty and so do we — sending credentials here
    /// would put them on the wire a second time for no benefit.
    public static func registerSlave(serverID: UInt32) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeInteger(MySQLCommand.registerSlave.rawValue)
        buffer.writeInteger(serverID, endianness: .little)
        buffer.writeInteger(UInt8(0))        // hostname length
        buffer.writeInteger(UInt8(0))        // user length
        buffer.writeInteger(UInt8(0))        // password length
        buffer.writeInteger(UInt16(0), endianness: .little)   // port
        buffer.writeInteger(UInt32(0), endianness: .little)   // replication rank, ignored
        buffer.writeInteger(UInt32(0), endianness: .little)   // master id
        return buffer
    }

    /// `COM_BINLOG_DUMP` — file-and-position addressing.
    ///
    /// ```
    /// int<1>   0x12
    /// int<4>   position
    /// int<2>   flags
    /// int<4>   server id
    /// string   filename, to end of packet
    /// ```
    public static func dump(
        serverID: UInt32,
        filename: String,
        position: UInt32,
        flags: MySQLBinlogDumpFlags = []
    ) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeInteger(MySQLCommand.binlogDump.rawValue)
        // A position below 4 is invalid — every binlog file opens with a 4-byte
        // magic — and the server answers with a confusing error rather than
        // clamping, so it is clamped here.
        buffer.writeInteger(max(position, 4), endianness: .little)
        buffer.writeInteger(flags.rawValue, endianness: .little)
        buffer.writeInteger(serverID, endianness: .little)
        buffer.writeString(filename)
        return buffer
    }

    /// `COM_BINLOG_DUMP_GTID` — resume from a GTID set.
    ///
    /// ```
    /// int<1>   0x1E
    /// int<2>   flags
    /// int<4>   server id
    /// int<4>   filename length
    /// string   filename
    /// int<8>   position
    /// int<4>   gtid data length
    /// blob     gtid data
    /// ```
    ///
    /// **MySQL only.** MariaDB uses the same `COM_BINLOG_DUMP` command and takes
    /// its GTID position from the `@slave_connect_state` session variable
    /// instead — see `MySQLConnection.startBinlogStream`.
    public static func dumpGTID(
        serverID: UInt32,
        filename: String,
        position: UInt64,
        gtidData: [UInt8],
        flags: MySQLBinlogDumpFlags = []
    ) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeInteger(MySQLCommand.binlogDumpGTID.rawValue)
        buffer.writeInteger(flags.rawValue, endianness: .little)
        buffer.writeInteger(serverID, endianness: .little)
        buffer.writeInteger(UInt32(filename.utf8.count), endianness: .little)
        buffer.writeString(filename)
        buffer.writeInteger(position, endianness: .little)
        buffer.writeInteger(UInt32(gtidData.count), endianness: .little)
        buffer.writeBytes(gtidData)
        return buffer
    }
}

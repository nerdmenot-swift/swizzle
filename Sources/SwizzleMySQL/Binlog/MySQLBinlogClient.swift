import Foundation
import NIOCore

extension MySQLConnection {

    /// Turns this connection into a binlog event stream.
    ///
    /// **The connection is consumed.** After `COM_BINLOG_DUMP` the server streams
    /// events until the socket closes; there is no way back to ordinary command
    /// use, so a binlog consumer needs its own connection and must never take one
    /// from a pool it intends to give back.
    ///
    /// A blocking dump — the default — never ends on its own. Stop it by breaking
    /// out of the loop or cancelling the task, either of which closes the
    /// connection. Pass `.nonBlocking` to have the stream finish at the current
    /// end of the log instead, which is what makes a bounded read possible.
    ///
    /// - Parameters:
    ///   - serverID: must be unique among everything replicating from this
    ///     primary. A collision causes the server to drop the *other* replica,
    ///     which is a memorably confusing failure to debug from this side.
    ///   - position: where to resume. `.gtid` is the safe choice for restart —
    ///     a file offset recorded before a failover points into a file the new
    ///     primary may never have had.
    public func startBinlogStream(
        serverID: UInt32,
        from position: MySQLBinlogPosition = .earliest,
        flags: MySQLBinlogDumpFlags = []
    ) async throws -> MySQLBinlogSequence {
        // Tells the primary this replica understands checksummed events. Without
        // it a checksum-enabled server sends events whose trailing 4 bytes we
        // would read as data — the corruption appears in the *next* event, not
        // this one, which makes it painful to trace.
        _ = try await query("SET @master_binlog_checksum = @@global.binlog_checksum")

        // Some primaries refuse a dump from a connection that has not registered.
        _ = try await send(MySQLBinlogCommands.registerSlave(serverID: serverID), kind: .resultSet(.text))

        let payload: ByteBuffer
        switch position {
        case .earliest:
            payload = MySQLBinlogCommands.dump(
                serverID: serverID, filename: "", position: 4, flags: flags
            )

        case .file(let name, let offset):
            payload = MySQLBinlogCommands.dump(
                serverID: serverID, filename: name, position: offset, flags: flags
            )

        case .gtid(let set):
            if metadata.isMariaDB {
                // MariaDB has no COM_BINLOG_DUMP_GTID. The position is set
                // through session variables and then an ordinary dump is issued
                // — a genuine protocol difference, not a convenience wrapper.
                _ = try await query("SET @slave_connect_state = '\(escaped(set))'")
                _ = try await query("SET @slave_gtid_strict_mode = 0")
                _ = try await query("SET @slave_gtid_ignore_duplicates = 0")
                payload = MySQLBinlogCommands.dump(
                    serverID: serverID, filename: "", position: 4, flags: flags
                )
            } else {
                payload = MySQLBinlogCommands.dumpGTID(
                    serverID: serverID,
                    filename: "",
                    position: 4,
                    gtidData: try MySQLGtidSet.encodeForDump(set),
                    flags: flags
                )
            }
        }

        let response = try await send(payload, kind: .binlog)
        guard case .binlog(let sequence) = response else {
            throw MySQLProtocolError.unexpectedPacket("binlog: unexpected response to dump")
        }
        return sequence
    }

    /// Single-quote escaping for the MariaDB session-variable path above. The
    /// value is a GTID set, so this is belt-and-braces rather than load-bearing —
    /// but it is still caller-supplied text going into a statement.
    private func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    /// Current binlog filename and position.
    ///
    /// The starting point for a first-time consumer that wants only new changes
    /// rather than the whole retained history.
    ///
    /// The statement has three spellings and **no single one works everywhere**:
    ///
    /// | server | statement |
    /// |---|---|
    /// | MariaDB 10.5.2+ | `SHOW BINLOG STATUS` |
    /// | MariaDB, older | `SHOW MASTER STATUS` |
    /// | MySQL 8.4+ / 9.x | `SHOW BINARY LOG STATUS` |
    ///
    /// MySQL 8.4 renamed it *and removed* `SHOW MASTER STATUS`, so a client that
    /// only knows the old name fails outright on every current MySQL. Dispatch is
    /// on the flavour first, with a fallback, rather than a blind cascade —
    /// swallowing errors to try the next spelling would also swallow a genuine
    /// "you lack BINLOG MONITOR" and report it as a missing status row.
    public func binlogPosition() async throws -> (filename: String, position: UInt32) {
        let candidates = metadata.isMariaDB
            ? ["SHOW BINLOG STATUS", "SHOW MASTER STATUS"]
            : ["SHOW BINARY LOG STATUS", "SHOW MASTER STATUS"]

        var result: MySQLQueryResult?
        var lastError: (any Error)?
        for statement in candidates {
            do {
                result = try await query(statement)
                break
            } catch let error as MySQLProtocolError {
                // 1064 is a syntax error — this server spells it differently, so
                // try the next. Anything else (a privilege failure, say) is real
                // and must surface as itself.
                if case .server(let code, _, _) = error, code == 1064 {
                    lastError = error
                    continue
                }
                throw error
            }
        }
        guard let result else {
            throw lastError ?? MySQLProtocolError.malformedPacket(
                "binlog: no usable status statement for this server"
            )
        }
        guard let row = result.rows.first,
              let filename = row[0].string,
              let position = row[1].int
        else {
            throw MySQLProtocolError.malformedPacket("binlog: no status row — is log_bin on?")
        }
        return (filename, UInt32(position))
    }
}

/// GTID-set encoding for `COM_BINLOG_DUMP_GTID`.
public enum MySQLGtidSet {
    /// Encodes a MySQL GTID set into the binary form the dump command expects.
    ///
    /// ```
    /// int<8>   number of source uuids
    /// per uuid:
    ///   16 bytes  uuid
    ///   int<8>    number of intervals
    ///   per interval: int<8> start, int<8> end   (end is exclusive)
    /// ```
    public static func encodeForDump(_ set: String) throws -> [UInt8] {
        var sources: [(uuid: [UInt8], intervals: [(UInt64, UInt64)])] = []

        for entry in set.split(separator: ",") {
            let parts = entry.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
            guard parts.count >= 2, let uuid = parseUUID(String(parts[0])) else {
                throw MySQLProtocolError.malformedPacket("binlog: malformed GTID set '\(set)'")
            }
            var intervals: [(UInt64, UInt64)] = []
            for range in parts.dropFirst() {
                let bounds = range.split(separator: "-")
                guard let start = UInt64(bounds[0]) else {
                    throw MySQLProtocolError.malformedPacket("binlog: malformed GTID range")
                }
                let end = bounds.count > 1 ? (UInt64(bounds[1]) ?? start) : start
                // The wire format's end bound is exclusive; the text form's is
                // inclusive. Getting this wrong silently skips or repeats one
                // transaction at every resume.
                intervals.append((start, end + 1))
            }
            sources.append((uuid, intervals))
        }

        var out = [UInt8]()
        appendLittleEndian(UInt64(sources.count), to: &out)
        for source in sources {
            out += source.uuid
            appendLittleEndian(UInt64(source.intervals.count), to: &out)
            for interval in source.intervals {
                appendLittleEndian(interval.0, to: &out)
                appendLittleEndian(interval.1, to: &out)
            }
        }
        return out
    }

    static func appendLittleEndian(_ value: UInt64, to out: inout [UInt8]) {
        for shift in stride(from: 0, to: 64, by: 8) {
            out.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    static func parseUUID(_ text: String) -> [UInt8]? {
        let hex = text.replacingOccurrences(of: "-", with: "")
        guard hex.count == 32 else { return nil }
        var out = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}

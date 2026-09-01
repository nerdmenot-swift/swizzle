import NIOCore

/// OK packet — also the terminator of a result set when `CLIENT_DEPRECATE_EOF`
/// is negotiated, in which case its header byte is `0xFE` rather than `0x00`.
/// A session-state change the server reported alongside an OK packet.
public enum MySQLSessionStateChange: Sendable, Equatable {
    case systemVariable(name: String, value: String)
    case schema(String)
    case stateChanged(Bool)
    case gtids(String)
    case transactionCharacteristics(String)
    case transactionState(String)
    case unknown(type: UInt8)
}

public struct MySQLOKPacket: Sendable, Equatable {
    public var affectedRows: UInt64
    public var lastInsertID: UInt64
    public var statusFlags: MySQLStatusFlags
    public var warningCount: UInt16
    public var info: String?
    /// Populated when `SESSION_TRACK` is negotiated and the server reports a
    /// change — a `USE`, a `SET`, an autocommit flip.
    public var sessionStateChanges: [MySQLSessionStateChange] = []

    /// Distinguishing an OK from an EOF/row packet needs the header byte *and*
    /// the length: a `0xFE` header is only an EOF marker when the payload is
    /// under 9 bytes, otherwise it is a length-encoded integer in row data.
    public static func isOK(_ packet: MySQLPacket) -> Bool {
        guard let first = packet.firstByte else { return false }
        if first == 0x00 { return true }
        if first == 0xFE, packet.payload.readableBytes < 9 { return true }
        return false
    }

    public static func parse(
        _ buffer: inout ByteBuffer, capabilities: MySQLCapabilities
    ) throws -> MySQLOKPacket {
        guard let header = buffer.readInteger(endianness: .little, as: UInt8.self),
              header == 0x00 || header == 0xFE
        else {
            throw MySQLProtocolError.malformedPacket("expected OK header")
        }
        guard let affectedRows = buffer.readLengthEncodedInteger(),
              let lastInsertID = buffer.readLengthEncodedInteger()
        else {
            throw MySQLProtocolError.malformedPacket("truncated OK body")
        }

        var statusFlags: MySQLStatusFlags = []
        var warningCount: UInt16 = 0
        if capabilities.contains(.protocol41) {
            guard let rawStatus = buffer.readInteger(endianness: .little, as: UInt16.self),
                  let warnings = buffer.readInteger(endianness: .little, as: UInt16.self)
            else {
                throw MySQLProtocolError.malformedPacket("truncated OK status block")
            }
            statusFlags = MySQLStatusFlags(rawValue: rawStatus)
            warningCount = warnings
        }

        // The trailing `info` field changes encoding based on a capability we
        // actually negotiate: with SESSION_TRACK it is length-encoded and may be
        // followed by a state-change block, without it it simply runs to the end
        // of the packet. Reading the wrong form swallows the state changes into
        // the info string.
        var info: String?
        var changes: [MySQLSessionStateChange] = []

        if capabilities.contains(.sessionTrack) {
            // The emptiness check is a readability guard, not a correctness
            // one — on an empty buffer the read below returns nil and `info`
            // stays nil either way, so no test can kill a mutation of it.
            if buffer.readableBytes > 0 {
                info = buffer.readLengthEncodedString()
            }
            if statusFlags.contains(.sessionStateChanged),
               var block = buffer.readLengthEncodedSlice() {
                changes = parseSessionStateChanges(&block)
            }
        } else if buffer.readableBytes > 0 {
            info = buffer.readString(length: buffer.readableBytes)
        }

        return MySQLOKPacket(
            affectedRows: affectedRows,
            lastInsertID: lastInsertID,
            statusFlags: statusFlags,
            warningCount: warningCount,
            info: info,
            sessionStateChanges: changes
        )
    }

    /// Each entry is a type byte, a length-encoded payload, and a per-type body.
    ///
    /// An unrecognised type is skipped by its declared length rather than
    /// guessed at, so a newer tracker cannot desynchronise the rest.
    static func parseSessionStateChanges(
        _ buffer: inout ByteBuffer
    ) -> [MySQLSessionStateChange] {
        var changes: [MySQLSessionStateChange] = []

        // Likewise not load-bearing: the guard inside breaks on a short read,
        // so the loop terminates on an empty buffer with or without this.
        while buffer.readableBytes > 0 {
            guard let type = buffer.readInteger(endianness: .little, as: UInt8.self),
                  var body = buffer.readLengthEncodedSlice()
            else { break }

            switch type {
            case 0x00:
                if let name = body.readLengthEncodedString(),
                   let value = body.readLengthEncodedString() {
                    changes.append(.systemVariable(name: name, value: value))
                }
            case 0x01:
                if let schema = body.readLengthEncodedString() {
                    changes.append(.schema(schema))
                }
            case 0x02:
                if let flag = body.readLengthEncodedString() {
                    changes.append(.stateChanged(flag == "1"))
                }
            case 0x03:
                if let gtids = body.readLengthEncodedString() {
                    changes.append(.gtids(gtids))
                }
            case 0x04:
                if let text = body.readLengthEncodedString() {
                    changes.append(.transactionCharacteristics(text))
                }
            case 0x05:
                if let text = body.readLengthEncodedString() {
                    changes.append(.transactionState(text))
                }
            default:
                changes.append(.unknown(type: type))
            }
        }
        return changes
    }
}

/// ERR packet.
public struct MySQLErrorPacket: Sendable, Equatable {
    public var errorCode: UInt16
    public var sqlState: String?
    public var message: String

    public static func isError(_ packet: MySQLPacket) -> Bool {
        packet.firstByte == 0xFF
    }

    public static func parse(
        _ buffer: inout ByteBuffer, capabilities: MySQLCapabilities
    ) throws -> MySQLErrorPacket {
        guard let header = buffer.readInteger(endianness: .little, as: UInt8.self),
              header == 0xFF
        else {
            throw MySQLProtocolError.malformedPacket("expected ERR header")
        }
        guard let errorCode = buffer.readInteger(endianness: .little, as: UInt16.self) else {
            throw MySQLProtocolError.malformedPacket("truncated ERR code")
        }

        // During the handshake phase the server may send an ERR *without* the
        // SQL-state block, so it is detected by its '#' marker rather than
        // assumed from the capability flags.
        var sqlState: String?
        if capabilities.contains(.protocol41),
           buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) == UInt8(ascii: "#") {
            buffer.moveReaderIndex(forwardBy: 1)
            sqlState = buffer.readString(length: 5)
        }

        let message = buffer.readString(length: buffer.readableBytes) ?? ""
        return MySQLErrorPacket(errorCode: errorCode, sqlState: sqlState, message: message)
    }

    public var asProtocolError: MySQLProtocolError {
        .server(code: errorCode, sqlState: sqlState ?? "", message: message)
    }
}

/// EOF packet — only sent when `CLIENT_DEPRECATE_EOF` was *not* negotiated.
public struct MySQLEOFPacket: Sendable, Equatable {
    public var warningCount: UInt16
    public var statusFlags: MySQLStatusFlags

    public static func isEOF(_ packet: MySQLPacket) -> Bool {
        packet.firstByte == 0xFE && packet.payload.readableBytes < 9
    }

    public static func parse(_ buffer: inout ByteBuffer) throws -> MySQLEOFPacket {
        guard let header = buffer.readInteger(endianness: .little, as: UInt8.self),
              header == 0xFE
        else {
            throw MySQLProtocolError.malformedPacket("expected EOF header")
        }
        let warnings = buffer.readInteger(endianness: .little, as: UInt16.self) ?? 0
        let status = buffer.readInteger(endianness: .little, as: UInt16.self) ?? 0
        return MySQLEOFPacket(
            warningCount: warnings, statusFlags: MySQLStatusFlags(rawValue: status)
        )
    }
}

/// `AuthSwitchRequest` — header `0xFE` during the auth phase, carrying a new
/// plugin name and a fresh scramble.
public struct MySQLAuthSwitchRequest: Sendable, Equatable {
    public var pluginName: String
    public var pluginData: [UInt8]

    public static func parse(_ buffer: inout ByteBuffer) throws -> MySQLAuthSwitchRequest {
        guard let header = buffer.readInteger(endianness: .little, as: UInt8.self),
              header == 0xFE
        else {
            throw MySQLProtocolError.malformedPacket("expected AuthSwitchRequest header")
        }
        guard let pluginName = buffer.readNullTerminatedString() else {
            throw MySQLProtocolError.malformedPacket("AuthSwitchRequest missing plugin name")
        }
        var data = buffer.readBytes(length: buffer.readableBytes) ?? []

        // Whether a trailing NUL is present depends on the plugin, and getting
        // this wrong is silent and rare.
        //
        // The classic plugins send `scramble || 0x00` — a 20-byte scramble in a
        // 21-byte field. MariaDB's `client_ed25519` and `parsec` instead send a
        // fixed **32-byte** scramble with no terminator. Stripping a trailing
        // zero unconditionally therefore corrupts exactly those scrambles whose
        // last random byte happens to be `0x00`: one in 256, producing a
        // signature over a 31-byte message and an "Access denied" that looks
        // like a wrong password.
        //
        // Found by a binlog test run putting enough connections through the
        // ed25519 path to hit it — 1 failure in 120 concurrent connections,
        // and none in 120 sequential ones, which is what made it look like a
        // concurrency bug rather than an arithmetic one.
        switch MySQLAuthPlugin(name: pluginName) {
        case .ed25519, .parsec:
            break                                  // fixed width, no terminator
        default:
            if data.last == 0 { data.removeLast() }
        }
        return MySQLAuthSwitchRequest(pluginName: pluginName, pluginData: data)
    }
}

/// A MariaDB progress report.
///
/// Sent during long-running statements — `ALTER TABLE`, `LOAD DATA`, index
/// builds — so a client can show progress instead of an unexplained wait.
///
/// It arrives disguised as an **error packet**: same `0xFF` header, with the
/// error code set to `0xFFFF`. That disguise is only safe because the server
/// sends these solely to clients that asked for them, which is why the
/// discrimination below is gated on the capability rather than on the code
/// alone — otherwise a genuine error numbered 65535 would be silently swallowed
/// as a progress update.
public struct MySQLProgressReport: Sendable, Equatable {
    /// Marker error code that distinguishes a progress report from an error.
    public static let marker: UInt16 = 0xFFFF

    /// 1-based stage, e.g. 2 of 3.
    public var stage: UInt8
    public var maxStage: UInt8
    /// Progress within the stage, in units of 0.001%.
    public var progress: UInt32
    /// Human-readable stage name, e.g. "copy to tmp table".
    public var stageInfo: String

    /// Progress within the current stage as a percentage.
    public var percentage: Double { Double(progress) / 1000.0 }

    /// Whether a packet is a progress report rather than an error.
    ///
    /// Requires the capability: without it the server never sends these, and
    /// `0xFFFF` means an ordinary error.
    public static func isProgressReport(
        _ packet: MySQLPacket, capabilities: MySQLCapabilities
    ) -> Bool {
        guard capabilities.contains(.progressObsolete), packet.firstByte == 0xFF else {
            return false
        }
        let payload = packet.payload
        return payload.getInteger(
            at: payload.readerIndex + 1, endianness: .little, as: UInt16.self
        ) == marker
    }

    public static func parse(_ buffer: inout ByteBuffer) throws -> MySQLProgressReport {
        guard let header = buffer.readInteger(endianness: .little, as: UInt8.self),
              header == 0xFF,
              let code = buffer.readInteger(endianness: .little, as: UInt16.self),
              code == marker
        else {
            throw MySQLProtocolError.malformedPacket("expected progress report header")
        }
        guard let stage = buffer.readInteger(as: UInt8.self),
              let maxStage = buffer.readInteger(as: UInt8.self),
              let low = buffer.readInteger(endianness: .little, as: UInt16.self),
              let high = buffer.readInteger(as: UInt8.self)
        else {
            throw MySQLProtocolError.malformedPacket("truncated progress report")
        }

        return MySQLProgressReport(
            stage: stage,
            maxStage: maxStage,
            progress: UInt32(low) | (UInt32(high) << 16),
            stageInfo: buffer.readLengthEncodedString() ?? ""
        )
    }
}

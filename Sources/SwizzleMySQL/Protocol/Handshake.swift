import NIOCore

/// Server greeting (protocol version 10).
public struct MySQLHandshakeV10: Sendable, Equatable {
    public var serverVersion: String
    public var connectionID: UInt32
    public var capabilities: MySQLCapabilities
    /// MariaDB's extended capabilities, always parsed but **not** merged into
    /// `capabilities`.
    ///
    /// Whether they may be honoured is a negotiation decision, not a parsing
    /// one: MariaDB signals that they are meaningful by *not* setting
    /// `CLIENT_LONG_PASSWORD`. See `MySQLCapabilityNegotiation`.
    public var mariaDBExtendedCapabilities: MySQLCapabilities
    public var characterSet: UInt8
    public var statusFlags: MySQLStatusFlags
    /// Concatenated auth-plugin-data parts 1 and 2, terminator stripped.
    /// 20 bytes for every plugin we support.
    public var authPluginData: [UInt8]
    public var authPluginName: String?

    /// Every auth plugin we support uses a 20-byte scramble.
    public static let scrambleLength = 20

    /// True when the greeting comes from MariaDB rather than MySQL. MariaDB
    /// advertises itself either via a `5.5.5-` version prefix (a compatibility
    /// hack for clients that reject major version 10+) or by containing "MariaDB".
    public var isMariaDB: Bool {
        serverVersion.hasPrefix("5.5.5-") || serverVersion.contains("MariaDB")
    }

    /// Version with MariaDB's `5.5.5-` compatibility prefix removed.
    public var normalizedServerVersion: String {
        serverVersion.hasPrefix("5.5.5-") ? String(serverVersion.dropFirst(6)) : serverVersion
    }
}

extension MySQLHandshakeV10 {
    /// Parses the initial handshake.
    ///
    /// Layout quirks worth naming, because each is a real-world bug source:
    /// - auth-plugin-data arrives in two parts (8 bytes, then the rest) split by
    ///   unrelated fields
    /// - part 2 is `max(13, len - 8)` bytes and includes a trailing NUL that is
    ///   *not* part of the scramble
    /// - MariaDB puts its extended capabilities in bytes MySQL reserves
    public static func parse(_ buffer: inout ByteBuffer) throws -> MySQLHandshakeV10 {
        guard let protocolVersion = buffer.readInteger(endianness: .little, as: UInt8.self) else {
            throw MySQLProtocolError.malformedHandshake("missing protocol version")
        }
        // 0xFF is not a protocol version — it is an ERR packet sent *instead of*
        // a greeting, which is how a server refuses a connection outright: too
        // many connections, host blocked after repeated failures, or the client
        // barred from this host. Reporting "unsupported protocol version 255"
        // there is actively misleading, and cost real debugging time here when
        // a test run exhausted `max_connections`.
        if protocolVersion == 0xFF {
            buffer.moveReaderIndex(to: buffer.readerIndex - 1)
            if let error = try? MySQLErrorPacket.parse(&buffer, capabilities: []) {
                throw MySQLProtocolError.server(
                    code: error.errorCode,
                    sqlState: error.sqlState ?? "",
                    message: error.message
                )
            }
            throw MySQLProtocolError.malformedHandshake(
                "server refused the connection but sent an unreadable error"
            )
        }
        guard protocolVersion == 10 else {
            throw MySQLProtocolError.unsupportedProtocolVersion(protocolVersion)
        }
        guard let serverVersion = buffer.readNullTerminatedString() else {
            throw MySQLProtocolError.malformedHandshake("missing server version")
        }
        guard let connectionID = buffer.readInteger(endianness: .little, as: UInt32.self) else {
            throw MySQLProtocolError.malformedHandshake("missing connection id")
        }
        guard let authDataPart1 = buffer.readBytes(length: 8) else {
            throw MySQLProtocolError.malformedHandshake("missing auth-plugin-data part 1")
        }
        guard buffer.readInteger(endianness: .little, as: UInt8.self) != nil else {
            throw MySQLProtocolError.malformedHandshake("missing filler")
        }
        guard let capabilitiesLow = buffer.readInteger(endianness: .little, as: UInt16.self) else {
            throw MySQLProtocolError.malformedHandshake("missing lower capability flags")
        }

        // Pre-4.1 servers stop here. We don't support them, but we must not
        // misparse the greeting while working that out.
        guard buffer.readableBytes > 0 else {
            return MySQLHandshakeV10(
                serverVersion: serverVersion,
                connectionID: connectionID,
                capabilities: MySQLCapabilities(rawValue: UInt64(capabilitiesLow)),
                mariaDBExtendedCapabilities: [],
                characterSet: 0,
                statusFlags: [],
                authPluginData: authDataPart1,
                authPluginName: nil
            )
        }

        guard let characterSet = buffer.readInteger(endianness: .little, as: UInt8.self),
              let statusFlagsRaw = buffer.readInteger(endianness: .little, as: UInt16.self),
              let capabilitiesHigh = buffer.readInteger(endianness: .little, as: UInt16.self)
        else {
            throw MySQLProtocolError.malformedHandshake("truncated capability block")
        }

        let capabilityBits = UInt32(capabilitiesLow) | (UInt32(capabilitiesHigh) << 16)
        let capabilities = MySQLCapabilities(rawValue: UInt64(capabilityBits))

        guard let authPluginDataLength = buffer.readInteger(endianness: .little, as: UInt8.self) else {
            throw MySQLProtocolError.malformedHandshake("missing auth-plugin-data length")
        }

        // 10 reserved bytes — except MariaDB uses the last 4 for its extended
        // capabilities. Parsed unconditionally into a separate field; whether
        // they are honoured is decided during negotiation.
        guard let reserved = buffer.readBytes(length: 10) else {
            throw MySQLProtocolError.malformedHandshake("truncated reserved block")
        }
        let mariaDBExtended = UInt32(reserved[6]) | (UInt32(reserved[7]) << 8)
            | (UInt32(reserved[8]) << 16) | (UInt32(reserved[9]) << 24)
        let mariaDBExtendedCapabilities =
            MySQLCapabilities(rawValue: UInt64(mariaDBExtended) << 32)

        var authPluginData = authDataPart1
        if capabilities.contains(.secureConnection) {
            // The length is interpreted as *signed*, mirroring the C client and
            // rust-mysql-common (`auth_plugin_data_len as i8 - 8`). A server
            // claiming more than 127 therefore falls back to 13 rather than
            // letting us swallow the plugin name into the scramble.
            let signedLength = Int(Int8(bitPattern: authPluginDataLength))
            let part2Length = max(13, signedLength - 8)
            guard let part2 = buffer.readBytes(length: part2Length) else {
                throw MySQLProtocolError.malformedHandshake("truncated auth-plugin-data part 2")
            }
            // Drop the trailing NUL; it is framing, not scramble material.
            authPluginData.append(contentsOf: part2.last == 0 ? part2.dropLast() : part2[...])
        }

        // Normalise a short scramble to the expected width rather than sending a
        // truncated auth response that fails for an unrelated-looking reason.
        if authPluginData.count < MySQLHandshakeV10.scrambleLength {
            authPluginData.append(
                contentsOf: [UInt8](
                    repeating: 0, count: MySQLHandshakeV10.scrambleLength - authPluginData.count
                )
            )
        }

        var authPluginName: String?
        if capabilities.contains(.pluginAuth) {
            // Some servers omit the terminator on the final field.
            authPluginName = buffer.readNullTerminatedString()
                ?? buffer.readString(length: buffer.readableBytes)
        }

        return MySQLHandshakeV10(
            serverVersion: serverVersion,
            connectionID: connectionID,
            capabilities: capabilities,
            mariaDBExtendedCapabilities: mariaDBExtendedCapabilities,
            characterSet: characterSet,
            statusFlags: MySQLStatusFlags(rawValue: statusFlagsRaw),
            authPluginData: authPluginData,
            authPluginName: authPluginName
        )
    }
}

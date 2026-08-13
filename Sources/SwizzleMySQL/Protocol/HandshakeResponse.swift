import NIOCore

/// `HandshakeResponse41` — the client's reply to the server greeting.
///
/// Field order is *not* what the MySQL docs' field list suggests: the username
/// comes **before** the auth response, and MariaDB steals the last 4 bytes of
/// what MySQL documents as a 23-byte filler for its extended capabilities.
/// Writing 23 zero bytes (the obvious reading) silently drops those, exactly
/// mirroring the reserved-bytes trick in the greeting.
///
/// Verified against `rust-mysql-common`'s `MySerialize for HandshakeResponse`.
public struct MySQLHandshakeResponse41: Sendable {
    /// utf8mb4_general_ci — valid on every MySQL and MariaDB we support.
    public static let defaultCharacterSet: UInt8 = 45
    public static let defaultMaxPacketSize: UInt32 = 4 * 1024 * 1024

    public var capabilities: MySQLCapabilities
    public var mariaDBCapabilities: MySQLCapabilities
    public var maxPacketSize: UInt32
    public var characterSet: UInt8
    public var username: String
    public var authResponse: [UInt8]
    public var database: String?
    public var authPluginName: String?
    public var connectAttributes: [(key: String, value: String)]
    /// Sent only when `.zstdCompressionAlgorithm` is negotiated. MySQL accepts
    /// 1–22; 3 is its default.
    public var zstdCompressionLevel: UInt8 = 3

    public init(
        capabilities: MySQLCapabilities,
        mariaDBCapabilities: MySQLCapabilities = [],
        maxPacketSize: UInt32 = MySQLHandshakeResponse41.defaultMaxPacketSize,
        characterSet: UInt8 = MySQLHandshakeResponse41.defaultCharacterSet,
        username: String,
        authResponse: [UInt8],
        database: String? = nil,
        authPluginName: String? = nil,
        connectAttributes: [(key: String, value: String)] = []
    ) {
        self.capabilities = Self.effectiveCapabilities(
            capabilities,
            database: database,
            authPluginName: authPluginName,
            hasConnectAttributes: !connectAttributes.isEmpty
        )
        self.mariaDBCapabilities = mariaDBCapabilities
        self.maxPacketSize = maxPacketSize
        self.characterSet = characterSet
        self.username = username
        self.authResponse = authResponse
        self.database = database
        self.authPluginName = authPluginName
        self.connectAttributes = connectAttributes
    }

    public func serialize(into buffer: inout ByteBuffer) {
        Self.writeHeader(
            capabilities: capabilities,
            mariaDBCapabilities: mariaDBCapabilities,
            maxPacketSize: maxPacketSize,
            characterSet: characterSet,
            into: &buffer
        )

        buffer.writeNullTerminatedString(username)

        // Three encodings, selected by capability. Picking the wrong one shifts
        // every subsequent field.
        if capabilities.contains(.pluginAuthLenencClientData) {
            buffer.writeLengthEncodedInteger(UInt64(authResponse.count))
            buffer.writeBytes(authResponse)
        } else if capabilities.contains(.secureConnection) {
            buffer.writeInteger(UInt8(authResponse.count), endianness: .little)
            buffer.writeBytes(authResponse)
        } else {
            buffer.writeBytes(authResponse)
            buffer.writeInteger(UInt8(0), endianness: .little)
        }

        if let database {
            buffer.writeNullTerminatedString(database)
        }
        if let authPluginName {
            buffer.writeNullTerminatedString(authPluginName)
        }

        if !connectAttributes.isEmpty {
            var attributes = ByteBuffer()
            for (key, value) in connectAttributes {
                attributes.writeLengthEncodedString(key)
                attributes.writeLengthEncodedString(value)
            }
            buffer.writeLengthEncodedInteger(UInt64(attributes.readableBytes))
            buffer.writeBuffer(&attributes)
        }

        // Requesting zstd adds a single trailing byte carrying the compression
        // level — the *only* payload difference between asking for zlib and
        // asking for zstd. It must come last, after the connection attributes,
        // or the server reads the level as the start of an attribute block.
        if capabilities.contains(.zstdCompressionAlgorithm) {
            buffer.writeInteger(zstdCompressionLevel)
        }
    }

    /// Narrows a capability set to what this packet will actually contain.
    ///
    /// **The SSLRequest must advertise the identical word.** The server commits
    /// to the capability set it reads from the SSLRequest, so if the handshake
    /// response that follows differs by even one bit — a `CONNECT_WITH_DB`
    /// derived later from a database name, say — the server fails to parse it
    /// and answers "Bad handshake" (error 1043), pointing nowhere near the
    /// actual cause. Both packets must be built through this function.
    ///
    /// Flags are only ever *removed* here, never added, so this can never claim
    /// a capability the server did not offer.
    public static func effectiveCapabilities(
        _ base: MySQLCapabilities,
        database: String?,
        authPluginName: String?,
        hasConnectAttributes: Bool
    ) -> MySQLCapabilities {
        var effective = base
        if database == nil { effective.remove(.connectWithDB) }
        if authPluginName == nil { effective.remove(.pluginAuth) }
        if !hasConnectAttributes { effective.remove(.connectAttrs) }
        return effective
    }

    /// The 32-byte prelude shared with `SSLRequest`.
    static func writeHeader(
        capabilities: MySQLCapabilities,
        mariaDBCapabilities: MySQLCapabilities,
        maxPacketSize: UInt32,
        characterSet: UInt8,
        into buffer: inout ByteBuffer
    ) {
        buffer.writeInteger(capabilities.lower, endianness: .little)
        buffer.writeInteger(maxPacketSize, endianness: .little)
        buffer.writeInteger(characterSet, endianness: .little)
        // 19 filler bytes, then MariaDB's extended capabilities occupy the last
        // 4 of MySQL's nominal 23-byte filler.
        buffer.writeBytes([UInt8](repeating: 0, count: 19))
        buffer.writeInteger(mariaDBCapabilities.upper, endianness: .little)
    }
}

/// `SSLRequest` — the 32-byte handshake-response prelude, sent alone to ask the
/// server to switch to TLS.
///
/// It must be sent *before* the real handshake response, since everything after
/// it (username, auth response) has to travel inside the TLS session. That
/// ordering is the entire point of the packet.
public struct MySQLSSLRequest: Sendable {
    public var capabilities: MySQLCapabilities
    public var mariaDBCapabilities: MySQLCapabilities
    public var maxPacketSize: UInt32
    public var characterSet: UInt8

    public init(
        capabilities: MySQLCapabilities,
        mariaDBCapabilities: MySQLCapabilities = [],
        maxPacketSize: UInt32 = MySQLHandshakeResponse41.defaultMaxPacketSize,
        characterSet: UInt8 = MySQLHandshakeResponse41.defaultCharacterSet
    ) {
        self.capabilities = capabilities.union(.ssl)
        self.mariaDBCapabilities = mariaDBCapabilities
        self.maxPacketSize = maxPacketSize
        self.characterSet = characterSet
    }

    public func serialize(into buffer: inout ByteBuffer) {
        MySQLHandshakeResponse41.writeHeader(
            capabilities: capabilities,
            mariaDBCapabilities: mariaDBCapabilities,
            maxPacketSize: maxPacketSize,
            characterSet: characterSet,
            into: &buffer
        )
    }
}

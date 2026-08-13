import NIOCore
import Testing
@testable import SwizzleMySQL

/// Field layout verified against rust-mysql-common's
/// `MySerialize for HandshakeResponse`.
@Suite("Handshake response")
struct HandshakeResponseTests {

    static func serialize(_ response: MySQLHandshakeResponse41) -> ByteBuffer {
        var buffer = ByteBuffer()
        response.serialize(into: &buffer)
        return buffer
    }

    /// capabilities(4) + maxPacketSize(4) + charset(1) + filler(19) + mariaDB(4)
    @Test func headerIs32Bytes() {
        var buffer = ByteBuffer()
        MySQLSSLRequest(capabilities: .swizzleDefault).serialize(into: &buffer)
        #expect(buffer.readableBytes == 32)
    }

    /// The filler is 19 bytes, not 23 — MariaDB's extended capabilities occupy
    /// the last 4 of MySQL's nominal 23-byte filler. Writing 23 zeroes would
    /// silently drop them.
    @Test func mariaDBCapabilitiesLandInTheFillerTail() {
        var buffer = ByteBuffer()
        MySQLSSLRequest(
            capabilities: .swizzleDefault,
            mariaDBCapabilities: .mariaDBStmtBulkOperations   // 1 << 34 -> upper bit 2
        ).serialize(into: &buffer)

        // Bytes 9..27 are filler, 28..31 carry the extended capabilities.
        #expect(buffer.getBytes(at: 9, length: 19) == [UInt8](repeating: 0, count: 19))
        #expect(buffer.getBytes(at: 28, length: 4) == [0x04, 0x00, 0x00, 0x00])
    }

    @Test func mysqlWritesZeroesWhereMariaDBWouldPutCapabilities() {
        var buffer = ByteBuffer()
        MySQLSSLRequest(capabilities: .swizzleDefault).serialize(into: &buffer)
        #expect(buffer.getBytes(at: 28, length: 4) == [0x00, 0x00, 0x00, 0x00])
    }

    /// Username precedes the auth response — the reverse of how the field list
    /// usually reads.
    @Test func usernamePrecedesAuthResponse() throws {
        var buffer = Self.serialize(
            MySQLHandshakeResponse41(
                capabilities: [.protocol41, .secureConnection, .pluginAuthLenencClientData],
                username: "root",
                authResponse: [0xAA, 0xBB],
                authPluginName: "mysql_native_password"
            )
        )
        buffer.moveReaderIndex(forwardBy: 32)
        #expect(buffer.readNullTerminatedString() == "root")
        #expect(buffer.readLengthEncodedInteger() == 2)
        #expect(buffer.readBytes(length: 2) == [0xAA, 0xBB])
    }

    /// Three encodings selected by capability; the wrong one shifts every
    /// subsequent field.
    @Test func authResponseUsesLengthEncodedFormWhenNegotiated() throws {
        var buffer = Self.serialize(
            MySQLHandshakeResponse41(
                capabilities: [.protocol41, .secureConnection, .pluginAuthLenencClientData],
                username: "u",
                authResponse: [UInt8](repeating: 0x11, count: 32)
            )
        )
        buffer.moveReaderIndex(forwardBy: 32)
        _ = buffer.readNullTerminatedString()
        #expect(buffer.readLengthEncodedInteger() == 32)
    }

    @Test func authResponseUsesSingleByteLengthWithoutLenencCapability() throws {
        var buffer = Self.serialize(
            MySQLHandshakeResponse41(
                capabilities: [.protocol41, .secureConnection],
                username: "u",
                authResponse: [UInt8](repeating: 0x11, count: 20)
            )
        )
        buffer.moveReaderIndex(forwardBy: 32)
        _ = buffer.readNullTerminatedString()
        #expect(buffer.readInteger(endianness: .little, as: UInt8.self) == 20)
    }

    @Test func authResponseIsNullTerminatedWithoutSecureConnection() throws {
        var buffer = Self.serialize(
            MySQLHandshakeResponse41(
                capabilities: [.protocol41],
                username: "u",
                authResponse: [0x01, 0x02]
            )
        )
        buffer.moveReaderIndex(forwardBy: 32)
        _ = buffer.readNullTerminatedString()
        #expect(buffer.readBytes(length: 3) == [0x01, 0x02, 0x00])
    }

    /// CONNECT_WITH_DB / PLUGIN_AUTH / CONNECT_ATTRS are narrowed to what the
    /// packet actually contains — flags are **removed** when unused.
    @Test func unusedCapabilityFlagsAreRemoved() {
        let response = MySQLHandshakeResponse41(
            capabilities: [.protocol41, .connectWithDB, .pluginAuth, .connectAttrs],
            username: "u", authResponse: []
        )
        #expect(response.capabilities.contains(.connectWithDB) == false)
        #expect(response.capabilities.contains(.pluginAuth) == false)
        #expect(response.capabilities.contains(.connectAttrs) == false)
        #expect(response.capabilities.contains(.protocol41))
    }

    /// Flags are never *added*, only removed.
    ///
    /// This is a safety property, not a detail: the capability set arrives from
    /// negotiation (server ∩ desired), so adding a bit here could claim
    /// something the server never offered. It is also what keeps the SSLRequest
    /// and the handshake response in agreement — they differed by exactly
    /// `CONNECT_WITH_DB` once, and the server answered "Bad handshake" with no
    /// hint as to why.
    @Test func flagsAreNeverAdded() {
        let response = MySQLHandshakeResponse41(
            capabilities: [.protocol41],
            username: "u", authResponse: [],
            database: "swizzle_test",
            authPluginName: "caching_sha2_password",
            connectAttributes: [(key: "_client_name", value: "swizzle")]
        )
        #expect(response.capabilities.contains(.connectWithDB) == false)
        #expect(response.capabilities.contains(.pluginAuth) == false)
        #expect(response.capabilities.contains(.connectAttrs) == false)
    }

    /// The SSLRequest and the handshake response must serialize an identical
    /// capability word — the server commits to whatever the SSLRequest declared.
    @Test func sslRequestAndResponseAgreeOnCapabilities() {
        let negotiated: MySQLCapabilities = .swizzleDefault
        let effective = MySQLHandshakeResponse41.effectiveCapabilities(
            negotiated,
            database: "swizzle_test",
            authPluginName: "caching_sha2_password",
            hasConnectAttributes: true
        )

        var sslBuffer = ByteBuffer()
        MySQLSSLRequest(capabilities: effective).serialize(into: &sslBuffer)

        var responseBuffer = Self.serialize(
            MySQLHandshakeResponse41(
                capabilities: effective,
                username: "u", authResponse: [],
                database: "swizzle_test",
                authPluginName: "caching_sha2_password",
                connectAttributes: [(key: "_client_name", value: "swizzle")]
            )
        )

        let sslWord = sslBuffer.getInteger(at: 0, endianness: .little, as: UInt32.self)!
        let responseWord = responseBuffer.getInteger(at: 0, endianness: .little, as: UInt32.self)!
        // SSLRequest additionally forces CLIENT_SSL; everything else must match.
        #expect(sslWord == responseWord | MySQLCapabilities.ssl.lower)
        _ = responseBuffer.readableBytes
    }

    @Test func databaseAndPluginFollowTheAuthResponse() throws {
        var buffer = Self.serialize(
            MySQLHandshakeResponse41(
                capabilities: [.protocol41, .secureConnection, .pluginAuthLenencClientData],
                username: "root",
                authResponse: [0xAA],
                database: "swizzle_test",
                authPluginName: "caching_sha2_password"
            )
        )
        buffer.moveReaderIndex(forwardBy: 32)
        #expect(buffer.readNullTerminatedString() == "root")
        _ = buffer.readLengthEncodedInteger()
        _ = buffer.readBytes(length: 1)
        #expect(buffer.readNullTerminatedString() == "swizzle_test")
        #expect(buffer.readNullTerminatedString() == "caching_sha2_password")
    }

    /// Attributes are a lenenc *total byte length* followed by lenenc pairs —
    /// not a pair count.
    @Test func connectAttributesAreLengthPrefixedInBytes() throws {
        var buffer = Self.serialize(
            MySQLHandshakeResponse41(
                capabilities: [.protocol41, .secureConnection, .pluginAuthLenencClientData],
                username: "u",
                authResponse: [],
                connectAttributes: [(key: "_client_name", value: "swizzle")]
            )
        )
        buffer.moveReaderIndex(forwardBy: 32)
        _ = buffer.readNullTerminatedString()
        _ = buffer.readLengthEncodedInteger()

        let totalLength = buffer.readLengthEncodedInteger()
        // 1 + 12 ("_client_name") + 1 + 7 ("swizzle")
        #expect(totalLength == 21)
        #expect(buffer.readLengthEncodedString() == "_client_name")
        #expect(buffer.readLengthEncodedString() == "swizzle")
    }

    /// SSLRequest always advertises CLIENT_SSL, whatever the caller passed.
    @Test func sslRequestForcesTheSSLCapability() {
        var buffer = ByteBuffer()
        MySQLSSLRequest(capabilities: [.protocol41]).serialize(into: &buffer)
        let raw = buffer.getInteger(at: 0, endianness: .little, as: UInt32.self)!
        #expect(MySQLCapabilities(rawValue: UInt64(raw)).contains(.ssl))
    }
}

import NIOCore
import Testing
@testable import SwizzleMySQL

/// Handshake fixtures are assembled in Swift straight from the documented wire
/// layout. No external oracle is needed here — unlike the auth scrambles, this
/// is byte placement rather than a computation that could be subtly misunderstood.
@Suite("Handshake parsing")
struct HandshakeTests {

    /// Builds a protocol-version-10 greeting.
    static func makeHandshake(
        serverVersion: String,
        pluginName: String,
        scramble: [UInt8],
        capabilitiesLow: UInt16 = 0xFFFF,
        capabilitiesHigh: UInt16 = 0x81FF,
        mariaDBExtended: UInt32 = 0
    ) -> ByteBuffer {
        precondition(scramble.count == 20)
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt8(10), endianness: .little)
        buffer.writeNullTerminatedString(serverVersion)
        buffer.writeInteger(UInt32(42), endianness: .little)          // connection id
        buffer.writeBytes(scramble.prefix(8))                          // auth data part 1
        buffer.writeInteger(UInt8(0), endianness: .little)             // filler
        buffer.writeInteger(capabilitiesLow, endianness: .little)
        buffer.writeInteger(UInt8(0x2D), endianness: .little)          // utf8mb4
        buffer.writeInteger(UInt16(0x0002), endianness: .little)       // status: autocommit
        buffer.writeInteger(capabilitiesHigh, endianness: .little)
        buffer.writeInteger(UInt8(21), endianness: .little)            // auth data length

        var reserved = [UInt8](repeating: 0, count: 10)
        if mariaDBExtended != 0 {
            reserved[6] = UInt8(mariaDBExtended & 0xFF)
            reserved[7] = UInt8((mariaDBExtended >> 8) & 0xFF)
            reserved[8] = UInt8((mariaDBExtended >> 16) & 0xFF)
            reserved[9] = UInt8((mariaDBExtended >> 24) & 0xFF)
        }
        buffer.writeBytes(reserved)

        buffer.writeBytes(scramble.suffix(12))                         // auth data part 2
        buffer.writeInteger(UInt8(0), endianness: .little)             // its NUL terminator
        buffer.writeNullTerminatedString(pluginName)
        return buffer
    }

    static let scramble: [UInt8] = Array(1...20)

    @Test func parsesMySQL8Greeting() throws {
        var buffer = Self.makeHandshake(
            serverVersion: "8.4.0",
            pluginName: "caching_sha2_password",
            scramble: Self.scramble
        )
        let handshake = try MySQLHandshakeV10.parse(&buffer)

        #expect(handshake.serverVersion == "8.4.0")
        #expect(handshake.connectionID == 42)
        #expect(handshake.authPluginName == "caching_sha2_password")
        #expect(handshake.characterSet == 0x2D)
        #expect(handshake.statusFlags.contains(.autocommit))
        #expect(handshake.isMariaDB == false)
        #expect(buffer.readableBytes == 0)
    }

    /// The scramble arrives in two parts split by unrelated fields, and part 2
    /// carries a trailing NUL that is framing rather than scramble material.
    /// Reassembling it wrong yields a 21-byte scramble and silent auth failure.
    @Test func reassemblesScrambleAndStripsTerminator() throws {
        var buffer = Self.makeHandshake(
            serverVersion: "8.4.0",
            pluginName: "caching_sha2_password",
            scramble: Self.scramble
        )
        let handshake = try MySQLHandshakeV10.parse(&buffer)

        #expect(handshake.authPluginData.count == 20)
        #expect(handshake.authPluginData == Self.scramble)
    }

    /// MariaDB reports itself as `5.5.5-<real version>` so old clients that
    /// reject major version 10+ still connect. We must see through that.
    @Test func detectsMariaDBBehindVersionPrefix() throws {
        var buffer = Self.makeHandshake(
            serverVersion: "5.5.5-11.4.2-MariaDB",
            pluginName: "mysql_native_password",
            scramble: Self.scramble
        )
        let handshake = try MySQLHandshakeV10.parse(&buffer)

        #expect(handshake.isMariaDB)
        #expect(handshake.normalizedServerVersion == "11.4.2-MariaDB")
        #expect(handshake.authPluginName == "mysql_native_password")
    }

    /// MariaDB puts extended capabilities in bytes MySQL treats as reserved.
    /// They land in their own field rather than being merged into
    /// `capabilities` — whether they may be *honoured* is a negotiation
    /// decision, covered in `NegotiationTests`.
    @Test func readsMariaDBExtendedCapabilities() throws {
        var buffer = Self.makeHandshake(
            serverVersion: "5.5.5-11.4.2-MariaDB",
            pluginName: "mysql_native_password",
            scramble: Self.scramble,
            mariaDBExtended: 0x0000_0004      // MARIADB_CLIENT_STMT_BULK_OPERATIONS (1 << 34)
        )
        let handshake = try MySQLHandshakeV10.parse(&buffer)
        #expect(handshake.mariaDBExtendedCapabilities.contains(.mariaDBStmtBulkOperations))
        #expect(handshake.capabilities.contains(.mariaDBStmtBulkOperations) == false)
    }

    @Test func mysqlGreetingHasNoMariaDBCapabilities() throws {
        var buffer = Self.makeHandshake(
            serverVersion: "8.4.0",
            pluginName: "caching_sha2_password",
            scramble: Self.scramble
        )
        let handshake = try MySQLHandshakeV10.parse(&buffer)
        #expect(handshake.mariaDBExtendedCapabilities.isEmpty)
        #expect(handshake.capabilities.contains(.mariaDBStmtBulkOperations) == false)
    }

    @Test func parsesStandardCapabilityFlags() throws {
        var buffer = Self.makeHandshake(
            serverVersion: "8.4.0",
            pluginName: "caching_sha2_password",
            scramble: Self.scramble
        )
        let handshake = try MySQLHandshakeV10.parse(&buffer)

        #expect(handshake.capabilities.contains(.protocol41))
        #expect(handshake.capabilities.contains(.secureConnection))
        #expect(handshake.capabilities.contains(.pluginAuth))
        #expect(handshake.capabilities.contains(.deprecateEOF))
    }

    /// A server claiming an auth-plugin-data length above 127 must fall back to
    /// 13 rather than letting us read the plugin name into the scramble. The
    /// length is signed in the C client and in rust-mysql-common
    /// (`auth_plugin_data_len as i8 - 8`).
    @Test func oversizedAuthDataLengthFallsBackToThirteen() throws {
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt8(10), endianness: .little)
        buffer.writeNullTerminatedString("8.4.0")
        buffer.writeInteger(UInt32(42), endianness: .little)
        buffer.writeBytes(Self.scramble.prefix(8))
        buffer.writeInteger(UInt8(0), endianness: .little)
        buffer.writeInteger(UInt16(0xFFFF), endianness: .little)
        buffer.writeInteger(UInt8(0x2D), endianness: .little)
        buffer.writeInteger(UInt16(0x0002), endianness: .little)
        buffer.writeInteger(UInt16(0x81FF), endianness: .little)
        buffer.writeInteger(UInt8(200), endianness: .little)      // bogus length
        buffer.writeBytes([UInt8](repeating: 0, count: 10))
        buffer.writeBytes(Self.scramble.suffix(12))
        buffer.writeInteger(UInt8(0), endianness: .little)
        buffer.writeNullTerminatedString("caching_sha2_password")

        let handshake = try MySQLHandshakeV10.parse(&buffer)
        #expect(handshake.authPluginData == Self.scramble)
        #expect(handshake.authPluginName == "caching_sha2_password")
    }

    /// A short scramble is padded rather than producing a truncated auth
    /// response that fails for an unrelated-looking reason. Matches
    /// rust-mysql-common's `nonce()`, which resizes to 20.
    @Test func shortScrambleIsPaddedToTwentyBytes() throws {
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt8(10), endianness: .little)
        buffer.writeNullTerminatedString("8.4.0")
        buffer.writeInteger(UInt32(42), endianness: .little)
        buffer.writeBytes(Self.scramble.prefix(8))
        buffer.writeInteger(UInt8(0), endianness: .little)
        buffer.writeInteger(UInt16(0xFFFF), endianness: .little)
        buffer.writeInteger(UInt8(0x2D), endianness: .little)
        buffer.writeInteger(UInt16(0x0002), endianness: .little)
        buffer.writeInteger(UInt16(0x81FF), endianness: .little)
        buffer.writeInteger(UInt8(21), endianness: .little)
        buffer.writeBytes([UInt8](repeating: 0, count: 10))
        buffer.writeBytes([UInt8](repeating: 0xAA, count: 12))  // 12 bytes, last isn't NUL
        buffer.writeInteger(UInt8(0), endianness: .little)
        buffer.writeNullTerminatedString("mysql_native_password")

        let handshake = try MySQLHandshakeV10.parse(&buffer)
        #expect(handshake.authPluginData.count == 20)
    }

    @Test func rejectsUnsupportedProtocolVersion() {
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt8(9), endianness: .little)
        buffer.writeNullTerminatedString("4.0.0")

        #expect(throws: MySQLProtocolError.unsupportedProtocolVersion(9)) {
            _ = try MySQLHandshakeV10.parse(&buffer)
        }
    }

    @Test func rejectsTruncatedGreeting() {
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt8(10), endianness: .little)
        buffer.writeNullTerminatedString("8.4.0")
        buffer.writeInteger(UInt16(1), endianness: .little)  // truncated connection id

        #expect(throws: (any Error).self) {
            _ = try MySQLHandshakeV10.parse(&buffer)
        }
    }

    /// Capability flags split across two 16-bit fields must recombine correctly.
    @Test func capabilitySplitAcrossFieldsRecombines() {
        let capabilities = MySQLCapabilities.swizzleDefault
        #expect(capabilities.lower != 0)
        #expect(capabilities.upper == 0)  // no MariaDB extensions in our default set

        let withMariaDB: MySQLCapabilities = [.swizzleDefault, .mariaDBCacheMetadata]
        #expect(withMariaDB.upper == (1 << 4))  // bit 36 -> bit 4 of the upper word
        #expect(withMariaDB.lower == capabilities.lower)
    }
}

import NIOCore

/// MySQL/MariaDB capability flags.
///
/// The low 32 bits are shared. MariaDB reuses the upper 32 bits of a 64-bit
/// space for its own extensions, sent in a field MySQL treats as reserved — which
/// is why this is modelled as 64-bit rather than the 32-bit set most of the
/// protocol documentation shows.
public struct MySQLCapabilities: OptionSet, Sendable, Hashable {
    public var rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let longPassword                = MySQLCapabilities(rawValue: 0x0000_0001)
    public static let foundRows                   = MySQLCapabilities(rawValue: 0x0000_0002)
    public static let longFlag                    = MySQLCapabilities(rawValue: 0x0000_0004)
    public static let connectWithDB               = MySQLCapabilities(rawValue: 0x0000_0008)
    public static let noSchema                    = MySQLCapabilities(rawValue: 0x0000_0010)
    public static let compress                    = MySQLCapabilities(rawValue: 0x0000_0020)
    public static let odbc                        = MySQLCapabilities(rawValue: 0x0000_0040)
    public static let localFiles                  = MySQLCapabilities(rawValue: 0x0000_0080)
    public static let ignoreSpace                 = MySQLCapabilities(rawValue: 0x0000_0100)
    public static let protocol41                  = MySQLCapabilities(rawValue: 0x0000_0200)
    public static let interactive                 = MySQLCapabilities(rawValue: 0x0000_0400)
    public static let ssl                         = MySQLCapabilities(rawValue: 0x0000_0800)
    public static let ignoreSigpipe               = MySQLCapabilities(rawValue: 0x0000_1000)
    public static let transactions                = MySQLCapabilities(rawValue: 0x0000_2000)
    public static let reserved                    = MySQLCapabilities(rawValue: 0x0000_4000)
    public static let secureConnection            = MySQLCapabilities(rawValue: 0x0000_8000)
    public static let multiStatements             = MySQLCapabilities(rawValue: 0x0001_0000)
    public static let multiResults                = MySQLCapabilities(rawValue: 0x0002_0000)
    public static let psMultiResults              = MySQLCapabilities(rawValue: 0x0004_0000)
    public static let pluginAuth                  = MySQLCapabilities(rawValue: 0x0008_0000)
    public static let connectAttrs                = MySQLCapabilities(rawValue: 0x0010_0000)
    public static let pluginAuthLenencClientData  = MySQLCapabilities(rawValue: 0x0020_0000)
    public static let canHandleExpiredPasswords   = MySQLCapabilities(rawValue: 0x0040_0000)
    public static let sessionTrack                = MySQLCapabilities(rawValue: 0x0080_0000)
    public static let deprecateEOF                = MySQLCapabilities(rawValue: 0x0100_0000)
    public static let optionalResultsetMetadata   = MySQLCapabilities(rawValue: 0x0200_0000)
    public static let zstdCompressionAlgorithm    = MySQLCapabilities(rawValue: 0x0400_0000)
    public static let queryAttributes             = MySQLCapabilities(rawValue: 0x0800_0000)
    public static let multiFactorAuthentication   = MySQLCapabilities(rawValue: 0x1000_0000)
    /// MariaDB's original progress-reporting flag, superseded by the extended
    /// `mariaDBProgress` bit. Modelled so a server advertising it round-trips.
    public static let progressObsolete            = MySQLCapabilities(rawValue: 0x2000_0000)
    public static let sslVerifyServerCert         = MySQLCapabilities(rawValue: 0x4000_0000)
    public static let rememberOptions             = MySQLCapabilities(rawValue: 0x8000_0000)

    // MariaDB-specific, upper 32 bits. Bit positions verified against
    // rust-mysql-common's `MariadbCapabilities`, which models them as a separate
    // u32; we merge them into one 64-bit set because that is how MariaDB
    // documents them and it keeps a single flag type at call sites.
    public static let mariaDBProgress             = MySQLCapabilities(rawValue: 1 << 32)
    /// Former `COM_MULTI`. Reserved and unused — present so an advertising
    /// server round-trips rather than losing the bit.
    public static let mariaDBReserved1            = MySQLCapabilities(rawValue: 1 << 33)
    public static let mariaDBStmtBulkOperations   = MySQLCapabilities(rawValue: 1 << 34)
    public static let mariaDBExtendedMetadata     = MySQLCapabilities(rawValue: 1 << 35)
    public static let mariaDBCacheMetadata        = MySQLCapabilities(rawValue: 1 << 36)
    public static let mariaDBBulkUnitResults      = MySQLCapabilities(rawValue: 1 << 37)

    /// What Swizzle asks for. Notably includes `deprecateEOF` — without it the
    /// server sends EOF packets we'd have to special-case in the row stream, and
    /// every server we support (MySQL 5.7+, MariaDB 10.2+) honours it.
    public static let swizzleDefault: MySQLCapabilities = [
        .longPassword, .longFlag, .protocol41, .transactions, .secureConnection,
        .multiResults, .psMultiResults, .pluginAuth, .pluginAuthLenencClientData,
        .deprecateEOF, .sessionTrack, .connectAttrs, .connectWithDB,
    ]

    /// The low 32 bits, as they appear on the wire in the shared capability field.
    public var lower: UInt32 { UInt32(truncatingIfNeeded: rawValue) }
    /// The high 32 bits — MariaDB extensions.
    public var upper: UInt32 { UInt32(truncatingIfNeeded: rawValue >> 32) }
}

/// Server status flags returned in OK/EOF packets.
public struct MySQLStatusFlags: OptionSet, Sendable, Hashable {
    public var rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let inTransaction         = MySQLStatusFlags(rawValue: 0x0001)
    public static let autocommit            = MySQLStatusFlags(rawValue: 0x0002)
    public static let moreResultsExists     = MySQLStatusFlags(rawValue: 0x0008)
    public static let noGoodIndexUsed       = MySQLStatusFlags(rawValue: 0x0010)
    public static let noIndexUsed           = MySQLStatusFlags(rawValue: 0x0020)
    public static let cursorExists          = MySQLStatusFlags(rawValue: 0x0040)
    public static let lastRowSent           = MySQLStatusFlags(rawValue: 0x0080)
    public static let dbDropped             = MySQLStatusFlags(rawValue: 0x0100)
    public static let noBackslashEscapes    = MySQLStatusFlags(rawValue: 0x0200)
    public static let metadataChanged       = MySQLStatusFlags(rawValue: 0x0400)
    public static let queryWasSlow          = MySQLStatusFlags(rawValue: 0x0800)
    public static let psOutParams           = MySQLStatusFlags(rawValue: 0x1000)
    public static let inTransactionReadonly = MySQLStatusFlags(rawValue: 0x2000)
    public static let sessionStateChanged   = MySQLStatusFlags(rawValue: 0x4000)
    /// The server treats `"` as an identifier quote rather than a string
    /// delimiter. Affects generated SQL, not just the driver.
    public static let ansiQuotes            = MySQLStatusFlags(rawValue: 0x8000)
}

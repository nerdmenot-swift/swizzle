/// MySQL column types.
///
/// Values verified against rust-mysql-common's `ColumnType`. The gap between
/// 21 (`TYPED_ARRAY`) and 242 (`VECTOR`) is real — MySQL reuses the high end of
/// the byte range for types added later.
public enum MySQLColumnType: UInt8, Sendable, CaseIterable {
    case decimal      = 0
    case tiny         = 1
    case short        = 2
    case long         = 3
    case float        = 4
    case double       = 5
    case null         = 6
    case timestamp    = 7
    case longlong     = 8
    case int24        = 9
    case date         = 10
    case time         = 11
    case datetime     = 12
    case year         = 13
    /// Internal to MySQL; never appears on the wire for a client.
    case newdate      = 14
    case varchar      = 15
    case bit          = 16
    case timestamp2   = 17
    case datetime2    = 18
    case time2        = 19
    /// Replication only — multi-valued indexes.
    case typedArray   = 20
    /// MySQL 9.0 vector type.
    case vector       = 242
    case unknown      = 243
    case json         = 245
    case newdecimal   = 246
    case enumeration  = 247
    case set          = 248
    case tinyBlob     = 249
    case mediumBlob   = 250
    case longBlob     = 251
    case blob         = 252
    case varString    = 253
    case string       = 254
    case geometry     = 255

    /// Unrecognised types decode as `.unknown` rather than failing the whole
    /// result set — a new server type should degrade to raw bytes, not an error.
    public init(rawValueOrUnknown raw: UInt8) {
        self = MySQLColumnType(rawValue: raw) ?? .unknown
    }

    /// Types the binary protocol encodes as a length-encoded string.
    ///
    /// `newdecimal` belongs here, which is what keeps DECIMAL exact: it travels
    /// as text and must never be routed through `Double`.
    public var isBinaryEncodedAsBytes: Bool {
        switch self {
        case .string, .varString, .varchar, .blob, .tinyBlob, .mediumBlob, .longBlob,
             .set, .enumeration, .decimal, .newdecimal, .bit, .geometry, .vector, .json,
             .unknown, .typedArray, .newdate:
            return true
        default:
            return false
        }
    }

    /// True for types whose value is a number, so an `UNSIGNED` column flag
    /// changes how the bytes are interpreted.
    public var isIntegral: Bool {
        switch self {
        case .tiny, .short, .int24, .long, .longlong, .year: return true
        default: return false
        }
    }

    /// DECIMAL and NEWDECIMAL must round-trip as text. Binary floating point
    /// cannot represent them exactly, and a silently lossy money column is the
    /// kind of bug that surfaces in an audit rather than a test.
    public var isExactNumeric: Bool {
        self == .decimal || self == .newdecimal
    }
}

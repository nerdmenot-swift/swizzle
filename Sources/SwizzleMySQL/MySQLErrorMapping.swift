import SwizzleCore

/// MySQL and MariaDB error numbers, in the shared vocabulary.
///
/// The numbers are the stable identity — SQLSTATE is coarser and messages are
/// localised — so the mapping is by code, with SQLSTATE carried through for
/// callers that prefer the standard spelling.
extension MySQLProtocolError: SQLDiagnosable {
    public var sqlKind: SQLErrorKind {
        switch self {
        case .server(let code, _, _):
            return Self.kind(forServerCode: code)

        // Everything else is the connection, not the statement.
        case .connectionClosed, .malformedHandshake, .unsupportedProtocolVersion,
             .tlsNotSupportedByServer, .compressionFailed:
            return .connection
        case .repeatedAuthSwitch, .insecureAuthRefused, .unsupportedAuthPlugin:
            return .authentication
        default:
            return .other
        }
    }

    static func kind(forServerCode code: UInt16) -> SQLErrorKind {
        switch code {
        case 1062, 1586: return .uniqueViolation          // ER_DUP_ENTRY(_WITH_KEY_NAME)
        case 1451, 1452, 1216, 1217: return .foreignKeyViolation
        case 1048, 1364: return .notNullViolation         // BAD_NULL_ERROR, NO_DEFAULT_FOR_FIELD
        case 3819, 3813: return .checkViolation           // CHECK_CONSTRAINT_VIOLATED

        case 1213: return .deadlock                       // ER_LOCK_DEADLOCK
        case 1205: return .lockTimeout                    // ER_LOCK_WAIT_TIMEOUT

        case 1406, 1265: return .dataTooLong              // DATA_TOO_LONG, WARN_DATA_TRUNCATED
        case 1264, 1690: return .numericOutOfRange

        case 1044, 1045, 1142, 1143, 1227: return .permission
        case 1064, 1146, 1054, 1051, 1109: return .syntax // parse error, no such table/column

        case 1021, 1114, 3: return .outOfSpace            // DISK_FULL, RECORD_FILE_FULL
        case 1290, 1836: return .readOnly                 // OPTION_PREVENTS_STATEMENT, READ_ONLY

        // MySQL reports an exceeded `max_execution_time` as 3024; MariaDB
        // reports its own `max_statement_time` as **1969**, which was not
        // mapped at all and so arrived as `.other` — not transient, not
        // recognisable as a timeout by any caller. Verified against all six
        // fixtures rather than from the error tables: MySQL 8.0/8.4/9.1 give
        // 3024 (HY000), MariaDB 11.4/12.3 give 1969 (70100).
        //
        // 1317 is a `KILL QUERY`, which is an operator's decision rather than a
        // deadline, but arrives through the same abort path.
        case 1317, 3024, 1969: return .timeout
        case 2006, 2013, 1053, 1077: return .connection   // SERVER_GONE / LOST / SHUTDOWN

        // The data itself is damaged. Retrying is pointless and the answer is a
        // repair or a backup, so it does not belong with the typos in `.other`.
        // ER_NOT_KEYFILE, ER_CRASHED_ON_USAGE, ER_CRASHED_ON_REPAIR,
        // ER_INDEX_CORRUPT, ER_TABLE_CORRUPT.
        case 1034, 1194, 1195, 1712, 1877: return .dataCorrupted

        default: return .other
        }
    }

    public var sqlState: String? {
        if case .server(_, let state, _) = self { return state }
        return nil
    }

    public var nativeCode: Int? {
        if case .server(let code, _, _) = self { return Int(code) }
        return nil
    }

    /// Whether the statement might have taken effect.
    ///
    /// **This answers differently from the Postgres driver, deliberately.**
    /// There, a server error means the statement applied nothing, because a
    /// Postgres statement is atomic — the server wraps each one in an implicit
    /// savepoint. MySQL makes no such promise: a statement against a
    /// non-transactional engine can apply some rows and then fail, and a
    /// multi-row `INSERT` that hits a duplicate key partway through has already
    /// written the rows before it. So a bare server error here is *not*
    /// evidence that nothing landed.
    ///
    /// Deadlock and lock-wait timeout are the exceptions, and they are
    /// exceptions for a reason rather than by convention: InnoDB rolls the
    /// victim's transaction back before reporting either one. They are both
    /// transient and certainly not applied, which is the conjunction
    /// ``SQLDiagnosable/isSafeToRetry`` needs.
    ///
    /// An execution timeout is deliberately **not** on that list, which is the
    /// opposite of the Postgres driver's treatment of `57014`. Postgres cancels
    /// a statement by aborting it, so nothing applied. MariaDB's
    /// `max_statement_time` is not restricted to `SELECT`, and neither it nor a
    /// `KILL QUERY` can promise a non-transactional table was left alone — so
    /// the conservative answer is the correct one here even though it is the
    /// wrong one there.
    public var mayHaveApplied: Bool {
        switch self {
        case .server(let code, _, _):
            // 1213 deadlock and 1205 lock timeout both roll back.
            return !(code == 1213 || code == 1205)
        default:
            return true
        }
    }
}

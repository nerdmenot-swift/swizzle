import SwizzleCore

/// Postgres SQLSTATE codes, in the shared vocabulary.
///
/// Unlike MySQL — where the numeric error is the stable identity and SQLSTATE is
/// an afterthought — Postgres treats SQLSTATE as the real code. It is documented,
/// versioned, and **hierarchical**: the first two characters are the class, so an
/// unrecognised code still classifies correctly through its class. That is why
/// this table can be short and still not lose anything: a code Postgres adds
/// tomorrow in class `23` is an integrity violation today.
public enum PostgresSQLState {

    /// The code, then the class. Exact codes win; the class catches the rest.
    public static func kind(for sqlState: String) -> SQLErrorKind {
        switch sqlState {
        // Class 23 — integrity constraint violation. The four distinctions a
        // caller actually branches on.
        case "23505": return .uniqueViolation
        case "23503": return .foreignKeyViolation
        case "23502": return .notNullViolation
        case "23514": return .checkViolation
        // An exclusion constraint says "this row overlaps one already there",
        // which is what a caller does about a unique violation too.
        case "23P01": return .uniqueViolation

        // Class 40 — transaction rollback. Both are the server picking a victim
        // and telling it to try again, which is the whole point of `isTransient`.
        case "40001": return .serializationFailure
        case "40P01": return .deadlock

        case "55P03": return .lockTimeout          // lock_not_available
        case "55006": return .lockTimeout          // object_in_use

        // Both `statement_timeout` and a client `CancelRequest` land here, which
        // is why cancellation and timeout are one kind rather than two.
        case "57014": return .timeout

        case "53100": return .outOfSpace           // disk_full
        case "53200", "53400": return .outOfSpace  // out_of_memory, config limit
        case "53300": return .connection           // too_many_connections

        case "25006": return .readOnly             // read_only_sql_transaction
        case "25P02": return .other                // in_failed_sql_transaction

        case "22001": return .dataTooLong          // string_data_right_truncation
        case "22003": return .numericOutOfRange

        case "42501": return .permission           // insufficient_privilege

        // data_corrupted, index_corrupted. Their own kind for the same reason as
        // the other two engines: retrying achieves nothing, and the answer is a
        // backup rather than a fix to the query.
        case "XX001", "XX002": return .dataCorrupted

        // The server is going away. Distinct from class 08 only in who noticed.
        case "57P01", "57P02", "57P03", "57P05": return .connection

        default:
            return kind(forClass: String(sqlState.prefix(2)))
        }
    }

    /// The class, which is what makes an unknown code still useful.
    static func kind(forClass sqlClass: String) -> SQLErrorKind {
        switch sqlClass {
        case "08": return .connection              // connection exception
        case "28": return .authentication          // invalid authorization
        case "0A": return .syntax                  // feature not supported
        case "22": return .other                   // data exception
        case "23": return .checkViolation          // integrity constraint, unclassified
        case "25": return .other                   // invalid transaction state
        case "40": return .serializationFailure    // transaction rollback
        case "42": return .syntax                  // syntax error or access rule
        case "3D", "3F": return .syntax            // no such catalog / schema
        case "53": return .outOfSpace              // insufficient resources
        case "54": return .other                   // program limit exceeded
        case "55": return .lockTimeout             // object not in prerequisite state
        case "57": return .connection              // operator intervention
        case "58": return .other                   // system error
        case "XX": return .other                   // internal error
        default: return .other
        }
    }

    /// Whether a statement that failed this way might still have taken effect.
    ///
    /// **Postgres answers this more definitively than MySQL can.** Any error
    /// aborts the surrounding transaction, and there is no non-transactional
    /// storage engine to leave half a statement behind — so a server error that
    /// arrived means the statement applied nothing.
    ///
    /// The exceptions are the codes where the server was *leaving*: a shutdown or
    /// a dropped connection can arrive after the statement committed, and the wire
    /// cannot say which side of the commit it fell on.
    static func mayHaveApplied(_ sqlState: String) -> Bool {
        // `57014` is the exception inside its own class, and getting it wrong has
        // a direction: class `57` is "operator intervention", which mostly means
        // the server is shutting down and the statement's fate is unknown — but
        // *this* code means the statement was cancelled, which Postgres
        // implements by aborting it. Nothing applied.
        //
        // Left in the class, it made every cancelled or timed-out statement look
        // like it might have landed, so `isSafeToRetry` said no to the one family
        // of failures that is unambiguously safe to retry. Found by cancelling a
        // real `pg_sleep`.
        if sqlState == "57014" { return false }

        switch String(sqlState.prefix(2)) {
        case "08", "57", "58", "XX": return true
        default: return false
        }
    }
}

extension PostgresConnectionError: SQLDiagnosable {
    public var sqlKind: SQLErrorKind {
        switch self {
        case .server(let message):
            return PostgresSQLState.kind(for: message.sqlState)
        case .authentication:
            return .authentication
        case .protocolVersion, .unexpected:
            return .connection
        }
    }

    public var sqlState: String? {
        guard case .server(let message) = self, !message.sqlState.isEmpty else { return nil }
        return message.sqlState
    }

    /// Postgres has no numeric error code — SQLSTATE *is* the code. Reporting one
    /// here would mean inventing it.
    public var nativeCode: Int? { nil }

    public var mayHaveApplied: Bool {
        switch self {
        case .server(let message):
            return PostgresSQLState.mayHaveApplied(message.sqlState)
        case .authentication, .protocolVersion:
            // The connection never carried a statement.
            return false
        case .unexpected:
            // Something went wrong mid-conversation and the position in the
            // stream is unknown. Conservative.
            return true
        }
    }
}

extension PostgresServerMessage {
    /// Which constraint rejected the row.
    ///
    /// Postgres names it; MySQL only puts it in the message text where it has to
    /// be scraped back out. Worth surfacing, because "which unique index" is the
    /// first thing a caller handling a duplicate wants to know.
    public var violatedConstraint: String? { constraintName }
}

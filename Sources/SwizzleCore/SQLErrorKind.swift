/// What went wrong, in terms that mean the same thing on every engine.
///
/// ## Why this exists
///
/// Without it, the only thing a caller can do with a failure is show it to
/// somebody. Whether to retry, whether a retry might duplicate a write, whether
/// the problem is the query or the connection — all of that lives in engine
/// specific codes: MySQL's `1213`, Postgres's `40P01`, SQLite's `SQLITE_BUSY`.
/// Every application that needs the answer ends up writing the same table.
///
/// Deliberately coarse. This is not a catalogue of every error a server can
/// raise — the engines already have those, and `nativeCode`/`sqlState` carry them
/// through untouched. It is the set of distinctions that change what a program
/// *does*.
public enum SQLErrorKind: String, Sendable, Equatable, Codable {
    /// Could not reach the server, or the connection died.
    case connection
    /// The statement or the connection exceeded a deadline.
    case timeout
    /// Credentials rejected.
    case authentication
    /// The statement is not valid SQL, or names something that does not exist.
    case syntax
    /// The server understood but refused: no privilege.
    case permission

    /// A unique index or primary key rejected the row.
    case uniqueViolation
    /// A foreign key rejected the row.
    case foreignKeyViolation
    /// A `NOT NULL` column got null.
    case notNullViolation
    /// A `CHECK` constraint rejected the row.
    case checkViolation

    /// Two transactions deadlocked and this one was chosen to die.
    case deadlock
    /// A serializable transaction could not be ordered and must be retried.
    case serializationFailure
    /// Waiting for a lock took too long.
    case lockTimeout

    /// The value did not fit the column.
    case dataTooLong
    /// A number was out of the column's range.
    case numericOutOfRange

    /// The database, tablespace or disk is full.
    case outOfSpace
    /// The database is read-only, or in recovery.
    case readOnly

    /// The stored data itself is damaged — a corrupt database file, a corrupt
    /// index, a table the server has marked as crashed.
    ///
    /// Its own case because the correct response is unlike every other kind's.
    /// Retrying accomplishes nothing and may make things worse; the answer is to
    /// stop, and to reach for a backup or a repair. All three engines can report
    /// it — SQLite as `SQLITE_CORRUPT`, Postgres as `XX001`/`XX002`, MySQL as
    /// "table is marked as crashed" — and all three used to fold it into
    /// ``other``, where it was indistinguishable from a typo.
    case dataCorrupted

    /// Nothing above. The native code is still there.
    case other

    /// Whether a retry is *expected* to succeed.
    ///
    /// True only for the failures a server raises to say "try again" — contention
    /// it resolved by picking a victim. A syntax error is not transient however
    /// many times you send it, and a unique violation means the row is already
    /// there.
    public var isTransient: Bool {
        switch self {
        case .deadlock, .serializationFailure, .lockTimeout, .connection, .timeout:
            true
        default:
            false
        }
    }

    /// Whether this failure is about the *statement* rather than the connection.
    ///
    /// A pool uses this to decide whether to hand the connection back or discard
    /// it: a constraint violation leaves a perfectly good connection, a protocol
    /// error does not.
    public var isStatementLevel: Bool {
        switch self {
        case .connection, .authentication: false
        default: true
        }
    }
}

/// An error a caller can reason about rather than only display.
///
/// Every driver's own error type conforms, so `catch let error as SQLDiagnosable`
/// works whichever engine raised it, and the native code stays reachable for the
/// cases the taxonomy deliberately does not model.
public protocol SQLDiagnosable: Error, Sendable {
    var sqlKind: SQLErrorKind { get }
    /// The five-character SQLSTATE, where the engine speaks it.
    var sqlState: String? { get }
    /// The engine's own numeric code — MySQL's error number, SQLite's extended
    /// result code, and so on.
    var nativeCode: Int? { get }

    /// Whether the statement may have reached the server and taken effect.
    ///
    /// **The distinction that makes automatic retry safe or dangerous**, and the
    /// one most error types leave out. It is not derivable from the kind: a
    /// connection that failed while opening definitely applied nothing, while one
    /// that died waiting for a reply may have applied everything. Only the driver
    /// knows which, so it reports it rather than the taxonomy inferring it.
    ///
    /// Go's `database/sql` draws the same line with `errBadConnNoWrite`, and it is
    /// the reason it can retry some failures and not others.
    var mayHaveApplied: Bool { get }
}

extension SQLDiagnosable {
    public var sqlState: String? { nil }
    public var nativeCode: Int? { nil }
    /// Conservative: a failure that has not said otherwise might have landed.
    public var mayHaveApplied: Bool { true }

    /// Whether retrying is both likely to help and certain not to duplicate.
    ///
    /// The conjunction is the point. A deadlock is transient *and* rolled back, so
    /// it is safe. A connection that dropped mid-statement is transient but may
    /// have applied, so an automatic retry could double a payment — which is
    /// exactly the bug this property exists to prevent someone writing.
    public var isSafeToRetry: Bool {
        sqlKind.isTransient && !mayHaveApplied
    }
}

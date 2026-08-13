import CSQLite
import SwizzleCore

/// SQLite's result codes, in the shared vocabulary.
///
/// The extended codes are the useful ones: plain `SQLITE_CONSTRAINT` says only
/// "a constraint", while `SQLITE_CONSTRAINT_UNIQUE` says which — and the
/// difference between a unique violation and a foreign-key violation is exactly
/// the sort of thing a caller branches on.
/// SQLite's extended result codes.
///
/// They are `#define`s that compute a value — `SQLITE_CONSTRAINT | (8<<8)` — so
/// they do not import into Swift. Written out here with the same arithmetic, which
/// is more legible than the constants would have been anyway: the low byte is the
/// primary code and the high byte says which flavour.
enum SQLiteExtended {
    static let constraintCheck      = SQLITE_CONSTRAINT | (1 << 8)
    static let constraintForeignKey = SQLITE_CONSTRAINT | (3 << 8)
    static let constraintNotNull    = SQLITE_CONSTRAINT | (5 << 8)
    static let constraintPrimaryKey = SQLITE_CONSTRAINT | (6 << 8)
    static let constraintUnique     = SQLITE_CONSTRAINT | (8 << 8)

    static let busySnapshot = SQLITE_BUSY | (2 << 8)
    static let busyTimeout  = SQLITE_BUSY | (3 << 8)
    static let lockedSharedCache = SQLITE_LOCKED | (1 << 8)

    static let readOnlyRecovery  = SQLITE_READONLY | (1 << 8)
    static let readOnlyCantLock  = SQLITE_READONLY | (2 << 8)
    static let readOnlyRollback  = SQLITE_READONLY | (3 << 8)
    static let readOnlyDBMoved   = SQLITE_READONLY | (4 << 8)
    static let readOnlyDirectory = SQLITE_READONLY | (6 << 8)

    static let corruptVTab     = SQLITE_CORRUPT | (1 << 8)
    static let corruptSequence = SQLITE_CORRUPT | (2 << 8)
    static let corruptIndex    = SQLITE_CORRUPT | (3 << 8)

    /// The low byte, which is the primary code however extended the value is.
    static func primary(_ code: Int32) -> Int32 { code & 0xFF }
}

extension SQLiteError: SQLDiagnosable {
    public var sqlKind: SQLErrorKind {
        switch code {
        case SQLiteExtended.constraintUnique, SQLiteExtended.constraintPrimaryKey:
            return .uniqueViolation
        case SQLiteExtended.constraintForeignKey:
            return .foreignKeyViolation
        case SQLiteExtended.constraintNotNull:
            return .notNullViolation
        case SQLiteExtended.constraintCheck:
            return .checkViolation

        // Both mean contention. `BUSY` is another *connection*, `LOCKED` is
        // another statement on this one — and only the first is worth retrying,
        // since the second will still be there.
        case SQLITE_BUSY, SQLiteExtended.busySnapshot, SQLiteExtended.busyTimeout,
             SQLITE_LOCKED, SQLiteExtended.lockedSharedCache:
            return .lockTimeout

        case SQLITE_READONLY, SQLiteExtended.readOnlyDBMoved,
             SQLiteExtended.readOnlyDirectory, SQLiteExtended.readOnlyRecovery,
             SQLiteExtended.readOnlyRollback, SQLiteExtended.readOnlyCantLock:
            return .readOnly
        // `NOMEM` joins `FULL` because both mean "no room to finish", and the
        // caller's options are the same. Postgres classes its own out-of-memory
        // (`53200`) the same way.
        case SQLITE_FULL, SQLITE_NOMEM:
            return .outOfSpace
        case SQLITE_PERM, SQLITE_AUTH:
            return .permission
        case SQLITE_TOOBIG:
            return .dataTooLong
        case SQLITE_INTERRUPT:
            return .timeout
        case SQLITE_CANTOPEN, SQLITE_NOTADB, SQLITE_IOERR:
            return .connection

        // The file is damaged. Retrying is pointless and the answer is a backup,
        // which is why this is not folded into `.other` with the typos.
        case SQLITE_CORRUPT, SQLiteExtended.corruptVTab, SQLiteExtended.corruptIndex,
             SQLiteExtended.corruptSequence:
            return .dataCorrupted

        // A value SQLite refused on type grounds — text into an
        // `INTEGER PRIMARY KEY`, or anything a `STRICT` table will not take. It
        // is a rejected *value*, so it belongs with the other integrity refusals
        // rather than with syntax errors.
        case SQLITE_MISMATCH:
            return .checkViolation

        // Another process is not following the locking protocol — historically a
        // second client with a different locking mode on the same file. Contention
        // shaped, and worth retrying once.
        case SQLITE_PROTOCOL:
            return .lockTimeout
        case SQLITE_ERROR, SQLITE_MISUSE, SQLITE_RANGE:
            // `SQLITE_ERROR` is SQLite's catch-all for "did not compile", which
            // in practice means a syntax error or a missing table or column.
            return .syntax
        default:
            // A bare CONSTRAINT with no extended code still says that much.
            return SQLiteExtended.primary(code) == SQLITE_CONSTRAINT ? .checkViolation : .other
        }
    }

    public var nativeCode: Int? { Int(code) }

    /// SQLite is the one engine that can answer this honestly.
    ///
    /// It is in-process, so there is no window where a statement is in flight and
    /// unaccounted for: if `sqlite3_step` returned an error, the statement did not
    /// commit. The transaction is either rolled back or never started.
    ///
    /// The exception is an I/O error, where the file may have been partially
    /// written before the failure.
    public var mayHaveApplied: Bool {
        SQLiteExtended.primary(code) == SQLITE_IOERR
    }
}

import NIOConcurrencyHelpers

/// Server-reported session state, refreshed from every OK/EOF packet.
///
/// Deliberately mirrors what the *server* says rather than tracking a local
/// "am I in a transaction" flag. MySQL commits implicitly on DDL and on a
/// handful of other statements, so local bookkeeping drifts out of step with
/// reality precisely when it matters — and does so silently. Reading the
/// server's `SERVER_STATUS_IN_TRANS` cannot drift.
public final class MySQLSessionState: Sendable {
    private let state = NIOLockedValueBox(MySQLStatusFlags())

    public init() {}

    public var statusFlags: MySQLStatusFlags {
        state.withLockedValue { $0 }
    }

    /// True while a transaction is open, as the server sees it.
    public var isInTransaction: Bool {
        statusFlags.contains(.inTransaction)
    }

    public var isAutocommit: Bool {
        statusFlags.contains(.autocommit)
    }

    /// True when the server has `ANSI_QUOTES` enabled, where `"` quotes
    /// identifiers rather than delimiting strings.
    public var isANSIQuotes: Bool {
        statusFlags.contains(.ansiQuotes)
    }

    func update(_ flags: MySQLStatusFlags) {
        state.withLockedValue { $0 = flags }
    }
}

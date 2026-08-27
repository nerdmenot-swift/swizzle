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


    /// Why this connection stopped being usable, if it has.
    ///
    /// `send` refuses to write to an inactive channel and reported only "the
    /// connection is closed" — true, and the least useful thing it could say.
    /// The driver knows more than that: the handler sees the close or the error
    /// that caused it, and by the time a caller asks, that knowledge has been
    /// thrown away.
    ///
    /// It cost a CI cycle to care about this. Two binlog tests failed on a
    /// contended macOS runner with exactly that message, and it names neither
    /// what closed the connection nor when — so the log could not distinguish a
    /// server that hung up from a timeout of ours from a peer reset, and the
    /// investigation had nothing to work from but a guess.
    ///
    /// Only the **first** cause is kept. A close cascades — an error arrives,
    /// the channel goes inactive, in-flight commands fail — and the last writer
    /// would overwrite the diagnosis with its own consequence.
    private let closed = NIOLockedValueBox<String?>(nil)

    var closeReason: String? {
        closed.withLockedValue { $0 }
    }

    func recordClose(_ reason: String) {
        closed.withLockedValue { if $0 == nil { $0 = reason } }
    }

    func update(_ flags: MySQLStatusFlags) {
        state.withLockedValue { $0 = flags }
    }
}

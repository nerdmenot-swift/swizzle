import SwizzleCore

/// What a statement did.
public struct PostgresQueryResult: Sendable, Equatable {
    public var columns: [PostgresColumnDescription] = []
    public var rows: [[SQLValue]] = []
    /// The server's own words — `INSERT 0 3`, `UPDATE 5`, `SELECT 12`.
    public var commandTag: String?
    /// Rows the statement changed, parsed from the tag.
    ///
    /// **The number postgres-nio would not give us.** It lives only in the
    /// command tag, and a driver that does not parse it has to guess — which is
    /// how `executeUpdate` came to return a drained row count of zero for months.
    public var affectedRows: Int?
    /// Set when a row-limited `Execute` stopped short, so the caller knows to ask
    /// for more rather than assuming the result ended.
    public var isSuspended = false

    /// The raw bytes of any column whose OID nothing recognised.
    ///
    /// Kept **only** for those columns, so the common query carries no extra
    /// memory at all. A value cannot be un-decoded once it has become a `.blob`,
    /// and resolving a user-defined type takes a round trip that can only happen
    /// after `RowDescription` — so the bytes have to survive that long or the
    /// second pass has nothing to work from.
    var unresolvedBytes: [Int: [[UInt8]?]] = [:]

    public init() {}

    /// Decodes the unrecognised columns again, now that the registry knows them.
    mutating func redecode(with registry: PostgresTypeRegistry) {
        for (columnIndex, columnBytes) in unresolvedBytes {
            guard columnIndex < columns.count else { continue }
            let oid = columns[columnIndex].dataTypeOID
            let format = columns[columnIndex].format
            for rowIndex in rows.indices where rowIndex < columnBytes.count {
                guard let bytes = columnBytes[rowIndex],
                      let value = registry.decode(bytes, oid: oid, format: format)
                else { continue }
                rows[rowIndex][columnIndex] = value
            }
        }
        unresolvedBytes.removeAll()
    }
}

/// Which server-side statement to bind, and whether it still needs parsing.
///
/// The unnamed statement is always correct and always costs a `Parse`; a named
/// one is parsed once and bound thereafter. Carrying both in one type keeps the
/// state machine free of any knowledge about caching — it is told what to send,
/// not asked to decide.
public struct PostgresPreparedStatementRef: Sendable, Equatable {
    /// The empty string is the unnamed statement.
    public var name: String
    public var needsParse: Bool

    public init(name: String, needsParse: Bool) {
        self.name = name
        self.needsParse = needsParse
    }

    public static let unnamed = PostgresPreparedStatementRef(name: "", needsParse: true)
}

/// A statement's shape, from `Describe`, before it has run.
public struct PostgresStatementDescription: Sendable, Equatable {
    public var parameterTypes: [UInt32] = []
    public var columns: [PostgresColumnDescription] = []

    public init() {}
}

/// Drives one statement from send to `ReadyForQuery`.
///
/// Pure, like the two machines beneath it. The interesting rule it encodes is the
/// one that trips people up: after an error, the server **discards every message
/// until `Sync`**, so a client that reports the failure and moves on will find its
/// next statement's replies arriving for a statement that never ran. The machine
/// therefore keeps consuming to `ReadyForQuery` and reports only then.
public struct PostgresQueryStateMachine: Sendable {

    public enum Mode: Sendable, Equatable {
        /// One `Query` message. Multiple statements allowed; this is how
        /// migrations run.
        case simple(String)
        /// Parse/Bind/Execute/Sync, with values already encoded.
        case extended(
            sql: String, bindings: [[UInt8]?], maxRows: Int32 = 0,
            statement: PostgresPreparedStatementRef = .unnamed,
            parameterTypes: [UInt32] = []
        )
        /// Another `Execute` against a portal that suspended.
        ///
        /// No `Parse` and no `Bind` — the portal is still open and still holds
        /// its position, so re-binding would restart it from the first row.
        ///
        /// The columns have to be carried in, because a resumed `Execute` sends
        /// **no `RowDescription`**: the server described the portal once and does
        /// not repeat itself. Without them every value decodes against an unknown
        /// OID and comes back as text — which counting rows does not notice.
        case resumePortal(maxRows: Int32, columns: [PostgresColumnDescription])

        /// Parse/Bind/Describe/Execute/**Flush** — no `Sync`.
        ///
        /// `Flush` asks the server to push out what it has without ending the
        /// implicit transaction block, which `Sync` would. That is the whole
        /// difference: results arrive now, the block stays open, and a later
        /// statement can use them and still be rolled back with the rest.
        ///
        /// Completion is therefore `CommandComplete` rather than
        /// `ReadyForQuery` — the latter only comes after a `Sync`, so waiting
        /// for it here would hang.
        case pipelined(
            sql: String, bindings: [[UInt8]?],
            statement: PostgresPreparedStatementRef = .unnamed
        )

        /// Parse/Describe/Sync, and **never** Bind or Execute.
        ///
        /// The whole reason this driver exists: it asks the server for a
        /// statement's shape without running it, which is what pillar 3's
        /// prepare-and-describe needs and what postgres-nio keeps internal.
        case describe(String)
    }

    public enum Action: Sendable, Equatable {
        case send([PostgresFrontendMessage])
        case wait
        case succeeded(PostgresQueryResult)
        case described(PostgresStatementDescription)
        case failed(PostgresConnectionError)
    }

    enum Phase: Sendable {
        case unsent
        case running
        /// An error arrived; consuming until `ReadyForQuery` because the server is
        /// discarding everything until then.
        case draining(PostgresServerMessage)
        case done
    }

    let mode: Mode
    var phase: Phase = .unsent
    /// True for a `Flush`-terminated statement, which never sees a
    /// `ReadyForQuery` of its own.
    var completesOnCommandComplete: Bool {
        if case .pipelined = mode { return true }
        return false
    }
    var result = PostgresQueryResult()
    var description = PostgresStatementDescription()
    /// The formats the server said it would use, per column.
    var columnFormats: [Int16] = []

    public init(mode: Mode) { self.mode = mode }

    public mutating func start() -> Action {
        phase = .running
        switch mode {
        case .simple(let sql):
            return .send([.query(sql)])

        case .extended(let sql, let bindings, let maxRows, let statement, let parameterTypes):
            // The portal is always unnamed: it is replaced on each use and needs
            // no explicit Close, which is one fewer round trip and one fewer thing
            // to leak. The *statement* may be named, when it is cached.
            var messages: [PostgresFrontendMessage] = []
            if statement.needsParse {
                messages.append(
                    .parse(
                        name: statement.name, query: sql, parameterTypes: parameterTypes
                    )
                )
            }
            messages.append(
                .bind(
                    portal: "", statement: statement.name,
                    parameterFormats: [], parameters: bindings,
                    // Ask for binary results: it is both cheaper and lossless for
                    // the types that have a text rendering worth avoiding.
                    resultFormats: [1]
                )
            )
            // **Describe the portal, always.**
            //
            // Not an optimisation and not optional: a portal sends a
            // `RowDescription` *only* if it is asked to. Without this the server
            // replies with bare `DataRow`s and no column metadata at all — so
            // every value decodes through the unknown-OID path and comes back as
            // text. `SELECT pg_try_advisory_lock($1)` returns `"\u{01}"` instead
            // of `true`, and nothing fails; it is simply wrong.
            //
            // The simple protocol has no such trap, which is what makes this easy
            // to miss: unbound queries look perfectly fine.
            messages.append(.describe(.portal, name: ""))
            messages.append(.execute(portal: "", maxRows: maxRows))
            messages.append(.sync)
            return .send(messages)

        case .resumePortal(let maxRows, let columns):
            // The columns come from the first batch: the server describes a portal
            // once and does not repeat itself, so this is the only way the values
            // decode as anything but text.
            result.columns = columns
            columnFormats = columns.map(\.format)
            return .send([
                .execute(portal: "", maxRows: maxRows),
                .sync,
            ])

        case .pipelined(let sql, let bindings, let statement):
            var messages: [PostgresFrontendMessage] = []
            if statement.needsParse {
                messages.append(.parse(name: statement.name, query: sql, parameterTypes: []))
            }
            messages.append(
                .bind(
                    portal: "", statement: statement.name,
                    parameterFormats: [], parameters: bindings, resultFormats: [1]
                )
            )
            messages.append(.describe(.portal, name: ""))
            messages.append(.execute(portal: "", maxRows: 0))
            // `Flush`, not `Sync`: push the results out and leave the implicit
            // transaction open for the next statement.
            messages.append(.flush)
            return .send(messages)

        case .describe(let sql):
            return .send([
                .parse(name: "", query: sql, parameterTypes: []),
                .describe(.statement, name: ""),
                .sync,
            ])
        }
    }

    public mutating func handle(_ message: PostgresBackendMessage) -> Action {
        // Notices and parameter changes are never a reply to a statement.
        switch message {
        case .notice, .parameterStatus, .backendKeyData:
            return .wait
        default:
            break
        }

        if case .draining(let error) = phase {
            // Everything until ReadyForQuery is discarded by the server, so it is
            // discarded here too — reporting early would leave the next statement
            // reading this one's tail.
            if case .readyForQuery = message {
                phase = .done
                return .failed(.server(error))
            }
            return .wait
        }

        switch message {
        case .error(let error):
            // A Flush-terminated statement has no `ReadyForQuery` of its own —
            // that only comes after the session's `Sync` — so draining to one
            // would wait forever. The caller is told now, and the session's
            // `Sync` consumes the tail the server is discarding.
            if completesOnCommandComplete {
                phase = .done
                return .failed(.server(error))
            }
            phase = .draining(error)
            return .wait

        case .parseComplete, .bindComplete, .closeComplete, .noData:
            return .wait

        case .parameterDescription(let oids):
            description.parameterTypes = oids
            return .wait

        case .rowDescription(let columns):
            description.columns = columns
            result.columns = columns
            columnFormats = columns.map(\.format)
            return .wait

        case .dataRow(let values):
            result.rows.append(decode(values))
            retainUnresolved(values)
            return .wait

        case .commandComplete(let tag):
            result.commandTag = tag
            result.affectedRows = PostgresCommandTag.affectedRows(tag)
            // A Flush-terminated statement ends here: its `ReadyForQuery` only
            // arrives after the session's `Sync`, so waiting would hang.
            if completesOnCommandComplete {
                phase = .done
                return .succeeded(result)
            }
            return .wait

        case .emptyQueryResponse:
            result.commandTag = ""
            return .wait

        case .portalSuspended:
            // A row-limited Execute stopped short. Flagged rather than treated as
            // the end, or a caller would silently see a truncated result.
            result.isSuspended = true
            return .wait

        case .readyForQuery:
            phase = .done
            if case .describe = mode { return .described(description) }
            return .succeeded(result)

        default:
            return .wait
        }
    }

    /// Turns wire values into `SQLValue`s using the formats the server declared.
    ///
    /// The format is per column and comes from `RowDescription`, not from what we
    /// asked for: a server may answer a binary request with text for a type it has
    /// no binary representation of, and decoding those bytes as binary would be
    /// nonsense.
    /// Keeps the bytes of columns nothing recognised, so they can be decoded
    /// again once the type registry has been asked about them.
    ///
    /// Only those columns: a query over built-in types stores nothing.
    mutating func retainUnresolved(_ values: [[UInt8]?]) {
        for index in result.columns.indices where index < values.count {
            let oid = result.columns[index].dataTypeOID
            guard PostgresOID(rawValue: oid) == nil else { continue }
            result.unresolvedBytes[index, default: []].append(values[index])
        }
    }

    func decode(_ values: [[UInt8]?]) -> [SQLValue] {
        values.enumerated().map { index, bytes in
            let oid = index < result.columns.count ? result.columns[index].dataTypeOID : 0
            let format = index < columnFormats.count ? columnFormats[index] : 0
            return PostgresValueDecoder.decode(bytes, oid: oid, format: format)
        }
    }
}

/// Reads Postgres's command tags.
///
/// The tag is the only place the affected-row count exists — there is no separate
/// field for it anywhere in the protocol. A driver that does not parse it cannot
/// answer "how many rows did that update", which is exactly the gap that made
/// `executeUpdate` return zero for months on the borrowed driver.
public enum PostgresCommandTag {
    /// `INSERT 0 3` → 3, `UPDATE 5` → 5, `SELECT 12` → 12.
    ///
    /// `INSERT` is the odd one: it carries an OID before the count, historically
    /// the row's OID and always `0` now. Taking the *last* field handles it and
    /// every other form without special-casing.
    public static func affectedRows(_ tag: String) -> Int? {
        let parts = tag.split(separator: " ")
        guard parts.count >= 2, let count = Int(parts[parts.count - 1]) else {
            // `BEGIN`, `COMMIT`, `SET`, `CREATE TABLE` — commands with no count.
            // Nil rather than zero: "no count" and "changed nothing" are different
            // answers and only one of them is a number.
            return nil
        }
        return count
    }

    /// The verb, for diagnostics.
    public static func command(_ tag: String) -> String {
        String(tag.split(separator: " ").first ?? "")
    }
}

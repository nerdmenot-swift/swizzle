import SwizzleCore

/// One statement in a pipeline.
public struct PostgresPipelineStatement: Sendable {
    public var sql: String
    public var bindings: [[UInt8]?]
    /// Parameter type hints, if the caller has them. Empty lets the server infer.
    public var parameterTypes: [UInt32]

    public init(sql: String, bindings: [[UInt8]?] = [], parameterTypes: [UInt32] = []) {
        self.sql = sql
        self.bindings = bindings
        self.parameterTypes = parameterTypes
    }
}

/// A pipeline failed, and which statement did it.
///
/// The index is diagnostic, not a recovery plan — and getting that round the
/// right way took a test. Statements sent between two `Sync`s form an **implicit
/// transaction block**, so an error rolls back the entire pipeline, including the
/// statements that had already succeeded. It is the `Sync` that commits.
///
/// So a pipeline is atomic whether or not the caller wrapped it in a transaction,
/// and `completed` describes which statements *produced results* before the
/// failure — which is what a developer needs to find the bad one — rather than
/// which ones persisted. None of them did.
public struct PostgresPipelineError: Error, Sendable, CustomStringConvertible {
    /// Zero-based, into the statements as submitted.
    public let statementIndex: Int
    public let sql: String
    public let underlying: PostgresConnectionError
    /// Statements before this one that produced results before the failure.
    ///
    /// Diagnostic only — the implicit transaction rolled them back too.
    public let completed: [PostgresQueryResult]

    public var description: String {
        "statement \(statementIndex + 1) of the pipeline failed: \(underlying.description)\n"
            + "\(sql)\n"
            + "\(completed.count) earlier statement(s) had produced results; every later "
            + "one was discarded by the server. A pipeline is an implicit transaction, so "
            + "the whole batch rolled back — nothing was applied"
    }
}

/// Runs several statements with a single `Sync`.
///
/// ## What this actually saves
///
/// Not bytes — the same messages go out either way. It saves **round trips**: a
/// serial driver waits for `ReadyForQuery` before sending the next statement, so
/// ten statements cost ten round trips. Pipelined they cost one. On a link with
/// any latency at all that is the difference between 10 ms and 1 ms, and it is why
/// `pg_restore` and every bulk tool pipeline.
///
/// ## It is already atomic
///
/// Statements between two `Sync`s form an **implicit transaction block**, so one
/// bad statement rolls back the whole batch — including the ones that had already
/// succeeded. That is stronger than it first appears, and the opposite of what a
/// "these are just several statements" reading suggests: wrapping a pipeline in
/// an explicit transaction changes nothing about its atomicity.
///
/// What the error still has to carry is *which* statement failed, because the
/// server names the failure and not the statement.
public struct PostgresPipelineStateMachine: Sendable {

    public enum Action: Sendable {
        case send([PostgresFrontendMessage])
        case wait
        case succeeded([PostgresQueryResult])
        case failed(PostgresPipelineError)
    }

    let statements: [PostgresPipelineStatement]
    var results: [PostgresQueryResult]
    /// Which statement's replies are arriving now.
    var current = 0
    var failure: PostgresServerMessage?
    var failureIndex = 0
    var columnFormats: [Int16] = []
    var isDone = false

    public init(statements: [PostgresPipelineStatement]) {
        self.statements = statements
        self.results = Array(repeating: PostgresQueryResult(), count: statements.count)
    }

    public mutating func start() -> Action {
        var messages: [PostgresFrontendMessage] = []
        messages.reserveCapacity(statements.count * 4 + 1)

        for statement in statements {
            // The unnamed statement and portal are reused across the whole
            // pipeline, which is safe *because* the replies come back in order:
            // each Execute has finished with the portal before the next Bind
            // replaces it.
            messages.append(
                .parse(name: "", query: statement.sql, parameterTypes: statement.parameterTypes)
            )
            messages.append(
                .bind(
                    portal: "", statement: "",
                    parameterFormats: [], parameters: statement.bindings,
                    resultFormats: [1]
                )
            )
            // Still required per statement — a portal describes only when asked,
            // and without it the rows arrive with no column metadata at all.
            messages.append(.describe(.portal, name: ""))
            messages.append(.execute(portal: "", maxRows: 0))
        }

        // **One** Sync, at the very end. A Sync per statement would work and would
        // also defeat the purpose: Sync is the synchronisation point, so N of them
        // is N round trips again.
        messages.append(.sync)
        return .send(messages)
    }

    public mutating func handle(_ message: PostgresBackendMessage) -> Action {
        switch message {
        case .notice, .parameterStatus, .backendKeyData, .notification:
            return .wait
        default:
            break
        }

        // Once something has failed, everything up to `ReadyForQuery` is the
        // server draining. Reading it as results would attribute one statement's
        // output to another.
        if failure != nil {
            if case .readyForQuery = message { return finish() }
            return .wait
        }

        switch message {
        case .error(let error):
            failure = error
            failureIndex = current
            return .wait

        case .parseComplete, .bindComplete, .noData, .closeComplete:
            return .wait

        case .rowDescription(let columns):
            guard current < results.count else { return .wait }
            results[current].columns = columns
            columnFormats = columns.map(\.format)
            return .wait

        case .dataRow(let values):
            guard current < results.count else { return .wait }
            let columns = results[current].columns
            results[current].rows.append(
                values.enumerated().map { index, bytes in
                    let oid = index < columns.count ? columns[index].dataTypeOID : 0
                    let format = index < columnFormats.count ? columnFormats[index] : 0
                    return PostgresValueDecoder.decode(bytes, oid: oid, format: format)
                }
            )
            return .wait

        case .commandComplete(let tag):
            guard current < results.count else { return .wait }
            results[current].commandTag = tag
            results[current].affectedRows = PostgresCommandTag.affectedRows(tag)
            // The boundary between statements. Each one's replies end with its own
            // CommandComplete, which is the only thing separating them — there is
            // no per-statement marker beyond it.
            current += 1
            columnFormats = []
            return .wait

        case .emptyQueryResponse:
            if current < results.count { results[current].commandTag = "" }
            current += 1
            return .wait

        case .readyForQuery:
            return finish()

        default:
            return .wait
        }
    }

    mutating func finish() -> Action {
        isDone = true
        guard let failure else { return .succeeded(results) }
        return .failed(
            PostgresPipelineError(
                statementIndex: failureIndex,
                sql: failureIndex < statements.count ? statements[failureIndex].sql : "",
                underlying: .server(failure),
                // Only the ones that actually completed — the failing statement
                // and everything after it produced nothing.
                completed: Array(results.prefix(failureIndex))
            )
        )
    }
}

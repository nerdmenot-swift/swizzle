import NIOCore
import NIOPosix
import NIOSSL

/// A single authenticated MySQL/MariaDB connection.
///
/// Phase 1 scope: connect, authenticate, close. Commands arrive in Phase 2.
public final class MySQLConnection: Sendable {
    public let channel: any Channel
    public let metadata: MySQLConnectionMetadata
    /// Kept so batching commands (bulk execute) can size a request without
    /// asking the caller to repeat the limit.
    public let maxAllowedPacket: Int

    /// Statement cache, only ever touched on the connection's event loop —
    /// which is what lets it be mutable state on a `Sendable` type without a
    /// lock.
    private let cacheBox: CacheBox

    final class CacheBox: @unchecked Sendable {
        var cache: MySQLStatementCache
        init(capacity: Int) { self.cache = MySQLStatementCache(capacity: capacity) }
    }

    /// Identifier assigned by the connection pool, if this connection is pooled.
    ///
    /// Written once by the pool's factory before the connection is handed to
    /// anyone, so it needs no synchronisation beyond the box.
    private let poolIDBox = PoolIDBox()

    final class PoolIDBox: @unchecked Sendable {
        var value: Int?
    }

    var poolID: Int { poolIDBox.value ?? Int(metadata.connectionID) }

    func assignPoolID(_ id: Int) { poolIDBox.value = id }

    /// Server-reported session state, refreshed from every command's terminator.
    ///
    /// Authoritative for "am I in a transaction": MySQL commits implicitly on
    /// DDL, so any locally-tracked flag would silently drift.
    public let sessionState: MySQLSessionState

    /// The zone this session's `TIMESTAMP` values are expressed in.
    ///
    /// Carried on the connection rather than left in the configuration because
    /// it is what makes a `TIMESTAMP` interpretable — a caller holding a row
    /// needs it to call ``MySQLDateTime/date(in:)`` and has no other way to know
    /// which zone the server rendered the value into.
    public let sessionTimeZone: MySQLSessionTimeZone

    init(
        channel: any Channel,
        metadata: MySQLConnectionMetadata,
        sessionState: MySQLSessionState = MySQLSessionState(),
        statementCacheCapacity: Int = MySQLStatementCache.defaultCapacity,
        maxAllowedPacket: Int = MySQLPacketDecoder.defaultMaxAllowedPacket,
        sessionTimeZone: MySQLSessionTimeZone = .server
    ) {
        self.sessionTimeZone = sessionTimeZone
        self.channel = channel
        self.metadata = metadata
        self.sessionState = sessionState
        self.cacheBox = CacheBox(capacity: statementCacheCapacity)
        self.maxAllowedPacket = maxAllowedPacket
    }

    public var isActive: Bool { channel.isActive }

    /// Opens a connection and completes the handshake.
    ///
    /// The returned connection is authenticated; a failure here means the
    /// channel is already closed.
    public static func connect(
        configuration: MySQLConnectionConfiguration,
        on eventLoop: any EventLoop
    ) async throws -> MySQLConnection {
        let readyPromise = eventLoop.makePromise(of: MySQLConnectionMetadata.self)
        let sessionState = MySQLSessionState()
        let compressionState = MySQLCompressionState()

        let bootstrap = ClientBootstrap(group: eventLoop)
            .connectTimeout(configuration.connectTimeout)
            // autoRead stays on for the handshake and is turned off the moment
            // authentication succeeds — see the note in MySQLChannelHandler.
            .channelInitializer { channel in
                do {
                    // Order is load-bearing. Inbound runs top to bottom, outbound
                    // bottom to top, so the compression frame codec must come
                    // before the packet codec in both directions: a plain packet
                    // may span compressed frames, so framing has to happen on
                    // decompressed bytes. Both stay pass-through until
                    // authentication completes.
                    //
                    // TLS is spliced in at the head later, which puts it outside
                    // compression — encrypting compressed bytes, which is the
                    // required order.
                    try channel.pipeline.syncOperations.addHandlers([
                        ByteToMessageHandler(
                            MySQLCompressedFrameDecoder(
                                state: compressionState,
                                maxAllowedPacket: configuration.maxAllowedPacket
                            )
                        ),
                        MySQLCompressedFrameEncoder(state: compressionState),
                        ByteToMessageHandler(
                            MySQLPacketDecoder(maxAllowedPacket: configuration.maxAllowedPacket)
                        ),
                        MessageToByteHandler(MySQLPacketEncoder()),
                        MySQLChannelHandler(
                            configuration: configuration,
                            sessionState: sessionState,
                            compressionState: compressionState,
                            readyPromise: readyPromise
                        ),
                    ])
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        let channel: any Channel
        do {
            switch configuration.address {
            case .hostname(let host, let port):
                channel = try await bootstrap.connect(host: host, port: port).get()
            case .unixDomainSocket(let path):
                channel = try await bootstrap.connect(unixDomainSocketPath: path).get()
            }
        } catch {
            // Nothing will ever fulfil the promise if the connect itself failed.
            readyPromise.fail(error)
            throw error
        }

        do {
            let metadata = try await readyPromise.futureResult.get()
            let connection = MySQLConnection(
                channel: channel,
                metadata: metadata,
                sessionState: sessionState,
                statementCacheCapacity: configuration.statementCacheCapacity,
                maxAllowedPacket: configuration.maxAllowedPacket,
                sessionTimeZone: configuration.timeZone
            )

            // Session setup runs before the connection is handed to anyone, and
            // a failure here closes it: a half-configured connection is worse
            // than none, because the misconfiguration surfaces later as wrong
            // results rather than as a connect error.
            // The time zone goes first: a setup statement may well depend on
            // it, and a `TIMESTAMP` read by one would otherwise be in the
            // server's zone rather than the configured one.
            var setup = configuration.setupStatements
            if let timeZoneStatement = try configuration.timeZone.setupStatement() {
                setup.insert(timeZoneStatement, at: 0)
            }

            for statement in setup {
                do {
                    _ = try await connection.query(statement)
                } catch {
                    connection.closeImmediately()
                    throw error
                }
            }
            return connection
        } catch {
            try? await channel.close().get()
            throw error
        }
    }

    /// Says `COM_QUIT`, then closes.
    ///
    /// ## Why the goodbye is not a nicety
    ///
    /// `COM_QUIT` is the protocol's clean disconnect and the server answers it by
    /// closing its side. Without it the server sees the socket vanish, and on a
    /// **TLS** connection that costs five seconds every single time: NIOSSL's
    /// graceful shutdown sends `close_notify` and waits for the peer's reply,
    /// which a server that was never told the session is over does not send. The
    /// timeout is five seconds, measured — a TLS close took 5.0012s and a
    /// plaintext one 0.0001s.
    ///
    /// So every closed TLS connection held a socket, a server-side session and a
    /// pool slot for five seconds after it was finished with. It looked like a
    /// hang, and it was really just nobody saying goodbye.
    ///
    /// The command gets no reply — the server closes rather than answering — so it
    /// is written and flushed rather than sent through the command path, which
    /// would wait for a response that is never coming.
    /// ## Why the server closing is not a failure
    ///
    /// `COM_QUIT` is answered *by closing the socket* — the comment above says so,
    /// and then this method used to treat it as an error anyway. `channel.close()`
    /// raced the server's own close: whoever got there first decided whether the
    /// call succeeded or threw `ChannelError.alreadyClosed`, or on a TLS
    /// connection `NIOSSLError.uncleanShutdown`, which is what NIOSSL reports when
    /// a peer drops TCP without `close_notify` — exactly what a server that has
    /// hung up on request does.
    ///
    /// macOS won the race and Linux lost it, so this read as a platform bug for
    /// months. It is not: it is a race that Linux happens to lose, on kqueue
    /// versus epoll delivery order, and it fails in **0.0001 s** — nothing to do
    /// with the five-second `close_notify` wait the rest of this comment is about.
    /// Measured with the two errors alternating run to run on the same machine,
    /// with TLS *and* without it, which is what a race looks like and what a
    /// platform difference does not.
    ///
    /// So both are the expected outcome of a delivered goodbye. Anything else
    /// still throws.
    public func close() async throws {
        guard channel.isActive else { return }
        await sayGoodbye()
        do {
            try await channel.close()
        } catch let error as ChannelError where error == .alreadyClosed {
            // The server hung up first, which is what we asked it to do.
        } catch NIOSSLError.uncleanShutdown {
            // Ditto, over TLS: no `close_notify` from a peer that has gone.
        }
    }

    /// Writes `COM_QUIT` and waits only for the write, never for a reply.
    ///
    /// `fireAndForget` is the honest kind for it: the server answers `COM_QUIT`
    /// by closing the socket, so a command that waited for a response would wait
    /// forever.
    func sayGoodbye() async {
        // Failure here is not worth reporting. The connection is going away, and
        // a goodbye that could not be delivered changes nothing about that — a
        // server that already hung up is exactly the case this cannot help.
        _ = try? await send(.mysqlCommand(.quit), kind: .fireAndForget)
    }

    // MARK: - Commands

    /// Runs a query and returns its **first** result set.
    ///
    /// Any further result sets are still drained, so the connection is left
    /// clean — a stored procedure always trails at least one status set, and
    /// leaving it unread would desynchronise the next command. Use
    /// ``queryAll(_:)`` when you need them.
    ///
    /// **Task cancellation does not abort this.** MySQL has no message to cancel
    /// a running command, and the reply must be read to completion or the next
    /// command would read this one's packets. Returning early on cancellation
    /// would therefore hand back a connection that is still busy. Cancelling a
    /// task waiting here is safe — the connection stays usable — but the command
    /// runs to completion. To bound a slow query, use MySQL's own
    /// `max_execution_time`/`max_statement_time`, or `KILL QUERY` from a second
    /// connection. ``stream(_:)`` *does* honour cancellation, because there the
    /// consumer controls the pace.
    @discardableResult
    public func query(_ sql: String) async throws -> MySQLQueryResult {
        let results = try await queryAll(sql)
        guard let first = results.first else {
            throw MySQLProtocolError.malformedPacket("query produced no result")
        }
        return first
    }

    /// Runs a query and returns every result set it produced.
    public func queryAll(_ sql: String) async throws -> [MySQLQueryResult] {
        try await send(.mysqlCommand(.query, argument: sql))
    }

    /// Round-trips the server. Also the pool's keep-alive probe.
    public func ping() async throws {
        _ = try await send(.mysqlCommand(.ping))
    }

    /// `USE <database>`.
    public func useDatabase(_ name: String) async throws {
        _ = try await send(.mysqlCommand(.initDB, argument: name))
    }

    /// Resets session state — temp tables, session variables, user variables.
    ///
    /// This is what keeps a pooled connection from leaking state between
    /// unrelated users of the pool.
    ///
    /// It also deallocates **every prepared statement** server-side, so the
    /// statement cache must be dropped with it. Keeping it would hand out
    /// statement ids the server has already forgotten, and the failure
    /// (`Unknown prepared statement handler`) would surface on a later,
    /// unrelated query.
    public func resetConnection() async throws {
        _ = try await send(.mysqlCommand(.resetConnection))
        _ = try await withCache { $0.removeAll() }
    }

    func send(_ payload: ByteBuffer) async throws -> [MySQLQueryResult] {
        let response = try await send(payload, kind: .resultSet(.text))
        guard case .results(let results) = response else {
            throw MySQLProtocolError.unexpectedPacket("expected a result set")
        }
        return results
    }

    func send(_ payload: ByteBuffer, kind: MySQLCommandKind) async throws -> MySQLCommandResponse {
        // Cheap and racy, and worth having anyway: it turns the common case —
        // using a connection that is already known to be dead — into an
        // immediate, well-named error instead of a trip through the pipeline.
        guard channel.isActive else {
            throw MySQLProtocolError.connectionClosed("the connection is closed")
        }

        let promise = channel.eventLoop.makePromise(of: MySQLCommandResponse.self)
        let request = MySQLCommandRequest(payload: payload, kind: kind, promise: promise)

        // `write` (not writeAndFlush) — the command handler flushes once it has
        // taken ownership of the request.
        //
        // **The write needs a promise.** With `promise: nil` a failed write is
        // discarded silently: the request never reaches the handler, so nothing
        // ever fulfils the command promise, and the `await` below waits forever.
        // A connection that died between the check above and this line — or one
        // whose pipeline rejects the write for any other reason — hung the caller
        // rather than failing it.
        //
        // The two outcomes are mutually exclusive, so there is no double-fulfil:
        // if the write succeeds the handler owns the request and this closure
        // never runs; if it fails the handler never saw it.
        let written = channel.eventLoop.makePromise(of: Void.self)
        channel.write(request, promise: written)
        written.futureResult.whenFailure { promise.fail($0) }

        return try await promise.futureResult.get()
    }

    // MARK: - Streaming

    /// Streams a query's rows under backpressure.
    ///
    /// Returns as soon as the column metadata arrives; rows are read from the
    /// socket only as they are consumed, so a result set larger than memory
    /// streams in bounded space.
    ///
    /// The connection is busy for the lifetime of the sequence — MySQL has no
    /// pipelining, so no other command can run until it is exhausted or
    /// abandoned. Abandoning it (a `break`, a thrown error, task cancellation)
    /// is safe: the remaining rows are drained in the background, because MySQL
    /// offers no way to abort a result set mid-flight and leaving them queued
    /// would corrupt the next command.
    public func stream(_ sql: String) async throws -> MySQLRowSequence {
        let response = try await send(
            .mysqlCommand(.query, argument: sql), kind: .stream(.text)
        )
        guard case .streaming(let sequence) = response else {
            throw MySQLProtocolError.unexpectedPacket("expected a row stream")
        }
        return sequence
    }

    /// Streams a prepared statement's rows. Values arrive in the binary protocol.
    public func stream(
        _ sql: String, _ parameters: [MySQLValue]
    ) async throws -> MySQLRowSequence {
        let statement = try await prepare(sql)
        guard parameters.count == statement.parameterCount else {
            throw MySQLProtocolError.unexpectedPacket(
                "statement expects \(statement.parameterCount) parameters, got \(parameters.count)"
            )
        }
        // With caching on, the cache owns the statement. With it off, nothing
        // does — and a stream cannot close it on the way out, because the rows
        // have not been read yet.
        let isCached = try await withCache { $0.contains(id: statement.id) }

        let (buffer, _) = MySQLStatementCommands.execute(
            statementID: statement.id, parameters: parameters
        )
        do {
            let response = try await send(buffer, kind: .stream(.binary))
            guard case .streaming(let sequence) = response else {
                throw MySQLProtocolError.unexpectedPacket("expected a row stream")
            }
            // Queued while the connection is busy streaming, so it goes out the
            // moment the stream ends — however it ends.
            if !isCached { try? await scheduleStatementClose(statement) }
            return sequence
        } catch {
            if !isCached { try? await scheduleStatementClose(statement) }
            throw error
        }
    }

    /// Streams rows through a **server-side cursor**.
    ///
    /// The other `stream` methods rely on TCP backpressure: the server sends the
    /// whole result set and we read it at our own pace. This instead asks the
    /// server to hold the result and hand it over `prefetch` rows at a time via
    /// `COM_STMT_FETCH`, so nothing is in flight that has not been asked for.
    ///
    /// That is genuinely row-bounded, but it is **not a strict upgrade**: MySQL
    /// frequently materialises the result into a temporary table to hold the
    /// cursor open, trading memory on the server for memory on the client.
    /// Prefer the socket-backpressure path unless a result set is large enough
    /// that the difference matters.
    ///
    /// Requires a prepared statement — cursors do not exist for `COM_QUERY`.
    public func streamWithCursor(
        _ sql: String,
        _ parameters: [MySQLValue] = [],
        prefetch: Int = 256
    ) async throws -> MySQLRowSequence {
        precondition(prefetch > 0)
        let statement = try await prepare(sql)
        guard parameters.count == statement.parameterCount else {
            throw MySQLProtocolError.unexpectedPacket(
                "statement expects \(statement.parameterCount) parameters, got \(parameters.count)"
            )
        }

        let isCached = try await withCache { $0.contains(id: statement.id) }

        // Opening a cursor returns the column definitions and no rows.
        let (executeBuffer, _) = MySQLStatementCommands.execute(
            statementID: statement.id, parameters: parameters, cursor: .readOnly
        )
        let response = try await send(executeBuffer, kind: .resultSet(.binary))
        guard case .results(let results) = response, let opening = results.first else {
            throw MySQLProtocolError.unexpectedPacket("cursor execute produced no result")
        }

        let columns = opening.columns.isEmpty ? statement.columns : opening.columns

        // Some servers answer a cursor-less statement without CURSOR_EXISTS, in
        // which case the rows already arrived and there is nothing to fetch.
        let connection = self
        guard opening.statusFlags.contains(.cursorExists) else {
            // No cursor was opened, so the rows already arrived and the
            // statement is finished with right now.
            if !isCached { try? await scheduleStatementClose(statement) }
            let buffered = BufferedRows(opening.rows)
            return MySQLRowSequence(columns: columns) { buffered.next() }
        }

        // Queued in the handler, so it waits for the connection rather than
        // racing it — `deinit` cannot await, and a bare detached close would be
        // rejected whenever the connection happened to be busy.
        var onRelease: (@Sendable () -> Void)?
        if !isCached {
            onRelease = { Task { try? await connection.scheduleStatementClose(statement) } }
        }

        let state = CursorState(
            statement: statement, columns: columns, prefetch: prefetch, onRelease: onRelease
        )
        return MySQLRowSequence(columns: columns) {
            try await state.next(on: connection)
        }
    }

    /// Holds rows the server already sent when it declined to open a cursor.
    final class BufferedRows: @unchecked Sendable {
        private var rows: [MySQLRow]
        private var index = 0
        init(_ rows: [MySQLRow]) { self.rows = rows }
        func next() -> MySQLRow? {
            guard index < rows.count else { return nil }
            defer { index += 1 }
            return rows[index]
        }
    }

    /// Pull-based cursor buffer: refills with a `COM_STMT_FETCH` only when the
    /// consumer has drained the previous batch.
    final class CursorState: @unchecked Sendable {
        private let statement: MySQLPreparedStatement
        private let columns: [MySQLColumnDefinition]
        private let prefetch: Int
        private var buffer: [MySQLRow] = []
        private var index = 0
        private var exhausted = false

        /// Runs when the cursor is released — drained to the end, abandoned
        /// mid-way, or dropped without a single read.
        ///
        /// `deinit` rather than an exhaustion check, because exhaustion is only
        /// one of the three ways a cursor ends and the other two are invisible
        /// from inside `next`. Unlike the socket-backed stream, the connection
        /// falls idle between fetches, so the close cannot simply be queued up
        /// front — it would fire between two `COM_STMT_FETCH`es and close the
        /// statement out from under the cursor.
        private let onRelease: (@Sendable () -> Void)?

        init(
            statement: MySQLPreparedStatement,
            columns: [MySQLColumnDefinition],
            prefetch: Int,
            onRelease: (@Sendable () -> Void)? = nil
        ) {
            self.statement = statement
            self.columns = columns
            self.prefetch = prefetch
            self.onRelease = onRelease
        }

        deinit { onRelease?() }

        func next(on connection: MySQLConnection) async throws -> MySQLRow? {
            if index < buffer.count {
                defer { index += 1 }
                return buffer[index]
            }
            guard !exhausted else { return nil }

            let response = try await connection.send(
                MySQLStatementCommands.fetch(
                    statementID: statement.id, rows: UInt32(prefetch)
                ),
                kind: .cursorFetch(columns: columns)
            )
            guard case .results(let results) = response, let batch = results.first else {
                exhausted = true
                return nil
            }

            // `lastRowSent` marks the final batch; without it the loop would
            // keep fetching empty batches forever.
            if batch.statusFlags.contains(.lastRowSent) { exhausted = true }
            buffer = batch.rows
            index = 0

            guard !buffer.isEmpty else {
                exhausted = true
                return nil
            }
            defer { index += 1 }
            return buffer[0]
        }
    }

    // MARK: - Prepared statements

    /// Prepares a statement, reusing a cached one when the query text matches.
    ///
    /// Caching here is the whole point of writing our own driver: MySQLNIO
    /// closes every statement as soon as its result set finishes, so it pays
    /// PREPARE/EXECUTE/CLOSE — three round trips — on every single query.
    public func prepare(_ query: String) async throws -> MySQLPreparedStatement {
        if let cached = try await withCache({ $0.statement(for: query) }) {
            return cached
        }

        let response = try await send(
            MySQLStatementCommands.prepare(query), kind: .prepare(query: query)
        )
        guard case .prepared(let statement) = response else {
            throw MySQLProtocolError.unexpectedPacket("expected a prepared statement")
        }

        // An evicted statement is still allocated on the server, so it has to be
        // closed rather than dropped.
        if let evicted = try await withCache({ $0.insert(statement) }) {
            try? await scheduleStatementClose(evicted)
        }
        return statement
    }

    /// Executes a prepared statement. Rows come back in the binary protocol.
    @discardableResult
    public func execute(
        _ statement: MySQLPreparedStatement,
        _ parameters: [MySQLValue] = []
    ) async throws -> MySQLQueryResult {
        guard parameters.count == statement.parameterCount else {
            throw MySQLProtocolError.unexpectedPacket(
                "statement expects \(statement.parameterCount) parameters, got \(parameters.count)"
            )
        }

        let (buffer, requiresLongData) = MySQLStatementCommands.execute(
            statementID: statement.id, parameters: parameters
        )

        if requiresLongData {
            // Ship byte parameters separately, then re-encode without them.
            for (index, parameter) in parameters.enumerated() {
                guard case .bytes(let bytes) = parameter else { continue }
                try await sendLongData(statement: statement, index: UInt16(index), bytes: bytes)
            }
            let (trimmed, _) = MySQLStatementCommands.execute(
                statementID: statement.id, parameters: parameters, omittingByteValues: true
            )
            return try await executeRequest(trimmed)
        }

        return try await executeRequest(buffer)
    }

    /// Whether this connection can use `COM_STMT_BULK_EXECUTE`.
    ///
    /// MariaDB 10.2+ only, and only when the capability was negotiated. MySQL
    /// has no equivalent, so callers wanting portable code need a fallback.
    public var supportsBulkExecute: Bool {
        metadata.isMariaDB
            && metadata.mariaDBCapabilities.contains(.mariaDBStmtBulkOperations)
    }

    /// Executes one prepared statement against many parameter sets in a single
    /// round trip.
    ///
    /// The point is latency: an insert loop that costs one round trip per row
    /// becomes one round trip per batch. Rows are split automatically so no
    /// request exceeds `max_allowed_packet`, which means a large array is safe
    /// to pass directly.
    ///
    /// Every row must have the same arity, and a parameter that is NULL in some
    /// rows and typed in others takes the concrete type for the whole batch —
    /// the server is told one type per parameter, not per row.
    ///
    /// - Returns: one result per batch actually sent.
    @discardableResult
    public func executeBulk(
        _ statement: MySQLPreparedStatement,
        rows: [[MySQLValue]]
    ) async throws -> [MySQLQueryResult] {
        guard supportsBulkExecute else {
            throw MySQLProtocolError.unexpectedPacket(
                "COM_STMT_BULK_EXECUTE needs MariaDB with MARIADB_CLIENT_STMT_BULK_OPERATIONS"
            )
        }
        guard !rows.isEmpty else { return [] }

        for row in rows where row.count != statement.parameterCount {
            throw MySQLBulkExecuteRequest.BulkError.mixedArity(
                expected: statement.parameterCount, found: row.count
            )
        }

        var results: [MySQLQueryResult] = []
        for batch in MySQLBulkExecuteRequest.batches(
            rows: rows, maxAllowedPacket: maxAllowedPacket
        ) {
            var payload = ByteBuffer()
            try MySQLBulkExecuteRequest(statementID: statement.id, rows: batch)
                .serialize(into: &payload)
            results.append(try await executeRequest(payload))
        }
        return results
    }

    /// Prepares (via the cache) and bulk-executes in one call.
    @discardableResult
    public func queryBulk(
        _ sql: String,
        rows: [[MySQLValue]]
    ) async throws -> [MySQLQueryResult] {
        let statement = try await prepare(sql)
        let isCached = try await withCache { $0.contains(id: statement.id) }
        defer {
            if !isCached {
                let connection = self
                Task { try? await connection.scheduleStatementClose(statement) }
            }
        }
        return try await executeBulk(statement, rows: rows)
    }

    /// Prepares (via the cache) and executes in one call.
    ///
    /// When caching is disabled the statement is nobody's to keep, so it is
    /// closed after use — otherwise every call would leak a statement on the
    /// server until the connection died.
    @discardableResult
    public func query(_ sql: String, _ parameters: [MySQLValue]) async throws -> MySQLQueryResult {
        let statement = try await prepare(sql)
        let isCached = try await withCache { $0.contains(id: statement.id) }
        defer {
            if !isCached {
                let connection = self
                Task { try? await connection.scheduleStatementClose(statement) }
            }
        }
        return try await execute(statement, parameters)
    }

    /// Closes a statement once the connection is free, without waiting for it.
    ///
    /// The lifetime problem this solves: `prepare` allocates a statement **on
    /// the server**, and something has to close it. Normally the cache owns
    /// that. With caching disabled nothing does, so each call site must.
    ///
    /// Doing it with `Task { try? await closeStatement(...) }` looks equivalent
    /// and is not. MySQL connections are strictly serial, so the detached task
    /// races the next command and whichever loses is rejected — with the `try?`
    /// swallowing the error. Measured: 50 uncached queries left 24 statements
    /// allocated on the server forever. `max_prepared_stmt_count` is global and
    /// defaults to 16382, so that leak eventually breaks *every* client of the
    /// server, not just this connection.
    ///
    /// Queuing it in the handler instead means it goes out the moment the
    /// connection falls idle — which for a stream is exactly when the stream
    /// ends, the one moment the caller cannot observe.
    func scheduleStatementClose(_ statement: MySQLPreparedStatement) async throws {
        _ = try await withCache { $0.remove(id: statement.id) }
        _ = try await send(
            MySQLStatementCommands.close(statementID: statement.id), kind: .deferredClose
        )
    }

    /// Closes a statement on the server and drops it from the cache.
    public func closeStatement(_ statement: MySQLPreparedStatement) async throws {
        _ = try await withCache { $0.remove(id: statement.id) }
        _ = try await send(
            MySQLStatementCommands.close(statementID: statement.id), kind: .fireAndForget
        )
    }

    public var cachedStatementCount: Int {
        get async throws { try await withCache { $0.count } }
    }

    /// Resets a statement's state without deallocating it — clears any open
    /// cursor and any parameters staged with `COM_STMT_SEND_LONG_DATA`.
    ///
    /// Needed before reusing a cached statement whose previous execution left a
    /// cursor open, since the server refuses to re-execute one that is still
    /// mid-fetch.
    public func resetStatement(_ statement: MySQLPreparedStatement) async throws {
        _ = try await send(
            MySQLStatementCommands.reset(statementID: statement.id),
            kind: .resultSet(.text)
        )
    }

    // MARK: - Session options

    /// Whether the server should accept several statements in one `COM_QUERY`.
    ///
    /// Off by default, and worth leaving off: multi-statement support turns a
    /// single injected `;` into an arbitrary second statement, which is the
    /// difference between a leaked row and a dropped table.
    public func setMultiStatements(_ enabled: Bool) async throws {
        var buffer = ByteBuffer()
        buffer.writeInteger(MySQLCommand.setOption.rawValue, endianness: .little)
        // 0 = MYSQL_OPTION_MULTI_STATEMENTS_ON, 1 = OFF
        buffer.writeInteger(UInt16(enabled ? 0 : 1), endianness: .little)
        _ = try await send(buffer, kind: .resultSet(.text))
    }

    /// Re-authenticates the connection as a different user.
    ///
    /// A heavier reset than ``resetConnection()``: it re-runs authentication and
    /// resets session state, so it also invalidates every prepared statement.
    ///
    /// Only usable when the target account authenticates with a plugin we can
    /// answer from the initial scramble. An account requiring an auth switch
    /// would need the full handshake state machine, which this deliberately does
    /// not re-enter.
    public func changeUser(
        username: String, password: String, database: String? = nil
    ) async throws {
        var buffer = ByteBuffer()
        buffer.writeInteger(MySQLCommand.changeUser.rawValue, endianness: .little)
        buffer.writeNullTerminatedString(username)

        let scramble = metadata.scramble
        let response: [UInt8]
        switch metadata.authPlugin {
        case .cachingSHA2Password:
            response = MySQLAuth.cachingSHA2Password(password: password, scramble: scramble)
        case .mysqlNativePassword:
            response = MySQLAuth.nativePassword(password: password, scramble: scramble)
        default:
            throw MySQLProtocolError.unsupportedAuthPlugin(
                "COM_CHANGE_USER is only supported for native and caching_sha2 accounts"
            )
        }

        // Same three encodings as the handshake response, chosen by the same
        // capability — not always a bare length byte.
        if metadata.capabilities.contains(.pluginAuthLenencClientData) {
            buffer.writeLengthEncodedInteger(UInt64(response.count))
            buffer.writeBytes(response)
        } else if metadata.capabilities.contains(.secureConnection) {
            buffer.writeInteger(UInt8(response.count), endianness: .little)
            buffer.writeBytes(response)
        } else {
            buffer.writeBytes(response)
            buffer.writeInteger(UInt8(0), endianness: .little)
        }

        buffer.writeNullTerminatedString(database ?? "")
        // Character set is 2 bytes here, not the 1 byte of the handshake response.
        buffer.writeInteger(UInt16(metadata.characterSet), endianness: .little)
        buffer.writeNullTerminatedString(metadata.authPlugin.name)

        // Having advertised CLIENT_CONNECT_ATTRS at handshake time, the server
        // expects the attribute block here too; omitting it leaves the packet
        // short of what it is parsing for.
        if metadata.capabilities.contains(.connectAttrs) {
            var attributes = ByteBuffer()
            for (key, value) in MySQLConnectionConfiguration.defaultAttributes {
                attributes.writeLengthEncodedString(key)
                attributes.writeLengthEncodedString(value)
            }
            buffer.writeLengthEncodedInteger(UInt64(attributes.readableBytes))
            buffer.writeBuffer(&attributes)
        }

        // The server usually answers with an AuthSwitchRequest carrying a fresh
        // scramble rather than an OK — the initial response above is only a
        // best guess, since the target account's plugin and salt are unknown
        // until the username has been read.
        _ = try await send(buffer, kind: .changeUser(password: password))
        // Re-authentication deallocates every prepared statement, exactly as
        // COM_RESET_CONNECTION does.
        _ = try await withCache { $0.removeAll() }
    }

    private func executeRequest(_ buffer: ByteBuffer) async throws -> MySQLQueryResult {
        let response = try await send(buffer, kind: .resultSet(.binary))
        guard case .results(let results) = response, let first = results.first else {
            throw MySQLProtocolError.unexpectedPacket("execute produced no result")
        }
        return first
    }

    /// Chunks an oversized parameter so each piece fits in one packet.
    private func sendLongData(
        statement: MySQLPreparedStatement, index: UInt16, bytes: [UInt8]
    ) async throws {
        // Leave room for the command header inside a single packet.
        let chunkSize = MySQLPacketFraming.maxPayloadSize - 16
        var offset = 0
        while offset < bytes.count {
            let end = Swift.min(offset + chunkSize, bytes.count)
            _ = try await send(
                MySQLStatementCommands.sendLongData(
                    statementID: statement.id,
                    parameterIndex: index,
                    chunk: Array(bytes[offset..<end])
                ),
                kind: .fireAndForget
            )
            offset = end
        }
    }

    private func withCache<T: Sendable>(
        _ body: @escaping @Sendable (inout MySQLStatementCache) -> T
    ) async throws -> T {
        let box = cacheBox
        return try await channel.eventLoop.submit { body(&box.cache) }.get()
    }
}

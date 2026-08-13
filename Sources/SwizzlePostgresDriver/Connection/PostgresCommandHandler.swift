import NIOCore

/// One thing a caller wants done, plus where the answer goes.
enum PostgresRequest {
    case query(PostgresQueryStateMachine.Mode, EventLoopPromise<PostgresQueryResult>)
    case describe(String, EventLoopPromise<PostgresStatementDescription>)
    /// Rows delivered as they arrive rather than collected. The promise resolves
    /// at `RowDescription` — before the first row — so a caller can see the
    /// columns and start iterating while the server is still producing.
    case stream(
        sql: String, bindings: [[UInt8]?], maxRows: Int32,
        EventLoopPromise<PostgresRowSequence>
    )
    /// A courtesy on the way out: it lets the server log a clean disconnect
    /// rather than a lost connection, which is the difference between a quiet
    /// log and one full of alarming entries after every deploy.
    case terminate(EventLoopPromise<Void>)

    /// `COPY … TO STDOUT`. Resolves at `CopyOutResponse`, before the data, so
    /// the caller can start consuming while the server is still producing.
    case copyOut(sql: String, EventLoopPromise<PostgresCopyOutSequence>)
    /// `COPY … FROM STDIN`. `started` resolves at `CopyInResponse`, which is the
    /// server saying it is ready to be fed; `finished` at `CommandComplete`.
    case copyIn(
        sql: String,
        started: EventLoopPromise<Void>,
        finished: EventLoopPromise<PostgresQueryResult>
    )
    /// A chunk of a copy already in progress. Deliberately *not* queued — the
    /// connection is in copy mode, so there is nothing to queue behind.
    case copyData([UInt8])
    case copyDone
    case copyFail(reason: String)

    /// Several statements with a single `Sync`.
    case pipeline([PostgresPipelineStatement], EventLoopPromise<[PostgresQueryResult]>)
    /// `Close` for a named statement or portal, driven rather than only encoded.
    case close(PostgresTargetKind, name: String, EventLoopPromise<Void>)
    /// Ends a pipeline session: a bare `Sync`, which commits the implicit
    /// transaction the Flush-terminated statements accumulated in.
    case pipelineSync(EventLoopPromise<Void>)
}

/// Runs statements, one at a time, and owns the read gate.
///
/// ## Where backpressure lives
///
/// The channel has `autoRead` off from the moment the handshake completes, so
/// **every read is asked for explicitly here**. For a collected query that is
/// uninteresting: keep reading until `ReadyForQuery`. For a stream it is the
/// whole point — the next read is issued only when the consumer has taken rows,
/// so a stalled consumer stops the socket, fills the receive buffer, and stalls
/// the server in its own write.
///
/// One statement at a time. Postgres allows pipelining several before a single
/// `Sync`, and that is a real optimisation, but it makes an error in the middle
/// of a batch everyone's problem — the server discards the rest, so every queued
/// statement has to be failed together. Serial first; pipelining is a separate
/// entry on the checklist rather than something to get subtly wrong here.
final class PostgresCommandHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = PostgresBackendMessage
    typealias OutboundIn = PostgresRequest
    typealias OutboundOut = PostgresFrontendMessage

    private struct Running {
        var machine: PostgresQueryStateMachine
        var request: PostgresRequest
        /// Set once the statement has been re-run after the server invalidated a
        /// cached plan. One retry only: a second failure is a real error, and
        /// retrying forever would turn it into a spin.
        var hasRetried: Bool = false
        /// Set once `RowDescription` has arrived on a streaming request.
        var stream: PostgresRowStream?
        var schema: PostgresRowSchema?
        /// Rows the consumer has not asked for yet are still delivered — the
        /// window is the socket, not this buffer — but they are batched per read
        /// so the producer is not woken once per row.
        var pending: [PostgresRow] = []
        /// Feeds a `COPY … TO STDOUT`, once the server has entered copy mode.
        var copyOut: AsyncThrowingStream<[UInt8], any Error>.Continuation?
        /// Set for a pipeline, which has its own machine: the result is several
        /// results rather than one, and the failure rule differs.
        var pipeline: PostgresPipelineStateMachine?
    }

    private var queue: [PostgresRequest] = []
    private var running: Running?
    private var context: ChannelHandlerContext?
    private var cache: PostgresStatementCache
    /// False while a stream's consumer is behind. The next read waits for it.
    private var wantsRead = true
    private var isClosed = false
    private let notifications = PostgresNotificationSink()
    /// What the server said about the transaction on the last `ReadyForQuery`.
    ///
    /// Tracked from the server's own report rather than inferred from the
    /// statements we sent, because the two disagree in exactly the case that
    /// matters: a failed statement moves the session to `failed` without anybody
    /// issuing anything, and a client-side flag would never know.
    private(set) var transactionStatus: PostgresTransactionStatus = .idle

    init(statementCacheCapacity: Int = PostgresStatementCache.defaultCapacity) {
        self.cache = PostgresStatementCache(capacity: statementCacheCapacity)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    // MARK: - Outbound

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let request = unwrapOutboundIn(data)
        guard !isClosed else {
            fail(request, PostgresConnectionError.unexpected(during: "a closed connection"))
            promise?.succeed(())
            return
        }
        // Copy traffic jumps the queue by definition: the connection is already
        // in copy mode, so these belong to the statement that is *running*, not
        // behind it. Queueing them would deadlock — the running copy is waiting
        // for exactly these bytes.
        switch request {
        case .copyData(let bytes):
            context.writeAndFlush(wrapOutboundOut(.copyData(bytes)), promise: promise)
            return
        case .copyDone:
            context.writeAndFlush(wrapOutboundOut(.copyDone), promise: promise)
            return
        case .copyFail(let reason):
            context.writeAndFlush(wrapOutboundOut(.copyFail(reason)), promise: promise)
            return
        default:
            break
        }

        // Terminate jumps the queue and expects no reply — the server closes the
        // socket. Queueing it behind a running statement would mean waiting for
        // a result nobody is going to read.
        if case .terminate(let done) = request {
            isClosed = true
            context.writeAndFlush(wrapOutboundOut(.terminate), promise: nil)
            done.succeed(())
            promise?.succeed(())
            return
        }

        queue.append(request)
        promise?.succeed(())
        startNextIfIdle(context: context)
    }

    private func startNextIfIdle(context: ChannelHandlerContext, hasRetried: Bool = false) {
        guard running == nil, !queue.isEmpty else { return }
        let request = queue.removeFirst()

        // Anything the cache evicted has to be closed on the server, or the
        // statement is leaked there until the connection dies.
        var closes: [PostgresFrontendMessage] = []

        // A pipeline runs on its own machine, so it short-circuits the whole
        // single-statement path below.
        if case .pipeline(let statements, _) = request {
            var machine = PostgresPipelineStateMachine(statements: statements)
            let action = machine.start()
            running = Running(
                machine: PostgresQueryStateMachine(mode: .simple("")),
                request: request, pipeline: machine
            )
            if case .send(let messages) = action {
                for message in messages { context.write(wrapOutboundOut(message), promise: nil) }
                context.flush()
            }
            wantsRead = true
            context.read()
            return
        }

        // `Close` needs no state machine either: one message, one reply, and the
        // `Sync` that follows is what makes `CloseComplete` arrive at all.
        if case .pipelineSync(_) = request {
            running = Running(
                machine: PostgresQueryStateMachine(mode: .simple("")), request: request
            )
            context.writeAndFlush(wrapOutboundOut(.sync), promise: nil)
            wantsRead = true
            context.read()
            return
        }

        if case .close(let kind, let name, _) = request {
            running = Running(
                machine: PostgresQueryStateMachine(mode: .simple("")), request: request
            )
            for message: PostgresFrontendMessage in [.close(kind, name: name), .sync] {
                context.write(wrapOutboundOut(message), promise: nil)
            }
            context.flush()
            wantsRead = true
            context.read()
            return
        }

        let mode: PostgresQueryStateMachine.Mode
        switch request {
        case .query(let requested, _):
            if case .extended(let sql, let bindings, let maxRows, _, let types) = requested {
                let (statement, evicted) = prepare(sql, parameterTypes: types)
                if let evicted { closes.append(.close(.statement, name: evicted)) }
                mode = .extended(
                    sql: sql, bindings: bindings, maxRows: maxRows, statement: statement,
                    parameterTypes: types
                )
            } else {
                mode = requested
            }
        case .describe(let sql, _):
            // Deliberately not cached. A describe is a generator's one-off
            // question about a statement's shape, and caching it would fill the
            // connection's statement table with things nobody will execute.
            mode = .describe(sql)
        case .stream(let sql, let bindings, let maxRows, _):
            let (statement, evicted) = prepare(sql, parameterTypes: [])
            if let evicted { closes.append(.close(.statement, name: evicted)) }
            mode = .extended(sql: sql, bindings: bindings, maxRows: maxRows, statement: statement)
        case .copyOut(let sql, _), .copyIn(let sql, _, _):
            // A copy is a plain `Query` — the sub-protocol starts when the server
            // answers with `CopyInResponse` or `CopyOutResponse`.
            mode = .simple(sql)
        case .terminate(let done):
            // Handled on the way in and never queued; this arm exists so adding a
            // request case later is a compile error rather than a silent hang.
            done.succeed(())
            return
        case .copyData, .copyDone, .copyFail:
            // Handled on the way in, never queued.
            return
        case .pipeline, .close, .pipelineSync:
            // All short-circuit above; this arm keeps a new request case a
            // compile error rather than a silent hang.
            return
        }

        var machine = PostgresQueryStateMachine(mode: mode)
        let action = machine.start()
        running = Running(machine: machine, request: request, hasRetried: hasRetried)
        if !closes.isEmpty { apply(.send(closes), context: context) }
        apply(action, context: context)

        // A statement is in flight, so there is something to read for.
        wantsRead = true
        context.read()
    }

    /// Picks the statement to bind, preparing a new one when the cache misses.
    /// The cache key is the SQL **and** the parameter type hints.
    ///
    /// Not the SQL alone. The hints are applied at `Parse`, and a cache hit skips
    /// the `Parse` entirely — so keying on SQL alone makes a hinted query silently
    /// reuse a statement parsed *without* the hints, and the hints do nothing.
    /// The same text really is two different prepared statements when the
    /// declared parameter types differ, and the server treats them that way.
    private func prepare(
        _ sql: String, parameterTypes: [UInt32]
    ) -> (PostgresPreparedStatementRef, evicted: String?) {
        guard cache.isEnabled else { return (.unnamed, nil) }
        let key = parameterTypes.isEmpty
            ? sql
            : sql + "\u{0}" + parameterTypes.map(String.init).joined(separator: ",")

        if let name = cache.name(for: key) {
            return (PostgresPreparedStatementRef(name: name, needsParse: false), nil)
        }
        let (name, evicted) = cache.insert(key)
        return (PostgresPreparedStatementRef(name: name, needsParse: true), evicted)
    }

    // MARK: - Inbound

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)

        // `NOTIFY` is the only message nobody asked for, and it arrives at any
        // message boundary — including boundaries *inside* a result set. So it is
        // handled before anything else, rather than only when the connection is
        // idle.
        if case .readyForQuery(let status) = message {
            transactionStatus = status
        }

        if case .notification(let processID, let channel, let payload) = message {
            notifications.deliver(
                PostgresNotification(processID: processID, channel: channel, payload: payload)
            )
            return
        }

        guard running != nil else {
            // Nothing asked for this. `NotificationResponse` and mid-session
            // `ParameterStatus` legitimately arrive on an idle connection; pass
            // them along rather than treating them as a protocol error.
            context.fireChannelRead(data)
            return
        }

        // ── Do not copy `running` here ───────────────────────────────────────
        //
        // This used to be `guard var state = running`, which copies the struct —
        // and with it a *second reference* to the growing rows array. Every
        // subsequent `append` then found the buffer shared and copied the whole
        // thing, making result collection **quadratic in the row count**.
        //
        // It was invisible until measured: 10k rows took 230 ms and 50k took
        // 4.7 s, which is 5× the rows for 20× the time. Nothing failed, and the
        // shape only shows up once results get big.
        //
        // Mutating through `running!` keeps the array uniquely referenced, so
        // `append` stays amortised O(1).
        let fastPathRow: Bool = {
            if case .dataRow = message, running!.schema != nil, running!.stream != nil {
                return true
            }
            return false
        }()

        // Rows are collected here and yielded once per read, so a thousand-row
        // batch wakes the consumer once instead of a thousand times.
        if fastPathRow {
            let schema = running!.schema!
            _ = running!.machine.handle(message)
            // `rows` is emptied on every pass, so a non-empty one means this
            // message produced a row — and an error, which leaves the machine
            // draining, produces none. That is what makes rows arriving after a
            // failure impossible to mistake for good ones.
            if let row = running!.machine.result.rows.last {
                running!.pending.append(PostgresRow(values: row, schema: schema))
                // The collected copy is dropped: a streamed result must not also
                // accumulate in memory, which would defeat the entire point.
                running!.machine.result.rows.removeAll(keepingCapacity: true)
            }
            return
        }

        // The collected-row path, and the one the quadratic copy was hiding in.
        if case .dataRow = message, running!.pipeline == nil, running!.copyOut == nil {
            _ = running!.machine.handle(message)
            return
        }

        // A pipeline drives its own machine end to end.
        if running!.pipeline != nil {
            let action = running!.pipeline!.handle(message)
            switch action {
            case .wait, .send:
                return
            case .succeeded(let results):
                let request = running!.request
                running = nil
                if case .pipeline(_, let promise) = request { promise.succeed(results) }
                startNextIfIdle(context: context)
                return
            case .failed(let error):
                let request = running!.request
                running = nil
                if case .pipeline(_, let promise) = request { promise.fail(error) }
                startNextIfIdle(context: context)
                return
            }
        }

        var state = running!

        // A pipeline `Sync` is done when its `ReadyForQuery` arrives.
        if case .pipelineSync(let promise) = state.request {
            if case .readyForQuery = message {
                running = nil
                promise.succeed(())
                startNextIfIdle(context: context)
            }
            return
        }

        // A `Close` is done when its `ReadyForQuery` arrives.
        if case .close(_, _, let promise) = state.request {
            switch message {
            case .error(let error):
                // Closing something that is not there is not fatal — the goal was
                // for it to be gone, and it is — but the failure is still
                // reported rather than swallowed.
                running?.machine.phase = .draining(error)
                return
            case .readyForQuery:
                running = nil
                if case .draining(let error) = state.machine.phase {
                    promise.fail(PostgresConnectionError.server(error))
                } else {
                    promise.succeed(())
                }
                startNextIfIdle(context: context)
                return
            default:
                return
            }
        }

        // ── The copy sub-protocol ────────────────────────────────────────────
        //
        // `CopyInResponse` / `CopyOutResponse` suspend the normal flow: until
        // the copy ends, one side speaks and the other listens. These are handled
        // ahead of the query state machine because the machine has no notion of a
        // mode where `DataRow` does not arrive.
        switch message {
        case .copyInResponse:
            if case .copyIn(_, let started, _) = state.request {
                started.succeed(())
            }
            return

        case .copyOutResponse:
            if case .copyOut(_, let promise) = state.request, state.copyOut == nil {
                let (stream, continuation) = AsyncThrowingStream.makeStream(
                    of: [UInt8].self, throwing: (any Error).self
                )
                state.copyOut = continuation
                running = state
                promise.succeed(PostgresCopyOutSequence(base: stream))
                return
            }
            return

        case .copyData(let bytes):
            state.copyOut?.yield(bytes)
            running = state
            return

        case .copyDone:
            // The data is over; `CommandComplete` still follows and ends the
            // statement, so the stream is finished here rather than there.
            state.copyOut?.finish()
            state.copyOut = nil
            running = state
            return

        default:
            break
        }

        let action = state.machine.handle(message)

        // `RowDescription` is where a streaming request becomes answerable: the
        // columns are known and the consumer can begin, with the rows still on
        // their way.
        if case .rowDescription(let columns) = message,
           case .stream(_, _, _, let promise) = state.request,
           state.stream == nil {
            let schema = PostgresRowSchema(columns)
            let stream = PostgresRowStream(
                schema: schema, eventLoop: context.eventLoop, dataSource: self
            )
            state.schema = schema
            state.stream = stream
            running = state
            promise.succeed(stream.makeSequence())
            return
        }

        running = state
        apply(action, context: context)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        flushPendingRows()

        // The read gate. `wantsRead` is false only when a stream's consumer is
        // behind, and in that case no read is issued — which is what stalls the
        // socket, and through it the server.
        if running != nil, wantsRead {
            context.read()
        } else if running == nil, notifications.hasListeners, !isClosed {
            // Nothing is running, but something is listening.
            //
            // With `autoRead` off, an idle connection reads nothing because
            // nothing asks — so a `LISTEN` would register successfully and then
            // deliver nothing at all. That is the worst kind of broken: it looks
            // like it works. A standing read only exists while there is a
            // listener, so a connection nobody is listening on stays fully
            // demand-driven.
            context.read()
        }
        context.fireChannelReadComplete()
    }

    /// Hands the batch to the consumer and records whether it wants more.
    private func flushPendingRows() {
        guard var state = running, let stream = state.stream, !state.pending.isEmpty else { return }
        let rows = state.pending
        state.pending.removeAll(keepingCapacity: true)
        running = state
        wantsRead = stream.yield(rows)
    }

    func channelInactive(context: ChannelHandlerContext) {
        isClosed = true
        // Listeners end rather than waiting forever on a socket that is gone.
        notifications.finish()
        failEverything(PostgresConnectionError.unexpected(during: "a connection that closed"))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        isClosed = true
        failEverything(error)
        context.close(promise: nil)
    }

    // MARK: - Completing a statement

    private func apply(
        _ action: PostgresQueryStateMachine.Action, context: ChannelHandlerContext
    ) {
        switch action {
        case .wait:
            break

        case .send(let messages):
            for message in messages {
                context.write(wrapOutboundOut(message), promise: nil)
            }
            context.flush()

        case .succeeded(let result):
            // Flushed *before* `running` is cleared, because that is where the
            // pending rows live. Clearing first drops the final batch — every row
            // that arrived since the last read-complete — and a result set that
            // ends one batch short is far harder to notice than one that fails.
            flushPendingRows()
            guard let state = running else { return }
            running = nil
            switch state.request {
            case .query(_, let promise):
                promise.succeed(result)
            case .stream(_, _, _, let promise):
                if let stream = state.stream {
                    // The stream already carried the rows; finishing it is what
                    // ends the caller's `for try await`.
                    stream.finish()
                } else {
                    // No `RowDescription` ever arrived, so the stream was never
                    // created and its promise is still outstanding. A statement
                    // that returns nothing — an `UPDATE`, or a `SELECT` the
                    // planner proved empty — reaches here, and leaving the
                    // promise unresolved would hang the caller forever rather
                    // than handing back an empty sequence.
                    promise.succeed(.empty(columns: result.columns))
                }
            case .describe(_, let promise):
                // A describe cannot land here — its mode reports `.described` —
                // but failing loudly beats resolving with something invented.
                promise.fail(PostgresConnectionError.unexpected(during: "describe"))
            case .terminate(let done):
                done.succeed(())
            case .copyOut(_, let promise):
                // The data stream is already finished; this ends the statement.
                // A copy that produced no `CopyOutResponse` at all still has an
                // outstanding promise, so it gets an empty sequence rather than
                // a caller waiting forever.
                state.copyOut?.finish()
                if state.copyOut == nil {
                    let (stream, continuation) = AsyncThrowingStream.makeStream(
                        of: [UInt8].self, throwing: (any Error).self
                    )
                    continuation.finish()
                    promise.succeed(PostgresCopyOutSequence(base: stream))
                }
            case .copyIn(_, let started, let finished):
                // `started` may still be outstanding if the statement was not a
                // `COPY … FROM STDIN` at all — the caller is waiting on it.
                started.succeed(())
                finished.succeed(result)
            case .copyData, .copyDone, .copyFail:
                break
            case .pipeline(_, let promise):
                // Driven by its own machine; unreachable here.
                promise.succeed([])
            case .close(_, _, let promise):
                promise.succeed(())
            case .pipelineSync(let promise):
                promise.succeed(())
            }
            startNextIfIdle(context: context)

        case .described(let description):
            guard let state = running else { return }
            running = nil
            if case .describe(_, let promise) = state.request {
                promise.succeed(description)
            }
            startNextIfIdle(context: context)

        case .failed(let error):
            guard let state = running else { return }
            running = nil

            // ── The trap that makes statement caching dangerous ───────────────
            //
            // Caching is free until somebody runs `ALTER TABLE`. The next
            // execution of a cached statement fails with `0A000` — *cached plan
            // must not change result type* — and then **fails again every time
            // after that**, because the cache keeps handing back the same stale
            // statement. A long-lived pooled connection stays broken until
            // something closes it, which in production means one deploy
            // poisoning a pool for hours.
            //
            // So: drop the cache and run it again, once. The server has already
            // discarded those statements itself, so there is nothing to `Close` —
            // trying to would fail on names that no longer exist.
            if case .server(let message) = error,
               message.indicatesStaleCachedPlan,
               !state.hasRetried,
               state.stream == nil {
                _ = cache.removeAll()
                queue.insert(state.request, at: 0)
                startNextIfIdle(context: context, hasRetried: true)
                return
            }

            fail(state.request, error, stream: state.stream, copyOut: state.copyOut)
            startNextIfIdle(context: context)
        }
    }

    private func fail(
        _ request: PostgresRequest, _ error: any Error, stream: PostgresRowStream? = nil,
        copyOut: AsyncThrowingStream<[UInt8], any Error>.Continuation? = nil
    ) {
        switch request {
        case .query(_, let promise):
            promise.fail(error)
        case .describe(_, let promise):
            promise.fail(error)
        case .stream(_, _, _, let promise):
            // If the sequence was already handed over, the error belongs on the
            // stream — the caller is iterating and will never look at the promise
            // again. Failing both would be a duplicate at best and a crash at
            // worst.
            if let stream {
                stream.finish(throwing: error)
            } else {
                promise.fail(error)
            }
        case .terminate(let done):
            done.succeed(())
        case .copyOut(_, let promise):
            // Same rule as a row stream: once the sequence is out there, the
            // error belongs on it and not on a promise nobody will read again.
            if let copyOut {
                copyOut.finish(throwing: error)
            } else {
                promise.fail(error)
            }
        case .copyIn(_, let started, let finished):
            // `started` first — a caller blocked waiting to be told the server is
            // ready must not wait for a copy that will never begin.
            started.fail(error)
            finished.fail(error)
        case .copyData, .copyDone, .copyFail:
            break
        case .pipeline(_, let promise):
            promise.fail(error)
        case .close(_, _, let promise):
            promise.fail(error)
        case .pipelineSync(let promise):
            promise.fail(error)
        }
    }

    private func failEverything(_ error: any Error) {
        if let state = running {
            running = nil
            fail(state.request, error, stream: state.stream, copyOut: state.copyOut)
        }
        let queued = queue
        queue.removeAll()
        for request in queued { fail(request, error) }
    }
}

extension PostgresCommandHandler {
    /// A stream of this connection's notifications.
    ///
    /// Creating one is also what makes the connection keep a read outstanding
    /// while idle — see `channelReadComplete`.
    func notificationStream() -> AsyncStream<PostgresNotification> {
        let stream = notifications.makeStream()
        // A listener that appears while the connection is idle would otherwise
        // wait for the *next* statement before any read was issued.
        if let context, running == nil, !isClosed {
            context.eventLoop.execute { context.read() }
        }
        return stream
    }

    /// Drops every cached statement name without sending `Close` for any of them.
    func forgetCache() {
        _ = cache.removeAll()
    }

    var cachedStatementCountForTesting: Int { cache.count }

    /// How many rows the running statement has accumulated in memory.
    ///
    /// Exists so a test can assert that a *streamed* result stays at zero. That
    /// is the property streaming is for, and it is otherwise invisible.
    var collectedRowCountForTesting: Int { running?.machine.result.rows.count ?? 0 }
}

extension PostgresCommandHandler: PostgresRowDataSource {
    /// The consumer drained enough to want more, so the socket is opened again.
    func requestMoreRows(for stream: PostgresRowStream) {
        guard let context, running?.stream === stream else { return }
        wantsRead = true
        context.read()
    }

    /// The consumer stopped early — a `break`, a thrown error, or task
    /// cancellation.
    ///
    /// The rest of the result still has to go somewhere. Draining is the polite
    /// answer and it is what MySQL does, but here the remaining rows may be
    /// unbounded and the server is blocked writing them, so the connection is
    /// closed instead. A connection is cheaper than an unbounded drain, and the
    /// pool will simply open another.
    func cancelStream(for stream: PostgresRowStream) {
        guard let context, running?.stream === stream else { return }
        running = nil
        isClosed = true
        context.close(promise: nil)
    }
}

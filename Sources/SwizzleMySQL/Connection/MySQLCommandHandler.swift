import Foundation
import NIOCore

/// One result set.
public struct MySQLQueryResult: Sendable {
    public var columns: [MySQLColumnDefinition]
    public var rows: [MySQLRow]
    public var affectedRows: UInt64
    public var lastInsertID: UInt64
    public var warningCount: UInt16
    public var info: String?
    /// Server status at the end of the result set.
    ///
    /// Carries `cursorExists` and `lastRowSent`, which is how cursor fetching
    /// knows when to stop.
    public var statusFlags: MySQLStatusFlags = []

    public var isEmpty: Bool { rows.isEmpty }

    /// Value by column name from a given row.
    public func value(_ columnName: String, row index: Int = 0) -> MySQLValue? {
        guard index < rows.count else { return nil }
        return rows[index][columnName]
    }
}

/// What kind of response a command produces.
enum MySQLCommandKind: Sendable {
    /// A buffered result set — text rows for `COM_QUERY`, binary for
    /// `COM_STMT_EXECUTE`.
    case resultSet(MySQLResultSetStateMachine.RowFormat)
    /// A streamed result set. The promise resolves as soon as the column
    /// definitions arrive; rows follow through the sequence under backpressure.
    case stream(MySQLResultSetStateMachine.RowFormat)
    /// A `COM_STMT_FETCH` reply: binary rows and a terminator, with the column
    /// definitions already known from the preceding `COM_STMT_EXECUTE`.
    case cursorFetch(columns: [MySQLColumnDefinition])
    /// `COM_STMT_PREPARE`, whose response has its own shape.
    case prepare(query: String)
    /// `COM_CHANGE_USER`, which re-runs authentication and therefore may be
    /// answered with an `AuthSwitchRequest` rather than an OK.
    case changeUser(password: String)
    /// Commands whose reply is a bare OK and which must not be awaited for
    /// rows — notably `COM_STMT_CLOSE`, which the server does not answer at all.
    case fireAndForget
    /// A `COM_STMT_CLOSE` that must happen *eventually* rather than now.
    ///
    /// Unlike every other kind this one is **queued instead of rejected** when a
    /// command is in flight. It has to be: a statement backing a live stream
    /// cannot be closed until the stream ends, and the caller has no way to
    /// observe when that is. Rejecting it would silently leak the statement on
    /// the server — which is exactly what used to happen.
    ///
    /// Safe to queue precisely because the server sends no reply to
    /// `COM_STMT_CLOSE`, so it occupies no response slot once written.
    case deferredClose
    /// `COM_BINLOG_DUMP`. Unlike every other kind this never completes: the
    /// server streams events until the connection is closed. The connection can
    /// never return to ordinary command use afterwards.
    case binlog
}

enum MySQLCommandResponse: Sendable {
    case results([MySQLQueryResult])
    case streaming(MySQLRowSequence)
    case prepared(MySQLPreparedStatement)
    case acknowledged
    case binlog(MySQLBinlogSequence)
}

struct MySQLCommandRequest {
    let payload: ByteBuffer
    let kind: MySQLCommandKind
    let promise: EventLoopPromise<MySQLCommandResponse>
}

/// Runs one command at a time and assembles its response.
///
/// MySQL has no pipelining — a connection may have exactly one command in
/// flight — so this holds a single pending activity rather than a queue, and
/// rejects overlapping commands outright rather than corrupting the stream.
///
/// Reads are demand-driven throughout: `autoRead` is off once authenticated. For
/// a buffered command that just means reading until the response completes; for
/// a stream it means reading only while the consumer is asking for rows.
final class MySQLCommandHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = MySQLPacket
    typealias OutboundIn = MySQLCommandRequest
    typealias OutboundOut = MySQLPacket

    private enum Decoder {
        case resultSet(MySQLResultSetStateMachine)
        case prepare(MySQLPrepareStateMachine)
    }

    // Buffering, Streaming and Binlog are **classes, not structs**, and that is
    // load-bearing rather than stylistic.
    //
    // As structs they were pulled out of the `activity` enum with
    // `case .buffering(let state)`, mutated, and put back. But `activity` still
    // held its own reference to the same row array, so every `append` saw a
    // refcount above one and triggered a full copy-on-write copy — making a
    // result set quadratic in its own size. Measured: doubling the rows
    // quadrupled the time (3.79x, 3.95x, 4.07x), and a 50k-row query that the
    // mysql CLI answers in 0.04s took 10.2s.
    //
    // Reference semantics remove the second reference entirely, so the arrays
    // are mutated in place.
    private final class Buffering {
        var promise: EventLoopPromise<MySQLCommandResponse>
        var decoder: Decoder
        var query: String
        var results: [MySQLQueryResult] = []
        var currentColumns: [MySQLColumnDefinition] = []
        var currentRows: [MySQLRow] = []

        init(
            promise: EventLoopPromise<MySQLCommandResponse>,
            decoder: Decoder,
            query: String
        ) {
            self.promise = promise
            self.decoder = decoder
            self.query = query
        }
    }

    private final class Streaming {
        /// Nil once the column definitions have arrived and it has been fulfilled.
        var promise: EventLoopPromise<MySQLCommandResponse>?
        var machine: MySQLResultSetStateMachine
        var stream: MySQLRowStream?
        /// Rows held since the last flush to the consumer.
        var pending: [MySQLRow] = []
        /// Whether the consumer currently wants more rows.
        var wantsMore = true
        /// Set when the consumer abandoned the sequence: keep reading to drain
        /// the result set, but discard everything.
        var isDraining = false

        init(
            promise: EventLoopPromise<MySQLCommandResponse>?,
            machine: MySQLResultSetStateMachine
        ) {
            self.promise = promise
            self.machine = machine
        }
    }

    /// `COM_CHANGE_USER` re-runs authentication mid-connection.
    ///
    /// The server almost always answers with an `AuthSwitchRequest` carrying a
    /// **fresh** scramble rather than an OK, because the target account's plugin
    /// and salt are only known once the username has been read. Answering with a
    /// response computed from the original handshake scramble fails as
    /// `Access denied ... (using password: NO)`, which reads like a credentials
    /// problem rather than a protocol one.
    private struct ChangingUser {
        var promise: EventLoopPromise<MySQLCommandResponse>
        var password: String
        var hasSwitched = false
    }

    private final class Binlog {
        var promise: EventLoopPromise<MySQLCommandResponse>?
        var producer: MySQLBinlogStreamProducer
        var decoder = MySQLBinlogEventDecoder()
        var pending: [MySQLBinlogEvent] = []
        var wantsMore = true

        init(
            promise: EventLoopPromise<MySQLCommandResponse>?,
            producer: MySQLBinlogStreamProducer
        ) {
            self.promise = promise
            self.producer = producer
        }
    }

    private enum Activity {
        case idle
        case buffering(Buffering)
        case streaming(Streaming)
        case changingUser(ChangingUser)
        case binlog(Binlog)
    }

    private let capabilities: MySQLCapabilities
    private let localInfile: MySQLConnectionConfiguration.LocalInfile
    private let onProgress: (@Sendable (MySQLProgressReport) -> Void)?

    /// A local failure during a `LOAD DATA LOCAL INFILE` transfer — refused by
    /// the allow-list, or unreadable.
    ///
    /// Held rather than thrown immediately because the protocol is mid-exchange:
    /// the server is waiting for file data and will send its own reply once the
    /// terminator arrives. Failing here and now would leave that reply unread
    /// and desync the connection, so the error surfaces when the reply lands.
    private var pendingLocalInfileError: (any Error)?
    private let sessionState: MySQLSessionState
    private var activity: Activity = .idle
    private var context: ChannelHandlerContext?

    init(
        capabilities: MySQLCapabilities,
        sessionState: MySQLSessionState,
        localInfile: MySQLConnectionConfiguration.LocalInfile = .disabled,
        onProgress: (@Sendable (MySQLProgressReport) -> Void)? = nil
    ) {
        self.localInfile = localInfile
        self.onProgress = onProgress
        self.capabilities = capabilities
        self.sessionState = sessionState
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    var isIdle: Bool {
        if case .idle = activity { return true }
        return false
    }

    /// `COM_STMT_CLOSE` packets waiting for the connection to fall idle.
    ///
    /// Bounded in practice by the number of statements prepared during one
    /// command, which is one.
    private var deferredCloses: [ByteBuffer] = []

    /// The single place the connection returns to idle, so the deferred closes
    /// have exactly one place to be flushed from.
    private func becomeIdle() {
        activity = .idle
        drainDeferredCloses()
    }

    private func drainDeferredCloses() {
        guard isIdle, let context, !deferredCloses.isEmpty else { return }
        let payloads = deferredCloses
        deferredCloses = []
        for payload in payloads {
            context.write(wrapOutboundOut(MySQLPacket(sequenceID: 0, payload: payload)), promise: nil)
        }
        context.flush()
    }

    // MARK: - Outbound

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let request = unwrapOutboundIn(data)

        if case .deferredClose = request.kind {
            deferredCloses.append(request.payload)
            request.promise.succeed(.acknowledged)
            drainDeferredCloses()
            promise?.succeed(())
            return
        }

        guard isIdle else {
            request.promise.fail(
                MySQLProtocolError.unexpectedPacket(
                    "a command is already in flight; MySQL connections are strictly serial"
                )
            )
            promise?.succeed(())
            return
        }

        // Commands restart the sequence at 0, unlike the handshake.
        let packet = MySQLPacket(sequenceID: 0, payload: request.payload)
        mysqlTrace(
            "CMD → seq=0 len=\(request.payload.readableBytes) "
            + "cmd=0x\(String(request.payload.getInteger(at: 0, as: UInt8.self) ?? 0, radix: 16))"
        )

        switch request.kind {
        case .deferredClose:
            // Handled above, before the busy check — it is the one kind that
            // queues rather than being rejected.
            promise?.succeed(())
            return

        case .binlog:
            // The promise resolves as soon as the dump is accepted; events then
            // flow for the life of the connection. Unlike a result set there is
            // no metadata to wait for, so the sequence is handed over at once.
            guard let context = self.context else {
                request.promise.fail(
                    MySQLProtocolError.connectionClosed("binlog: channel unavailable")
                )
                promise?.succeed(())
                return
            }
            let producer = MySQLBinlogStreamProducer(
                eventLoop: context.eventLoop, dataSource: self
            )
            let sequence = producer.makeSequence()
            activity = .binlog(Binlog(promise: nil, producer: producer))
            context.writeAndFlush(wrapOutboundOut(packet), promise: promise)
            request.promise.succeed(.binlog(sequence))
            context.read()
            return

        case .fireAndForget:
            // COM_STMT_CLOSE has no reply at all; waiting for one would hang.
            context.writeAndFlush(wrapOutboundOut(packet), promise: promise)
            request.promise.succeed(.acknowledged)
            return

        case .resultSet(let format):
            activity = .buffering(
                Buffering(
                    promise: request.promise,
                    decoder: .resultSet(
                        MySQLResultSetStateMachine(capabilities: capabilities, rowFormat: format)
                    ),
                    query: ""
                )
            )

        case .cursorFetch(let columns):
            activity = .buffering(
                Buffering(
                    promise: request.promise,
                    decoder: .resultSet(
                        MySQLResultSetStateMachine(
                            capabilities: capabilities,
                            rowFormat: .binary,
                            knownColumns: columns
                        )
                    ),
                    query: ""
                )
            )

        case .stream(let format):
            activity = .streaming(
                Streaming(
                    promise: request.promise,
                    machine: MySQLResultSetStateMachine(
                        capabilities: capabilities, rowFormat: format
                    )
                )
            )

        case .prepare(let query):
            activity = .buffering(
                Buffering(
                    promise: request.promise,
                    decoder: .prepare(MySQLPrepareStateMachine(capabilities: capabilities)),
                    query: query
                )
            )

        case .changeUser(let password):
            activity = .changingUser(
                ChangingUser(promise: request.promise, password: password)
            )
        }

        context.writeAndFlush(wrapOutboundOut(packet), promise: promise)
        context.read()
    }

    // MARK: - Inbound

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let packet = unwrapInboundIn(data)

        switch activity {
        case .idle:
            context.fireChannelRead(data)
        case .buffering:
            handleBuffered(packet)
        case .streaming:
            handleStreamed(packet)
        case .changingUser:
            handleChangeUser(packet, context: context)
        case .binlog:
            handleBinlog(packet)
        }
    }

    /// Drives the re-authentication triggered by `COM_CHANGE_USER`.
    private func handleChangeUser(_ packet: MySQLPacket, context: ChannelHandlerContext) {
        guard case .changingUser(var state) = activity else { return }
        var buffer = packet.payload

        switch packet.firstByte {
        case 0x00:
            becomeIdle()
            state.promise.succeed(.acknowledged)

        case 0xFF:
            becomeIdle()
            do {
                let error = try MySQLErrorPacket.parse(&buffer, capabilities: capabilities)
                state.promise.fail(error.asProtocolError)
            } catch {
                state.promise.fail(error)
            }

        case 0xFE:
            // AuthSwitchRequest with a fresh scramble. Permitted once, for the
            // same reason as during the handshake: repeated switches would let a
            // server walk the client down to a weaker plugin.
            guard !state.hasSwitched else {
                becomeIdle()
                state.promise.fail(MySQLProtocolError.repeatedAuthSwitch)
                return
            }
            do {
                let request = try MySQLAuthSwitchRequest.parse(&buffer)
                let plugin = MySQLAuthPlugin(name: request.pluginName)
                let response: [UInt8]
                switch plugin {
                case .mysqlNativePassword:
                    response = MySQLAuth.nativePassword(
                        password: state.password, scramble: request.pluginData
                    )
                case .cachingSHA2Password:
                    response = MySQLAuth.cachingSHA2Password(
                        password: state.password, scramble: request.pluginData
                    )
                default:
                    becomeIdle()
                    state.promise.fail(
                        MySQLProtocolError.unsupportedAuthPlugin(
                            "COM_CHANGE_USER cannot answer \(plugin.name)"
                        )
                    )
                    return
                }

                state.hasSwitched = true
                activity = .changingUser(state)

                // The sequence continues from the server's packet — it does not
                // restart the way a new command does.
                var payload = ByteBuffer()
                payload.writeBytes(response)
                context.writeAndFlush(
                    wrapOutboundOut(
                        MySQLPacket(sequenceID: packet.sequenceID &+ 1, payload: payload)
                    ),
                    promise: nil
                )
                context.read()
            } catch {
                becomeIdle()
                state.promise.fail(error)
            }

        case 0x01:
            // caching_sha2 fast-auth success; the OK still follows, and the
            // server expects nothing from us in between.
            break

        default:
            becomeIdle()
            state.promise.fail(
                MySQLProtocolError.unexpectedPacket(
                    "unexpected COM_CHANGE_USER reply 0x\(String(packet.firstByte ?? 0, radix: 16))"
                )
            )
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        switch activity {
        case .idle:
            break
        case .buffering:
            // A buffered command reads until its response is complete.
            context.read()
        case .streaming(let state):
            // Hand over whatever accumulated in this read burst, then read again
            // only if the consumer still wants rows. This is where backpressure
            // actually bites.
            flushPendingRows(state)
            if state.wantsMore || state.isDraining { context.read() }
        case .changingUser:
            // Re-authentication is a short request/response exchange.
            context.read()
        case .binlog(let state):
            flushPendingEvents(state)
            if state.wantsMore { context.read() }
        }
        context.fireChannelReadComplete()
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(MySQLProtocolError.connectionClosed("connection closed mid-command"))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        fail(error)
        context.fireErrorCaught(error)
    }

    // MARK: - Buffered path

    private func handleBuffered(_ packet: MySQLPacket) {
        guard case .buffering(let state) = activity else { return }

        switch state.decoder {
        case .resultSet(var machine):
            let action = machine.receive(packet)
            state.decoder = .resultSet(machine)
            handleResultSetAction(action, sequenceID: packet.sequenceID)
        case .prepare(var machine):
            let action = machine.receive(packet)
            state.decoder = .prepare(machine)
            handlePrepareAction(action)
        }
    }

    private func handleResultSetAction(
        _ action: MySQLResultSetStateMachine.Action, sequenceID: UInt8
    ) {
        guard case .buffering(let state) = activity else { return }

        switch action {
        case .wait:
            return
        case .progress(let report):
            // Informational: the command is still in flight, so nothing about
            // the buffered state changes.
            onProgress?(report)
            return
        case .columns(let columns):
            state.currentColumns = columns
        case .row(let row):
            state.currentRows.append(row)
        case .sendLocalFile(let path):
            sendLocalFile(path: path, startingAt: sequenceID &+ 1)
            return
        case .finishedWithoutRows(let ok), .finished(let ok):
            recordStatus(ok)
            // A refusal is reported now, once the server's reply has been read
            // and the connection is back in sync.
            if let error = pendingLocalInfileError {
                pendingLocalInfileError = nil
                becomeIdle()
                state.promise.fail(error)
                return
            }
            state.results.append(makeResult(state, ok))
            becomeIdle()
            state.promise.succeed(.results(state.results))
            return
        case .finishedWithMoreResults(let ok):
            recordStatus(ok)
            state.results.append(makeResult(state, ok))
            if case .resultSet(var machine) = state.decoder {
                machine.reset()
                state.decoder = .resultSet(machine)
            }
            state.currentColumns = []
            state.currentRows = []
        case .fail(let error):
            becomeIdle()
            state.promise.fail(error)
            return
        }
    }

    // MARK: - LOAD DATA LOCAL INFILE

    /// Chunk size for the file transfer. Well under the 16 MiB packet limit, so
    /// each chunk is one packet and the split-packet path is never involved.
    private static let localInfileChunkSize = 1 << 20

    /// Answers the server's file request.
    ///
    /// The protocol obligation that shapes this method: **the terminating empty
    /// packet must be sent whatever happens.** Refusing the path, or failing to
    /// open the file, does not excuse us from it — the server is mid-transfer
    /// and will sit waiting. Skipping the terminator on the error path leaves
    /// the connection permanently desynchronised, which is far worse than the
    /// original error. So local failures are recorded and reported later, after
    /// the server's reply has been consumed.
    private func sendLocalFile(path: String, startingAt firstSequence: UInt8) {
        guard let context else { return }
        var sequence = firstSequence

        func send(_ bytes: [UInt8]) {
            var payload = context.channel.allocator.buffer(capacity: bytes.count)
            payload.writeBytes(bytes)
            context.write(
                wrapOutboundOut(MySQLPacket(sequenceID: sequence, payload: payload)),
                promise: nil
            )
            sequence &+= 1
        }

        if localInfile.permits(path) {
            do {
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                defer { try? handle.close() }
                while true {
                    let chunk = try handle.read(upToCount: Self.localInfileChunkSize) ?? Data()
                    if chunk.isEmpty { break }
                    send(Array(chunk))
                }
            } catch {
                pendingLocalInfileError = error
            }
        } else {
            pendingLocalInfileError = MySQLProtocolError.localInfileRefused(
                "server asked for '\(path)', which is not in the LOCAL INFILE allow-list"
            )
        }

        // The terminator, always.
        send([])
        context.flush()
        context.read()
    }

    private func handlePrepareAction(_ action: MySQLPrepareStateMachine.Action) {
        guard case .buffering(let state) = activity else { return }

        switch action {
        case .wait:
            return
        case .prepared(let header, let parameters, let columns):
            becomeIdle()
            state.promise.succeed(
                .prepared(
                    MySQLPreparedStatement(
                        id: header.statementID,
                        query: state.query,
                        parameters: parameters,
                        columns: columns
                    )
                )
            )
        case .fail(let error):
            becomeIdle()
            state.promise.fail(error)
        }
    }

    /// Every terminator carries the server's current session status, so this is
    /// the single point where our view of "in a transaction" is refreshed.
    private func recordStatus(_ ok: MySQLOKPacket) {
        sessionState.update(ok.statusFlags)
    }

    private func makeResult(_ state: Buffering, _ ok: MySQLOKPacket) -> MySQLQueryResult {
        MySQLQueryResult(
            columns: state.currentColumns,
            rows: state.currentRows,
            affectedRows: ok.affectedRows,
            lastInsertID: ok.lastInsertID,
            warningCount: ok.warningCount,
            info: ok.info,
            statusFlags: ok.statusFlags
        )
    }

    // MARK: - Binlog path

    /// One event per packet, prefixed with the usual `0x00` marker.
    ///
    /// The marker matters: `0xFF` is a genuine error (a bad position, or the
    /// primary purging the file we asked for) and `0xFE` ends a non-blocking
    /// dump. Both must be distinguished from event data, whose first byte is the
    /// low byte of a timestamp and can be anything.
    private func handleBinlog(_ packet: MySQLPacket) {
        guard case .binlog(let state) = activity else { return }
        var payload = packet.payload

        switch packet.firstByte {
        case 0xFF:
            let error = (try? MySQLErrorPacket.parse(&payload, capabilities: capabilities))
                .map { MySQLProtocolError.server(code: $0.errorCode, sqlState: $0.sqlState ?? "", message: $0.message) }
                ?? MySQLProtocolError.malformedPacket("binlog: unreadable error packet")
            failBinlog(state, error)
            return

        case 0xFE where payload.readableBytes < 9:
            // End of a non-blocking dump: the log has been read to its end.
            let promise = state.promise
            state.promise = nil
            flushPendingEvents(state)
            state.producer.finish()
            becomeIdle()
            promise?.succeed(.binlog(state.producer.makeSequence()))
            return

        default:
            break
        }

        payload.moveReaderIndex(forwardBy: 1)      // strip the 0x00 marker

        do {
            // One packet can yield several events: a compressed transaction
            // expands to everything it contained.
            state.pending.append(contentsOf: try state.decoder.decode(intoEvents: payload))
        } catch {
            failBinlog(state, error)
            return
        }
    }

    private func failBinlog(_ state: Binlog, _ error: any Error) {
        let promise = state.promise
        state.promise = nil
        state.producer.finish(throwing: error)
        becomeIdle()
        promise?.fail(error)
    }

    private func flushPendingEvents(_ state: Binlog) {
        guard !state.pending.isEmpty else { return }
        let events = state.pending
        state.pending = []
        state.wantsMore = state.producer.yield(events)
    }

    // MARK: - Streaming path

    private func handleStreamed(_ packet: MySQLPacket) {
        guard case .streaming(let state) = activity, let context else { return }

        let action = state.machine.receive(packet)

        switch action {
        case .wait:
            break

        case .progress(let report):
            onProgress?(report)
            return

        case .columns(let columns):
            // Resolve the caller as soon as metadata is known — before a single
            // row has been read.
            let stream = MySQLRowStream(
                columns: columns, eventLoop: context.eventLoop, dataSource: self
            )
            state.stream = stream
            let promise = state.promise
            state.promise = nil
            promise?.succeed(.streaming(stream.makeSequence()))

        case .row(let row):
            if !state.isDraining { state.pending.append(row) }

        case .sendLocalFile(let path):
            // Reachable because `LOAD DATA LOCAL INFILE` can be issued through
            // the streaming API; it just yields no rows.
            sendLocalFile(path: path, startingAt: packet.sequenceID &+ 1)
            return

        case .finishedWithoutRows(let ok), .finished(let ok):
            recordStatus(ok)
            if let error = pendingLocalInfileError {
                pendingLocalInfileError = nil
                let promise = state.promise
                state.promise = nil
                state.stream?.finish(throwing: error)
                becomeIdle()
                promise?.fail(error)
                return
            }
            finishStream(state)
            becomeIdle()
            return

        case .finishedWithMoreResults:
            // Only the first result set is streamed; the rest are drained so the
            // connection is left clean.
            state.isDraining = true
            state.pending = []
            state.machine.reset()

        case .fail(let error):
            let promise = state.promise
            state.promise = nil
            state.stream?.finish(throwing: error)
            becomeIdle()
            promise?.fail(error)
            return
        }
    }

    /// Hands accumulated rows to the consumer and records whether it wants more.
    private func flushPendingRows(_ state: Streaming) {
        guard let stream = state.stream, !state.pending.isEmpty else { return }
        let rows = state.pending
        state.pending = []
        state.wantsMore = stream.yield(rows)
    }

    private func finishStream(_ state: Streaming) {
        flushPendingRows(state)
        // A stream that ends before any column definitions arrived (an OK from
        // a non-SELECT) still needs a sequence to hand back, or the caller waits
        // for a promise nobody will fulfil.
        if let promise = state.promise, let context {
            let stream = MySQLRowStream(
                columns: [], eventLoop: context.eventLoop, dataSource: self
            )
            state.promise = nil
            promise.succeed(.streaming(stream.makeSequence()))
            stream.finish()
            return
        }
        state.stream?.finish()
    }

    private func fail(_ error: any Error) {
        switch activity {
        case .idle:
            break
        case .buffering(let state):
            becomeIdle()
            state.promise.fail(error)
        case .streaming(let state):
            becomeIdle()
            state.stream?.finish(throwing: error)
            state.promise?.fail(error)
        case .changingUser(let state):
            becomeIdle()
            state.promise.fail(error)
        case .binlog(let state):
            failBinlog(state, error)
        }
    }
}

// MARK: - Binlog demand

extension MySQLCommandHandler: MySQLBinlogDataSource {
    func requestMoreEvents(for stream: MySQLBinlogStreamProducer) {
        guard case .binlog(let state) = activity, let context else { return }
        state.wantsMore = true
        context.read()
    }

    /// The consumer stopped iterating. A binlog connection cannot be drained and
    /// reused — the server would keep streaming forever — so the only correct
    /// response is to close it.
    func cancelBinlog(for stream: MySQLBinlogStreamProducer) {
        guard case .binlog = activity, let context else { return }
        becomeIdle()
        context.close(promise: nil)
    }
}

// MARK: - Row demand

extension MySQLCommandHandler: MySQLRowDataSource {
    /// The consumer drained enough to want more rows.
    func requestMoreRows(for stream: MySQLRowStream) {
        guard case .streaming(let state) = activity, let context else { return }
        state.wantsMore = true
        context.read()
    }

    /// The consumer abandoned the sequence — a `break`, a thrown error, or task
    /// cancellation.
    ///
    /// MySQL offers no way to abort a result set mid-flight, so the remaining
    /// rows are read and discarded. Skipping the drain would leave them queued
    /// for whatever command ran next on this connection.
    func cancelStream(for stream: MySQLRowStream) {
        guard case .streaming(let state) = activity, let context else { return }
        state.isDraining = true
        state.pending = []
        state.wantsMore = true
        context.read()
    }
}

import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import SwizzleCore
import Testing
@testable import SwizzlePostgresDriver

@Suite("Postgres command handler")
struct CommandHandlerTests {

    /// Counts `read()` calls from the head of the pipeline.
    ///
    /// This is what makes the read gate testable at all: with `autoRead` off,
    /// every read is an explicit request, so counting them is counting exactly how
    /// much the driver asked the socket for.
    final class ReadCounter: ChannelOutboundHandler {
        typealias OutboundIn = NIOAny
        private let count = NIOLockedValueBox(0)
        var reads: Int { count.withLockedValue { $0 } }

        func read(context: ChannelHandlerContext) {
            count.withLockedValue { $0 += 1 }
            context.read()
        }
    }

    final class Harness {
        let channel = EmbeddedChannel()
        let counter = ReadCounter()
        let handler: PostgresCommandHandler

        init(statementCacheCapacity: Int = PostgresStatementCache.defaultCapacity) throws {
            handler = PostgresCommandHandler(statementCacheCapacity: statementCacheCapacity)
            try channel.pipeline.syncOperations.addHandler(counter)
            try channel.pipeline.syncOperations.addHandler(handler)
            try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 5432)).wait()
            // The command phase is demand-driven, exactly as the real connection
            // leaves it after the handshake.
            try channel.setOption(.autoRead, value: false).wait()
        }

        func send(_ request: PostgresRequest) {
            channel.pipeline.fireUserInboundEventTriggered(())  // no-op, keeps ordering explicit
            _ = channel.writeAndFlush(request)
        }

        /// Delivers messages one at a time, each with its own read-complete —
        /// which is what `EmbeddedChannel.writeInbound` does anyway.
        func receive(_ messages: [PostgresBackendMessage]) throws {
            for message in messages {
                try channel.writeInbound(message)
            }
        }

        /// Delivers messages as **one** read, the way a single TCP segment does.
        ///
        /// Distinct from `receive` and not a convenience: `writeInbound` fires a
        /// read-complete per message, so it can never produce a batch. Anything
        /// about batching — which is where the row buffer and the read gate both
        /// live — is invisible unless the reads are grouped like this.
        func receiveAsOneRead(_ messages: [PostgresBackendMessage]) {
            for message in messages {
                channel.pipeline.fireChannelRead(NIOAny(message))
            }
            channel.pipeline.fireChannelReadComplete()
        }

        func sentMessages() throws -> [PostgresFrontendMessage] {
            var messages: [PostgresFrontendMessage] = []
            while let message = try channel.readOutbound(as: PostgresFrontendMessage.self) {
                messages.append(message)
            }
            return messages
        }
    }

    func column(_ name: String, _ oid: PostgresOID = .int8) -> PostgresColumnDescription {
        PostgresColumnDescription(
            name: name, tableOID: 1, columnAttributeNumber: 1,
            dataTypeOID: oid.rawValue, dataTypeSize: 8, dataTypeModifier: -1, format: 1
        )
    }

    func int8(_ value: Int64) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }

    // MARK: - Collected queries

    @Test("a query sends its messages and resolves with the rows")
    func collectedQuery() throws {
        let harness = try Harness()
        let promise = harness.channel.eventLoop.makePromise(of: PostgresQueryResult.self)
        harness.send(.query(.extended(sql: "SELECT id FROM t", bindings: []), promise))

        #expect(try harness.sentMessages().count == 5)  // Parse, Bind, Describe, Execute, Sync

        try harness.receive([
            .parseComplete, .bindComplete,
            .rowDescription([column("id")]),
            .dataRow([int8(1)]), .dataRow([int8(2)]),
            .commandComplete(tag: "SELECT 2"),
            .readyForQuery(.idle),
        ])

        let result = try promise.futureResult.wait()
        #expect(result.rows == [[.int(1)], [.int(2)]])
        #expect(result.affectedRows == 2)
    }

    @Test("a describe resolves with the statement's shape")
    func describe() throws {
        let harness = try Harness()
        let promise = harness.channel.eventLoop.makePromise(
            of: PostgresStatementDescription.self
        )
        harness.send(.describe("SELECT id FROM t WHERE id = $1", promise))

        try harness.receive([
            .parseComplete,
            .parameterDescription([PostgresOID.int8.rawValue]),
            .rowDescription([column("id")]),
            .readyForQuery(.idle),
        ])

        let description = try promise.futureResult.wait()
        #expect(description.parameterTypes == [PostgresOID.int8.rawValue])
        #expect(description.columns.map(\.name) == ["id"])
    }

    /// One statement at a time: the second must not go out until the first has
    /// reached `ReadyForQuery`, or the replies interleave with nothing to tell
    /// them apart.
    @Test("statements are serialised, not interleaved")
    func serialised() throws {
        let harness = try Harness()
        let first = harness.channel.eventLoop.makePromise(of: PostgresQueryResult.self)
        let second = harness.channel.eventLoop.makePromise(of: PostgresQueryResult.self)
        harness.send(.query(.simple("SELECT 1"), first))
        harness.send(.query(.simple("SELECT 2"), second))

        // Only the first query is on the wire.
        #expect(try harness.sentMessages() == [.query("SELECT 1")])

        try harness.receive([.commandComplete(tag: "SELECT 0"), .readyForQuery(.idle)])
        _ = try first.futureResult.wait()

        // And now the second.
        #expect(try harness.sentMessages() == [.query("SELECT 2")])
    }

    // MARK: - The read gate

    /// With `autoRead` off, every read is an explicit request. A consumer that
    /// stops taking rows must stop the reads — that is what fills the receive
    /// buffer and, through TCP, stalls the server in its own write.
    @Test("reads stop when the consumer stops taking rows")
    func readsStopWhenConsumerStalls() async throws {
        let harness = try Harness()
        let promise = harness.channel.eventLoop.makePromise(of: PostgresRowSequence.self)
        harness.send(.stream(sql: "SELECT id FROM big", bindings: [], maxRows: 0, promise))

        let readsAfterStart = harness.counter.reads
        #expect(readsAfterStart > 0)  // a statement is in flight, so reads are wanted

        try harness.receive([.rowDescription([column("id")])])
        _ = try await promise.futureResult.get()

        // Deliver more than the buffer's target, without consuming any.
        let target = PostgresAdaptiveRowBuffer.defaultTarget
        try harness.receive((0..<(target + 1)).map { .dataRow([int8(Int64($0))]) })

        // The gate is now closed. Every further read-complete must produce no
        // read at all — not merely fewer.
        let readsAtStall = harness.counter.reads
        for _ in 0..<5 {
            try harness.receive([.dataRow([int8(0)])])
        }
        #expect(harness.counter.reads == readsAtStall)
    }

    /// And it opens again. A gate that closes and stays shut is a hang, not
    /// backpressure — the consumer taking rows is what asks for the next read.
    @Test("consuming rows opens the read gate again")
    func consumingReopensTheGate() async throws {
        let harness = try Harness()
        let promise = harness.channel.eventLoop.makePromise(of: PostgresRowSequence.self)
        harness.send(.stream(sql: "SELECT id FROM big", bindings: [], maxRows: 0, promise))
        try harness.receive([.rowDescription([column("id")])])
        let sequence = try await promise.futureResult.get()

        let target = PostgresAdaptiveRowBuffer.defaultTarget
        try harness.receive((0..<(target + 1)).map { .dataRow([int8(Int64($0))]) })
        let readsAtStall = harness.counter.reads

        // Drain the buffer, which is what `produceMore` reacts to.
        var iterator = sequence.makeAsyncIterator()
        for _ in 0..<(target + 1) { _ = try await iterator.next() }
        harness.channel.embeddedEventLoop.run()

        #expect(harness.counter.reads > readsAtStall)
    }

    @Test("a stream resolves before the first row, so columns are known early")
    func columnsAvailableBeforeRows() throws {
        let harness = try Harness()
        let promise = harness.channel.eventLoop.makePromise(of: PostgresRowSequence.self)
        harness.send(.stream(sql: "SELECT id, name FROM t", bindings: [], maxRows: 0, promise))

        // RowDescription alone — not a single DataRow yet.
        try harness.receive([.rowDescription([column("id"), column("name", .text)])])

        let sequence = try promise.futureResult.wait()
        #expect(sequence.columns.map(\.name) == ["id", "name"])
    }

    @Test("streamed rows reach the consumer and the sequence ends")
    func streamDelivers() async throws {
        let harness = try Harness()
        let promise = harness.channel.eventLoop.makePromise(of: PostgresRowSequence.self)
        harness.send(.stream(sql: "SELECT id FROM t", bindings: [], maxRows: 0, promise))

        try harness.receive([.rowDescription([column("id")])])
        let sequence = try await promise.futureResult.get()

        try harness.receive([.dataRow([int8(7)]), .dataRow([int8(8)])])
        try harness.receive([.commandComplete(tag: "SELECT 2"), .readyForQuery(.idle)])

        let rows = try await sequence.collect()
        #expect(rows.map { $0[0] } == [.int(7), .int(8)])
    }

    /// Rows are batched per read, so the ones that arrive in the *same* read as
    /// `CommandComplete` are still pending when the statement finishes. Flushing
    /// after clearing the running state drops them — and a result set that ends
    /// one batch short is far harder to notice than one that fails.
    @Test("rows arriving in the final read are not dropped")
    func finalBatchIsDelivered() async throws {
        let harness = try Harness()
        let promise = harness.channel.eventLoop.makePromise(of: PostgresRowSequence.self)
        harness.send(.stream(sql: "SELECT id FROM t", bindings: [], maxRows: 0, promise))
        try harness.receive([.rowDescription([column("id")])])
        let sequence = try await promise.futureResult.get()

        // Everything in one read, ending the statement — the case where the last
        // rows are still pending when the statement completes.
        harness.receiveAsOneRead([
            .dataRow([int8(1)]), .dataRow([int8(2)]), .dataRow([int8(3)]),
            .commandComplete(tag: "SELECT 3"),
            .readyForQuery(.idle),
        ])

        let rows = try await sequence.collect()
        #expect(rows.map { $0[0] } == [.int(1), .int(2), .int(3)])
    }

    /// A streamed result must not *also* pile up in memory, or streaming buys
    /// nothing but a different API.
    @Test("streamed rows are not accumulated behind the consumer's back")
    func streamedRowsAreNotAlsoCollected() throws {
        let harness = try Harness()
        let promise = harness.channel.eventLoop.makePromise(of: PostgresRowSequence.self)
        harness.send(.stream(sql: "SELECT id FROM t", bindings: [], maxRows: 0, promise))
        try harness.receive([.rowDescription([column("id")])])
        _ = try promise.futureResult.wait()

        try harness.receive((0..<64).map { .dataRow([int8(Int64($0))]) })

        // The state machine's own row array stays empty throughout.
        let collected = harness.handler.collectedRowCountForTesting
        #expect(collected == 0)
    }

    // MARK: - The empty case that would otherwise hang

    /// A statement that returns nothing sends no `RowDescription`, so the stream
    /// is never created. Leaving its promise unresolved would hang the caller
    /// forever instead of handing back an empty sequence.
    @Test("a statement with no result yields an empty sequence, not a hang")
    func emptyStream() async throws {
        let harness = try Harness()
        let promise = harness.channel.eventLoop.makePromise(of: PostgresRowSequence.self)
        harness.send(.stream(sql: "UPDATE t SET a = 1", bindings: [], maxRows: 0, promise))

        try harness.receive([
            .parseComplete, .bindComplete, .noData,
            .commandComplete(tag: "UPDATE 3"),
            .readyForQuery(.idle),
        ])

        let sequence = try await promise.futureResult.get()
        #expect(try await sequence.collect().isEmpty)
    }

    // MARK: - Failures

    @Test("a failing statement fails its promise")
    func failure() throws {
        let harness = try Harness()
        let promise = harness.channel.eventLoop.makePromise(of: PostgresQueryResult.self)
        harness.send(.query(.simple("boom"), promise))

        try harness.receive([
            .error(PostgresServerMessage(fields: [0x43: "42601", 0x4D: "syntax error"])),
            .readyForQuery(.failed),
        ])

        #expect(throws: (any Error).self) { try promise.futureResult.wait() }
    }

    /// Once the sequence has been handed over the caller is iterating and will
    /// never look at the promise again, so a later error belongs on the stream.
    /// Failing both would be a duplicate resolution at best.
    @Test("an error after the stream started surfaces through the sequence")
    func errorAfterStreamStarted() async throws {
        let harness = try Harness()
        let promise = harness.channel.eventLoop.makePromise(of: PostgresRowSequence.self)
        harness.send(.stream(sql: "SELECT id FROM t", bindings: [], maxRows: 0, promise))
        try harness.receive([.rowDescription([column("id")])])
        let sequence = try await promise.futureResult.get()

        try harness.receive([
            .dataRow([int8(1)]),
            .error(PostgresServerMessage(fields: [0x43: "57014", 0x4D: "canceling statement"])),
            .readyForQuery(.failed),
        ])

        await #expect(throws: (any Error).self) { _ = try await sequence.collect() }
    }

    // MARK: - Statement caching

    /// The unnamed statement is correct but costs a `Parse` on every execution.
    /// A named one is parsed once and bound thereafter.
    @Test("a repeated query is parsed once and bound thereafter")
    func cachedStatementSkipsParse() throws {
        let harness = try Harness()

        func run(_ sql: String) throws -> [PostgresFrontendMessage] {
            let promise = harness.channel.eventLoop.makePromise(of: PostgresQueryResult.self)
            harness.send(.query(.extended(sql: sql, bindings: []), promise))
            let sent = try harness.sentMessages()
            try harness.receive([.commandComplete(tag: "SELECT 0"), .readyForQuery(.idle)])
            _ = try promise.futureResult.wait()
            return sent
        }

        let first = try run("SELECT id FROM t")
        #expect(first.count == 5)  // Parse, Bind, Describe, Execute, Sync
        guard case .parse(let name, _, _) = first[0] else {
            Issue.record("expected a Parse"); return
        }
        #expect(!name.isEmpty)  // named, so it survives to be reused

        let second = try run("SELECT id FROM t")
        #expect(second.count == 4)  // Bind, Describe, Execute, Sync — no Parse
        guard case .bind(_, let statement, _, _, _) = second[0] else {
            Issue.record("expected a Bind"); return
        }
        #expect(statement == name)
    }

    /// A prepared statement is a server-side allocation, so an evicted one must
    /// be closed — dropping the entry silently leaks it until the connection dies.
    @Test("an evicted statement is closed on the server")
    func evictionSendsClose() throws {
        let harness = try Harness(statementCacheCapacity: 1)

        func run(_ sql: String) throws -> [PostgresFrontendMessage] {
            let promise = harness.channel.eventLoop.makePromise(of: PostgresQueryResult.self)
            harness.send(.query(.extended(sql: sql, bindings: []), promise))
            let sent = try harness.sentMessages()
            try harness.receive([.commandComplete(tag: "SELECT 0"), .readyForQuery(.idle)])
            _ = try promise.futureResult.wait()
            return sent
        }

        _ = try run("SELECT 1")
        let second = try run("SELECT 2")

        let closes = second.filter { if case .close = $0 { return true } else { return false } }
        #expect(closes.count == 1)
    }

    /// A describe is a generator's one-off question about a statement's shape.
    /// Caching it would fill the connection's statement table with things nobody
    /// will ever execute.
    @Test("describes are not cached")
    func describesAreNotCached() throws {
        let harness = try Harness()
        let promise = harness.channel.eventLoop.makePromise(
            of: PostgresStatementDescription.self
        )
        harness.send(.describe("SELECT id FROM t", promise))

        let sent = try harness.sentMessages()
        guard case .parse(let name, _, _) = sent[0] else {
            Issue.record("expected a Parse"); return
        }
        #expect(name.isEmpty)
    }

    /// **The trap that makes caching dangerous.** After `ALTER TABLE`, a cached
    /// statement fails with `0A000` — and fails again every time after that,
    /// because the cache keeps handing back the same stale statement. One deploy
    /// poisons a pooled connection for hours.
    @Test("a stale cached plan is dropped and the statement retried once")
    func staleCachedPlanIsRetried() throws {
        let harness = try Harness()
        let sql = "SELECT id FROM t"

        // Prime the cache.
        let first = harness.channel.eventLoop.makePromise(of: PostgresQueryResult.self)
        harness.send(.query(.extended(sql: sql, bindings: []), first))
        _ = try harness.sentMessages()
        try harness.receive([.commandComplete(tag: "SELECT 0"), .readyForQuery(.idle)])
        _ = try first.futureResult.wait()

        // Now the schema changes underneath it.
        let second = harness.channel.eventLoop.makePromise(of: PostgresQueryResult.self)
        harness.send(.query(.extended(sql: sql, bindings: []), second))
        #expect(try harness.sentMessages().count == 4)  // cached: no Parse

        try harness.receive([
            .error(PostgresServerMessage(fields: [
                0x43: "0A000", 0x4D: "cached plan must not change result type",
            ])),
            .readyForQuery(.failed),
        ])

        // Retried automatically, and this time with a Parse — the cache was
        // dropped, so the statement is prepared afresh.
        let retry = try harness.sentMessages()
        #expect(retry.count == 5)
        if case .parse = retry[0] {} else { Issue.record("the retry should re-Parse") }

        try harness.receive([.commandComplete(tag: "SELECT 0"), .readyForQuery(.idle)])
        // And the caller never saw the failure at all.
        #expect(try second.futureResult.wait().commandTag == "SELECT 0")
    }

    /// One retry only. A second failure is a real error, and retrying forever
    /// would turn it into a spin.
    @Test("a statement that fails the same way twice gives up")
    func staleCachedPlanRetriesOnlyOnce() throws {
        let harness = try Harness()
        let promise = harness.channel.eventLoop.makePromise(of: PostgresQueryResult.self)
        harness.send(.query(.extended(sql: "SELECT id FROM t", bindings: []), promise))
        _ = try harness.sentMessages()

        let stale = PostgresBackendMessage.error(PostgresServerMessage(fields: [
            0x43: "0A000", 0x4D: "cached plan must not change result type",
        ]))
        try harness.receive([stale, .readyForQuery(.failed)])
        _ = try harness.sentMessages()
        try harness.receive([stale, .readyForQuery(.failed)])

        #expect(throws: (any Error).self) { try promise.futureResult.wait() }
    }

    /// `DISCARD ALL` deallocates every prepared statement server-side, so the
    /// driver's cache has to go with it. Leaving it populated would have the next
    /// query bind a name the server has just thrown away — every statement
    /// failing with "prepared statement does not exist", on a connection that
    /// looks perfectly healthy.
    @Test("forgetting the cache sends no Close, because the server already dropped them")
    func forgettingCacheSendsNoClose() throws {
        let harness = try Harness()
        let promise = harness.channel.eventLoop.makePromise(of: PostgresQueryResult.self)
        harness.send(.query(.extended(sql: "SELECT 1", bindings: []), promise))
        _ = try harness.sentMessages()
        try harness.receive([.commandComplete(tag: "SELECT 0"), .readyForQuery(.idle)])
        _ = try promise.futureResult.wait()
        #expect(harness.handler.cachedStatementCountForTesting == 1)

        harness.handler.forgetPreparedStatements()

        #expect(harness.handler.cachedStatementCountForTesting == 0)
        // Closing names the server has already discarded would fail on every one.
        #expect(try harness.sentMessages().isEmpty)

        // And the next execution of the same SQL parses afresh.
        let again = harness.channel.eventLoop.makePromise(of: PostgresQueryResult.self)
        harness.send(.query(.extended(sql: "SELECT 1", bindings: []), again))
        #expect(try harness.sentMessages().count == 5)
    }

    @Test("a connection that dies fails the running statement and the queue")
    func connectionDies() throws {
        let harness = try Harness()
        let first = harness.channel.eventLoop.makePromise(of: PostgresQueryResult.self)
        let queued = harness.channel.eventLoop.makePromise(of: PostgresQueryResult.self)
        harness.send(.query(.simple("SELECT 1"), first))
        harness.send(.query(.simple("SELECT 2"), queued))

        _ = try? harness.channel.finish()

        #expect(throws: (any Error).self) { try first.futureResult.wait() }
        // The queued one never went out, and must not be left hanging either.
        #expect(throws: (any Error).self) { try queued.futureResult.wait() }
    }
}

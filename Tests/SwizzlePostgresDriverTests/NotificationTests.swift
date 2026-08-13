import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import Testing
@testable import SwizzlePostgresDriver

@Suite("Postgres LISTEN/NOTIFY")
struct NotificationTests {

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
        let handler = PostgresCommandHandler()

        init() throws {
            try channel.pipeline.syncOperations.addHandler(counter)
            try channel.pipeline.syncOperations.addHandler(handler)
            try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 5432)).wait()
            try channel.setOption(.autoRead, value: false).wait()
        }
    }

    func notification(
        _ channel: String, _ payload: String = "", pid: Int32 = 42
    ) -> PostgresBackendMessage {
        .notification(processID: pid, channel: channel, payload: payload)
    }

    @Test("a notification reaches a listener")
    func delivery() async throws {
        let harness = try Harness()
        let stream = harness.handler.notificationStream()

        try harness.channel.writeInbound(notification("jobs", "42"))

        var iterator = stream.makeAsyncIterator()
        let received = await iterator.next()
        #expect(received?.channel == "jobs")
        #expect(received?.payload == "42")
        #expect(received?.processID == 42)
    }

    /// Notifications arrive at any message boundary, **including boundaries
    /// inside a result set** — so they cannot be handled only when the connection
    /// is idle, and they must not be mistaken for part of the result.
    @Test("a notification mid-result is delivered without disturbing the rows")
    func deliveryDuringAQuery() async throws {
        let harness = try Harness()
        let stream = harness.handler.notificationStream()

        let promise = harness.channel.eventLoop.makePromise(of: PostgresQueryResult.self)
        harness.channel.pipeline.fireUserInboundEventTriggered(())
        harness.channel.write(PostgresRequest.query(.simple("SELECT id FROM t"), promise), promise: nil)
        harness.channel.flush()

        let column = PostgresColumnDescription(
            name: "id", tableOID: 1, columnAttributeNumber: 1,
            dataTypeOID: PostgresOID.int8.rawValue, dataTypeSize: 8,
            dataTypeModifier: -1, format: 0
        )
        try harness.channel.writeInbound(PostgresBackendMessage.rowDescription([column]))
        try harness.channel.writeInbound(PostgresBackendMessage.dataRow([Array("1".utf8)]))
        // Straight down the middle of the result set.
        try harness.channel.writeInbound(notification("jobs", "mid"))
        try harness.channel.writeInbound(PostgresBackendMessage.dataRow([Array("2".utf8)]))
        try harness.channel.writeInbound(PostgresBackendMessage.commandComplete(tag: "SELECT 2"))
        try harness.channel.writeInbound(PostgresBackendMessage.readyForQuery(.idle))

        let result = try promise.futureResult.wait()
        #expect(result.rows.count == 2)

        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.payload == "mid")
    }

    /// **The trap.** With `autoRead` off, an idle connection reads nothing
    /// because nothing asks — so a `LISTEN` would register successfully and then
    /// deliver nothing at all. That looks like it works, which is what makes it
    /// worth a test.
    @Test("an idle connection keeps reading while something is listening")
    func idleConnectionKeepsReading() throws {
        let harness = try Harness()
        let before = harness.counter.reads

        let stream = harness.handler.notificationStream()
        harness.channel.embeddedEventLoop.run()

        // Subscribing alone asks for a read, rather than waiting for the next
        // statement to open the gate.
        #expect(harness.counter.reads > before)

        // And each arriving notification asks for the next one.
        let afterSubscribe = harness.counter.reads
        try harness.channel.writeInbound(notification("jobs"))
        #expect(harness.counter.reads > afterSubscribe)

        _ = stream
    }

    /// A connection nobody is listening on stays fully demand-driven — the
    /// standing read exists only while there is a listener.
    @Test("an idle connection with no listeners does not read")
    func idleWithoutListenersDoesNotRead() throws {
        let harness = try Harness()
        let before = harness.counter.reads
        harness.channel.pipeline.fireChannelReadComplete()
        #expect(harness.counter.reads == before)
    }

    @Test("every listener sees every notification")
    func multipleListeners() async throws {
        let harness = try Harness()
        let first = harness.handler.notificationStream()
        let second = harness.handler.notificationStream()

        try harness.channel.writeInbound(notification("jobs", "both"))

        var a = first.makeAsyncIterator()
        var b = second.makeAsyncIterator()
        #expect(await a.next()?.payload == "both")
        #expect(await b.next()?.payload == "both")
    }

    @Test("listeners end when the connection closes rather than waiting forever")
    func closeFinishesListeners() async throws {
        let harness = try Harness()
        let stream = harness.handler.notificationStream()

        _ = try? harness.channel.finish()

        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    // MARK: - Injection

    /// A channel name is an *identifier*, not a value, so it cannot be bound as a
    /// parameter. A name containing a `"` would close the quoting and inject;
    /// doubling it is Postgres's own escape.
    @Test("a channel name with a quote in it is escaped, not injected")
    func identifierQuoting() {
        #expect(PostgresConnection.quoteIdentifier("jobs") == "\"jobs\"")
        #expect(
            PostgresConnection.quoteIdentifier(#"a"; DROP TABLE users; --"#)
                == #""a""; DROP TABLE users; --""#
        )
    }
}

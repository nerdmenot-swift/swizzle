import NIOCore

/// Adaptive backpressure for row delivery.
///
/// The same strategy the MySQL driver uses, and for the same reasons:
///
/// - `didYield` always returns `false`. Producing never continues just because
///   rows arrived; it continues only when the consumer takes some. That is what
///   makes the whole thing demand-driven rather than a race between socket and
///   consumer.
/// - Draining to empty **doubles** the target, so a fast consumer stops paying a
///   round trip per batch.
/// - Overshooting **halves** it, but only once a yield has been seen since the
///   last growth, so a single burst cannot collapse the window.
struct PostgresAdaptiveRowBuffer: NIOAsyncSequenceProducerBackPressureStrategy {
    static let defaultTarget = 256
    static let defaultMinimum = 1
    static let defaultMaximum = 16384

    let minimum: Int
    let maximum: Int
    private var target: Int
    private var canShrink = false

    init(
        minimum: Int = PostgresAdaptiveRowBuffer.defaultMinimum,
        maximum: Int = PostgresAdaptiveRowBuffer.defaultMaximum,
        target: Int = PostgresAdaptiveRowBuffer.defaultTarget
    ) {
        precondition(minimum <= target && target <= maximum)
        self.minimum = minimum
        self.maximum = maximum
        self.target = target
    }

    mutating func didYield(bufferDepth: Int) -> Bool {
        if bufferDepth > target, canShrink, target > minimum {
            target >>= 1
        }
        canShrink = true
        return false
    }

    mutating func didConsume(bufferDepth: Int) -> Bool {
        if bufferDepth == 0, target < maximum {
            target *= 2
            canShrink = false
        }
        return bufferDepth < target
    }
}

/// The channel-side half of a row stream.
///
/// Split out from the stream itself so the delegate callbacks — which arrive on
/// whatever thread the consumer happens to be on — can hop to the event loop
/// before touching connection state.
protocol PostgresRowDataSource: AnyObject, Sendable {
    func requestMoreRows(for stream: PostgresRowStream)
    func cancelStream(for stream: PostgresRowStream)
}

/// Bridges rows arriving on the event loop to an `AsyncSequence` consumer.
///
/// ## Where Postgres's backpressure actually comes from
///
/// This is the one place the two drivers genuinely differ, and it is worth being
/// explicit rather than assuming the MySQL design transfers.
///
/// MySQL's cursor mode has a **protocol-level** fetch: `COM_STMT_FETCH` asks for
/// N rows and the server sends N. Postgres's ordinary path has no equivalent —
/// once `Execute` goes out with a row limit of zero, the server streams the
/// entire result as fast as the socket will take it, and there is no message
/// that means "pause".
///
/// So backpressure here is **`autoRead = false`**: when the consumer stops
/// taking rows, the channel stops reading, the receive buffer fills, and TCP flow
/// control propagates the stall back to the server, which blocks in its own
/// write. It is a level lower than MySQL's, and it works — but it means a stalled
/// consumer holds a server backend open in a blocking write, which is why an
/// abandoned stream must be drained or the connection closed rather than simply
/// dropped.
///
/// The row-limited `Execute` path is the protocol-level alternative: `maxRows`
/// with `PortalSuspended` is a real cursor, at the cost of a round trip per
/// batch. Both exist, and callers should not have to know which one a query used.
final class PostgresRowStream: @unchecked Sendable {
    typealias Producer = NIOThrowingAsyncSequenceProducer<
        PostgresRow, any Error, PostgresAdaptiveRowBuffer, PostgresRowStream
    >

    let schema: PostgresRowSchema
    private let eventLoop: any EventLoop
    private weak var dataSource: (any PostgresRowDataSource)?

    private var source: Producer.Source?
    private var isFinished = false

    init(
        schema: PostgresRowSchema,
        eventLoop: any EventLoop,
        dataSource: any PostgresRowDataSource
    ) {
        self.schema = schema
        self.eventLoop = eventLoop
        self.dataSource = dataSource
    }

    /// Creates the consumer-facing sequence. Called once, immediately after init.
    func makeSequence() -> PostgresRowSequence {
        let made = Producer.makeSequence(
            elementType: PostgresRow.self,
            failureType: (any Error).self,
            backPressureStrategy: PostgresAdaptiveRowBuffer(),
            // The stream's lifetime is the statement's, not the sequence value's:
            // finishing on deinit would end a result set merely because the
            // sequence was passed along by value.
            finishOnDeinit: false,
            delegate: self
        )
        source = made.source
        return PostgresRowSequence(base: made.sequence, schema: schema)
    }

    /// Yields a batch. Returns true when the producer should keep reading.
    func yield(_ rows: [PostgresRow]) -> Bool {
        guard let source, !isFinished, !rows.isEmpty else { return !isFinished }
        switch source.yield(contentsOf: rows) {
        case .produceMore:
            return true
        case .stopProducing:
            return false
        case .dropped:
            // The consumer went away; nothing more will be read.
            isFinished = true
            return false
        @unknown default:
            return false
        }
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        source?.finish()
    }

    func finish(throwing error: any Error) {
        guard !isFinished else { return }
        isFinished = true
        source?.finish(error)
    }
}

extension PostgresRowStream: NIOAsyncSequenceProducerDelegate {
    /// The consumer drained enough to want more.
    func produceMore() {
        eventLoop.execute { [weak self] in
            guard let self, let dataSource = self.dataSource else { return }
            dataSource.requestMoreRows(for: self)
        }
    }

    /// The consumer stopped early — a `break`, a thrown error, or task
    /// cancellation. The rest of the result still has to be drained (or the
    /// connection killed) before it can be reused: an abandoned Postgres stream
    /// leaves a server backend blocked in a write that nobody is reading.
    func didTerminate() {
        eventLoop.execute { [weak self] in
            guard let self, let dataSource = self.dataSource else { return }
            dataSource.cancelStream(for: self)
        }
    }
}

/// An `AsyncSequence` of result rows.
///
/// Iterating applies real backpressure: rows leave the socket only as they are
/// consumed, so a result set larger than memory streams in bounded space.
public struct PostgresRowSequence: AsyncSequence, Sendable {
    public typealias Element = PostgresRow

    /// Two delivery mechanisms behind one type.
    ///
    /// The socket path is *push*, held back by `autoRead`; the portal path is
    /// *pull*, issuing a row-limited `Execute` only when the consumer runs dry.
    /// Callers should not have to care which mode a query used.
    enum Backing: Sendable {
        case socket(PostgresRowStream.Producer)
        case portal(@Sendable () async throws -> PostgresRow?)
    }

    let backing: Backing
    /// Column metadata, available before the first row arrives — `RowDescription`
    /// precedes every `DataRow`.
    public let schema: PostgresRowSchema

    public var columns: [PostgresColumnDescription] { schema.columns }

    init(base: PostgresRowStream.Producer, schema: PostgresRowSchema) {
        self.backing = .socket(base)
        self.schema = schema
    }

    init(schema: PostgresRowSchema, next: @escaping @Sendable () async throws -> PostgresRow?) {
        self.backing = .portal(next)
        self.schema = schema
    }

    public func makeAsyncIterator() -> AsyncIterator {
        switch backing {
        case .socket(let producer):
            return AsyncIterator(base: .socket(producer.makeAsyncIterator()))
        case .portal(let next):
            return AsyncIterator(base: .portal(next))
        }
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        enum Base {
            case socket(PostgresRowStream.Producer.AsyncIterator)
            case portal(@Sendable () async throws -> PostgresRow?)
        }
        var base: Base

        public mutating func next() async throws -> PostgresRow? {
            switch base {
            case .socket(var iterator):
                let row = try await iterator.next()
                base = .socket(iterator)
                return row
            case .portal(let pull):
                return try await pull()
            }
        }
    }
}

extension PostgresRowSequence {
    /// A sequence that ends immediately.
    ///
    /// Needed because a statement can complete without ever sending a
    /// `RowDescription` — an `UPDATE`, or a `SELECT` the planner proved empty —
    /// and a streaming caller must get an empty sequence rather than a promise
    /// that never resolves.
    static func empty(columns: [PostgresColumnDescription] = []) -> PostgresRowSequence {
        PostgresRowSequence(schema: PostgresRowSchema(columns)) { nil }
    }

    /// Collects every row. Defeats the point of streaming, but useful in tests
    /// and for results known to be small.
    public func collect() async throws -> [PostgresRow] {
        var rows: [PostgresRow] = []
        for try await row in self { rows.append(row) }
        return rows
    }
}

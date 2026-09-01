import NIOCore

/// Adaptive backpressure for row delivery.
///
/// Ported from PostgresNIO's `AdaptiveRowBuffer`, which is the reference design
/// for this in SwiftNIO. The shape is worth understanding rather than tuning
/// blindly:
///
/// - `didYield` always returns `false`. Producing never continues just because
///   rows arrived; it continues only when the consumer takes some. That is what
///   makes the whole thing demand-driven rather than a race between socket and
///   consumer.
/// - Draining to empty **doubles** the target, so a fast consumer stops paying
///   a round trip per batch.
/// - Overshooting the target **halves** it, but only once a yield has been seen
///   since the last growth (`canShrink`), so a single burst cannot collapse the
///   window.
struct MySQLAdaptiveRowBuffer: NIOAsyncSequenceProducerBackPressureStrategy {
    static let defaultTarget = 256
    static let defaultMinimum = 1
    static let defaultMaximum = 16384

    let minimum: Int
    let maximum: Int
    private var target: Int
    private var canShrink = false

    init(minimum: Int = MySQLAdaptiveRowBuffer.defaultMinimum,
         maximum: Int = MySQLAdaptiveRowBuffer.defaultMaximum,
         target: Int = MySQLAdaptiveRowBuffer.defaultTarget) {
        // Weakening this conjunction to a disjunction cannot be killed by any
        // test: catching it means constructing a buffer the correct
        // precondition rejects, and a failed precondition traps rather than
        // throwing. The tests pin both inclusive boundaries instead, which is
        // the half that is observable.
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
protocol MySQLRowDataSource: AnyObject, Sendable {
    func requestMoreRows(for stream: MySQLRowStream)
    func cancelStream(for stream: MySQLRowStream)
}

/// Bridges rows arriving on the event loop to an `AsyncSequence` consumer.
final class MySQLRowStream: @unchecked Sendable {
    typealias Producer = NIOThrowingAsyncSequenceProducer<
        MySQLRow, any Error, MySQLAdaptiveRowBuffer, MySQLRowStream
    >

    let columns: [MySQLColumnDefinition]
    private let eventLoop: any EventLoop
    private weak var dataSource: (any MySQLRowDataSource)?

    private var source: Producer.Source?
    private var isFinished = false

    init(
        columns: [MySQLColumnDefinition],
        eventLoop: any EventLoop,
        dataSource: any MySQLRowDataSource
    ) {
        self.columns = columns
        self.eventLoop = eventLoop
        self.dataSource = dataSource
    }

    /// Creates the consumer-facing sequence. Called once, immediately after init.
    func makeSequence() -> MySQLRowSequence {
        let made = Producer.makeSequence(
            elementType: MySQLRow.self,
            failureType: (any Error).self,
            backPressureStrategy: MySQLAdaptiveRowBuffer(),
            finishOnDeinit: false,
            delegate: self
        )
        source = made.source
        return MySQLRowSequence(base: made.sequence, columns: columns)
    }

    /// Yields a batch. Returns true when the producer should keep reading.
    func yield(_ rows: [MySQLRow]) -> Bool {
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

extension MySQLRowStream: NIOAsyncSequenceProducerDelegate {
    /// The consumer drained enough to want more.
    func produceMore() {
        eventLoop.execute { [weak self] in
            guard let self, let dataSource = self.dataSource else { return }
            dataSource.requestMoreRows(for: self)
        }
    }

    /// The consumer stopped early — a `break`, a thrown error, or task
    /// cancellation. The remaining rows still have to be drained (or the
    /// connection killed) before it can be reused.
    func didTerminate() {
        eventLoop.execute { [weak self] in
            guard let self, let dataSource = self.dataSource else { return }
            dataSource.cancelStream(for: self)
        }
    }
}

/// An `AsyncSequence` of result rows.
///
/// Iterating applies real backpressure: rows are read from the socket only as
/// they are consumed, so a result set larger than memory streams in bounded
/// space. This is the capability MySQLNIO cannot express — its `onRow` callback
/// has no way to say "stop".
public struct MySQLRowSequence: AsyncSequence, Sendable {
    public typealias Element = MySQLRow

    /// Two delivery mechanisms behind one type.
    ///
    /// The socket path is *push* with a backpressure window; the cursor path is
    /// *pull*, issuing a `COM_STMT_FETCH` only when the consumer runs dry.
    /// Callers should not have to care which mode a query used.
    enum Backing: Sendable {
        case socket(MySQLRowStream.Producer)
        case cursor(@Sendable () async throws -> MySQLRow?)
    }

    let backing: Backing
    /// Column metadata, available before the first row arrives.
    public let columns: [MySQLColumnDefinition]

    init(base: MySQLRowStream.Producer, columns: [MySQLColumnDefinition]) {
        self.backing = .socket(base)
        self.columns = columns
    }

    init(
        columns: [MySQLColumnDefinition],
        next: @escaping @Sendable () async throws -> MySQLRow?
    ) {
        self.backing = .cursor(next)
        self.columns = columns
    }

    public func makeAsyncIterator() -> AsyncIterator {
        switch backing {
        case .socket(let producer):
            return AsyncIterator(base: .socket(producer.makeAsyncIterator()))
        case .cursor(let next):
            return AsyncIterator(base: .cursor(next))
        }
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        enum Base {
            case socket(MySQLRowStream.Producer.AsyncIterator)
            case cursor(@Sendable () async throws -> MySQLRow?)
        }
        var base: Base

        public mutating func next() async throws -> MySQLRow? {
            switch base {
            case .socket(var iterator):
                let row = try await iterator.next()
                base = .socket(iterator)
                return row
            case .cursor(let pull):
                return try await pull()
            }
        }
    }
}

extension MySQLRowSequence {
    /// Collects every row. Defeats the point of streaming, but useful in tests
    /// and for small results.
    public func collect() async throws -> [MySQLRow] {
        var rows: [MySQLRow] = []
        for try await row in self { rows.append(row) }
        return rows
    }
}

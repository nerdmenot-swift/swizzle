import NIOCore

/// Backpressure for the binlog stream.
///
/// Deliberately simpler than `MySQLAdaptiveRowBuffer`. A result set is a bounded
/// batch where growing the window amortises round trips; a binlog is an
/// open-ended tail where the useful property is a *stable* bound on how far
/// ahead of the consumer the driver may run. Events are also far more variable
/// in size — a row event can carry thousands of rows — so counting them is a
/// poor proxy for memory and a small fixed window is the safer choice.
struct MySQLBinlogBackPressure: NIOAsyncSequenceProducerBackPressureStrategy {
    private let low = 16
    private let high = 64

    mutating func didYield(bufferDepth: Int) -> Bool {
        // Never resume merely because events arrived — only because the consumer
        // took some. Same rule as the row buffer, and the reason delivery is
        // demand-driven rather than a race with the socket.
        false
    }

    mutating func didConsume(bufferDepth: Int) -> Bool {
        bufferDepth < low
    }
}

protocol MySQLBinlogDataSource: AnyObject, Sendable {
    func requestMoreEvents(for stream: MySQLBinlogStreamProducer)
    func cancelBinlog(for stream: MySQLBinlogStreamProducer)
}

/// Bridges binlog events arriving on the event loop to an `AsyncSequence`.
final class MySQLBinlogStreamProducer: @unchecked Sendable {
    typealias Producer = NIOThrowingAsyncSequenceProducer<
        MySQLBinlogEvent, any Error, MySQLBinlogBackPressure, MySQLBinlogStreamProducer
    >

    private let eventLoop: any EventLoop
    private weak var dataSource: (any MySQLBinlogDataSource)?
    private var source: Producer.Source?
    private var isFinished = false

    init(eventLoop: any EventLoop, dataSource: any MySQLBinlogDataSource) {
        self.eventLoop = eventLoop
        self.dataSource = dataSource
    }

    func makeSequence() -> MySQLBinlogSequence {
        let made = Producer.makeSequence(
            elementType: MySQLBinlogEvent.self,
            failureType: (any Error).self,
            backPressureStrategy: MySQLBinlogBackPressure(),
            finishOnDeinit: false,
            delegate: self
        )
        source = made.source
        return MySQLBinlogSequence(base: made.sequence)
    }

    func yield(_ events: [MySQLBinlogEvent]) -> Bool {
        guard let source, !isFinished, !events.isEmpty else { return !isFinished }
        switch source.yield(contentsOf: events) {
        case .produceMore: return true
        case .stopProducing: return false
        case .dropped:
            isFinished = true
            return false
        @unknown default: return false
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

extension MySQLBinlogStreamProducer: NIOAsyncSequenceProducerDelegate {
    func produceMore() {
        eventLoop.execute { [weak self] in
            guard let self, let dataSource = self.dataSource else { return }
            dataSource.requestMoreEvents(for: self)
        }
    }

    func didTerminate() {
        eventLoop.execute { [weak self] in
            guard let self, let dataSource = self.dataSource else { return }
            dataSource.cancelBinlog(for: self)
        }
    }
}

/// An `AsyncSequence` of binlog events.
///
/// Unlike a result set this does not end on its own: a blocking dump stays open
/// and delivers events as they are written, indefinitely. Terminate it by
/// breaking out of the loop or cancelling the task, both of which close the
/// connection — a connection that has issued `COM_BINLOG_DUMP` can never be
/// returned to normal command use, which is why binlog takes a dedicated one.
public struct MySQLBinlogSequence: AsyncSequence, Sendable {
    public typealias Element = MySQLBinlogEvent

    let base: MySQLBinlogStreamProducer.Producer

    init(base: MySQLBinlogStreamProducer.Producer) {
        self.base = base
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: MySQLBinlogStreamProducer.Producer.AsyncIterator

        public mutating func next() async throws -> MySQLBinlogEvent? {
            try await iterator.next()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: base.makeAsyncIterator())
    }
}

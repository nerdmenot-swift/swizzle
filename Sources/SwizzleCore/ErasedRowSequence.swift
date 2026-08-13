/// A row sequence with its concrete type forgotten.
///
/// ## Why this exists rather than `any AsyncSequence<SQLRow, any Error>`
///
/// That spelling needs the `Failure` associated type, which is macOS 15. Swizzle
/// targets macOS 14, so the erasure is hand-written.
///
/// ## Why it is not an `AsyncThrowingStream`
///
/// A stream would need a task pumping rows into a buffer, and a buffer is exactly
/// what this library exists to avoid: the driver's whole design is that a slow
/// consumer stops reading from the socket. This erases the *iterator* instead —
/// one closure call per `next()`, forwarded straight to the underlying producer —
/// so demand still travels all the way down. Nothing is read ahead, and a
/// consumer that stops iterating stops the network read.
///
/// The cost is one closure indirection per row, against the generic path's direct
/// call. That is the entire price of not having to name the executor's type.
public struct ErasedRowSequence: AsyncSequence, Sendable {
    public typealias Element = SQLRow

    private let start: @Sendable () -> AsyncIterator

    public init<Source: AsyncSequence & Sendable>(_ source: Source)
    where Source.Element == SQLRow {
        start = {
            // The upstream iterator is a struct and `next()` mutates it, so it
            // needs a stable home the closure can keep mutating across calls.
            let box = IteratorBox(source.makeAsyncIterator())
            return AsyncIterator { try await box.next() }
        }
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let pull: () async throws -> SQLRow?
        public mutating func next() async throws -> SQLRow? { try await pull() }
    }

    public func makeAsyncIterator() -> AsyncIterator { start() }

    /// Holds one upstream iterator.
    ///
    /// `@unchecked Sendable` because an `AsyncSequence` iterator is only ever
    /// touched from the single task that is iterating it — the same contract
    /// every `AsyncIteratorProtocol` already relies on. Iterating one sequence
    /// from two tasks is undefined with or without this box.
    private final class IteratorBox<Upstream: AsyncIteratorProtocol>: @unchecked Sendable
    where Upstream.Element == SQLRow {
        private var iterator: Upstream
        init(_ iterator: Upstream) { self.iterator = iterator }
        func next() async throws -> SQLRow? { try await iterator.next() }
    }
}

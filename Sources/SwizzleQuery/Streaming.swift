import SwizzleCore

/// One decoded row, holding the tuple the projection describes.
///
/// ## Why the tuple is boxed rather than being the `Element` directly
///
/// An `AsyncSequence` whose `Element` is a pack expansion cannot be written:
/// `AsyncIteratorProtocol.next()` returns `Element?`, and
/// `Optional<(repeat each V)>` is rejected with *"pack expansion requires that
/// 'each V' and '(repeat each V)?' have the same shape"*. That is still true on
/// Swift 6.3.
///
/// The blocker is the **optional**, not the pack. Wrapping the tuple in a nominal
/// type makes `Projected<repeat each V>?` an ordinary optional of an ordinary
/// type, and the whole thing compiles and iterates. So streaming gets to look
/// like fetching after all:
///
/// ```swift
/// for row in try await query.fetch(on: db)          { let (id, name) = row }
/// for try await row in query.stream(on: db)         { let (id, name) = row.values }
/// ```
///
/// The `.values` is the entire price, and it buys an ordinary `for try await`
/// over a callback.
public struct Projected<each V>: @unchecked Sendable {
    public let values: (repeat each V)

    public init(_ values: repeat each V) {
        self.values = (repeat each values)
    }
}

/// A stream of decoded rows.
///
/// Decoding happens per row as it arrives, so a result set larger than memory
/// streams in bounded space — the demand signal still reaches the socket,
/// because this wraps the driver's own sequence rather than buffering it.
public struct SQLRowStream<Source: AsyncSequence & Sendable, each V: SQLColumnValue>: AsyncSequence, @unchecked Sendable
where Source.Element == SQLRow {
    public typealias Element = Projected<repeat each V>

    let source: Source

    public struct AsyncIterator: AsyncIteratorProtocol {
        var upstream: Source.AsyncIterator

        public mutating func next() async throws -> Projected<repeat each V>? {
            guard let row = try await upstream.next() else { return nil }
            var index = 0
            return Projected(repeat try Self.decode((each V).self, row, &index))
        }

        private static func decode<T: SQLColumnValue>(
            _ type: T.Type, _ row: SQLRow, _ index: inout Int
        ) throws -> T {
            defer { index += 1 }
            guard index < row.values.count else {
                throw SQLDecodeError(expected: "\(T.self) at column \(index)", actual: .null)
            }
            return try T(sqlValue: row.values[index])
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(upstream: source.makeAsyncIterator())
    }
}

extension SelectQuery {
    /// Streams the query, decoding each row into the projection's tuple.
    ///
    /// The streaming counterpart of ``fetch(on:)``, and deliberately the same
    /// shape: both are `for … in` over typed rows, so moving a query from one to
    /// the other is a one-word change rather than a rewrite into a callback.
    ///
    /// ```swift
    /// for try await row in try await db.select(u.id, u.name).from(u).stream(on: db) {
    ///     let (id, name) = row.values
    /// }
    /// ```
    public func stream<Executor: SQLStreamingExecutor>(
        on executor: Executor
    ) async throws -> SQLRowStream<Executor.RowSequence, repeat each V>
    where Executor.Dialect == D {
        let (sql, bindings) = build()
        return SQLRowStream(source: try await executor.stream(sql: sql, bindings: bindings))
    }
}

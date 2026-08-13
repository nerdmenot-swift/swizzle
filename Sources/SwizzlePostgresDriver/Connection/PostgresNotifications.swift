import NIOConcurrencyHelpers
import NIOCore

/// One `NOTIFY`.
public struct PostgresNotification: Sendable, Equatable {
    /// The backend that sent it. Useful for ignoring your own notifications,
    /// which Postgres delivers to the sender too.
    public let processID: Int32
    public let channel: String
    public let payload: String
}

/// Delivers asynchronous notifications to whoever is listening.
///
/// ## The part that is not obvious
///
/// `NOTIFY` is the only message a Postgres connection receives that nobody asked
/// for. Everything else is a reply. That has two consequences this type exists to
/// handle:
///
/// 1. **An idle connection must keep reading.** The driver runs with
///    `autoRead = false`, so nothing is read unless something asks — and an idle
///    connection asks for nothing. Without a standing read, a `LISTEN` would
///    register successfully and then never deliver anything, which is the worst
///    kind of broken: it looks like it works.
/// 2. **It can arrive mid-statement.** The server sends notifications at message
///    boundaries, which includes boundaries inside a result set, so they cannot
///    be handled only when the connection is idle.
final class PostgresNotificationSink: @unchecked Sendable {
    typealias Continuation = AsyncStream<PostgresNotification>.Continuation

    private let lock = NIOLock()
    private var continuations: [Int: Continuation] = [:]
    private var nextID = 0

    /// Whether anything is listening, and therefore whether the connection needs
    /// to keep a read outstanding while idle.
    var hasListeners: Bool {
        lock.withLock { !continuations.isEmpty }
    }

    func makeStream() -> AsyncStream<PostgresNotification> {
        let (stream, continuation) = AsyncStream.makeStream(of: PostgresNotification.self)
        let id = lock.withLock { () -> Int in
            nextID += 1
            continuations[nextID] = continuation
            return nextID
        }
        continuation.onTermination = { [weak self] _ in
            self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    func deliver(_ notification: PostgresNotification) {
        // A snapshot, so a listener finishing during delivery cannot deadlock on
        // the lock its termination handler wants.
        let targets = lock.withLock { Array(continuations.values) }
        for continuation in targets { continuation.yield(notification) }
    }

    func finish() {
        let targets = lock.withLock { () -> [Continuation] in
            let values = Array(continuations.values)
            continuations.removeAll()
            return values
        }
        for continuation in targets { continuation.finish() }
    }
}

extension PostgresConnection {
    /// Every notification this connection receives, as they arrive.
    ///
    /// Subscribing is not the same as listening: the server only sends
    /// notifications for channels this connection has run `LISTEN` on. Use
    /// ``listen(to:)`` for both halves in one call.
    ///
    /// The sequence ends when the connection closes.
    public var notifications: AsyncStream<PostgresNotification> {
        get async throws {
            try await commandHandler().notificationStream()
        }
    }

    /// Runs `LISTEN` and returns the notifications for that channel.
    ///
    /// The channel name is an identifier, not a value, so it cannot be bound as
    /// a parameter — it is quoted instead. A name containing a `"` would
    /// otherwise close the quoting and inject; doubling it is Postgres's own
    /// escape.
    public func listen(to channel: String) async throws -> AsyncStream<PostgresNotification> {
        let stream = try await commandHandler().notificationStream()
        _ = try await query("LISTEN \(Self.quoteIdentifier(channel))")
        return stream
    }

    public func unlisten(from channel: String) async throws {
        _ = try await query("UNLISTEN \(Self.quoteIdentifier(channel))")
    }

    /// Sends a notification.
    ///
    /// The payload *is* a value and is bound, so it needs no escaping. The
    /// channel is an identifier and is quoted — which is why this uses
    /// `pg_notify` rather than the `NOTIFY` statement: `pg_notify` is a function,
    /// so both arguments can be bound and neither has to be spliced into SQL.
    public func notify(channel: String, payload: String = "") async throws {
        _ = try await query("SELECT pg_notify($1, $2)", [.text(channel), .text(payload)])
    }

    static func quoteIdentifier(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Reaches into the pipeline for the command handler.
    ///
    /// **`syncOperations` must be called on the event loop**, and this is reached
    /// from `async` code that is not on it — so it hops rather than asserting.
    /// Getting this wrong is a `preconditionFailure` inside NIO, not an error: a
    /// hard crash in a public API.
    ///
    /// It survived the handler-level tests because `EmbeddedChannel` runs its
    /// event loop on the calling thread, so `inEventLoop` is always true there.
    /// Only a real socket has a real loop to be off.
    private func commandHandler() async throws -> PostgresCommandHandler {
        let channel = self.channel
        return try await channel.eventLoop.submit {
            try channel.pipeline.syncOperations.handler(type: PostgresCommandHandler.self)
        }.get()
    }
}

import NIOCore
import SwizzleCore

/// The bulk-load path — `COPY`, in both directions.
///
/// ## Why this is not just a faster `INSERT`
///
/// `COPY` bypasses the executor entirely: no parse, no plan, no per-row round
/// trip. For an import it is the difference between a few thousand rows a second
/// and a few hundred thousand. Every serious Postgres tool is built on it —
/// `pg_dump`, `pg_restore`, every ETL loader — and a driver without it forces
/// those workloads through the slowest path it has.
///
/// ## The sub-protocol
///
/// `COPY` suspends the normal query flow. After `CopyInResponse` the *client*
/// speaks until it sends `CopyDone` or `CopyFail`; after `CopyOutResponse` the
/// *server* does. Either way the connection is not answering queries until the
/// mode ends, which is why these take the connection rather than going through
/// the pool's convenience path.
public enum PostgresCopyFormat: Sendable, Equatable {
    /// Tab-separated, `\N` for null. What `COPY … TO STDOUT` gives by default.
    case text
    case csv
    /// Length-prefixed and typed. Faster and lossless, at the cost of a header,
    /// a trailer, and per-column encoding.
    case binary

    var sqlClause: String {
        switch self {
        case .text: "FORMAT text"
        case .csv: "FORMAT csv"
        case .binary: "FORMAT binary"
        }
    }
}

public enum PostgresCopyError: Error, Sendable, Equatable, CustomStringConvertible {
    case notInCopyMode(String)
    case malformedBinaryHeader
    case unexpectedTrailer
    case cancelled(String)

    public var description: String {
        switch self {
        case .notInCopyMode(let got):
            "the server did not enter COPY mode — it sent \(got) instead. The "
                + "statement was probably not a COPY"
        case .malformedBinaryHeader:
            "the binary COPY stream does not begin with the PGCOPY signature"
        case .unexpectedTrailer:
            "the binary COPY stream ended in the middle of a row"
        case .cancelled(let reason):
            "the COPY was cancelled: \(reason)"
        }
    }
}

/// The fixed header every binary `COPY` stream begins with.
///
/// `PGCOPY\n\377\r\n\0` — chosen by Postgres to be mangled visibly by anything
/// that treats the stream as text, so a transfer corrupted by a line-ending
/// conversion fails immediately instead of importing nonsense.
public enum PostgresBinaryCopy {
    public static let signature: [UInt8] = Array("PGCOPY\n".utf8) + [0xFF, 0x0D, 0x0A, 0x00]

    /// Signature, a flags word, and an extension-area length. Both zero today.
    public static func header() -> [UInt8] {
        signature + [0, 0, 0, 0] + [0, 0, 0, 0]
    }

    /// A field count of `-1` marks the end of the data.
    public static let trailer: [UInt8] = [0xFF, 0xFF]

    /// One row: an `Int16` field count, then each field length-prefixed with
    /// `-1` for null.
    public static func encodeRow(_ values: [[UInt8]?]) -> [UInt8] {
        var buffer = ByteBuffer()
        buffer.writeInteger(Int16(values.count))
        for value in values {
            guard let value else {
                buffer.writeInteger(Int32(-1))
                continue
            }
            buffer.writeInteger(Int32(value.count))
            buffer.writeBytes(value)
        }
        return buffer.readBytes(length: buffer.readableBytes) ?? []
    }

    /// Reads the header, returning what remains.
    public static func stripHeader(_ bytes: [UInt8]) throws -> [UInt8] {
        guard bytes.count >= header().count,
              Array(bytes.prefix(signature.count)) == signature
        else { throw PostgresCopyError.malformedBinaryHeader }
        return Array(bytes.dropFirst(header().count))
    }
}

extension PostgresConnection {

    // MARK: - COPY OUT

    /// Runs `COPY … TO STDOUT` and delivers the data as it arrives.
    ///
    /// The chunks are whatever the server sent — `CopyData` boundaries are not
    /// row boundaries, and a row can span two of them — so a caller parsing text
    /// must buffer across chunks rather than assuming a chunk is a line.
    public func copyOut(_ sql: String) async throws -> PostgresCopyOutSequence {
        let promise = channel.eventLoop.makePromise(of: PostgresCopyOutSequence.self)
        let request = PostgresRequest.copyOut(sql: sql, promise)

        guard channel.isActive else {
            let error = PostgresConnectionError.unexpected(during: "a closed connection")
            promise.fail(error)
            throw error
        }
        do {
            try await channel.writeAndFlush(request).get()
        } catch {
            promise.fail(error)
            throw error
        }
        return try await promise.futureResult.get()
    }

    /// Collects a whole `COPY … TO STDOUT` into memory.
    ///
    /// Convenient, and the opposite of the point for anything large — the
    /// streaming form exists because a dump does not fit.
    public func copyOutCollected(_ sql: String) async throws -> [UInt8] {
        var bytes: [UInt8] = []
        for try await chunk in try await copyOut(sql) { bytes.append(contentsOf: chunk) }
        return bytes
    }

    // MARK: - COPY IN

    /// Runs `COPY … FROM STDIN`, feeding it from `body`.
    ///
    /// The writer hands chunks to the server as they are produced, so an import
    /// larger than memory streams. `body` throwing sends `CopyFail`, which makes
    /// the server abort the copy and roll back its part — the alternative,
    /// `CopyDone`, would commit a half-written import.
    @discardableResult
    public func copyIn(
        _ sql: String,
        _ body: (PostgresCopyWriter) async throws -> Void
    ) async throws -> Int {
        let started = channel.eventLoop.makePromise(of: Void.self)
        let finished = channel.eventLoop.makePromise(of: PostgresQueryResult.self)
        let request = PostgresRequest.copyIn(sql: sql, started: started, finished: finished)

        guard channel.isActive else {
            let error = PostgresConnectionError.unexpected(during: "a closed connection")
            started.fail(error)
            finished.fail(error)
            throw error
        }
        do {
            try await channel.writeAndFlush(request).get()
        } catch {
            started.fail(error)
            finished.fail(error)
            throw error
        }

        try await started.futureResult.get()

        let writer = PostgresCopyWriter(channel: channel)
        do {
            try await body(writer)
        } catch {
            // `CopyFail` rather than `CopyDone`: the server discards everything
            // it has taken so far. Finishing a partial import cleanly is the one
            // outcome nobody wants.
            try? await channel.writeAndFlush(
                PostgresRequest.copyFail(reason: String(describing: error))
            ).get()
            _ = try? await finished.futureResult.get()
            throw error
        }

        try await channel.writeAndFlush(PostgresRequest.copyDone).get()
        return try await finished.futureResult.get().affectedRows ?? 0
    }

    /// `COPY … FROM STDIN WITH (FORMAT binary)`, with rows encoded for you.
    ///
    /// The header and trailer are written here because forgetting either is a
    /// server-side error with a message that does not mention them.
    @discardableResult
    public func copyInBinary(
        _ sql: String,
        rows: some Sequence<[[UInt8]?]> & Sendable
    ) async throws -> Int {
        try await copyIn(sql) { writer in
            try await writer.write(PostgresBinaryCopy.header())
            for row in rows {
                try await writer.write(PostgresBinaryCopy.encodeRow(row))
            }
            try await writer.write(PostgresBinaryCopy.trailer)
        }
    }
}

/// Feeds a `COPY … FROM STDIN`.
public struct PostgresCopyWriter: Sendable {
    let channel: any Channel

    /// Sends a chunk.
    ///
    /// Awaiting the write is what applies backpressure: a producer faster than
    /// the socket is held here rather than filling an unbounded queue, which for
    /// an import bigger than memory is the difference between working and not.
    public func write(_ bytes: [UInt8]) async throws {
        guard !bytes.isEmpty else { return }
        try await channel.writeAndFlush(PostgresRequest.copyData(bytes)).get()
    }

    /// Sends one row of a text-format copy, tab-separated with `\N` for null.
    ///
    /// The escaping is the part worth not hand-rolling: a literal tab, newline or
    /// backslash in a value would otherwise end the field or the row, silently
    /// shifting every column after it.
    public func writeTextRow(_ values: [String?]) async throws {
        let line = values.map { value -> String in
            guard let value else { return "\\N" }
            return value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\t", with: "\\t")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
        }.joined(separator: "\t")
        try await write(Array((line + "\n").utf8))
    }
}

/// The chunks of a `COPY … TO STDOUT`.
public struct PostgresCopyOutSequence: AsyncSequence, Sendable {
    public typealias Element = [UInt8]

    let base: AsyncThrowingStream<[UInt8], any Error>

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator())
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: AsyncThrowingStream<[UInt8], any Error>.AsyncIterator

        public mutating func next() async throws -> [UInt8]? {
            try await base.next()
        }
    }
}

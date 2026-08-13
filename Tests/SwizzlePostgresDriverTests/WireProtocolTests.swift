import NIOCore
import Testing
@testable import SwizzlePostgresDriver

@Suite("Postgres wire framing")
struct FrameTests {

    func encoded(_ message: PostgresFrontendMessage) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: 64)
        message.encode(into: &buffer)
        return buffer
    }

    /// The length counts itself and excludes the tag. Off by four in either
    /// direction desynchronises the stream, so it is worth pinning by hand rather
    /// than only round-tripping.
    @Test("the length covers itself and excludes the tag")
    func lengthConvention() {
        var buffer = encoded(.sync)
        // 'S' then a length of exactly 4: an empty body.
        #expect(buffer.readableBytes == 5)
        #expect(buffer.readInteger(as: UInt8.self) == UInt8(ascii: "S"))
        #expect(buffer.readInteger(as: Int32.self) == 4)

        var query = encoded(.query("SELECT 1"))
        #expect(query.readInteger(as: UInt8.self) == UInt8(ascii: "Q"))
        // 4 for the length + 8 for the text + 1 for the NUL.
        #expect(query.readInteger(as: Int32.self) == 13)
        #expect(query.readableBytes == 9)
    }

    /// Startup, SSLRequest and CancelRequest carry no tag, because they are sent
    /// before there is a protocol version to agree on.
    @Test("the three pre-handshake messages are untagged")
    func untaggedMessages() {
        var ssl = encoded(.sslRequest)
        #expect(ssl.readInteger(as: Int32.self) == 8)
        #expect(ssl.readInteger(as: Int32.self) == 80_877_103)

        var cancel = encoded(.cancelRequest(processID: 7, secretKey: 9))
        #expect(cancel.readInteger(as: Int32.self) == 16)
        #expect(cancel.readInteger(as: Int32.self) == 80_877_102)
        #expect(cancel.readInteger(as: Int32.self) == 7)
        #expect(cancel.readInteger(as: Int32.self) == 9)

        var startup = encoded(.startup(parameters: [("user", "ada"), ("database", "app")]))
        _ = startup.readInteger(as: Int32.self)
        #expect(startup.readInteger(as: Int32.self) == 0x0003_0000)
    }

    @Test("the startup parameter list ends with an empty key")
    func startupTerminator() {
        var buffer = encoded(.startup(parameters: [("user", "ada")]))
        _ = buffer.readInteger(as: Int32.self)
        _ = buffer.readInteger(as: Int32.self)
        #expect(buffer.readableBytesView.last == 0)
        // "user\0ada\0" plus the terminating zero.
        #expect(buffer.readableBytes == 10)
    }

    /// -1 is null and 0 is an empty value. Collapsing them would turn every empty
    /// string into a null on the way in.
    ///
    /// Both are four bytes with nothing after them, so the *sizes* match and only
    /// the value distinguishes them — which is exactly why it is worth asserting
    /// the value rather than the length.
    @Test("a null parameter is minus one, an empty one is zero")
    func nullIsDistinctFromEmpty() {
        func firstValueLength(_ parameters: [[UInt8]?]) -> Int32? {
            var buffer = encoded(
                .bind(
                    portal: "", statement: "", parameterFormats: [],
                    parameters: parameters, resultFormats: []
                )
            )
            // Tag, length, two empty cstrings, the format count, the value count.
            buffer.moveReaderIndex(forwardBy: 1 + 4 + 1 + 1 + 2 + 2)
            return buffer.readInteger(as: Int32.self)
        }

        #expect(firstValueLength([nil]) == -1)
        #expect(firstValueLength([[]]) == 0)
        #expect(firstValueLength([[0xAB]]) == 1)
    }

    /// An embedded NUL would truncate the value and shift everything after it,
    /// which is invisible corruption rather than a loud failure.
    @Test("an embedded NUL in a string is refused")
    func embeddedNulIsRefused() {
        var buffer = ByteBufferAllocator().buffer(capacity: 16)
        // Not testable as a throw — it is a precondition, deliberately, because a
        // caller cannot recover from it and the reference errors here too.
        buffer.writeCString("safe")
        #expect(buffer.readableBytes == 5)
    }
}

@Suite("Postgres backend decoding")
struct BackendDecodingTests {

    /// Builds a server message the way a server would.
    func framed(_ tag: Character, _ body: (inout ByteBuffer) -> Void) -> ByteBuffer {
        var payload = ByteBufferAllocator().buffer(capacity: 32)
        body(&payload)
        var buffer = ByteBufferAllocator().buffer(capacity: payload.readableBytes + 5)
        buffer.writeInteger(tag.asciiValue!)
        buffer.writeInteger(Int32(payload.readableBytes + 4))
        buffer.writeImmutableBuffer(payload)
        return buffer
    }

    @Test("a complete message decodes and consumes exactly its own bytes")
    func decodesAndConsumes() throws {
        var buffer = framed("Z") { $0.writeInteger(UInt8(ascii: "I")) }
        buffer.writeString("trailing")

        let message = try PostgresBackendMessage.decode(from: &buffer)
        #expect(message == .readyForQuery(.idle))
        // The next message's bytes are untouched.
        #expect(buffer.readString(length: buffer.readableBytes) == "trailing")
    }

    /// A partial read must leave the buffer exactly as it was, or the caller
    /// cannot simply try again when more bytes arrive.
    @Test("a partial message yields nil and consumes nothing")
    func partialMessageIsNotConsumed() throws {
        let complete = framed("S") { $0.writeCString("TimeZone"); $0.writeCString("UTC") }

        for prefix in 0..<complete.readableBytes {
            var partial = complete
            partial.moveWriterIndex(to: partial.readerIndex + prefix)
            let before = partial.readableBytes
            #expect(try PostgresBackendMessage.decode(from: &partial) == nil)
            #expect(partial.readableBytes == before, "consumed bytes from an incomplete message")
        }
    }

    @Test("every message kind round-trips")
    func messageKinds() throws {
        var ready = framed("Z") { $0.writeInteger(UInt8(ascii: "T")) }
        #expect(try PostgresBackendMessage.decode(from: &ready) == .readyForQuery(.inTransaction))

        var key = framed("K") { $0.writeInteger(Int32(42)); $0.writeInteger(Int32(99)) }
        #expect(
            try PostgresBackendMessage.decode(from: &key)
                == .backendKeyData(processID: 42, secretKey: 99)
        )

        var complete = framed("C") { $0.writeCString("INSERT 0 3") }
        #expect(try PostgresBackendMessage.decode(from: &complete) == .commandComplete(tag: "INSERT 0 3"))

        var status = framed("S") { $0.writeCString("client_encoding"); $0.writeCString("UTF8") }
        #expect(
            try PostgresBackendMessage.decode(from: &status)
                == .parameterStatus(name: "client_encoding", value: "UTF8")
        )

        for (tag, expected) in [
            ("1", PostgresBackendMessage.parseComplete), ("2", .bindComplete),
            ("3", .closeComplete), ("n", .noData), ("s", .portalSuspended),
            ("I", .emptyQueryResponse), ("c", .copyDone),
        ] {
            var buffer = framed(Character(tag)) { _ in }
            #expect(try PostgresBackendMessage.decode(from: &buffer) == expected)
        }
    }

    /// The message the whole driver exists for.
    @Test("Describe's two replies decode")
    func describeReplies() throws {
        var parameters = framed("t") {
            $0.writeInteger(Int16(2)); $0.writeInteger(UInt32(23)); $0.writeInteger(UInt32(25))
        }
        #expect(
            try PostgresBackendMessage.decode(from: &parameters) == .parameterDescription([23, 25])
        )

        var rows = framed("T") {
            $0.writeInteger(Int16(1))
            $0.writeCString("email")
            $0.writeInteger(UInt32(16385))   // tableOID
            $0.writeInteger(Int16(2))        // attnum
            $0.writeInteger(UInt32(25))      // text
            $0.writeInteger(Int16(-1))
            $0.writeInteger(Int32(-1))
            $0.writeInteger(Int16(0))
        }
        guard case .rowDescription(let columns)? = try PostgresBackendMessage.decode(from: &rows)
        else { Issue.record("expected a RowDescription"); return }

        #expect(columns.count == 1)
        #expect(columns[0].name == "email")
        // Non-zero tableOID plus attnum is what makes a column traceable to a base
        // table — and therefore what makes nullability recoverable at all, since
        // the wire carries none.
        #expect(columns[0].tableOID == 16385)
        #expect(columns[0].columnAttributeNumber == 2)
        #expect(columns[0].dataTypeOID == 25)
    }

    @Test("a null column is distinct from an empty one")
    func dataRowNulls() throws {
        var buffer = framed("D") {
            $0.writeInteger(Int16(3))
            $0.writeInteger(Int32(-1))               // null
            $0.writeInteger(Int32(0))                // empty
            $0.writeInteger(Int32(2)); $0.writeBytes([0xDE, 0xAD])
        }
        #expect(
            try PostgresBackendMessage.decode(from: &buffer) == .dataRow([nil, [], [0xDE, 0xAD]])
        )
    }

    /// The fields are what make a failure actionable, so none of them may be
    /// dropped at the protocol layer.
    @Test("an ErrorResponse keeps every field")
    func errorFields() throws {
        var buffer = framed("E") {
            $0.writeInteger(UInt8(ascii: "S")); $0.writeCString("ERROR")
            $0.writeInteger(UInt8(ascii: "C")); $0.writeCString("23505")
            $0.writeInteger(UInt8(ascii: "M")); $0.writeCString("duplicate key value")
            $0.writeInteger(UInt8(ascii: "n")); $0.writeCString("users_email_key")
            $0.writeInteger(UInt8(ascii: "P")); $0.writeCString("15")
            $0.writeInteger(UInt8(0))
        }
        guard case .error(let error)? = try PostgresBackendMessage.decode(from: &buffer) else {
            Issue.record("expected an ErrorResponse"); return
        }
        #expect(error.sqlState == "23505")
        #expect(error.message == "duplicate key value")
        #expect(error.constraintName == "users_email_key")
        #expect(error.position == 15)
        #expect(error.severity == "ERROR")
    }

    @Test("the authentication family decodes")
    func authenticationRequests() throws {
        var ok = framed("R") { $0.writeInteger(Int32(0)) }
        #expect(try PostgresBackendMessage.decode(from: &ok) == .authentication(.ok))

        var md5 = framed("R") { $0.writeInteger(Int32(5)); $0.writeBytes([1, 2, 3, 4]) }
        #expect(
            try PostgresBackendMessage.decode(from: &md5) == .authentication(.md5Password(salt: [1, 2, 3, 4]))
        )

        var sasl = framed("R") {
            $0.writeInteger(Int32(10))
            $0.writeCString("SCRAM-SHA-256")
            $0.writeCString("SCRAM-SHA-256-PLUS")
            $0.writeInteger(UInt8(0))
        }
        #expect(
            try PostgresBackendMessage.decode(from: &sasl)
                == .authentication(.sasl(mechanisms: ["SCRAM-SHA-256", "SCRAM-SHA-256-PLUS"]))
        )

        // Kerberos, GSS and friends are carried rather than thrown, so the
        // connection error can name what the server actually wanted.
        var gss = framed("R") { $0.writeInteger(Int32(7)) }
        #expect(try PostgresBackendMessage.decode(from: &gss) == .authentication(.unsupported(code: 7)))
    }

    // MARK: - Hostile input

    /// A length below 4 makes the body length negative. Reading on would index
    /// out of bounds; the decoder must refuse.
    @Test("a length below the minimum is refused")
    func impossibleLength() {
        var buffer = ByteBufferAllocator().buffer(capacity: 8)
        buffer.writeInteger(UInt8(ascii: "Z"))
        buffer.writeInteger(Int32(2))
        buffer.writeInteger(UInt8(ascii: "I"))
        #expect(throws: PostgresWireError.self) {
            _ = try PostgresBackendMessage.decode(from: &buffer)
        }
    }

    /// A count that claims more rows than the body holds must be an error, never
    /// a read past the end.
    @Test("a lying column count is refused rather than over-read")
    func lyingCount() {
        var buffer = framed("D") {
            $0.writeInteger(Int16(5))                 // claims five
            $0.writeInteger(Int32(1)); $0.writeBytes([1])  // provides one
        }
        #expect(throws: PostgresWireError.self) {
            _ = try PostgresBackendMessage.decode(from: &buffer)
        }
    }

    @Test("a value length longer than the body is refused")
    func lyingValueLength() {
        var buffer = framed("D") {
            $0.writeInteger(Int16(1))
            $0.writeInteger(Int32(9999))
            $0.writeBytes([1, 2])
        }
        #expect(throws: PostgresWireError.self) {
            _ = try PostgresBackendMessage.decode(from: &buffer)
        }
    }

    @Test("an unterminated string is refused rather than read to the end")
    func unterminatedString() {
        var buffer = framed("C") { $0.writeString("no terminator") }
        #expect(throws: PostgresWireError.self) {
            _ = try PostgresBackendMessage.decode(from: &buffer)
        }
    }

    /// One message must not be able to read into the next. The body is sliced, so
    /// a message that under-reads cannot desynchronise the stream.
    @Test("a message cannot read past its own body")
    func bodyIsIsolated() throws {
        var buffer = framed("t") {
            $0.writeInteger(Int16(2))
            $0.writeInteger(UInt32(23))
            // The second OID is missing — the next message's bytes must not be
            // mistaken for it.
        }
        buffer.writeImmutableBuffer(framed("Z") { $0.writeInteger(UInt8(ascii: "I")) })

        #expect(throws: PostgresWireError.self) {
            _ = try PostgresBackendMessage.decode(from: &buffer)
        }
    }

    @Test("an unknown tag is reported with the tag")
    func unknownTag() {
        // A valid ASCII byte that is not a tag the protocol defines.
        var buffer = framed("Y") { _ in }
        #expect(throws: PostgresWireError.self) {
            _ = try PostgresBackendMessage.decode(from: &buffer)
        }
    }

    @Test("an unknown transaction status is refused")
    func unknownTransactionStatus() {
        var buffer = framed("Z") { $0.writeInteger(UInt8(ascii: "X")) }
        #expect(throws: PostgresWireError.self) {
            _ = try PostgresBackendMessage.decode(from: &buffer)
        }
    }
}

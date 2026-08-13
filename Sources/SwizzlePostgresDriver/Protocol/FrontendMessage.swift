import NIOCore

/// Messages the client sends.
///
/// ## Framing
///
/// Every message is a one-byte tag, then a big-endian `Int32` length, then the
/// body. The length **includes its own four bytes and excludes the tag**, which
/// is the detail worth stating plainly because it is off-by-four in both
/// directions if you assume otherwise.
///
/// Three messages have no tag at all — `StartupMessage`, `SSLRequest` and
/// `CancelRequest` — because they are sent before the connection has a protocol
/// version to agree on. They are length-prefixed the same way, and the first
/// `Int32` of the body says which one it is.
///
/// Simpler than MySQL's framing in every respect: no sequence IDs to keep in
/// step, no 16 MiB splitting, no `max_allowed_packet` to bound reassembly
/// against. Confirmed against `postgres-protocol/src/message/frontend.rs`.
public enum PostgresFrontendMessage: Sendable, Equatable {
    case startup(parameters: [(String, String)])
    case sslRequest
    case cancelRequest(processID: Int32, secretKey: Int32)

    case password(String)
    case saslInitialResponse(mechanism: String, data: [UInt8]?)
    case saslResponse([UInt8])

    case query(String)

    case parse(name: String, query: String, parameterTypes: [UInt32])
    case bind(
        portal: String, statement: String,
        parameterFormats: [Int16], parameters: [[UInt8]?], resultFormats: [Int16]
    )
    case describe(PostgresTargetKind, name: String)
    case execute(portal: String, maxRows: Int32)
    case close(PostgresTargetKind, name: String)
    case flush
    case sync

    case copyData([UInt8])
    case copyDone
    case copyFail(String)

    case terminate

    public static func == (lhs: Self, rhs: Self) -> Bool {
        var left = ByteBufferAllocator().buffer(capacity: 64)
        var right = ByteBufferAllocator().buffer(capacity: 64)
        lhs.encode(into: &left)
        rhs.encode(into: &right)
        return left == right
    }
}

/// Whether a `Describe` or `Close` names a prepared statement or a portal.
public enum PostgresTargetKind: UInt8, Sendable, Equatable {
    case statement = 0x53  // 'S'
    case portal = 0x50     // 'P'
}

extension PostgresFrontendMessage {
    /// Protocol version 3.0, as the startup message spells it.
    static let protocolVersion: Int32 = 0x0003_0000
    /// The magic version numbers that mark the two untagged requests.
    static let sslRequestCode: Int32 = 80_877_103
    static let cancelRequestCode: Int32 = 80_877_102

    public func encode(into buffer: inout ByteBuffer) {
        switch self {
        case .startup(let parameters):
            writeUntagged(&buffer) { body in
                body.writeInteger(Self.protocolVersion)
                for (key, value) in parameters {
                    body.writeCString(key)
                    body.writeCString(value)
                }
                // The empty key that ends the list.
                body.writeInteger(UInt8(0))
            }

        case .sslRequest:
            writeUntagged(&buffer) { $0.writeInteger(Self.sslRequestCode) }

        case .cancelRequest(let processID, let secretKey):
            writeUntagged(&buffer) { body in
                body.writeInteger(Self.cancelRequestCode)
                body.writeInteger(processID)
                body.writeInteger(secretKey)
            }

        case .password(let password):
            writeTagged(&buffer, "p") { $0.writeCString(password) }

        case .saslInitialResponse(let mechanism, let data):
            writeTagged(&buffer, "p") { body in
                body.writeCString(mechanism)
                if let data {
                    body.writeInteger(Int32(data.count))
                    body.writeBytes(data)
                } else {
                    // -1 means "no initial response", which is distinct from an
                    // empty one and the server treats differently.
                    body.writeInteger(Int32(-1))
                }
            }

        case .saslResponse(let data):
            writeTagged(&buffer, "p") { $0.writeBytes(data) }

        case .query(let sql):
            writeTagged(&buffer, "Q") { $0.writeCString(sql) }

        case .parse(let name, let query, let parameterTypes):
            writeTagged(&buffer, "P") { body in
                body.writeCString(name)
                body.writeCString(query)
                body.writeInteger(Int16(parameterTypes.count))
                for oid in parameterTypes { body.writeInteger(oid) }
            }

        case .bind(let portal, let statement, let parameterFormats, let parameters, let resultFormats):
            writeTagged(&buffer, "B") { body in
                body.writeCString(portal)
                body.writeCString(statement)
                body.writeInteger(Int16(parameterFormats.count))
                for format in parameterFormats { body.writeInteger(format) }
                body.writeInteger(Int16(parameters.count))
                for parameter in parameters {
                    guard let parameter else {
                        // -1 is null. Zero would be an empty value, which is a
                        // different thing entirely.
                        body.writeInteger(Int32(-1))
                        continue
                    }
                    body.writeInteger(Int32(parameter.count))
                    body.writeBytes(parameter)
                }
                body.writeInteger(Int16(resultFormats.count))
                for format in resultFormats { body.writeInteger(format) }
            }

        case .describe(let kind, let name):
            writeTagged(&buffer, "D") { body in
                body.writeInteger(kind.rawValue)
                body.writeCString(name)
            }

        case .execute(let portal, let maxRows):
            writeTagged(&buffer, "E") { body in
                body.writeCString(portal)
                // 0 means "all rows"; anything else suspends the portal, which is
                // Postgres's row-bounded fetch.
                body.writeInteger(maxRows)
            }

        case .close(let kind, let name):
            writeTagged(&buffer, "C") { body in
                body.writeInteger(kind.rawValue)
                body.writeCString(name)
            }

        case .flush:
            writeTagged(&buffer, "H") { _ in }

        case .sync:
            writeTagged(&buffer, "S") { _ in }

        case .copyData(let bytes):
            writeTagged(&buffer, "d") { $0.writeBytes(bytes) }

        case .copyDone:
            writeTagged(&buffer, "c") { _ in }

        case .copyFail(let reason):
            writeTagged(&buffer, "f") { $0.writeCString(reason) }

        case .terminate:
            writeTagged(&buffer, "X") { _ in }
        }
    }

    /// Writes the tag, reserves the length, writes the body, then backfills.
    ///
    /// Reserving and backfilling rather than encoding the body separately: it
    /// avoids a second allocation per message, and the length can only be wrong
    /// if the arithmetic here is, rather than at seventeen call sites.
    private func writeTagged(
        _ buffer: inout ByteBuffer, _ tag: Character, _ body: (inout ByteBuffer) -> Void
    ) {
        buffer.writeInteger(tag.asciiValue!)
        writeUntagged(&buffer, body)
    }

    private func writeUntagged(
        _ buffer: inout ByteBuffer, _ body: (inout ByteBuffer) -> Void
    ) {
        let lengthIndex = buffer.writerIndex
        buffer.writeInteger(Int32(0))
        body(&buffer)
        // The length covers itself and the body, and excludes the tag.
        let length = Int32(buffer.writerIndex - lengthIndex)
        buffer.setInteger(length, at: lengthIndex)
    }
}

extension ByteBuffer {
    /// A NUL-terminated string.
    ///
    /// An embedded NUL would silently truncate the value and shift everything
    /// after it, so it is refused rather than written — the same call the
    /// reference makes, and the reason is that the corruption is invisible.
    mutating func writeCString(_ value: String) {
        precondition(
            !value.utf8.contains(0),
            "a Postgres string cannot contain an embedded NUL: \(value.debugDescription)"
        )
        writeString(value)
        writeInteger(UInt8(0))
    }
}

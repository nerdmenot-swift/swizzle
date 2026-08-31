import NIOCore

/// MySQL's length-encoded integer and string primitives.
///
/// These are the load-bearing encoding of the entire protocol — every packet
/// body, every result row, every column definition is built from them — so they
/// get their own file and exhaustive tests.
extension ByteBuffer {
    /// Length-encoded integer.
    ///
    /// - `< 0xFB` — the byte itself
    /// - `0xFB`   — NULL (only meaningful inside a text-protocol row)
    /// - `0xFC`   — 2-byte little-endian follows
    /// - `0xFD`   — 3-byte little-endian follows
    /// - `0xFE`   — 8-byte little-endian follows
    /// - `0xFF`   — never valid here; it marks an ERR packet
    ///
    /// Returns `nil` if the buffer is truncated, leaving the reader index
    /// untouched so a partial read can be retried when more bytes arrive.
    public mutating func readLengthEncodedInteger() -> UInt64? {
        let save = readerIndex
        guard let first = readInteger(endianness: .little, as: UInt8.self) else { return nil }

        switch first {
        case 0xFB, 0xFF:
            moveReaderIndex(to: save)
            return nil
        case 0xFC:
            guard let v = readInteger(endianness: .little, as: UInt16.self) else {
                moveReaderIndex(to: save)
                return nil
            }
            return UInt64(v)
        case 0xFD:
            guard let bytes = readBytes(length: 3) else {
                moveReaderIndex(to: save)
                return nil
            }
            return UInt64(bytes[0]) | (UInt64(bytes[1]) << 8) | (UInt64(bytes[2]) << 16)
        case 0xFE:
            guard let v = readInteger(endianness: .little, as: UInt64.self) else {
                moveReaderIndex(to: save)
                return nil
            }
            return v
        default:
            return UInt64(first)
        }
    }

    /// Distinguishes a genuine NULL (`0xFB`) from a truncated read, which
    /// `readLengthEncodedInteger` collapses into the same `nil`.
    public mutating func readLengthEncodedIntegerOrNull() -> UInt64?? {
        guard let first = getInteger(at: readerIndex, as: UInt8.self) else { return nil }
        if first == 0xFB {
            moveReaderIndex(forwardBy: 1)
            return .some(nil)
        }
        guard let value = readLengthEncodedInteger() else { return nil }
        return .some(value)
    }

    public mutating func writeLengthEncodedInteger(_ value: UInt64) {
        switch value {
        case ..<0xFB:
            writeInteger(UInt8(value), endianness: .little)
        case ..<0x1_0000:
            writeInteger(UInt8(0xFC), endianness: .little)
            writeInteger(UInt16(value), endianness: .little)
        case ..<0x100_0000:
            writeInteger(UInt8(0xFD), endianness: .little)
            writeInteger(UInt8(value & 0xFF), endianness: .little)
            writeInteger(UInt8((value >> 8) & 0xFF), endianness: .little)
            writeInteger(UInt8((value >> 16) & 0xFF), endianness: .little)
        default:
            writeInteger(UInt8(0xFE), endianness: .little)
            writeInteger(value, endianness: .little)
        }
    }

    /// Length-encoded string: a length-encoded integer followed by that many bytes.
    ///
    /// The length is bounded before it becomes an `Int`, and that guard is not
    /// theoretical: `Int(someUInt64)` **traps** above `Int64.max`, and a
    /// length-encoded integer is eight bytes of whatever the peer sent. A packet
    /// beginning `0xFE` followed by eight high bytes took the process down —
    /// found by fuzzing this decoder with random bytes, which is the only kind of
    /// test that reaches it, because a well-behaved server never sends one.
    ///
    /// Every length-encoded string in the protocol comes through here — column
    /// names, values, the lot — so this was reachable from any packet on any
    /// connection.
    ///
    /// Checked against `readableBytes` rather than against `Int.max`: a length
    /// longer than the buffer is malformed regardless, so the narrower bound is
    /// both safe and more honest about what is wrong.
    public mutating func readLengthEncodedSlice() -> ByteBuffer? {
        let save = readerIndex
        guard let length = readLengthEncodedInteger(),
              length <= UInt64(readableBytes),
              let slice = readSlice(length: Int(length))
        else {
            moveReaderIndex(to: save)
            return nil
        }
        return slice
    }

    public mutating func readLengthEncodedString() -> String? {
        guard var slice = readLengthEncodedSlice() else { return nil }
        return slice.readString(length: slice.readableBytes)
    }

    public mutating func writeLengthEncodedSlice(_ buffer: ByteBuffer) {
        writeLengthEncodedInteger(UInt64(buffer.readableBytes))
        var copy = buffer
        writeBuffer(&copy)
    }

    public mutating func writeLengthEncodedString(_ string: String) {
        let bytes = Array(string.utf8)
        writeLengthEncodedInteger(UInt64(bytes.count))
        writeBytes(bytes)
    }

}

// Null-terminated strings come from NIOCore (`readNullTerminatedString` /
// `writeNullTerminatedString`). Its reader already returns nil when no
// terminator is present, which is the behaviour the handshake parser relies on
// to reject truncated greetings — see the test that pins that contract.

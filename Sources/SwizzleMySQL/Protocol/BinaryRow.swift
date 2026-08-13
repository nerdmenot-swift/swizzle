import NIOCore

/// The NULL bitmap used by the binary protocol.
///
/// Two things make this easy to get wrong, and both are silent when wrong:
/// the bit offset differs by direction, and the byte length depends on that
/// same offset.
///
/// - **Server side** (result-set rows we receive): offset **2**. The first two
///   bits are reserved, so column 0 is bit 2.
/// - **Client side** (parameters we send in `COM_STMT_EXECUTE`): offset **0**.
///
/// Verified against rust-mysql-common's `NullBitmap` and its
/// `ServerSide`/`ClientSide` marker types.
public struct MySQLNullBitmap: Sendable, Equatable {
    public enum Side: Sendable {
        case server
        case client

        var bitOffset: Int { self == .server ? 2 : 0 }
    }

    public let side: Side
    public let columnCount: Int
    public private(set) var bytes: [UInt8]

    public static func byteCount(columnCount: Int, side: Side) -> Int {
        (columnCount + 7 + side.bitOffset) / 8
    }

    public init(columnCount: Int, side: Side) {
        self.side = side
        self.columnCount = columnCount
        self.bytes = [UInt8](repeating: 0, count: Self.byteCount(columnCount: columnCount, side: side))
    }

    public init(bytes: [UInt8], columnCount: Int, side: Side) {
        self.side = side
        self.columnCount = columnCount
        self.bytes = bytes
    }

    public static func read(
        from buffer: inout ByteBuffer, columnCount: Int, side: Side
    ) throws -> MySQLNullBitmap {
        let length = byteCount(columnCount: columnCount, side: side)
        guard let bytes = buffer.readBytes(length: length) else {
            throw MySQLProtocolError.malformedPacket("truncated NULL bitmap")
        }
        return MySQLNullBitmap(bytes: bytes, columnCount: columnCount, side: side)
    }

    public func isNull(_ columnIndex: Int) -> Bool {
        let offset = columnIndex + side.bitOffset
        let byte = offset / 8
        guard byte < bytes.count else { return false }
        return bytes[byte] & (1 << UInt8(offset % 8)) != 0
    }

    public mutating func setNull(_ columnIndex: Int) {
        let offset = columnIndex + side.bitOffset
        let byte = offset / 8
        guard byte < bytes.count else { return }
        bytes[byte] |= (1 << UInt8(offset % 8))
    }
}

/// One row of the binary protocol, as returned by `COM_STMT_EXECUTE`.
///
/// Layout: a `0x00` header, then the NULL bitmap, then the non-NULL values in
/// column order. NULL columns occupy no bytes at all — which is why a
/// mis-parsed bitmap corrupts every value after it rather than just one.
public struct MySQLBinaryRow: Sendable, Equatable {
    public var values: [MySQLValue]

    public init(values: [MySQLValue]) { self.values = values }

    public static func parse(
        _ buffer: inout ByteBuffer, columns: [MySQLColumnDefinition]
    ) throws -> MySQLBinaryRow {
        guard let header = buffer.readInteger(endianness: .little, as: UInt8.self),
              header == 0x00
        else {
            throw MySQLProtocolError.malformedPacket("binary row: expected 0x00 header")
        }

        let bitmap = try MySQLNullBitmap.read(
            from: &buffer, columnCount: columns.count, side: .server
        )

        var values: [MySQLValue] = []
        values.reserveCapacity(columns.count)
        for (index, column) in columns.enumerated() {
            if bitmap.isNull(index) {
                values.append(.null)
                continue
            }
            values.append(
                try MySQLValue.decodeBinary(
                    &buffer,
                    type: MySQLColumnType(rawValueOrUnknown: column.type),
                    flags: column.flags
                )
            )
        }
        return MySQLBinaryRow(values: values)
    }
}

// Typed access lives on `MySQLRow` (see Row.swift) and `MySQLQueryResult`.
// Rows are decoded as they are parsed, so there is no separate decode step.

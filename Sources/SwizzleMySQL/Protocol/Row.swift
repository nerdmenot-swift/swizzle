import NIOCore

/// The column layout of a result set, shared by every row in it.
///
/// This exists so name lookup is not a linear scan. It used to be: each row
/// carried the column array and `row["name"]` searched it, comparing strings
/// until it hit a match. On a five-column table that is invisible. On a wide one
/// it is not — and reading *every* column by name, which is exactly what mapping
/// a row onto a model does, made the cost quadratic in the table's width. On a
/// 60-column table it cost more to read 10,000 rows by name than to decode them
/// off the wire in the first place.
///
/// One schema per result set, referenced by every row, so the map is built once
/// per query rather than searched once per access.
public final class MySQLRowSchema: Sendable {
    public let columns: [MySQLColumnDefinition]
    private let indexByName: [String: Int]

    public init(_ columns: [MySQLColumnDefinition]) {
        self.columns = columns
        // SQL permits duplicate column names in one result set — `SELECT a.id,
        // b.id FROM a JOIN b` yields two columns called `id`. A linear search
        // returns the first, so the map must too: `updateValue` would keep the
        // last, which would silently change which column a caller reads.
        var map = [String: Int](minimumCapacity: columns.count)
        for (index, column) in columns.enumerated() where map[column.name] == nil {
            map[column.name] = index
        }
        self.indexByName = map
    }

    /// The position of a column, or nil if there is no such column.
    ///
    /// Resolving a name once and then reading by index is the fastest path, and
    /// the one a generated mapper or the query builder should take: it turns a
    /// per-row hash lookup into a per-*query* one.
    public func index(of name: String) -> Int? { indexByName[name] }

    public var isEmpty: Bool { columns.isEmpty }
    public var count: Int { columns.count }
}

/// A decoded result row.
///
/// One type for both wire formats. The text and binary protocols differ
/// completely in encoding but produce the same values, and callers should not
/// have to care which one a query happened to use — a prepared statement and a
/// plain query returning the same data must be indistinguishable here.
public struct MySQLRow: Sendable, Equatable {
    public var values: [MySQLValue]
    /// Shared with every other row of the same result set.
    public var schema: MySQLRowSchema

    public var columns: [MySQLColumnDefinition] { schema.columns }

    public init(values: [MySQLValue], schema: MySQLRowSchema) {
        self.values = values
        self.schema = schema
    }

    /// Builds a one-off schema. Convenient for constructing a row by hand;
    /// decoding a result set should share one schema instead.
    public init(values: [MySQLValue], columns: [MySQLColumnDefinition]) {
        self.init(values: values, schema: MySQLRowSchema(columns))
    }

    /// Two rows are equal when they hold the same values under the same column
    /// names. Schema *identity* is deliberately not part of it: rows decoded
    /// from two separate executions of the same query should compare equal.
    public static func == (lhs: MySQLRow, rhs: MySQLRow) -> Bool {
        lhs.values == rhs.values
            && (lhs.schema === rhs.schema || lhs.columns == rhs.columns)
    }

    public subscript(index: Int) -> MySQLValue {
        index >= 0 && index < values.count ? values[index] : .null
    }

    /// Column lookup by name. Returns nil when there is no such column, which is
    /// distinct from a column that exists and is NULL.
    public subscript(name: String) -> MySQLValue? {
        guard let index = schema.index(of: name), index < values.count else { return nil }
        return values[index]
    }

    public func string(at index: Int) -> String? {
        self[index].string
    }

    public func int(at index: Int) -> Int64? {
        self[index].int
    }

    /// Parses a text-protocol row, decoding each value by its column type.
    static func parseText(
        _ buffer: inout ByteBuffer, schema: MySQLRowSchema
    ) throws -> MySQLRow {
        let columns = schema.columns
        var values: [MySQLValue] = []
        values.reserveCapacity(columns.count)

        for (index, column) in columns.enumerated() {
            guard let marker = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) else {
                throw MySQLProtocolError.malformedPacket("row: truncated at column \(index)")
            }
            if marker == 0xFB {
                buffer.moveReaderIndex(forwardBy: 1)
                values.append(.null)
                continue
            }
            guard let slice = buffer.readLengthEncodedSlice() else {
                throw MySQLProtocolError.malformedPacket("row: truncated value at column \(index)")
            }
            values.append(
                MySQLValue.decodeText(
                    slice,
                    type: MySQLColumnType(rawValueOrUnknown: column.type),
                    flags: column.flags
                )
            )
        }
        return MySQLRow(values: values, schema: schema)
    }

    /// Parses a binary-protocol row: `0x00` header, NULL bitmap, then the
    /// non-NULL values.
    static func parseBinary(
        _ buffer: inout ByteBuffer, schema: MySQLRowSchema
    ) throws -> MySQLRow {
        let binary = try MySQLBinaryRow.parse(&buffer, columns: schema.columns)
        return MySQLRow(values: binary.values, schema: schema)
    }
}

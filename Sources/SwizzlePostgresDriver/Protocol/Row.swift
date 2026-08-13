import SwizzleCore

/// The column layout of a result set, shared by every row in it.
///
/// One schema per result set rather than per row, for the reason the MySQL side
/// documents at length: reading every column by name — which is exactly what
/// mapping a row onto a model does — is quadratic in the table's width if each
/// lookup is a scan.
public final class PostgresRowSchema: Sendable {
    public let columns: [PostgresColumnDescription]
    private let indexByName: [String: Int]

    public init(_ columns: [PostgresColumnDescription]) {
        self.columns = columns
        // SQL permits duplicate column names — `SELECT a.id, b.id FROM a JOIN b`
        // yields two called `id`. A scan returns the first, so the map must too.
        var map = [String: Int](minimumCapacity: columns.count)
        for (index, column) in columns.enumerated() where map[column.name] == nil {
            map[column.name] = index
        }
        self.indexByName = map
    }

    public func index(of name: String) -> Int? { indexByName[name] }
    public var count: Int { columns.count }
    public var isEmpty: Bool { columns.isEmpty }
}

/// A decoded result row.
///
/// Values land as `SQLValue` directly rather than in a Postgres-specific value
/// type. Postgres's binary decoding already produces exactly the cases `SQLValue`
/// has, so an intermediate type would be a rename and a second conversion — the
/// MySQL driver needs `MySQLValue` because its wire types genuinely do not line
/// up, and this one does not.
public struct PostgresRow: Sendable, Equatable {
    public var values: [SQLValue]
    /// Shared with every other row of the same result set.
    public var schema: PostgresRowSchema

    public var columns: [PostgresColumnDescription] { schema.columns }

    public init(values: [SQLValue], schema: PostgresRowSchema) {
        self.values = values
        self.schema = schema
    }

    public init(values: [SQLValue], columns: [PostgresColumnDescription]) {
        self.init(values: values, schema: PostgresRowSchema(columns))
    }

    /// Equal when the same values sit under the same column names. Schema
    /// *identity* is deliberately not part of it, so rows from two executions of
    /// the same query compare equal.
    public static func == (lhs: PostgresRow, rhs: PostgresRow) -> Bool {
        lhs.values == rhs.values
            && (lhs.schema === rhs.schema || lhs.columns == rhs.columns)
    }

    public subscript(index: Int) -> SQLValue {
        index < values.count ? values[index] : .null
    }

    /// Lookup by name. Nil means *there is no such column*, which is a different
    /// answer from a column that exists and holds NULL.
    public subscript(name: String) -> SQLValue? {
        guard let index = schema.index(of: name), index < values.count else { return nil }
        return values[index]
    }

    /// An array column, with its elements.
    ///
    /// Separate from `subscript` because the neutral `SQLValue` has no array
    /// case — it holds the text Postgres would print — and inventing one there
    /// would put a type only Postgres can produce into the vocabulary all three
    /// engines share. Callers that want elements ask for them.
    public func array(at index: Int) -> PostgresArray? {
        guard index < schema.count else { return nil }
        let column = schema.columns[index]
        guard PostgresOID(rawValue: column.dataTypeOID)?.elementType != nil else { return nil }
        switch values[index] {
        case .text(let rendered):
            return PostgresArrayDecoder.decodeText(
                Array(rendered.utf8),
                elementOID: PostgresOID(rawValue: column.dataTypeOID)?.elementType?.rawValue ?? 0
            )
        case .blob(let bytes):
            return PostgresArrayDecoder.decodeBinary(bytes)
        case .null:
            return nil
        default:
            return nil
        }
    }

    public func array(named name: String) -> PostgresArray? {
        guard let index = schema.index(of: name) else { return nil }
        return array(at: index)
    }

    /// The neutral row the executor seams speak in.
    ///
    /// `SQLRow` is positional and carries no names, which is why this is a
    /// projection rather than the storage type: the generated code resolves
    /// columns by index anyway, and dropping the schema here would make
    /// `row["email"]` impossible for anyone hand-writing a query.
    public var sqlRow: SQLRow { SQLRow(values: values) }
}

import NIOCore

/// A Swift type that can be built from a MySQL column value.
///
/// The counterpart to ``MySQLBindable``. Conform your own types to decode them
/// straight out of a row.
public protocol MySQLDecodable: Sendable {
    init(mysqlValue: MySQLValue) throws
}

/// A column could not be read as the requested type.
///
/// Carries the column's position and name because the failure is almost always
/// "I asked for the columns in the wrong order", and a message naming the column
/// says that immediately.
public struct MySQLDecodingError: Error, Sendable, CustomStringConvertible {
    public let column: Int
    public let columnName: String?
    public let expected: String
    public let actual: MySQLValue

    public var description: String {
        let where_ = columnName.map { "column \(column) (\($0))" } ?? "column \(column)"
        return "could not decode \(where_) as \(expected): value was \(actual)"
    }
}

extension MySQLDecodable {
    /// Wraps a failed conversion so it names the column rather than the value.
    static func decode(
        _ value: MySQLValue, column: Int, name: String?
    ) throws -> Self {
        do {
            return try Self(mysqlValue: value)
        } catch let error as MySQLDecodingError {
            throw MySQLDecodingError(
                column: column, columnName: name,
                expected: error.expected, actual: error.actual
            )
        }
    }

    static func mismatch(_ value: MySQLValue) -> MySQLDecodingError {
        MySQLDecodingError(column: 0, columnName: nil, expected: "\(Self.self)", actual: value)
    }
}

// MARK: - Conformances

extension MySQLValue: MySQLDecodable {
    public init(mysqlValue: MySQLValue) throws { self = mysqlValue }
}

/// Integers accept any integral representation the server might have used.
///
/// This is deliberately more forgiving than the wire type alone. The *same
/// column* comes back as `.int` over the binary protocol and as text over
/// `COM_QUERY`, and a `COUNT(*)` is `.uint` on one server and `.int` on another.
/// A decoder that insisted on one representation would make the protocol a
/// caller's problem, which is exactly the leak this library exists to plug.
///
/// What it will *not* do is lose information: a value outside the target's range
/// throws rather than wrapping.
extension FixedWidthInteger where Self: MySQLDecodable {
    public init(mysqlValue value: MySQLValue) throws {
        switch value {
        case .int(let raw):
            guard let converted = Self(exactly: raw) else { throw Self.mismatch(value) }
            self = converted
        case .uint(let raw):
            guard let converted = Self(exactly: raw) else { throw Self.mismatch(value) }
            self = converted
        case .bytes(let bytes):
            // DECIMAL and the text protocol both arrive as digits.
            guard let text = String(bytes: bytes, encoding: .utf8),
                  let converted = Self(text) else { throw Self.mismatch(value) }
            self = converted
        default:
            throw Self.mismatch(value)
        }
    }
}

extension Int: MySQLDecodable {}
extension Int8: MySQLDecodable {}
extension Int16: MySQLDecodable {}
extension Int32: MySQLDecodable {}
extension Int64: MySQLDecodable {}
extension UInt: MySQLDecodable {}
extension UInt8: MySQLDecodable {}
extension UInt16: MySQLDecodable {}
extension UInt32: MySQLDecodable {}
extension UInt64: MySQLDecodable {}

extension String: MySQLDecodable {
    public init(mysqlValue value: MySQLValue) throws {
        guard let text = value.string else { throw Self.mismatch(value) }
        self = text
    }
}

extension Double: MySQLDecodable {
    public init(mysqlValue value: MySQLValue) throws {
        guard let number = value.double else { throw Self.mismatch(value) }
        self = number
    }
}

extension Float: MySQLDecodable {
    public init(mysqlValue value: MySQLValue) throws {
        guard let number = value.double else { throw Self.mismatch(value) }
        self = Float(number)
    }
}

/// `BOOL` is `TINYINT(1)`, so anything non-zero is true — matching how the
/// server itself evaluates it.
extension Bool: MySQLDecodable {
    public init(mysqlValue value: MySQLValue) throws {
        switch value {
        case .int(let raw): self = raw != 0
        case .uint(let raw): self = raw != 0
        case .bytes(let bytes) where bytes.count == 1: self = bytes[0] != 0
        default: throw Self.mismatch(value)
        }
    }
}

extension Array: MySQLDecodable where Element == UInt8 {
    public init(mysqlValue value: MySQLValue) throws {
        guard case .bytes(let bytes) = value else { throw Self.mismatch(value) }
        self = bytes
    }
}

extension MySQLDateTime: MySQLDecodable {
    public init(mysqlValue value: MySQLValue) throws {
        guard case .dateTime(let parsed) = value else { throw Self.mismatch(value) }
        self = parsed
    }
}

extension MySQLTime: MySQLDecodable {
    public init(mysqlValue value: MySQLValue) throws {
        guard case .time(let parsed) = value else { throw Self.mismatch(value) }
        self = parsed
    }
}

/// SQL `NULL` decodes to `nil`, and only to `nil`.
///
/// Declaring a column non-optional and getting `NULL` is an error rather than a
/// zero value — the mistake worth catching is a schema that permits `NULL` where
/// the code assumes it cannot.
extension Optional: MySQLDecodable where Wrapped: MySQLDecodable {
    public init(mysqlValue value: MySQLValue) throws {
        if case .null = value {
            self = .none
        } else {
            self = .some(try Wrapped(mysqlValue: value))
        }
    }
}

// MARK: - Row decoding

extension MySQLRow {

    /// Decodes the leading columns into a typed tuple.
    ///
    /// ```swift
    /// let (id, name, email) = try row.decode(Int.self, String.self, String?.self)
    /// ```
    ///
    /// Compare the alternatives. Go makes you pass pointers and pre-declare every
    /// variable (`rows.Scan(&id, &name)`), plus `sql.NullString` wherever a column
    /// is nullable. `mysql_async` gets there with `FromRow`, but nullability rides
    /// on `Option<T>` inside a derive macro. PyMySQL hands back an untyped tuple.
    /// Here the types are the argument list, the tuple comes back destructurable,
    /// and a nullable column is just `String?`.
    public func decode<each T: MySQLDecodable>(
        _ types: repeat (each T).Type
    ) throws -> (repeat each T) {
        var index = 0
        func next<V: MySQLDecodable>(_ type: V.Type) throws -> V {
            defer { index += 1 }
            guard index < values.count else {
                throw MySQLDecodingError(
                    column: index, columnName: nil, expected: "\(V.self)",
                    actual: .null
                )
            }
            let name = index < schema.columns.count ? schema.columns[index].name : nil
            return try V.decode(values[index], column: index, name: name)
        }
        return (repeat try next((each types)))
    }

    /// Decodes one column by position.
    public func decode<T: MySQLDecodable>(_ type: T.Type, at index: Int) throws -> T {
        guard index < values.count else {
            throw MySQLDecodingError(
                column: index, columnName: nil, expected: "\(T.self)", actual: .null
            )
        }
        let name = index < schema.columns.count ? schema.columns[index].name : nil
        return try T.decode(values[index], column: index, name: name)
    }

    /// Decodes one column by name.
    ///
    /// A missing column throws rather than returning `nil`, which keeps it
    /// distinct from a column that exists and is `NULL` — the distinction
    /// `subscript(name:)` returns as `Optional<MySQLValue>` and which is easy to
    /// flatten by accident.
    public func decode<T: MySQLDecodable>(_ type: T.Type, at name: String) throws -> T {
        guard let index = schema.index(of: name) else {
            throw MySQLDecodingError(
                column: -1, columnName: name, expected: "\(T.self)", actual: .null
            )
        }
        return try decode(type, at: index)
    }
}

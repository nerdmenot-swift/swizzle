import NIOCore

/// A SQL statement and its bound parameters, written as one string.
///
/// ```swift
/// let id = 42
/// let rows = try await connection.execute("SELECT name FROM users WHERE id = \(id)")
/// ```
///
/// The interpolation does **not** build a string. `\(id)` appends a `?` to the
/// SQL and the value to a separate bind list, so what reaches the server is
/// `SELECT name FROM users WHERE id = ?` with 42 sent out-of-band in the binary
/// protocol. Injection is not "discouraged" here, it is unrepresentable: there
/// is no code path from an interpolated value into the SQL text.
///
/// This is the one ergonomic every reference client wants and no other language
/// lets them have. `mysql_async` needs a `params!` macro and `:named` markers,
/// go's driver and PyMySQL make you keep a positional argument list in sync with
/// the `?`/`%s` markers by hand, and node-mysql2 offers named placeholders as an
/// opt-in config flag. All four separate the query from its values, which is
/// exactly where the mistakes live. Swift's string interpolation collapses the
/// two without giving up the separation on the wire.
///
/// Three things cannot be parameters, and each has a deliberate escape hatch:
/// identifiers (`\(identifier:)`), lists for `IN` (`\(list:)`), and genuinely
/// dynamic SQL (`\(unescaped:)` or ``init(unsafeSQL:binds:)``).
public struct MySQLQuery: Sendable, Equatable, ExpressibleByStringInterpolation {
    /// The statement, with `?` where each bound value goes.
    public let sql: String
    /// Values for the placeholders, in order.
    public let binds: [MySQLValue]

    /// Builds a query from SQL you have already assembled.
    ///
    /// Named `unsafeSQL` because it is: whatever is in `sql` is sent verbatim.
    /// Reach for it when the *shape* of the statement is dynamic — a column list
    /// chosen at runtime, a generated migration — not to avoid interpolation.
    public init(unsafeSQL sql: String, binds: [MySQLValue] = []) {
        self.sql = sql
        self.binds = binds
    }

    public init(stringLiteral value: String) {
        self.init(unsafeSQL: value)
    }

    public init(stringInterpolation: StringInterpolation) {
        self.sql = stringInterpolation.sql
        self.binds = stringInterpolation.binds
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        public typealias StringLiteralType = String

        var sql: String = ""
        var binds: [MySQLValue] = []

        public init(literalCapacity: Int, interpolationCount: Int) {
            sql.reserveCapacity(literalCapacity + interpolationCount)
            binds.reserveCapacity(interpolationCount)
        }

        /// The parts you typed. Only these ever become SQL.
        public mutating func appendLiteral(_ literal: String) {
            sql += literal
        }

        /// A bound value. Becomes `?`, never text.
        public mutating func appendInterpolation(_ value: some MySQLBindable) {
            sql += "?"
            binds.append(value.mysqlValue)
        }

        /// A pre-built value, for when you are holding a `MySQLValue` already.
        public mutating func appendInterpolation(_ value: MySQLValue) {
            sql += "?"
            binds.append(value)
        }

        /// A list of values, as `?, ?, ?` — for `IN` and `VALUES`.
        ///
        /// ```swift
        /// "SELECT * FROM users WHERE id IN (\(list: ids))"
        /// ```
        ///
        /// This is the single most common place hand-written binding goes wrong,
        /// because the number of placeholders has to match the array at runtime
        /// and nothing checks it. None of the four reference clients has an
        /// answer: you build the `?, ?, ?` string yourself and hope.
        ///
        /// An empty list renders `NULL`, so `IN ()` — which is a *syntax error*
        /// in MySQL — becomes `IN (NULL)`, which is valid and matches nothing.
        /// That is what an empty list means.
        public mutating func appendInterpolation(list values: [some MySQLBindable]) {
            guard !values.isEmpty else {
                sql += "NULL"
                return
            }
            sql += String(repeating: "?, ", count: values.count - 1) + "?"
            binds.append(contentsOf: values.map(\.mysqlValue))
        }

        /// A table or column name, quoted.
        ///
        /// Identifiers cannot be bound — the server needs them at parse time —
        /// so this quotes instead. A backtick inside the name is doubled, which
        /// is MySQL's own escaping rule, so a name can never terminate its own
        /// quoting.
        public mutating func appendInterpolation(identifier name: String) {
            sql += "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
        }

        /// Raw SQL, spliced in with no escaping at all.
        ///
        /// Deliberately ugly at the call site: if a value from outside your
        /// program reaches this, you have a SQL injection. It exists for the
        /// cases interpolation genuinely cannot express — an `ORDER BY`
        /// direction, a generated `WHERE` fragment.
        public mutating func appendInterpolation(unescaped sql: String) {
            self.sql += sql
        }
    }
}

extension MySQLQuery: CustomStringConvertible {
    /// The SQL with its placeholders intact.
    ///
    /// Bound values are *not* substituted in, on purpose: this is what a log
    /// line should show, and rendering the values here would put user data into
    /// logs and invite someone to treat the result as executable SQL.
    public var description: String { sql }
}

// MARK: - Binding

/// A Swift value that can be sent to MySQL as a bound parameter.
///
/// Conform your own types to reach the interpolation directly:
///
/// ```swift
/// extension UserID: MySQLBindable {
///     var mysqlValue: MySQLValue { .int(Int64(rawValue)) }
/// }
/// ```
public protocol MySQLBindable: Sendable {
    var mysqlValue: MySQLValue { get }
}

extension MySQLValue: MySQLBindable {
    public var mysqlValue: MySQLValue { self }
}

// Integers. MySQL distinguishes signed from unsigned on the wire, so the
// unsigned types map to `.uint` rather than being widened into `.int` — a
// `UInt64` above `Int64.max` would otherwise arrive negative.
extension Int: MySQLBindable { public var mysqlValue: MySQLValue { .int(Int64(self)) } }
extension Int8: MySQLBindable { public var mysqlValue: MySQLValue { .int(Int64(self)) } }
extension Int16: MySQLBindable { public var mysqlValue: MySQLValue { .int(Int64(self)) } }
extension Int32: MySQLBindable { public var mysqlValue: MySQLValue { .int(Int64(self)) } }
extension Int64: MySQLBindable { public var mysqlValue: MySQLValue { .int(self) } }
extension UInt: MySQLBindable { public var mysqlValue: MySQLValue { .uint(UInt64(self)) } }
extension UInt8: MySQLBindable { public var mysqlValue: MySQLValue { .uint(UInt64(self)) } }
extension UInt16: MySQLBindable { public var mysqlValue: MySQLValue { .uint(UInt64(self)) } }
extension UInt32: MySQLBindable { public var mysqlValue: MySQLValue { .uint(UInt64(self)) } }
extension UInt64: MySQLBindable { public var mysqlValue: MySQLValue { .uint(self) } }

extension String: MySQLBindable { public var mysqlValue: MySQLValue { .bytes(Array(utf8)) } }
extension Double: MySQLBindable { public var mysqlValue: MySQLValue { .double(self) } }
extension Float: MySQLBindable { public var mysqlValue: MySQLValue { .float(self) } }

/// MySQL has no boolean type — `BOOL` is an alias for `TINYINT(1)` — so this
/// binds 1 and 0, which is what the server stores either way.
extension Bool: MySQLBindable { public var mysqlValue: MySQLValue { .int(self ? 1 : 0) } }

extension Array: MySQLBindable where Element == UInt8 {
    public var mysqlValue: MySQLValue { .bytes(self) }
}

extension MySQLDateTime: MySQLBindable { public var mysqlValue: MySQLValue { .dateTime(self) } }
extension MySQLTime: MySQLBindable { public var mysqlValue: MySQLValue { .time(self) } }

/// `nil` binds as SQL `NULL`, so an optional needs no special handling at the
/// call site — which is the whole reason `sql.NullString` exists in Go and does
/// not need to here.
extension Optional: MySQLBindable where Wrapped: MySQLBindable {
    public var mysqlValue: MySQLValue {
        switch self {
        case .none: .null
        case .some(let value): value.mysqlValue
        }
    }
}

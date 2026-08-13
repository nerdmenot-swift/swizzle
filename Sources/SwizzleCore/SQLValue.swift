/// A bound parameter value. Deliberately a closed enum rather than `any Sendable`
/// so binding is allocation-free for the common scalar cases and trivially Sendable.
public enum SQLValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case text(String)
    case blob([UInt8])
}

public struct SQLDecodeError: Error, Sendable {
    public let expected: String
    public let actual: SQLValue
    public init(expected: String, actual: SQLValue) {
        self.expected = expected
        self.actual = actual
    }
}

/// One protocol covering both directions (bind + decode).
///
/// This is a type-checker decision, not just an aesthetic one: every extra
/// protocol in the constraint system is more work for the solver on every
/// operator overload. One protocol keeps `==`, `<`, `in`, etc. cheap.
public protocol SQLColumnValue: Sendable {
    var sqlValue: SQLValue { get }
    init(sqlValue: SQLValue) throws
}

extension Int64: SQLColumnValue {
    public var sqlValue: SQLValue { .int(self) }
    public init(sqlValue: SQLValue) throws {
        guard case .int(let v) = sqlValue else { throw SQLDecodeError(expected: "Int64", actual: sqlValue) }
        self = v
    }
}

extension Int: SQLColumnValue {
    public var sqlValue: SQLValue { .int(Int64(self)) }
    public init(sqlValue: SQLValue) throws {
        guard case .int(let v) = sqlValue else { throw SQLDecodeError(expected: "Int", actual: sqlValue) }
        self = Int(v)
    }
}

extension String: SQLColumnValue {
    public var sqlValue: SQLValue { .text(self) }
    public init(sqlValue: SQLValue) throws {
        guard case .text(let v) = sqlValue else { throw SQLDecodeError(expected: "String", actual: sqlValue) }
        self = v
    }
}

extension Bool: SQLColumnValue {
    public var sqlValue: SQLValue { .bool(self) }
    public init(sqlValue: SQLValue) throws {
        switch sqlValue {
        case .bool(let value): self = value
        // Neither SQLite nor MySQL has a boolean type — both store 0 and 1 in an
        // integer column, so refusing an integer here would mean every boolean
        // round-trip failed on two of the three engines.
        case .int(let value): self = value != 0
        default: throw SQLDecodeError(expected: "Bool", actual: sqlValue)
        }
    }
}

extension Double: SQLColumnValue {
    public var sqlValue: SQLValue { .double(self) }
    public init(sqlValue: SQLValue) throws {
        guard case .double(let v) = sqlValue else { throw SQLDecodeError(expected: "Double", actual: sqlValue) }
        self = v
    }
}

extension Optional: SQLColumnValue where Wrapped: SQLColumnValue {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
    public init(sqlValue: SQLValue) throws {
        if case .null = sqlValue { self = .none } else { self = try Wrapped(sqlValue: sqlValue) }
    }
}

/// Placeholder row type. The real one will be driver-backed and avoid the array copy.
/// `BIGINT UNSIGNED` and friends.
///
/// Needed because `SQLValue.int` is `Int64`, so an unsigned 64-bit value above
/// 2^63 has nowhere to sit. The MySQL driver already handles this correctly on
/// the way in — `MySQLValue.sqlValue` tries `Int64(exactly:)` and falls back to
/// `.text` rather than wrapping — but there was no Swift type on the other side
/// that could accept both halves, so such a column could not be declared at all.
///
/// Reading accepts either form; writing emits `.int` when it fits and `.text`
/// otherwise, mirroring the driver.
/// A value that declines to be narrowed.
///
/// Needed by the code generator: SQLite reports no type at all for an expression
/// column — `decltype` is null for `COUNT(*)` and `a || b` — so the honest Swift
/// type is the untyped one. Without this conformance the generator could describe
/// such a column but not emit anything able to decode it.
///
/// The conversion is the identity in both directions, which is the point: this is
/// where a caller opts out of typing rather than where a type is guessed.
extension SQLValue: SQLColumnValue {
    public var sqlValue: SQLValue { self }
    public init(sqlValue: SQLValue) throws { self = sqlValue }
}

extension UInt64: SQLColumnValue {
    public var sqlValue: SQLValue {
        Int64(exactly: self).map { .int($0) } ?? .text(String(self))
    }

    public init(sqlValue: SQLValue) throws {
        switch sqlValue {
        case .int(let value):
            guard let unsigned = UInt64(exactly: value) else {
                throw SQLDecodeError(expected: "UInt64", actual: sqlValue)
            }
            self = unsigned
        case .text(let text):
            guard let unsigned = UInt64(text) else {
                throw SQLDecodeError(expected: "UInt64", actual: sqlValue)
            }
            self = unsigned
        default:
            throw SQLDecodeError(expected: "UInt64", actual: sqlValue)
        }
    }
}

extension [UInt8]: SQLColumnValue {
    public var sqlValue: SQLValue { .blob(self) }
    public init(sqlValue: SQLValue) throws {
        switch sqlValue {
        case .blob(let bytes): self = bytes
        // Drivers hand back TEXT and BLOB through the same column type often
        // enough that refusing the text case would be pedantry, not safety.
        case .text(let string): self = Array(string.utf8)
        default: throw SQLDecodeError(expected: "[UInt8]", actual: sqlValue)
        }
    }
}

public struct SQLRow: Sendable {
    public var values: [SQLValue]
    public init(values: [SQLValue]) { self.values = values }
}

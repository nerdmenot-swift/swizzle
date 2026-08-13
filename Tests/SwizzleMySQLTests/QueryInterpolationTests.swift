import NIOCore
import Testing
@testable import SwizzleMySQL

/// What the interpolation actually produces.
///
/// The whole claim of ``MySQLQuery`` is that an interpolated value never becomes
/// SQL text. These assert the SQL and the binds separately, which is the only
/// way to show that — a round-trip test would pass even if the value had been
/// concatenated in.
@Suite("Query interpolation")
struct QueryInterpolationTests {

    @Test("an interpolated value becomes a placeholder, not text")
    func valuesBecomePlaceholders() {
        let id = 42
        let query: MySQLQuery = "SELECT name FROM users WHERE id = \(id)"

        #expect(query.sql == "SELECT name FROM users WHERE id = ?")
        #expect(query.binds == [.int(42)])
    }

    /// The point of the whole design. If interpolation built a string, this
    /// would produce two statements; instead the payload is one opaque value.
    @Test("SQL in a value is data, not syntax")
    func injectionIsUnrepresentable() {
        let hostile = "'; DROP TABLE users; --"
        let query: MySQLQuery = "SELECT * FROM users WHERE name = \(hostile)"

        #expect(query.sql == "SELECT * FROM users WHERE name = ?")
        #expect(!query.sql.contains("DROP"))
        #expect(query.binds == [.bytes(Array(hostile.utf8))])
    }

    @Test("several values keep their order")
    func multipleValuesKeepOrder() {
        let query: MySQLQuery = "INSERT INTO t (a, b, c) VALUES (\(1), \("two"), \(3.5))"
        #expect(query.sql == "INSERT INTO t (a, b, c) VALUES (?, ?, ?)")
        #expect(query.binds == [.int(1), .bytes(Array("two".utf8)), .double(3.5)])
    }

    @Test("a literal with no interpolation binds nothing")
    func plainLiteral() {
        let query: MySQLQuery = "SELECT 1"
        #expect(query.sql == "SELECT 1")
        #expect(query.binds.isEmpty)
    }

    // MARK: - Lists

    /// The `IN (?, ?, ?)` problem: none of the reference clients solve it, so
    /// callers build the placeholder run by hand and it drifts from the array.
    @Test("a list expands to one placeholder per element")
    func listExpands() {
        let ids = [1, 2, 3]
        let query: MySQLQuery = "SELECT * FROM users WHERE id IN (\(list: ids))"
        #expect(query.sql == "SELECT * FROM users WHERE id IN (?, ?, ?)")
        #expect(query.binds == [.int(1), .int(2), .int(3)])
    }

    @Test("a single-element list needs no separator")
    func singleElementList() {
        let query: MySQLQuery = "WHERE id IN (\(list: [7]))"
        #expect(query.sql == "WHERE id IN (?)")
        #expect(query.binds == [.int(7)])
    }

    /// `IN ()` is a syntax error in MySQL, so an empty list cannot render as
    /// nothing. `IN (NULL)` is valid and matches no rows, which is what an empty
    /// set of candidates means.
    @Test("an empty list is NULL, not a syntax error")
    func emptyList() {
        let empty: [Int] = []
        let query: MySQLQuery = "SELECT * FROM users WHERE id IN (\(list: empty))"
        #expect(query.sql == "SELECT * FROM users WHERE id IN (NULL)")
        #expect(query.binds.isEmpty)
    }

    // MARK: - Identifiers

    /// Identifiers are needed at parse time so they cannot be bound. Quoting is
    /// the only option, and the quoting has to survive a backtick in the name.
    @Test("identifiers are quoted, and cannot escape their quoting")
    func identifiersAreQuoted() {
        let plain: MySQLQuery = "SELECT * FROM \(identifier: "users")"
        #expect(plain.sql == "SELECT * FROM `users`")

        let hostile: MySQLQuery = "SELECT * FROM \(identifier: "us`ers")"
        #expect(hostile.sql == "SELECT * FROM `us``ers`")
        #expect(hostile.binds.isEmpty)
    }

    @Test("raw SQL is spliced verbatim")
    func unescapedIsVerbatim() {
        let direction = "DESC"
        let query: MySQLQuery = "SELECT * FROM t ORDER BY id \(unescaped: direction)"
        #expect(query.sql == "SELECT * FROM t ORDER BY id DESC")
        #expect(query.binds.isEmpty)
    }

    // MARK: - Values

    @Test("nil binds as NULL")
    func optionalsBindAsNull() {
        let missing: String? = nil
        let present: String? = "here"
        let query: MySQLQuery = "INSERT INTO t VALUES (\(missing), \(present))"
        #expect(query.sql == "INSERT INTO t VALUES (?, ?)")
        #expect(query.binds == [.null, .bytes(Array("here".utf8))])
    }

    /// Unsigned values above `Int64.max` must not be widened through a signed
    /// type, or they arrive negative.
    @Test("unsigned integers stay unsigned")
    func unsignedStaysUnsigned() {
        let big = UInt64.max
        let query: MySQLQuery = "SELECT \(big)"
        #expect(query.binds == [.uint(UInt64.max)])
    }

    @Test("booleans bind as MySQL's TINYINT(1)")
    func boolsBindAsIntegers() {
        let query: MySQLQuery = "SELECT \(true), \(false)"
        #expect(query.binds == [.int(1), .int(0)])
    }

    /// Logging a query must not print the values it carries.
    @Test("description shows placeholders, never the bound values")
    func descriptionHidesValues() {
        let secret = "hunter2"
        let query: MySQLQuery = "SELECT * FROM users WHERE password = \(secret)"
        #expect(query.description == "SELECT * FROM users WHERE password = ?")
        #expect(!query.description.contains("hunter2"))
    }

    @Test("unsafeSQL passes through untouched")
    func unsafeSQLPassesThrough() {
        let query = MySQLQuery(unsafeSQL: "SELECT * FROM t WHERE a = ?", binds: [.int(1)])
        #expect(query.sql == "SELECT * FROM t WHERE a = ?")
        #expect(query.binds == [.int(1)])
    }
}

/// Decoding a row into Swift types.
@Suite("Row decoding")
struct RowDecodingTests {

    static func row(_ values: [MySQLValue], names: [String] = []) -> MySQLRow {
        let columns = (0..<values.count).map { index in
            MySQLColumnDefinition(
                catalog: "def", schema: "db", table: "t", originalTable: "t",
                name: index < names.count ? names[index] : "c\(index)",
                originalName: "c\(index)", characterSet: 33, columnLength: 255,
                type: MySQLColumnType.varString.rawValue, flags: [], decimals: 0
            )
        }
        return MySQLRow(values: values, columns: columns)
    }

    @Test("a row decodes into a typed tuple")
    func decodesTuple() throws {
        let row = Self.row([.int(1), .bytes(Array("ada".utf8)), .double(2.5)])
        let (id, name, score) = try row.decode(Int.self, String.self, Double.self)
        #expect(id == 1)
        #expect(name == "ada")
        #expect(score == 2.5)
    }

    /// The distinction Go needs `sql.NullString` for, and Swift gets free.
    @Test("NULL decodes to nil for an optional, and throws for a non-optional")
    func nullHandling() throws {
        let row = Self.row([.null])
        #expect(try row.decode(String?.self, at: 0) == nil)
        #expect(throws: MySQLDecodingError.self) { try row.decode(String.self, at: 0) }
    }

    /// The same column arrives as `.int` over the binary protocol and as digits
    /// over the text protocol. A caller should not have to know which.
    @Test("integers decode from either wire representation")
    func integersAcceptEitherRepresentation() throws {
        #expect(try Self.row([.int(7)]).decode(Int.self, at: 0) == 7)
        #expect(try Self.row([.uint(7)]).decode(Int.self, at: 0) == 7)
        #expect(try Self.row([.bytes(Array("7".utf8))]).decode(Int.self, at: 0) == 7)
    }

    /// Narrowing must fail loudly rather than wrap.
    @Test("a value outside the target's range throws")
    func rangeIsChecked() {
        let row = Self.row([.int(300)])
        #expect(throws: MySQLDecodingError.self) { try row.decode(Int8.self, at: 0) }
    }

    @Test("decoding by name finds the column")
    func decodesByName() throws {
        let row = Self.row([.int(1), .bytes(Array("ada".utf8))], names: ["id", "name"])
        #expect(try row.decode(String.self, at: "name") == "ada")
        #expect(throws: MySQLDecodingError.self) { try row.decode(String.self, at: "nope") }
    }

    /// The error has to say *which* column, because the usual cause is asking
    /// for the columns in the wrong order.
    @Test("a decode error names the column")
    func errorNamesTheColumn() throws {
        let row = Self.row([.bytes(Array("not a number".utf8))], names: ["count"])
        do {
            _ = try row.decode(Int.self, at: 0)
            Issue.record("expected a decoding error")
        } catch let error as MySQLDecodingError {
            #expect(error.columnName == "count")
            #expect(error.description.contains("count"))
        }
    }

    @Test("asking for more columns than the row has throws")
    func tooManyColumns() {
        let row = Self.row([.int(1)])
        #expect(throws: MySQLDecodingError.self) {
            try row.decode(Int.self, String.self)
        }
    }
}

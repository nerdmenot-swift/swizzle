import Foundation
import SwizzleCore
import Testing

@testable import SwizzleSQLite

/// What SQLite makes of the values this driver binds.
///
/// ## The gap this closes
///
/// MySQL has four differential oracle suites and Postgres two. SQLite had none,
/// so nothing checked that a value bound through `sqlite3_bind_*` means to
/// SQLite what the driver intended. Every genuine semantic bug found in this
/// project came from an oracle rather than from coverage or mutation, and this
/// was the driver with the lowest barrier to being adopted and the least
/// grounding.
///
/// ## Two independent paths, and why they are independent
///
/// Each value is presented to SQLite twice: once **bound as a parameter**, and
/// once written as a **SQL literal** in the statement text. The literal never
/// touches the binding code — SQLite's own parser turns it into a value — so
/// the two agreeing means the driver produced what SQLite would have.
///
/// The comparison is made with `typeof()` and `quote()`, which are evaluated
/// *inside* SQLite and returned as text. That matters: asking the driver to
/// decode both sides and comparing the results would pass just as happily if
/// the decoder mangled both the same way.
///
/// ## The anchor against comparing the code with itself
///
/// A differential alone can still be circular — two paths can agree and both be
/// wrong, and a decoder that returned the empty string for everything would
/// make every comparison pass. So each subject also carries the rendering
/// SQLite is *documented* to produce, written down here rather than harvested
/// from a run. If the expectation and the two paths ever disagree three ways,
/// that is the interesting case.
///
/// `quote()` renderings come from SQLite's documented behaviour: NULL is
/// `NULL`, integers and reals are their decimal text, text is single-quoted
/// with embedded quotes doubled, and blobs are `X'hex'`.
@Suite("SQLite value oracle")
struct SQLiteValueOracleTests {

    /// A value, the SQL literal that means the same thing, and what SQLite is
    /// documented to make of it.
    struct Subject: Sendable, CustomStringConvertible {
        let name: String
        let value: SQLValue
        /// Parsed by SQLite, never by this driver.
        let literal: String
        /// What `typeof()` must report: one of null/integer/real/text/blob.
        let expectedType: String
        /// What `quote()` must render, from SQLite's documented format.
        let expectedQuote: String
        /// Which binding branch this reaches, and why it is worth a row.
        let reaches: String
        /// What the driver decodes the literal back to, when that is not the
        /// value itself. SQLite has no boolean type, so a bound `.bool` is an
        /// integer from the moment it arrives and cannot come back as a bool.
        /// Stating the lossy cases beats skipping them: if a later change made
        /// bools round-trip, that is a behaviour change callers should see fail
        /// here rather than discover.
        var decodesAs: SQLValue? = nil

        var description: String { name }
    }

    static let subjects: [Subject] = [
        .init(name: "null", value: .null, literal: "NULL",
              expectedType: "null", expectedQuote: "NULL",
              reaches: "sqlite3_bind_null"),

        // Bool has no SQLite type. The driver binds it as an integer, which is
        // a decision nothing had pinned — if it bound text instead, every
        // comparison against an integer column would silently change meaning.
        .init(name: "true", value: .bool(true), literal: "1",
              expectedType: "integer", expectedQuote: "1",
              reaches: "bind_int64 via .bool — SQLite has no boolean type",
              decodesAs: .int(1)),
        .init(name: "false", value: .bool(false), literal: "0",
              expectedType: "integer", expectedQuote: "0",
              reaches: "bind_int64 via .bool",
              decodesAs: .int(0)),

        .init(name: "zero", value: .int(0), literal: "0",
              expectedType: "integer", expectedQuote: "0",
              reaches: "bind_int64"),
        .init(name: "negative", value: .int(-1), literal: "-1",
              expectedType: "integer", expectedQuote: "-1",
              reaches: "bind_int64, sign"),
        // The boundaries, where the literal path exercises SQLite's own decimal
        // parser at the edge of what it can represent.
        .init(name: "Int64.max", value: .int(9223372036854775807),
              literal: "9223372036854775807",
              expectedType: "integer", expectedQuote: "9223372036854775807",
              reaches: "bind_int64 upper bound"),
        .init(name: "Int64.min", value: .int(-9223372036854775808),
              literal: "-9223372036854775808",
              expectedType: "integer", expectedQuote: "-9223372036854775808",
              reaches: "bind_int64 lower bound"),

        .init(name: "double whole", value: .double(1), literal: "1.0",
              expectedType: "real", expectedQuote: "1.0",
              reaches: "bind_double — a whole real must not become an integer"),
        .init(name: "double fraction", value: .double(0.5), literal: "0.5",
              expectedType: "real", expectedQuote: "0.5",
              reaches: "bind_double"),
        // `quote()` renders negative zero as `0.0` — confirmed against the
        // sqlite3 CLI, a different binary from this driver, so the expectation
        // is not harvested from the code under test. It also means this row
        // cannot say whether the sign survived; `signedZeroSurvivesBinding`
        // below asks that separately.
        .init(name: "double negative zero", value: .double(-0.0), literal: "-0.0",
              expectedType: "real", expectedQuote: "0.0",
              reaches: "bind_double, sign of zero"),

        .init(name: "empty text", value: .text(""), literal: "''",
              expectedType: "text", expectedQuote: "''",
              reaches: "the explicit empty-string branch in bind_text"),
        .init(name: "ascii", value: .text("abc"), literal: "'abc'",
              expectedType: "text", expectedQuote: "'abc'",
              reaches: "bind_text"),
        // An embedded quote is where a driver that built SQL by concatenation
        // rather than binding would produce a different value or a syntax error.
        .init(name: "text with quote", value: .text("it's"), literal: "'it''s'",
              expectedType: "text", expectedQuote: "'it''s'",
              reaches: "bind_text with a character that is SQL syntax"),
        .init(name: "unicode", value: .text("héllo — 世界"), literal: "'héllo — 世界'",
              expectedType: "text", expectedQuote: "'héllo — 世界'",
              reaches: "bind_text, multi-byte UTF-8"),
        // Text that looks like a number. Without an affinity to convert it this
        // must stay text, and that is what distinguishes a value from its
        // spelling.
        .init(name: "numeric-looking text", value: .text("123"), literal: "'123'",
              expectedType: "text", expectedQuote: "'123'",
              reaches: "bind_text that a careless conversion would turn into 123"),

        .init(name: "empty blob", value: .blob([]), literal: "X''",
              expectedType: "blob", expectedQuote: "X''",
              reaches: "bind_zeroblob — the empty case is bound differently"),
        .init(name: "blob", value: .blob([0x41, 0x42, 0x43]), literal: "X'414243'",
              expectedType: "blob", expectedQuote: "X'414243'",
              reaches: "bind_blob"),
        // A blob containing a NUL is the case a C string boundary gets wrong:
        // treated as text it would truncate at the first zero byte.
        .init(name: "blob with NUL", value: .blob([0x00, 0x01, 0x00]), literal: "X'000100'",
              expectedType: "blob", expectedQuote: "X'000100'",
              reaches: "bind_blob across an embedded NUL"),
        .init(name: "blob high bytes", value: .blob([0xFF, 0xFE, 0x80]), literal: "X'FFFE80'",
              expectedType: "blob", expectedQuote: "X'FFFE80'",
              reaches: "bind_blob, bytes that are not valid UTF-8"),
    ]

    static func text(_ row: SQLRow, _ index: Int) -> String? {
        guard index < row.values.count, case .text(let value) = row.values[index] else { return nil }
        return value
    }

    // MARK: - The differential

    /// **The oracle.** For every subject, what SQLite says about the bound value
    /// must equal what it says about the literal — and both must equal the
    /// documented rendering written down beside them.
    @Test("a bound value and its literal are the same value to SQLite", arguments: subjects)
    func boundMatchesLiteral(subject: Subject) async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }

        let bound = try await connection.query(
            "SELECT typeof(?1), quote(?1)", [subject.value]
        )
        let literal = try await connection.query(
            "SELECT typeof(\(subject.literal)), quote(\(subject.literal))"
        )

        guard let boundRow = bound.first, let literalRow = literal.first else {
            Issue.record("no row for \(subject.name)")
            return
        }

        let boundType = Self.text(boundRow, 0)
        let boundQuote = Self.text(boundRow, 1)

        #expect(
            boundType == Self.text(literalRow, 0),
            "\(subject.name): bound is \(boundType ?? "nil"), literal is \(Self.text(literalRow, 0) ?? "nil") — \(subject.reaches)"
        )
        #expect(
            boundQuote == Self.text(literalRow, 1),
            "\(subject.name): bound renders \(boundQuote ?? "nil"), literal renders \(Self.text(literalRow, 1) ?? "nil")"
        )

        // The anchor: both agreeing is not enough if both are wrong.
        #expect(boundType == subject.expectedType, "\(subject.name) typeof")
        #expect(boundQuote == subject.expectedQuote, "\(subject.name) quote")
    }

    // MARK: - Storage, where affinity gets involved

    /// The same differential, but stored in a column first.
    ///
    /// SQLite applies **type affinity** on the way in: a value written to a
    /// column declared `INTEGER` may be converted, and the conversion depends on
    /// the value's type rather than its spelling. So a driver that binds the
    /// wrong type does not necessarily produce a wrong value in a `SELECT` — it
    /// produces one after a round trip through a table, which is where the
    /// application will find it.
    ///
    /// Both rows go into the same column, so any affinity applies equally; what
    /// is being compared is still the bound path against the literal path.
    @Test(
        "a bound value and its literal store identically under every affinity",
        arguments: subjects, ["INTEGER", "REAL", "TEXT", "BLOB", "NUMERIC", ""]
    )
    func storedValuesMatch(subject: Subject, affinity: String) async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }

        _ = try await connection.execute("CREATE TABLE t (v \(affinity))")
        _ = try await connection.execute("INSERT INTO t (v) VALUES (?)", [subject.value])
        _ = try await connection.execute("INSERT INTO t (v) VALUES (\(subject.literal))")

        let rows = try await connection.query(
            "SELECT typeof(v), quote(v) FROM t ORDER BY rowid"
        )
        guard rows.count == 2 else {
            Issue.record("expected two rows, got \(rows.count)")
            return
        }

        let declared = affinity.isEmpty ? "no declared type" : affinity
        #expect(
            Self.text(rows[0], 0) == Self.text(rows[1], 0),
            "\(subject.name) in a \(declared) column: bound stored as \(Self.text(rows[0], 0) ?? "nil"), literal as \(Self.text(rows[1], 0) ?? "nil")"
        )
        #expect(
            Self.text(rows[0], 1) == Self.text(rows[1], 1),
            "\(subject.name) in a \(declared) column: bound renders \(Self.text(rows[0], 1) ?? "nil"), literal renders \(Self.text(rows[1], 1) ?? "nil")"
        )
    }

    // MARK: - Back through the driver

    /// The other direction: what the driver decodes for a value SQLite itself
    /// produced from a literal.
    ///
    /// This one *is* the driver on both ends, so it cannot ground the encoder —
    /// that is what the two tests above are for. Its value is localisation: with
    /// the encoder independently grounded, a failure here is the decoder, and
    /// the two together cover the round trip an application actually performs.
    @Test("a literal SQLite parsed comes back as the value it denotes", arguments: subjects)
    func literalDecodesToTheValue(subject: Subject) async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }

        let rows = try await connection.query("SELECT \(subject.literal)")
        guard let decoded = rows.first?.values.first else {
            Issue.record("no value for \(subject.name)")
            return
        }
        let expected = subject.decodesAs ?? subject.value
        #expect(
            decoded == expected,
            "\(subject.name): SQLite parsed \(subject.literal) and the driver decoded \(decoded), not \(expected)"
        )
    }

    // MARK: - What quote() cannot see

    /// **Signed zero**, which the oracle above is structurally blind to.
    ///
    /// `quote()` renders both zeros as `0.0`, so the differential passes whether
    /// or not the sign survived. That is worth stating rather than leaving as a
    /// silent hole: an oracle is only as good as the projection it compares
    /// through, and this one projects the sign away.
    ///
    /// **And SQLite offers no probe for it.** Division by zero is NULL rather
    /// than infinity, `printf(.%f.)` gives `0.000000` for both, and `CAST` to
    /// text gives `0.0` — checked against the sqlite3 CLI. There is no
    /// expression whose value differs, so the sign of zero cannot be grounded
    /// against SQLite at all. That is a limit of the oracle, recorded here
    /// rather than papered over with a test that proves something else.
    ///
    /// What is left is the driver round trip, which is *not* oracle-grounded:
    /// it is this code on both ends, so it shows the driver does not normalise
    /// the sign away, and nothing more.
    @Test("the driver does not normalise away the sign of zero")
    func signedZeroSurvivesTheDriverRoundTrip() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }

        let rows = try await connection.query("SELECT ?1, ?2", [.double(-0.0), .double(0.0)])
        guard case .double(let negative)? = rows.first?.values.first,
              case .double(let positive)? = rows.first?.values.last
        else {
            Issue.record("no reals came back")
            return
        }
        #expect(negative.sign == .minus, "bound -0.0 came back as \(negative)")
        #expect(positive.sign == .plus, "bound 0.0 came back as \(positive)")
    }

    /// **Large integers must not arrive as reals.** A driver that routed
    /// integers through a `Double` would lose precision above 2^53, and
    /// `typeof` would still say `integer` after SQLite converted it back — so
    /// the type check alone does not catch it. The value has to be compared.
    @Test("an integer beyond a double's precision survives exactly")
    func largeIntegerSurvivesExactly() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }

        // 2^53 + 1: the smallest integer a Double cannot represent.
        let value: Int64 = 9007199254740993
        let rows = try await connection.query(
            "SELECT ?1 = 9007199254740993, quote(?1)", [.int(value)]
        )
        guard let row = rows.first else {
            Issue.record("no row")
            return
        }
        // The comparison is SQLite's, against a literal it parsed itself.
        #expect(row.values.first == .int(1), "SQLite says the bound value is not 9007199254740993")
        #expect(Self.text(row, 1) == "9007199254740993", "got \(Self.text(row, 1) ?? "nil")")
    }
}

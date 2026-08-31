import NIOCore
import NIOPosix
import SwizzleCore
import SwizzlePostgresDriver
import Testing

/// The types found missing by diffing our OID table against
/// `postgres-types/src/type_gen.rs`.
///
/// ## How these are verified
///
/// Not against hand-written expectations, which would only prove I can copy a
/// format description. Each value is fetched **twice** — once letting the driver
/// decode the binary form, once with `::text` so the *server* renders it — and
/// the two must agree.
///
/// That makes Postgres itself the oracle. A decoder that produces a plausible but
/// non-canonical spelling — `1.0` for `1`, `::` for a single zero group, a box
/// with brackets an lseg would have — fails here, and every one of those is a bug
/// a hand-written expectation would have happily enshrined.
@Suite(
    "Postgres extended types", .serialized,
    .enabled(if: PostgresTestServer.isAvailable, PostgresTestServer.skipReason)
)
struct PostgresExtendedTypeTests {

    static let url = PostgresTestServer.url

    static func open() async throws -> PostgresConnection {
        try await PostgresConnection.connect(
            configuration: PostgresConnectionConfiguration(swizzleURL: url),
            on: MultiThreadedEventLoopGroup.singleton.next()
        )
    }

    /// Fetches the same value in **both wire formats** and returns both.
    ///
    /// A bound parameter takes the extended protocol, where the driver asks for
    /// binary; the same literal with no parameters takes the simple protocol,
    /// which is always text. So the comparison is binary-decoded against
    /// server-rendered, which is exactly the contract these decoders claim.
    ///
    /// The first version of this used `::text` as the oracle and was wrong for
    /// `inet`: casting to text always appends the prefix, while the type's own
    /// output function omits it for a full-width host address. Two different
    /// functions, and only one of them is what comes down the wire.
    func agree(
        _ connection: PostgresConnection, _ literal: String, _ type: String
    ) async throws -> (binary: SQLValue, text: SQLValue) {
        let binary = try await connection.query("SELECT $1::\(type)", [.text(literal)]).rows
        let quoted = literal.replacingOccurrences(of: "'", with: "''")
        let text = try await connection.query("SELECT '\(quoted)'::\(type)").rows
        return (binary[0][0], text[0][0])
    }

    func check(
        _ connection: PostgresConnection, _ literal: String, _ type: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let (binary, text) = try await agree(connection, literal, type)
        #expect(
            binary == text,
            "\(type) '\(literal)': binary \(binary), text \(text)",
            sourceLocation: sourceLocation
        )
    }

    // MARK: - Network addresses

    /// `inet` prints its prefix only when it is not a full-width host address;
    /// `cidr` always prints it. Getting that backwards produces a value that
    /// looks right and compares unequal to the server's.
    @Test("inet and cidr match the server's rendering")
    func networkAddresses() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        for literal in ["192.168.0.1", "10.0.0.0/8", "255.255.255.255", "0.0.0.0/0"] {
            try await check(connection, literal, "inet")
        }
        for literal in ["10.0.0.0/8", "192.168.100.128/25", "0.0.0.0/0"] {
            try await check(connection, literal, "cidr")
        }
    }

    /// IPv6 compression is where a decoder invents its own spelling. The server
    /// collapses the longest run of zero groups and only when the run is two or
    /// more — a single zero group is written out.
    @Test("IPv6 compression matches the server exactly")
    func ipv6() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        for literal in [
            "::1",
            "2001:db8::1",
            "fe80::1234:5678:9abc:def0",
            "2001:0db8:0000:0042:0000:8a2e:0370:7334",
            "::",
            "2001:db8:0:1:1:1:1:1",
        ] {
            try await check(connection, literal, "inet")
        }
    }

    @Test("MAC addresses match")
    func macAddresses() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        try await check(connection, "08:00:2b:01:02:03", "macaddr")
        try await check(connection, "08:00:2b:01:02:03:04:05", "macaddr8")
    }

    // MARK: - money and bit strings

    /// Money is exact, like `numeric`: through binary floating point it loses a
    /// cent per row.
    @Test("money keeps its cents")
    func money() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        // The server prints money with the locale's currency symbol, so the
        // renderings deliberately differ — what matters is the *amount*.
        for literal in ["1234.56", "0.01", "-99.99", "0.00"] {
            let rows = try await connection.query("SELECT $1::money", [.text(literal)]).rows
            guard case .text(let decoded) = rows[0][0] else {
                Issue.record("expected text, got \(rows[0][0])"); return
            }
            #expect(decoded == literal, "money '\(literal)' decoded as \(decoded)")
        }
        #expect(PostgresOID.money.swiftType == .decimalString)
    }

    /// The length is in **bits**, so `B'101'` occupies one byte of which five are
    /// padding that must not be printed.
    @Test("bit strings print only their real bits")
    func bitStrings() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        for literal in ["101", "1", "0", "11111111", "100000001"] {
            try await check(connection, literal, "varbit")
        }
        try await check(connection, "1010", "bit(4)")
    }

    // MARK: - Ranges

    /// The brackets carry the inclusivity, and dropping them turns a half-open
    /// range into an ambiguous pair — for a `tstzrange` that is the difference
    /// between including midnight and not.
    @Test("ranges keep their bounds and inclusivity")
    func ranges() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        for literal in ["[1,10)", "(1,10]", "[1,10]", "empty", "[5,)", "(,5)"] {
            try await check(connection, literal, "int4range")
        }
        try await check(connection, "[1,100)", "int8range")
        try await check(connection, "[2024-01-01,2024-12-31)", "daterange")
        try await check(connection, "[1.5,2.5)", "numrange")
    }

    // MARK: - System types

    @Test("xid, cid and tid decode")
    func systemTypes() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        try await check(connection, "(0,1)", "tid")

        let xid = try await connection.query("SELECT $1::xid", [.text("42")]).rows
        #expect(xid[0][0] == .int(42))
    }

    @Test("pg_lsn matches the server's hex spelling")
    func pgLSN() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        for literal in ["0/16B374", "16/B374D848", "0/0", "FFFFFFFF/FFFFFFFF"] {
            try await check(connection, literal, "pg_lsn")
        }
    }

    // MARK: - Geometric

    /// Each of these prints with different punctuation — a box has no enclosing
    /// brackets where an lseg does, a line uses braces, a circle angle brackets.
    /// Comparing against the server is what keeps them straight.
    @Test("geometric types match the server's punctuation")
    func geometry() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        try await check(connection, "(1,2)", "point")
        try await check(connection, "[(1,2),(3,4)]", "lseg")
        try await check(connection, "(3,4),(1,2)", "box")
        try await check(connection, "{1,2,3}", "line")
        try await check(connection, "<(1,2),3>", "circle")
        try await check(connection, "((1,2),(3,4),(5,6))", "path")
        try await check(connection, "[(1,2),(3,4)]", "path")
        try await check(connection, "((1,2),(3,4),(5,6))", "polygon")
    }

    /// Postgres prints an integral coordinate without a trailing `.0`, and a
    /// fractional one in full.
    @Test("coordinates round-trip whole and fractional values")
    func coordinateFormatting() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        try await check(connection, "(1.5,-2.25)", "point")
        try await check(connection, "(0,0)", "point")
        try await check(connection, "(-1,-1)", "point")
    }

    // MARK: - Multiranges

    /// Postgres 14 gave every range type a multirange companion, and a column of
    /// `int4multirange` is as ordinary as one of `int4range`. Without an entry
    /// here they arrived as opaque bytes.
    ///
    /// `rust-postgres` knows multiranges only as a *kind* — it records the
    /// element type and ships no codec — so this is one of the few places we are
    /// ahead of the reference. Which is exactly why it is checked against the
    /// server rather than against my reading of the format: there was no second
    /// implementation to cross-check.
    @Test("multiranges match the server's rendering")
    func multiranges() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        // Several ranges, one range, and none — the empty multirange is its own
        // case in the encoding, being a count of zero with nothing after it.
        try await check(connection, "{[1,5),[10,20)}", "int4multirange")
        try await check(connection, "{[1,5)}", "int4multirange")
        try await check(connection, "{}", "int4multirange")
        // Unbounded ends, where the flags byte says a bound is absent rather
        // than present-and-empty.
        try await check(connection, "{(,5)}", "int4multirange")
        try await check(connection, "{[10,)}", "int4multirange")
        try await check(connection, "{(,)}", "int4multirange")

        try await check(connection, "{[1,100)}", "int8multirange")
        try await check(connection, "{[1.5,2.5)}", "nummultirange")
        try await check(connection, "{[2024-01-01,2024-02-01)}", "datemultirange")
        try await check(
            connection, "{[2024-01-01 00:00:00,2024-01-02 00:00:00)}", "tsmultirange"
        )
    }

    // MARK: - Catalog types

    /// Nobody declares a column of these; everybody meets them the moment they
    /// read `pg_index` or `pg_proc`, which is the worst time to be handed bytes.
    @Test("int2vector and oidvector match the server's rendering")
    func vectors() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        try await check(connection, "1 2 3", "int2vector")
        try await check(connection, "0", "int2vector")
        // Empty, which is what an index on no columns would carry — and the case
        // a length-guessing decoder gets wrong.
        try await check(connection, "", "int2vector")
        try await check(connection, "23 25 1043", "oidvector")

        // And through the catalogs themselves, which is where they actually turn
        // up. A literal cast proves the decoder; this proves the OID is the one
        // the server really sends.
        let rows = try await connection.query(
            "SELECT indkey FROM pg_index WHERE indexrelid = 'pg_class_oid_index'::regclass"
        ).rows
        guard case .text(let indkey) = rows[0][0] else {
            Issue.record("pg_index.indkey decoded as \(rows[0][0])"); return
        }
        #expect(!indkey.isEmpty)
    }

    /// `xid8` is 64-bit where `xid` is 32, and reading it as a `UInt32` would
    /// silently take half of it.
    @Test("xid8 decodes as a 64-bit value")
    func xid8() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        // One statement, so both columns describe the *same* transaction id —
        // two calls would be two transactions and two different numbers.
        // `pg_current_xact_id()` also has the useful property of assigning a real
        // id rather than reporting a virtual one, so the value is stable within
        // the statement.
        let rows = try await connection.query(
            "SELECT pg_current_xact_id(), pg_current_xact_id()::text"
        ).rows
        guard case .int(let value) = rows[0][0] else {
            Issue.record("xid8 decoded as \(rows[0][0])"); return
        }
        guard case .text(let rendered) = rows[0][1] else {
            Issue.record("expected text, got \(rows[0][1])"); return
        }
        #expect(value > 0)
        // The comparison that catches a half-read: the low 32 bits alone would
        // still look like a perfectly plausible transaction id.
        #expect(String(value) == rendered)
    }

    /// **The two formats have to agree**, and for the integer-shaped system types
    /// they did not.
    ///
    /// `decodeBinary` returned `.int` for `xid`, `cid` and `xid8` while
    /// `decodeText` returned `.text`, so `row[0].int` was non-nil or nil
    /// depending on whether the query happened to carry a bound parameter — the
    /// extended protocol asks for binary, the simple protocol always gets text.
    /// Nothing in the SQL suggests that difference, and nothing was comparing the
    /// two for these types.
    @Test("system integer types decode the same in both formats")
    func systemIntegersAgreeAcrossFormats() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        // `$1` forces the extended protocol and binary; the bare literal forces
        // the simple protocol and text.
        for type in ["xid", "cid", "xid8", "oid"] {
            let binary = try await connection.query("SELECT $1::\(type)", [.text("42")]).rows
            let text = try await connection.query("SELECT '42'::\(type)").rows
            #expect(
                binary[0][0] == .int(42),
                "\(type) binary decoded as \(binary[0][0])"
            )
            #expect(binary[0][0] == text[0][0], "\(type): binary \(binary[0][0]), text \(text[0][0])")
        }
    }

    /// `regcollation` completes the `reg*` family, which was missing exactly one
    /// entry. Like its siblings it carries an OID in binary and a name in text,
    /// so only the binary side is compared here.
    @Test("regcollation decodes as an OID")
    func regcollation() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        let rows = try await connection.query("SELECT $1::regcollation", [.text("\"C\"")]).rows
        guard case .int(let oid) = rows[0][0] else {
            Issue.record("regcollation decoded as \(rows[0][0])"); return
        }
        #expect(oid > 0)
    }

    /// `aclitem` is what `pg_class.relacl` holds, and `refcursor` is what a
    /// function returning a cursor hands back.
    ///
    /// **`aclitem` has no binary output function at all** — `SELECT $1::aclitem`
    /// fails with `no binary output function available for type aclitem`, so it
    /// can only ever arrive as text. The OID entry still earns its place: without
    /// it the text form decodes through the unknown-OID path, and adding it keeps
    /// the type named rather than guessed. It is checked through the simple
    /// protocol only, because there is no second format to compare against.
    @Test("aclitem and refcursor are readable")
    func aclitemAndRefcursor() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        let acl = try await connection.query("SELECT 'swizzle=arwdDxt/swizzle'::aclitem").rows
        #expect(acl[0][0] == .text("swizzle=arwdDxt/swizzle"))

        // And where they actually occur: a table's ACL, as an aclitem[].
        let relacl = try await connection.query(
            "SELECT relacl FROM pg_class WHERE relname = 'pg_class'"
        ).rows
        #expect(relacl.count == 1)

        let rows = try await connection.query("SELECT $1::refcursor", [.text("my_cursor")]).rows
        #expect(rows[0][0] == .text("my_cursor"))
    }

    // MARK: - The gap that remains

    /// Types with no binary decoder are left **out** of the OID table on purpose.
    ///
    /// The decoder's `default` arm for a *known* OID returns `.blob`, whereas an
    /// unrecognised OID tries UTF-8 first — so adding an entry without a decoder
    /// would make the value strictly less useful. `tsvector` is the example.
    @Test("a type with no decoder is still readable")
    func undecodedTypesStayReadable() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        // Not in the OID table, so it falls back to UTF-8 rather than to bytes.
        let rows = try await connection.query(
            "SELECT $1::tsvector::text", [.text("a fat cat")]
        ).rows
        guard case .text = rows[0][0] else {
            Issue.record("expected readable text, got \(rows[0][0])"); return
        }
    }

    // MARK: - numeric

    /// `numeric` was not in this table, which is why its binary decoder's
    /// fraction handling had mutation survivors: the trailing-zero padding that
    /// makes `1.10` come back as `1.10` rather than `1.1` is a property of the
    /// *binary* form, and nothing compared the two formats for this type.
    ///
    /// The display scale is carried on the wire and the fraction is padded up to
    /// it, so the cases that matter are the ones where the digits and the scale
    /// disagree — a value with fewer significant digits than its scale, a value
    /// with none at all, and the sign.
    @Test("numeric agrees between binary and text")
    func numericAgrees() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        for literal in [
            "0", "1", "-1", "1.1", "1.10", "1.100", "0.001", "-0.001",
            "1234567890.12345", "-1234567890.12345",
            "0.00000000000001", "100000000000000",
            // Weight boundaries: the base-10000 groups either side of the point.
            "9999", "10000", "99999999", "0.0001", "0.00001",
            // Scale with no fraction, and a whole number carrying one.
            "123.000", "123.4560",
        ] {
            try await check(connection, literal, "numeric")
        }
    }

    /// `NaN` is a numeric value with no digits at all, and its own sign word.
    @Test("numeric NaN agrees between binary and text")
    func numericNaN() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }
        try await check(connection, "NaN", "numeric")
    }

    // MARK: - xid8

    /// A 64-bit transaction id is **unsigned**, and `SQLValue` has no unsigned
    /// case — so anything past `Int64.max` renders as text rather than wrapping
    /// into a negative. The boundary had a survivor, and nothing exercised it.
    ///
    /// Unreachable in practice, as the comment at the decoder says: the counter
    /// would need centuries. It is here because a silent wrap is precisely the
    /// failure that check exists to prevent, and an untested guard against an
    /// unreachable case is indistinguishable from no guard at all.
    @Test("xid8 agrees between binary and text, including past Int64.max")
    func xid8Agrees() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        for literal in [
            "0", "1", "4294967295",
            "9223372036854775807",   // Int64.max — the last value that fits
            "9223372036854775808",   // one past it, which must not become negative
            "18446744073709551615",  // UInt64.max
        ] {
            try await check(connection, literal, "xid8")
        }
    }

}

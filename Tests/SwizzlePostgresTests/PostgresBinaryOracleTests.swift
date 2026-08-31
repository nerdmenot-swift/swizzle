import NIOCore
import NIOPosix
import SwizzleCore
import SwizzlePostgresDriver
import Testing

/// Every type the driver decodes, checked against what the server prints.
///
/// ## Why this file exists
///
/// The driver's promise for these types is not "matches the wire format" — it is
/// **"a column reads identically whichever format it arrived in"**. A value
/// fetched over the extended protocol comes back in Postgres's binary encoding
/// and is decoded here; the same value fetched over the simple protocol comes
/// back as text the server rendered. Those two have to agree, or the same query
/// returns different strings depending on whether it had a parameter.
///
/// Three suites were written to check exactly that and could not fail, all the
/// same way:
///
/// ```swift
/// "SELECT (\(expression))::text, \(expression)"   // no bindings
/// ```
///
/// No bindings means the *simple* protocol, which returns **both** columns as
/// text — so it compared the server's rendering against the server's rendering.
/// `PostgresTextSearchTests` and `PostgresTemporalTests` both did this, and the
/// user-type fixtures were all one level deep, so the registry's resolution
/// rounds were never entered either.
///
/// Measured after the fact: 76 types have a dedicated binary decoder and roughly
/// 26 were checked against the server in binary. The rest — including every
/// temporal, `uuid`, `bytea`, `jsonb`, `inet` and every array — were verified
/// only by tests that could not fail.
///
/// ## Why the server and not `rust-postgres`
///
/// This driver was grounded on `rust-postgres`, and that reference could not have
/// caught most of what was wrong. Three of the bugs found here were in *rendering
/// to Postgres's text form* — how the server prints a composite, a `tsquery`, an
/// interval — which is a server behaviour rather than a codec the reference
/// implements. It has no multirange codec at all. A reference tells you the wire
/// format; it does not tell you what `psql` prints, and matching that is the
/// promise.
///
/// ## Completeness
///
/// The table below is checked against `PostgresOID.allCases`, so **adding a
/// decoder without adding a case here fails this suite**. Types that genuinely
/// cannot be compared this way are listed in `exempt` with the reason, which
/// keeps the omissions visible instead of implicit.
@Suite(
    "Postgres binary/text oracle",
    .enabled(if: PostgresTestServer.isAvailable, PostgresTestServer.skipReason)
)
struct PostgresBinaryOracleTests {

    static let url = PostgresTestServer.url

    /// Pinned to UTC, because `timestamptz`'s *text* form is rendered in the
    /// session's zone while its binary form is an absolute instant. Without
    /// this the comparison measures the server's locale rather than the codec —
    /// the first run failed on a machine set to +05:30 for exactly that reason.
    static func open() async throws -> PostgresConnection {
        let connection = try await PostgresConnection.connect(
            configuration: PostgresConnectionConfiguration(swizzleURL: url),
            on: MultiThreadedEventLoopGroup.singleton.next()
        )
        _ = try await connection.query("SET TimeZone TO 'UTC'")
        return connection
    }

    /// One type, its SQL spelling, and literals worth round-tripping.
    struct Subject {
        let oid: PostgresOID
        let sql: String
        let literals: [String]
    }

    /// Literals chosen for the edges rather than the middle: zero, the sign, the
    /// boundary of the representation, and whatever the renderer has to decide
    /// about — trailing zeros, empty elements, nulls inside a container.
    static let subjects: [Subject] = [
        .init(oid: .bool, sql: "bool", literals: ["true", "false"]),
        .init(oid: .bytea, sql: "bytea", literals: [#"\x"#, #"\xdeadbeef"#, #"\x00"#]),
        .init(oid: .char, sql: "\"char\"", literals: ["a", "Z"]),
        .init(oid: .name, sql: "name", literals: ["public", ""]),
        .init(oid: .int8, sql: "int8",
              literals: ["0", "1", "-1", "9223372036854775807", "-9223372036854775808"]),
        .init(oid: .int2, sql: "int2", literals: ["0", "1", "-1", "32767", "-32768"]),
        .init(oid: .int4, sql: "int4", literals: ["0", "1", "-1", "2147483647", "-2147483648"]),
        .init(oid: .text, sql: "text", literals: ["", "a", "a b", "ünïcødé", "a\nb"]),
        .init(oid: .oid, sql: "oid", literals: ["0", "1", "4294967295"]),
        .init(oid: .json, sql: "json", literals: [#"{"a":1}"#, "[]", "null"]),
        .init(oid: .xml, sql: "xml", literals: ["<a/>", "<a>b</a>"]),
        .init(oid: .float4, sql: "float4", literals: ["0", "1.5", "-1.5", "Infinity", "NaN"]),
        .init(oid: .float8, sql: "float8",
              literals: ["0", "1.5", "-1.5", "Infinity", "-Infinity", "NaN", "1e300"]),
        .init(oid: .bpchar, sql: "char(5)", literals: ["ab", "abcde"]),
        .init(oid: .varchar, sql: "varchar", literals: ["", "abc"]),
        .init(oid: .date, sql: "date",
              literals: ["2000-01-01", "1970-01-01", "1900-02-28", "2024-02-29", "0001-01-01"]),
        .init(oid: .time, sql: "time",
              literals: ["00:00:00", "23:59:59.999999", "12:34:56.5"]),
        .init(oid: .timestamp, sql: "timestamp",
              literals: ["2000-01-01 00:00:00", "1970-01-01 00:00:00",
                         "2024-03-05 14:30:00.123456", "0001-01-01 00:00:00"]),
        .init(oid: .timestamptz, sql: "timestamptz",
              literals: ["2000-01-01 00:00:00+00", "2024-03-05 14:30:00.123456+00"]),
        .init(oid: .interval, sql: "interval",
              literals: ["0", "1 year", "-1 year", "1 mon", "-1 mon", "1 day", "-1 day",
                         "1 year 2 mons 3 days 04:05:06.789", "-00:00:01.5", "-1 day -02:00:00"]),
        .init(oid: .timetz, sql: "timetz", literals: ["00:00:00+00", "12:34:56.5-05"]),
        .init(oid: .numeric, sql: "numeric",
              literals: ["0", "1", "-1", "1.10", "0.001", "NaN", "1234567890.12345"]),
        .init(oid: .uuid, sql: "uuid",
              literals: ["00000000-0000-0000-0000-000000000000",
                         "ffffffff-ffff-ffff-ffff-ffffffffffff",
                         "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"]),
        .init(oid: .jsonb, sql: "jsonb",
              literals: [#"{"a":1}"#, "[]", "null", #"{"b":[1,2,{"c":null}]}"#]),
        .init(oid: .tid, sql: "tid", literals: ["(0,1)", "(4294967295,65535)"]),
        .init(oid: .xid, sql: "xid", literals: ["0", "1", "4294967295"]),
        .init(oid: .cid, sql: "cid", literals: ["0", "1"]),
        .init(oid: .point, sql: "point", literals: ["(0,0)", "(1.5,-2.5)"]),
        .init(oid: .lseg, sql: "lseg", literals: ["[(0,0),(1,1)]"]),
        .init(oid: .path, sql: "path", literals: ["[(0,0),(1,1),(2,0)]", "((0,0),(1,1))"]),
        .init(oid: .box, sql: "box", literals: ["(1,1),(0,0)"]),
        .init(oid: .polygon, sql: "polygon", literals: ["((0,0),(1,1),(2,0))"]),
        .init(oid: .line, sql: "line", literals: ["{1,-1,0}"]),
        .init(oid: .cidr, sql: "cidr", literals: ["10.0.0.0/8", "::/0", "2001:db8::/32"]),
        .init(oid: .circle, sql: "circle", literals: ["<(0,0),1>"]),
        .init(oid: .macaddr8, sql: "macaddr8", literals: ["08:00:2b:01:02:03:04:05"]),
        .init(oid: .macaddr, sql: "macaddr", literals: ["08:00:2b:01:02:03"]),
        .init(oid: .inet, sql: "inet",
              literals: ["127.0.0.1", "10.0.0.1/8", "::1", "2001:db8::1",
                         "2001:0:1:2::3", "::", "2001:db8::/32"]),
        .init(oid: .bit, sql: "bit(5)", literals: ["00000", "10101"]),
        .init(oid: .varbit, sql: "varbit", literals: ["", "1", "10101010101"]),
        .init(oid: .pgLSN, sql: "pg_lsn", literals: ["0/0", "16/B374D848", "FFFFFFFF/FFFFFFFF"]),
        .init(oid: .tsvector, sql: "tsvector",
              literals: ["a fat cat", "cat:1A,2B", "'it''s':1", ""]),
        .init(oid: .tsquery, sql: "tsquery",
              literals: ["cat", "cat & rat", "cat | rat", "!cat", "cat <-> rat",
                         "(cat | rat) & dog", "cat:*A", "cat:AB"]),
        .init(oid: .jsonpath, sql: "jsonpath", literals: ["$.a", "$[*] ? (@ > 1)"]),
        .init(oid: .int4Range, sql: "int4range", literals: ["[1,10)", "empty", "(,5)", "[1,)"]),
        .init(oid: .numRange, sql: "numrange", literals: ["[1.5,10.25)", "empty"]),
        .init(oid: .tsRange, sql: "tsrange",
              literals: ["[2024-01-01,2024-02-01)", "empty"]),
        .init(oid: .tstzRange, sql: "tstzrange",
              literals: ["[2024-01-01 00:00:00+00,2024-02-01 00:00:00+00)"]),
        .init(oid: .dateRange, sql: "daterange", literals: ["[2024-01-01,2024-02-01)", "empty"]),
        .init(oid: .int8Range, sql: "int8range", literals: ["[1,10)", "empty"]),
        .init(oid: .int4Multirange, sql: "int4multirange",
              literals: ["{}", "{[1,5)}", "{[1,5),[10,20)}"]),
        .init(oid: .numMultirange, sql: "nummultirange", literals: ["{}", "{[1.5,5.5)}"]),
        .init(oid: .tsMultirange, sql: "tsmultirange",
              literals: ["{}", "{[2024-01-01,2024-02-01)}"]),
        .init(oid: .tstzMultirange, sql: "tstzmultirange",
              literals: ["{}", "{[2024-01-01 00:00:00+00,2024-02-01 00:00:00+00)}"]),
        .init(oid: .dateMultirange, sql: "datemultirange",
              literals: ["{}", "{[2024-01-01,2024-02-01)}"]),
        .init(oid: .int8Multirange, sql: "int8multirange", literals: ["{}", "{[1,5)}"]),
        .init(oid: .int2Vector, sql: "int2vector", literals: ["1 2 3", "0"]),
        .init(oid: .oidVector, sql: "oidvector", literals: ["1 2 3", "0"]),
        .init(oid: .xid8, sql: "xid8",
              literals: ["0", "9223372036854775807", "18446744073709551615"]),
        .init(oid: .refcursor, sql: "refcursor", literals: ["mycursor"]),

        // Arrays. The elements matter as much as the container: a null inside,
        // an empty string, and a value carrying the delimiters the text form
        // quotes with.
        .init(oid: .boolArray, sql: "bool[]", literals: ["{}", "{t,f}", "{t,NULL}"]),
        .init(oid: .int2Array, sql: "int2[]", literals: ["{}", "{1,-1}", "{1,NULL}"]),
        .init(oid: .int4Array, sql: "int4[]", literals: ["{}", "{1,2,3}", "{NULL}"]),
        .init(oid: .int8Array, sql: "int8[]", literals: ["{}", "{9223372036854775807}"]),
        .init(oid: .textArray, sql: "text[]",
              literals: ["{}", "{a,b}", "{NULL}", #"{"",a}"#, #"{"a,b","c\"d"}"#,
                         #"{"NULL"}"#, "{{1,2},{3,4}}"]),
        .init(oid: .varcharArray, sql: "varchar[]", literals: ["{}", "{a,b}"]),
        .init(oid: .float4Array, sql: "float4[]", literals: ["{}", "{1.5,-1.5}"]),
        .init(oid: .float8Array, sql: "float8[]", literals: ["{}", "{1.5,NaN}"]),
        .init(oid: .numericArray, sql: "numeric[]", literals: ["{}", "{1.10,0.001}"]),
        .init(oid: .uuidArray, sql: "uuid[]",
              literals: ["{}", "{00000000-0000-0000-0000-000000000000}"]),
        .init(oid: .jsonbArray, sql: "jsonb[]", literals: ["{}", #"{"{\"a\": 1}"}"#]),
        .init(oid: .timestampArray, sql: "timestamp[]",
              literals: ["{}", #"{"2024-03-05 14:30:00"}"#]),
        .init(oid: .timestamptzArray, sql: "timestamptz[]",
              literals: ["{}", #"{"2024-03-05 14:30:00+00"}"#]),
    ]

    /// Types with a decoder but no meaningful binary/text comparison, and why.
    ///
    /// Listed rather than omitted: an exemption with a reason is a decision, an
    /// absence is an oversight, and only one of those survives a refactor.
    static let exempt: [PostgresOID: String] = [
        .money: "its text form carries lc_monetary's symbol and separators while the\n            binary form is a bare number, so the two differ by design. Covered\n            against literals in PostgresExtendedTypeTests instead",
        .unknown: "the OID for an untyped literal; a column never has it",
        .cstring: "internal to function calls — no SQL type accepts a cast",
        .aclitem: "no binary send function; the server refuses to send it in binary",
        .gtsvector: "an index-internal type with no stable external form",
        .txidSnapshot: "deprecated in favour of pg_snapshot, and its text form is transient",
        .regproc: "an OID rendered as a name that depends on search_path",
        .regprocedure: "as regproc",
        .regoper: "as regproc",
        .regoperator: "as regproc",
        .regclass: "as regproc",
        .regtype: "as regproc",
        .regconfig: "as regproc",
        .regdictionary: "as regproc",
        .regnamespace: "as regproc",
        .regrole: "as regproc",
        .regcollation: "as regproc",
    ]

    // MARK: - The oracle

    /// Binary against text, for one literal.
    ///
    /// `$1` forces the extended protocol, which asks for binary results; the
    /// quoted literal takes the simple protocol and gets the server's own
    /// rendering. Comparing those two is the whole point — and doing it in one
    /// statement, as three other suites did, defeats it entirely.
    static func agree(
        _ connection: PostgresConnection, _ literal: String, _ sql: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let binary = try await connection.queryResolvingTypes(
            "SELECT $1::\(sql)", [.text(literal)]
        ).rows
        let quoted = literal.replacingOccurrences(of: "'", with: "''")
        let text = try await connection.query("SELECT '\(quoted)'::\(sql)").rows
        #expect(
            Self.same(binary.first?[0], text.first?[0]),
            "\(sql) '\(literal)': binary \(binary.first?[0] as Any), text \(text.first?[0] as Any)",
            sourceLocation: sourceLocation
        )
    }

    /// Equality that treats two NaNs as the same value.
    ///
    /// IEEE 754 says `NaN != NaN`, so `.double(nan) == .double(nan)` is false and
    /// the oracle reported a mismatch between two identical values. That is the
    /// comparison being wrong rather than the driver — the whole question here is
    /// whether the two formats produced the *same* value, and they did.
    static func same(_ lhs: SQLValue?, _ rhs: SQLValue?) -> Bool {
        if case .double(let a)? = lhs, case .double(let b)? = rhs, a.isNaN, b.isNaN {
            return true
        }
        return lhs == rhs
    }

    @Test("every literal decodes the same from binary as the server renders it",
          arguments: subjects)
    func binaryMatchesText(subject: Subject) async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }
        for literal in subject.literals {
            try await Self.agree(connection, literal, subject.sql)
        }
    }

    // MARK: - Completeness

    /// The guard that keeps this file honest.
    ///
    /// A decoder added to `PostgresOID` without a subject or an exemption fails
    /// here, which is the only way a table like this stays complete. The
    /// alternative — noticing later — is what left fifty types unchecked.
    @Test("every OID the driver knows is either covered or exempt with a reason")
    func everyOIDIsAccountedFor() {
        let covered = Set(Self.subjects.map(\.oid))
        let exempted = Set(Self.exempt.keys)
        let missing = PostgresOID.allCases.filter {
            !covered.contains($0) && !exempted.contains($0)
        }
        #expect(
            missing.isEmpty,
            Comment(rawValue: "these OIDs have a decoder but no oracle case and no"
                + " exemption: " + missing.map { "\($0)" }.joined(separator: ", "))
        )
        #expect(
            covered.isDisjoint(with: exempted),
            "an OID cannot be both covered and exempt"
        )
    }
}

extension PostgresBinaryOracleTests.Subject: CustomStringConvertible {
    var description: String { sql }
}

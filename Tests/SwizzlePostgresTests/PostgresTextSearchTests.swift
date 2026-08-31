import NIOCore
import NIOPosix
import SwizzleCore
import SwizzlePostgresDriver
import Testing

/// `tsvector` and `jsonpath` — the two types left unlisted by the reference
/// verification that turned out to have decoders worth writing.
///
/// Verified the same way as the rest: the driver's binary decode against the
/// server's own text rendering of the same value, so Postgres is the oracle.
@Suite(
    "Postgres text search types", .serialized,
    .enabled(if: PostgresTestServer.isAvailable, PostgresTestServer.skipReason)
)
struct PostgresTextSearchTests {

    static let url = PostgresTestServer.url

    static func open() async throws -> PostgresConnection {
        try await PostgresConnection.connect(
            configuration: PostgresConnectionConfiguration(swizzleURL: url),
            on: MultiThreadedEventLoopGroup.singleton.next()
        )
    }

    /// Fetches an expression twice: once as the server renders it, once as the
    /// driver decodes the binary form. One statement, so both are the same value.
    func agree(
        _ connection: PostgresConnection, _ expression: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let rows = try await connection.query(
            "SELECT (\(expression))::text, \(expression)"
        ).rows
        #expect(
            rows[0][0] == rows[0][1],
            "\(expression): server \(rows[0][0]), driver \(rows[0][1])",
            sourceLocation: sourceLocation
        )
    }

    // MARK: - tsvector

    /// Each position is a packed `UInt16` — **weight in the top two bits, position
    /// in the low fourteen** — so reading it whole gives positions in the tens of
    /// thousands. Confirmed against `pgx/pgtype/tsvector.go`.
    @Test("tsvector matches the server's rendering")
    func tsvector() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        for text in ["a fat cat sat on a mat", "the quick brown fox", "single", ""] {
            try await agree(connection, "to_tsvector('simple', '\(text)')")
        }
    }

    /// The weight encoding is inverted from the obvious guess: `3` is `A` and `0`
    /// is `D` — and `D` is the default, so printing it would disagree with the
    /// server.
    @Test("weights round-trip, and the default weight stays invisible")
    func weights() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        try await agree(connection, "setweight(to_tsvector('simple','cat dog'),'A')")
        try await agree(connection, "setweight(to_tsvector('simple','cat dog'),'B')")
        try await agree(connection, "setweight(to_tsvector('simple','cat dog'),'C')")
        // D is the default and is not printed.
        try await agree(connection, "setweight(to_tsvector('simple','cat dog'),'D')")
        // Mixed weights in one vector.
        try await agree(
            connection,
            "setweight(to_tsvector('simple','cat'),'A') || "
                + "setweight(to_tsvector('simple','dog'),'C')"
        )
    }

    /// A lexeme is single-quoted, so a quote inside one has to be doubled — the
    /// classic place a hand-rolled renderer diverges.
    @Test("a lexeme containing a quote is escaped as the server escapes it")
    func quotedLexeme() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        try await agree(connection, "to_tsvector('simple', 'it''s fine')")
        try await agree(connection, "'''quoted'''::tsvector")
    }

    /// Many positions on one lexeme, and enough lexemes to cross a read boundary.
    @Test("a large tsvector reassembles exactly")
    func largeVector() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        try await agree(
            connection,
            "to_tsvector('simple', repeat('alpha beta gamma delta ', 200))"
        )
    }

    // MARK: - jsonpath

    /// The same shape as `jsonb`, and the same trap: a leading version byte that
    /// is not part of the expression.
    @Test("jsonpath strips its version byte")
    func jsonpath() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        for expression in [
            "$.a.b",
            "$[*] ? (@ > 2)",
            "strict $.store.book[*].price",
            "$.floor[*].apt[*] ? (@.area > 40 && @.area < 90)",
        ] {
            try await agree(connection, "'\(expression)'::jsonpath")
        }
    }

    // MARK: - The reg* family, where the two formats genuinely differ

    /// **The one family where binary and text cannot agree**, and the exception
    /// to the contract every other type here keeps.
    ///
    /// The wire carries an OID; the text form carries the *name* that OID
    /// resolves to. Matching them would need a catalogue lookup per value, on a
    /// family of types that exists for tooling rather than application data — so
    /// the OID is decoded honestly and `::text` remains the way to ask for a name.
    ///
    /// Before this, binary `regclass` was four bytes that were not valid UTF-8,
    /// so it came back as an opaque blob. An integer is strictly better.
    @Test("reg types decode their OID, and text still gives the name")
    func regTypes() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        // Binary: the OID, which is a number that matches pg_class.
        let binary = try await connection.query(
            "SELECT $1::regclass", [.text("pg_class")]
        ).rows
        guard case .int(let oid) = binary[0][0] else {
            Issue.record("expected an OID, got \(binary[0][0])"); return
        }
        #expect(oid > 0)

        let expected = try await connection.query(
            "SELECT oid FROM pg_class WHERE relname = 'pg_class'"
        ).rows
        #expect(expected[0][0] == .int(oid))

        // Text: the name, which is what the simple protocol delivers.
        let text = try await connection.query("SELECT 'pg_class'::regclass").rows
        #expect(text[0][0] == .text("pg_class"))

        // And `regtype`, to show it is the family and not one type.
        let regtype = try await connection.query("SELECT 'int4'::regtype").rows
        #expect(regtype[0][0] == .text("integer"))
    }

    // MARK: - What is still not decoded, and why

    // MARK: - tsquery

    /// **A corpus, not a handful of cases.**
    ///
    /// Reading the tree is easy; printing it back the way Postgres does is not.
    /// The server emits the *minimum* parentheses, so a fully-parenthesised
    /// rendering would be semantically identical and textually different — which
    /// is worse than not decoding, because it looks right and compares unequal.
    ///
    /// Every precedence pairing appears here in both orders, because the rule is
    /// asymmetric: a child is wrapped when its precedence is lower than its
    /// parent's, or equal *and* it is the right operand of a phrase operator.
    @Test("tsquery renders exactly as the server does")
    func tsquery() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        for expression in [
            // Flat
            "cat", "cat & rat", "cat | rat", "!cat", "cat <-> rat", "cat <3> rat",
            // Precedence, both ways round
            "cat & rat | dog", "cat | rat & dog",
            "(cat | rat) & dog", "cat & (rat | dog)",
            "cat <-> rat & dog", "cat & rat <-> dog",
            "!cat & rat", "!(cat & rat)", "!cat | rat", "!(cat | rat)",
            // Phrase is not associative, which is the case equal precedence has
            // to get right.
            "cat <-> rat <-> dog", "cat <-> (rat <-> dog)", "(cat <-> rat) <-> dog",
            "cat <2> (rat <3> dog)",
            // Nested and deep
            "(cat | rat) & (dog | fox)", "!(cat & (rat | !dog))",
            "a & b & c & d", "a | b | c | d", "((a | b) & c) | d",
            // Weights and prefixes
            "cat:A", "cat:AB", "cat:*", "cat:*A", "cat:ABCD",
            "cat:A & rat:*B",
            // Quoting
            "'it''s'", "'a b'",
        ] {
            try await agree(connection, "'\(expression.replacingOccurrences(of: "'", with: "''"))'::tsquery")
        }
    }

    /// `to_tsquery` and `plainto_tsquery` build trees the parser would not, so
    /// they exercise shapes the literal forms above miss.
    @Test("tsquery built by the server's own parsers matches too")
    func tsqueryFromParsers() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        for expression in [
            "to_tsquery('simple', 'cat & rat')",
            "plainto_tsquery('simple', 'the quick brown fox')",
            "phraseto_tsquery('simple', 'quick brown fox')",
            "websearch_to_tsquery('simple', '\"quick brown\" -fox')",
            "to_tsquery('simple', 'cat') && to_tsquery('simple', 'rat')",
            "to_tsquery('simple', 'cat') || to_tsquery('simple', 'rat')",
            "!!to_tsquery('simple', 'cat')",
        ] {
            try await agree(connection, expression)
        }
    }

    /// The empty query prints as nothing, and must not be mistaken for a decode
    /// failure.
    @Test("an empty tsquery is empty, not a blob")
    func emptyTSQuery() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        let rows = try await connection.query(
            "SELECT $1::tsquery", [.text("")]
        ).rows
        #expect(rows[0][0] == .text(""))
    }

    /// Proof that `agree` above was tautological for the binary path, kept as a
    /// test because the property it asserts is the one that matters.
    ///
    /// `connection.query(sql)` with no bindings uses the **simple** protocol,
    /// which returns every value in *text* format. So `SELECT expr::text, expr`
    /// compared the server's rendering against the server's rendering: the
    /// binary decoder never ran, and could not fail. Thirteen mutation survivors
    /// in the `tsquery` renderer said so before anyone noticed.
    ///
    /// Passing a binding forces the extended protocol, which asks for binary
    /// results — so this runs the decoder those tests were written for.
    func agreeInBinary(
        _ connection: PostgresConnection, _ expression: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        // The binding is unused by the projection; it is there to make the
        // driver take the extended path.
        let rows = try await connection.query(
            "SELECT (\(expression))::text, \(expression) WHERE $1::bool", [.bool(true)]
        ).rows
        #expect(
            rows.first?[0] == rows.first?[1],
            "\(expression): server \(rows.first?[0] as Any), driver \(rows.first?[1] as Any)",
            sourceLocation: sourceLocation
        )
    }

    @Test("tsquery decodes from binary exactly as the server renders it")
    func tsqueryInBinary() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        for expression in [
            "cat", "cat & rat", "cat | rat", "!cat", "cat <-> rat", "cat <3> rat",
            "cat & rat | dog", "cat | rat & dog",
            "(cat | rat) & dog", "cat & (rat | dog)",
            "cat <-> rat & dog", "cat & rat <-> dog",
            "!cat & rat", "!(cat & rat)", "!cat | rat", "!(cat | rat)",
            "cat <-> rat <-> dog", "cat <-> (rat <-> dog)", "(cat <-> rat) <-> dog",
            "cat <2> (rat <3> dog)",
            "(cat | rat) & (dog | fox)", "!(cat & (rat | !dog))",
            "a & b & c & d", "a | b | c | d", "((a | b) & c) | d",
            "cat:A", "cat:AB", "cat:*", "cat:*A", "cat:ABCD", "cat:A & rat:*B",
            "'it''s'", "'a b'",
        ] {
            let escaped = expression.replacingOccurrences(of: "'", with: "''")
            try await agreeInBinary(connection, "'\(escaped)'::tsquery")
        }
    }

    @Test("tsvector decodes from binary exactly as the server renders it")
    func tsvectorInBinary() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        for expression in [
            "a fat cat", "a:1 fat:2 cat:3", "cat:1A", "cat:2B,3C", "cat:1A,2B,3C,4D",
            "'it''s':1", "'a b':1", "cat", "", "cat:1 dog:2,3 fox:4A",
        ] {
            let escaped = expression.replacingOccurrences(of: "'", with: "''")
            try await agreeInBinary(connection, "'\(escaped)'::tsvector")
        }
    }

}

import Testing

@testable import Swizzle

/// The `raw(_:_:)` scanner at the end of its input.
///
/// ## Where these came from
///
/// A mutation run over `SwizzleQuery` left thirteen survivors and eight are in
/// this one scanner, every one of them a `while index < characters.count`
/// relaxed to `<=`. That mutation reads one character past the end of the
/// string, which is a crash rather than a wrong answer — and the whole suite
/// stayed green, so nothing was driving the scanner to its boundary.
///
/// The scanner tracks string literals, quoted identifiers, line comments and
/// block comments so a `?` inside one is not mistaken for a placeholder. Each of
/// those is a small loop with its own end-of-input check, and each check is only
/// exercised by SQL that *ends inside* the construct — unterminated, which is
/// exactly what nobody writes on purpose and what arrives when SQL is
/// concatenated, truncated in a log, or pasted at a line break.
///
/// The placeholder counts below are what the documented rule gives: a `?`
/// inside a literal or comment is not a placeholder, and `??` is an escaped
/// literal `?`.
@Suite("Raw placeholder boundaries")
struct RawPlaceholderBoundaryTests {

    /// Renders the fragment and reports how many placeholders it found, or nil
    /// if the scan produced a mismatch against the values supplied.
    static func placeholderCount(_ sql: String, values: [SQLValue] = []) -> Int? {
        let fragment = SQLFragment.raw(sql, values)
        if let mismatch = fragment.mismatch { return mismatch.placeholders }
        return values.count
    }

    /// Scanning must terminate and must not read past the end for SQL that stops
    /// inside each construct the scanner tracks.
    @Test(
        "SQL ending inside any construct is scanned without running off the end",
        arguments: [
            "",                       // nothing at all
            "?",                      // a placeholder and immediately the end
            "??",                     // an escaped literal, ending exactly after it
            "?",                      // trailing placeholder
            "SELECT '",               // ends opening a string literal
            "SELECT 'a",              // ends inside one
            "SELECT 'a\\",            // ends on an escape inside one
            "SELECT \"",              // ends opening a quoted identifier
            "SELECT `",               // ends opening a backquoted identifier
            "SELECT -",               // a lone dash: the two-character comment lookahead
            "SELECT --",              // ends opening a line comment
            "SELECT -- trailing",     // ends inside one, with no newline
            "SELECT /",               // a lone slash
            "SELECT /*",              // ends opening a block comment
            "SELECT /* trailing",     // ends inside one, unterminated
            "SELECT /* a * b",        // a star that does not close it
            "SELECT '?",              // a placeholder inside an unterminated string
            "SELECT -- ?",            // and inside an unterminated comment
            "SELECT /* ? ",           // and inside an unterminated block comment
        ]
    )
    func scanningTerminatesAtEveryBoundary(sql: String) {
        // No assertion on the value: the input is malformed SQL and any reading
        // of it is defensible. Terminating, and not indexing past the end, is
        // the property.
        _ = SQLFragment.raw(sql, [])
    }

    /// **A `?` inside an unterminated construct is still not a placeholder.**
    /// The end-of-input checks are what stop the scanner falling out of the
    /// construct and treating the rest as ordinary SQL.
    @Test("a placeholder inside an unterminated construct is not counted")
    func unterminatedConstructsSwallowTheirPlaceholders() {
        #expect(SQLFragment.raw("SELECT '?", []).mismatch == nil, "inside a string")
        #expect(SQLFragment.raw("SELECT -- ?", []).mismatch == nil, "inside a line comment")
        #expect(SQLFragment.raw("SELECT /* ? ", []).mismatch == nil, "inside a block comment")
    }

    /// And the terminated forms agree, which is what makes the check above about
    /// the boundary rather than about the construct.
    @Test("a placeholder inside a closed construct is not counted either")
    func closedConstructsSwallowTheirPlaceholders() {
        #expect(SQLFragment.raw("SELECT 'why?' FROM t", []).mismatch == nil)
        #expect(SQLFragment.raw("SELECT 1 -- why?\nFROM t", []).mismatch == nil)
        #expect(SQLFragment.raw("SELECT /* why? */ 1", []).mismatch == nil)
    }

    /// **The control.** Real placeholders are still found, so a scanner that
    /// gave up at the first boundary would not satisfy these.
    @Test("placeholders outside every construct are still counted")
    func realPlaceholdersAreCounted() {
        let two = SQLFragment.raw(
            "SELECT id FROM t WHERE a = ? AND b = ?", [.int(1), .int(2)]
        )
        #expect(two.mismatch == nil, "two placeholders, two values")

        let short = SQLFragment.raw("SELECT ? , ?", [.int(1)])
        #expect(short.mismatch?.placeholders == 2, "two found, one value given")
        #expect(short.mismatch?.values == 1)
    }

    /// A doubled `?` is an escaped literal and not a placeholder — including
    /// when it is the last thing in the string, where the lookahead runs to the
    /// boundary.
    @Test("a doubled question mark is a literal, including at the very end")
    func doubledQuestionMarkIsLiteral() {
        #expect(SQLFragment.raw("SELECT '??'", []).mismatch == nil)
        #expect(SQLFragment.raw("SELECT ??", []).mismatch == nil, "at the end of the string")
        #expect(
            SQLFragment.raw("SELECT ??, ?", [.int(1)]).mismatch == nil,
            "an escaped literal followed by a real placeholder"
        )
    }
}

/// Splits a script into individual statements.
///
/// Sounds trivial and is not. `split(separator: ";")` breaks on the first
/// semicolon that lives inside a string literal, a comment, a quoted identifier,
/// or a trigger body — and every one of those appears in real migrations. The
/// failure is also nasty: the script does not error, it runs *half* a statement,
/// which on MySQL cannot be rolled back.
///
/// So this is a small lexer. It tracks whatever it is currently inside and only
/// treats a `;` as a boundary at the top level.
///
/// The rules differ per database, which is why ``Syntax`` exists rather than one
/// permissive superset. Being too permissive is not safe: Postgres treats a
/// backslash in an ordinary string literal as a literal backslash, so consuming
/// `\'` as an escape there would run past the true end of the string and swallow
/// the rest of the file.
public struct SQLStatementSplitter: Sendable {

    /// The lexical rules of one dialect.
    public struct Syntax: Sendable, Equatable {
        /// `'a\'b'` — MySQL, unless `NO_BACKSLASH_ESCAPES` is set. Standard SQL
        /// says a backslash is just a character.
        public var backslashEscapes: Bool
        /// `$$ … $$` and `$tag$ … $tag$` — Postgres, and the only sane way to
        /// write a function body. Everything inside is literal.
        public var dollarQuoting: Bool
        /// `` `name` `` — MySQL's quoted identifier.
        public var backtickIdentifiers: Bool
        /// `# comment` — MySQL only.
        public var hashComments: Bool
        /// Recognise `BEGIN … END` routine bodies and ignore the semicolons
        /// inside them.
        ///
        /// On for MySQL and SQLite, whose triggers and procedures carry an
        /// inline compound body. Off for Postgres, where a function body is
        /// dollar-quoted and therefore already handled — and where a bare
        /// `BEGIN` is far more likely to be a transaction.
        public var compoundStatements: Bool

        public init(
            backslashEscapes: Bool = false,
            dollarQuoting: Bool = false,
            backtickIdentifiers: Bool = false,
            hashComments: Bool = false,
            compoundStatements: Bool = false
        ) {
            self.backslashEscapes = backslashEscapes
            self.dollarQuoting = dollarQuoting
            self.backtickIdentifiers = backtickIdentifiers
            self.hashComments = hashComments
            self.compoundStatements = compoundStatements
        }

        public static let mysql = Syntax(
            backslashEscapes: true, backtickIdentifiers: true, hashComments: true,
            compoundStatements: true
        )
        public static let postgres = Syntax(dollarQuoting: true)
        public static let sqlite = Syntax(compoundStatements: true)
    }

    public let syntax: Syntax

    public init(syntax: Syntax) {
        self.syntax = syntax
    }

    /// Splits `script`, dropping statements that are only whitespace or comments.
    ///
    /// Comments are *kept* inside the statements they belong to rather than
    /// stripped: a migration's comments are worth having in the server's slow
    /// log and error messages, and stripping them means reconstructing the SQL
    /// rather than passing through what was written.
    public func split(_ script: String) -> [String] {
        var statements: [String] = []
        var current = ""
        var block = CompoundTracker(enabled: syntax.compoundStatements)

        /// Nothing but whitespace and comments — a trailing `;` after the last
        /// real statement, or a file that is only a header.
        func flush() {
            if !isBlank(current) { statements.append(trimmed(current)) }
            current = ""
            block.reset()
        }

        // The walk itself lives in `SQLScanner`, which knows the same per-dialect
        // rules this file used to implement inline. Everything that is *not*
        // executable SQL — strings, quoted identifiers, dollar-quoted bodies,
        // comments — comes back as one region and is copied through verbatim,
        // which is exactly the old behaviour: a `;` inside any of them was never
        // a statement boundary.
        //
        // What remains here is the part that is genuinely the splitter's own: the
        // semicolon rule, and the compound-body tracker that has to see the same
        // tokens the server would.
        SQLScanner(syntax: syntax).forEachRegion(script) { region, text in
            guard region == .code else {
                // A quoted or commented run is one token as far as `BEGIN … END`
                // detection is concerned, so the tracker sees a boundary rather
                // than the contents — a comment containing the word END must not
                // close a trigger body.
                block.feed(" ")
                current += text
                return
            }

            for character in text {
                block.feed(character)
                current.append(character)
                // A semicolon inside `BEGIN … END` belongs to the body, not to
                // the file. Before auto-detection this required
                // `-- +swizzle StatementBegin`, and forgetting it silently cut a
                // trigger into fragments — the exact corruption the splitter
                // exists to prevent.
                if character == ";", !block.isInsideBody { flush() }
            }
        }
        flush()
        return statements
    }

    private func peek(_ characters: [Character], _ index: Int) -> Character? {
        index < characters.count ? characters[index] : nil
    }

    // MARK: - Blankness

    /// Whether a fragment carries no executable SQL.
    ///
    /// Comment-aware, because a file ending in a trailing comment would
    /// otherwise produce a final "statement" of nothing but that comment, which
    /// the server rejects as empty.
    private func isBlank(_ text: String) -> Bool {
        var characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace || character == ";" {
                index += 1
            } else if character == "-", peek(characters, index + 1) == "-" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
            } else if syntax.hashComments, character == "#" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
            } else if character == "/", peek(characters, index + 1) == "*" {
                index += 2
                while index < characters.count,
                      !(characters[index] == "*" && peek(characters, index + 1) == "/") {
                    index += 1
                }
                index = min(index + 2, characters.count)
            } else {
                return false
            }
        }
        return true
    }

    private func trimmed(_ text: String) -> String {
        var result = text
        while let last = result.last, last.isWhitespace || last == ";" { result.removeLast() }
        while let first = result.first, first.isWhitespace { result.removeFirst() }
        return result
    }
}


/// Tracks whether the scanner is inside a `BEGIN … END` routine body.
///
/// Deliberately not a SQL parser. It answers one question — is this semicolon
/// inside a compound body — and everything here exists because the naive
/// answers are wrong:
///
/// - `BEGIN` on its own starts a **transaction**, so the counter only runs once
///   a routine definition has been seen.
/// - `END IF`, `END WHILE`, `END LOOP`, `END CASE` and `END REPEAT` all contain
///   `END` and none of them closes the block.
/// - Bodies nest, so it is a depth counter rather than a flag.
/// - A body need not be compound at all: `CREATE TRIGGER … FOR EACH ROW SET
///   NEW.a = 1;` ends at that semicolon, and depth never leaves zero.
///
/// What it deliberately does **not** cover: a routine whose body is a bare
/// control structure rather than a block — `CREATE PROCEDURE p() IF … THEN …;
/// END IF;` is legal and splits wrongly here. Extending the counter to treat
/// `IF`/`CASE` as openers would collide with `IF(a, b, c)` the function and
/// `CASE … END` the expression, and a false positive there would swallow
/// migrations that work today. That trade is worse than asking for
/// `-- +swizzle StatementBegin` in a rare case, which is what it is for.
struct CompoundTracker {
    let enabled: Bool

    private var word = ""
    private var sawCreate = false
    private var inRoutine = false
    private var depth = 0
    /// `BEGIN` with nothing before it might be a transaction, so judgement is
    /// deferred one word to see whether `NOT ATOMIC` follows.
    private var pendingBegin = false
    /// `END` waits for the next word before deciding: `END IF` closes nothing.
    private var pendingEnd = false

    /// Keywords that turn `END` into the end of a *control structure* rather
    /// than the end of the body.
    private static let notBlockEnd: Set<String> = ["IF", "WHILE", "LOOP", "CASE", "REPEAT"]

    private static let routineKeywords: Set<String> = [
        "TRIGGER", "PROCEDURE", "FUNCTION", "EVENT",
    ]

    init(enabled: Bool) { self.enabled = enabled }

    var isInsideBody: Bool { enabled && depth > 0 }

    mutating func reset() {
        word = ""
        sawCreate = false
        inRoutine = false
        depth = 0
        pendingEnd = false
        pendingBegin = false
    }

    mutating func feed(_ character: Character) {
        guard enabled else { return }

        if character.isLetter || character == "_" {
            word.append(character)
            return
        }
        if !word.isEmpty {
            finish(word.uppercased())
            word = ""
        }

        // `END` defers its decision until it can see the next word, because
        // `END IF` closes nothing. But `END;` has no next word — so the
        // semicolon resolves it, and must do so *before* the caller asks
        // whether this semicolon is inside the body.
        if character == ";", pendingEnd {
            pendingEnd = false
            depth = max(0, depth - 1)
        }
    }

    private mutating func finish(_ token: String) {
        // `BEGIN NOT ATOMIC` is MariaDB's anonymous compound block. It is worth
        // recognising because the token pair is unambiguous — a transaction is
        // never written that way — so there is no risk of swallowing a file.
        if pendingBegin {
            pendingBegin = false
            if token == "NOT" {
                inRoutine = true
                depth += 1
            }
        }

        // `END` deferred its decision until it could see what followed.
        if pendingEnd {
            pendingEnd = false
            if !Self.notBlockEnd.contains(token) {
                depth = max(0, depth - 1)
            }
            // Fall through: this token still gets its own turn, so
            // `END END` and `END; BEGIN` both behave.
        }

        switch token {
        case "CREATE":
            sawCreate = true
        case _ where Self.routineKeywords.contains(token):
            // `CREATE TRIGGER`, not `DROP TRIGGER` — only a definition has a
            // body to be inside.
            if sawCreate { inRoutine = true }
        case "BEGIN":
            // Only inside a routine. Outside one, `BEGIN` starts a transaction
            // and counting it would swallow the rest of the file — so a bare
            // `BEGIN` waits to see whether `NOT ATOMIC` follows.
            if inRoutine {
                depth += 1
            } else {
                pendingBegin = true
            }
        case "END":
            if inRoutine, depth > 0 { pendingEnd = true }
        default:
            break
        }
    }
}

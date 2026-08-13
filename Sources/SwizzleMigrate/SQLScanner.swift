import SwizzleCore

/// Walks SQL text and says which parts are code and which are not.
///
/// Anything that wants to look for a keyword has to know that the keyword might
/// be inside a string, a quoted identifier or a comment — where it means nothing.
/// This is the third place in the codebase that needs that knowledge, after the
/// statement splitter and the renderer's dead-binding check, so it is written
/// once here rather than a third time.
///
/// It reuses ``SQLStatementSplitter/Syntax`` rather than inventing its own rules,
/// because those rules are already the per-dialect truth: backslash escapes on
/// MySQL, dollar quoting on Postgres, backticks and `#` comments on MySQL.
///
/// `SQLStatementSplitter` runs on this too. It used to carry its own copy of the
/// walk — 118 lines of it — which was left in place when this type was written
/// and then removed once the code generator had proved the scanner against real
/// SQL. The splitter keeps only what is genuinely its own: the semicolon rule and
/// the compound-body (`BEGIN … END`) tracker.
struct SQLScanner {
    enum Region: Equatable {
        /// Executable SQL. The only place a keyword means what it says.
        case code
        /// A `'…'` literal, a `"…"`/`` `…` `` identifier, or a `$tag$…$tag$` body.
        case quoted
        /// `--`, `#`, or `/* … */`.
        case comment
    }

    let syntax: SQLStatementSplitter.Syntax

    init(syntax: SQLStatementSplitter.Syntax) {
        self.syntax = syntax
    }

    /// Calls `body` for each maximal run of one kind, in order.
    ///
    /// Regions are handed over as substrings rather than ranges: every caller so
    /// far wants the text, and substrings share storage.
    func forEachRegion(_ sql: String, _ body: (Region, Substring) -> Void) {
        let characters = Array(sql)
        var index = 0
        var codeStart = 0

        func flushCode(upTo end: Int) {
            guard end > codeStart else { return }
            body(.code, Substring(String(characters[codeStart..<end])))
        }

        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil

            switch character {
            case "'":
                flushCode(upTo: index)
                index = consumeQuoted(characters, from: index, terminator: "'", body)
                codeStart = index

            case "\"":
                flushCode(upTo: index)
                index = consumeQuoted(characters, from: index, terminator: "\"", body)
                codeStart = index

            case "`" where syntax.backtickIdentifiers:
                flushCode(upTo: index)
                index = consumeQuoted(characters, from: index, terminator: "`", body)
                codeStart = index

            case "$" where syntax.dollarQuoting:
                if let tag = dollarTag(characters, at: index) {
                    flushCode(upTo: index)
                    index = consumeDollarQuoted(characters, from: index, tag: tag, body)
                    codeStart = index
                } else {
                    index += 1
                }

            case "-" where next == "-":
                flushCode(upTo: index)
                index = consumeLine(characters, from: index, body)
                codeStart = index

            case "#" where syntax.hashComments:
                flushCode(upTo: index)
                index = consumeLine(characters, from: index, body)
                codeStart = index

            case "/" where next == "*":
                flushCode(upTo: index)
                index = consumeBlockComment(characters, from: index, body)
                codeStart = index

            default:
                index += 1
            }
        }
        flushCode(upTo: characters.count)
    }

    /// Consumes through the closing quote, honouring both escape conventions: a
    /// doubled quote, which is standard, and a backslash, which is MySQL's
    /// default unless `NO_BACKSLASH_ESCAPES` is set.
    private func consumeQuoted(
        _ characters: [Character], from start: Int, terminator: Character,
        _ body: (Region, Substring) -> Void
    ) -> Int {
        var index = start + 1
        while index < characters.count {
            let character = characters[index]
            if syntax.backslashEscapes, character == "\\", index + 1 < characters.count {
                index += 2
                continue
            }
            if character == terminator {
                // A doubled terminator is an escaped one, not the end.
                if index + 1 < characters.count, characters[index + 1] == terminator {
                    index += 2
                    continue
                }
                index += 1
                break
            }
            index += 1
        }
        body(.quoted, Substring(String(characters[start..<min(index, characters.count)])))
        return index
    }

    /// `$tag$` — returns the full opening delimiter when one starts here.
    private func dollarTag(_ characters: [Character], at start: Int) -> String? {
        var index = start + 1
        var tag = "$"
        while index < characters.count {
            let character = characters[index]
            if character == "$" { return tag + "$" }
            // Tags are identifiers; anything else means this `$` was not a quote.
            guard character.isLetter || character.isNumber || character == "_" else { return nil }
            tag.append(character)
            index += 1
        }
        return nil
    }

    private func consumeDollarQuoted(
        _ characters: [Character], from start: Int, tag: String,
        _ body: (Region, Substring) -> Void
    ) -> Int {
        let delimiter = Array(tag)
        var index = start + delimiter.count
        while index + delimiter.count <= characters.count {
            if Array(characters[index..<(index + delimiter.count)]) == delimiter {
                index += delimiter.count
                body(.quoted, Substring(String(characters[start..<index])))
                return index
            }
            index += 1
        }
        body(.quoted, Substring(String(characters[start...])))
        return characters.count
    }

    private func consumeLine(
        _ characters: [Character], from start: Int, _ body: (Region, Substring) -> Void
    ) -> Int {
        var index = start
        while index < characters.count, characters[index] != "\n" { index += 1 }
        body(.comment, Substring(String(characters[start..<index])))
        return index
    }

    private func consumeBlockComment(
        _ characters: [Character], from start: Int, _ body: (Region, Substring) -> Void
    ) -> Int {
        var index = start + 2
        while index + 1 < characters.count {
            if characters[index] == "*", characters[index + 1] == "/" {
                index += 2
                body(.comment, Substring(String(characters[start..<index])))
                return index
            }
            index += 1
        }
        body(.comment, Substring(String(characters[start...])))
        return characters.count
    }
}

/// Cheap questions about a statement that do not need a parser.
public enum SQLStatementFacts {
    /// Whether the statement contains an outer join.
    ///
    /// The code generator needs this because two of the three engines cannot say
    /// whether a result column came from the nullable side of one. Knowing *which*
    /// side would need a parser; knowing that the statement has one at all is a
    /// keyword scan, and widening every otherwise-non-optional column in such a
    /// statement is the cheap, safe failure. A per-query annotation narrows it
    /// back where the author knows better.
    ///
    /// MySQL does not need this at all — it computes `NOT NULL` for the projected
    /// expression itself, correctly, through joins.
    ///
    /// `NATURAL LEFT JOIN` and `LEFT JOIN LATERAL` fall out of the same rule,
    /// since only the words before `JOIN` are examined.
    public static func hasOuterJoin(
        _ sql: String, syntax: SQLStatementSplitter.Syntax
    ) -> Bool {
        var found = false
        SQLScanner(syntax: syntax).forEachRegion(sql) { region, text in
            guard !found, region == .code else { return }
            found = containsOuterJoin(text)
        }
        return found
    }

    /// `LEFT|RIGHT|FULL` then optionally `OUTER`, then `JOIN` — on word
    /// boundaries, so a column named `left_join_count` does not match.
    private static func containsOuterJoin(_ text: Substring) -> Bool {
        // Underscores and digits are part of an identifier, so a column named
        // `left_join_count` must not split into LEFT / JOIN / COUNT and match.
        let words = text.uppercased().split {
            !($0.isLetter || $0.isNumber || $0 == "_")
        }
        var index = 0
        while index < words.count {
            if ["LEFT", "RIGHT", "FULL"].contains(String(words[index])) {
                var next = index + 1
                if next < words.count, words[next] == "OUTER" { next += 1 }
                if next < words.count, words[next] == "JOIN" { return true }
            }
            index += 1
        }
        return false
    }
}

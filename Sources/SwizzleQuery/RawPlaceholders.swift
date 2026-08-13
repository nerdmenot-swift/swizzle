import SwizzleCore

/// A `raw(_:_:)` whose `?` count did not match the values it was given.
///
/// Raised at execution rather than at construction: `raw` sits mid-chain where
/// nothing can throw, and failing there would mean either a crash or a silently
/// wrong statement. Rendering still works, so `debugSQL` can be inspected to see
/// exactly which placeholder went unfilled.
public struct SQLPlaceholderMismatch: Error, Sendable, CustomStringConvertible {
    public let placeholders: Int
    public let values: Int
    public let sql: String

    public var description: String {
        "raw SQL has \(placeholders) placeholder\(placeholders == 1 ? "" : "s") "
            + "but \(values) value\(values == 1 ? "" : "s") were given: \(sql)"
    }
}

extension SQLFragment {
    /// Builds a fragment from SQL text containing `?` placeholders plus the
    /// values to fill them.
    ///
    /// This is the path for SQL you already have — pasted from a client, lifted
    /// from a log, handed over by someone else — where rewriting it into Swift
    /// interpolation first is busywork.
    ///
    /// ```swift
    /// db.raw("SELECT id, name FROM users WHERE age > ? AND city = ?", [.int(18), .text("Pune")])
    /// ```
    ///
    /// `?` is the placeholder on **every** dialect, including Postgres: the
    /// renderer renumbers to `$1`, `$2` on the way out. A query copied from a
    /// MySQL session therefore runs unchanged against Postgres, which is the one
    /// thing none of the libraries this was modelled on will do for you.
    ///
    /// A `?` inside a string literal, a quoted identifier, or a comment is left
    /// alone — the scan tracks all three, so `WHERE note = 'why?'` is one
    /// placeholder-free predicate rather than a parse accident.
    ///
    /// - Note: To write a literal `?` outside a string, double it: `??`.
    public static func raw(_ sql: String, _ values: [SQLValue]) -> SQLFragment {
        var parts: [SQLNode] = []
        var literal = ""
        var consumed = 0

        var scanner = PlaceholderScanner(sql)
        while let piece = scanner.next() {
            switch piece {
            case .text(let text):
                literal += text
            case .placeholder:
                if !literal.isEmpty { parts.append(.raw(literal)); literal = "" }
                if consumed < values.count {
                    parts.append(.bind(values[consumed]))
                } else {
                    // Keep the `?` visible in the rendered SQL so `debugSQL`
                    // shows which one had nothing to fill it. Execution refuses
                    // separately.
                    parts.append(.raw("?"))
                }
                consumed += 1
            }
        }
        if !literal.isEmpty { parts.append(.raw(literal)) }

        var fragment = SQLFragment(parts: parts)
        if consumed != values.count {
            fragment.mismatch = SQLPlaceholderMismatch(
                placeholders: consumed, values: values.count, sql: sql
            )
        }
        return fragment
    }
}

/// Splits SQL into literal text and placeholder positions.
///
/// Not a SQL parser and not trying to be — it only needs to know when a `?` is
/// *not* a placeholder, which means tracking the three things that can contain
/// one: string literals, quoted identifiers, and comments. Getting that wrong in
/// either direction is silent, so it is worth the forty lines rather than a
/// `split(separator: "?")`.
struct PlaceholderScanner {
    enum Piece {
        case text(String)
        case placeholder
    }

    private let characters: [Character]
    private var index = 0

    init(_ sql: String) { characters = Array(sql) }

    mutating func next() -> Piece? {
        guard index < characters.count else { return nil }

        if characters[index] == "?" {
            // `??` is an escaped literal question mark.
            if index + 1 < characters.count, characters[index + 1] == "?" {
                index += 2
                return .text("?")
            }
            index += 1
            return .placeholder
        }

        var text = ""
        while index < characters.count, characters[index] != "?" {
            let character = characters[index]
            switch character {
            case "'", "\"", "`":
                text += consumeQuoted(character)
            case "-" where peek(1) == "-":
                text += consumeLine()
            case "/" where peek(1) == "*":
                text += consumeBlockComment()
            default:
                text.append(character)
                index += 1
            }
        }
        return .text(text)
    }

    private func peek(_ offset: Int) -> Character? {
        let position = index + offset
        return position < characters.count ? characters[position] : nil
    }

    /// Consumes through the closing quote, honouring both escape conventions:
    /// a doubled quote (standard SQL) and a backslash (MySQL's default).
    private mutating func consumeQuoted(_ quote: Character) -> String {
        var text = String(characters[index])
        index += 1
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                text.append(character)
                text.append(characters[index + 1])
                index += 2
                continue
            }
            text.append(character)
            index += 1
            if character == quote {
                if index < characters.count, characters[index] == quote {
                    text.append(quote)
                    index += 1
                    continue
                }
                break
            }
        }
        return text
    }

    private mutating func consumeLine() -> String {
        var text = ""
        while index < characters.count, characters[index] != "\n" {
            text.append(characters[index])
            index += 1
        }
        return text
    }

    private mutating func consumeBlockComment() -> String {
        var text = "/*"
        index += 2
        while index < characters.count {
            if characters[index] == "*", peek(1) == "/" {
                text += "*/"
                index += 2
                break
            }
            text.append(characters[index])
            index += 1
        }
        return text
    }
}

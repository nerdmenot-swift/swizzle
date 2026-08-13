import Foundation
import SwizzleCore
import SwizzleMigrate

/// One query as written in a `.sql` file, before the database has seen it.
public struct ParsedQuery: Sendable, Equatable {
    public var name: String
    public var sql: String
    public var cardinality: QuerySignature.Cardinality
    public var parameters: [DeclaredParameter]
    /// Columns the author asserts are not null, overriding the engine.
    public var notNull: Set<String>
    /// Columns the author asserts may be null.
    public var nullable: Set<String>
    public var file: String
    public var line: Int
}

/// A parameter as declared in the query file.
///
/// The Swift type is kept as **text** rather than parsed into a ``SwiftType``, so
/// an author can name anything that conforms to `SQLColumnValue` — including
/// `UInt64`, `[UInt8]`, or a type of their own — without the generator needing a
/// case for it. Where the engine can check the declaration, it compares the
/// rendering; where it cannot, the Swift compiler does.
public struct DeclaredParameter: Sendable, Equatable {
    public var name: String
    public var type: String
}

public struct QueryParseError: Error, Sendable, CustomStringConvertible {
    public let file: String
    public let line: Int
    public let reason: String

    public var description: String { "\(file):\(line): \(reason)" }
}

/// Reads `.sql` query files.
///
/// The directive form is the migrations' — `-- +swizzle <Keyword>` — deliberately,
/// including its stated reason: a plain SQL file with comment directives **stays
/// runnable by hand**, which is what you want when something has gone wrong and
/// you need to paste the query into a client.
///
/// ```sql
/// -- +swizzle Query GetUser(id: Int64) :one
/// SELECT id, email FROM users WHERE id = ?;
///
/// -- +swizzle NotNull total
/// -- +swizzle Query OrderTotals(userID: Int64) :many
/// SELECT u.id, o.total FROM users u LEFT JOIN orders o ON o.user_id = u.id
/// WHERE u.id = ?;
/// ```
///
/// Placeholders are the **engine's own** — `?` on MySQL and SQLite, `$1` on
/// Postgres — rather than a portable invention, for the same reason. A query file
/// is written against one database, exactly as a migration is.
public enum QueryParser {

    public static func parse(_ text: String, filename: String) throws -> [ParsedQuery] {
        var queries: [ParsedQuery] = []

        var pendingNotNull: Set<String> = []
        var pendingNullable: Set<String> = []
        var current: ParsedQuery?
        var body = ""

        func finish() throws {
            guard var query = current else { return }
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            // A trailing semicolon is what makes the file runnable by hand, and
            // what some engines refuse inside a prepared statement. Kept in the
            // file, dropped on the way to the server.
            query.sql = trimmed.hasSuffix(";") ? String(trimmed.dropLast()) : trimmed
            guard !query.sql.isEmpty else {
                throw QueryParseError(
                    file: filename, line: query.line,
                    reason: "query '\(query.name)' has no SQL after its directive"
                )
            }
            queries.append(query)
            current = nil
            body = ""
        }

        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = offset + 1
            guard let directive = Self.directive(in: rawLine) else {
                if current != nil { body += rawLine + "\n" }
                continue
            }

            let (keyword, rest) = Self.split(directive)
            switch keyword {
            case "Query":
                try finish()
                let header = try Self.parseHeader(rest, file: filename, line: line)
                current = ParsedQuery(
                    name: header.name, sql: "", cardinality: header.cardinality,
                    parameters: header.parameters,
                    notNull: pendingNotNull, nullable: pendingNullable,
                    file: filename, line: line
                )
                pendingNotNull = []
                pendingNullable = []

            case "NotNull":
                let column = rest.trimmingCharacters(in: .whitespaces)
                guard !column.isEmpty else {
                    throw QueryParseError(
                        file: filename, line: line,
                        reason: "NotNull needs a column name, e.g. '-- +swizzle NotNull total'"
                    )
                }
                pendingNotNull.insert(column)

            case "Nullable":
                let column = rest.trimmingCharacters(in: .whitespaces)
                guard !column.isEmpty else {
                    throw QueryParseError(
                        file: filename, line: line,
                        reason: "Nullable needs a column name"
                    )
                }
                pendingNullable.insert(column)

            default:
                throw QueryParseError(
                    file: filename, line: line,
                    reason: "unknown directive '\(keyword)' — "
                        + "query files understand Query, NotNull and Nullable"
                )
            }
        }
        try finish()

        guard pendingNotNull.isEmpty, pendingNullable.isEmpty else {
            throw QueryParseError(
                file: filename, line: text.components(separatedBy: .newlines).count,
                reason: "NotNull/Nullable at the end of the file applies to no query"
            )
        }

        try Self.checkForDuplicates(queries, filename: filename)
        return queries
    }

    /// `-- +swizzle Xyz …` → `Xyz …`. Anything else is ordinary SQL.
    static func directive(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("--") else { return nil }
        let comment = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
        guard comment.hasPrefix("+swizzle") else { return nil }
        return comment.dropFirst("+swizzle".count).trimmingCharacters(in: .whitespaces)
    }

    static func split(_ directive: String) -> (String, String) {
        let parts = directive.split(separator: " ", maxSplits: 1)
        let keyword = parts.first.map(String.init) ?? ""
        let rest = parts.count > 1 ? String(parts[1]) : ""
        return (keyword, rest)
    }

    struct Header {
        var name: String
        var parameters: [DeclaredParameter]
        var cardinality: QuerySignature.Cardinality
    }

    /// `GetUser(id: Int64) :one` — or `StreamAll :stream` with no parameters.
    static func parseHeader(_ text: String, file: String, line: Int) throws -> Header {
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        guard let colon = trimmed.lastIndex(of: ":") else {
            throw QueryParseError(
                file: file, line: line,
                reason: "query '\(trimmed)' has no cardinality — "
                    + "add one of :one, :many, :stream, :exec"
            )
        }
        let cardinalityText = String(trimmed[trimmed.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        guard let cardinality = QuerySignature.Cardinality(rawValue: cardinalityText) else {
            throw QueryParseError(
                file: file, line: line,
                reason: "unknown cardinality ':\(cardinalityText)' — "
                    + "expected :one, :many, :stream or :exec"
            )
        }

        var declaration = String(trimmed[trimmed.startIndex..<colon])
            .trimmingCharacters(in: .whitespaces)

        var parameters: [DeclaredParameter] = []
        if let open = declaration.firstIndex(of: "(") {
            guard declaration.hasSuffix(")") else {
                throw QueryParseError(
                    file: file, line: line,
                    reason: "unclosed parameter list in '\(declaration)'"
                )
            }
            let inside = declaration[declaration.index(after: open)..<declaration.index(before: declaration.endIndex)]
            declaration = String(declaration[declaration.startIndex..<open])
                .trimmingCharacters(in: .whitespaces)

            for piece in inside.split(separator: ",") {
                let parts = piece.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else {
                    throw QueryParseError(
                        file: file, line: line,
                        reason: "parameter '\(piece.trimmingCharacters(in: .whitespaces))' "
                            + "needs a type, e.g. 'id: Int64'"
                    )
                }
                let name = parts[0].trimmingCharacters(in: .whitespaces)
                let type = parts[1].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !type.isEmpty else {
                    throw QueryParseError(
                        file: file, line: line, reason: "malformed parameter in '\(inside)'"
                    )
                }
                parameters.append(DeclaredParameter(name: name, type: type))
            }
        }

        guard !declaration.isEmpty else {
            throw QueryParseError(file: file, line: line, reason: "query has no name")
        }
        return Header(name: declaration, parameters: parameters, cardinality: cardinality)
    }

    /// Two queries with one name would generate two functions with one name.
    ///
    /// Caught here rather than by the Swift compiler so the message names the
    /// file and line rather than the generated output nobody wrote.
    static func checkForDuplicates(_ queries: [ParsedQuery], filename: String) throws {
        var seen: [String: Int] = [:]
        for query in queries {
            if let first = seen[query.name] {
                throw QueryParseError(
                    file: filename, line: query.line,
                    reason: "query '\(query.name)' is already defined at line \(first)"
                )
            }
            seen[query.name] = query.line
        }
    }
}

/// Loads every `.sql` file in a directory.
public struct QueryDirectory: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }
    public init(path: String) { self.init(url: URL(fileURLWithPath: path)) }

    public func load() throws -> [ParsedQuery] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw QueryParseError(file: url.path, line: 0, reason: "not a directory")
        }

        // Sorted so generation is byte-stable across machines.
        let entries = try manager.contentsOfDirectory(atPath: url.path)
            .filter { $0.hasSuffix(".sql") && !$0.hasPrefix(".") }
            .sorted()

        var queries: [ParsedQuery] = []
        for filename in entries {
            let text = try String(
                contentsOf: url.appendingPathComponent(filename), encoding: .utf8
            )
            queries.append(contentsOf: try QueryParser.parse(text, filename: filename))
        }

        // Names have to be unique across the whole directory, not just per file,
        // because they all land in one generated type.
        try QueryParser.checkForDuplicates(queries, filename: url.lastPathComponent)
        return queries
    }
}

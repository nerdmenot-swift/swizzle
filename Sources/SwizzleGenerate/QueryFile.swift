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
    /// Swift types the author supplies for columns the engine could not type.
    ///
    /// The counterpart to ``DeclaredParameter``'s type, and it exists for the same
    /// reason: on a dynamically typed engine the database genuinely does not know.
    /// SQLite's `decltype` is null for every expression, so `SELECT COUNT(*)` —
    /// the most ordinary query anyone writes — has no type to report and lands on
    /// ``SwiftType/dynamic``. `NotNull` could fix the optionality and nothing
    /// could fix the type, so an author who knew the answer had no way to say it.
    public var types: [String: DeclaredColumnType]
    public var file: String
    public var line: Int
}

/// A column type written out in a query file — `Int64`, or `String?`.
///
/// Carries the optionality because the author is naming a **Swift** type, and in
/// Swift `Int64` and `Int64?` are different types. Making them mean the same
/// thing and requiring a second directive to choose between them would be a
/// vocabulary of our own laid over one every reader already knows.
///
/// `NotNull` / `Nullable` still apply afterwards and still win, so a column can be
/// typed in one place and have its optionality corrected in another when that
/// reads better — usually when the type is fine and only the nullability is not.
public struct DeclaredColumnType: Sendable, Equatable {
    public var type: SwiftType
    public var isOptional: Bool

    public init(type: SwiftType, isOptional: Bool) {
        self.type = type
        self.isOptional = isOptional
    }

    /// How it was written, which is also how the lockfile keys it.
    public var declaredName: String {
        type.declaredName + (isOptional ? "?" : "")
    }
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
///
/// -- +swizzle Type n Int64
/// -- +swizzle Query CountUsers :one
/// SELECT COUNT(*) AS n FROM users;
/// ```
///
/// `NotNull` / `Nullable` correct the engine's optionality; `Type` supplies a
/// Swift type the engine could not report at all, optionality included — write
/// `String?` for a column that may be null. The two directives are separate
/// because the databases fail at them separately: MySQL and Postgres type an
/// aggregate perfectly well and only nullability needs help, while SQLite can say
/// nothing about `COUNT(*)` in either direction.
///
/// Placeholders are the **engine's own** — `?` on MySQL and SQLite, `$1` on
/// Postgres — rather than a portable invention, for the same reason. A query file
/// is written against one database, exactly as a migration is.
public enum QueryParser {

    /// - Parameter syntax: the dialect's quoting and comment rules, used to find
    ///   where each query's statement actually ends. Not defaulted, because
    ///   guessing it wrong is silent: a Postgres file's `$$ … $$` body or a MySQL
    ///   file's `` `identifier` `` would be misread as ordinary text.
    public static func parse(
        _ text: String, filename: String, syntax: SQLStatementSplitter.Syntax
    ) throws -> [ParsedQuery] {
        var queries: [ParsedQuery] = []
        let splitter = SQLStatementSplitter(syntax: syntax)

        var pendingNotNull: Set<String> = []
        var pendingNullable: Set<String> = []
        var pendingTypes: [String: DeclaredColumnType] = [:]
        var current: ParsedQuery?
        var body = ""

        func finish() throws {
            guard var query = current else { return }

            // Split rather than trim, and this is the whole reason the parser
            // needs a dialect.
            //
            // The body is every line between this query's directive and the next
            // one, which includes any ordinary comment the author wrote *after*
            // the statement — and a directive block explaining the next query is
            // written exactly there. Trimming a trailing semicolon left all of it
            // in the SQL: the generated `listByAuthor` in `examples/codegen`
            // shipped four lines of prose about `COUNT(*)` to the server, with an
            // embedded `;` in the middle because the string no longer ended in
            // one. Found by writing that example, not by reading this.
            //
            // The splitter already knows where a statement ends in each dialect —
            // it is what the migrations run on — so it drops the trailing comment
            // and the semicolon together, and reports a body holding two
            // statements instead of silently generating one function for both.
            let statements = splitter.split(body)
            guard let statement = statements.first else {
                throw QueryParseError(
                    file: filename, line: query.line,
                    reason: "query '\(query.name)' has no SQL after its directive"
                )
            }
            guard statements.count == 1 else {
                throw QueryParseError(
                    file: filename, line: query.line,
                    reason: "query '\(query.name)' has \(statements.count) statements — "
                        + "one query generates one function, so give each its own "
                        + "'-- +swizzle Query' directive"
                )
            }
            query.sql = statement
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
                    types: pendingTypes,
                    file: filename, line: line
                )
                pendingNotNull = []
                pendingNullable = []
                pendingTypes = [:]

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

            case "Type":
                let parts = rest.split(
                    separator: " ", maxSplits: 1, omittingEmptySubsequences: true
                )
                guard parts.count == 2 else {
                    throw QueryParseError(
                        file: filename, line: line,
                        reason: "Type needs a column and a Swift type, "
                            + "e.g. '-- +swizzle Type n Int64'"
                    )
                }
                let column = String(parts[0])
                let spelling = parts[1].trimmingCharacters(in: .whitespaces)
                let isOptional = spelling.hasSuffix("?")
                let bare = isOptional ? String(spelling.dropLast()) : spelling
                guard let type = SwiftType(declared: bare) else {
                    throw QueryParseError(
                        file: filename, line: line,
                        reason: "unknown type '\(spelling)' for column '\(column)' — "
                            + "expected one of "
                            + SwiftType.declarableNames.joined(separator: ", ")
                            + ", each optionally followed by '?'"
                    )
                }
                let declared = DeclaredColumnType(type: type, isOptional: isOptional)
                // Two spellings for one column is a mistake with a silent
                // resolution otherwise: the last one wins and the author is
                // reading the first.
                if let existing = pendingTypes[column], existing != declared {
                    throw QueryParseError(
                        file: filename, line: line,
                        reason: "column '\(column)' is given two types — "
                            + "'\(existing.declaredName)' and '\(spelling)'"
                    )
                }
                pendingTypes[column] = declared

            default:
                throw QueryParseError(
                    file: filename, line: line,
                    reason: "unknown directive '\(keyword)' — "
                        + "query files understand Query, NotNull, Nullable and Type"
                )
            }
        }
        try finish()

        guard pendingNotNull.isEmpty, pendingNullable.isEmpty, pendingTypes.isEmpty else {
            throw QueryParseError(
                file: filename, line: text.components(separatedBy: .newlines).count,
                reason: "NotNull/Nullable/Type at the end of the file applies to no query"
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
    public let syntax: SQLStatementSplitter.Syntax

    public init(url: URL, syntax: SQLStatementSplitter.Syntax) {
        self.url = url
        self.syntax = syntax
    }

    public init(path: String, syntax: SQLStatementSplitter.Syntax) {
        self.init(url: URL(fileURLWithPath: path), syntax: syntax)
    }

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
            queries.append(
                contentsOf: try QueryParser.parse(text, filename: filename, syntax: syntax)
            )
        }

        // Names have to be unique across the whole directory, not just per file,
        // because they all land in one generated type.
        try QueryParser.checkForDuplicates(queries, filename: url.lastPathComponent)
        return queries
    }
}

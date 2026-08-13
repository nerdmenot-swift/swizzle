import SwizzleCore
import Foundation

/// Something a migration does that is worth a second look before it ships.
public struct LintFinding: Sendable, Equatable {
    public enum Severity: String, Sendable, Equatable {
        /// Will lose data, break running application code, or lock a table long
        /// enough to be an outage.
        case error
        /// Worth knowing and often fine — the judgement depends on context the
        /// linter does not have.
        case warning
    }

    /// Stable identifier, so a project can silence one check without silencing
    /// all of them.
    public let rule: String
    public let severity: Severity
    public let migration: String
    public let statement: String
    public let message: String
    /// What to do instead. A finding without one is just an obstacle.
    public let remedy: String
}

/// A rule.
///
/// Given a statement and what the database currently looks like, say what is
/// worrying about it. The schema is optional because `validate` runs in CI
/// without a database — the checks that need one simply do not fire, rather than
/// the whole linter refusing to run.
public protocol LintRule: Sendable {
    var name: String { get }
    func check(
        statement: String, parsed: ParsedStatement, schema: DatabaseSchema?
    ) -> [(severity: LintFinding.Severity, message: String, remedy: String)]
}

/// Just enough understanding of a statement to lint it.
///
/// Not a SQL parser and not trying to be. Every rule here keys off the leading
/// keywords and the table name, which a handful of patterns gets right for the
/// DDL people actually write. A full parser would be a large, permanently
/// incomplete project for findings that are advisory anyway — and getting a
/// statement wrong costs a false warning, not a wrong migration.
public struct ParsedStatement: Sendable, Equatable {
    public enum Operation: Sendable, Equatable {
        case createTable(table: String)
        case dropTable(table: String)
        case truncate(table: String)
        case addColumn(table: String, column: String, nullable: Bool, hasDefault: Bool)
        case dropColumn(table: String, column: String)
        case modifyColumn(table: String, column: String)
        case renameColumn(table: String, from: String)
        case addIndex(table: String, unique: Bool)
        case otherAlter(table: String)
        case other
    }

    public var operation: Operation
    /// The statement with comments and runs of whitespace collapsed, which is
    /// what the patterns match against.
    public var normalised: String

    public var table: String? {
        switch operation {
        case .createTable(let t), .dropTable(let t), .truncate(let t),
             .addColumn(let t, _, _, _), .dropColumn(let t, _),
             .modifyColumn(let t, _), .renameColumn(let t, _),
             .addIndex(let t, _), .otherAlter(let t):
            t
        case .other:
            nil
        }
    }

    public static func parse(_ statement: String) -> ParsedStatement {
        let text = normalise(statement)
        let upper = text.uppercased()

        func identifier(after prefixes: [String]) -> String? {
            for prefix in prefixes where upper.hasPrefix(prefix) {
                let rest = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                return unquote(rest.prefix(while: { !$0.isWhitespace && $0 != "(" }))
            }
            return nil
        }

        if let table = identifier(after: [
            "CREATE TABLE IF NOT EXISTS ", "CREATE TABLE ",
            "CREATE TEMPORARY TABLE IF NOT EXISTS ", "CREATE TEMPORARY TABLE ",
        ]) {
            return ParsedStatement(operation: .createTable(table: table), normalised: text)
        }
        if let table = identifier(after: ["DROP TABLE IF EXISTS ", "DROP TABLE "]) {
            return ParsedStatement(operation: .dropTable(table: table), normalised: text)
        }
        if let table = identifier(after: ["TRUNCATE TABLE ", "TRUNCATE "]) {
            return ParsedStatement(operation: .truncate(table: table), normalised: text)
        }
        if let table = identifier(after: [
            "CREATE UNIQUE INDEX ", "CREATE INDEX ",
        ]) {
            // `CREATE INDEX name ON table` — the identifier taken above is the
            // index, so the table comes after ON.
            _ = table
            let onTable = Self.value(after: " ON ", in: text, upper: upper)
            return ParsedStatement(
                operation: .addIndex(
                    table: onTable ?? "", unique: upper.hasPrefix("CREATE UNIQUE INDEX ")
                ),
                normalised: text
            )
        }

        if upper.hasPrefix("ALTER TABLE ") {
            let rest = text.dropFirst("ALTER TABLE ".count)
                .trimmingCharacters(in: .whitespaces)
            // Advance past the *raw* token, not the unquoted name: `\`users\``
            // is eight characters and `users` is five, and dropping the shorter
            // length left two stray backticks that turned every quoted ALTER
            // into an unrecognised one.
            let rawTable = rest.prefix(while: { !$0.isWhitespace })
            let table = unquote(rawTable)
            let action = String(rest.dropFirst(rawTable.count))
                .trimmingCharacters(in: .whitespaces)
            let actionUpper = action.uppercased()

            if actionUpper.hasPrefix("DROP COLUMN ") || actionUpper.hasPrefix("DROP ") {
                let prefix = actionUpper.hasPrefix("DROP COLUMN ") ? "DROP COLUMN " : "DROP "
                let column = unquote(
                    action.dropFirst(prefix.count).prefix(while: { !$0.isWhitespace && $0 != "," })
                )
                // `DROP INDEX`/`DROP KEY` are not column drops.
                if !["INDEX", "KEY", "PRIMARY", "FOREIGN", "CONSTRAINT", "CHECK"]
                    .contains(column.uppercased()) {
                    return ParsedStatement(
                        operation: .dropColumn(table: table, column: column), normalised: text
                    )
                }
            }
            if actionUpper.hasPrefix("ADD COLUMN ") || actionUpper.hasPrefix("ADD ") {
                let prefix = actionUpper.hasPrefix("ADD COLUMN ") ? "ADD COLUMN " : "ADD "
                let tail = String(action.dropFirst(prefix.count))
                let tailUpper = tail.uppercased()

                if tailUpper.hasPrefix("INDEX") || tailUpper.hasPrefix("KEY")
                    || tailUpper.hasPrefix("UNIQUE") || tailUpper.hasPrefix("CONSTRAINT")
                    || tailUpper.hasPrefix("FOREIGN") || tailUpper.hasPrefix("PRIMARY") {
                    return ParsedStatement(
                        operation: .addIndex(
                            table: table, unique: tailUpper.hasPrefix("UNIQUE")
                        ),
                        normalised: text
                    )
                }
                let column = unquote(tail.prefix(while: { !$0.isWhitespace }))
                return ParsedStatement(
                    operation: .addColumn(
                        table: table, column: column,
                        nullable: !tailUpper.contains(" NOT NULL"),
                        hasDefault: tailUpper.contains(" DEFAULT ")
                    ),
                    normalised: text
                )
            }
            if actionUpper.hasPrefix("MODIFY ") || actionUpper.hasPrefix("CHANGE ") {
                let prefix = actionUpper.hasPrefix("MODIFY COLUMN ") ? "MODIFY COLUMN "
                    : actionUpper.hasPrefix("CHANGE COLUMN ") ? "CHANGE COLUMN "
                    : actionUpper.hasPrefix("MODIFY ") ? "MODIFY " : "CHANGE "
                let column = unquote(
                    action.dropFirst(prefix.count).prefix(while: { !$0.isWhitespace })
                )
                return ParsedStatement(
                    operation: .modifyColumn(table: table, column: column), normalised: text
                )
            }
            if actionUpper.hasPrefix("RENAME COLUMN ") {
                let from = unquote(
                    action.dropFirst("RENAME COLUMN ".count).prefix(while: { !$0.isWhitespace })
                )
                return ParsedStatement(
                    operation: .renameColumn(table: table, from: from), normalised: text
                )
            }
            return ParsedStatement(operation: .otherAlter(table: table), normalised: text)
        }

        return ParsedStatement(operation: .other, normalised: text)
    }

    /// Strips comments and collapses whitespace so the patterns above see one
    /// canonical form regardless of how the migration was laid out.
    static func normalise(_ statement: String) -> String {
        var result = ""
        let characters = Array(statement)
        var index = 0
        while index < characters.count {
            if characters[index] == "-", index + 1 < characters.count,
               characters[index + 1] == "-" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
            } else if characters[index] == "/", index + 1 < characters.count,
                      characters[index + 1] == "*" {
                index += 2
                while index + 1 < characters.count,
                      !(characters[index] == "*" && characters[index + 1] == "/") { index += 1 }
                index = min(index + 2, characters.count)
            } else {
                result.append(characters[index])
                index += 1
            }
        }
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    static func unquote(_ text: some StringProtocol) -> String {
        var result = String(text)
        for quote in ["`", "\"", "'"] where result.hasPrefix(quote) && result.hasSuffix(quote) {
            result = String(result.dropFirst().dropLast())
        }
        return result.replacingOccurrences(of: "`", with: "")
    }

    static func value(after marker: String, in text: String, upper: String) -> String? {
        guard let range = upper.range(of: marker) else { return nil }
        let rest = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return unquote(rest.prefix(while: { !$0.isWhitespace && $0 != "(" }))
    }
}

import Foundation

/// Applies an `ALTER TABLE` without holding the table.
///
/// A protocol here and an implementation elsewhere: the only technique that
/// works is a shadow-table copy kept in sync from the binary log, which needs a
/// driver and several connections — neither of which `SwizzleMigrate` has, by
/// design. `SwizzleOnlineDDL` supplies the MySQL one.
public protocol OnlineDDLRunner: Sendable {
    func run(table: String, alterClause: String) async throws
}

/// Splits `ALTER TABLE x ADD COLUMN y` into the table and the rest.
///
/// An online runner works on the clause, because it applies it to the shadow
/// table rather than the named one.
public enum OnlineAlter {
    public static func parse(_ statement: String) -> (table: String, clause: String)? {
        let text = ParsedStatement.normalise(statement)
        guard text.uppercased().hasPrefix("ALTER TABLE ") else { return nil }

        let rest = text.dropFirst("ALTER TABLE ".count).trimmingCharacters(in: .whitespaces)
        // Advance past the raw token, not the unquoted name — a quoted table is
        // longer than the name it contains.
        let rawTable = rest.prefix(while: { !$0.isWhitespace })
        let table = ParsedStatement.unquote(rawTable)
        let clause = String(rest.dropFirst(rawTable.count)).trimmingCharacters(in: .whitespaces)

        guard !table.isEmpty, !clause.isEmpty else { return nil }
        return (table, clause)
    }
}

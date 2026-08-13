import SwizzleCore
import Foundation

/// The default rules.
///
/// Each one is a real production incident, not a style preference. The severity
/// says whether it will break something (`error`) or merely might (`warning`),
/// and every finding carries a remedy — a linter that only says "no" gets turned
/// off.
public enum LintRules {
    public static let all: [any LintRule] = [
        DestructiveTableRule(),
        DestructiveColumnRule(),
        NotNullWithoutDefaultRule(),
        RenameColumnRule(),
        BlockingIndexRule(),
        ColumnTypeChangeRule(),
        MissingPrimaryKeyRule(),
        TruncateRule(),
    ]
}

// MARK: - Destructive

/// Dropping a table.
public struct DestructiveTableRule: LintRule {
    public let name = "destructive-table"
    public init() {}

    public func check(
        statement: String, parsed: ParsedStatement, schema: DatabaseSchema?
    ) -> [(severity: LintFinding.Severity, message: String, remedy: String)] {
        guard case .dropTable(let table) = parsed.operation else { return [] }

        // A table the database does not have is a no-op, and reporting it as
        // data loss is the kind of false positive that trains people to stop
        // reading the linter. Only skipped when a schema was actually consulted:
        // with no schema, "not found" means "unknown".
        if let schema, schema.table(named: table) == nil { return [] }

        // With a schema we can say whether it actually holds anything, which is
        // the difference between "cleaning up" and "deleting production data".
        let rows = schema?.table(named: table)?.estimatedRows
        let detail = rows.map { $0 > 0 ? " (~\($0) rows)" : " (appears empty)" } ?? ""

        return [(
            rows == 0 ? .warning : .error,
            "drops table `\(table)`\(detail) — the data cannot be recovered by a Down section",
            """
            If this is a real removal, deploy it separately from the code that stopped \
            using the table, so a rollback of the code does not need the table back. \
            Rename it first and drop it a release later if you want an undo window.
            """
        )]
    }
}

/// Dropping a column.
public struct DestructiveColumnRule: LintRule {
    public let name = "destructive-column"
    public init() {}

    public func check(
        statement: String, parsed: ParsedStatement, schema: DatabaseSchema?
    ) -> [(severity: LintFinding.Severity, message: String, remedy: String)] {
        guard case .dropColumn(let table, let column) = parsed.operation else { return [] }
        if let schema, schema.table(named: table) == nil { return [] }
        let rows = schema?.table(named: table)?.estimatedRows
        let detail = rows.map { $0 > 0 ? " (~\($0) rows)" : " (appears empty)" } ?? ""

        return [(
            rows == 0 ? .warning : .error,
            "drops column `\(table)`.`\(column)`\(detail) — the data is gone and a "
                + "Down section can only recreate the column, not its contents",
            """
            Ship the code that stops writing it first, wait a release, then drop it. \
            A running instance of the old code will error the moment the column \
            disappears.
            """
        )]
    }
}

public struct TruncateRule: LintRule {
    public let name = "truncate"
    public init() {}

    public func check(
        statement: String, parsed: ParsedStatement, schema: DatabaseSchema?
    ) -> [(severity: LintFinding.Severity, message: String, remedy: String)] {
        guard case .truncate(let table) = parsed.operation else { return [] }
        return [(
            .error,
            "truncates `\(table)` — every row, unrecoverably, and it cannot be rolled back",
            "If this is seeding a fresh table, guard it so it cannot run against a "
                + "database that already has data."
        )]
    }
}

// MARK: - Breaking running code

/// `ADD COLUMN … NOT NULL` with no default.
public struct NotNullWithoutDefaultRule: LintRule {
    public let name = "not-null-no-default"
    public init() {}

    public func check(
        statement: String, parsed: ParsedStatement, schema: DatabaseSchema?
    ) -> [(severity: LintFinding.Severity, message: String, remedy: String)] {
        guard case .addColumn(let table, let column, let nullable, let hasDefault) =
            parsed.operation, !nullable, !hasDefault
        else { return [] }

        // On an empty table this is completely fine, which is why the schema is
        // worth having: without it this fires on every new table's first ALTER.
        if let rows = schema?.table(named: table)?.estimatedRows, rows == 0 {
            return [(
                .warning,
                "adds NOT NULL column `\(column)` with no default to `\(table)`, "
                    + "which appears empty — safe now, but not once it has rows",
                "Give it a default anyway, so the same migration is safe to replay "
                    + "against a populated database."
            )]
        }

        return [(
            .error,
            "adds NOT NULL column `\(table)`.`\(column)` with no default — existing rows "
                + "have no value to put there, so this fails outright or silently fills "
                + "in a zero, and any running instance of the old code cannot INSERT",
            """
            Add it nullable, backfill, then add the NOT NULL constraint in a later \
            migration — or give it a DEFAULT so existing rows and old code both have \
            an answer.
            """
        )]
    }
}

/// Renaming a column.
public struct RenameColumnRule: LintRule {
    public let name = "rename-column"
    public init() {}

    public func check(
        statement: String, parsed: ParsedStatement, schema: DatabaseSchema?
    ) -> [(severity: LintFinding.Severity, message: String, remedy: String)] {
        guard case .renameColumn(let table, let from) = parsed.operation else { return [] }
        return [(
            .error,
            "renames `\(table)`.`\(from)` — there is no moment when both the old and the "
                + "new code work, because the column has one name at a time",
            """
            Add the new column, write to both, backfill, move reads across, then drop \
            the old one. Four migrations and three deploys, which is what it costs to \
            rename a column without downtime.
            """
        )]
    }
}

// MARK: - Locking

/// Adding an index to a table big enough for it to hurt.
public struct BlockingIndexRule: LintRule {
    public let name = "blocking-index"
    /// Below this, even a table-copying ALTER finishes fast enough not to matter.
    public static let threshold: Int64 = 100_000
    public init() {}

    public func check(
        statement: String, parsed: ParsedStatement, schema: DatabaseSchema?
    ) -> [(severity: LintFinding.Severity, message: String, remedy: String)] {
        guard case .addIndex(let table, let unique) = parsed.operation, !table.isEmpty
        else { return [] }

        // Without a schema there is no way to know if the table is big, and
        // warning on every index would train people to ignore the linter.
        guard let rows = schema?.table(named: table)?.estimatedRows,
              rows >= Self.threshold
        else { return [] }

        let uniqueNote = unique
            ? " A UNIQUE index also fails outright if the existing data has duplicates."
            : ""

        return [(
            .warning,
            "adds an index to `\(table)` (~\(rows) rows), which will hold the table "
                + "while it builds.\(uniqueNote)",
            "Run it in a low-traffic window, or apply it online — see the Online DDL "
                + "directive, which copies through the binlog instead of locking."
        )]
    }
}

/// Changing a column's type.
public struct ColumnTypeChangeRule: LintRule {
    public let name = "column-type-change"
    public init() {}

    public func check(
        statement: String, parsed: ParsedStatement, schema: DatabaseSchema?
    ) -> [(severity: LintFinding.Severity, message: String, remedy: String)] {
        guard case .modifyColumn(let table, let column) = parsed.operation else { return [] }
        let rows = schema?.table(named: table)?.estimatedRows ?? 0
        let size = rows > 0 ? " (~\(rows) rows)" : ""

        return [(
            // Always a warning. A type change on a small table is cheap and on a
            // large one is slow, but neither is *wrong* — the risk is a
            // narrowing conversion that truncates, which the size does not tell
            // us about.
            .warning,
            "changes the type of `\(table)`.`\(column)`\(size) — MySQL usually rewrites "
                + "the whole table for this, holding it for the duration, and a narrowing "
                + "change silently truncates values that no longer fit",
            "Check the new type holds every existing value before shipping. For a large "
                + "table, apply it online rather than in place."
        )]
    }
}

// MARK: - Shape

/// A table with no primary key.
public struct MissingPrimaryKeyRule: LintRule {
    public let name = "no-primary-key"
    public init() {}

    public func check(
        statement: String, parsed: ParsedStatement, schema: DatabaseSchema?
    ) -> [(severity: LintFinding.Severity, message: String, remedy: String)] {
        guard case .createTable(let table) = parsed.operation else { return [] }

        let upper = parsed.normalised.uppercased()
        guard !upper.contains("PRIMARY KEY"), !upper.contains("AUTO_INCREMENT") else { return [] }

        return [(
            .warning,
            "creates `\(table)` with no primary key — row-based replication has to scan "
                + "the whole table for every changed row, and the table cannot be "
                + "safely paged through or copied online",
            "Add a primary key, even a surrogate one."
        )]
    }
}

// MARK: - Running the rules

/// Runs the rules over a set of migrations.
public struct Linter: Sendable {
    public let rules: [any LintRule]
    /// Rules to skip, by name.
    public var disabled: Set<String>

    public init(rules: [any LintRule] = LintRules.all, disabled: Set<String> = []) {
        self.rules = rules
        self.disabled = disabled
    }

    /// Lints migrations against an optional current schema.
    ///
    /// Passing `nil` is the CI case: the checks that need to know how big a
    /// table is stay quiet rather than guessing, and the rest still fire.
    public func lint(_ migrations: [Migration], schema: DatabaseSchema? = nil) -> [LintFinding] {
        var findings: [LintFinding] = []

        for migration in migrations {
            // A Swift migration's body is a closure; there is no SQL to read.
            // One more place where the code path gives something up.
            for statement in migration.upStatements {
                let parsed = ParsedStatement.parse(statement)
                for rule in rules where !disabled.contains(rule.name)
                    && migration.allowedRules[rule.name] == nil {
                    for result in rule.check(statement: statement, parsed: parsed, schema: schema) {
                        findings.append(
                            LintFinding(
                                rule: rule.name, severity: result.severity,
                                migration: migration.filename,
                                statement: Self.abbreviate(parsed.normalised),
                                message: result.message, remedy: result.remedy
                            )
                        )
                    }
                }
            }
        }
        return findings
    }

    /// Suppressions in force, so they can be shown rather than silently obeyed.
    ///
    /// An allowance that nobody ever sees again is the same as no rule at all —
    /// listing them keeps the exceptions in view as the schema evolves.
    public func suppressions(_ migrations: [Migration]) -> [(migration: String, rule: String, reason: String)] {
        migrations.flatMap { migration in
            migration.allowedRules
                .sorted { $0.key < $1.key }
                .map { (migration.filename, $0.key, $0.value) }
        }
    }

    static func abbreviate(_ statement: String) -> String {
        statement.count <= 120 ? statement : String(statement.prefix(117)) + "…"
    }
}

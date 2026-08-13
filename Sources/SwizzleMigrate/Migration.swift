import Foundation

/// One migration: a version, a name, and the SQL to apply and revert it.
///
/// Deliberately SQL-first. Swizzle does not diff a Swift schema against the
/// database and emit SQL — the file *is* the source of truth, which is the
/// goose model rather than Drizzle's. That choice is why hand-editing a
/// migration is normal here rather than awkward: nothing regenerates it.
public struct Migration: Sendable, Equatable, Identifiable {

    /// Which of the two kinds this is.
    public enum Kind: Sendable, Equatable {
        /// Applied once, in version order. The ordinary case.
        case versioned(Int64)

        /// Re-applied whenever its content changes, after every versioned
        /// migration, in name order.
        ///
        /// For objects that are *replaced* rather than altered: views, stored
        /// procedures, functions, triggers, grants. Without this, changing a
        /// view means writing a new migration containing the whole `CREATE OR
        /// REPLACE` — every time, forever — so the current definition is smeared
        /// across a dozen files and no single file shows what it is now. Here it
        /// lives in one file that reads like source code, and the checksum
        /// decides when to re-run it.
        ///
        /// Flyway calls these `R__` migrations and they are the feature most
        /// worth borrowing from it. They have no `Down`: the way to revert a
        /// replaced object is to change the file back.
        case repeatable
    }

    /// What a migration actually does.
    ///
    /// One type for both, so ordering, the journal, the lock and `status` are a
    /// single mechanism rather than two parallel ones. That unification is the
    /// whole reason Swift migrations share this type instead of living beside
    /// it.
    public enum Body: Sendable {
        case sql([String])
        /// A Swift migration's body. Not `Equatable` and not checksummable —
        /// see ``SwiftMigration`` for why that is accepted rather than solved.
        case swift(@Sendable (any MigrationContext) async throws -> Void)
    }

    public let kind: Kind

    /// Ordering key for a versioned migration; nil for a repeatable one, which
    /// has no position in the sequence.
    public var version: Int64? {
        if case .versioned(let version) = kind { return version }
        return nil
    }

    public var isRepeatable: Bool { kind == .repeatable }

    /// Key in the journal. Unique across both kinds.
    public var identifier: String {
        switch kind {
        case .versioned(let version): String(version)
        case .repeatable: "R__" + name
        }
    }

    /// Ordering key, taken from the filename prefix.
    ///
    /// Any integer works, which lets a project use either common convention
    /// without the library caring: `001_init.sql` counts up, and
    /// `20240615120000_init.sql` is a timestamp. Timestamps are worth preferring
    /// on a team — two branches both adding `004_` collide, whereas two
    /// timestamps merely interleave.
    ///
    /// Human-readable half of the filename, for logs and error messages.
    public let name: String
    /// What to run when applying.
    public let up: Body
    /// What to run when reverting. `nil` means the migration declares itself
    /// irreversible — see ``isReversible``.
    public let down: Body?
    /// Apply this migration's `ALTER`s online, without holding the table.
    ///
    /// Set by `-- +swizzle Online`. Requires a runner to be supplied — the
    /// migrator refuses rather than silently falling back to a locking ALTER,
    /// because a migration that asked for online and got blocking is an outage
    /// nobody agreed to.
    public let isOnline: Bool

    /// Whether to wrap the statements in a transaction.
    ///
    /// Honoured only where the database can actually roll back the statements in
    /// question; see ``MigrationRunner`` for why that is narrower than it sounds.
    public let usesTransaction: Bool
    /// Lint rules this migration is permitted to break, and why.
    ///
    /// Keyed by rule name; the value is the reason the author gave. See
    /// ``MigrationParser`` for why a reason is mandatory.
    public let allowedRules: [String: String]

    /// Hash of the source text, so an edit to an applied migration is detectable.
    public let checksum: String

    public var id: String { identifier }

    /// Whether this migration can be reverted.
    ///
    /// A migration with no `Down` section is not an error — dropping a column
    /// genuinely cannot be undone once the data is gone, and pretending
    /// otherwise is worse than admitting it. It just cannot be rolled back, and
    /// ``MigrationRunner`` refuses rather than silently skipping.
    public var isReversible: Bool { down != nil }

    /// Whether this is a Swift migration rather than a SQL one.
    public var isSwift: Bool {
        if case .swift = up { return true }
        return false
    }

    /// The SQL statements, when this is a SQL migration. Empty for a Swift one,
    /// which is why `--dry-run` can only name it rather than print it.
    public var upStatements: [String] {
        if case .sql(let statements) = up { return statements }
        return []
    }

    public var downStatements: [String] {
        if case .sql(let statements) = down { return statements }
        return []
    }

    public init(
        kind: Kind,
        name: String,
        up: Body,
        down: Body?,
        usesTransaction: Bool = true,
        isOnline: Bool = false,
        allowedRules: [String: String] = [:],
        checksum: String
    ) {
        self.allowedRules = allowedRules
        self.isOnline = isOnline
        self.kind = kind
        self.name = name
        self.up = up
        self.down = down
        self.usesTransaction = usesTransaction
        self.checksum = checksum
    }

    /// The filename this migration came from.
    public var filename: String {
        switch kind {
        case .versioned(let version): "\(version)_\(name).sql"
        case .repeatable: "R__\(name).sql"
        }
    }

    /// Compared by identity and content rather than by body: a closure cannot be
    /// compared, and two migrations with the same identifier and checksum are
    /// the same migration for every purpose here.
    public static func == (lhs: Migration, rhs: Migration) -> Bool {
        lhs.identifier == rhs.identifier && lhs.checksum == rhs.checksum
    }

    /// Orders migrations and refuses two that claim the same identity.
    ///
    /// The check lives here, in the one funnel every source goes through, rather
    /// than in each loader. It used to be in `MigrationDirectory` only — so a
    /// directory rejected `3_a.sql` alongside `3_b.sql`, and the same pair
    /// embedded into an `InMemoryMigrations` was accepted.
    ///
    /// That gap is worse than it sounds. The journal keys on the identifier, so
    /// the first of the pair records `3`, and the second then *looks already
    /// applied*: it never runs, and `status` never reports it as pending. A
    /// migration that silently does not exist is the worst outcome available.
    public static func validated(_ migrations: [Migration]) throws -> [Migration] {
        var seen: [String: String] = [:]
        for migration in migrations {
            if let existing = seen[migration.identifier] {
                throw MigrationParseError(
                    file: migration.filename,
                    reason: "version \(migration.identifier) is already used by '\(existing)' — "
                        + "the journal keys on it, so one of the two would never run"
                )
            }
            seen[migration.identifier] = migration.filename
        }
        return ordered(migrations)
    }

    /// Sorts versioned migrations by version, then repeatable ones by name.
    ///
    /// Repeatable last is not arbitrary: a view almost always depends on the
    /// tables a versioned migration just created or altered, so re-creating it
    /// before them would fail.
    public static func ordered(_ migrations: [Migration]) -> [Migration] {
        let versioned = migrations.compactMap { m -> (Int64, Migration)? in
            m.version.map { ($0, m) }
        }.sorted { $0.0 < $1.0 }.map(\.1)
        let repeatable = migrations.filter(\.isRepeatable).sorted { $0.name < $1.name }
        return versioned + repeatable
    }
}

/// A migration file could not be read or understood.
public struct MigrationParseError: Error, Sendable, Equatable, CustomStringConvertible {
    public let file: String
    public let reason: String

    public init(file: String, reason: String) {
        self.file = file
        self.reason = reason
    }

    public var description: String { "\(file): \(reason)" }
}

// MARK: - Parsing

/// Reads the annotated-SQL migration format.
///
/// ```sql
/// -- +swizzle Up
/// CREATE TABLE users (id INT PRIMARY KEY, email VARCHAR(255) NOT NULL);
/// CREATE UNIQUE INDEX users_email ON users (email);
///
/// -- +swizzle Down
/// DROP TABLE users;
/// ```
///
/// The directive form is goose's, because it is the one people already know and
/// because a plain SQL file with comment directives stays runnable by `psql` or
/// `mysql` directly — which matters when a migration goes wrong at 3am and
/// somebody needs to apply half of it by hand.
///
/// | directive | effect |
/// |---|---|
/// | `-- +swizzle Up` | begins the apply section |
/// | `-- +swizzle Down` | begins the revert section |
/// | `-- +swizzle StatementBegin` / `StatementEnd` | the enclosed text is **one** statement |
/// | `-- +swizzle NoTransaction` | do not wrap this migration in a transaction |
/// | `-- +swizzle Online` | apply this migration's `ALTER`s without holding the table |
/// | `-- +swizzle Allow <rule> <reason>` | this migration may break that lint rule |
///
/// `StatementBegin`/`StatementEnd` is an escape hatch and is rarely needed: the
/// splitter recognises dollar-quoted bodies and `BEGIN … END` compound bodies on
/// its own. Reach for it only when something defeats that detection.
public enum MigrationParser {

    private enum Section { case none, up, down }

    /// Parses one migration file.
    ///
    /// `version` and `name` come from the filename; see ``parseFilename(_:)``.
    public static func parse(
        _ text: String,
        kind: Migration.Kind,
        name: String,
        filename: String,
        syntax: SQLStatementSplitter.Syntax
    ) throws -> Migration {
        let splitter = SQLStatementSplitter(syntax: syntax)

        var section = Section.none
        var usesTransaction = true
        var isOnline = false
        var allowedRules: [String: String] = [:]
        var upText = ""
        var downText = ""
        var upStatements: [String] = []
        var downStatements: [String] = []
        var literalBlock: String?

        func appendText(_ line: String) {
            switch section {
            case .up: upText += line + "\n"
            case .down: downText += line + "\n"
            case .none: break
            }
        }

        /// Flushes what has accumulated as free-form SQL before a literal block
        /// starts or a section ends, so ordering between the two is preserved.
        func flushText() {
            switch section {
            case .up:
                upStatements.append(contentsOf: splitter.split(upText))
                upText = ""
            case .down:
                downStatements.append(contentsOf: splitter.split(downText))
                downText = ""
            case .none:
                break
            }
        }

        func appendLiteral(_ statement: String) {
            let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            switch section {
            case .up: upStatements.append(trimmed)
            case .down: downStatements.append(trimmed)
            case .none: break
            }
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)

            if var block = literalBlock {
                if directive(in: line) == "StatementEnd" {
                    appendLiteral(block)
                    literalBlock = nil
                } else {
                    block += line + "\n"
                    literalBlock = block
                }
                continue
            }

            switch directive(in: line) {
            case "Up":
                flushText()
                section = .up
            case "Down":
                flushText()
                section = .down
            case "NoTransaction":
                usesTransaction = false
            case "Online":
                isOnline = true

            case .some(let keyword) where keyword.hasPrefix("Allow "):
                // `-- +swizzle Allow <rule> <reason>`
                //
                // Every escape hatch used to be a CLI flag, which turns a check
                // off for the whole run and every migration in it — so the only
                // way past one intentional `DROP TABLE` was to stop checking
                // drops entirely, forever. That is how a linter gets switched
                // off, and it is the failure the rules exist to avoid.
                //
                // Scoped to one migration instead, and living in the file, so it
                // shows up in the diff that introduces it.
                let body = keyword.dropFirst("Allow ".count)
                    .trimmingCharacters(in: .whitespaces)
                let parts = body.split(separator: " ", maxSplits: 1)
                guard let rule = parts.first.map(String.init), !rule.isEmpty else {
                    throw MigrationParseError(
                        file: filename,
                        reason: "Allow needs a rule name, e.g. "
                            + "'-- +swizzle Allow destructive-table shadow-written for two releases'"
                    )
                }
                // The reason is mandatory. A bare suppression is invisible in
                // review — the reason is the whole point, because it forces the
                // author to articulate why this one is safe.
                let reason = parts.count > 1
                    ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
                guard !reason.isEmpty else {
                    throw MigrationParseError(
                        file: filename,
                        reason: "Allow \(rule) needs a reason after the rule name — "
                            + "a suppression nobody has to justify is one nobody reviews"
                    )
                }
                allowedRules[rule] = reason
            case "StatementBegin":
                guard section != .none else {
                    throw MigrationParseError(
                        file: filename,
                        reason: "StatementBegin appears before any Up or Down section"
                    )
                }
                flushText()
                literalBlock = ""
            case "StatementEnd":
                throw MigrationParseError(
                    file: filename, reason: "StatementEnd without a matching StatementBegin"
                )
            case .some(let unknown):
                throw MigrationParseError(
                    file: filename, reason: "unknown directive '+swizzle \(unknown)'"
                )
            case nil:
                appendText(line)
            }
        }

        if literalBlock != nil {
            throw MigrationParseError(
                file: filename, reason: "StatementBegin without a matching StatementEnd"
            )
        }
        flushText()

        guard !upStatements.isEmpty else {
            throw MigrationParseError(
                file: filename,
                reason: "no Up section, or it contains no statements — expected '-- +swizzle Up'"
            )
        }

        // A repeatable migration is re-run whenever it changes, so a Down section
        // would have no moment at which to run. Reverting one means editing the
        // file back to what it was.
        if kind == .repeatable, !downStatements.isEmpty {
            throw MigrationParseError(
                file: filename,
                reason: "a repeatable migration cannot have a Down section — "
                    + "revert it by changing the file back"
            )
        }

        return Migration(
            kind: kind,
            name: name,
            up: .sql(upStatements),
            down: downStatements.isEmpty ? nil : .sql(downStatements),
            usesTransaction: usesTransaction,
            isOnline: isOnline,
            allowedRules: allowedRules,
            checksum: Checksum.of(text)
        )
    }

    /// The directive on a line, if it is one.
    ///
    /// Matched only at the start of a line (after whitespace), so a `+swizzle`
    /// mentioned inside a statement or a trailing comment is left alone.
    private static func directive(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("--") else { return nil }
        let body = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
        guard body.hasPrefix("+swizzle") else { return nil }
        let keyword = body.dropFirst("+swizzle".count).trimmingCharacters(in: .whitespaces)
        return keyword.isEmpty ? nil : keyword
    }

    /// Splits `<version>_<name>.sql` into its parts.
    ///
    /// The version has to be an integer so ordering is total and obvious. A file
    /// that does not match is rejected rather than skipped: a migration silently
    /// ignored because it was misnamed is the kind of failure that only shows up
    /// in production.
    public static func parseFilename(
        _ filename: String
    ) throws -> (kind: Migration.Kind, name: String) {
        let base = filename.hasSuffix(".sql") ? String(filename.dropLast(4)) : filename

        // `R__name.sql` — Flyway's spelling, kept because it is the one people
        // already recognise and because the double underscore makes it visually
        // distinct from a versioned file in a directory listing.
        if base.hasPrefix("R__") {
            let name = String(base.dropFirst(3))
            guard !name.isEmpty else {
                throw MigrationParseError(
                    file: filename, reason: "a repeatable migration needs a name after 'R__'"
                )
            }
            return (.repeatable, name)
        }

        guard let separator = base.firstIndex(of: "_") else {
            throw MigrationParseError(
                file: filename, reason: "expected <version>_<name>.sql"
            )
        }
        let versionText = String(base[base.startIndex..<separator])
        guard let version = Int64(versionText), version > 0 else {
            throw MigrationParseError(
                file: filename,
                reason: "'\(versionText)' is not a positive integer version"
            )
        }
        let name = String(base[base.index(after: separator)...])
        guard !name.isEmpty else {
            throw MigrationParseError(file: filename, reason: "the name after the version is empty")
        }
        return (.versioned(version), name)
    }
}

import ArgumentParser
import Foundation
import SwizzleGenerate
import SwizzleMigrate

@main
struct Swizzle: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swizzle",
        abstract: "Swizzle — SQL migrations, a query builder, and a query cache.",
        subcommands: [Migrate.self, Generate.self]
    )
}

struct Migrate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "migrate",
        abstract: "Apply, revert and inspect SQL migrations.",
        discussion: """
            Migrations are plain .sql files named <version>_<name>.sql, with the \
            sections marked by comment directives:

                -- +swizzle Up
                CREATE TABLE users (id INT PRIMARY KEY);

                -- +swizzle Down
                DROP TABLE users;

            The file is the source of truth. Nothing here generates or rewrites \
            it, so editing one by hand is expected — but editing one that has \
            already been applied is caught (see `status`).
            """,
        subcommands: [
            Status.self, Up.self, Down.self, Redo.self, Baseline.self,
            Create.self, Validate.self, Lint.self, Embed.self,
        ],
        defaultSubcommand: Status.self
    )
}

// MARK: - status

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show which migrations are applied, pending, or have drifted."
    )

    @OptionGroup var database: DatabaseOptions
    @OptionGroup var options: MigrationOptions

    func run() async throws {
        let statuses = try await withMigrator(database, options) { migrator, _ in
            try await migrator.status()
        }

        guard !statuses.isEmpty else {
            print("No migrations found in \(options.directory).")
            return
        }

        let width = statuses.map { $0.version.map { String($0).count } ?? 3 }.max() ?? 8
        var pending = 0
        var drifted = 0

        for status in statuses {
            let label = status.version.map { String($0) } ?? "R"
            let version = Output.pad(label, width)
            let name = status.isRepeatable ? "R__\(status.name)" : status.name
            switch status.state {
            case .pending:
                pending += 1
                print("\(Output.yellow("pending"))  \(version)  \(name)")
            case .applied(let at):
                print("\(Output.green("applied"))  \(version)  \(name)  \(Output.dim(at))")
            case .outdated(let at):
                // Not drift: a changed repeatable migration is how you edit a
                // view, and it simply re-runs.
                pending += 1
                print("\(Output.yellow("changed"))  \(version)  \(name)  \(Output.dim(at))")
            case .modified(let at, _, _):
                drifted += 1
                print("\(Output.red("MODIFIED")) \(version)  \(name)  \(Output.dim(at))")
            case .missingFile(let at):
                drifted += 1
                print("\(Output.red("NO FILE"))  \(version)  \(name)  \(Output.dim(at))")
            }
        }

        print("")
        print("\(statuses.count) migrations, \(pending) to run.")

        if drifted > 0 {
            // Worth spelling out rather than leaving as a status word: the
            // consequence is invisible in the schema itself.
            print("")
            print(Output.red("\(drifted) migration(s) differ from what was applied."))
            print("""
                A migration edited after it ran leaves existing databases on the old
                version of it and new databases on the new one, with nothing in the
                schema to say so. Add a new migration instead.

                If you are still writing this migration, `swizzle migrate redo` reverts
                and re-applies it. If the edit was deliberate on a shared database,
                pass --no-verify.
                """)
            throw ExitCode(1)
        }
    }
}

// MARK: - up

struct Up: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Apply every pending migration.",
        discussion: """
            Safe to run on every deploy: applying nothing is success, not an error.

            An advisory lock is held for the whole run, so two instances rolling \
            out at once cannot both apply the same migration — the second waits, \
            re-reads, and finds nothing to do.
            """
    )

    @OptionGroup var database: DatabaseOptions
    @OptionGroup var options: MigrationOptions

    @Option(help: ArgumentHelp("Stop after this version.", valueName: "version"))
    var to: Int64?

    @Flag(
        name: .customLong("dry-run"),
        help: "Print the exact statements that would run, and change nothing."
    )
    var dryRun = false

    func run() async throws {
        if dryRun {
            let plan = try await withMigrator(database, options) { migrator, _ in
                try await migrator.plan(to: to)
            }
            guard !plan.isEmpty else {
                print("Nothing to apply — already up to date.")
                return
            }
            for migration in plan {
                let label = migration.version.map { String($0) } ?? "R__\(migration.name)"
                print(Output.dim("-- \(label)  \(migration.name)"))
                if migration.isSwift {
                    // A closure has no SQL to show. Naming it is the honest
                    // limit of what a dry run can offer for a code migration —
                    // and one of the reasons to prefer the SQL path.
                    print(Output.dim("   (Swift migration — body cannot be shown)"))
                } else {
                    for statement in migration.upStatements { print(statement + ";") }
                }
                print("")
            }
            print(Output.dim("\(plan.count) migration(s) would be applied. Nothing was run."))
            return
        }

        let applied = try await withMigrator(database, options) { migrator, _ in
            try await migrator.up(to: to)
        }

        guard !applied.isEmpty else {
            print("Nothing to apply — already up to date.")
            return
        }
        for migration in applied {
            let label = migration.version.map { String($0) } ?? "R"
            let name = migration.isRepeatable ? "R__\(migration.name)" : migration.name
            print("\(Output.green("applied"))  \(label)  \(name)")
        }
        print("")
        print("Applied \(applied.count) migration(s).")
    }
}

// MARK: - down

struct Down: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Revert applied migrations, newest first.",
        discussion: """
            Destructive, and asks before doing anything unless --yes is given.

            A migration with no Down section cannot be reverted — that is not a \
            defect. Dropping a column cannot be undone once the data is gone, and \
            a fake Down that pretends otherwise is worse than refusing.
            """
    )

    @OptionGroup var database: DatabaseOptions
    @OptionGroup var options: MigrationOptions

    @Option(help: ArgumentHelp("How many to revert.", valueName: "n"))
    var count: Int = 1

    @Option(
        help: ArgumentHelp("Revert down to and including this version.", valueName: "version")
    )
    var to: Int64?

    @Flag(name: [.customLong("yes"), .customShort("y")], help: "Do not ask for confirmation.")
    var assumeYes = false

    func validate() throws {
        if to != nil, count != 1 {
            throw ValidationError("pass either --count or --to, not both")
        }
        if count < 1 {
            throw ValidationError("--count must be at least 1")
        }
    }

    func run() async throws {
        // What *would* happen, shown before anything is touched. A migrator that
        // reverts first and reports after is no use to someone who typed the
        // wrong number.
        //
        // Drift is checked here rather than left to the revert itself. Doing it
        // the other way round printed a plan and *then* failed the checksum
        // check, which reads as though the revert half-happened. It also hid
        // migrations: a `.modified` one is still applied, so leaving it out of
        // the plan understated what `--to` was about to do.
        let plan = try await withMigrator(database, options) { migrator, _ in
            let statuses = try await migrator.status()

            if !options.skipChecksumVerification {
                let drifted = statuses.filter {
                    if case .modified = $0.state { true } else { false }
                }
                if !drifted.isEmpty {
                    throw MigrateFailure(
                        """
                        \(drifted.count) applied migration(s) differ from their files:
                        \(drifted.map { "  \($0.version)  \($0.name)" }.joined(separator: "\n"))

                        Reverting would run a Down section that does not match the Up \
                        that was applied. Restore the files, or pass --no-verify if you \
                        are certain.
                        """
                    )
                }
            }

            // Both states count as applied — a modified migration is still in
            // the database. Repeatable ones are excluded: they have no Down.
            let applied = statuses
                .filter { !$0.isRepeatable }
                .filter {
                    switch $0.state {
                    case .applied, .modified: true
                    case .pending, .outdated, .missingFile: false
                    }
                }
                .sorted { ($0.version ?? 0) > ($1.version ?? 0) }

            if let to {
                return applied.filter { ($0.version ?? 0) >= to }
            }
            return Array(applied.prefix(count))
        }

        guard !plan.isEmpty else {
            print("Nothing to revert.")
            return
        }

        print("This will revert \(plan.count) migration(s), newest first:")
        for status in plan {
            print("  \(status.version.map(String.init) ?? "")  \(status.name)")
        }

        if !assumeYes {
            print("")
            print("Reverting runs each migration's Down section. Continue? [y/N] ", terminator: "")
            guard let answer = readLine()?.lowercased(), answer == "y" || answer == "yes" else {
                print("Cancelled.")
                throw ExitCode(1)
            }
        }

        let reverted = try await withMigrator(database, options) { migrator, _ in
            if let to {
                return try await migrator.down(to: to)
            }
            return try await migrator.down(count: count)
        }

        for migration in reverted {
            print("\(Output.yellow("reverted")) \(migration.version.map(String.init) ?? "")  \(migration.name)")
        }
        print("")
        print("Reverted \(reverted.count) migration(s).")
    }
}

// MARK: - redo

struct Redo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Revert the newest migration and apply it again.",
        discussion: """
            The development loop. While you are still writing a migration you             apply it, find it wrong, edit it, and want to run it again — which             the checksum check otherwise refuses, because on a shared database             that edit would be a real problem.

            Not for production: it reverts, so it destroys whatever the Down             section destroys.
            """
    )

    @OptionGroup var database: DatabaseOptions
    @OptionGroup var options: MigrationOptions

    @Flag(name: [.customLong("yes"), .customShort("y")], help: "Do not ask for confirmation.")
    var assumeYes = false

    func run() async throws {
        if !assumeYes {
            print("Redo reverts the newest migration and re-applies it. Continue? [y/N] ",
                  terminator: "")
            guard let answer = readLine()?.lowercased(), answer == "y" || answer == "yes" else {
                print("Cancelled.")
                throw ExitCode(1)
            }
        }

        // Verification is skipped for the revert half by design: the whole point
        // is that the file has changed since it was applied.
        var relaxed = options
        relaxed.skipChecksumVerification = true

        let applied = try await withMigrator(database, relaxed) { migrator, _ in
            try await migrator.redo()
        }
        guard let migration = applied.first else {
            print("Nothing to redo — no migrations are applied.")
            return
        }
        print("\(Output.green("redone"))   \(migration.version.map(String.init) ?? "")  \(migration.name)")
    }
}

// MARK: - baseline

struct Baseline: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Mark migrations up to a version as applied, without running them.",
        discussion: """
            How an existing database adopts Swizzle. Without this, pointing the             migrator at a schema that already has your tables would try to run             migration 1 against them and fail.

            Write migrations describing the schema you already have, baseline to             the last of them, and everything after that runs normally.

            Repeatable migrations are deliberately not baselined — they are cheap             to re-apply, and re-applying proves they match what is in the database.
            """
    )

    @OptionGroup var database: DatabaseOptions
    @OptionGroup var options: MigrationOptions

    @Argument(help: ArgumentHelp("Mark everything up to and including this version.", valueName: "version"))
    var version: Int64

    @Flag(name: [.customLong("yes"), .customShort("y")], help: "Do not ask for confirmation.")
    var assumeYes = false

    func run() async throws {
        if !assumeYes {
            print("""
                This records migrations up to \(version) as applied WITHOUT running them.
                Only correct if the database already has exactly that schema.
                """)
            print("Continue? [y/N] ", terminator: "")
            guard let answer = readLine()?.lowercased(), answer == "y" || answer == "yes" else {
                print("Cancelled.")
                throw ExitCode(1)
            }
        }

        let marked = try await withMigrator(database, options) { migrator, _ in
            try await migrator.baseline(to: version)
        }
        guard !marked.isEmpty else {
            print("Nothing to baseline — those migrations are already recorded.")
            return
        }
        for migration in marked {
            print("\(Output.dim("baselined")) \(migration.version.map(String.init) ?? "")  \(migration.name)")
        }
        print("")
        print("Recorded \(marked.count) migration(s) as applied without running them.")
    }
}

// MARK: - create

struct Create: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Write a new empty migration file.",
        discussion: """
            The version is a UTC timestamp, which is what makes concurrent work \
            safe: two branches both adding `004_` collide, whereas two timestamps \
            merely interleave.
            """
    )

    @Argument(help: ArgumentHelp("What the migration does, e.g. add_users_table.", valueName: "name"))
    var name: String

    @Option(
        name: [.customLong("dir"), .customShort("d")],
        help: ArgumentHelp("Where to write it.", valueName: "path")
    )
    var directory: String = "migrations"

    @Option(
        help: ArgumentHelp(
            "Use a sequential version instead of a timestamp.", valueName: "version"
        )
    )
    var version: Int64?

    func run() async throws {
        let slug = Self.slug(name)
        guard !slug.isEmpty else {
            throw ValidationError("the name must contain at least one letter or digit")
        }

        let manager = FileManager.default
        try manager.createDirectory(atPath: directory, withIntermediateDirectories: true)

        // A timestamp is only second-resolution, and creating two migrations
        // back to back is completely normal — which produced two files with the
        // same version, a pair the loader then rejected as duplicates. Stepping
        // forward until the version is unused keeps them readable and ordered.
        var version = try self.version ?? Self.timestampVersion()
        let existing = Set(
            ((try? manager.contentsOfDirectory(atPath: directory)) ?? [])
                .compactMap { filename -> Int64? in
                    guard let parsed = try? MigrationParser.parseFilename(filename),
                          case .versioned(let version) = parsed.kind else { return nil }
                    return version
                }
        )
        if self.version == nil {
            while existing.contains(version) { version += 1 }
        } else if existing.contains(version) {
            throw ValidationError("version \(version) is already used")
        }

        let filename = "\(version)_\(slug).sql"
        let path = (directory as NSString).appendingPathComponent(filename)

        guard !manager.fileExists(atPath: path) else {
            throw ValidationError("\(path) already exists")
        }

        let template = """
            -- \(name)
            --
            -- Up runs when applying, Down when reverting. Delete the Down section
            -- if this change genuinely cannot be undone — an empty one is honest,
            -- a wrong one is not.

            -- +swizzle Up


            -- +swizzle Down

            """
        try template.write(toFile: path, atomically: true, encoding: .utf8)
        print("Created \(path)")
    }

    /// `YYYYMMDDHHMMSS` in UTC, so versions from different machines still order
    /// correctly.
    static func timestampVersion() throws -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: Date()
        )
        let text = String(
            format: "%04d%02d%02d%02d%02d%02d",
            parts.year!, parts.month!, parts.day!, parts.hour!, parts.minute!, parts.second!
        )
        guard let version = Int64(text) else {
            throw ValidationError("could not build a timestamp version")
        }
        return version
    }

    /// Lowercased, with anything that is not a letter or digit collapsed into an
    /// underscore — the filename has to round-trip through the parser, which
    /// splits on the first underscore.
    static func slug(_ name: String) -> String {
        var result = ""
        var lastWasSeparator = true      // suppresses a leading underscore
        for character in name.lowercased() {
            if character.isLetter || character.isNumber {
                result.append(character)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                result.append("_")
                lastWasSeparator = true
            }
        }
        while result.hasSuffix("_") { result.removeLast() }
        return result
    }
}

// MARK: - validate

struct Validate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Parse every migration without connecting to a database.",
        discussion: """
            Meant for CI. Catches a malformed filename, an unknown directive, a \
            duplicate version, an unbalanced StatementBegin, or a missing Up \
            section — before a deploy finds them.
            """
    )

    @Option(
        name: [.customLong("dir"), .customShort("d")],
        help: ArgumentHelp("Directory holding the .sql migrations.", valueName: "path")
    )
    var directory: String = "migrations"

    @Flag(name: .customLong("no-lint"), help: "Only parse; skip the safety checks.")
    var skipLint = false

    @Option(
        name: .customLong("disable"),
        help: ArgumentHelp("Skip a lint rule, by name. Repeatable.", valueName: "rule")
    )
    var disabledRules: [String] = []

    func run() async throws {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(atPath: directory) else {
            throw MigrateFailure("\(directory) is not a directory")
        }
        let files = entries.filter { $0.hasSuffix(".sql") && !$0.hasPrefix(".") }.sorted()

        guard !files.isEmpty else {
            print("No migrations found in \(directory).")
            return
        }

        // Every file is reported, not just the first bad one. `load()` stops at
        // the first failure, which is right for a migrator about to touch a
        // database and wrong for CI — one run should list everything that needs
        // fixing.
        var migrations: [Migration] = []
        var failures = 0
        var seen: [String: String] = [:]

        for filename in files {
            do {
                let (kind, name) = try MigrationParser.parseFilename(filename)
                let identity = kind == .repeatable ? "R__\(name)" : "\(kind)"
                if let existing = seen[identity] {
                    throw MigrationParseError(
                        file: filename,
                        reason: "duplicate migration identity, already used by '\(existing)'"
                    )
                }
                seen[identity] = filename

                let path = (directory as NSString).appendingPathComponent(filename)
                let text = try String(contentsOfFile: path, encoding: .utf8)
                let migration = try MigrationParser.parse(
                    text, kind: kind, name: name, filename: filename, syntax: .mysql
                )
                migrations.append(migration)

                let label = migration.version.map { String($0) } ?? "R__\(migration.name)"
                let down = migration.isRepeatable
                    ? Output.dim("repeatable")
                    : migration.isReversible
                    ? "\(migration.downStatements.count) down"
                    : Output.dim("irreversible")
                let transaction = migration.usesTransaction ? "" : Output.dim("  no-transaction")
                print(
                    "\(Output.green("ok"))    \(label)  \(migration.name)"
                    + "  \(Output.dim("\(migration.upStatements.count) up, \(down)"))\(transaction)"
                )
            } catch let error as MigrationParseError {
                failures += 1
                print("\(Output.red("error")) \(filename)")
                print("      \(error.reason)")
            }
        }

        print("")
        print("\(migrations.count) ok, \(failures) failed.")

        // Linting without a schema: the checks that need to know how big a table
        // is stay quiet rather than guessing, and the rest still fire. That is
        // what makes this useful in CI, where there is no database.
        if !skipLint, !migrations.isEmpty {
            print("")
            let linter = Linter(disabled: Set(disabledRules))
            let errors = LintOutput.report(linter.lint(migrations, schema: nil), checkedSchema: false)
            LintOutput.reportSuppressions(linter.suppressions(migrations))
            if errors > 0 { throw ExitCode(1) }
        }

        let irreversible = migrations.filter { !$0.isReversible && !$0.isRepeatable }
        if !irreversible.isEmpty {
            print(
                Output.dim(
                    "\(irreversible.count) cannot be reverted: "
                    + irreversible.compactMap { $0.version.map(String.init) }.joined(separator: ", ")
                )
            )
        }

        if failures > 0 { throw ExitCode(1) }
    }
}


// MARK: - lint

struct Lint: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check migrations for changes that lose data, break running code, or lock a table.",
        discussion: """
            Unlike `validate`, this connects — so it knows how big each table is,             which is what separates "drops an empty table" from "drops production".

            Every finding names a rule, so a project can silence one without             silencing all of them:

                swizzle migrate lint --disable blocking-index

            Rules: destructive-table, destructive-column, truncate,             not-null-no-default, rename-column, blocking-index,             column-type-change, no-primary-key.
            """
    )

    @OptionGroup var database: DatabaseOptions
    @OptionGroup var options: MigrationOptions

    @Option(
        name: .customLong("disable"),
        help: ArgumentHelp("Skip a rule, by name. Repeatable.", valueName: "rule")
    )
    var disabledRules: [String] = []

    @Flag(
        name: .customLong("pending-only"),
        help: "Only check migrations that have not been applied yet."
    )
    var pendingOnly = false

    func run() async throws {
        let (findings, checked) = try await withMigrator(database, options) { migrator, introspector in
            // Same source the migrator built, so `--pending-only` and the lint
            // see identical files.
            var migrations = try migrator.source.load()

            if pendingOnly {
                let plan = try await migrator.plan(to: nil)
                let pending = Set(plan.map(\.identifier))
                migrations = migrations.filter { pending.contains($0.identifier) }
            }

            // An engine with no introspector simply loses the size-dependent
            // rules, rather than the whole lint refusing to run.
            let schema = try await introspector?.schema()
            let linter = Linter(disabled: Set(disabledRules))
            LintOutput.reportSuppressions(linter.suppressions(migrations))
            return (linter.lint(migrations, schema: schema), schema != nil)
        }

        let errors = LintOutput.report(findings, checkedSchema: checked)
        if errors > 0 { throw ExitCode(1) }
    }
}


// MARK: - embed

struct Embed: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Generate a Swift file containing the migrations, for a single-binary deploy.",
        discussion: """
            A deployed executable has no migrations directory to point at. goose \
            solves this with Go's `//go:embed`; Swift has no equivalent, so the \
            honest answer is generated source you commit.

            The output is an `InMemoryMigrations`, which the migrator already \
            accepts — so embedding changes where the files come from and nothing \
            else. Ordering, the journal, the lock and the lint all behave \
            identically.

                swizzle migrate embed > Sources/App/Migrations.swift

            Needs no database, so it belongs in the same CI step as `validate`.
            """
    )

    @Option(
        name: [.customLong("dir"), .customShort("d")],
        help: ArgumentHelp("Directory holding the .sql migrations.", valueName: "path")
    )
    var directory: String = "migrations"

    @Option(help: ArgumentHelp("Name of the generated enum.", valueName: "name"))
    var typeName: String = "EmbeddedMigrations"

    @Option(help: ArgumentHelp("Dialect whose lexer rules the files were written for.",
                               valueName: "mysql|postgres|sqlite"))
    var syntax: String = "mysql"

    func run() async throws {
        let rules: SQLStatementSplitter.Syntax
        switch syntax.lowercased() {
        case "mysql", "mariadb": rules = .mysql
        case "postgres", "postgresql": rules = .postgres
        case "sqlite": rules = .sqlite
        default: throw ValidationError("syntax must be mysql, postgres or sqlite")
        }

        // Parsed rather than copied, so a file that cannot be read fails here
        // rather than at the first boot of the deployed binary.
        _ = try MigrationDirectory(path: directory, syntax: rules).load()

        let manager = FileManager.default
        let files = (try manager.contentsOfDirectory(atPath: directory))
            .filter { $0.hasSuffix(".sql") && !$0.hasPrefix(".") }
            .sorted()

        var out = """
            // Generated by `swizzle migrate embed`. Do not edit.
            //
            // Regenerate after changing anything in \(directory)/ — the checksums
            // recorded in the journal are of *this* text, so a stale copy here and a
            // fresh one on disk are two different migrations.

            import SwizzleMigrate

            public enum \(typeName) {
                public static func source() throws -> InMemoryMigrations {
                    try InMemoryMigrations(files: files, syntax: .\(syntax.lowercased()))
                }

                public static let files: [String: String] = [

            """

        for filename in files {
            let path = (directory as NSString).appendingPathComponent(filename)
            let text = try String(contentsOfFile: path, encoding: .utf8)
            // Raw string delimiters sized past the longest run of quotes in the
            // file, so SQL containing `\"""` cannot terminate its own literal.
            out += "        \(Self.literal(filename)): \(Self.literal(text)),\n"
        }

        out += """
                ]
            }

            """
        print(out, terminator: "")
    }

    /// A Swift string literal that cannot be broken by its contents.
    static func literal(_ text: String) -> String {
        var hashes = 1
        while text.contains("\"" + String(repeating: "#", count: hashes)) { hashes += 1 }
        let pad = String(repeating: "#", count: hashes)
        return "\(pad)\"\"\"\n\(text)\n\"\"\"\(pad)"
    }
}


// MARK: - generate

struct Generate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate",
        abstract: "Generate Swift from the database.",
        discussion: """
            Reads a live database and emits Swift you commit.

            Unlike sqlc, which parses your SQL with an embedded parser per dialect,             Swizzle asks the database itself — so there is no parser to maintain and             the answer is whatever the engine actually says. The cost is a connection             at generation time.
            """,
        subcommands: [GenerateSchema.self, GenerateQueries.self],
        defaultSubcommand: GenerateSchema.self
    )
}

struct GenerateSchema: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "schema",
        abstract: "Emit SQLTable declarations from the live schema.",
        discussion: """
            Table declarations are otherwise hand-written, which means the SQL type in             `varchar("email", 255)` is a comment nothing verifies and can drift from the             migration that created the column. Generating them from what the server             reports makes it a fact.

            Writes to stdout unless --out is given:

                swizzle generate schema --url sqlite:app.db --out Sources/App/Schema.swift
            """
    )

    @OptionGroup var database: DatabaseOptions

    @Option(name: [.customShort("o"), .long], help: "File to write. Defaults to stdout.")
    var out: String?

    @Option(help: "Access level for the generated declarations.")
    var accessLevel: String = "public"

    @Option(
        parsing: .upToNextOption,
        help: "Tables to skip. The migration journal and lock are always skipped."
    )
    var exclude: [String] = []

    func run() async throws {
        let source = try await withEngine(database) { connection -> String in
            guard let introspector = connection.introspector else {
                throw ValidationError(
                    "the \(connection.executor.dialectName) engine cannot introspect, "
                        + "so there is no schema to generate from"
                )
            }
            var schema = try await introspector.schema()

            // Swizzle's own bookkeeping is not part of anybody's domain model.
            let skipped = Set(exclude.map { $0.lowercased() } + [
                "swizzle_migrations", "swizzle_migration_lock",
            ])
            schema.tables = schema.tables.filter {
                !skipped.contains($0.name.lowercased())
            }

            guard !schema.tables.isEmpty else {
                throw ValidationError(
                    "no tables found — has the database been migrated?"
                )
            }

            return SchemaEmitter(
                options: .init(
                    accessLevel: accessLevel,
                    dialect: connection.executor.dialectName
                )
            ).emit(schema)
        }

        if let out {
            try source.write(toFile: out, atomically: true, encoding: .utf8)
            FileHandle.standardError.write(
                Data("wrote \(out)\n".utf8)
            )
        } else {
            print(source, terminator: "")
        }
    }
}


struct GenerateQueries: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "queries",
        abstract: "Emit typed functions from .sql query files.",
        discussion: """
            Each query is described by the database itself — prepared but never run — \
            so the result columns, their types and their nullability come from the \
            engine rather than from a parser.

                -- +swizzle Query GetUser(id: Int64) :one
                SELECT id, email FROM users WHERE id = ?;

            becomes a `getUser(id:)` returning an optional row struct. Cardinality is \
            one of :one, :many, :stream or :exec. Use `-- +swizzle NotNull <column>` \
            to narrow a column the engine had to be pessimistic about, and \
            `-- +swizzle Type <column> <T>` to supply a type it could not report \
            at all — SQLite cannot type `COUNT(*)`, so that one is common there.

            By default the migrations are run into a throwaway database and the \
            queries described there, so generated code follows the migrations rather \
            than whatever state a server happens to be in. --no-shadow describes \
            against the URL directly.

            --verify needs no database at all: it recomputes the lockfile from the \
            files on disk and fails if the committed output is stale. That is the \
            check to run in CI.
            """
    )

    @OptionGroup var database: DatabaseOptions

    @Option(name: [.customShort("q"), .long], help: "Directory holding the .sql query files.")
    var queries: String = "queries"

    @Option(name: [.customShort("d"), .long], help: "Directory holding the .sql migrations.")
    var dir: String = "migrations"

    @Option(name: [.customShort("o"), .long], help: "File to write. Defaults to stdout.")
    var out: String?

    @Option(help: "Lockfile recording what was generated.")
    var lockfile: String = "swizzle.lock.json"

    @Option(help: "Name of the generated type holding the query functions.")
    var typeName: String = "Queries"

    @Option(help: "Access level for the generated code.")
    var accessLevel: String = "public"

    @Flag(help: "Describe against --url directly instead of a throwaway database.")
    var noShadow = false

    @Flag(help: "Check the committed output is current. Needs no database.")
    var verify = false

    func run() async throws {
        // The engine is resolved *before* the query files are read, because
        // finding where a statement ends needs the dialect's quoting rules — a
        // Postgres `$$ … $$` body is text to every other dialect's scanner.
        // `--verify` takes it from the lockfile, having no database to ask.
        if verify {
            let lock = try Lockfile.read(from: lockfile)
            try await runVerify(try load(syntax: Self.syntax(for: lock.engine)), lock: lock)
            return
        }

        let url = try database.resolvedURL()
        guard let engine = engines.engine(forURL: url) else {
            throw ValidationError("no registered engine handles '\(url)'")
        }
        let parsed = try load(syntax: Self.syntax(for: engine.name))

        let (source, lock) = try await generate(parsed)
        if let out {
            try source.write(toFile: out, atomically: true, encoding: .utf8)
            try lock.write(to: lockfile)
            FileHandle.standardError.write(
                Data("wrote \(out) and \(lockfile) — \(Self.count(parsed.count))\n".utf8)
            )
        } else {
            print(source, terminator: "")
        }
    }

    private func load(syntax: SQLStatementSplitter.Syntax) throws -> [ParsedQuery] {
        let parsed = try QueryDirectory(path: queries, syntax: syntax).load()
        guard !parsed.isEmpty else {
            throw ValidationError("no .sql query files found in '\(queries)'")
        }
        return parsed
    }

    /// The no-database path.
    ///
    /// Recomputes the lockfile keys from the files on disk, then re-emits Swift
    /// from the **stored** signatures and compares. Catches a query edited without
    /// regenerating, a migration added without regenerating, and generated code
    /// edited by hand — the three ways a tree goes stale.
    private func runVerify(_ parsed: [ParsedQuery], lock: Lockfile) async throws {
        let migrations = try MigrationDirectory(
            path: dir, syntax: Self.syntax(for: lock.engine)
        ).load()

        let result = lock.verify(against: parsed, migrations: migrations, engine: lock.engine)
        guard result.isClean else { throw MigrateFailure(result.report) }

        guard let out else {
            print("lockfile is current — \(Self.count(parsed.count))")
            return
        }
        let expected = QueryEmitter(
            options: .init(
                accessLevel: accessLevel, typeName: typeName,
                dialect: Self.dialectType(lock.engine)
            )
        ).emit(lock.resolved(matching: parsed))

        let committed = (try? String(contentsOfFile: out, encoding: .utf8)) ?? ""
        guard committed == expected else {
            throw MigrateFailure(
                "\(out) does not match the lockfile — it has been edited by "
                    + "hand, or was generated by a different version.\n"
                    + "  Run `swizzle generate queries` to bring it back."
            )
        }
        print("lockfile and \(out) are current — \(Self.count(parsed.count))")
    }

    private func generate(_ parsed: [ParsedQuery]) async throws -> (String, Lockfile) {
        let url = try database.resolvedURL()
        guard let engine = engines.engine(forURL: url) else {
            throw ValidationError("no registered engine handles '\(url)'")
        }
        let migrations = try MigrationDirectory(
            path: dir, syntax: Self.syntax(for: engine.name)
        ).load()
        let fingerprint = Lockfile.fingerprint(of: migrations)

        func build(_ connection: any EngineConnection) async throws -> (String, Lockfile) {
            guard let analyzer = connection.analyzer else {
                throw ValidationError(
                    "the \(connection.executor.dialectName) engine cannot describe "
                        + "statements yet, so queries cannot be generated against it"
                )
            }
            let resolved = try await QueryGenerator(analyzer: analyzer).resolve(parsed)
            let dialect = connection.executor.dialectName
            let source = QueryEmitter(
                options: .init(
                    accessLevel: accessLevel, typeName: typeName,
                    dialect: Self.dialectType(dialect)
                )
            ).emit(resolved)

            let entries = zip(parsed, resolved).map { declaration, resolved in
                Lockfile.Entry(
                    name: declaration.name, file: declaration.file,
                    key: Lockfile.key(
                        for: declaration, engine: dialect, schemaFingerprint: fingerprint,
                        generatorVersion: Lockfile.generatorVersion
                    ),
                    signature: resolved.signature
                )
            }
            return (
                source,
                Lockfile(engine: dialect, schemaFingerprint: fingerprint, queries: entries)
            )
        }

        if noShadow {
            return try await withEngine(database) { try await build($0) }
        }
        return try await ShadowRunner.withMigratedShadow(
            engine: engine, url: url,
            migrations: MigrationDirectory(path: dir, syntax: Self.syntax(for: engine.name))
        ) { connection in
            try await build(connection)
        }
    }

    static func count(_ n: Int) -> String { "\(n) quer\(n == 1 ? "y" : "ies")" }

    static func syntax(for engine: String) -> SQLStatementSplitter.Syntax {
        switch engine {
        case "mysql", "mariadb": .mysql
        case "postgres": .postgres
        default: .sqlite
        }
    }

    /// The dialect's runtime name to its Swift type, which is what the generated
    /// constraint has to say.
    static func dialectType(_ name: String) -> String {
        switch name {
        case "mysql": "MySQL"
        case "mariadb": "MariaDB"
        case "postgres": "Postgres"
        case "sqlite": "SQLite"
        default: name
        }
    }
}

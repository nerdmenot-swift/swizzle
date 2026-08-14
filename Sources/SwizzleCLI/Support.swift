import ArgumentParser
import Foundation
import NIOPosix
import SwizzleCore
import SwizzleMigrate
import SwizzleMySQLEngine
import SwizzleSQLite
import SwizzleSQLiteEngine
import SwizzlePostgres

// MARK: - Options shared by every migrate subcommand

struct DatabaseOptions: ParsableArguments {
    @Option(
        name: [.customLong("url"), .customShort("u")],
        help: ArgumentHelp(
            "Connection URL.",
            discussion: """
                mysql://user:password@host:3306/database?tls=require

                Defaults to $DATABASE_URL, which is how a deployed service is \
                normally configured — so in CI or a container you usually pass \
                nothing at all.
                """,
            valueName: "url"
        )
    )
    var url: String?

    func resolvedURL() throws -> String {
        if let url { return url }
        if let fromEnvironment = ProcessInfo.processInfo.environment["DATABASE_URL"],
           !fromEnvironment.isEmpty {
            return fromEnvironment
        }
        throw ValidationError("no --url given and DATABASE_URL is not set")
    }
}

struct MigrationOptions: ParsableArguments {
    @Option(
        name: [.customLong("dir"), .customShort("d")],
        help: ArgumentHelp("Directory holding the .sql migrations.", valueName: "path")
    )
    var directory: String = "migrations"

    @Option(help: ArgumentHelp("Table recording what has been applied.", valueName: "name"))
    var journalTable: String = "swizzle_migrations"

    @Option(help: ArgumentHelp("Seconds to wait for the migration lock.", valueName: "n"))
    var lockTimeout: Int = 30

    @Flag(
        name: .customLong("no-verify"),
        help: """
            Skip the checksum check, allowing a migration that has already been \
            applied to differ from its file. Only do this when the edit was \
            deliberate — see `swizzle migrate status`.
            """
    )
    var skipChecksumVerification = false

    @Flag(
        name: .customLong("online"),
        help: """
            Enable the binlog-driven online runner, so migrations marked \
            `-- +swizzle Online` apply without holding the table. Needs REPLICATION \
            SLAVE privileges and binlog_format=ROW. Off by default because it opens \
            extra connections and reads the binary log, which is not something to do \
            without being asked.
            """
    )
    var online = false

    @Option(
        help: ArgumentHelp(
            "Server id for the online runner's binlog connection. Must not collide "
                + "with a real replica.",
            valueName: "id"
        )
    )
    var onlineServerID: UInt32 = 9_000_042

    @Flag(
        name: .customLong("allow-out-of-order"),
        help: """
            Apply a migration numbered below one already applied. Happens after \
            a branch merge, and means running a migration against a schema it \
            was not written for.
            """
    )
    var allowOutOfOrder = false
}

// MARK: - Connecting

/// Engines this build of the CLI ships with.
///
/// A registry rather than a hardcoded engine: adding Postgres means adding one
/// line here and a module, not editing the migrator or a switch statement.
let engines = EngineRegistry([MySQLEngine.self, PostgresEngine.self, SQLiteEngine.self])
/// Connects, runs `body`, and closes — without building a migrator.
///
/// `withMigrator` always constructs one, which the generator does not want: it
/// needs the executor, the introspector and the analyzer, and never applies a
/// migration.
func withEngine<T>(
    _ database: DatabaseOptions,
    _ body: (any EngineConnection) async throws -> T
) async throws -> T {
    let url = try database.resolvedURL()
    let connection = try await engines.connect(url: url)
    defer { connection.close() }
    return try await body(connection)
}


/// Opens a connection, builds a migrator, and hands both to `body`.
///
/// Nothing in here names a database. The URL scheme picks the engine, the engine
/// supplies the executor, the dialect, the introspector and the online runner,
/// and the connection is closed on the way out however this exits — so an
/// advisory lock never outlives the process holding it.
func withMigrator<T>(
    _ database: DatabaseOptions,
    _ options: MigrationOptions,
    _ body: (Migrator, (any SchemaIntrospector)?) async throws -> T
) async throws -> T {
    let url = try database.resolvedURL()
    let connection = try await engines.connect(url: url)
    defer { connection.close() }

    var settings = Migrator.Configuration()
    settings.journalTable = options.journalTable
    settings.lockTimeoutSeconds = options.lockTimeout
    settings.verifyChecksums = !options.skipChecksumVerification
    settings.requireOrdered = !options.allowOutOfOrder

    let migrator = Migrator(
        executor: connection.executor,
        dialect: connection.dialect,
        // The splitter's rules come from the dialect, so a migration written for
        // Postgres is lexed by Postgres rules without the caller saying so.
        source: MigrationDirectory(
            path: options.directory, syntax: connection.dialect.migrationSyntax
        ),
        configuration: settings,
        onlineRunner: options.online
            ? connection.onlineRunner(serverID: options.onlineServerID)
            : nil
    )

    return try await body(migrator, connection.introspector)
}

/// A runtime problem, as opposed to a malformed command line.
///
/// `ValidationError` is ArgumentParser's, and it exits 64 (`EX_USAGE`) with a
/// usage hint — right for "you passed the wrong flag", wrong for "the database
/// is in a state that forbids this". This prints the message and exits 1.
struct MigrateFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Prints lint findings.
enum LintOutput {
    /// Prints the allowances in force.
    ///
    /// An exception nobody sees again is the same as no rule at all, so they are
    /// listed on every run rather than silently obeyed.
    static func reportSuppressions(
        _ suppressions: [(migration: String, rule: String, reason: String)]
    ) {
        guard !suppressions.isEmpty else { return }
        print("")
        print(Output.dim("\(suppressions.count) rule(s) allowed by the migrations themselves:"))
        for item in suppressions {
            print(Output.dim("  \(item.migration)  \(item.rule) — \(item.reason)"))
        }
    }

    static func report(_ findings: [LintFinding], checkedSchema: Bool) -> Int {
        guard !findings.isEmpty else {
            print(Output.green("No issues found."))
            if !checkedSchema {
                print(Output.dim(
                    "Checks that need table sizes were skipped — run `swizzle migrate lint` "
                    + "against a database for those."
                ))
            }
            return 0
        }

        for finding in findings {
            let tag = finding.severity == .error
                ? Output.red("error") : Output.yellow("warn ")
            print("\(tag) \(finding.migration)  \(Output.dim(finding.rule))")
            print("      \(finding.message)")
            print("      \(Output.dim(finding.statement))")
            // The remedy is the point. A linter that only says "no" gets
            // switched off.
            for line in finding.remedy.split(separator: "\n") {
                print("      \(Output.dim("→ " + line.trimmingCharacters(in: .whitespaces)))")
            }
            print("")
        }

        let errors = findings.filter { $0.severity == .error }.count
        let warnings = findings.count - errors
        print("\(errors) error(s), \(warnings) warning(s).")
        return errors
    }
}

// MARK: - Output

enum Output {
    /// Colour only when attached to a terminal, so piping to a file or a CI log
    /// does not fill it with escape sequences.
    static let isTerminal = isatty(STDOUT_FILENO) == 1

    static func styled(_ text: String, _ code: String) -> String {
        isTerminal ? "\u{001B}[\(code)m\(text)\u{001B}[0m" : text
    }

    static func green(_ text: String) -> String { styled(text, "32") }
    static func yellow(_ text: String) -> String { styled(text, "33") }
    static func red(_ text: String) -> String { styled(text, "31") }
    static func dim(_ text: String) -> String { styled(text, "2") }

    static func error(_ message: String) {
        FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    }

    /// Pads to a visible width, ignoring any escape sequences already applied.
    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width
            ? text
            : text + String(repeating: " ", count: width - text.count)
    }
}

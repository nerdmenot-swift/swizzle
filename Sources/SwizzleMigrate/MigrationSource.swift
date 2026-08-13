import Crypto
import Foundation

/// Hash of a migration's source text.
///
/// Recorded when a migration is applied and re-checked on every subsequent run,
/// so editing a migration that has already run is *detected* rather than
/// silently ignored. That edit is a real and common mistake — fixing a typo in a
/// migration that shipped last week leaves every existing database on the old
/// version of it and every new database on the new one, and nothing about the
/// schema says so.
///
/// goose does not do this at all. Drizzle hashes files but only to decide what
/// to run, not to detect drift. Flyway validates, and is right to.
///
/// SHA-256 rather than something cheaper because swift-crypto is already a
/// dependency and the cost is irrelevant next to a round trip.
public enum Checksum {
    public static func of(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Where migrations come from.
///
/// A protocol so migrations can be read from disk during development and from an
/// embedded resource in a shipped binary, without the runner caring. A server
/// deployed as a single executable has no migrations directory to point at.
public protocol MigrationSource: Sendable {
    func load() throws -> [Migration]
}

/// Migrations held in memory.
///
/// The embedding case, and what tests use.
public struct InMemoryMigrations: MigrationSource {
    public let migrations: [Migration]

    /// Non-throwing, so a caller holding already-validated migrations keeps a
    /// simple initialiser. Everything that builds from *files* goes through the
    /// throwing path below, which validates.
    public init(_ migrations: [Migration]) {
        self.migrations = Migration.ordered(migrations)
    }

    /// Validating initialiser — refuses two migrations claiming one version.
    public init(validating migrations: [Migration]) throws {
        self.migrations = try Migration.validated(migrations)
    }

    /// Parses a set of `filename: contents` pairs, as a build step would emit.
    public init(
        files: [String: String],
        syntax: SQLStatementSplitter.Syntax
    ) throws {
        var parsed: [Migration] = []
        for filename in files.keys.sorted() {
            let (kind, name) = try MigrationParser.parseFilename(filename)
            parsed.append(
                try MigrationParser.parse(
                    files[filename]!, kind: kind, name: name,
                    filename: filename, syntax: syntax
                )
            )
        }
        try self.init(validating: parsed)
    }

    public func load() throws -> [Migration] { migrations }
}

/// Migrations read from a directory of `.sql` files.
public struct MigrationDirectory: MigrationSource {
    public let url: URL
    public let syntax: SQLStatementSplitter.Syntax

    public init(url: URL, syntax: SQLStatementSplitter.Syntax) {
        self.url = url
        self.syntax = syntax
    }

    public init(path: String, syntax: SQLStatementSplitter.Syntax) {
        self.init(url: URL(fileURLWithPath: path), syntax: syntax)
    }

    public func load() throws -> [Migration] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw MigrationParseError(
                file: url.path, reason: "not a directory"
            )
        }

        let entries = try manager.contentsOfDirectory(atPath: url.path)
            .filter { $0.hasSuffix(".sql") && !$0.hasPrefix(".") }
            .sorted()

        var migrations: [Migration] = []

        for filename in entries {
            let (kind, name) = try MigrationParser.parseFilename(filename)
            let text = try String(
                contentsOf: url.appendingPathComponent(filename), encoding: .utf8
            )
            migrations.append(
                try MigrationParser.parse(
                    text, kind: kind, name: name, filename: filename, syntax: syntax
                )
            )
        }
        return try Migration.validated(migrations)
    }
}
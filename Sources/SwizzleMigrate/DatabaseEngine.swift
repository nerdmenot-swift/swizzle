import SwizzleCore

/// Everything one database supplies.
///
/// The point of the protocol is what it removes: before it, adding a database
/// meant editing `SwizzleMigrate` (to declare its `MigrationDialect`
/// conformance) and the CLI (to add a case to a hand-written enum). A plugin
/// system where the core changes for every plugin is not one.
///
/// An engine now lives entirely in its own module, registers itself, and nothing
/// shared has to know it exists.
public protocol DatabaseEngine: Sendable {
    /// For diagnostics and `--engine`.
    static var name: String { get }

    /// URL schemes this engine answers to, lowercased — `["postgres",
    /// "postgresql"]`. How the CLI picks an engine without being told.
    static var urlSchemes: [String] { get }

    /// Rules that only make sense for this database. MySQL's non-transactional
    /// DDL warnings mean nothing to Postgres.
    static var lintRules: [any LintRule] { get }

    static func connect(url: String) async throws -> any EngineConnection

    /// A throwaway database to run the migrations into.
    ///
    /// The code generator needs a schema that is definitely the migrations' —
    /// not whatever a server happens to hold. Generating against a drifted
    /// database produces code matching the drift, silently, and the drift is
    /// exactly what nobody knows about.
    ///
    /// Running the migrations into a scratch database also validates them for
    /// free, which is the same trick Prisma's shadow database plays.
    static func makeShadow(url: String, label: String) async throws -> any ShadowDatabase
}

/// A database that exists for the length of one command.
public protocol ShadowDatabase: Sendable {
    var connection: any EngineConnection { get }
    /// Removes it. Must be safe to call twice.
    func destroy() async
}

/// The engine has no throwaway-database story.
public struct ShadowUnsupported: Error, Sendable, CustomStringConvertible {
    public let engine: String
    public init(engine: String) { self.engine = engine }
    public var description: String {
        "the \(engine) engine cannot create a shadow database — "
            + "point --url at a scratch database yourself, or use --no-shadow"
    }
}

/// One open connection, with everything the tooling needs hanging off it.
///
/// Deliberately not `SQLExecutor`: this is the runtime path, where the dialect
/// is discovered rather than declared. See ``AnySQLExecutor``.
public protocol EngineConnection: Sendable {
    var executor: AnySQLExecutor { get }
    var dialect: AnyMigrationDialect { get }
    /// `nil` when the database cannot be introspected, which disables the
    /// size-dependent lint rules rather than failing.
    var introspector: (any SchemaIntrospector)? { get }
    /// `nil` when the engine has no zero-downtime path — most do not.
    func onlineRunner(serverID: UInt32) -> (any OnlineDDLRunner)?
    /// Describes statements without running them, for the code generator.
    ///
    /// `nil` when the engine cannot describe — which is a real possibility, not a
    /// placeholder: Postgres's own wire protocol carries everything needed, but
    /// postgres-nio keeps it internal, so this stays nil there until that is
    /// unblocked.
    var analyzer: (any QueryAnalyzer)? { get }
    func close()
}

extension EngineConnection {
    public var introspector: (any SchemaIntrospector)? { nil }
    public func onlineRunner(serverID: UInt32) -> (any OnlineDDLRunner)? { nil }
    public var analyzer: (any QueryAnalyzer)? { nil }
}

extension DatabaseEngine {
    public static func makeShadow(url: String, label: String) async throws -> any ShadowDatabase {
        throw ShadowUnsupported(engine: name)
    }
}

/// Engines available to this process.
///
/// A registry rather than a compile-time list so an application can ship only
/// the engines it uses — a service that talks to Postgres should not link a
/// MySQL driver to run its migrations.
public struct EngineRegistry: Sendable {
    private var engines: [any DatabaseEngine.Type] = []

    public init(_ engines: [any DatabaseEngine.Type] = []) {
        self.engines = engines
    }

    public mutating func register(_ engine: any DatabaseEngine.Type) {
        engines.append(engine)
    }

    public var names: [String] { engines.map { $0.name } }

    /// The engine whose scheme matches, or nil.
    public func engine(forURL url: String) -> (any DatabaseEngine.Type)? {
        guard let scheme = url.split(separator: ":").first.map(String.init)?.lowercased()
        else { return nil }
        return engines.first { $0.urlSchemes.contains(scheme) }
    }

    /// Connects using whichever engine claims the URL's scheme.
    public func connect(url: String) async throws -> any EngineConnection {
        guard let engine = engine(forURL: url) else {
            let known = engines.flatMap { $0.urlSchemes }.sorted().joined(separator: ", ")
            throw EngineError.noEngine(
                url: url,
                reason: known.isEmpty
                    ? "no engines are registered"
                    : "no registered engine handles that scheme — known: \(known)"
            )
        }
        return try await engine.connect(url: url)
    }
}

public enum EngineError: Error, Sendable, CustomStringConvertible {
    case noEngine(url: String, reason: String)

    public var description: String {
        switch self {
        case .noEngine(_, let reason): "cannot connect: \(reason)"
        }
    }
}

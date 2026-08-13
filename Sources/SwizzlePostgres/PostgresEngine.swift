import Foundation
import Logging
import NIOCore
import SwizzleCore
import SwizzleMigrate
import SwizzlePostgresDriver

/// Postgres as a pluggable engine.
public enum PostgresEngine: DatabaseEngine {
    public static let name = "postgres"
    public static let urlSchemes = ["postgres", "postgresql"]

    /// Only the rules that mean something here.
    ///
    /// `blocking-index` is dropped: Postgres has `CREATE INDEX CONCURRENTLY`, so
    /// the advice attached to that finding — "apply it online" — is wrong for
    /// this database. Shipping a warning whose remedy does not apply is how a
    /// linter gets switched off.
    public static var lintRules: [any LintRule] {
        LintRules.all.filter { $0.name != "blocking-index" }
    }

    public static func connect(url: String) async throws -> any EngineConnection {
        try await connect(configuration: PostgresConnectionConfiguration(swizzleURL: url))
    }

    /// The same, for a configuration already in hand — which is how the shadow
    /// reaches a database that has no URL of its own.
    static func connect(
        configuration connectionConfiguration: PostgresConnectionConfiguration
    ) async throws -> any EngineConnection {
        // A migrator opens one connection and holds a lock on it; a pool that
        // handed out a *different* connection would release the advisory lock
        // with the session that took it.
        var configuration = PostgresClient.Configuration(connection: connectionConfiguration)
        configuration.minimumConnections = 1
        configuration.maximumConnections = 1
        // The migrator's whole point is that state carries between statements —
        // `BEGIN`, `SET LOCAL`, an advisory lock — so resetting on release would
        // undo it between every statement.
        configuration.resetOnRelease = false

        var logger = Logger(label: "swizzle.postgres")
        logger.logLevel = .error

        let client = PostgresClient(configuration: configuration, logger: logger)

        // `run()` owns the connection pool for the client's whole life, so it is
        // a sibling task rather than something to await.
        let running = Task { await client.run() }

        // A probe, so a bad URL fails here rather than inside the first
        // migration.
        //
        // It used to be a *retry loop* against a ten-second deadline, because
        // postgres-nio's client could be queried before its own `run()` had been
        // scheduled — opening two clients back to back left the second failing on
        // the spot. That was a property of the borrowed client's startup, and it
        // is gone: the pool this uses opens a connection on demand, so the first
        // query is simply the first query.
        do {
            _ = try await client.query("SELECT 1")
        } catch {
            running.cancel()
            throw error
        }

        return PostgresEngineConnection(client: client, logger: logger, running: running)
    }
}

struct PostgresEngineConnection: EngineConnection {
    let client: PostgresClient
    let logger: Logger
    let running: Task<Void, Never>

    var executor: AnySQLExecutor {
        PostgresExecutor(client: client, logger: logger).erased
    }

    var dialect: AnyMigrationDialect { Postgres.erased }

    var introspector: (any SchemaIntrospector)? {
        PostgresIntrospector(executor: PostgresExecutor(client: client, logger: logger))
    }

    /// The analyzer holds **one** connection for the whole run.
    ///
    /// Not incidental. A describe leaves state on the session — the unnamed
    /// statement — and the catalogue lookups that follow have to resolve against
    /// the same `search_path`, so a schema-qualified name means the same thing
    /// throughout. Going statement-by-statement through the pool would be correct
    /// only because the migrator pins it to a single connection, which is exactly
    /// the accidental correctness the executor's own doc comment warns about.
    var analyzer: (any QueryAnalyzer)? { PostgresQueryAnalyzer(client: client) }

    /// None. Postgres does not need one: `ADD COLUMN` with a default is O(1)
    /// since 11, and `CREATE INDEX CONCURRENTLY` already builds without holding
    /// the table. The shadow-copy machinery exists for MySQL's lack of both.
    func onlineRunner(serverID: UInt32) -> (any OnlineDDLRunner)? { nil }

    func close() { running.cancel() }
}

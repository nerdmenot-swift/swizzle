import Foundation
import SwizzleCore
import SwizzleMigrate

/// SQLite, registered like any other engine.
///
/// Adding it touched no shared code: `SQLiteMigrationDialect`, this file and the
/// executor live entirely in this module, and the CLI learns about SQLite from
/// one line in the registry. That was the claim the pluggable-engine work made
/// after Postgres, and this is the second engine to test it.
public enum SQLiteEngine: DatabaseEngine {
    public static let name = "sqlite"

    /// `sqlite:` and `file:` both appear in the wild; `sqlite3:` is common in
    /// tooling that predates the shorter form.
    public static let urlSchemes = ["sqlite", "sqlite3", "file"]

    /// None yet.
    ///
    /// The MySQL rules warn about non-transactional DDL and about `ALTER TABLE`
    /// rewriting a large table under a lock — neither of which describes SQLite,
    /// whose DDL is transactional and whose "lock" is the whole file for the
    /// duration of a write. Inventing rules to fill the slot would be worse than
    /// leaving it empty; the shared rules still apply.
    public static let lintRules: [any LintRule] = []

    public static func connect(url: String) async throws -> any EngineConnection {
        let path = try SQLiteURL.path(from: url)
        let connection = try SQLiteConnection(path: path)
        // The lock table has to exist before the migrator's first `acquireLock`,
        // and the migrator only ever creates the journal. Postgres and MySQL do
        // not need this because their advisory locks need no storage.
        _ = try await connection.query(SQLite.createLockTable())
        return SQLiteEngineConnection(connection: connection)
    }
}

struct SQLiteEngineConnection: EngineConnection {
    let connection: SQLiteConnection

    var executor: AnySQLExecutor { connection.executor.erased }
    var dialect: AnyMigrationDialect { AnyMigrationDialect(SQLite.self) }
    var introspector: (any SchemaIntrospector)? { SQLiteIntrospector(connection) }
    var analyzer: (any QueryAnalyzer)? { SQLiteQueryAnalyzer(connection) }

    func onlineRunner(serverID: UInt32) -> (any OnlineDDLRunner)? {
        // There is nothing to be online about. Online DDL exists because MySQL's
        // `ALTER TABLE` holds a lock for the length of a table rewrite; SQLite's
        // writes are already exclusive and already fast on the file sizes it is
        // used for. A shadow-table copy here would add risk and buy nothing.
        nil
    }

    func close() { connection.close() }
}

/// Turns a URL into a filesystem path.
enum SQLiteURL {
    /// Accepts what people actually type.
    ///
    /// - `sqlite:app.db` and `sqlite:./app.db` — relative
    /// - `sqlite:/var/db/app.db` and `sqlite:///var/db/app.db` — absolute
    /// - `sqlite::memory:` — in-memory, private to the connection
    /// - `file:app.db?mode=ro` — passed through to SQLite's own URI handling
    ///
    /// The three-slash form is the one that trips people up: `sqlite:///x` is a
    /// URL with an empty authority and path `/x`, while `sqlite://x` names a
    /// *host* `x` and no path at all. Rather than silently reading the second as
    /// a relative path, it is refused with an explanation — a database opened at
    /// the wrong path creates an empty one and looks like data loss.
    static func path(from url: String) throws -> String {
        guard let separator = url.firstIndex(of: ":") else { return url }
        let scheme = String(url[url.startIndex..<separator]).lowercased()
        var rest = String(url[url.index(after: separator)...])

        // `file:` is SQLite's own URI form. Hand it over untouched so its query
        // parameters — mode, cache, immutable — keep working.
        if scheme == "file" { return url }
        guard scheme == "sqlite" || scheme == "sqlite3" else { return url }

        if rest == ":memory:" || rest.hasPrefix(":memory:") { return ":memory:" }

        if rest.hasPrefix("//") {
            let afterSlashes = rest.dropFirst(2)
            guard afterSlashes.hasPrefix("/") else {
                throw SQLiteURLError(
                    url: url,
                    reason: "'\(scheme)://\(afterSlashes)' names a host, not a path. "
                        + "Use '\(scheme):\(afterSlashes)' for a relative path "
                        + "or '\(scheme):///\(afterSlashes)' for an absolute one."
                )
            }
            rest = String(afterSlashes)
        }

        guard !rest.isEmpty else {
            throw SQLiteURLError(url: url, reason: "no database path")
        }
        return rest.removingPercentEncoding ?? rest
    }
}

struct SQLiteURLError: Error, Sendable, CustomStringConvertible {
    let url: String
    let reason: String
    var description: String { "cannot read SQLite URL '\(url)': \(reason)" }
}

extension SQLiteEngine {
    /// SQLite's shadow database is free.
    ///
    /// An in-memory connection *is* a throwaway database: it needs no server, no
    /// privileges, no name to avoid colliding with, and it disappears when the
    /// connection closes. The `url` is ignored on purpose — the whole point is
    /// not to touch whatever it names.
    public static func makeShadow(url: String, label: String) async throws -> any ShadowDatabase {
        let connection = try SQLiteConnection.inMemory()
        _ = try await connection.query(SQLite.createLockTable())
        return SQLiteShadow(inner: SQLiteEngineConnection(connection: connection))
    }
}

struct SQLiteShadow: ShadowDatabase {
    let inner: SQLiteEngineConnection
    var connection: any EngineConnection { inner }
    func destroy() async { inner.close() }
}

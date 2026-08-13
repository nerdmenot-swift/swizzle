import Foundation
import NIOConcurrencyHelpers
import NIOPosix
import SwizzleCore
import SwizzleMigrate
import SwizzleMySQL

extension MySQLEngine {

    /// Creates a throwaway database, migrates into it, and drops it afterwards.
    ///
    /// ## The trap that makes this different from `USE`
    ///
    /// The obvious implementation is `CREATE DATABASE …` then `USE …` on the same
    /// connection. It is wrong, and wrong in a way that shows up as impossible
    /// behaviour rather than an error.
    ///
    /// A prepared statement is **per session** and resolves its unqualified table
    /// names against whatever database was current when it was *prepared*. The
    /// driver caches prepared statements per connection, so after a `USE` the
    /// cache still holds statements bound to the old schema — and the analyzer's
    /// whole job is preparing statements. Half a run would describe the shadow and
    /// half would describe production, with nothing to say which.
    ///
    /// So the shadow gets its **own connection**, opened with the database already
    /// in the configuration. A fresh session has an empty statement cache by
    /// construction, which is the only version of this that cannot drift.
    ///
    /// Postgres avoids the problem entirely — it has no cross-database connection
    /// to reuse — but arrives at the same shape for its own reasons.
    public static func makeShadow(url: String, label: String) async throws -> any ShadowDatabase {
        var configuration = try MySQLConnectionConfiguration(url: url)

        let name = shadowName(label)
        guard isShadowName(name) else { throw ShadowUnsupported(engine: name) }

        // The maintenance connection creates and drops. It keeps whatever
        // database the URL named, and never issues `USE`.
        let maintenance = try await MySQLConnection.connect(
            configuration: configuration, on: MultiThreadedEventLoopGroup.singleton.next()
        )

        do {
            // Dropped first in case a previous run died before its own cleanup;
            // otherwise one interrupted generate poisons the workspace until
            // somebody drops the database by hand.
            _ = try await maintenance.query("DROP DATABASE IF EXISTS \(quoteIdentifier(name))")
            _ = try await maintenance.query("CREATE DATABASE \(quoteIdentifier(name))")
        } catch {
            try? await maintenance.close()
            throw error
        }

        configuration.database = name
        do {
            let shadow = try await MySQLConnection.connect(
                configuration: configuration, on: MultiThreadedEventLoopGroup.singleton.next()
            )
            return MySQLShadow(
                inner: MySQLEngineConnection(connection: shadow, url: url),
                shadowConnection: shadow,
                maintenance: maintenance,
                name: name
            )
        } catch {
            _ = try? await maintenance.query("DROP DATABASE IF EXISTS \(quoteIdentifier(name))")
            try? await maintenance.close()
            throw error
        }
    }

    /// `swizzle_shadow_` then the label, reduced to characters an identifier can
    /// hold. A label is a directory name or a test name, so it cannot be assumed
    /// to be one already.
    public static func shadowName(_ label: String) -> String {
        let sanitised = label.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "_"
        }
        // MySQL's limit is 64 characters, one more than Postgres's 63. Trimmed to
        // the same 63 anyway, so a project that generates against both engines
        // cannot end up with names that agree on one and collide on the other.
        return String(("swizzle_shadow_" + String(sanitised)).prefix(63))
    }

    public static func isShadowName(_ name: String) -> Bool {
        name.hasPrefix("swizzle_shadow_") && name.count > "swizzle_shadow_".count
    }

    /// Backticks, doubled to escape — MySQL's own rule, and the reason the
    /// renderer hardcodes them.
    public static func quoteIdentifier(_ identifier: String) -> String {
        "`" + identifier.replacingOccurrences(of: "`", with: "``") + "`"
    }
}

/// A class, and with a flag, because "safe to call twice" has to be a guarantee.
///
/// The first `destroy()` closes the maintenance connection; a second one issuing
/// `DROP DATABASE` down it is a query on a dead connection. That used to hang
/// forever rather than fail — see the write-promise fix in `MySQLConnection.send`
/// — and relying on the statements being *harmless* was never the same thing as
/// not sending them.
final class MySQLShadow: ShadowDatabase, @unchecked Sendable {
    let inner: MySQLEngineConnection
    let shadowConnection: MySQLConnection
    let maintenance: MySQLConnection
    let name: String

    private let lock = NIOLock()
    private var isDestroyed = false

    init(
        inner: MySQLEngineConnection, shadowConnection: MySQLConnection,
        maintenance: MySQLConnection, name: String
    ) {
        self.inner = inner
        self.shadowConnection = shadowConnection
        self.maintenance = maintenance
        self.name = name
    }

    var connection: any EngineConnection { inner }

    /// Safe to call twice, which the runner relies on: it destroys on both the
    /// success and the failure path.
    func destroy() async {
        let alreadyDone = lock.withLock {
            defer { isDestroyed = true }
            return isDestroyed
        }
        guard !alreadyDone else { return }

        // The shadow's own session goes first. MySQL will drop a database with
        // sessions attached, unlike Postgres, but a connection whose default
        // schema has just vanished is a connection nothing good happens on.
        try? await shadowConnection.close()

        guard MySQLEngine.isShadowName(name) else {
            // Unreachable by construction, and checked anyway: this statement
            // drops a database, and being wrong is not recoverable.
            try? await maintenance.close()
            return
        }

        _ = try? await maintenance.query(
            "DROP DATABASE IF EXISTS \(MySQLEngine.quoteIdentifier(name))"
        )
        try? await maintenance.close()
    }
}

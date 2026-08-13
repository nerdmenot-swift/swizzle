import Foundation
import NIOConcurrencyHelpers
import Logging
import SwizzleCore
import SwizzleMigrate
import SwizzlePostgresDriver

extension PostgresEngine {

    /// Creates a throwaway database, migrates into it, and drops it afterwards.
    ///
    /// ## Why a real database rather than a schema
    ///
    /// A separate *schema* would be cheaper and would not need `CREATEDB`. It is
    /// also the wrong answer: migrations name their own schemas, create
    /// extensions, and set database-level parameters, so a schema-shaped shadow
    /// diverges from the thing it is standing in for exactly when the migrations
    /// get interesting. A database is what production is.
    ///
    /// ## The two Postgres-specific traps
    ///
    /// `CREATE DATABASE` cannot run inside a transaction block, and it cannot run
    /// on the database being created — so both statements go through a
    /// *maintenance* connection to a different database, which stays open for the
    /// shadow's whole life.
    ///
    /// And `DROP DATABASE` fails outright while any session is connected. The
    /// shadow's own connection is closed first, and the drop asks for `FORCE` so
    /// an abandoned session — a `psql` someone left open on it — does not leave
    /// the database behind forever.
    public static func makeShadow(url: String, label: String) async throws -> any ShadowDatabase {
        var configuration = try PostgresConnectionConfiguration(swizzleURL: url)

        let name = shadowName(label)
        // A guard rail, not a formality: `destroy()` refuses to drop anything
        // that does not match, so the name has to be built the same way here.
        guard isShadowName(name) else {
            throw ShadowUnsupported(engine: name)
        }

        // The maintenance connection goes to whatever the URL named. Falling back
        // to `postgres` would be the libpq habit, but a managed provider often
        // does not grant access to it — and the URL's own database is one we
        // demonstrably can reach.
        let maintenanceURL = url
        let maintenance = try await connect(url: maintenanceURL)

        do {
            // Dropped first in case a previous run died before its own cleanup.
            _ = try await maintenance.executor.execute(
                sql: "DROP DATABASE IF EXISTS \(quoteIdentifier(name)) WITH (FORCE)", bindings: []
            )
            _ = try await maintenance.executor.execute(
                sql: "CREATE DATABASE \(quoteIdentifier(name))", bindings: []
            )
        } catch {
            maintenance.close()
            throw error
        }

        configuration.database = name
        do {
            let shadow = try await connect(configuration: configuration)
            return PostgresShadow(
                inner: shadow, maintenance: maintenance, name: name
            )
        } catch {
            _ = try? await maintenance.executor.execute(
                sql: "DROP DATABASE IF EXISTS \(quoteIdentifier(name)) WITH (FORCE)", bindings: []
            )
            maintenance.close()
            throw error
        }
    }

    /// `swizzle_shadow_` then the label, reduced to characters an identifier can
    /// hold. A label is a directory name or a test name, so it cannot be trusted
    /// to be one already.
    public static func shadowName(_ label: String) -> String {
        let sanitised = label.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "_"
        }
        // Postgres truncates identifiers at 63 bytes, silently. Two shadows whose
        // names differ only past the limit would be the *same* database, so the
        // trim happens here where it is visible.
        return String(("swizzle_shadow_" + String(sanitised)).prefix(63))
    }

    public static func isShadowName(_ name: String) -> Bool {
        name.hasPrefix("swizzle_shadow_") && name.count > "swizzle_shadow_".count
    }

    public static func quoteIdentifier(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// A class, and with a flag, because "safe to call twice" has to be a guarantee.
///
/// The first `destroy()` closes the maintenance connection, so a second one
/// issuing `DROP DATABASE` down it is a query on a dead connection. Relying on
/// the statement being *harmless* is not the same as not sending it — and on the
/// MySQL side the identical shape hung forever.
final class PostgresShadow: ShadowDatabase, @unchecked Sendable {
    let inner: any EngineConnection
    let maintenance: any EngineConnection
    let name: String

    private let lock = NIOLock()
    private var isDestroyed = false

    init(inner: any EngineConnection, maintenance: any EngineConnection, name: String) {
        self.inner = inner
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

        // The shadow's own session has to go first — `DROP DATABASE` fails while
        // anything is connected, including us.
        inner.close()

        guard PostgresEngine.isShadowName(name) else {
            // Unreachable by construction, and checked anyway: this statement
            // drops a database, and the cost of being wrong is not recoverable.
            maintenance.close()
            return
        }

        _ = try? await maintenance.executor.execute(
            sql: "DROP DATABASE IF EXISTS \(PostgresEngine.quoteIdentifier(name)) WITH (FORCE)",
            bindings: []
        )
        maintenance.close()
    }
}

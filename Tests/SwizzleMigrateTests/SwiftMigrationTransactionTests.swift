import SwizzleCore
import Testing

@testable import SwizzleMigrate

/// `usesTransaction` on the Swift migration path.
///
/// The SQL path has had `-- +swizzle NoTransaction` since it was written, and
/// `goose` — which this file format is modelled on — has the same split on its
/// *code* path: `AddMigrationContext` hands you a `*sql.Tx` while
/// `AddMigrationNoTxContext` hands you a `*sql.DB`. Swift migrations had neither
/// half, so every one of them was wrapped with no way to say otherwise.
///
/// Two things that made impossible: `CREATE INDEX CONCURRENTLY`, which Postgres
/// refuses inside a transaction block at all, and honest batching — chunking
/// exists to keep transactions short, and every chunk was landing inside one
/// long-running transaction.
///
/// These tests work on the `Migration` the source produces rather than against a
/// server, because the flag's whole job is to reach the runner: the runner's own
/// `wrap` decision is `migration.usesTransaction && dialect.hasTransactionalDDL`,
/// and it was the first half that could not be influenced.
@Suite("Swift migration transaction control")
struct SwiftMigrationTransactionTests {

    struct Wrapped: SwiftMigration {
        static let version: Int64 = 1
        static let name = "wrapped"
        func up(_ database: some MigrationContext) async throws {}
    }

    struct Unwrapped: SwiftMigration {
        static let version: Int64 = 2
        static let name = "unwrapped"
        static let usesTransaction = false
        func up(_ database: some MigrationContext) async throws {}
    }

    /// The default has to stay `true`: a migration that quietly stopped being
    /// atomic because a property was added would be the worst kind of change.
    @Test("a migration that says nothing is still wrapped")
    func defaultIsWrapped() throws {
        let loaded = try SwiftMigrations([Wrapped()]).load()
        #expect(loaded.count == 1)
        #expect(loaded[0].usesTransaction)
    }

    /// **The gap.** Before this, `usesTransaction` was never passed through, so
    /// the value below could be declared and had no effect whatsoever.
    @Test("opting out reaches the Migration the runner sees")
    func optOutReachesTheRunner() throws {
        let loaded = try SwiftMigrations([Unwrapped()]).load()
        #expect(loaded.count == 1)
        #expect(loaded[0].usesTransaction == false)
    }

    /// Mixed sources keep each migration's own answer — the flag travels with
    /// the migration, not with the source.
    @Test("the flag survives being combined with SQL migrations")
    func survivesCombining() throws {
        let sql = InMemoryMigrations([
            Migration(
                kind: .versioned(3), name: "plain_sql",
                up: .sql(["SELECT 1"]), down: nil, checksum: "x"
            )
        ])
        let combined = try CombinedMigrations([sql, SwiftMigrations([Wrapped(), Unwrapped()])])
            .load()

        let byName = Dictionary(uniqueKeysWithValues: combined.map { ($0.name, $0) })
        #expect(byName["wrapped"]?.usesTransaction == true)
        #expect(byName["unwrapped"]?.usesTransaction == false)
        #expect(byName["plain_sql"]?.usesTransaction == true)
    }

    /// And it composes with `ReversibleSwiftMigration`, which is a separate axis:
    /// "can be reverted" and "runs in a transaction" are independent questions
    /// and a migration may answer them differently.
    @Test("reversibility and transaction control are independent")
    func independentOfReversibility() throws {
        struct Both: ReversibleSwiftMigration {
            static let version: Int64 = 4
            static let name = "both"
            static let usesTransaction = false
            func up(_ database: some MigrationContext) async throws {}
            func down(_ database: some MigrationContext) async throws {}
        }
        let loaded = try SwiftMigrations([Both()]).load()
        #expect(loaded[0].usesTransaction == false)
        #expect(loaded[0].down != nil)
    }
}

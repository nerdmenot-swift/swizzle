import Testing
@testable import SwizzlePostgresDriver

@Suite("Postgres statement cache")
struct StatementCacheTests {

    @Test("a repeated query reuses its statement")
    func reuse() {
        var cache = PostgresStatementCache()
        let (name, evicted) = cache.insert("SELECT 1")
        #expect(evicted == nil)
        #expect(cache.name(for: "SELECT 1") == name)
        #expect(cache.count == 1)
    }

    /// Distinguishable from a statement the application prepared itself with
    /// `PREPARE`, which shares the same namespace.
    @Test("names are prefixed and unique")
    func names() {
        var cache = PostgresStatementCache()
        let first = cache.insert("SELECT 1").name
        let second = cache.insert("SELECT 2").name
        #expect(first.hasPrefix("swizzle_"))
        #expect(first != second)
    }

    /// **Eviction is a protocol concern, not a memory one.** A prepared statement
    /// is a server-side allocation, so the evicted name has to come back for the
    /// caller to `Close` — dropping it silently leaks the statement on the server
    /// until the connection dies.
    @Test("eviction hands back the name that must be closed")
    func evictionReturnsTheName() {
        var cache = PostgresStatementCache(capacity: 2)
        let first = cache.insert("SELECT 1").name
        _ = cache.insert("SELECT 2")
        let (_, evicted) = cache.insert("SELECT 3")

        #expect(evicted == first)
        #expect(cache.count == 2)
        #expect(cache.name(for: "SELECT 1") == nil)
    }

    @Test("least recently used goes first, not least recently inserted")
    func lruOrder() {
        var cache = PostgresStatementCache(capacity: 2)
        _ = cache.insert("SELECT 1")
        let second = cache.insert("SELECT 2").name
        // Touching the first makes the second the oldest.
        _ = cache.name(for: "SELECT 1")

        let (_, evicted) = cache.insert("SELECT 3")
        #expect(evicted == second)
        #expect(cache.name(for: "SELECT 1") != nil)
    }

    /// Re-parsing the same query supersedes the old statement, which also has to
    /// be closed rather than orphaned.
    @Test("re-inserting a query supersedes and returns the old name")
    func supersede() {
        var cache = PostgresStatementCache()
        let first = cache.insert("SELECT 1").name
        let (second, evicted) = cache.insert("SELECT 1")

        #expect(evicted == first)
        #expect(second != first)
        #expect(cache.count == 1)
        #expect(cache.name(for: "SELECT 1") == second)
    }

    /// With caching off a name is still handed out, but nothing is stored — and
    /// crucially nothing is reported as evicted, or the caller would close the
    /// very statement it is about to use.
    @Test("a disabled cache stores nothing and evicts nothing")
    func disabled() {
        var cache = PostgresStatementCache(capacity: 0)
        let (name, evicted) = cache.insert("SELECT 1")
        #expect(!name.isEmpty)
        #expect(evicted == nil)
        #expect(cache.isEmpty)
        #expect(!cache.isEnabled)
        #expect(cache.name(for: "SELECT 1") == nil)
    }

    @Test("removeAll reports what it was tracking")
    func removeAll() {
        var cache = PostgresStatementCache()
        _ = cache.insert("SELECT 1")
        _ = cache.insert("SELECT 2")
        #expect(cache.removeAll().count == 2)
        #expect(cache.isEmpty)
    }

    // MARK: - The error that makes caching dangerous

    /// `ALTER TABLE` invalidates cached plans, and the server says so with
    /// `0A000`. Recognising it is what separates a cache from an outage.
    @Test("a stale cached plan is recognised")
    func staleCachedPlan() {
        let stale = PostgresServerMessage(fields: [
            0x43: "0A000", 0x4D: "cached plan must not change result type",
        ])
        #expect(stale.indicatesStaleCachedPlan)

        // Not every 0A000 is this — `0A000` is feature_not_supported generally.
        let other = PostgresServerMessage(fields: [
            0x43: "0A000", 0x4D: "cannot insert into a view",
        ])
        #expect(!other.indicatesStaleCachedPlan)

        let unrelated = PostgresServerMessage(fields: [0x43: "42601", 0x4D: "cached plan"])
        #expect(!unrelated.indicatesStaleCachedPlan)
    }

    /// Superseding one query must not disturb the eviction order of the others.
    ///
    /// `supersede` above checks the name handed back and stops there, so the
    /// mutation sweep could flip `usageOrder.removeAll { $0 == existing }` to
    /// `!= existing` — which removes **everything except** the superseded entry —
    /// and nothing noticed. The cache still answers `name(for:)` correctly from
    /// its dictionaries; only the eviction order is destroyed, and that surfaces
    /// later as the wrong statement being closed while it is still in use.
    @Test("superseding a query leaves the other entries' order intact")
    func supersedeKeepsLRUOrder() {
        var cache = PostgresStatementCache(capacity: 3)
        let one = cache.insert("SELECT 1").name
        _ = cache.insert("SELECT 2")
        _ = cache.insert("SELECT 3")

        // Re-parse the newest. `SELECT 1` is still the oldest and must stay so.
        _ = cache.insert("SELECT 3")

        let (_, evicted) = cache.insert("SELECT 4")
        #expect(
            evicted == one,
            "the oldest entry should have gone; the supersession must not have reordered it"
        )
    }

    /// And `remove(name:)` — used when the server rejects a statement — takes out
    /// exactly one entry.
    ///
    /// It had no test at all, which is why the same inversion survived there too.
    /// With `!= name` the call empties the usage order of everything *but* the
    /// statement being forgotten, so the cache believes its only live statement
    /// is the one just discarded.
    @Test("removing one statement leaves the rest tracked and ordered")
    func removeTakesExactlyOne() {
        var cache = PostgresStatementCache(capacity: 3)
        let one = cache.insert("SELECT 1").name
        let two = cache.insert("SELECT 2").name
        _ = cache.insert("SELECT 3")

        let removed = cache.remove(name: two)
        #expect(removed)
        #expect(cache.count == 2)
        #expect(cache.name(for: "SELECT 2") == nil, "the removed one is gone")
        #expect(cache.name(for: "SELECT 1") != nil, "the others are not")
        #expect(cache.name(for: "SELECT 3") != nil)

        // `name(for:)` above touched 1 then 3, so 1 is the oldest again.
        _ = cache.insert("SELECT 4")
        let (_, evicted) = cache.insert("SELECT 5")
        #expect(evicted != nil, "the cache is full again and must evict")
        #expect(evicted != two, "an already-removed statement must never be evicted twice")
    }

    /// Removing something that was never there is not an error and changes
    /// nothing — the server can reject a name the cache has already dropped.
    @Test("removing an unknown name reports false and disturbs nothing")
    func removeUnknown() {
        var cache = PostgresStatementCache(capacity: 2)
        let one = cache.insert("SELECT 1").name
        let missing = cache.remove(name: "swizzle_never")
        #expect(!missing)
        #expect(cache.count == 1)
        #expect(cache.name(for: "SELECT 1") == one)
    }

}

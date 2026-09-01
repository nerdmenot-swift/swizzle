import Testing
@testable import SwizzleMySQL

/// The prepared-statement cache, where eviction is a **protocol** obligation.
///
/// ## Why an ordinary LRU test is not enough
///
/// A prepared statement is a server-side allocation. Evicting an entry without
/// telling anyone does not free memory — it strands the statement on the server
/// until the connection dies, and a long-lived pooled connection running a query
/// generator strands one per eviction. So `insert` hands back whatever it
/// displaced and the caller must send `COM_STMT_CLOSE` for it, which makes
/// *what comes back* as much a part of the contract as what stays in.
///
/// Two displacements are possible and they are different: an eviction, when the
/// cache is over capacity, and a supersession, when the same query text is
/// re-prepared under a new id. Both strand a statement if dropped, and the
/// second is easy to miss because nothing about it looks like an eviction.
///
/// Nothing tested this file at all.
@Suite("MySQL statement cache")
struct StatementCacheTests {

    static func statement(id: UInt32, query: String) -> MySQLPreparedStatement {
        MySQLPreparedStatement(id: id, query: query, parameters: [], columns: [])
    }

    // MARK: - Capacity

    /// A zero capacity disables the cache entirely, and `isEnabled` is what
    /// callers branch on before preparing at all.
    @Test("a zero capacity disables the cache")
    func zeroCapacityDisables() {
        var cache = MySQLStatementCache(capacity: 0)
        #expect(!cache.isEnabled)
        #expect(cache.insert(Self.statement(id: 1, query: "SELECT 1")) == nil,
                "returning the statement here would make the caller close the one it is about to use")
        #expect(cache.isEmpty)
        #expect(cache.statement(for: "SELECT 1") == nil)
    }

    /// A capacity of one is enabled — the boundary next to it.
    @Test("a capacity of one is enabled")
    func capacityOneIsEnabled() {
        var cache = MySQLStatementCache(capacity: 1)
        #expect(cache.isEnabled)
        #expect(cache.insert(Self.statement(id: 1, query: "a")) == nil)
        #expect(cache.count == 1)
    }

    /// A negative capacity is clamped rather than producing a cache that
    /// evicts on every insert.
    @Test("a negative capacity behaves as zero")
    func negativeCapacity() {
        var cache = MySQLStatementCache(capacity: -5)
        #expect(!cache.isEnabled)
        #expect(cache.insert(Self.statement(id: 1, query: "a")) == nil)
        #expect(cache.isEmpty)
    }

    // MARK: - Eviction

    /// Filling to exactly capacity evicts nothing; one more evicts exactly one.
    /// Both sides, because an off-by-one here throws away a live statement on
    /// every insert once the cache is warm.
    @Test("eviction turns over at exactly one past capacity")
    func evictionBoundary() {
        var cache = MySQLStatementCache(capacity: 3)
        for id: UInt32 in 1...3 {
            #expect(
                cache.insert(Self.statement(id: id, query: "q\(id)")) == nil,
                "filling to capacity evicts nothing"
            )
        }
        #expect(cache.count == 3)

        let evicted = cache.insert(Self.statement(id: 4, query: "q4"))
        #expect(evicted?.id == 1, "the least recently used goes")
        #expect(cache.count == 3, "and the cache stays at capacity")
        #expect(cache.statement(for: "q1") == nil, "its query mapping goes with it")
        #expect(cache.contains(id: 1) == false)
    }

    /// A lookup marks a statement most-recently-used, which is the whole point
    /// of the ordering — a hot query must not be evicted by a burst of cold
    /// ones.
    @Test("a lookup protects a statement from the next eviction")
    func lookupRefreshesOrder() {
        var cache = MySQLStatementCache(capacity: 3)
        for id: UInt32 in 1...3 { cache.insert(Self.statement(id: id, query: "q\(id)")) }

        #expect(cache.statement(for: "q1")?.id == 1, "touching the oldest")
        let evicted = cache.insert(Self.statement(id: 4, query: "q4"))
        #expect(evicted?.id == 2, "so the next-oldest goes instead")
        #expect(cache.contains(id: 1), "and the touched one stays")
    }

    /// Repeated eviction stays at capacity rather than drifting.
    @Test("a long run of inserts holds the cache at capacity")
    func steadyState() {
        var cache = MySQLStatementCache(capacity: 4)
        var evictions = 0
        for id: UInt32 in 1...100 {
            if cache.insert(Self.statement(id: id, query: "q\(id)")) != nil { evictions += 1 }
            #expect(cache.count <= 4, "after \(id) inserts")
        }
        #expect(cache.count == 4)
        #expect(evictions == 96, "every insert past the first four displaced one")
    }

    // MARK: - Supersession

    /// **The displacement that does not look like one.** Re-preparing the same
    /// query text yields a *new* statement id, and the old one is still
    /// allocated on the server — so it has to come back to be closed, exactly
    /// like an eviction.
    @Test("re-preparing a query returns the statement it supersedes")
    func supersessionReturnsTheOldStatement() {
        var cache = MySQLStatementCache(capacity: 10)
        cache.insert(Self.statement(id: 1, query: "SELECT 1"))

        let superseded = cache.insert(Self.statement(id: 2, query: "SELECT 1"))
        #expect(superseded?.id == 1, "the old id is still allocated server-side")
        #expect(cache.count == 1, "and does not linger as a second entry")
        #expect(cache.statement(for: "SELECT 1")?.id == 2)
        #expect(!cache.contains(id: 1))
    }

    /// Inserting the *same* statement again is not a supersession — there is
    /// nothing to close, and returning it would make the caller close the
    /// statement it just looked up.
    @Test("re-inserting the identical statement supersedes nothing")
    func reinsertingTheSameStatement() {
        var cache = MySQLStatementCache(capacity: 10)
        cache.insert(Self.statement(id: 1, query: "SELECT 1"))

        #expect(
            cache.insert(Self.statement(id: 1, query: "SELECT 1")) == nil,
            "same query, same id — nothing was displaced"
        )
        #expect(cache.count == 1)
        #expect(cache.statement(for: "SELECT 1")?.id == 1)
    }

    /// A supersession must not corrupt the ordering of everything else, which
    /// it would if it removed the wrong entries from the usage list.
    @Test("a supersession leaves the rest of the ordering intact")
    func supersessionKeepsOrdering() {
        var cache = MySQLStatementCache(capacity: 3)
        cache.insert(Self.statement(id: 1, query: "a"))
        cache.insert(Self.statement(id: 2, query: "b"))
        cache.insert(Self.statement(id: 3, query: "c"))

        // Re-prepare the middle one under a new id.
        #expect(cache.insert(Self.statement(id: 4, query: "b"))?.id == 2)
        #expect(cache.count == 3)

        // `a` is still the least recently used, so it goes next.
        #expect(cache.insert(Self.statement(id: 5, query: "d"))?.id == 1)
        #expect(cache.contains(id: 3), "c survives")
        #expect(cache.contains(id: 4), "and the re-prepared b survives")
    }

    // MARK: - Removal

    @Test("removing a statement returns it and clears its query mapping")
    func removal() {
        var cache = MySQLStatementCache(capacity: 10)
        cache.insert(Self.statement(id: 1, query: "a"))
        cache.insert(Self.statement(id: 2, query: "b"))

        #expect(cache.remove(id: 1)?.query == "a")
        #expect(cache.statement(for: "a") == nil)
        #expect(cache.count == 1)
        #expect(cache.remove(id: 1) == nil, "removing it twice is not an error")
        #expect(cache.remove(id: 99) == nil)
    }

    /// Removal must take the entry out of the ordering too, or a later eviction
    /// picks an id that is no longer there and evicts nothing while the cache
    /// stays over capacity.
    @Test("a removed statement leaves the ordering usable")
    func removalKeepsOrderingUsable() {
        var cache = MySQLStatementCache(capacity: 2)
        cache.insert(Self.statement(id: 1, query: "a"))
        cache.insert(Self.statement(id: 2, query: "b"))
        #expect(cache.remove(id: 1)?.id == 1)

        // Room for one more without evicting.
        #expect(cache.insert(Self.statement(id: 3, query: "c")) == nil)
        #expect(cache.count == 2)
        // And the next insert evicts `b`, the oldest of what remains.
        #expect(cache.insert(Self.statement(id: 4, query: "d"))?.id == 2)
        #expect(cache.count == 2)
    }

    /// `removeAll` exists for `COM_RESET_CONNECTION` and `COM_CHANGE_USER`,
    /// which deallocate every statement server-side. Keeping the cache after
    /// one would hand out ids the server has forgotten, and the resulting
    /// "Unknown prepared statement handler" arrives on a later, unrelated
    /// query.
    @Test("removeAll returns every statement and empties the cache")
    func removeAllReturnsEverything() {
        var cache = MySQLStatementCache(capacity: 10)
        for id: UInt32 in 1...5 { cache.insert(Self.statement(id: id, query: "q\(id)")) }

        let all = cache.removeAll()
        #expect(Set(all.map(\.id)) == Set<UInt32>(1...5))
        #expect(cache.isEmpty)
        #expect(cache.statement(for: "q1") == nil)

        // And the cache still works afterwards, with the ordering reset.
        #expect(cache.insert(Self.statement(id: 9, query: "later")) == nil)
        #expect(cache.statement(for: "later")?.id == 9)
        #expect(cache.removeAll().count == 1)
        #expect(cache.removeAll().isEmpty)
    }
}

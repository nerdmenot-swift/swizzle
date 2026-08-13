/// LRU cache of server-side prepared statements, keyed by query text.
///
/// The unnamed statement is correct but costs a `Parse` on every execution — the
/// server re-plans each time. A named statement is parsed once and bound
/// thereafter, which is the difference between two round trips of work and one.
///
/// Eviction is a **protocol** concern, not just a memory one: a prepared
/// statement is a server-side allocation, so `insert` hands back whatever it
/// evicted and the caller must send `Close` for it. Dropping the entry silently
/// leaks the statement on the server until the connection dies.
///
/// Modelled on MySQL's `MySQLStatementCache`, which was modelled on
/// `mysql_async`'s `StmtCache`. The names differ from MySQL's numeric statement
/// ids because Postgres names statements with strings.
public struct PostgresStatementCache: Sendable {
    /// Large enough that a normal application never evicts, small enough to bound
    /// a pathological query generator.
    public static let defaultCapacity = 256

    private let capacity: Int
    /// Query text to statement name.
    private var namesByQuery: [String: String] = [:]
    private var queriesByName: [String: String] = [:]
    /// Least-recently-used first.
    private var usageOrder: [String] = []
    private var nextID = 0

    public init(capacity: Int = PostgresStatementCache.defaultCapacity) {
        self.capacity = Swift.max(0, capacity)
    }

    public var count: Int { queriesByName.count }
    public var isEmpty: Bool { queriesByName.isEmpty }
    public var isEnabled: Bool { capacity > 0 }

    /// The name of an already-prepared statement, marked most-recently-used.
    public mutating func name(for query: String) -> String? {
        guard let name = namesByQuery[query] else { return nil }
        touch(name)
        return name
    }

    /// Reserves a name for a query about to be parsed, returning any statement
    /// evicted to make room.
    ///
    /// **The returned name must be closed on the server.**
    public mutating func insert(_ query: String) -> (name: String, evicted: String?) {
        nextID += 1
        // Prefixed so a statement this driver created is distinguishable from
        // one the application prepared itself with `PREPARE`, which shares the
        // same namespace.
        let name = "swizzle_\(nextID)"

        // With caching off, a name is still handed out — the caller may want a
        // named statement for other reasons — but nothing is stored, and nothing
        // is evicted. Returning an eviction here would make the caller close the
        // statement it is about to use.
        guard capacity > 0 else { return (name, nil) }

        // Re-parsing the same query supersedes the old statement, which also has
        // to be closed rather than orphaned.
        var evicted: String?
        if let existing = namesByQuery[query] {
            evicted = existing
            queriesByName.removeValue(forKey: existing)
            usageOrder.removeAll { $0 == existing }
        }

        namesByQuery[query] = name
        queriesByName[name] = query
        touch(name)

        if evicted == nil, queriesByName.count > capacity, let oldest = usageOrder.first {
            usageOrder.removeFirst()
            if let query = queriesByName.removeValue(forKey: oldest) {
                namesByQuery.removeValue(forKey: query)
            }
            evicted = oldest
        }
        return (name, evicted)
    }

    /// Forgets a single statement — used when the server rejects it.
    @discardableResult
    public mutating func remove(name: String) -> Bool {
        guard let query = queriesByName.removeValue(forKey: name) else { return false }
        namesByQuery.removeValue(forKey: query)
        usageOrder.removeAll { $0 == name }
        return true
    }

    /// Forgets everything, returning the names that were being tracked.
    ///
    /// The names are returned rather than discarded because the caller may still
    /// need to close them — except in the one case this exists for, where the
    /// server has already invalidated them itself.
    @discardableResult
    public mutating func removeAll() -> [String] {
        let names = Array(queriesByName.keys)
        namesByQuery.removeAll()
        queriesByName.removeAll()
        usageOrder.removeAll()
        return names
    }

    private mutating func touch(_ name: String) {
        usageOrder.removeAll { $0 == name }
        usageOrder.append(name)
    }
}

extension PostgresServerMessage {
    /// Whether this error means "your cached statement is stale".
    ///
    /// ## The trap this exists for
    ///
    /// Caching prepared statements on a connection is free until somebody runs
    /// `ALTER TABLE`. The next execution of a cached statement fails with
    /// `0A000` — *cached plan must not change result type* — and, crucially, it
    /// **fails again every time after that**, because the cache keeps handing back
    /// the same stale statement. A long-lived pooled connection stays broken until
    /// something closes it, which in production means one deploy poisoning a pool
    /// for hours.
    ///
    /// The fix is to recognise the error, drop the cache, and retry once. pgx and
    /// asyncpg both do exactly this; a driver that caches without it has traded a
    /// round trip for an outage.
    public var indicatesStaleCachedPlan: Bool {
        sqlState == "0A000" && message.contains("cached plan")
    }
}

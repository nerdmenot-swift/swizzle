/// LRU cache of server-side prepared statements, keyed by query text.
///
/// This is the piece MySQLNIO cannot offer: it closes every statement as soon
/// as the result set finishes, so PREPARE/EXECUTE/CLOSE runs on every query —
/// three round trips where there should be one.
///
/// Eviction is a **protocol** concern, not just a memory one: a prepared
/// statement is a server-side allocation, so `insert` hands back whatever it
/// evicted and the caller must send `COM_STMT_CLOSE` for it. Dropping the entry
/// silently leaks the statement on the server until the connection dies.
///
/// Modelled on `mysql_async`'s `StmtCache`.
public struct MySQLStatementCache: Sendable {
    /// node-mysql2's default; large enough that a normal application never
    /// evicts, small enough to bound a pathological query generator.
    public static let defaultCapacity = 256

    private var capacity: Int
    /// Query text to statement id.
    private var idsByQuery: [String: UInt32] = [:]
    private var entries: [UInt32: MySQLPreparedStatement] = [:]
    /// Least-recently-used first.
    private var usageOrder: [UInt32] = []

    public init(capacity: Int = MySQLStatementCache.defaultCapacity) {
        self.capacity = Swift.max(0, capacity)
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
    public var isEnabled: Bool { capacity > 0 }

    public func contains(id: UInt32) -> Bool { entries[id] != nil }

    /// Looks up a statement and marks it most-recently-used.
    public mutating func statement(for query: String) -> MySQLPreparedStatement? {
        guard let id = idsByQuery[query], let statement = entries[id] else { return nil }
        touch(id)
        return statement
    }

    /// Inserts a statement, returning any statement evicted to make room.
    ///
    /// **The returned statement must be closed on the server.**
    @discardableResult
    public mutating func insert(_ statement: MySQLPreparedStatement) -> MySQLPreparedStatement? {
        // With caching disabled nothing is stored and nothing is evicted.
        // Returning the statement here would make the caller close the very
        // statement it is about to use.
        guard capacity > 0 else { return nil }

        // Re-preparing the same query supersedes the old statement, which also
        // has to be closed rather than orphaned.
        var superseded: MySQLPreparedStatement?
        if let existingID = idsByQuery[statement.query], existingID != statement.id {
            superseded = entries.removeValue(forKey: existingID)
            usageOrder.removeAll { $0 == existingID }
        }

        idsByQuery[statement.query] = statement.id
        entries[statement.id] = statement
        touch(statement.id)

        if let superseded { return superseded }

        if entries.count > capacity, let oldest = usageOrder.first {
            usageOrder.removeFirst()
            let evicted = entries.removeValue(forKey: oldest)
            if let evicted { idsByQuery.removeValue(forKey: evicted.query) }
            return evicted
        }
        return nil
    }

    public mutating func remove(id: UInt32) -> MySQLPreparedStatement? {
        guard let statement = entries.removeValue(forKey: id) else { return nil }
        idsByQuery.removeValue(forKey: statement.query)
        usageOrder.removeAll { $0 == id }
        return statement
    }

    /// Drops every entry and returns them all.
    ///
    /// Used after `COM_RESET_CONNECTION` / `COM_CHANGE_USER`, which deallocate
    /// every prepared statement server-side. Keeping the cache after one of
    /// those would hand out statement ids the server has already forgotten —
    /// and the resulting "Unknown prepared statement handler" arrives on a
    /// later, unrelated query.
    public mutating func removeAll() -> [MySQLPreparedStatement] {
        let all = Array(entries.values)
        entries.removeAll()
        idsByQuery.removeAll()
        usageOrder.removeAll()
        return all
    }

    private mutating func touch(_ id: UInt32) {
        usageOrder.removeAll { $0 == id }
        usageOrder.append(id)
    }
}

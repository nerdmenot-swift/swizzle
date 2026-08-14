public protocol SQLDialect: Sendable {
    static var dialectName: String { get }
    static var identifierQuote: Character { get }
    static func writePlaceholder(index: Int, into sql: inout String)

    /// What goes between `INSERT` and `INTO` to ignore duplicates, including its
    /// trailing space. Empty for a dialect that does not offer it.
    ///
    /// A property rather than a branch in the renderer, and that is the whole
    /// point of it existing. The renderer used to write
    /// `D.dialectName == "sqlite" ? "OR IGNORE " : "IGNORE "` — the only place in
    /// shared code that compared a dialect *by name*. Two ways for that to be
    /// wrong: a fourth dialect conforming to ``SupportsInsertIgnore`` silently
    /// got MySQL's spelling, and renaming a dialect changed the SQL it emits.
    ///
    /// `INSERT OR IGNORE` is a syntax error on MySQL and `INSERT IGNORE` is one
    /// on SQLite, so a silently wrong spelling is a statement that does not run.
    static var insertIgnoreClause: String { get }
}

extension SQLDialect {
    @inlinable
    public static func writeIdentifier(_ name: String, into sql: inout String) {
        sql.append(identifierQuote)
        sql.append(name)
        sql.append(identifierQuote)
    }

    /// The MySQL spelling, which is the majority one. A dialect that spells it
    /// differently — SQLite — says so, and one that cannot do it at all simply
    /// never conforms to ``SupportsInsertIgnore``, so this is unreachable there.
    public static var insertIgnoreClause: String { "IGNORE " }
}

// MARK: - Capability protocols
//
// The core bet of the library: dialect capabilities are protocol conformances,
// so `.returning()` on MySQL is a *compile* error rather than a runtime one.
// Drizzle ships three near-duplicate packages to get the same effect.

public protocol SupportsReturning: SQLDialect {}
public protocol SupportsOnConflict: SQLDialect {}
public protocol SupportsOnDuplicateKeyUpdate: SQLDialect {}
public protocol SupportsInsertIgnore: SQLDialect {}
public protocol SupportsDistinctOn: SQLDialect {}
public protocol SupportsLateralJoin: SQLDialect {}
public protocol SupportsFullOuterJoin: SQLDialect {}
public protocol SupportsNullsOrdering: SQLDialect {}

/// `UPDATE … ORDER BY … LIMIT n` and the same on `DELETE`.
///
/// Postgres has no such syntax at all. SQLite has it only when compiled with
/// `SQLITE_ENABLE_UPDATE_DELETE_LIMIT`, which is off in the amalgamation most
/// people link — a capability that depends on how the library was built is not
/// one we can promise, so SQLite is excluded rather than left to fail at runtime.
public protocol SupportsWriteLimit: SQLDialect {}

/// `SELECT … FOR UPDATE` / `FOR SHARE`, and the `NOWAIT` / `SKIP LOCKED`
/// modifiers.
///
/// SQLite has none of it — its locking is whole-database, so there is nothing
/// row-level to ask for. Everyone else does.
public protocol SupportsRowLocking: SQLDialect {}

/// `FOR NO KEY UPDATE` and `FOR KEY SHARE` — Postgres's two weaker lock modes.
public protocol SupportsWeakRowLocking: SupportsRowLocking {}

// MARK: - Dialects

public enum Postgres: SQLDialect, SupportsReturning, SupportsOnConflict, SupportsDistinctOn,
                      SupportsLateralJoin, SupportsFullOuterJoin, SupportsNullsOrdering,
                      SupportsWeakRowLocking {
    public static let dialectName = "postgres"
    public static let identifierQuote: Character = "\""
    @inlinable
    public static func writePlaceholder(index: Int, into sql: inout String) {
        sql.append("$")
        sql.append(String(index + 1))
    }
}

public enum SQLite: SQLDialect, SupportsReturning, SupportsOnConflict, SupportsInsertIgnore,
                    SupportsFullOuterJoin, SupportsNullsOrdering {
    public static let dialectName = "sqlite"
    public static let identifierQuote: Character = "\""
    /// `INSERT OR IGNORE`, not `INSERT IGNORE` — the latter is a syntax error here.
    public static let insertIgnoreClause = "OR IGNORE "
    @inlinable
    public static func writePlaceholder(index: Int, into sql: inout String) {
        sql.append("?")
    }
}

public enum MySQL: SQLDialect, SupportsOnDuplicateKeyUpdate, SupportsInsertIgnore,
                   SupportsLateralJoin, SupportsWriteLimit, SupportsRowLocking {
    public static let dialectName = "mysql"
    public static let identifierQuote: Character = "`"
    @inlinable
    public static func writePlaceholder(index: Int, into sql: inout String) {
        sql.append("?")
    }
}

/// MariaDB diverges from MySQL enough to deserve its own dialect: it has had
/// `INSERT ... RETURNING` since 10.5 and `DELETE ... RETURNING` since 10.0.
public enum MariaDB: SQLDialect, SupportsReturning, SupportsOnDuplicateKeyUpdate,
                     SupportsInsertIgnore, SupportsLateralJoin, SupportsWriteLimit,
                     SupportsRowLocking {
    public static let dialectName = "mariadb"
    public static let identifierQuote: Character = "`"
    @inlinable
    public static func writePlaceholder(index: Int, into sql: inout String) {
        sql.append("?")
    }
}

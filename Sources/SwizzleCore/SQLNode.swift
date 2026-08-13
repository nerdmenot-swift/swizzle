/// Untyped SQL IR.
///
/// Key design point for compile times: the *node tree is fully dynamic*, and all
/// type safety lives in a phantom parameter on `SQLExpression<Value>`. The type
/// checker therefore only ever maps phantom types through operators; it never has
/// to reason about tree structure. This is what keeps deep query chains cheap.
public indirect enum SQLNode: Sendable {
    case column(qualifier: String?, name: String)
    case bind(SQLValue)
    case raw(String)
    case binary(SQLNode, String, SQLNode)
    case prefix(String, SQLNode)
    case postfix(SQLNode, String)
    case function(String, [SQLNode])
    case list([SQLNode])
    case group(SQLNode)
    case aliased(SQLNode, String)
    case star(qualifier: String?)
    case selectSubquery(SQLSelectCore)
    /// A dialect-quoted identifier standing alone, from `\(identifier:)`.
    case identifier(String)
    /// A value written into the SQL text as a quoted literal instead of being
    /// bound, from `\(inline:)`.
    ///
    /// Not the same as `.raw`: the value is still escaped for the dialect, so it
    /// is safe in a way a spliced string is not. It exists because some positions
    /// simply cannot take a parameter — `COLLATE`, several `SET` forms, and parts
    /// of DDL — where the alternative is abandoning the builder entirely.
    case literal(SQLValue)
    /// Parts concatenated with **no** separator — the shape a raw fragment takes.
    /// Literal text arrives as `.raw`, interpolated values as `.bind`, and
    /// interpolated columns as `.column`, so one case covers the whole escape hatch.
    case fragment([SQLNode])
    /// Postgres/SQLite `EXCLUDED."col"` — the proposed row inside `ON CONFLICT`.
    case excluded(String)
    /// MySQL/MariaDB ``VALUES(`col`)`` — the same idea, spelled the way MySQL
    /// spells it. Two cases rather than one because each is only reachable from
    /// the correspondingly capability-gated builder method, which means the
    /// renderer never has to guess which dialect it is serving.
    case valuesOf(String)
}

/// Lives in Core rather than the builder: a table is IR-level structure, and the
/// renderer needs it independently of any typed query surface.
public protocol SQLTable: Sendable {
    static var tableName: String { get }
    static var schemaName: String? { get }
    /// Instance-level alias, so `Users(as: "author")` yields a distinct qualifier.
    var tableAlias: String? { get }
}

extension SQLTable {
    public static var schemaName: String? { nil }
    public var tableAlias: String? { nil }
    public var qualifier: String { tableAlias ?? Self.tableName }
    public var source: SQLSource {
        .table(schema: Self.schemaName, name: Self.tableName, alias: tableAlias)
    }
}

public indirect enum SQLSource: Sendable {
    case table(schema: String?, name: String, alias: String?)
    case subquery(SQLSelectCore, alias: String)
    /// A hand-written source — a table-valued function, `UNNEST(…)`,
    /// `generate_series(…)`, a vendor extension. `FROM` is the one clause a
    /// trailing fragment cannot reach, so it gets its own door.
    case fragment(SQLNode, alias: String?)
}

/// A row-locking clause: `FOR UPDATE`, `FOR SHARE`, and how to behave when the
/// rows are already locked.
public struct SQLLocking: Sendable {
    public enum Strength: String, Sendable {
        case update = "FOR UPDATE"
        case share = "FOR SHARE"
        /// Postgres only — a weaker lock that still blocks deletes.
        case noKeyUpdate = "FOR NO KEY UPDATE"
        /// Postgres only.
        case keyShare = "FOR KEY SHARE"
    }

    /// What to do when a row is already locked.
    public enum Wait: String, Sendable {
        /// Block until the other transaction finishes. The default, and the only
        /// behaviour older servers have.
        case wait = ""
        /// Fail immediately rather than queue.
        case noWait = "NOWAIT"
        /// Skip locked rows entirely — the queue-worker pattern.
        case skipLocked = "SKIP LOCKED"
    }

    public var strength: Strength
    public var wait: Wait

    public init(strength: Strength, wait: Wait = .wait) {
        self.strength = strength
        self.wait = wait
    }
}

public struct SQLJoin: Sendable {
    public enum Kind: String, Sendable {
        case inner = "INNER JOIN"
        case left = "LEFT JOIN"
        case right = "RIGHT JOIN"
        case full = "FULL OUTER JOIN"
        case cross = "CROSS JOIN"
    }
    public var kind: Kind
    public var source: SQLSource
    public var on: SQLNode?
    public var isLateral: Bool

    public init(kind: Kind, source: SQLSource, on: SQLNode?, isLateral: Bool = false) {
        self.kind = kind
        self.source = source
        self.on = on
        self.isLateral = isLateral
    }
}

public struct SQLOrderTerm: Sendable {
    public enum Nulls: Sendable { case first, last }
    public var node: SQLNode
    public var descending: Bool
    public var nulls: Nulls?

    public init(node: SQLNode, descending: Bool = false, nulls: Nulls? = nil) {
        self.node = node
        self.descending = descending
        self.nulls = nulls
    }
}

/// One `SET col = expr` pair.
///
/// The value is a `SQLNode` rather than a `SQLValue` so an assignment can be an
/// *expression* — `views = views + 1`, or `name = EXCLUDED.name`. Restricting it
/// to literals is the limitation that makes people abandon a builder mid-query.
public struct SQLAssignment: Sendable {
    /// Normally a `.column`. Held as a node rather than a name so that an
    /// assignment target written as a raw fragment renders as written instead of
    /// being dropped or crashing — the escape hatch stays open on both sides of
    /// the `=`.
    public var target: SQLNode
    public var value: SQLNode

    public init(target: SQLNode, value: SQLNode) {
        self.target = target
        self.value = value
    }

    public init(column: String, value: SQLNode) {
        self.target = .column(qualifier: nil, name: column)
        self.value = value
    }
}

public struct SQLUpdateCore: Sendable {
    /// Rendered verbatim after every other clause. See `SQLSelectCore.trailing`.
    public var trailing: [SQLNode] = []
    public var schema: String?
    public var table: String
    public var alias: String?
    public var assignments: [SQLAssignment] = []
    public var predicates: [SQLNode] = []
    public var orderBy: [SQLOrderTerm] = []
    public var limit: Int?
    public var returning: [SQLNode] = []

    public init(schema: String? = nil, table: String, alias: String? = nil) {
        self.schema = schema
        self.table = table
        self.alias = alias
    }
}

public struct SQLDeleteCore: Sendable {
    /// Rendered verbatim after every other clause. See `SQLSelectCore.trailing`.
    public var trailing: [SQLNode] = []
    public var schema: String?
    public var table: String
    public var alias: String?
    public var predicates: [SQLNode] = []
    public var orderBy: [SQLOrderTerm] = []
    public var limit: Int?
    public var returning: [SQLNode] = []

    public init(schema: String? = nil, table: String, alias: String? = nil) {
        self.schema = schema
        self.table = table
        self.alias = alias
    }
}

/// One `WITH` binding.
///
/// ## Why the body is boxed
///
/// `SQLSelectCore` holds `[SQLCommonTableExpression]`, and this holds a
/// `SQLSelectCore` — a **recursive value type**. Swift accepts it, because an
/// array is a pointer and the size is finite, and then generates a value witness
/// that is wrong: copying the array crashes in `swift_retain` on a garbage
/// pointer. It compiles clean, passes in isolation, and dies once enough of the
/// type's metadata has been instantiated elsewhere in the process — which is
/// exactly how it showed up here, green in every filtered run and a segfault in
/// the full one.
///
/// The fix is one level of indirection. `SQLNode` is already an `indirect enum`,
/// so the body rides inside a `.selectSubquery` box and the public shape is
/// unchanged. `SQLSource` has always relied on the same trick for subqueries.
public struct SQLCommonTableExpression: Sendable {
    public var name: String
    public var columns: [String]
    /// `WITH RECURSIVE`. A property of the whole `WITH` clause in SQL rather than
    /// of one binding, but tracked per binding so adding a recursive CTE does not
    /// require the caller to also remember to flip a flag on the query.
    public var isRecursive: Bool

    private var boxed: SQLNode

    public var body: SQLSelectCore {
        get {
            guard case .selectSubquery(let core) = boxed else { return SQLSelectCore() }
            return core
        }
        set { boxed = .selectSubquery(newValue) }
    }

    public init(name: String, columns: [String] = [], body: SQLSelectCore, isRecursive: Bool = false) {
        self.name = name
        self.columns = columns
        self.isRecursive = isRecursive
        self.boxed = .selectSubquery(body)
    }
}

/// `UNION`, `INTERSECT`, `EXCEPT` and their `ALL` forms.
///
/// The body is boxed for the same reason as ``SQLCommonTableExpression``.
public struct SQLSetOperation: Sendable {
    public enum Kind: String, Sendable {
        case union = "UNION"
        case unionAll = "UNION ALL"
        case intersect = "INTERSECT"
        case intersectAll = "INTERSECT ALL"
        case except = "EXCEPT"
        case exceptAll = "EXCEPT ALL"
    }

    public var kind: Kind
    private var boxed: SQLNode

    public var body: SQLSelectCore {
        get {
            guard case .selectSubquery(let core) = boxed else { return SQLSelectCore() }
            return core
        }
        set { boxed = .selectSubquery(newValue) }
    }

    public init(kind: Kind, body: SQLSelectCore) {
        self.kind = kind
        self.boxed = .selectSubquery(body)
    }
}

public struct SQLSelectCore: Sendable {
    /// Fragments rendered verbatim after every other clause.
    ///
    /// The guarantee that the builder is never a dead end. Anything SQL can put
    /// at the end of a statement — an index hint, a vendor `OPTION`, a locking
    /// form we have not modelled, a hint comment — goes here without needing the
    /// whole query rewritten as raw text. Bindings inside still bind.
    public var trailing: [SQLNode] = []
    /// `FOR UPDATE` and friends.
    public var locking: SQLLocking?
    public var ctes: [SQLCommonTableExpression] = []
    public var setOperations: [SQLSetOperation] = []
    public var projection: [SQLNode] = []
    public var from: SQLSource?
    public var joins: [SQLJoin] = []
    public var predicates: [SQLNode] = []
    public var groupBy: [SQLNode] = []
    public var having: [SQLNode] = []
    public var orderBy: [SQLOrderTerm] = []
    public var limit: Int?
    public var offset: Int?
    public var isDistinct: Bool = false
    public var distinctOn: [SQLNode] = []

    public init() {}
}

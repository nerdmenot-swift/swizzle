/// What a database says about a statement's shape, without running it.
///
/// The whole of pillar 3 rests on one observation: every engine can describe a
/// prepared statement before it executes. sqlc instead *parses* SQL, which costs a
/// real parser per dialect — `libpg_query` for Postgres, Vitess for MySQL, an
/// ANTLR grammar for SQLite — and that asymmetry is exactly why sqlc's Postgres
/// support is so much better than its other two.
///
/// Asking the database means no parser to write or maintain, correctness by
/// construction, and every type the drivers already understand comes along for
/// free. The price is a live database at generation time, paid on a developer's
/// machine and kept out of CI by the lockfile.
public struct QuerySignature: Sendable, Equatable, Codable {
    /// The name from the query file's `-- +swizzle Query <name>` directive.
    public var name: String
    /// The statement as written, verbatim.
    public var sql: String
    public var cardinality: Cardinality
    public var parameters: [ParameterInfo]
    public var columns: [ColumnInfo]

    /// Whether the statement contains an outer join.
    ///
    /// Recorded rather than applied here, because the engines disagree about
    /// whether it matters — see ``NullabilityReason/outerJoinWidened``.
    public var hasOuterJoin: Bool

    public init(
        name: String, sql: String, cardinality: Cardinality,
        parameters: [ParameterInfo], columns: [ColumnInfo], hasOuterJoin: Bool
    ) {
        self.name = name
        self.sql = sql
        self.cardinality = cardinality
        self.parameters = parameters
        self.columns = columns
        self.hasOuterJoin = hasOuterJoin
    }

    /// How many rows the caller expects, and therefore what the generated
    /// function returns.
    public enum Cardinality: String, Sendable, Codable {
        /// `T?` — or the bare column type when the projection is a single column.
        case one
        /// `[T]`.
        case many
        /// An `AsyncSequence` of `T`.
        ///
        /// No sqlc equivalent. It exists because streaming and fetching are meant
        /// to feel the same here, and a generator that could only materialise
        /// arrays would quietly undo that.
        case stream
        /// `Int` — rows affected.
        case exec
    }
}

/// One `?` / `$1` in the statement.
///
/// ## Why parameters are declared rather than discovered
///
/// This is the half the databases are bad at. MySQL returns placeholder
/// definitions — every parameter typed `VAR_STRING` regardless of use — so only
/// the *arity* is real. SQLite has no concept of a parameter type at all, being
/// dynamically typed. Only Postgres genuinely infers them and sends OIDs.
///
/// So the author declares parameters in the query file, and the engines that can
/// check the declaration do. Deriving what the database knows well and declaring
/// what it does not is more honest than pretending all three are equal.
public struct ParameterInfo: Sendable, Equatable, Codable {
    /// 1-based, matching the placeholder's position.
    public var ordinal: Int
    /// The name from the query file's declaration.
    public var name: String
    /// The engine's own rendering, when it has one — `int8`, `varchar`. Nil where
    /// the engine cannot say, which is MySQL and SQLite.
    public var sqlType: String?
    public var swiftType: SwiftType
    /// Where the type came from, so a mismatch can be reported precisely.
    public var source: Source

    public init(
        ordinal: Int, name: String, sqlType: String?, swiftType: SwiftType, source: Source
    ) {
        self.ordinal = ordinal
        self.name = name
        self.sqlType = sqlType
        self.swiftType = swiftType
        self.source = source
    }

    public enum Source: String, Sendable, Codable {
        /// The engine reported a real type and it agreed with the declaration.
        case verified
        /// Declared by the author; the engine could not check it.
        case declared
        /// Declared by the author and the engine disagreed — a generation error,
        /// carried so the message can name both.
        case conflicted
    }
}

/// One column of the result set.
public struct ColumnInfo: Sendable, Equatable, Codable {
    /// As the result set labels it, alias included.
    public var name: String
    /// The engine's own rendering — `bigint unsigned`, `numeric(10,2)`, `int4`.
    public var sqlType: String
    public var swiftType: SwiftType
    public var isOptional: Bool
    /// **Why** it is or is not optional.
    ///
    /// The reason is carried rather than derived because it is what makes a
    /// `--verify` diff legible: a column going from `String` to `String?` says
    /// nothing, while `baseColumnNotNull` → `outerJoinWidened` names the change
    /// that caused it.
    public var nullability: NullabilityReason
    /// The base table and column this traces back to, when it traces at all.
    /// Nil for expressions, aggregates and literals.
    public var origin: ColumnOrigin?

    public init(
        name: String, sqlType: String, swiftType: SwiftType,
        isOptional: Bool, nullability: NullabilityReason, origin: ColumnOrigin?
    ) {
        self.name = name
        self.sqlType = sqlType
        self.swiftType = swiftType
        self.isOptional = isOptional
        self.nullability = nullability
        self.origin = origin
    }
}

public struct ColumnOrigin: Sendable, Equatable, Codable {
    public var schema: String?
    public var table: String
    public var column: String

    public init(schema: String? = nil, table: String, column: String) {
        self.schema = schema
        self.table = table
        self.column = column
    }
}

/// How a column's optionality was decided.
///
/// Nullability is not equally knowable per engine, and pretending otherwise is how
/// generated code ends up lying:
///
/// - **MySQL** computes `NOT_NULL` for the *projected expression*, so it is
///   correct even through a `LEFT JOIN`. It is trusted directly, and the
///   outer-join widening below is deliberately **not** applied on top — doing so
///   would make the one engine that gets this right the worst of the three.
/// - **SQLite** answers only for columns traceable to a base table, via
///   `origin_name` → `sqlite3_table_column_metadata`.
/// - **Postgres** has no nullability on the wire at all — no client anywhere can
///   get it from a describe — so it comes from a `pg_attribute` lookup, and only
///   for base columns.
///
/// For the latter two, a statement containing an outer join widens everything that
/// would otherwise be non-optional, because knowing *which side* a column sits on
/// requires a parser and pessimism on a few columns is the cheaper failure.
public enum NullabilityReason: String, Sendable, Codable {
    /// The engine reported it for the projected expression. MySQL only.
    case engineFlag
    /// Traced to a base-table column declared `NOT NULL`.
    case baseColumnNotNull
    /// Traced to a base-table column that permits null.
    case baseColumnNullable
    /// Would be non-optional, but the statement has an outer join and this engine
    /// cannot say which side the column came from.
    case outerJoinWidened
    /// An expression, aggregate or literal with no traceable origin.
    case expression
    /// Traceable in principle, but the engine did not report an origin.
    case unknownOrigin
    /// `-- +swizzle NotNull <column>`.
    case annotationNotNull
    /// `-- +swizzle Nullable <column>`.
    case annotationNullable

    /// Whether this reason was chosen because we could not do better.
    ///
    /// Useful for a generation report: a project with many pessimistic columns is
    /// a project that would benefit from annotations.
    public var isPessimistic: Bool {
        switch self {
        case .outerJoinWidened, .expression, .unknownOrigin: true
        case .engineFlag, .baseColumnNotNull, .baseColumnNullable,
             .annotationNotNull, .annotationNullable: false
        }
    }
}

/// The Swift type a column or parameter maps to.
///
/// Deliberately a closed enum rather than a type name string: the emitter has to
/// render it, the lockfile has to round-trip it, and an open string would let an
/// engine invent a type nothing can decode.
public indirect enum SwiftType: Sendable, Equatable, Codable {
    case int64, int32, int16, int8
    case uint64
    case double, float
    case string
    case bytes
    case bool

    /// `DECIMAL` / `NUMERIC`, carried as `String`.
    ///
    /// Never `Double`. An exact numeric routed through binary floating point
    /// loses the cents, which is the whole reason the type exists — the same rule
    /// the hand-written table declarations already document.
    case decimalString

    case date
    case uuid
    case json

    /// Postgres arrays.
    case array(SwiftType)

    /// `SQLValue` — the honest answer when the engine will not say.
    ///
    /// SQLite reaches this for expression columns, where `decltype` returns null
    /// and there is genuinely nothing to report.
    case dynamic

    /// The engine could not type this at all.
    ///
    /// Only parameters reach it: MySQL reports every placeholder as `VAR_STRING`
    /// and SQLite has no parameter types, so the declaration in the query file is
    /// the only source. A signature still carrying `.unresolved` at emission time
    /// is a generation error, not something to render.
    case unresolved
}

/// Describes a statement without running it.
///
/// One implementation per engine, each doing whatever its database supports —
/// `COM_STMT_PREPARE` on MySQL, `sqlite3_prepare_v2` plus the column-metadata
/// calls on SQLite, Parse/Describe/Sync on Postgres. The generator never learns
/// which is which, the same way the migrator never learns which dialect it is
/// running against.
public protocol QueryAnalyzer: Sendable {
    /// Prepares and describes. Must **not** execute: a generator that ran the
    /// statements it was analysing would delete rows to find out what `DELETE`
    /// returns.
    func analyze(_ sql: String) async throws -> QuerySignature

    /// Releases whatever the run accumulated.
    ///
    /// Not optional tidying. MySQL's `prepare` leaves every statement allocated
    /// on the server and inserted into a bounded LRU; analysing a few hundred
    /// queries without this both leaks them and thrashes the cache that the rest
    /// of the connection depends on.
    func finish() async
}

/// A statement could not be described.
public struct QueryAnalysisError: Error, Sendable, CustomStringConvertible {
    public let name: String?
    public let sql: String
    public let reason: String

    public init(name: String? = nil, sql: String, reason: String) {
        self.name = name
        self.sql = sql
        self.reason = reason
    }

    public var description: String {
        let subject = name.map { "query '\($0)'" } ?? "query"
        return "cannot describe \(subject): \(reason)\n\(sql)"
    }
}

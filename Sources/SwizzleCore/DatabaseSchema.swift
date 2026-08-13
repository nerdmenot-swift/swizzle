/// What the database currently looks like.
///
/// Lives here rather than with the migrator because more than one pillar needs
/// it: the linter cannot judge a change without knowing how big a table is, drift
/// detection compares against it, and the planned code generator needs column
/// types and nullability to emit Swift.
public struct DatabaseSchema: Sendable, Equatable {
    public var tables: [TableSchema]

    public init(tables: [TableSchema]) { self.tables = tables }

    public func table(named name: String) -> TableSchema? {
        tables.first { $0.name.lowercased() == name.lowercased() }
    }
}

public struct TableSchema: Sendable, Equatable {
    public init(
        name: String, columns: [ColumnSchema], indexes: [IndexSchema], estimatedRows: Int64
    ) {
        self.name = name
        self.columns = columns
        self.indexes = indexes
        self.estimatedRows = estimatedRows
    }

    public var name: String
    public var columns: [ColumnSchema]
    public var indexes: [IndexSchema]
    /// The optimiser's estimate, not a `COUNT(*)`.
    ///
    /// Deliberately approximate: counting every row of every table to lint a
    /// migration would cost more than the migration. InnoDB's estimate can be
    /// off by a wide margin on a small table and is close enough on a large one
    /// — which is the direction that matters, since the checks care about "is
    /// this big enough to hurt".
    public var estimatedRows: Int64

    public var primaryKey: IndexSchema? { indexes.first { $0.isPrimary } }
    public func column(named name: String) -> ColumnSchema? {
        columns.first { $0.name.lowercased() == name.lowercased() }
    }
}

public struct ColumnSchema: Sendable, Equatable {
    public init(
        name: String, type: String, isNullable: Bool, hasDefault: Bool, isAutoIncrement: Bool
    ) {
        self.name = name
        self.type = type
        self.isNullable = isNullable
        self.hasDefault = hasDefault
        self.isAutoIncrement = isAutoIncrement
    }

    public var name: String
    /// As the server reports it, e.g. `varchar(255)` or `bigint unsigned`.
    public var type: String
    public var isNullable: Bool
    public var hasDefault: Bool
    public var isAutoIncrement: Bool
}

public struct IndexSchema: Sendable, Equatable {
    public init(name: String, columns: [String], isUnique: Bool, isPrimary: Bool) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.isPrimary = isPrimary
    }

    public var name: String
    public var columns: [String]
    public var isUnique: Bool
    public var isPrimary: Bool
}

/// Reads the current schema.
///
/// A protocol so the linter is testable without a database, and so Postgres and
/// SQLite can supply their own once those drivers exist.
public protocol SchemaIntrospector: Sendable {
    func schema() async throws -> DatabaseSchema
}

import SwizzleCore

/// Reads Postgres's `information_schema` and `pg_class`.
///
/// Same three-query shape as the MySQL one — and sequential for the same
/// reason, since this client holds a single connection.
public struct PostgresIntrospector<Executor: SQLExecutor>: SchemaIntrospector {
    let executor: Executor

    public init(executor: Executor) { self.executor = executor }

    public func schema() async throws -> DatabaseSchema {
        let columnRows = try await executor.execute(
            sql: """
                SELECT table_name, column_name, data_type, is_nullable, column_default
                FROM information_schema.columns
                WHERE table_schema = CURRENT_SCHEMA()
                ORDER BY table_name, ordinal_position
                """,
            bindings: []
        )
        let indexRows = try await executor.execute(
            sql: """
                SELECT t.relname, i.relname, a.attname, ix.indisunique, ix.indisprimary
                FROM pg_class t
                JOIN pg_index ix ON t.oid = ix.indrelid
                JOIN pg_class i ON i.oid = ix.indexrelid
                JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(ix.indkey)
                JOIN pg_namespace n ON n.oid = t.relnamespace
                WHERE n.nspname = CURRENT_SCHEMA() AND t.relkind = 'r'
                ORDER BY t.relname, i.relname
                """,
            bindings: []
        )
        // `reltuples` is the planner's estimate, the same trade the MySQL side
        // makes: counting every row of every table to lint a migration would
        // cost more than the migration.
        let tableRows = try await executor.execute(
            sql: """
                SELECT c.relname, c.reltuples::bigint
                FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = CURRENT_SCHEMA() AND c.relkind = 'r'
                """,
            bindings: []
        )

        var columns: [String: [ColumnSchema]] = [:]
        for row in columnRows where row.values.count >= 5 {
            let table = Self.text(row.values[0])
            columns[table, default: []].append(
                ColumnSchema(
                    name: Self.text(row.values[1]),
                    type: Self.text(row.values[2]).lowercased(),
                    isNullable: Self.text(row.values[3]).uppercased() == "YES",
                    hasDefault: !Self.isNull(row.values[4]),
                    // Postgres spells this as a `nextval(...)` default rather
                    // than a column flag.
                    isAutoIncrement: Self.text(row.values[4]).contains("nextval(")
                )
            )
        }

        var indexParts: [String: [String: (columns: [String], unique: Bool, primary: Bool)]] = [:]
        for row in indexRows where row.values.count >= 5 {
            let table = Self.text(row.values[0])
            let index = Self.text(row.values[1])
            var forTable = indexParts[table] ?? [:]
            var entry = forTable[index] ?? ([], false, false)
            entry.columns.append(Self.text(row.values[2]))
            entry.unique = Self.bool(row.values[3])
            entry.primary = Self.bool(row.values[4])
            forTable[index] = entry
            indexParts[table] = forTable
        }

        var estimates: [String: Int64] = [:]
        var names: Set<String> = []
        for row in tableRows where row.values.count >= 2 {
            let table = Self.text(row.values[0])
            names.insert(table)
            estimates[table] = Self.int(row.values[1]) ?? 0
        }

        return DatabaseSchema(tables: names.sorted().map { name in
            TableSchema(
                name: name,
                columns: columns[name] ?? [],
                indexes: (indexParts[name] ?? [:]).map { index, part in
                    IndexSchema(
                        name: index, columns: part.columns,
                        isUnique: part.unique, isPrimary: part.primary
                    )
                }.sorted { $0.name < $1.name },
                estimatedRows: max(0, estimates[name] ?? 0)
            )
        })
    }

    static func text(_ value: SQLValue) -> String {
        switch value {
        case .text(let raw): raw
        case .int(let raw): String(raw)
        case .double(let raw): String(raw)
        case .bool(let raw): String(raw)
        case .blob(let bytes): String(decoding: bytes, as: UTF8.self)
        case .null: ""
        }
    }
    static func int(_ value: SQLValue) -> Int64? {
        switch value {
        case .int(let raw): raw
        case .double(let raw): Int64(raw)
        case .text(let raw): Int64(raw)
        default: nil
        }
    }
    static func bool(_ value: SQLValue) -> Bool {
        switch value {
        case .bool(let raw): raw
        case .int(let raw): raw != 0
        case .text(let raw): raw == "t" || raw.lowercased() == "true"
        default: false
        }
    }
    static func isNull(_ value: SQLValue) -> Bool {
        if case .null = value { return true }
        return false
    }
}

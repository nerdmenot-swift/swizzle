import SwizzleCore

/// Reads MySQL's and MariaDB's `information_schema`.
public struct MySQLIntrospector<Executor: SQLExecutor>: SchemaIntrospector {
    let executor: Executor

    public init(executor: Executor) {
        self.executor = executor
    }

    public func schema() async throws -> DatabaseSchema {
        // Three queries over the whole schema rather than three per table: a
        // hundred tables would otherwise be three hundred round trips, and the
        // linter runs on every CI build.
        //
        // Sequential, not concurrent. `async let` here looked like a free win
        // and is not: a MySQL connection carries exactly one command at a time,
        // so the three collided and the driver rejected them outright — which
        // is the guard working, not a limitation to route around.
        let columnRows = try await executor.execute(
            sql: """
                SELECT table_name, column_name, column_type, is_nullable,
                       column_default, extra
                FROM information_schema.columns
                WHERE table_schema = DATABASE()
                ORDER BY table_name, ordinal_position
                """,
            bindings: []
        )
        let indexRows = try await executor.execute(
            sql: """
                SELECT table_name, index_name, column_name, non_unique
                FROM information_schema.statistics
                WHERE table_schema = DATABASE()
                ORDER BY table_name, index_name, seq_in_index
                """,
            bindings: []
        )
        let tableRows = try await executor.execute(
            sql: """
                SELECT table_name, table_rows
                FROM information_schema.tables
                WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE'
                """,
            bindings: []
        )

        var columns: [String: [ColumnSchema]] = [:]
        for row in columnRows where row.values.count >= 6 {
            let table = Self.text(row.values[0])
            columns[table, default: []].append(
                ColumnSchema(
                    name: Self.text(row.values[1]),
                    type: Self.text(row.values[2]).lowercased(),
                    isNullable: Self.text(row.values[3]).uppercased() == "YES",
                    // A NULL default and a nullable column are different things:
                    // `DEFAULT NULL` on a nullable column reads as no default
                    // here, which is the answer the linter wants anyway.
                    hasDefault: !Self.isNull(row.values[4]),
                    isAutoIncrement: Self.text(row.values[5]).lowercased()
                        .contains("auto_increment")
                )
            )
        }

        // Grouped by index name, because a composite index is several rows.
        var indexParts: [String: [String: (columns: [String], unique: Bool)]] = [:]
        for row in indexRows where row.values.count >= 4 {
            let table = Self.text(row.values[0])
            let index = Self.text(row.values[1])
            let column = Self.text(row.values[2])
            let unique = Self.int(row.values[3]) == 0

            var forTable = indexParts[table] ?? [:]
            var entry = forTable[index] ?? ([], unique)
            entry.columns.append(column)
            entry.unique = unique
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

        let tables = names.sorted().map { name in
            TableSchema(
                name: name,
                columns: columns[name] ?? [],
                indexes: (indexParts[name] ?? [:]).map { index, part in
                    IndexSchema(
                        name: index, columns: part.columns,
                        isUnique: part.unique, isPrimary: index == "PRIMARY"
                    )
                }.sorted { $0.name < $1.name },
                estimatedRows: estimates[name] ?? 0
            )
        }
        return DatabaseSchema(tables: tables)
    }

    static func text(_ value: SQLValue) -> String {
        switch value {
        case .text(let raw): raw
        case .blob(let bytes): String(decoding: bytes, as: UTF8.self)
        case .int(let raw): String(raw)
        case .double(let raw): String(raw)
        case .bool(let raw): String(raw)
        case .null: ""
        }
    }

    static func int(_ value: SQLValue) -> Int64? {
        switch value {
        case .int(let raw): raw
        case .double(let raw): Int64(raw)
        case .text(let raw): Int64(raw)
        case .null, .bool, .blob: nil
        }
    }

    static func isNull(_ value: SQLValue) -> Bool {
        if case .null = value { return true }
        return false
    }
}

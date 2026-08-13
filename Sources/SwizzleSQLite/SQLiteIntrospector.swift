import SwizzleCore

/// Reads the current schema out of SQLite's pragmas.
///
/// The other two engines query `information_schema`, which is ordinary SQL and
/// takes ordinary parameters. SQLite instead exposes pragmas, and the table-valued
/// forms (`pragma_table_info(…)`) are what make them usable from a query at all —
/// the bare `PRAGMA table_info(x)` statement takes its argument as syntax, so it
/// cannot be parameterised and cannot be joined against.
public struct SQLiteIntrospector: SchemaIntrospector {
    let connection: SQLiteConnection

    public init(_ connection: SQLiteConnection) {
        self.connection = connection
    }

    public func schema() async throws -> DatabaseSchema {
        let tableRows = try await connection.query(
            """
            SELECT name FROM sqlite_schema
             WHERE type = 'table'
               AND name NOT LIKE 'sqlite_%'
             ORDER BY name
            """
        )

        var tables: [TableSchema] = []
        for row in tableRows {
            guard case .text(let name) = row.values[0] else { continue }
            tables.append(
                TableSchema(
                    name: name,
                    columns: try await columns(of: name),
                    indexes: try await indexes(of: name),
                    estimatedRows: try await estimatedRows(of: name)
                )
            )
        }
        return DatabaseSchema(tables: tables)
    }

    private func columns(of table: String) async throws -> [ColumnSchema] {
        let rows = try await connection.query(
            """
            SELECT name, type, "notnull", dflt_value, pk
              FROM pragma_table_info(?1)
             ORDER BY cid
            """,
            [.text(table)]
        )

        // SQLite has no per-column autoincrement flag. A single INTEGER PRIMARY
        // KEY *is* the rowid and behaves like one, whether or not AUTOINCREMENT
        // was written — so that is the honest thing to report.
        let integerPrimaryKeys = rows.filter { row in
            row.values.count > 4 && row.values[4].intValue.map { $0 > 0 } == true
                && row.values[1].stringValue?.uppercased() == "INTEGER"
        }
        let soleRowIDKey = integerPrimaryKeys.count == 1 ? integerPrimaryKeys[0].values[0].stringValue : nil

        return rows.compactMap { row in
            guard let name = row.values[0].stringValue else { return nil }
            return ColumnSchema(
                name: name,
                type: row.values[1].stringValue ?? "",
                isNullable: (row.values[2].intValue ?? 0) == 0,
                hasDefault: row.values[3] != .null,
                isAutoIncrement: name == soleRowIDKey
            )
        }
    }

    private func indexes(of table: String) async throws -> [IndexSchema] {
        var result: [IndexSchema] = []

        // The primary key does not appear in `index_list` unless it happens to
        // be backed by one, so it is read from the column pragma instead.
        let keyRows = try await connection.query(
            "SELECT name FROM pragma_table_info(?1) WHERE pk > 0 ORDER BY pk", [.text(table)]
        )
        let keyColumns = keyRows.compactMap { $0.values[0].stringValue }
        if !keyColumns.isEmpty {
            result.append(
                IndexSchema(name: "PRIMARY", columns: keyColumns, isUnique: true, isPrimary: true)
            )
        }

        let indexRows = try await connection.query(
            "SELECT name, \"unique\" FROM pragma_index_list(?1)", [.text(table)]
        )
        for row in indexRows {
            guard let name = row.values[0].stringValue else { continue }
            // Auto-created indexes backing UNIQUE constraints are reported here
            // too; they are real indexes and belong in the schema.
            let columnRows = try await connection.query(
                "SELECT name FROM pragma_index_info(?1) ORDER BY seqno", [.text(name)]
            )
            result.append(
                IndexSchema(
                    name: name,
                    columns: columnRows.compactMap { $0.values[0].stringValue },
                    isUnique: (row.values[1].intValue ?? 0) == 1,
                    isPrimary: false
                )
            )
        }
        return result
    }

    /// SQLite keeps no row-count statistics unless `ANALYZE` has been run, so
    /// this counts.
    ///
    /// Defensible only because it is SQLite: the count is a local B-tree walk
    /// with no network, and the databases involved are the ones small enough to
    /// live in a single file. The lint rules that consume this care about
    /// "is this big enough to hurt", and an exact answer serves that better than
    /// `sqlite_stat1`, which is absent until someone remembers to `ANALYZE`.
    private func estimatedRows(of table: String) async throws -> Int64 {
        let rows = try await connection.query(
            "SELECT COUNT(*) FROM \(SQLite.quotedIdentifier(table))"
        )
        return rows.first?.values.first?.intValue ?? 0
    }
}

extension SQLite {
    /// Quotes an identifier for a position that cannot take a parameter.
    static func quotedIdentifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

extension SQLValue {
    var stringValue: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    var intValue: Int64? {
        switch self {
        case .int(let value): value
        case .bool(let flag): flag ? 1 : 0
        default: nil
        }
    }
}

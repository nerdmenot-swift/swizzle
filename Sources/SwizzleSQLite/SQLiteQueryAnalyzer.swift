import Foundation
import SwizzleCore
import SwizzleMigrate

/// Describes statements against a real SQLite database.
///
/// The cheapest of the three analyzers by a wide margin, because SQLite is
/// in-process: describing a query is a `sqlite3_prepare_v2` and a handful of
/// accessor calls, with no server, no network and no shadow database to
/// provision — an in-memory connection *is* the shadow database. That is why the
/// code generator was built here first: the whole pipeline is unit-testable on
/// every machine.
///
/// What SQLite cannot do is type anything that is not a plain column. `decltype`
/// returns null for every expression, aggregate and literal, so `SELECT COUNT(*)`
/// and `SELECT a || b` are genuinely unknowable and become ``SwiftType/dynamic``.
/// That is not a gap to paper over; it is what a dynamically typed database
/// knows.
public struct SQLiteQueryAnalyzer: QueryAnalyzer {
    let connection: SQLiteConnection

    public init(_ connection: SQLiteConnection) {
        self.connection = connection
    }

    public func analyze(_ sql: String) async throws -> QuerySignature {
        let description: SQLiteStatementDescription
        do {
            description = try await connection.describe(sql)
        } catch let error as SQLiteError {
            throw QueryAnalysisError(sql: sql, reason: error.message)
        }

        // Widening applies to this whole statement, because working out which
        // side of the join a column came from would need a parser.
        let hasOuterJoin = SQLStatementFacts.hasOuterJoin(sql, syntax: .sqlite)

        let parameters = (0..<description.parameterCount).map { index in
            ParameterInfo(
                ordinal: index + 1,
                // Placeholder for the declaration the query file supplies; the
                // generator replaces it. SQLite reports a name only for the
                // `:name` forms, and nothing at all about the type.
                name: description.parameterNames[index] ?? "p\(index + 1)",
                sqlType: nil,
                swiftType: .unresolved,
                source: .declared
            )
        }

        let columns = description.columns.map { column in
            Self.columnInfo(column, hasOuterJoin: hasOuterJoin)
        }

        return QuerySignature(
            name: "", sql: sql, cardinality: .many,
            parameters: parameters, columns: columns, hasOuterJoin: hasOuterJoin
        )
    }

    /// Nothing to release: `describe` finalises its statement before returning,
    /// and SQLite has no server-side state to clean up.
    public func finish() async {}

    static func columnInfo(
        _ column: SQLiteColumnDescription, hasOuterJoin: Bool
    ) -> ColumnInfo {
        guard column.hasOrigin, let table = column.tableName, let origin = column.originName else {
            // An expression, aggregate or literal. SQLite will not say what it
            // is or whether it can be null, and guessing would be a lie.
            return ColumnInfo(
                name: column.name, sqlType: column.declaredType ?? "",
                swiftType: SQLiteTypeMap.swiftType(for: column.declaredType),
                isOptional: true, nullability: .expression, origin: nil
            )
        }

        let reason: NullabilityReason
        let isOptional: Bool
        if !column.isNotNull && !Self.isRowIDAlias(column) {
            reason = .baseColumnNullable
            isOptional = true
        } else if hasOuterJoin {
            reason = .outerJoinWidened
            isOptional = true
        } else {
            reason = .baseColumnNotNull
            isOptional = false
        }

        return ColumnInfo(
            name: column.name,
            sqlType: column.declaredType ?? "",
            swiftType: SQLiteTypeMap.swiftType(for: column.declaredType),
            isOptional: isOptional,
            nullability: reason,
            origin: ColumnOrigin(
                schema: column.databaseName == "main" ? nil : column.databaseName,
                table: table, column: origin
            )
        )
    }
}

extension SQLiteQueryAnalyzer {
    /// Whether this column is the table's rowid under another name.
    ///
    /// `id INTEGER PRIMARY KEY` is not an ordinary column: SQLite makes it an
    /// alias for the rowid, which always has a value. The schema still reports it
    /// as nullable — inserting `NULL` is legal and means "assign one" — so
    /// `table_column_metadata` says `notnull = 0`, truthfully but uselessly.
    ///
    /// Taking that at face value would make every SQLite primary key generate as
    /// `Int64?`, which is precisely the unwrap-everything failure that makes
    /// generated code unpleasant enough to abandon. A rowid alias can never come
    /// back null from a query, so it is reported as non-optional.
    ///
    /// The rule is narrow on purpose: exactly `INTEGER` (not `INT`, not `BIGINT`)
    /// and a primary key, which is precisely SQLite's own condition for the
    /// aliasing to happen at all.
    static func isRowIDAlias(_ column: SQLiteColumnDescription) -> Bool {
        column.isPrimaryKey
            && column.declaredType?.uppercased().trimmingCharacters(in: .whitespaces) == "INTEGER"
    }
}

/// SQLite's declared type → a Swift type.
///
/// SQLite does not have column types; it has **affinities**, and it derives them
/// from the declared type by substring rules rather than by a fixed list — which
/// is why `VARYING CHARACTER(255)` and `NATIVE CHARACTER` both work. Those rules
/// are reproduced here in the order the documentation gives them, because the
/// order is load-bearing: `INT` must be checked before `TEXT`, or `POINT` matches
/// the wrong one.
public enum SQLiteTypeMap {
    public static func swiftType(for declaredType: String?) -> SwiftType {
        // No declared type means an expression column. There is nothing to map.
        guard let declaredType, !declaredType.isEmpty else { return .dynamic }
        let name = declaredType.uppercased()

        // Checked ahead of the affinity rules: an exact numeric must survive as
        // text, and SQLite's own rules would send DECIMAL to REAL, which loses
        // the cents. The same contract the table declarations already document.
        if name.contains("DECIMAL") || name.contains("NUMERIC") { return .decimalString }
        if name.contains("BOOL") { return .bool }
        if name.contains("DATE") || name.contains("TIME") { return .date }
        if name.contains("UUID") { return .uuid }
        if name.contains("JSON") { return .json }

        // The affinity rules proper, in the documented order.
        if name.contains("INT") { return .int64 }
        if name.contains("CHAR") || name.contains("CLOB") || name.contains("TEXT") {
            return .string
        }
        if name.contains("BLOB") { return .bytes }
        if name.contains("REAL") || name.contains("FLOA") || name.contains("DOUB") {
            return .double
        }
        // NUMERIC affinity — anything unrecognised. Kept as text rather than
        // guessed at, for the same reason DECIMAL is.
        return .decimalString
    }
}

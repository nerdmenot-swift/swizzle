import Foundation
import SwizzleCore

/// Describes statements against a real MySQL or MariaDB server.
///
/// ## The engine that answers the hard question properly
///
/// MySQL is alone among the three in computing `NOT_NULL` for the **projected
/// expression** rather than for the underlying column. A `NOT NULL` column
/// reached through a `LEFT JOIN` really can arrive null, and MySQL says so — so
/// the flag is trusted directly and the outer-join widening that SQLite and
/// Postgres need is deliberately *not* applied on top. Applying it would make the
/// one engine that gets this right the worst of the three.
///
/// What MySQL is bad at is parameters: `COM_STMT_PREPARE` returns a definition per
/// placeholder, but every one is typed `VAR_STRING` regardless of use. Only the
/// arity is real, which is why parameters are declared in the query file.
public final class MySQLQueryAnalyzer: QueryAnalyzer, @unchecked Sendable {
    let connection: MySQLConnection
    /// Statements prepared during this run, kept so `finish()` can close them.
    private let prepared = PreparedBox()

    public init(_ connection: MySQLConnection) {
        self.connection = connection
    }

    public func analyze(_ sql: String) async throws -> QuerySignature {
        let statement: MySQLPreparedStatement
        do {
            statement = try await connection.prepare(sql)
        } catch MySQLProtocolError.server(_, _, let message) {
            // The server's own words. Anything else is a driver or connection
            // failure, and its description is the best available.
            throw QueryAnalysisError(sql: sql, reason: message)
        } catch {
            throw QueryAnalysisError(sql: sql, reason: String(describing: error))
        }
        prepared.add(statement)

        let parameters = (0..<statement.parameters.count).map { index in
            ParameterInfo(
                ordinal: index + 1,
                // Replaced by the query file's declaration. MySQL reports every
                // placeholder as VAR_STRING, so there is nothing here worth
                // keeping beyond the count.
                name: "p\(index + 1)",
                sqlType: nil,
                swiftType: .unresolved,
                source: .declared
            )
        }

        let columns = statement.columns.map(Self.columnInfo)

        return QuerySignature(
            name: "", sql: sql, cardinality: .many,
            parameters: parameters, columns: columns,
            // Recorded for the lockfile's benefit, and pointedly unused: the
            // server has already accounted for it.
            hasOuterJoin: false
        )
    }

    /// Closes every statement this run prepared.
    ///
    /// Not tidying. `prepare` leaves each statement allocated **on the server**
    /// and inserted into a bounded LRU, so analysing a few hundred queries both
    /// leaks that many server-side statements and evicts everything the rest of
    /// the connection was relying on. The driver already learned this lesson once
    /// with `Prepared_stmt_count`.
    public func finish() async {
        for statement in prepared.drain() {
            try? await connection.closeStatement(statement)
        }
    }

    static func columnInfo(_ column: MySQLColumnDefinition) -> ColumnInfo {
        let type = MySQLColumnType(rawValueOrUnknown: column.type)
        let isOptional = !column.flags.contains(.notNull)

        // `originalTable` is empty for an expression, aggregate or literal —
        // the same signal SQLite gives through a missing origin name.
        //
        // Testing both fields is defensive rather than load-bearing, and no
        // test kills a mutation of it: probing the fixtures across aliases,
        // literals, aggregates and derived tables found no query where exactly
        // one of the two is empty — the server sets both or neither. Kept
        // because "an origin needs both halves to be usable" is the actual
        // requirement, and relying on them moving together is an assumption
        // about the server rather than about this code.
        let origin = column.originalTable.isEmpty || column.originalName.isEmpty
            ? nil
            : ColumnOrigin(
                schema: column.schema.isEmpty ? nil : column.schema,
                table: column.originalTable, column: column.originalName
            )

        return ColumnInfo(
            name: column.name,
            sqlType: Self.sqlTypeName(type, column: column),
            swiftType: MySQLTypeMap.swiftType(type, column: column),
            isOptional: isOptional,
            // Always `.engineFlag`, because MySQL always has a real answer:
            // unlike the other two it computes NOT NULL for the projected
            // expression, so there is no case where we fall back to tracing an
            // origin or widening for a join.
            nullability: .engineFlag,
            origin: origin
        )
    }

    /// A readable rendering for the lockfile and for `--verify` diffs.
    static func sqlTypeName(_ type: MySQLColumnType, column: MySQLColumnDefinition) -> String {
        var name = "\(type)"
        if column.isUnsigned { name += " unsigned" }
        if column.isBinary, type == .string || type == .varString { name += " binary" }
        return name
    }

    /// Holds statements across `analyze` calls so `finish()` can close them.
    ///
    /// A small lock rather than an actor: `finish()` is the only reader, the
    /// writes are one array append, and making the analyzer an actor would force
    /// every caller into its isolation for no benefit.
    private final class PreparedBox: @unchecked Sendable {
        private let lock = NSLock()
        private var statements: [MySQLPreparedStatement] = []

        func add(_ statement: MySQLPreparedStatement) {
            lock.lock(); defer { lock.unlock() }
            statements.append(statement)
        }

        func drain() -> [MySQLPreparedStatement] {
            lock.lock(); defer { lock.unlock() }
            let all = statements
            statements = []
            return all
        }
    }
}

/// MySQL's column type plus its flags → a Swift type.
///
/// Type alone is not enough, which is the whole reason this takes the definition
/// rather than the type: `LONGLONG` is `Int64` or `UInt64` depending on a flag,
/// and `STRING` is text or bytes depending on the charset. The driver already
/// makes the second distinction when bridging rows and gets it wrong without the
/// metadata; the generator has to make the same call.
public enum MySQLTypeMap {
    public static func swiftType(
        _ type: MySQLColumnType, column: MySQLColumnDefinition
    ) -> SwiftType {
        switch type {
        case .tiny:
            // `TINYINT(1)` is how MySQL spells a boolean, and how every ORM
            // reads one back.
            return column.columnLength == 1 ? .bool : .int16
        case .short, .year: return column.isUnsigned ? .int32 : .int16
        case .int24, .long: return column.isUnsigned ? .int64 : .int32
        case .longlong:
            // An unsigned 64-bit value does not fit `Int64`. The driver already
            // hands the large ones over as text rather than wrapping, and
            // `UInt64` is the type that accepts both halves.
            return column.isUnsigned ? .uint64 : .int64

        // Exact numerics stay text on every engine — routing them through
        // `Double` is how the cents go missing.
        case .decimal, .newdecimal: return .decimalString

        case .float: return .float
        case .double: return .double

        case .date, .datetime, .datetime2, .timestamp, .timestamp2, .time, .time2:
            return .date

        case .json: return .json

        case .bit, .tinyBlob, .mediumBlob, .longBlob, .blob, .geometry, .vector:
            // The blob types carry text when the charset says so — MySQL uses the
            // same type byte for `TEXT` and `BLOB`, and only the charset tells
            // them apart.
            return column.isBinary ? .bytes : .string

        case .varchar, .varString, .string:
            return column.isBinary ? .bytes : .string

        case .enumeration, .set: return .string

        case .null, .newdate, .typedArray, .unknown:
            return .dynamic
        }
    }
}

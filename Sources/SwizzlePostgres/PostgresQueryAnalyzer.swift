import Foundation
import SwizzleCore
import SwizzleMigrate
import SwizzlePostgresDriver

/// Describes statements against a real Postgres server.
///
/// ## The engine that answers the *other* half properly
///
/// Postgres is alone among the three in genuinely typing parameters. MySQL
/// reports every placeholder as `VAR_STRING`, SQLite has no concept of a
/// parameter type at all — Postgres infers them from the statement and sends real
/// OIDs. So parameters here are `verified` rather than merely `declared`, and a
/// query file that declares `id: String` for a `bigint` parameter is a generation
/// error instead of a runtime surprise.
///
/// And it is the worst at the half MySQL gets right. **Nullability is not on the
/// wire.** `RowDescription` has no null flag — not for this driver, not for any
/// client, in any language — so it comes from a `pg_attribute` lookup keyed on the
/// `(table OID, attribute number)` pair the describe *does* carry. That answers
/// for base columns only, which is why a statement containing an outer join
/// widens everything: knowing which side a column sits on needs a parser, and
/// pessimism on a few columns is the cheaper failure.
///
/// This is exactly the file postgres-nio made impossible. `Describe` was
/// unreachable and `ParameterDescription.dataTypes` was discarded outright, so
/// neither half of a signature could be obtained at all.
public final class PostgresQueryAnalyzer: QueryAnalyzer, @unchecked Sendable {
    private let client: PostgresClient
    /// Leased on first use and held until `finish()`, so every describe and every
    /// catalogue lookup in a run sees the same session — and therefore the same
    /// `search_path`, which is what makes an unqualified table name mean one
    /// thing throughout.
    private var borrowed: (connection: PostgresConnection, release: @Sendable (Bool) async -> Void)?
    private var catalogue: CatalogueCache?

    public init(client: PostgresClient) {
        self.client = client
    }

    /// Takes the connection if this is the first call.
    private func session() async throws -> (PostgresConnection, CatalogueCache) {
        if let borrowed, let catalogue { return (borrowed.connection, catalogue) }
        let lease = try await client.leaseConnection()
        let cache = CatalogueCache(connection: lease.connection)
        borrowed = lease
        catalogue = cache
        return (lease.connection, cache)
    }

    public func analyze(_ sql: String) async throws -> QuerySignature {
        let (connection, catalogue) = try await session()

        let description: PostgresStatementDescription
        do {
            description = try await connection.describe(sql)
        } catch let error as PostgresConnectionError {
            // The server's own words, which for a syntax error name the offending
            // token. Anything else is a connection failure.
            if case .server(let message) = error {
                throw QueryAnalysisError(sql: sql, reason: message.message)
            }
            throw QueryAnalysisError(sql: sql, reason: error.description)
        } catch {
            throw QueryAnalysisError(sql: sql, reason: String(describing: error))
        }

        let hasOuterJoin = SQLStatementFacts.hasOuterJoin(sql, syntax: .postgres)

        // Attributes first, because they are what recovers a *domain*.
        //
        // `RowDescription` reports a domain column as its **base** type —
        // domains are transparent to clients, so the wire says `text` where the
        // schema says `postcode`. `pg_attribute.atttypid` is the declared type,
        // and looking it up costs nothing extra since the nullability lookup
        // already goes there.
        try await catalogue.loadAttributes(
            description.columns
                .filter { $0.tableOID != 0 && $0.columnAttributeNumber > 0 }
                .map { (relation: $0.tableOID, attribute: $0.columnAttributeNumber) }
        )

        // One round trip for every type in the statement rather than one per
        // column — including the declared types the attributes just revealed.
        let declaredTypes = description.columns.compactMap {
            catalogue.attribute(
                relation: $0.tableOID, number: $0.columnAttributeNumber
            )?.typeOID
        }
        try await catalogue.loadTypes(
            description.parameterTypes + description.columns.map(\.dataTypeOID) + declaredTypes
        )

        let parameters = description.parameterTypes.enumerated().map { index, oid in
            ParameterInfo(
                ordinal: index + 1,
                // Replaced by the query file's declaration, which supplies the
                // Swift-side name. The *type* here is real, unlike the other two
                // engines, so the declaration gets checked against it.
                name: "p\(index + 1)",
                sqlType: catalogue.name(for: oid),
                swiftType: catalogue.swiftType(for: oid),
                source: .verified
            )
        }

        let columns = description.columns.map {
            Self.columnInfo($0, hasOuterJoin: hasOuterJoin, catalogue: catalogue)
        }

        return QuerySignature(
            name: "", sql: sql, cardinality: .many,
            parameters: parameters, columns: columns, hasOuterJoin: hasOuterJoin
        )
    }

    /// Gives the connection back.
    ///
    /// There is nothing to *deallocate*: the describe uses the **unnamed**
    /// statement, which the server replaces on every use, so unlike MySQL's
    /// `prepare` a three-hundred-query run leaves nothing behind on the server.
    /// The driver declines to cache describes for the same reason. What has to
    /// happen is the borrow ending, or the pool is one connection short forever.
    public func finish() async {
        let lease = borrowed
        borrowed = nil
        catalogue = nil
        await lease?.release(false)
    }

    static func columnInfo(
        _ column: PostgresColumnDescription, hasOuterJoin: Bool, catalogue: CatalogueCache
    ) -> ColumnInfo {
        // A tableOID of zero means the column is an expression, an aggregate or a
        // literal — Postgres has nothing to trace it to, and neither do we.
        guard column.tableOID != 0, column.columnAttributeNumber > 0,
              let attribute = catalogue.attribute(
                  relation: column.tableOID, number: column.columnAttributeNumber
              )
        else {
            return ColumnInfo(
                name: column.name,
                sqlType: catalogue.name(for: column.dataTypeOID),
                swiftType: catalogue.swiftType(for: column.dataTypeOID),
                isOptional: true,
                nullability: column.tableOID == 0 ? .expression : .unknownOrigin,
                origin: nil
            )
        }

        // The *declared* type, which is the domain where there is one. The wire's
        // OID is the base type, so recording it would lose the distinction between
        // a `text` column and a `postcode` column — and a lockfile that cannot see
        // that change cannot report it.
        let typeOID = attribute.typeOID != 0 ? attribute.typeOID : column.dataTypeOID
        let sqlType = catalogue.name(for: typeOID)
        let swiftType = catalogue.swiftType(for: typeOID)

        let reason: NullabilityReason
        let isOptional: Bool
        if !attribute.isNotNull {
            reason = .baseColumnNullable
            isOptional = true
        } else if hasOuterJoin {
            // `pg_attribute` describes the *column*, not the projection. A
            // `NOT NULL` column reached through a `LEFT JOIN` really can arrive
            // null, and unlike MySQL the server does not account for that here.
            reason = .outerJoinWidened
            isOptional = true
        } else {
            reason = .baseColumnNotNull
            isOptional = false
        }

        return ColumnInfo(
            name: column.name, sqlType: sqlType, swiftType: swiftType,
            isOptional: isOptional, nullability: reason,
            origin: ColumnOrigin(
                // `public` is on every default `search_path`, so recording it
                // would put noise in the lockfile that changes nothing.
                schema: attribute.schema == "public" ? nil : attribute.schema,
                table: attribute.table, column: attribute.column
            )
        )
    }
}

/// Batched `pg_type` and `pg_attribute` lookups, cached for the run.
final class CatalogueCache: @unchecked Sendable {

    struct TypeEntry {
        var name: String
        /// `b` base, `d` domain, `e` enum, `c` composite, `r`/`m` range.
        var kind: String
        var baseType: UInt32
    }

    struct AttributeEntry {
        var isNotNull: Bool
        /// The *declared* type, which is the domain where there is one.
        var typeOID: UInt32
        var schema: String
        var table: String
        var column: String
    }

    private let connection: PostgresConnection
    private var types: [UInt32: TypeEntry] = [:]
    private var attributes: [AttributeKey: AttributeEntry] = [:]

    struct AttributeKey: Hashable {
        var relation: UInt32
        var number: Int16
    }

    init(connection: PostgresConnection) {
        self.connection = connection
    }

    // MARK: - Types

    func loadTypes(_ oids: [UInt32]) async throws {
        var wanted = Set(oids.filter { $0 != 0 && types[$0] == nil })
        // Domains point at a base type that may itself be unknown, so this
        // resolves in rounds rather than one pass. Bounded, because each round
        // must produce a *new* oid to continue.
        while !wanted.isEmpty {
            let rows = try await connection.query(
                """
                SELECT oid, typname, typtype, typbasetype
                FROM pg_type WHERE oid = ANY($1::oid[])
                """,
                [.text(oidArray(wanted))]
            ).rows

            var next = Set<UInt32>()
            for row in rows {
                guard case .int(let oid) = row[0], case .text(let name) = row[1] else { continue }
                let kind: String
                if case .text(let value) = row[2] { kind = value } else { kind = "b" }
                var base: UInt32 = 0
                if case .int(let value) = row[3] { base = UInt32(truncatingIfNeeded: value) }

                types[UInt32(truncatingIfNeeded: oid)] = TypeEntry(
                    name: name, kind: kind, baseType: base
                )
                if base != 0, types[base] == nil { next.insert(base) }
            }
            wanted = next
        }
    }

    func name(for oid: UInt32) -> String {
        // The catalogue is authoritative — a user type has no built-in name — but
        // the built-in table answers before any lookup has happened, which keeps
        // the analyzer usable in tests with no server.
        types[oid]?.name ?? PostgresOID(rawValue: oid)?.name ?? "oid\(oid)"
    }

    func swiftType(for oid: UInt32) -> SwiftType {
        if let builtIn = PostgresOID(rawValue: oid) { return builtIn.swiftType }
        guard let entry = types[oid] else { return .dynamic }

        switch entry.kind {
        case "d":
            // A domain is its base type with a constraint bolted on. The
            // constraint is the server's business; the *type* is what the
            // generator has to emit, so it follows the chain.
            return entry.baseType != 0 ? swiftType(for: entry.baseType) : .string
        case "e":
            // An enum arrives as its label. Emitting a Swift enum would be nicer
            // and would also mean the generated code stops compiling whenever
            // somebody adds a value — which is a migration, not a code change.
            return .string
        default:
            return .dynamic
        }
    }

    // MARK: - Attributes

    /// **The lookup that has to exist because the wire has no null flag.**
    ///
    /// `RowDescription` carries the `(table OID, attribute number)` pair and
    /// nothing about nullability — for any client, in any language. So the pair
    /// is resolved against `pg_attribute`, which is what psql, pgAdmin and every
    /// ORM do for the same reason.
    func loadAttributes(_ pairs: [(relation: UInt32, attribute: Int16)]) async throws {
        let missing = pairs.filter {
            attributes[AttributeKey(relation: $0.relation, number: $0.attribute)] == nil
        }
        guard !missing.isEmpty else { return }

        let rows = try await connection.query(
            """
            SELECT a.attrelid, a.attnum, a.attnotnull, c.relname, n.nspname, a.attname, a.atttypid
            FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE a.attrelid = ANY($1::oid[]) AND a.attnum = ANY($2::smallint[])
            """,
            [
                .text(oidArray(Set(missing.map(\.relation)))),
                .text(intArray(Set(missing.map { Int64($0.attribute) }))),
            ]
        ).rows

        // The two `ANY`s are independent, so this matches a few pairs nobody
        // asked about. Harmless — they are keyed by the pair and simply never
        // looked up — and far cheaper than a row-constructor `IN` list that would
        // grow with the query count.
        for row in rows {
            guard case .int(let relation) = row[0], case .int(let number) = row[1],
                  case .text(let table) = row[3], case .text(let schema) = row[4]
            else { continue }
            let isNotNull: Bool
            switch row[2] {
            case .bool(let value): isNotNull = value
            case .text(let value): isNotNull = value == "t" || value == "true"
            default: isNotNull = false
            }

            var typeOID: UInt32 = 0
            if case .int(let value) = row[6] { typeOID = UInt32(truncatingIfNeeded: value) }
            var columnName = ""
            if case .text(let value) = row[5] { columnName = value }

            attributes[
                AttributeKey(
                    relation: UInt32(truncatingIfNeeded: relation),
                    number: Int16(truncatingIfNeeded: number)
                )
            ] = AttributeEntry(
                isNotNull: isNotNull, typeOID: typeOID, schema: schema, table: table,
                // The *base* column name, not the projected one. `SELECT email
                // AS e` describes a column called `e`, and the origin has to say
                // `users.email` or it cannot be traced to anything.
                column: columnName
            )
        }
    }

    func attribute(relation: UInt32, number: Int16) -> AttributeEntry? {
        attributes[AttributeKey(relation: relation, number: number)]
    }

    /// Arrays go over as Postgres's own text form and are cast on arrival.
    ///
    /// Binding an array as text and letting the server parse it means no
    /// per-element round trip and no growing `IN` list — the statement text is
    /// the same whether there is one column or three hundred, so the plan cache
    /// sees one query rather than three hundred.
    private func oidArray(_ values: Set<UInt32>) -> String {
        "{" + values.sorted().map(String.init).joined(separator: ",") + "}"
    }

    private func intArray(_ values: Set<Int64>) -> String {
        "{" + values.sorted().map(String.init).joined(separator: ",") + "}"
    }
}

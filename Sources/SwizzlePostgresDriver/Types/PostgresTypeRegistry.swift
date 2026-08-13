import NIOCore
import NIOConcurrencyHelpers
import SwizzleCore

/// What the catalogue says about a type the built-in table does not cover.
public struct PostgresUserType: Sendable, Equatable {
    /// `b` base · `d` domain · `e` enum · `c` composite · `r`/`m` range
    public enum Kind: String, Sendable {
        case base = "b"
        case domain = "d"
        case `enum` = "e"
        case composite = "c"
        case range = "r"
        case multirange = "m"
        case pseudo = "p"
    }

    public var oid: UInt32
    public var name: String
    public var schema: String
    public var kind: Kind
    /// The element of an array type.
    public var elementOID: UInt32
    /// The subtype of a range.
    public var rangeSubtypeOID: UInt32
    /// The type a domain is built on.
    public var baseOID: UInt32
    /// An enum's labels, in `enumsortorder`.
    public var labels: [String] = []
    /// A composite's fields, in `attnum`.
    public var fields: [(name: String, oid: UInt32)] = []
    /// The relation backing a composite, whose `pg_attribute` rows *are* its
    /// fields. Zero for everything else.
    public var relationOID: UInt32 = 0

    public static func == (lhs: PostgresUserType, rhs: PostgresUserType) -> Bool {
        lhs.oid == rhs.oid && lhs.name == rhs.name && lhs.schema == rhs.schema
            && lhs.kind == rhs.kind && lhs.elementOID == rhs.elementOID
            && lhs.rangeSubtypeOID == rhs.rangeSubtypeOID && lhs.baseOID == rhs.baseOID
            && lhs.labels == rhs.labels
            && lhs.fields.map(\.name) == rhs.fields.map(\.name)
            && lhs.fields.map(\.oid) == rhs.fields.map(\.oid)
    }
}

/// Resolves user-defined type OIDs against the catalogue, and remembers.
///
/// ## Why the driver needs one at all
///
/// The built-in OIDs are fixed and can live in a table. Everything a user
/// creates — an enum, a composite, a domain, a range over them — gets an OID
/// assigned at creation time, **different in every database**. So a driver that
/// only knows built-ins hands back opaque bytes for exactly the types an
/// application defined for itself.
///
/// The analyzer already resolves these for codegen; this is the runtime half, and
/// it is what `tokio-postgres` keeps in its own typeinfo cache.
///
/// ## Why it is worth caching hard
///
/// Resolving costs up to three round trips — the type, then its labels or fields,
/// then a domain's base — and a schema does not change under a live connection in
/// any way that matters. Without the cache a query returning an enum column would
/// pay those round trips **per execution**, which is worse than the opaque bytes
/// it replaces.
public final class PostgresTypeRegistry: Sendable {

    private struct State {
        var types: [UInt32: PostgresUserType] = [:]
        /// OIDs the catalogue had nothing for. Remembered so a genuinely unknown
        /// type is asked about once rather than on every row.
        var absent: Set<UInt32> = []
    }

    private let state = NIOLockedValueBox(State())

    public init() {}

    public func known(_ oid: UInt32) -> PostgresUserType? {
        state.withLockedValue { $0.types[oid] }
    }

    public func removeAll() {
        state.withLockedValue { $0 = State() }
    }

    public var count: Int {
        state.withLockedValue { $0.types.count }
    }

    /// Resolves any OIDs not already known, using `connection` for the lookups.
    ///
    /// Domains and ranges point at other types, so this resolves in rounds until
    /// nothing new is referenced. Bounded, because a round only continues if it
    /// produced an OID nobody had seen.
    public func resolve(_ oids: [UInt32], on connection: PostgresConnection) async throws {
        var wanted = state.withLockedValue { current in
            Set(oids.filter { oid in
                oid != 0 && current.types[oid] == nil && !current.absent.contains(oid)
                    && PostgresOID(rawValue: oid) == nil
            })
        }

        while !wanted.isEmpty {
            let list = "{" + wanted.sorted().map(String.init).joined(separator: ",") + "}"
            let rows = try await connection.query(
                """
                SELECT t.oid, t.typname, t.typtype, t.typelem, t.typbasetype,
                       n.nspname, t.typrelid, COALESCE(r.rngsubtype, 0)
                FROM pg_catalog.pg_type t
                INNER JOIN pg_catalog.pg_namespace n ON t.typnamespace = n.oid
                LEFT OUTER JOIN pg_catalog.pg_range r ON r.rngtypid = t.oid
                WHERE t.oid = ANY($1::oid[])
                """,
                [.text(list)]
            ).rows

            var found: [PostgresUserType] = []
            var next = Set<UInt32>()
            for row in rows {
                guard let type = Self.decodeRow(row) else { continue }
                found.append(type)
                wanted.remove(type.oid)
                for referenced in [type.elementOID, type.baseOID, type.rangeSubtypeOID]
                where referenced != 0 && PostgresOID(rawValue: referenced) == nil {
                    next.insert(referenced)
                }
            }

            // Enum labels and composite fields each need their own query, and only
            // for the types that actually have them.
            for index in found.indices {
                switch found[index].kind {
                case .enum:
                    found[index].labels = try await Self.labels(
                        of: found[index].oid, on: connection
                    )
                case .composite:
                    let fields = try await Self.fields(
                        of: found[index].relationOID, on: connection
                    )
                    found[index].fields = fields
                    for field in fields where PostgresOID(rawValue: field.oid) == nil {
                        next.insert(field.oid)
                    }
                default:
                    break
                }
            }

            let unresolved = wanted
            state.withLockedValue { current in
                for type in found { current.types[type.oid] = type }
                // Anything the catalogue did not answer for does not exist; not
                // recording that would re-ask on every single row.
                current.absent.formUnion(unresolved)
            }

            wanted = state.withLockedValue { current in
                next.filter { current.types[$0] == nil && !current.absent.contains($0) }
            }
        }
    }

    /// Decodes a value whose OID the built-in table does not cover.
    ///
    /// Everything renders to the text Postgres itself prints, which is the same
    /// contract the built-in types keep. An enum *is* its label; a domain is its
    /// base type; a range over a user type is the bounds it spans.
    public func decode(_ bytes: [UInt8], oid: UInt32, format: Int16) -> SQLValue? {
        guard let type = known(oid) else { return nil }

        switch type.kind {
        case .enum:
            // The wire carries the label, so this is just text — and being an
            // enum is what makes that *correct* rather than a fallback.
            return String(bytes: bytes, encoding: .utf8).map { .text($0) }

        case .domain:
            // A domain is its base type with a constraint bolted on. The
            // constraint is the server's business; the representation is the
            // base type's.
            guard type.baseOID != 0 else { return nil }
            if PostgresOID(rawValue: type.baseOID) != nil {
                return PostgresValueDecoder.decode(bytes, oid: type.baseOID, format: format)
            }
            return decode(bytes, oid: type.baseOID, format: format)

        case .range, .multirange:
            guard format == 1 else {
                return String(bytes: bytes, encoding: .utf8).map { .text($0) }
            }
            var buffer = ByteBuffer(bytes: bytes)
            return PostgresExtendedTypes.decodeRange(
                &buffer, elementOID: type.rangeSubtypeOID
            )

        case .composite:
            guard format == 1 else {
                return String(bytes: bytes, encoding: .utf8).map { .text($0) }
            }
            var buffer = ByteBuffer(bytes: bytes)
            return decodeComposite(&buffer)

        case .base, .pseudo:
            // A user-defined base type — a PostGIS geometry, say. Its binary form
            // is its own business, so text if it reads as text and bytes if not,
            // which is what an unknown OID already did.
            return String(bytes: bytes, encoding: .utf8).map { .text($0) } ?? .blob(bytes)
        }
    }

    /// A composite's binary form: a field count, then each field as its **own**
    /// OID plus a length-prefixed value.
    ///
    /// The per-field OID is on the wire, so a composite decodes without consulting
    /// `pg_attribute` again — the field *names* need the catalogue, the values do
    /// not.
    func decodeComposite(_ buffer: inout ByteBuffer) -> SQLValue? {
        guard let count: Int32 = buffer.readInteger(), count >= 0 else { return nil }
        var parts: [String] = []
        parts.reserveCapacity(Int(count))

        for _ in 0..<count {
            guard let fieldOID: UInt32 = buffer.readInteger(),
                  let length: Int32 = buffer.readInteger()
            else { return nil }
            if length < 0 {
                parts.append("")
                continue
            }
            guard let field = buffer.readBytes(length: Int(length)) else { return nil }
            let value = PostgresOID(rawValue: fieldOID) != nil
                ? PostgresValueDecoder.decode(field, oid: fieldOID, format: 1)
                : (decode(field, oid: fieldOID, format: 1) ?? .blob(field))
            parts.append(PostgresCompositeLiteral.quote(PostgresArray.plainText(value)))
        }
        return .text("(" + parts.joined(separator: ",") + ")")
    }

    static func labels(of oid: UInt32, on connection: PostgresConnection) async throws -> [String] {
        let rows = try await connection.query(
            """
            SELECT enumlabel FROM pg_catalog.pg_enum
            WHERE enumtypid = $1::oid ORDER BY enumsortorder
            """,
            [.int(Int64(oid))]
        ).rows
        return rows.compactMap { row in
            if case .text(let label) = row[0] { return label }
            return nil
        }
    }

    static func fields(
        of relationOID: UInt32, on connection: PostgresConnection
    ) async throws -> [(name: String, oid: UInt32)] {
        guard relationOID != 0 else { return [] }
        let rows = try await connection.query(
            """
            SELECT attname, atttypid FROM pg_catalog.pg_attribute
            WHERE attrelid = $1::oid AND NOT attisdropped AND attnum > 0
            ORDER BY attnum
            """,
            [.int(Int64(relationOID))]
        ).rows
        return rows.compactMap { row in
            guard case .text(let name) = row[0], case .int(let oid) = row[1] else { return nil }
            return (name, UInt32(truncatingIfNeeded: oid))
        }
    }

    static func decodeRow(_ row: [SQLValue]) -> PostgresUserType? {
        func oid(_ index: Int) -> UInt32 {
            if case .int(let value) = row[index] { return UInt32(truncatingIfNeeded: value) }
            return 0
        }
        func text(_ index: Int) -> String {
            if case .text(let value) = row[index] { return value }
            return ""
        }
        guard case .int = row[0] else { return nil }

        var type = PostgresUserType(
            oid: oid(0), name: text(1),
            schema: text(5),
            kind: PostgresUserType.Kind(rawValue: text(2)) ?? .base,
            elementOID: oid(3), rangeSubtypeOID: oid(7), baseOID: oid(4)
        )
        type.relationOID = oid(6)
        return type
    }
}


/// The quoting rules for a composite's text form.
///
/// Postgres prints a composite as `(a,b,c)` and quotes a field only when it has
/// to. The rules differ from an array's: a `,` `(` `)` `"` `\` or whitespace
/// forces quotes, and an *empty* field means NULL rather than the empty string —
/// which is the opposite of an array, where the empty string is quoted and NULL
/// is the bare word.
enum PostgresCompositeLiteral {
    static func quote(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let needsQuotes = text.contains { "(),\"\\ \t\n\r".contains($0) }
        guard needsQuotes else { return text }
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

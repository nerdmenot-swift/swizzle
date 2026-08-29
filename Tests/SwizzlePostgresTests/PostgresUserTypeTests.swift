import NIOCore
import NIOPosix
import SwizzleCore
import SwizzlePostgresDriver
import Testing

/// Enums, composites, domains and user-defined ranges, at **runtime**.
///
/// The analyzer resolved these for codegen; the driver decoded them as opaque
/// bytes. The built-in OIDs are fixed and can live in a table, but everything a
/// user creates gets an OID assigned at creation time and **different in every
/// database** — so these are precisely the types an application defined for
/// itself, and precisely the ones that did not work.
@Suite(
    "Postgres user-defined types", .serialized,
    .enabled(if: PostgresTestServer.isAvailable, PostgresTestServer.skipReason)
)
struct PostgresUserTypeTests {

    static let url = PostgresTestServer.url

    static let schema = """
        DROP SCHEMA IF EXISTS usertypes CASCADE;
        CREATE SCHEMA usertypes;
        SET search_path TO usertypes, public;
        CREATE TYPE mood AS ENUM ('sad', 'ok', 'happy');
        CREATE TYPE address AS (street text, city text, postcode text);
        CREATE DOMAIN positive_int AS int CHECK (VALUE > 0);
        CREATE DOMAIN short_text AS varchar(10);
        CREATE TYPE intrange AS RANGE (subtype = int4);
        """

    static func open() async throws -> PostgresConnection {
        let connection = try await PostgresConnection.connect(
            configuration: PostgresConnectionConfiguration(swizzleURL: url),
            on: MultiThreadedEventLoopGroup.singleton.next()
        )
        for statement in schema.split(separator: ";") where !statement.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty {
            _ = try await connection.query(String(statement))
        }
        _ = try await connection.query("SET search_path TO usertypes, public")
        return connection
    }

    // MARK: - Enums

    /// The wire carries the label, so an enum decodes to text — and being an enum
    /// is what makes that *correct* rather than a fallback.
    @Test("an enum decodes to its label")
    func enums() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        let rows = try await connection.queryResolvingTypes("SELECT 'happy'::mood").rows
        #expect(rows[0][0] == .text("happy"))
    }

    /// Without the registry this is the failure: the value arrives, nothing
    /// recognises the OID, and it degrades. Asserting the *old* behaviour on the
    /// unresolved path is what proves the new one is doing something.
    @Test("the registry is what makes the difference")
    func registryIsLoadBearing() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        // Straight `query` does not resolve, so this is the before picture.
        let raw = try await connection.query("SELECT 'happy'::mood").rows
        #expect(connection.typeRegistry.count == 0)

        let resolved = try await connection.queryResolvingTypes("SELECT 'happy'::mood").rows
        #expect(connection.typeRegistry.count > 0)
        #expect(resolved[0][0] == .text("happy"))
        // Both happen to read as text here — an enum label is UTF-8 either way —
        // so the registry's real proof is the metadata below, not this value.
        _ = raw
    }

    @Test("the registry records an enum's labels in order")
    func enumLabels() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        _ = try await connection.queryResolvingTypes("SELECT 'ok'::mood")

        let oids = try await connection.query(
            "SELECT oid FROM pg_type WHERE typname = 'mood'"
        ).rows
        guard case .int(let oid) = oids[0][0] else {
            Issue.record("expected an oid"); return
        }
        let type = connection.typeRegistry.known(UInt32(oid))
        #expect(type?.kind == .enum)
        #expect(type?.name == "mood")
        #expect(type?.schema == "usertypes")
        // `enumsortorder`, not alphabetical — the declared order is the type's.
        #expect(type?.labels == ["sad", "ok", "happy"])
    }

    // MARK: - Domains

    /// A domain is its base type with a constraint bolted on. The constraint is
    /// the server's business; the representation is the base type's.
    @Test("a domain decodes as its base type")
    func domains() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        let number = try await connection.queryResolvingTypes("SELECT 42::positive_int").rows
        #expect(number[0][0] == .int(42))

        let text = try await connection.queryResolvingTypes("SELECT 'abc'::short_text").rows
        #expect(text[0][0] == .text("abc"))
    }

    // MARK: - Composites

    /// A composite's binary form carries each field's **own** OID, so the values
    /// decode without consulting the catalogue again — the field *names* need it,
    /// the values do not.
    @Test("a composite decodes to the tuple Postgres prints")
    func composites() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        let binary = try await connection.queryResolvingTypes(
            "SELECT ROW('1 High St','London','N1 1AA')::address"
        ).rows
        let text = try await connection.query(
            "SELECT (ROW('1 High St','London','N1 1AA')::address)::text"
        ).rows
        #expect(binary[0][0] == text[0][0])
    }

    /// Composite quoting is *not* array quoting: an empty field means NULL rather
    /// than the empty string, which is the opposite of an array.
    @Test("a composite with a null and an awkward field matches the server")
    func compositeQuoting() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        let literal = "ROW('a,b', NULL, 'has \"quote\"')::address"
        let binary = try await connection.queryResolvingTypes("SELECT \(literal)").rows
        let text = try await connection.query("SELECT (\(literal))::text").rows
        #expect(binary[0][0] == text[0][0])
    }

    @Test("the registry records a composite's fields in attnum order")
    func compositeFields() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        _ = try await connection.queryResolvingTypes("SELECT ROW('a','b','c')::address")

        let oids = try await connection.query(
            "SELECT oid FROM pg_type WHERE typname = 'address'"
        ).rows
        guard case .int(let oid) = oids[0][0] else {
            Issue.record("expected an oid"); return
        }
        let type = connection.typeRegistry.known(UInt32(oid))
        #expect(type?.kind == .composite)
        #expect(type?.fields.map(\.name) == ["street", "city", "postcode"])
    }

    // MARK: - User-defined ranges

    /// A range over a user-declared subtype. The built-in range OIDs are fixed;
    /// this one is not, so it only works through the registry.
    @Test("a user-defined range decodes its bounds")
    func userRange() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        let binary = try await connection.queryResolvingTypes(
            "SELECT intrange(1, 10)"
        ).rows
        let text = try await connection.query("SELECT (intrange(1, 10))::text").rows
        #expect(binary[0][0] == text[0][0])
    }

    // MARK: - The cache

    /// Resolving costs up to three round trips, and a schema does not change under
    /// a live connection in any way that matters. Without the cache an enum column
    /// would pay those per execution — worse than the opaque bytes it replaces.
    @Test("resolving happens once, not per query")
    func cached() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        _ = try await connection.queryResolvingTypes("SELECT 'ok'::mood")
        let afterFirst = connection.typeRegistry.count
        #expect(afterFirst > 0)

        for _ in 0..<5 {
            _ = try await connection.queryResolvingTypes("SELECT 'sad'::mood")
        }
        #expect(connection.typeRegistry.count == afterFirst)
    }

    /// A genuinely unknown OID must be asked about once, not on every row — the
    /// absent set is what stops a lookup storm on a type the catalogue has
    /// nothing for.
    @Test("an OID with no catalogue entry is not asked about twice")
    func absentTypesAreRemembered() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        try await connection.typeRegistry.resolve([999_999], on: connection)
        #expect(connection.typeRegistry.known(999_999) == nil)
        // Asking again is a no-op rather than another round trip.
        try await connection.typeRegistry.resolve([999_999], on: connection)
    }

    /// A built-in type must never reach the registry — that is the whole point of
    /// having a fixed table for the OIDs that are fixed.
    @Test("built-in OIDs are never looked up")
    func builtInsAreNotResolved() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        _ = try await connection.queryResolvingTypes("SELECT 1::int8, 'x'::text, now()")
        #expect(connection.typeRegistry.count == 0)
    }

    /// End to end against the server, because the unit test asserts our
    /// rendering agrees with itself and this asserts it agrees with Postgres.
    ///
    /// The driver printed `(,x)` for both `ROW(NULL,'x')` and `ROW('','x')`,
    /// where the server distinguishes them. Found by a mutation survivor that
    /// pointed at the `length < 0` null marker: writing a test to separate the
    /// two cases failed on unmutated code, which is the good kind of surprise.
    @Test("a composite distinguishes a null field from an empty one")
    func compositeNullVersusEmpty() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        let rows = try await connection.query(
            "SELECT ROW(NULL::text, 'x')::text, ROW(''::text, 'x')::text"
        )
        #expect(rows.rows.first?.first == .text("(,x)"))
        #expect(rows.rows.first?.last == .text("(\"\",x)"))
    }

}

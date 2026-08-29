import Testing
@testable import SwizzlePostgresDriver

/// The session settings a connection reports, and what they default to.
///
/// The mutation sweep flagged `standard_conforming_strings` — flipping its `!=`
/// to `==` inverts the answer and nothing noticed, because nothing referenced
/// the property at all. `integer_datetimes` sits next to it with the same shape
/// and the same absence of coverage, so both are here.
///
/// These read as trivia and are not. `standardConformingStrings` decides whether
/// a backslash inside a string literal escapes, which is the difference between
/// `'a\'b'` being one string and being a syntax error — and getting it backwards
/// is the shape of an escaping bug rather than a crash. `hasIntegerDatetimes`
/// decides whether temporals arrive as 64-bit microseconds or as floating point,
/// so inverting it mis-decodes every timestamp on the connection.
///
/// The **default matters as much as the value**. Both are `!= "off"` rather than
/// `== "on"`, so a server that does not send the parameter at all is treated as
/// having it enabled — which is right, because every server since 9.1 has
/// `standard_conforming_strings` on and cannot be built without integer
/// datetimes. `== "on"` would look equivalent and quietly invert the default for
/// any server that stays silent.
@Suite("Postgres connection metadata")
struct ConnectionMetadataTests {

    static func metadata(_ parameters: [String: String]) -> PostgresConnectionMetadata {
        PostgresConnectionMetadata(
            parameters: parameters,
            backendKey: nil,
            transactionStatus: .idle,
            isTLSActive: false,
            saslMechanism: nil
        )
    }

    // MARK: - standard_conforming_strings

    @Test("standard-conforming strings are on unless the server says off")
    func standardConformingStrings() {
        #expect(Self.metadata(["standard_conforming_strings": "on"]).standardConformingStrings)
        #expect(!Self.metadata(["standard_conforming_strings": "off"]).standardConformingStrings)
    }

    /// The silent case, which is the one `!= "off"` exists for. A server that
    /// never sends the parameter must be read as conforming, not as escaping.
    @Test("a server that does not report it is treated as conforming")
    func standardConformingStringsDefault() {
        #expect(Self.metadata([:]).standardConformingStrings)
        #expect(Self.metadata(["server_version": "16.15"]).standardConformingStrings)
    }

    // MARK: - integer_datetimes

    @Test("integer datetimes are on unless the server says off")
    func integerDatetimes() {
        #expect(Self.metadata(["integer_datetimes": "on"]).hasIntegerDatetimes)
        #expect(!Self.metadata(["integer_datetimes": "off"]).hasIntegerDatetimes)
        #expect(Self.metadata([:]).hasIntegerDatetimes)
    }

    // MARK: - server_version

    /// Optional rather than defaulted: there is no sensible version to invent for
    /// a server that did not say, and guessing one would be worse than `nil`.
    @Test("the server version is reported when present and nil when not")
    func serverVersion() {
        #expect(Self.metadata(["server_version": "16.15"]).serverVersion == "16.15")
        #expect(Self.metadata([:]).serverVersion == nil)
    }

    /// Which OIDs get sent to the catalog, which is a performance property and
    /// therefore one no result-checking test can see.
    ///
    /// The sweep relaxed the `&&` in this predicate to `||` and nothing failed:
    /// every row still decoded correctly, and the driver had quietly started
    /// asking the server about `int8` on every query. Same class as the
    /// quadratic decode this driver carried for months — right answers, paid for
    /// twice.
    @Test("a built-in OID is never sent for resolution")
    func builtInsAreNeverUnresolved() {
        // Nothing is in the registry, which is the state that makes `||` and
        // `&&` differ: with `||`, every one of these becomes "unresolved".
        let builtIns = [PostgresOID.int8, .text, .bool, .timestamptz].map(\.rawValue)
        #expect(PostgresConnection.unresolvedOIDs(builtIns, known: { _ in false }).isEmpty)
    }

    /// The other half: an OID the driver does not recognise and the registry has
    /// not learned is exactly what the round trip is for.
    @Test("an unknown OID is reported once and only while it stays unknown")
    func unknownOIDsAreResolvedOnce() {
        let custom: UInt32 = 99_999
        #expect(PostgresConnection.unresolvedOIDs([custom], known: { _ in false }) == [custom])
        // Once the registry has learned it, it must not be asked for again.
        #expect(PostgresConnection.unresolvedOIDs([custom], known: { $0 == custom }).isEmpty)
    }

    /// A mixed projection asks about the custom column and nothing else.
    @Test("only the unknown columns of a mixed row are resolved")
    func mixedProjection() {
        let oids = [PostgresOID.int8.rawValue, 99_999, PostgresOID.text.rawValue]
        #expect(PostgresConnection.unresolvedOIDs(oids, known: { _ in false }) == [99_999])
    }

}

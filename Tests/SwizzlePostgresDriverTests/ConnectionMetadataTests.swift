import NIOCore
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


    // MARK: - Composite decoding

    /// A composite's binary form is a field count, then each field as its own OID
    /// and a length-prefixed value. The sweep found every bound in it unguarded,
    /// because composites are only ever tested by round-tripping one through a
    /// real server.
    ///
    /// `decodeComposite` is reachable for any user-defined composite type, and a
    /// length taken from the wire is the classic place to read past a buffer. The
    /// `length < 0` branch is not an error path either — **negative means SQL
    /// NULL** here, which is the same convention the row decoder uses, so
    /// inverting it turns every null field into a failed decode and every real
    /// field into an empty one.
    @Test("a composite with no fields decodes to the empty tuple")
    func emptyComposite() {
        let registry = PostgresTypeRegistry()
        var buffer = ByteBuffer(bytes: Self.int32(0))
        #expect(registry.decodeComposite(&buffer) == .text("()"))
    }

    /// A negative count is not a field count.
    @Test("a composite with a negative field count is refused")
    func negativeCompositeCount() {
        let registry = PostgresTypeRegistry()
        var buffer = ByteBuffer(bytes: Self.int32(-1))
        #expect(registry.decodeComposite(&buffer) == nil)
    }

    /// `-1` as a field length is SQL NULL, which renders as nothing between the
    /// commas — `(1,,3)` — exactly as Postgres prints it.
    @Test("a null field renders as an empty slot, not a failure")
    func nullFieldInComposite() {
        let registry = PostgresTypeRegistry()
        var bytes = Self.int32(2)
        bytes += Self.uint32(23)             // int4
        bytes += Self.int32(-1)              // NULL
        bytes += Self.uint32(23)
        bytes += Self.int32(4)
        bytes += Self.int32(7)
        var buffer = ByteBuffer(bytes: bytes)
        #expect(registry.decodeComposite(&buffer) == .text("(,7)"))
    }

    /// A field that claims more bytes than the buffer holds must fail rather
    /// than read past it.
    @Test("a field longer than the buffer is refused")
    func truncatedCompositeField() {
        let registry = PostgresTypeRegistry()
        var bytes = Self.int32(1)
        bytes += Self.uint32(23)
        bytes += Self.int32(64)              // claims 64 bytes
        bytes += [0x01]                      // supplies one
        var buffer = ByteBuffer(bytes: bytes)
        #expect(registry.decodeComposite(&buffer) == nil)
    }

    /// A count that promises more fields than the buffer describes.
    @Test("a composite claiming more fields than it carries is refused")
    func compositeWithMissingFields() {
        let registry = PostgresTypeRegistry()
        var bytes = Self.int32(3)
        bytes += Self.uint32(23)
        bytes += Self.int32(4)
        bytes += Self.int32(1)
        var buffer = ByteBuffer(bytes: bytes)
        #expect(registry.decodeComposite(&buffer) == nil)
    }

    /// Every truncation of a valid composite, for the same reason the array
    /// scanner gets one: no prefix may crash.
    @Test("no prefix of a valid composite crashes the decoder")
    func everyCompositeTruncationIsSafe() {
        var bytes = Self.int32(2)
        bytes += Self.uint32(23); bytes += Self.int32(4); bytes += Self.int32(1)
        bytes += Self.uint32(25); bytes += Self.int32(3); bytes += Array("abc".utf8)

        let registry = PostgresTypeRegistry()
        for length in 0...bytes.count {
            var buffer = ByteBuffer(bytes: Array(bytes.prefix(length)))
            _ = registry.decodeComposite(&buffer)
        }
    }

    static func int32(_ value: Int32) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }

    static func uint32(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }


    /// An **empty** field is not a null field, and the two must not render the
    /// same. `-1` is SQL NULL; `0` is a value that happens to have no bytes.
    ///
    /// The null test above does not separate them — both comparisons treat a
    /// negative length as null, so the mutant relaxing `length < 0` to `<= 0`
    /// lived through it. Postgres prints the difference, `(,x)` against `("",x)`,
    /// and a client that collapses them loses the distinction between "this
    /// field has no value" and "this field is the empty string".
    @Test("an empty field is distinct from a null field")
    func emptyFieldIsNotNull() {
        let registry = PostgresTypeRegistry()

        var withNull = Self.int32(1)
        withNull += Self.uint32(25)
        withNull += Self.int32(-1)
        var nullBuffer = ByteBuffer(bytes: withNull)
        let nullRendering = registry.decodeComposite(&nullBuffer)

        var withEmpty = Self.int32(1)
        withEmpty += Self.uint32(25)
        withEmpty += Self.int32(0)
        var emptyBuffer = ByteBuffer(bytes: withEmpty)
        let emptyRendering = registry.decodeComposite(&emptyBuffer)

        #expect(nullRendering != nil)
        #expect(emptyRendering != nil)
        #expect(
            nullRendering != emptyRendering,
            "a null and an empty field both rendered as \(nullRendering as Any)"
        )
    }

}

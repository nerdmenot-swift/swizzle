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
}

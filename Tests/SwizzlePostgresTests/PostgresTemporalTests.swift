import NIOCore
import NIOPosix
import SwizzleCore
import SwizzlePostgresDriver
import Testing

/// Temporals, where the *session* decides what the text format looks like.
@Suite(
    "Postgres temporals and DateStyle", .serialized,
    .enabled(if: PostgresTestServer.isAvailable, PostgresTestServer.skipReason)
)
struct PostgresTemporalTests {

    static let url = PostgresTestServer.url

    static func open(
        parameters: [String: String] = [:]
    ) async throws -> PostgresConnection {
        var configuration = try PostgresConnectionConfiguration(swizzleURL: url)
        configuration.parameters = parameters
        return try await PostgresConnection.connect(
            configuration: configuration, on: MultiThreadedEventLoopGroup.singleton.next()
        )
    }

    func agree(
        _ connection: PostgresConnection, _ expression: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let rows = try await connection.query(
            "SELECT (\(expression))::text, \(expression)"
        ).rows
        #expect(
            rows[0][0] == rows[0][1],
            "\(expression): server \(rows[0][0]), driver \(rows[0][1])",
            sourceLocation: sourceLocation
        )
    }

    // MARK: - DateStyle

    /// **The driver asks for ISO, and this is why.**
    ///
    /// `DateStyle` changes the *text* rendering of every date and timestamp and
    /// the binary rendering not at all, so on a non-ISO setting the same column
    /// decodes to a different string depending on whether the query had
    /// parameters. Measured on the fixture, one timestamp renders four ways:
    /// `2024-03-05 14:30:00`, `03/05/2024 14:30:00`, `05.03.2024 14:30:00`,
    /// `Tue 05 Mar 14:30:00 2024`.
    @Test("the connection requests ISO dates")
    func requestsISO() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        let style = connection.metadata.parameters["DateStyle"] ?? ""
        #expect(style.hasPrefix("ISO"), "DateStyle was \(style)")
    }

    /// And with ISO in force, the two wire formats agree — which is the contract
    /// every other type in the driver keeps.
    @Test("binary and text temporals agree under ISO")
    func formatsAgree() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        for expression in [
            "'2024-03-05 14:30:00'::timestamp",
            "'2024-03-05'::date",
            "'2024-12-31 23:59:59.123456'::timestamp",
            "'1999-01-01 00:00:00'::timestamp",
        ] {
            try await agree(connection, expression)
        }
    }

    /// A caller who genuinely wants another style can have it, and the driver
    /// stays out of the way rather than overriding them.
    @Test("an explicit DateStyle is honoured")
    func explicitDateStyleWins() async throws {
        let connection = try await Self.open(parameters: ["DateStyle": "SQL, MDY"])
        defer { connection.closeImmediately() }

        let style = connection.metadata.parameters["DateStyle"] ?? ""
        #expect(style.hasPrefix("SQL"), "DateStyle was \(style)")

        // And the divergence is then real and expected. It takes a *bound*
        // parameter to see it: without one the query goes down the simple
        // protocol, which is text on both sides and agrees with itself.
        let text = try await connection.query("SELECT '2024-03-05'::date").rows
        #expect(text[0][0] == .text("03/05/2024"))

        let binary = try await connection.query(
            "SELECT $1::date", [.text("2024-03-05")]
        ).rows
        #expect(binary[0][0] == .text("2024-03-05"))
    }

    // MARK: - interval

    /// Three fields — microseconds, days, months — because Postgres refuses to
    /// pretend a month is a fixed number of days. It used to arrive as a blob.
    @Test("interval decodes in the server's own style")
    func intervals() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        for literal in [
            "1 year 2 mons 3 days 04:05:06",
            "1 day",
            "2 days",
            "1 mon",
            "3 mons",
            "1 year",
            "2 years",
            "04:05:06",
            "00:00:00",
            "1.5 hours",
            "-1 day -04:05:06",
            "-04:05:06",
            "1 year 6 mons",
            "00:00:00.123456",
            "00:00:00.5",
            "100 years",
        ] {
            try await agree(connection, "'\(literal)'::interval")
        }
    }

    /// The pluralisation is Postgres's own and is not regular — `mon` is
    /// abbreviated where `year` and `day` are not — so it is copied rather than
    /// derived.
    @Test("interval pluralisation matches exactly")
    func intervalPluralisation() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        for months in [1, 2, 11, 12, 13, 24, 25] {
            try await agree(connection, "'\(months) mons'::interval")
        }
        for days in [1, 2, 30, 400] {
            try await agree(connection, "'\(days) days'::interval")
        }
    }

    // MARK: - integer_datetimes

    /// Eight bytes either way, so nothing but the session's own
    /// `integer_datetimes` distinguishes microsecond integers from `float8`
    /// seconds — and reading one as the other gives a date around the year six
    /// million rather than an error.
    ///
    /// Every server since 10 has it on and cannot turn it off, so this asserts
    /// the flag is *read* rather than assumed.
    @Test("integer_datetimes is read from the session")
    func integerDatetimes() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        #expect(connection.metadata.hasIntegerDatetimes)
        #expect(connection.metadata.parameters["integer_datetimes"] == "on")
    }

    /// The float path is unreachable on any supported server, so it is checked at
    /// the decoder instead — otherwise it would be code nobody has ever run.
    @Test("the float8 path decodes the same instant")
    func floatDatetimes() {
        // 2000-01-02 00:00:00 — one day after the Postgres epoch.
        let asInteger = Int64(86_400) * 1_000_000
        let asFloat = Double(86_400)

        let integerBytes = withUnsafeBytes(of: asInteger.bigEndian) { Array($0) }
        let floatBytes = withUnsafeBytes(of: asFloat.bitPattern.bigEndian) { Array($0) }

        let fromInteger = PostgresValueDecoder.decode(
            integerBytes, oid: PostgresOID.timestamp.rawValue, format: 1,
            hasIntegerDatetimes: true
        )
        let fromFloat = PostgresValueDecoder.decode(
            floatBytes, oid: PostgresOID.timestamp.rawValue, format: 1,
            hasIntegerDatetimes: false
        )
        #expect(fromInteger == .text("2000-01-02 00:00:00"))
        #expect(fromFloat == fromInteger)

        // And reading float bytes as an integer is the silent disaster this
        // guards against — a plausible-looking date, tens of thousands of years
        // out.
        let misread = PostgresValueDecoder.decode(
            floatBytes, oid: PostgresOID.timestamp.rawValue, format: 1,
            hasIntegerDatetimes: true
        )
        #expect(misread != fromInteger)
    }
}

import Testing
@testable import SwizzlePostgresDriver

/// What goes in the startup packet, and what the driver supplies when the caller
/// does not.
///
/// The mutation sweep flipped `parameters["DateStyle"] == nil` to `!= nil` and
/// nothing failed — the property had no test at all. The inversion is not subtle
/// once stated: the driver would stop sending `DateStyle` for the connections
/// that need it and start sending it twice for the connections that had already
/// set it.
///
/// That matters because `DateStyle` decides how the server *formats* dates in
/// text results. A connection that inherits the server's locale-dependent default
/// can hand back `25/12/2026`, which the temporal decoders parse as a different
/// day or refuse outright — a wrong date rather than an error, on a setting the
/// caller never touched.
@Suite("Postgres startup parameters")
struct StartupParametersTests {

    static func configuration(
        database: String? = nil, parameters: [String: String] = [:]
    ) -> PostgresConnectionConfiguration {
        var configuration = PostgresConnectionConfiguration(
            address: .tcp(host: "127.0.0.1", port: 5432), username: "swizzle"
        )
        configuration.database = database
        configuration.parameters = parameters
        return configuration
    }

    // MARK: - What the driver supplies

    /// The default is sent when the caller has not asked for one, which is the
    /// overwhelmingly common case and the one the guard exists for.
    @Test("DateStyle defaults to ISO when the caller has not set it")
    func dateStyleDefaultIsSent() {
        let list = Self.configuration().startupParameters
        let dateStyles = list.filter { $0.0 == "DateStyle" }
        #expect(dateStyles.count == 1, "exactly one DateStyle, got \(dateStyles)")
        #expect(dateStyles.first?.1 == PostgresConnectionConfiguration.defaultDateStyle)
    }

    /// And it is not sent twice when the caller has. Sending both would leave the
    /// session's format decided by whichever the server read last, which is not a
    /// thing to leave to ordering.
    @Test("a caller's own DateStyle wins and is sent once")
    func callerDateStyleIsNotDuplicated() {
        let list = Self.configuration(parameters: ["DateStyle": "German, DMY"]).startupParameters
        let dateStyles = list.filter { $0.0 == "DateStyle" }
        #expect(dateStyles.count == 1, "exactly one DateStyle, got \(dateStyles)")
        #expect(dateStyles.first?.1 == "German, DMY")
    }

    // MARK: - The rest of the packet

    @Test("the user is always first and the database only when set")
    func userAndDatabase() {
        let withoutDatabase = Self.configuration().startupParameters
        #expect(withoutDatabase.first?.0 == "user")
        #expect(withoutDatabase.first?.1 == "swizzle")
        #expect(!withoutDatabase.contains { $0.0 == "database" })

        let withDatabase = Self.configuration(database: "app").startupParameters
        #expect(withDatabase.contains { $0 == ("database", "app") })
    }

    /// `user` and `database` come from their own fields, so a stray copy in
    /// `parameters` must not be appended a second time — the server takes the
    /// last one, and a caller who set `parameters["user"]` by accident would
    /// authenticate as somebody else.
    @Test("user and database in the parameter bag are not sent twice")
    func duplicateIdentityParametersAreDropped() {
        let list = Self.configuration(
            database: "app", parameters: ["user": "someone_else", "database": "other"]
        ).startupParameters
        #expect(list.filter { $0.0 == "user" }.count == 1)
        #expect(list.filter { $0.0 == "database" }.count == 1)
        #expect(list.first { $0.0 == "user" }?.1 == "swizzle")
        #expect(list.first { $0.0 == "database" }?.1 == "app")
    }

    /// Sorted, so a packet capture reads the same twice and a test can assert on
    /// it at all.
    @Test("the remaining parameters are ordered deterministically")
    func remainingParametersAreSorted() {
        let list = Self.configuration(
            parameters: ["zeta": "1", "alpha": "2", "mu": "3"]
        ).startupParameters
        let names = list.map(\.0).filter { !["user", "database", "DateStyle"].contains($0) }
        #expect(names == ["alpha", "mu", "zeta"])
    }
}

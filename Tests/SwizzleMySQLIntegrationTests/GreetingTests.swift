import Testing
@testable import SwizzleMySQL

/// Validates the packet decoder and handshake parser against **real** server
/// greetings from all four fixtures — before any connection logic exists.
///
/// This is the first thing in the project that has touched a real MySQL server,
/// and it exercises exactly the fields that unit-test fixtures had to guess at:
/// the real `5.5.5-` MariaDB prefix, real capability bits, and a real scramble
/// split across two packet fields.
@Suite(
    "Real server greetings",
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct GreetingTests {

    @Test("every fixture sends a parseable handshake", arguments: TestServers.all)
    func parsesGreeting(server: MySQLTestServer) async throws {
        let handshake = try await GreetingProbe.read(port: server.port)

        #expect(handshake.connectionID > 0)
        #expect(handshake.authPluginName != nil)
        // Every plugin we support uses a 20-byte scramble; a 21 here would mean
        // the trailing NUL was not stripped.
        #expect(handshake.authPluginData.count == 20)
        #expect(handshake.capabilities.contains(.protocol41))
        #expect(handshake.capabilities.contains(.secureConnection))
        #expect(handshake.capabilities.contains(.pluginAuth))
    }

    @Test("server version matches the pinned image", arguments: TestServers.all)
    func versionMatchesFixture(server: MySQLTestServer) async throws {
        let handshake = try await GreetingProbe.read(port: server.port)
        #expect(
            handshake.normalizedServerVersion.hasPrefix(server.expectedVersionPrefix),
            "\(server) reported \(handshake.serverVersion)"
        )
    }

    /// MariaDB reports itself as `5.5.5-<real version>` so pre-10.0 clients
    /// don't reject a double-digit major version. Detection has to see through
    /// that, and this is the first check of it against a real server.
    @Test("MariaDB is detected behind the 5.5.5- prefix", arguments: TestServers.all)
    func mariaDBDetection(server: MySQLTestServer) async throws {
        let handshake = try await GreetingProbe.read(port: server.port)
        switch server.flavor {
        case .mariaDB:
            #expect(handshake.isMariaDB, "expected MariaDB, got \(handshake.serverVersion)")
        case .mysql:
            #expect(!handshake.isMariaDB, "expected MySQL, got \(handshake.serverVersion)")
        }
    }

    /// TLS is enabled on every fixture, so all four must advertise CLIENT_SSL.
    @Test("all fixtures advertise TLS", arguments: TestServers.all)
    func advertisesTLS(server: MySQLTestServer) async throws {
        let handshake = try await GreetingProbe.read(port: server.port)
        #expect(handshake.capabilities.contains(.ssl))
    }

    /// Capability negotiation against a real greeting: the result must be a
    /// subset of both sides, never a union.
    @Test("negotiation intersects with the real server", arguments: TestServers.all)
    func negotiationIsSubsetOfBoth(server: MySQLTestServer) async throws {
        let handshake = try await GreetingProbe.read(port: server.port)
        let result = MySQLCapabilityNegotiation.negotiate(handshake: handshake)

        #expect(result.capabilities.isSubset(of: handshake.capabilities))
        #expect(result.capabilities.isSubset(of: .swizzleDefault))
        #expect(result.isMariaDB == (server.flavor == .mariaDB))
    }

    /// Records what each real server actually offers — a MySQL server must not
    /// yield MariaDB extended capabilities, whatever is in its reserved bytes.
    @Test("MariaDB extended capabilities appear only on MariaDB", arguments: TestServers.all)
    func extendedCapabilities(server: MySQLTestServer) async throws {
        let handshake = try await GreetingProbe.read(port: server.port)
        let result = MySQLCapabilityNegotiation.negotiate(handshake: handshake)
        if server.flavor == .mysql {
            #expect(result.mariaDBCapabilities.isEmpty)
        }
    }
}

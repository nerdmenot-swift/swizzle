import NIOCore
import NIOPosix
import Testing
@testable import SwizzleMySQL

/// The compressed wire protocol against real servers.
///
/// Compression is a whole-stream transform sitting under the packet framing, so
/// the failure mode to guard against is a payload that *happens* to fit in one
/// frame working while anything larger desyncs. Several tests here therefore
/// push deliberately past a single frame, or past the compression threshold in
/// both directions.
@Suite(
    "Compression",
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct CompressionTests {

    static func configuration(
        _ server: MySQLTestServer,
        compression: MySQLConnectionConfiguration.Compression = .zlib(),
        tls: MySQLConnectionConfiguration.TLSMode = .disable
    ) -> MySQLConnectionConfiguration {
        var config = TestServers.configuration(for: server, tls: tls)
        config.compression = compression
        // Well above the largest fixture below, so a failure is a framing bug
        // rather than the guard rail firing.
        config.maxAllowedPacket = 64 * 1024 * 1024
        return config
    }

    static func connect(
        _ server: MySQLTestServer,
        compression: MySQLConnectionConfiguration.Compression = .zlib(),
        tls: MySQLConnectionConfiguration.TLSMode = .disable
    ) async throws -> MySQLConnection {
        try await MySQLConnection.connect(
            configuration: configuration(server, compression: compression, tls: tls),
            on: TestServers.group.next()
        )
    }

    // MARK: - Negotiation

    /// The assertion that actually matters, and the reason this suite is not
    /// merely self-consistent: the **server** reports whether the session is
    /// compressed. Everything else here could pass with a pass-through encoder,
    /// but `Compression = ON` cannot.
    @Test("the server reports the session as compressed", arguments: TestServers.all)
    func serverConfirmsCompression(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        #expect(connection.metadata.capabilities.contains(.compress))
        #expect(connection.metadata.isCompressionActive)

        let status = try await connection.query("SHOW SESSION STATUS LIKE 'Compression'")
        #expect(status.rows[0][1].string == "ON")
    }

    /// The other half of that oracle. The capability must not be requested when
    /// the feature is off — otherwise the server may start compressing while we
    /// are not decompressing.
    @Test("the server reports an uncompressed session by default", arguments: TestServers.all)
    func disabledByDefault(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server, compression: .disabled)
        defer { connection.closeImmediately() }

        #expect(!connection.metadata.capabilities.contains(.compress))
        #expect(!connection.metadata.isCompressionActive)

        let status = try await connection.query("SHOW SESSION STATUS LIKE 'Compression'")
        #expect(status.rows[0][1].string == "OFF")
    }

    // MARK: - Round trips

    @Test("round-trips a trivial query", arguments: TestServers.all)
    func trivialQuery(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let result = try await connection.query("SELECT 1 AS one")
        #expect(result.rows[0][0].int == 1)
    }

    /// Below `minimumCompressLength` the payload is sent **stored** — a frame
    /// with `uncompressed_length == 0`. That path is the one a naive
    /// implementation forgets, and every short query takes it.
    @Test("round-trips payloads below the compression threshold", arguments: TestServers.all)
    func storedFrames(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        // Comfortably under 50 bytes including the packet header, so the request
        // frame is stored rather than deflated.
        for i in 1...5 {
            let result = try await connection.query("SELECT \(i)")
            #expect(result.rows[0][0].int == Int64(i))
        }
    }

    /// Highly compressible, and large enough that the *reply* must span more
    /// than one compressed frame.
    @Test("round-trips a large compressible result", arguments: TestServers.all)
    func largeCompressibleResult(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let result = try await connection.query("SELECT REPEAT('a', 4000000) AS big")
        let value = try #require(result.rows[0][0].string)
        #expect(value.count == 4_000_000)
        #expect(value.allSatisfy { $0 == "a" })
    }

    /// Random bytes do not deflate, so the encoder's "compressed came out larger
    /// — send it stored instead" fallback fires. Without that fallback this
    /// still works but silently wastes bandwidth; the assertion here is just
    /// that the fallback is wired correctly and round-trips.
    @Test("round-trips incompressible data", arguments: TestServers.all)
    func incompressibleData(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let result = try await connection.query("SELECT LENGTH(RANDOM_BYTES(1024)) AS n")
        #expect(result.rows[0][0].int == 1024)
    }

    /// A large payload travelling *client to server*, which exercises the
    /// encoder rather than the decoder. The two directions are independent code
    /// paths and it is easy to get only one right.
    @Test("round-trips a large outbound payload", arguments: TestServers.all)
    func largeOutboundPayload(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let payload = String(repeating: "swizzle", count: 200_000)   // ~1.4 MB
        let result = try await connection.query(
            "SELECT LENGTH(?) AS n", [.bytes(Array(payload.utf8))]
        )
        #expect(result.rows[0][0].int == Int64(payload.utf8.count))
    }

    // MARK: - Interaction with other features

    /// Compression sits *inside* TLS, so the bytes are deflated and then
    /// encrypted. Getting the pipeline order backwards fails here and nowhere
    /// else.
    @Test("works together with TLS", arguments: TestServers.all)
    func withTLS(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server, tls: .require)
        defer { connection.closeImmediately() }

        #expect(connection.metadata.isTLSActive)
        #expect(connection.metadata.isCompressionActive)

        let result = try await connection.query("SELECT REPEAT('b', 100000) AS big")
        #expect(result.rows[0][0].string?.count == 100_000)
    }

    @Test("works with prepared statements", arguments: TestServers.all)
    func withPreparedStatements(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        for i in 1...20 {
            // CAST, because MySQL types `? + ?` as DECIMAL over the binary
            // protocol while MariaDB gives an integer — a genuine dialect
            // difference, not something the driver should paper over.
            let result = try await connection.query(
                "SELECT CAST(? + ? AS SIGNED) AS total", [.int(Int64(i)), .int(Int64(i * 2))]
            )
            #expect(result.rows[0][0].int == Int64(i * 3))
        }
    }

    /// Streaming is where a frame-boundary bug would surface as a truncated or
    /// stalled sequence rather than an error.
    @Test("works with streaming", arguments: TestServers.all)
    func withStreaming(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        // Built from a self-join rather than MariaDB's `seq_1_to_N` engine,
        // which MySQL has no equivalent of.
        _ = try await connection.query("DROP TEMPORARY TABLE IF EXISTS pad_src")
        _ = try await connection.query("CREATE TEMPORARY TABLE pad_src (n INT)")
        for chunk in stride(from: 1, through: 5000, by: 500) {
            let values = (chunk..<min(chunk + 500, 5001)).map { "(\($0))" }.joined(separator: ",")
            _ = try await connection.query("INSERT INTO pad_src VALUES \(values)")
        }
        let stream = try await connection.stream(
            "SELECT n, REPEAT('x', 200) AS pad FROM pad_src ORDER BY n"
        )

        var count = 0
        var lastSeq = 0
        for try await row in stream {
            count += 1
            lastSeq = Int(row[0].int ?? -1)
        }
        #expect(count == 5000)
        #expect(lastSeq == 5000)
    }

    /// A connection is reused many times over its life, and the compression
    /// sequence resets per command. If it did not, the server would eventually
    /// reject a frame.
    @Test("survives many sequential commands", arguments: TestServers.all)
    func manyCommands(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        for i in 1...300 {
            let result = try await connection.query("SELECT \(i) AS n")
            #expect(result.rows[0][0].int == Int64(i))
        }
    }
}

/// zstd connection compression — **MySQL 8.0.18+ only**.
///
/// Verified purely empirically: none of the four reference clients implements
/// zstd connection compression, so there was no port to check against. The
/// server's own `Compression_algorithm` status variable is the oracle.
@Suite(
    "Zstd compression",
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct ZstdCompressionTests {

    static func connect(
        _ server: MySQLTestServer,
        compression: MySQLConnectionConfiguration.Compression,
        tls: MySQLConnectionConfiguration.TLSMode = .disable
    ) async throws -> MySQLConnection {
        let user = server.primaryUser
        var config = MySQLConnectionConfiguration(
            address: .hostname(TestServers.host, port: server.port),
            username: user.name, password: user.password,
            database: TestServers.database, tls: tls,
            serverPublicKey: .requestFromServer
        )
        config.compression = compression
        config.maxAllowedPacket = 64 * 1024 * 1024
        return try await MySQLConnection.connect(
            configuration: config, on: TestServers.group.next()
        )
    }

    /// The oracle: the server names the algorithm it is actually using. Every
    /// other assertion here would pass with a pass-through encoder; this one
    /// would not, and it also distinguishes zstd from zlib.
    @Test("the server reports zstd as the algorithm", arguments: TestServers.mysql)
    func serverConfirmsZstd(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server, compression: .zstd())
        defer { connection.closeImmediately() }

        #expect(connection.metadata.capabilities.contains(.zstdCompressionAlgorithm))
        #expect(connection.metadata.isCompressionActive)

        let status = try await connection.query(
            "SHOW SESSION STATUS LIKE 'Compression_algorithm'"
        )
        #expect(status.rows[0][1].string == "zstd", "server reports \(status.rows[0][1])")
    }

    /// zlib on the same server must still report zlib — otherwise the test above
    /// proves only that *some* compression happened.
    @Test("zlib and zstd are distinguishable", arguments: TestServers.mysql)
    func zlibReportsZlib(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server, compression: .zlib())
        defer { connection.closeImmediately() }

        let status = try await connection.query(
            "SHOW SESSION STATUS LIKE 'Compression_algorithm'"
        )
        #expect(status.rows[0][1].string == "zlib")
    }

    @Test("round-trips a large compressible result", arguments: TestServers.mysql)
    func largeResult(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server, compression: .zstd())
        defer { connection.closeImmediately() }

        let result = try await connection.query("SELECT REPEAT('a', 4000000) AS big")
        let value = try #require(result.rows[0][0].string)
        #expect(value.count == 4_000_000)
        #expect(value.allSatisfy { $0 == "a" })
    }

    /// Client-to-server, which is the encoder rather than the decoder.
    @Test("round-trips a large outbound payload", arguments: TestServers.mysql)
    func largeOutbound(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server, compression: .zstd())
        defer { connection.closeImmediately() }

        let payload = String(repeating: "swizzle", count: 200_000)
        let result = try await connection.query(
            "SELECT LENGTH(?) AS n", [.bytes(Array(payload.utf8))]
        )
        #expect(result.rows[0][0].int == Int64(payload.utf8.count))
    }

    /// Short payloads go **stored** rather than compressed, which is the path
    /// every small query takes.
    @Test("round-trips below the compression threshold", arguments: TestServers.mysql)
    func storedFrames(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server, compression: .zstd())
        defer { connection.closeImmediately() }
        for i in 1...5 {
            let result = try await connection.query("SELECT \(i)")
            #expect(result.rows[0][0].int == Int64(i))
        }
    }

    @Test("works together with TLS", arguments: TestServers.mysql)
    func withTLS(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server, compression: .zstd(), tls: .require)
        defer { connection.closeImmediately() }

        #expect(connection.metadata.isTLSActive)
        #expect(connection.metadata.isCompressionActive)
        let result = try await connection.query("SELECT REPEAT('b', 100000) AS big")
        #expect(result.rows[0][0].string?.count == 100_000)
    }

    /// MariaDB has no zstd connection compression at all. Asking for it must
    /// leave the connection working and simply uncompressed, not fail.
    @Test("degrades to uncompressed on MariaDB", arguments: TestServers.mariaDB)
    func degradesOnMariaDB(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server, compression: .zstd())
        defer { connection.closeImmediately() }

        #expect(!connection.metadata.capabilities.contains(.zstdCompressionAlgorithm))
        #expect(!connection.metadata.isCompressionActive)

        let result = try await connection.query("SELECT 1 AS ok")
        #expect(result.rows[0][0].int == 1)
    }
}

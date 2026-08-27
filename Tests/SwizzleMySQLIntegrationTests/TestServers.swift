import Foundation
import NIOCore
import NIOPosix
import SwizzleMySQL

#if canImport(Darwin)
import Darwin
private let systemSocket = Darwin.socket
private let systemConnect = Darwin.connect
private let systemClose = Darwin.close
/// `SOCK_STREAM` is a plain `Int32` here, but glibc declares the socket types
/// as an enum (`__socket_type`), so it has to be normalised per platform.
private let systemSockStream = SOCK_STREAM
#else
import Glibc
private let systemSocket = Glibc.socket
private let systemConnect = Glibc.connect
private let systemClose = Glibc.close
private let systemSockStream = Int32(SOCK_STREAM.rawValue)
#endif

/// The fixtures defined in `docker/docker-compose.yml`.
///
/// Version-pinned on purpose: auth plugin availability differs sharply between
/// releases, and a matrix built only on "latest" would miss the configurations
/// most deployments actually run.
public struct MySQLTestServer: Sendable, CustomStringConvertible {
    public enum Flavor: Sendable { case mysql, mariaDB }

    public let name: String
    public let port: Int
    public let flavor: Flavor
    public let expectedVersionPrefix: String
    public let users: [TestUser]

    public var description: String { "\(name):\(port)" }

    /// The unix socket `./Scripts/test-servers.sh` starts each server on.
    ///
    /// Kept in step with `socket_for()` in that script; a mismatch shows up as a
    /// connection refused rather than as anything subtle.
    public var socketPath: String { "/tmp/swzl-\(port).sock" }

    /// The server's own RSA public key, which MySQL writes into its data
    /// directory at initialisation.
    ///
    /// This is what a deployment would copy out and hand to
    /// ``MySQLConnectionConfiguration/ServerPublicKey/pinned(contentsOfFile:)``,
    /// so the tests pin the real file rather than a stand-in. MariaDB has no
    /// such file — it implements neither plugin that needs one.
    public var publicKeyPath: String {
        TestServers.fixtureData.appendingPathComponent("\(name)/public_key.pem").path
    }

    /// The general-purpose fixture user for this server.
    ///
    /// **Not always `mysql_native_password`.** MySQL 9.0 removed that plugin
    /// outright, so no such user exists on the 9.x fixture and force-unwrapping
    /// one there is a crash. Tests that merely need *a* working login should use
    /// this; only tests actually exercising a specific plugin should name one.
    public var primaryUser: TestUser {
        users.first { $0.plugin == "mysql_native_password" && !$0.password.isEmpty }
            ?? users.first { $0.plugin == "caching_sha2_password" && !$0.password.isEmpty }
            ?? users.first { !$0.password.isEmpty }
            ?? users[0]
    }

    public struct TestUser: Sendable {
        public let name: String
        public let password: String
        public let plugin: String
    }
}

/// ## Why every fixture connection says `serverPublicKey: .requestFromServer`
///
/// `MySQLConnectionConfiguration.serverPublicKey` defaults to `.refuse`, so a
/// plaintext connection to a MySQL server whose `caching_sha2_password` cache is
/// cold is declined rather than completing an RSA key exchange with a key the
/// server just sent. That is the right production default and it is what the
/// `mysql` client itself does.
///
/// It also means these fixtures need the opt-in, for two reasons that have
/// nothing to do with the tests being lax:
///
/// 1. A freshly started server has a cold cache for **every** account, so the
///    first plaintext connection of a run takes the RSA path.
/// 2. The authentication suite clears the cache deliberately, with
///    `FLUSH PRIVILEGES`, which is server-wide. Suites run in parallel, so any
///    other suite connecting in the clear can land in that window.
///
/// Loopback to a fixture we started ourselves is exactly the trusted network the
/// option exists for. The policy itself is tested where it belongs — in
/// `MySQLServerPublicKeyTests`, against these same servers, including the
/// default.
public enum TestServers {
    /// Where `./Scripts/test-servers.sh` puts each server's data directory.
    ///
    /// Derived from this file rather than the working directory: `swift test`
    /// runs from the package root, but an IDE or a `--package-path` invocation
    /// does not have to, and a relative path that silently resolves elsewhere
    /// would look like a missing fixture.
    public static let fixtureData = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SwizzleMySQLIntegrationTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // the package root
        .appendingPathComponent(".testservers/data-\(platformTag)")

    /// The platform-tagged data directory `./Scripts/test-servers.sh` writes to.
    ///
    /// Tagged because a checkout is routinely used from two platforms at once —
    /// `Scripts/linux-tests.sh` mounts it into a Linux container on a macOS host.
    /// An untagged cache meant the container found the host's binaries and died
    /// with `cannot execute binary file`, so the fixtures now key on
    /// `uname -s`/`uname -m` and these paths follow.
    static var platformTag: String {
        #if os(Linux)
        // Matches `uname -s | tr` in the script. Swift has no direct `uname -m`,
        // and the two architectures CI and developers use are the two below.
        #if arch(arm64)
        return "linux-aarch64"
        #else
        return "linux-x86_64"
        #endif
        #else
        #if arch(arm64)
        return "darwin-arm64"
        #else
        return "darwin-x86_64"
        #endif
        #endif
    }
    public static let host = "127.0.0.1"
    public static let rootPassword = "rootpass"
    public static let database = "swizzle_test"

    /// MariaDB 11.4 LTS. ed25519 is available; parsec is not (11.6+).
    public static let mariadb114 = MySQLTestServer(
        name: "mariadb114", port: 3306, flavor: .mariaDB, expectedVersionPrefix: "11.4",
        users: [
            .init(name: "native", password: "nativepass", plugin: "mysql_native_password"),
            .init(name: "nopass", password: "", plugin: "mysql_native_password"),
            .init(name: "ed25519", password: "ed25519pass", plugin: "ed25519"),
        ]
    )

    /// MariaDB 11.8 LTS — the earliest fixture with parsec.
    public static let mariadb118 = MySQLTestServer(
        name: "mariadb118", port: 3307, flavor: .mariaDB, expectedVersionPrefix: "11.8",
        users: [
            .init(name: "native", password: "nativepass", plugin: "mysql_native_password"),
            .init(name: "nopass", password: "", plugin: "mysql_native_password"),
            .init(name: "ed25519", password: "ed25519pass", plugin: "ed25519"),
            .init(name: "parsec", password: "parsecpass", plugin: "parsec"),
        ]
    )

    public static let mariadb122 = MySQLTestServer(
        name: "mariadb122", port: 3308, flavor: .mariaDB, expectedVersionPrefix: "12.2",
        users: [
            .init(name: "native", password: "nativepass", plugin: "mysql_native_password"),
            .init(name: "nopass", password: "", plugin: "mysql_native_password"),
            .init(name: "ed25519", password: "ed25519pass", plugin: "ed25519"),
            .init(name: "parsec", password: "parsecpass", plugin: "parsec"),
        ]
    )

    /// MySQL 8.0. The version most deployments are actually on, and the last
    /// where `mysql_native_password` is the plugin you meet without the server
    /// having been asked for it — 8.4 needs a flag, 9.0 removed it. Everything
    /// else here tested a MySQL that most users have not upgraded to yet.
    public static let mysql80 = MySQLTestServer(
        name: "mysql80", port: 3311, flavor: .mysql, expectedVersionPrefix: "8.0",
        users: [
            .init(name: "native", password: "nativepass", plugin: "mysql_native_password"),
            .init(name: "nopass", password: "", plugin: "mysql_native_password"),
            .init(name: "caching", password: "cachingpass", plugin: "caching_sha2_password"),
            .init(name: "sha256", password: "sha256pass", plugin: "sha256_password"),
        ]
    )

    /// MySQL 8.4 LTS. The only fixture with `mysql_native_password`, which 9.0
    /// removed, and the one that makes `caching_sha2_password` full auth and
    /// `sha256_password` verifiable at all.
    public static let mysql84 = MySQLTestServer(
        name: "mysql84", port: 3309, flavor: .mysql, expectedVersionPrefix: "8.4",
        users: [
            .init(name: "native", password: "nativepass", plugin: "mysql_native_password"),
            .init(name: "nopass", password: "", plugin: "mysql_native_password"),
            .init(name: "caching", password: "cachingpass", plugin: "caching_sha2_password"),
            .init(name: "sha256", password: "sha256pass", plugin: "sha256_password"),
        ]
    )

    /// MySQL 9.1. **No `mysql_native_password` at all** — 9.0 removed it — so
    /// this fixture is what a client meets on any current MySQL.
    public static let mysql91 = MySQLTestServer(
        name: "mysql91", port: 3310, flavor: .mysql, expectedVersionPrefix: "9.1",
        users: [
            .init(name: "caching", password: "cachingpass", plugin: "caching_sha2_password"),
            .init(name: "nopass", password: "", plugin: "caching_sha2_password"),
            .init(name: "sha256", password: "sha256pass", plugin: "sha256_password"),
        ]
    )

    public static let all = [mariadb114, mariadb118, mariadb122, mysql80, mysql84, mysql91]

    /// The MariaDB-only fixtures, for features MySQL does not have —
    /// `client_ed25519`, `parsec`, `COM_STMT_BULK_EXECUTE`, `log_bin_compress`.
    public static let mariaDB = [mariadb114, mariadb118, mariadb122]

    /// The MySQL-only fixtures, for features MariaDB does not have —
    /// `caching_sha2_password`, `sha256_password`, zstd, MySQL-dialect GTIDs
    /// and `COM_BINLOG_DUMP_GTID`.
    public static let mysql = [mysql80, mysql84, mysql91]

    /// The newest MariaDB fixture — used where a test needs one server rather
    /// than the whole matrix.
    public static let latest = mariadb122

    /// The newest MySQL fixture, for the same purpose.
    public static let latestMySQL = mysql91

    /// Servers offering `parsec`, as the fixture actually built them.
    ///
    /// **Read from the fixture rather than declared from a version number**,
    /// because availability is a property of the build. MariaDB 11.6+ supports
    /// PARSEC, but the x86_64 Linux tarballs ship only the *client* plugin
    /// (`parsec.so`) and not the server one (`auth_parsec.so`), so on that
    /// platform it cannot be installed at all. A hardcoded list said 11.8 and
    /// 12.2 had it, CI disagreed, and the disagreement surfaced as a seed that
    /// aborted and left two servers with no users whatsoever.
    ///
    /// `./Scripts/test-servers.sh` records what it managed to install in
    /// `.plugins` beside each data directory. Empty here means the parsec suites
    /// skip, which is the honest outcome on a build that cannot run them.
    public static let withParsec: [MySQLTestServer] = [mariadb118, mariadb122]
        .filter { hasPlugin("parsec", $0) }

    static func hasPlugin(_ plugin: String, _ server: MySQLTestServer) -> Bool {
        let path = fixtureData.appendingPathComponent("\(server.name)/.plugins")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return false }
        return text.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces) == plugin
        }
    }
    // MARK: - Coverage note
    //
    // Both flavours are present, and that is the point: each implements things
    // the other does not, so a single-flavour matrix leaves real code paths
    // permanently unverifiable.
    //
    //   MariaDB only: client_ed25519, parsec, COM_STMT_BULK_EXECUTE,
    //                 log_bin_compress, MariaDB-dialect GTIDs
    //   MySQL only:   caching_sha2_password (fast + RSA full auth),
    //                 sha256_password, zstd compression, MySQL-dialect GTIDs,
    //                 COM_BINLOG_DUMP_GTID, partial JSON, TRANSACTION_PAYLOAD
    //
    // Tests that apply to everything use `all`; the rest name `mariaDB` or
    // `mysql` explicitly rather than silently skipping.

    /// Shared across the whole test process.
    ///
    /// Deliberately never shut down: creating and tearing down an
    /// `EventLoopGroup` per probe churns threads badly when Swift Testing runs
    /// cases in parallel.
    public static let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)

    // MARK: - Availability

    /// Probed once, lazily.
    ///
    /// Uses a raw POSIX socket rather than NIO on purpose. This is evaluated
    /// from a `static let` during trait resolution, and any blocking NIO
    /// `.wait()` there can stall Swift Concurrency's cooperative thread pool —
    /// which manifests as the whole suite hanging rather than failing.
    public static let isAvailable: Bool = all.allSatisfy { canConnect(port: $0.port) }

    static func canConnect(port: Int) -> Bool {
        let fd = systemSocket(AF_INET, systemSockStream, 0)
        guard fd >= 0 else { return false }
        defer { _ = systemClose(fd) }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr(host)

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                systemConnect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}

// MARK: - Greeting probe

/// Reads a server's initial handshake without any connection logic, so the
/// packet decoder and handshake parser can be validated against real servers
/// before the connection layer exists.
public enum GreetingProbe {
    /// `async` rather than blocking: `.wait()` on the cooperative thread pool
    /// deadlocks once enough parallel test cases block at the same time.
    public static func read(port: Int) async throws -> MySQLHandshakeV10 {
        let group = TestServers.group
        let promise = group.next().makePromise(of: MySQLPacket.self)

        let channel = try await ClientBootstrap(group: group)
            .connectTimeout(.seconds(5))
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    ByteToMessageHandler(MySQLPacketDecoder()),
                    FirstPacketHandler(promise: promise),
                ])
            }
            .connect(host: TestServers.host, port: port)
            .get()

        do {
            var packet = try await promise.futureResult.get()
            try? await channel.close().get()
            return try MySQLHandshakeV10.parse(&packet.payload)
        } catch {
            try? await channel.close().get()
            throw error
        }
    }
}

private final class FirstPacketHandler: ChannelInboundHandler {
    typealias InboundIn = MySQLPacket

    private let promise: EventLoopPromise<MySQLPacket>
    private var fulfilled = false

    init(promise: EventLoopPromise<MySQLPacket>) { self.promise = promise }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !fulfilled else { return }
        fulfilled = true
        promise.succeed(unwrapInboundIn(data))
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if !fulfilled { fulfilled = true; promise.fail(error) }
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !fulfilled {
            fulfilled = true
            promise.fail(MySQLProtocolError.truncatedPacket)
        }
    }
}

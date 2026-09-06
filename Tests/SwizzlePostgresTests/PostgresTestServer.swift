import Testing

#if canImport(Darwin)
import Darwin
private let systemSocket = Darwin.socket
private let systemConnect = Darwin.connect
private let systemClose = Darwin.close
/// `SOCK_STREAM` is a plain `Int32` here, but glibc declares the socket types as
/// an enum (`__socket_type`), so it has to be normalised per platform.
private let systemSockStream = SOCK_STREAM
#else
import Glibc
private let systemSocket = Glibc.socket
private let systemConnect = Glibc.connect
private let systemClose = Glibc.close
private let systemSockStream = Int32(SOCK_STREAM.rawValue)
#endif

/// Is the Postgres fixture reachable?
///
/// The MySQL integration suites have had this since they were written — every
/// one of them carries `.enabled(if: TestServers.isAvailable)` and skips cleanly
/// on a machine with no servers. The Postgres suites never grew the equivalent,
/// so on such a machine they did not skip: each test opened a connection, waited
/// out the ten-second acquisition timeout and failed.
///
/// Found by running the suite in a Linux container, where the fixtures are
/// unreachable by construction — they bind to the *host's* loopback. The run
/// produced **172 failures in 124 seconds** where it should have produced a few
/// hundred skips in no time at all, and none of the 172 said anything about
/// Linux. A contributor without `./Scripts/test-servers.sh up` saw the same wall
/// of red.
enum PostgresTestServer {
    /// The platform-tagged directory `./Scripts/test-servers.sh` writes to.
    ///
    /// Tagged because a checkout is used from two platforms at once —
    /// `Scripts/linux-tests.sh` mounts it into a Linux container on a macOS host,
    /// and an untagged cache meant the container found the host's binaries and
    /// died with `cannot execute binary file`.
    static var platformTag: String {
        #if os(Linux)
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
    static let host = "127.0.0.1"
    static let port = 5432

    /// The fixture URL every integration suite here connects with.
    ///
    /// `sslmode=require` rather than the default `verify-full`: the fixture's
    /// certificate is self-signed, and these suites are testing everything
    /// *except* the trust chain. `PostgresURLTrustRootTests` is where the
    /// verifying rungs are exercised.
    ///
    /// `connect_timeout=60` because this is a fixture, not a deployment. The
    /// macOS integration job runs the full suite three times over on a
    /// three-core runner alongside seven database servers, and three Postgres
    /// suites failed there with "the connection was not ready within
    /// connect_timeout" — a queue, not a fault. The driver's own default is
    /// untouched, and `PostgresConnectTimeoutTests` sets its own 300 ms deadline
    /// precisely because it is testing this, so it is unaffected.
    ///
    /// Nothing asserts on it: a connection that never completes still fails,
    /// just later.
    static let url = "\(baseURL)?sslmode=require&connect_timeout=60"

    /// The same fixture with no query string, for the handful of tests that
    /// append their own parameters.
    ///
    /// These are the credentials `./Scripts/test-servers.sh` seeds into a
    /// loopback-only server, so they are fixture data rather than secrets — but
    /// they live in **one** place so that stays a deliberate statement instead of
    /// nineteen copies nobody is counting.
    static let baseURL = "postgres://swizzle:swizzlepass@127.0.0.1:5432/swizzle_test"


    // MARK: - The version matrix

    /// One fixture server.
    ///
    /// Added alongside `url` and `port` rather than replacing them. Nineteen
    /// suites target the single fixture and are testing the driver, not the
    /// server's version; rewriting them all to be version-parameterised would be
    /// a large change for coverage that `PostgresVersionMatrixTests` gets on its
    /// own.
    struct Instance: Sendable, CustomStringConvertible {
        let name: String
        let port: Int

        /// The major the fixture is pinned to, asserted against what the server
        /// reports — so a matrix that silently ran three copies of one version
        /// cannot pass.
        let major: Int

        var description: String { "\(name):\(port)" }

        var url: String {
            "postgres://swizzle:swizzlepass@\(host):\(port)/swizzle_test"
                + "?sslmode=require&connect_timeout=60"
        }
    }

    /// Oldest still supported upstream, and where multiranges arrived.
    static let postgres14 = Instance(name: "postgres14", port: 5433, major: 14)

    /// Widely deployed, and previously skipped. The gap between 14 and 16 was
    /// never a decision — it is where the matrix happened to start.
    static let postgres15 = Instance(name: "postgres15", port: 5435, major: 15)

    /// The version developed against, and the one every other suite uses.
    static let postgres16 = Instance(name: "postgres16", port: 5432, major: 16)

    /// The most common version in new deployments, and likewise skipped until
    /// now.
    static let postgres17 = Instance(name: "postgres17", port: 5436, major: 17)

    /// Current. Adds direct TLS negotiation, which this driver does not
    /// implement — connecting at all against it is the point.
    static let postgres18 = Instance(name: "postgres18", port: 5434, major: 18)

    static let all = [postgres14, postgres15, postgres16, postgres17, postgres18]

    /// The fixtures actually running, probed once.
    ///
    /// Filtered rather than assumed, for the same reason the MySQL matrix reads
    /// `.plugins` from disk: a developer may have only the one server up, and a
    /// suite that fails because a fixture is absent teaches people to ignore it.
    static let available: [Instance] = all.filter { canConnect(port: $0.port) }

    static let matrixSkipReason: Comment =
        "No Postgres fixtures reachable — start them with ./Scripts/test-servers.sh up"

    /// Computed once. A probe per suite would be a syscall per suite, and the
    /// answer cannot change mid-run in any way worth handling.
    static let isAvailable: Bool = canConnect(port: port)

    /// A `Comment`, not a `String`: `.enabled(if:_:)` takes the former, and a
    /// `String` variable will not convert even though a literal would.
    static let skipReason: Comment =
        "Postgres fixture not reachable — start it with ./Scripts/test-servers.sh up"

    /// A bare TCP connect with a one-second timeout. Deliberately not a Postgres
    /// handshake: the question is "is anything listening", and answering it with
    /// a real connection would need credentials, TLS and an event loop before a
    /// single test had run.
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

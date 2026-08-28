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

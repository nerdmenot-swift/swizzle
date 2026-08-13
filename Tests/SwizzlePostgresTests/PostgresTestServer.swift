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
    static let host = "127.0.0.1"
    static let port = 5432

    /// The fixture URL every integration suite here connects with.
    ///
    /// `sslmode=require` rather than the default `verify-full`: the fixture's
    /// certificate is self-signed, and these suites are testing everything
    /// *except* the trust chain. `PostgresURLTrustRootTests` is where the
    /// verifying rungs are exercised.
    static let url =
        "postgres://swizzle:swizzlepass@127.0.0.1:5432/swizzle_test?sslmode=require"

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

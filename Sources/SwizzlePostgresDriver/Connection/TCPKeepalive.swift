// Deliberately duplicated between `SwizzleMySQL` and `SwizzlePostgresDriver`.
//
// `SwizzleCore` is the obvious shared home and is the wrong one: it has **no
// dependencies at all**, which is what lets someone use the query builder
// without pulling SwiftNIO into their build. Putting a NIO type there would
// impose the whole networking stack on every consumer to save forty lines.
//
// It also matches the stated design goal that each driver depends on
// `SwizzleCore` and nothing else of ours, so any one of them can be lifted out
// into its own package. Two copies of a value type is the price of that, and it
// is cheaper than the coupling.
// No libc import: every symbol here comes from NIO, and the one that looked
// like it needed one — `IPPROTO_TCP` — is only mentioned in a comment. The
// reflex `#if canImport(Darwin) import Darwin #else import Glibc #endif` broke
// **both static-musl cross-builds**, where the module is not called `Glibc`,
// while compiling cleanly on macOS and on Linux glibc. `canImport` below still
// selects the platform's option numbers; it does not need the module imported.
import NIOCore
import NIOPosix

/// TCP keep-alive settings for a database connection.
///
/// ## Why this is on by default
///
/// A pooled connection spends most of its life idle, and something in the path
/// reaps idle connections without telling either end: NAT tables expire, AWS's
/// network load balancer drops flows at 350 seconds, corporate firewalls are
/// worse. The client keeps a socket it believes is open.
///
/// Nothing then times out. TCP will not abandon a black-holed connection for
/// something like fifteen minutes, and if the middlebox dropped the flow
/// silently rather than sending a reset, **never** — the next query waits
/// forever on a socket that will never answer.
///
/// That is the shape of failure people cannot debug and do not forgive: it works
/// on a laptop, it works in staging, and it hangs in production at 3am after an
/// idle period. Both reference implementations default it on — `libpq` sets
/// `keepalives=1`, and `pgx` relies on Go's dialer, which enables it — so this
/// does too.
///
/// ## Why the idle time is set rather than inherited
///
/// `SO_KEEPALIVE` alone is close to useless here. Linux and Darwin both default
/// the idle time to **two hours**, so a connection reaped at 350 seconds stays
/// dead for the rest of those two hours. The setting that matters is
/// `TCP_KEEPIDLE`, and it has to be lower than whatever is reaping the flow.
///
/// Sixty seconds is chosen to sit under the shortest idle timeout in common
/// use — it costs one small packet per idle connection per minute, which is
/// nothing next to a hung request.
public struct TCPKeepalive: Sendable, Equatable {
    /// Whether keep-alive probing is on at all.
    public var isEnabled: Bool
    /// How long a connection may be idle before the first probe.
    public var idle: TimeAmount
    /// Gap between probes once they start.
    public var interval: TimeAmount
    /// Unanswered probes before the connection is declared dead.
    public var count: Int

    public init(
        isEnabled: Bool = true,
        idle: TimeAmount = .seconds(60),
        interval: TimeAmount = .seconds(10),
        count: Int = 6
    ) {
        self.isEnabled = isEnabled
        self.idle = idle
        self.interval = interval
        self.count = count
    }

    /// Off, for a caller who has a reason — a unix socket, or a network where
    /// the probes are unwelcome.
    public static let disabled = TCPKeepalive(isEnabled: false)

    // The per-socket tuning knobs are not named constants in NIO, and their
    // numbers differ between platforms: Darwin's `TCP_KEEPALIVE` is 0x10 and
    // means "idle seconds", while Linux spells the same idea `TCP_KEEPIDLE` and
    // numbers it 4. Written out rather than imported because the C headers
    // expose them inconsistently across platforms and Swift versions.
    #if canImport(Darwin)
    static let idleOption = NIOBSDSocket.Option(rawValue: 0x10)     // TCP_KEEPALIVE
    static let intervalOption = NIOBSDSocket.Option(rawValue: 0x101) // TCP_KEEPINTVL
    static let countOption = NIOBSDSocket.Option(rawValue: 0x102)    // TCP_KEEPCNT
    #else
    static let idleOption = NIOBSDSocket.Option(rawValue: 4)         // TCP_KEEPIDLE
    static let intervalOption = NIOBSDSocket.Option(rawValue: 5)     // TCP_KEEPINTVL
    static let countOption = NIOBSDSocket.Option(rawValue: 6)        // TCP_KEEPCNT
    #endif

    /// Enables keep-alive on a bootstrap.
    ///
    /// Only `SO_KEEPALIVE` is set here, because a bootstrap option that the
    /// kernel rejects fails the **connect**, and that is the correct severity for
    /// this one and the wrong severity for the others: a connection that cannot
    /// enable keep-alives is a connection that can hang forever, while one whose
    /// kernel spells the idle time differently should still get probes at the
    /// system default rather than no connection at all.
    ///
    /// The tuning goes through ``tune(_:)`` after the socket exists.
    public func apply(to bootstrap: ClientBootstrap) -> ClientBootstrap {
        guard isEnabled else { return bootstrap }
        return bootstrap.channelOption(.socketOption(.so_keepalive), value: 1)
    }

    /// Applies the idle, interval and count knobs to a connected channel.
    ///
    /// Best-effort and deliberately silent on failure. These live at
    /// `IPPROTO_TCP` rather than `SOL_SOCKET` — setting them through
    /// `.socketOption` returns `ENOPROTOOPT`, which is how the first version of
    /// this broke every connection it touched — and they are not uniformly
    /// available: a container, a VPN stack or a future platform may refuse one.
    /// Refusing to connect over a knob is worse than probing at the kernel's own
    /// rate.
    public func tune(_ channel: any Channel) async {
        guard isEnabled else { return }
        let seconds = { (amount: TimeAmount) in
            SocketOptionValue(max(1, amount.nanoseconds / 1_000_000_000))
        }
        for (option, value) in [
            (Self.idleOption, seconds(idle)),
            (Self.intervalOption, seconds(interval)),
            (Self.countOption, SocketOptionValue(count)),
        ] {
            _ = try? await channel.setOption(.tcpOption(option), value: value).get()
        }
    }
}

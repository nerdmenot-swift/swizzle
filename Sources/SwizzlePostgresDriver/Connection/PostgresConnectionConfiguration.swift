import NIOCore
import NIOSSL

/// Everything needed to open a connection.
public struct PostgresConnectionConfiguration: Sendable {

    /// Where the server is.
    public enum Address: Sendable, Equatable {
        case tcp(host: String, port: Int)
        /// A unix domain socket, given as the *directory* Postgres keeps its
        /// socket in — which is how libpq spells it, because the filename is
        /// derived from the port (`.s.PGSQL.5432`).
        case unixSocketDirectory(String, port: Int)

        /// Whether the link is already private without TLS.
        ///
        /// A unix socket cannot be read by anyone who is not already on the
        /// machine and past its file permissions, so it gates cleartext password
        /// authentication the same way TLS does.
        public var isSecureTransport: Bool {
            if case .unixSocketDirectory = self { return true }
            return false
        }

        public var host: String? {
            if case .tcp(let host, _) = self { return host }
            return nil
        }

        /// The path libpq would connect to.
        public var socketPath: String? {
            guard case .unixSocketDirectory(let directory, let port) = self else { return nil }
            let trimmed = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
            return "\(trimmed)/.s.PGSQL.\(port)"
        }
    }

    public var address: Address
    public var username: String
    public var password: String?
    public var database: String?

    /// Startup parameters sent with the connection request.
    ///
    /// `application_name` in particular is worth setting: it is what
    /// `pg_stat_activity` shows, and an unnamed connection is one nobody can
    /// attribute when the database is busy.
    public var parameters: [String: String]

    /// Defaults to `verify-full`, not libpq's `prefer`.
    ///
    /// libpq's default exists for backwards compatibility it has to carry and
    /// this driver does not. `prefer` offers no guarantee at all — an attacker
    /// strips the offer and the client continues in the clear without noticing.
    public var tlsMode: PostgresTLSMode
    public var tlsConfiguration: TLSConfiguration
    /// Overrides the name checked against the certificate and sent as SNI.
    public var tlsServerName: String?

    /// How long to wait for the peer's `close_notify` when shutting TLS down.
    ///
    /// NIOSSL defaults this to **five seconds**, which is right for a peer that
    /// reciprocates and wrong for a database server, which answers `Terminate`
    /// by closing the socket. Measured on the MySQL side, that default made every
    /// TLS close take 5.0012s against 0.0001s for plaintext — five seconds of held
    /// socket, held server session and held pool slot per finished connection.
    ///
    /// Short rather than zero, so a peer that *does* reciprocate still gets a
    /// clean shutdown.
    public var tlsShutdownTimeout: TimeAmount = .milliseconds(250)

    /// Whether to attempt SCRAM-SHA-256-PLUS. See `PostgresChannelBindingMode`.
    public var channelBinding: PostgresChannelBindingMode = .preferred

    /// The largest message the decoder will assemble.
    public var maximumMessageSize: Int

    /// How many server-side prepared statements to keep per connection. Zero
    /// disables caching, which falls back to the unnamed statement — correct, and
    /// a `Parse` on every execution.
    public var statementCacheCapacity: Int

    /// How long to wait for the TCP connection itself.
    ///
    /// `libpq` spells it `connect_timeout` and `tokio-postgres` exposes it as
    /// `Config::connect_timeout`; our MySQL driver has had one since it was
    /// written, and this driver was the odd one out.
    ///
    /// Being precise about what was wrong: connections were **not** unbounded —
    /// NIO's `ClientBootstrap` applies its own ten-second default, and a
    /// black-holed host failed in 10.003 s when measured. What was missing was
    /// any way to *change* it. A latency-sensitive service that would rather fail
    /// over in 500 ms had no way to say so, and `connect_timeout` in a URL was
    /// rejected as an unknown parameter.
    ///
    /// This bounds the *connect*, not the handshake. A server that completes the
    /// TCP connection and then stalls is a different failure, and the caller's own
    /// task cancellation is the tool for it.
    /// TCP keep-alive. On by default — see `TCPKeepalive` for why a database
    /// client that leaves it off can hang forever on a reaped connection.
    public var tcpKeepalive: TCPKeepalive = TCPKeepalive()

    public var connectTimeout: TimeAmount

    public init(
        address: Address,
        username: String,
        password: String? = nil,
        database: String? = nil,
        parameters: [String: String] = [:],
        tlsMode: PostgresTLSMode = .verifyFull,
        tlsConfiguration: TLSConfiguration = .makeClientConfiguration(),
        tlsServerName: String? = nil,
        maximumMessageSize: Int = PostgresMessageDecoder.defaultMaximumMessageSize,
        statementCacheCapacity: Int = PostgresStatementCache.defaultCapacity,
        connectTimeout: TimeAmount = .seconds(10)
    ) {
        self.connectTimeout = connectTimeout
        self.statementCacheCapacity = statementCacheCapacity
        self.address = address
        self.username = username
        self.password = password
        self.database = database
        self.parameters = parameters
        self.tlsMode = tlsMode
        self.tlsConfiguration = tlsConfiguration
        self.tlsServerName = tlsServerName
        self.maximumMessageSize = maximumMessageSize
    }

    /// The startup parameter list, in the order the server expects.
    ///
    /// `user` is mandatory and `database` defaults to the user name when absent —
    /// which is the server's rule, applied here so the omission is deliberate
    /// rather than an empty string on the wire.
    /// Ask the server for ISO dates unless the caller says otherwise.
    ///
    /// ## Why the driver has an opinion here
    ///
    /// `DateStyle` changes the **text** rendering of every date and timestamp,
    /// and the binary rendering not at all. Measured against the fixture, the two
    /// wire formats produce for one value:
    ///
    /// | DateStyle | text |
    /// |---|---|
    /// | `ISO, MDY` | `2024-03-05 14:30:00` |
    /// | `SQL, MDY` | `03/05/2024 14:30:00` |
    /// | `German, DMY` | `05.03.2024 14:30:00` |
    /// | `Postgres, DMY` | `Tue 05 Mar 14:30:00 2024` |
    ///
    /// Binary stays ISO throughout. So on any non-ISO setting the same column
    /// decodes to a *different string* depending on whether the query had
    /// parameters — which is the sort of inconsistency that surfaces as a parsing
    /// bug months later. Asking for ISO removes the question rather than teaching
    /// the decoder four output formats it would then have to keep in step.
    ///
    /// A caller who genuinely wants another style can set `DateStyle` in
    /// `parameters`, and this stays out of the way.
    public static let defaultDateStyle = "ISO"

    public var startupParameters: [(String, String)] {
        var list: [(String, String)] = [("user", username)]
        if let database { list.append(("database", database)) }
        if parameters["DateStyle"] == nil {
            list.append(("DateStyle", Self.defaultDateStyle))
        }
        for key in parameters.keys.sorted() where key != "user" && key != "database" {
            list.append((key, parameters[key]!))
        }
        return list
    }

    /// The configuration the authentication machine needs.
    ///
    /// `isSecureTransport` is computed from the address *and* the negotiated TLS
    /// outcome, so it must be passed in rather than read from the mode: asking
    /// for `prefer` and being refused leaves a plaintext link that must still
    /// refuse a cleartext password.
    public func authenticationConfiguration(
        isTLSActive: Bool,
        channelBindingData: @escaping @Sendable () -> [UInt8]? = { nil }
    ) -> PostgresAuthenticationStateMachine.Configuration {
        // Written as a branch rather than a ternary: a conditional between two
        // closure literals defeats the type checker here.
        var binding: @Sendable () -> [UInt8]? = channelBindingData
        if channelBinding == .disabled {
            binding = { nil }
        }
        return PostgresAuthenticationStateMachine.Configuration(
            username: username,
            password: password,
            database: database,
            parameters: parameters,
            isSecureTransport: isTLSActive || address.isSecureTransport,
            channelBindingData: binding
        )
    }
}

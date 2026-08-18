import Foundation
import NIOCore
import NIOSSL

public struct MySQLConnectionConfiguration: Sendable {

    public enum Address: Sendable {
        case hostname(String, port: Int)
        /// A unix socket counts as a secure transport, so `caching_sha2_password`
        /// full auth may send the password in the clear over it — same rule the
        /// reference applies.
        case unixDomainSocket(path: String)

        public var isSecureTransport: Bool {
            if case .unixDomainSocket = self { return true }
            return false
        }
    }

    /// The same five-rung ladder `libmysqlclient` spells `--ssl-mode` and
    /// `mysql_async` spells `require_ssl` / `verify_ca` / `verify_identity`.
    ///
    /// The top two rungs used to be missing here, which meant a MySQL connection
    /// string could not ask for a *verified* server at all — only "encrypted,
    /// whoever you are". Our own Postgres driver has had the full ladder since it
    /// was written, so this was an inconsistency between the two as much as a gap
    /// against the reference.
    public enum TLSMode: Sendable, Equatable {
        /// Never attempt TLS.
        case disable
        /// Use TLS when the server advertises it; continue unencrypted otherwise.
        ///
        /// Provides no guarantee: an attacker who can strip the server's offer
        /// gets a plaintext session and the client carries on.
        case prefer
        /// Fail the connection if the server does not advertise TLS, but do not
        /// check who is on the other end.
        ///
        /// Stops passive eavesdropping and nothing else — an unverified
        /// certificate is one anybody can present.
        case require
        /// Require TLS and verify the certificate chain.
        ///
        /// `--ssl-mode=VERIFY_CA`. Needs a trust root: set `tlsConfiguration`
        /// with one, or the default system roots apply.
        case verifyCA
        /// Require TLS, verify the chain, **and** check the hostname.
        ///
        /// `--ssl-mode=VERIFY_IDENTITY`. The only rung that resists an active
        /// attacker.
        case verifyFull

        /// Whether a server without TLS is fatal.
        public var requiresTLS: Bool {
            switch self {
            case .disable, .prefer: false
            case .require, .verifyCA, .verifyFull: true
            }
        }

        public var verifiesCertificate: Bool { self == .verifyCA || self == .verifyFull }
        public var verifiesHostname: Bool { self == .verifyFull }
    }

    public var address: Address
    public var username: String
    public var password: String
    public var database: String?

    public var tls: TLSMode
    /// Defaults to certificate verification **disabled**, because the fixtures
    /// (and most managed MySQL) present self-signed certs. Set an explicit
    /// configuration with a trust root for production.
    public var tlsConfiguration: TLSConfiguration
    /// Hostname used for TLS SNI and certificate validation. Defaults to the
    /// connection hostname.
    public var tlsServerName: String?

    /// How long to wait for the peer's `close_notify` when shutting TLS down.
    ///
    /// NIOSSL defaults this to **five seconds**, which is right for a peer that
    /// reciprocates and wrong for MySQL, which answers `COM_QUIT` by closing the
    /// socket and sends no `close_notify` at all. Measured against the MariaDB
    /// fixture, that default made every TLS close take 5.0012s against 0.0001s
    /// for plaintext — five seconds of held socket, held server session and held
    /// pool slot per finished connection.
    ///
    /// Short rather than zero, so a peer that *does* reciprocate still gets a
    /// clean shutdown.
    public var tlsShutdownTimeout: TimeAmount = .milliseconds(250)

    /// Bound on a single reassembled inbound payload. Also advertised to the
    /// server as our max packet size.
    public var maxAllowedPacket: Int

    /// `mysql_clear_password` sends the password with no obfuscation, so it is
    /// refused unless this is set **and** the transport is secure.
    public var allowCleartextPlugin: Bool

    /// How many prepared statements to keep cached per connection.
    ///
    /// Zero disables caching entirely, which is what MySQLNIO effectively does.
    public var statementCacheCapacity: Int

    /// zlib compression for the connection.
    ///
    /// Off by default. On a local socket or inside a VPC it usually costs more
    /// CPU than it saves bandwidth; it earns its keep over a constrained or
    /// metered link, or when result sets are large and text-heavy.
    public var compression: Compression

    public enum Compression: Sendable, Equatable {
        case disabled
        /// zlib, at the given level (0–9). The server must advertise
        /// `CLIENT_COMPRESS`; if it does not, the connection proceeds
        /// uncompressed rather than failing.
        case zlib(level: Int32 = MySQLCompression.defaultLevel)
        /// zstd, at the given level (1–22). **MySQL 8.0.18+ only** — MariaDB has
        /// no zstd connection compression, and a MariaDB server simply will not
        /// advertise the capability, leaving the connection uncompressed.
        ///
        /// Materially better than zlib on result-set-shaped data at comparable
        /// CPU, which is why MySQL added it.
        case zstd(level: Int32 = MySQLCompression.defaultZstdLevel)

        public var isEnabled: Bool { self != .disabled }

        var isZstd: Bool { if case .zstd = self { return true }; return false }

        var level: Int32 {
            switch self {
            case .disabled: MySQLCompression.defaultLevel
            case .zlib(let level): level
            case .zstd(let level): level
            }
        }
    }

    /// Whether the server may ask us to send it a local file (`LOCAL INFILE`).
    ///
    /// **Off by default, and the default matters.** The request arrives from the
    /// server, so a malicious or compromised one can name *any* path the client
    /// process can read and the client will send it — the client never asked for
    /// a file to be read. Enabling this requires naming the files explicitly.
    public var localInfile: LocalInfile

    public enum LocalInfile: Sendable, Equatable {
        case disabled
        /// Only these exact paths may be sent. Anything else is refused and the
        /// connection stays usable.
        case allowList(Set<String>)

        public var isEnabled: Bool { self != .disabled }

        /// Compares standardised absolute paths.
        ///
        /// Matching the raw string would let a server slip past the list with
        /// `/tmp/./data.csv` or `/tmp/x/../data.csv` — the same file under a
        /// spelling the list does not contain. Symlinks are deliberately *not*
        /// resolved: that would let a permitted path be repointed at an
        /// arbitrary file after the list was written.
        public func permits(_ path: String) -> Bool {
            switch self {
            case .disabled:
                return false
            case .allowList(let allowed):
                let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
                return allowed.contains {
                    URL(fileURLWithPath: $0).standardizedFileURL.path == candidate
                }
            }
        }
    }

    /// What the client may do when the server demands the password RSA-encrypted
    /// under a public key.
    ///
    /// **Off by default, and the default matters** — this is the one place in
    /// MySQL authentication where a man in the middle wins.
    ///
    /// `caching_sha2_password` (on a cold cache) and `sha256_password` both need
    /// the cleartext password at the server. Over TLS or a unix socket it simply
    /// travels inside the secure channel. Over a plaintext socket the password is
    /// instead encrypted under an RSA public key **the server sends us during the
    /// handshake** — and a key that arrives over an unauthenticated channel
    /// authenticates nothing. An attacker in the path substitutes their own key,
    /// decrypts the password, re-encrypts it under the server's real key and
    /// forwards it. Both sides see a successful login.
    ///
    /// Postgres closes this with SCRAM channel binding. MySQL has no equivalent
    /// in any of its authentication plugins, so the mitigation is the one its own
    /// client uses: know the key in advance, or decline.
    ///
    /// | | our spelling | `mysql` client | Connector/J |
    /// |---|---|---|---|
    /// | know it in advance | ``pinned(pem:)`` | `--server-public-key-path` | `serverRSAPublicKeyFile` |
    /// | accept what arrives | ``requestFromServer`` | `--get-server-public-key` | `allowPublicKeyRetrieval=true` |
    ///
    /// None of this applies over TLS or a unix socket, where the RSA exchange
    /// does not happen at all.
    public var serverPublicKey: ServerPublicKey

    public enum ServerPublicKey: Sendable, Equatable {
        /// Refuse the exchange, failing the connection with an error that names
        /// the ways forward. The default.
        case refuse

        /// Trust the key the server sends.
        ///
        /// Reasonable on a network you already trust for other reasons — a
        /// loopback socket, a private VPC — and no worse than the alternative on
        /// one you do not, since the password would otherwise not be sent at all.
        /// It is trust-on-first-use without the "first": every connection
        /// re-accepts whatever key arrives.
        case requestFromServer

        /// Encrypt only under this key, in PEM (`-----BEGIN PUBLIC KEY-----`).
        ///
        /// The server's copy lives at `public_key.pem` in its data directory.
        ///
        /// The key is still requested from the server and compared against this
        /// one before use. Encrypting under the pinned key without asking would
        /// be equally *safe* — an attacker's substituted key never gets used —
        /// but it would also be silent, and a mismatch here means someone is in
        /// the path. That deserves an error, not a successful login.
        case pinned(pem: String)

        /// Reads a PEM public key from disk — the `--server-public-key-path`
        /// spelling. Throws rather than falling back to ``refuse``: a pin that
        /// quietly did not load would be the worst of both worlds.
        public static func pinned(contentsOfFile path: String) throws -> ServerPublicKey {
            .pinned(pem: try String(contentsOfFile: path, encoding: .utf8))
        }

        public var isPinned: Bool { if case .pinned = self { return true }; return false }
    }

    /// Receives MariaDB progress reports for long-running statements.
    ///
    /// Setting this is what requests the capability — the server sends nothing
    /// unless asked. Called on the connection's event loop, so it should not
    /// block.
    public var onProgress: (@Sendable (MySQLProgressReport) -> Void)?

    /// Report *matched* rows rather than *changed* rows from an UPDATE.
    ///
    /// Off by default, matching the server. With it on, `UPDATE t SET x = 1`
    /// against a row that already has `x = 1` reports 1 affected row instead of
    /// 0 — which is what most ORMs and "did my update apply?" checks expect, and
    /// why the reference client exposes it.
    public var reportsMatchedRows: Bool

    /// Statements run on every new connection, before it is handed out.
    ///
    /// The session-setup hook a pool needs: `SET time_zone`, `SET NAMES`, a
    /// `sql_mode` the application relies on. Without it those have to be
    /// re-applied by every borrower, and a connection reset silently undoes them.
    ///
    /// Run in order; a failure fails the connection rather than yielding one
    /// that is half-configured.
    /// The session time zone, which decides what a `TIMESTAMP` column means.
    ///
    /// Defaults to ``MySQLSessionTimeZone/server`` — inherit the server's — so
    /// this changes nothing unless asked. See ``MySQLSessionTimeZone`` for why
    /// ``MySQLSessionTimeZone/utc`` is worth setting if you read `TIMESTAMP`
    /// columns at all.
    public var timeZone: MySQLSessionTimeZone = .server

    public var setupStatements: [String]

    public var connectAttributes: [(key: String, value: String)]
    public var capabilities: MySQLCapabilities
    public var mariaDBCapabilities: MySQLCapabilities
    public var characterSet: UInt8
    /// TCP keep-alive. On by default — see `TCPKeepalive` for why a database
    /// client that leaves it off can hang forever on a reaped connection.
    public var tcpKeepalive: TCPKeepalive = TCPKeepalive()

    /// Fail a command if the server sends nothing for this long.
    ///
    /// **Off by default, and that is the reference behaviour rather than an
    /// oversight.** `go-sql-driver`'s `NewConfig` leaves `ReadTimeout` at zero
    /// for a good reason: a legitimate query can produce no bytes for minutes —
    /// a large aggregate, a lock wait, an `ALTER` — and a driver that killed
    /// those by default would be broken in a more obvious way than the hang it
    /// was trying to prevent.
    ///
    /// Set it when you would rather fail than wait: a request path with its own
    /// deadline, or a network where a silently dropped flow is likelier than a
    /// slow query. ``tcpKeepalive`` covers the idle-connection case on its own
    /// and is on by default; this covers the narrower case of a path that dies
    /// **while a command is in flight**, where keep-alive probes have not yet
    /// had time to notice.
    ///
    /// Never applied to a binlog stream: a blocking dump on a quiet server is
    /// silent for as long as nobody writes, and that is the whole point of it.
    public var readTimeout: TimeAmount?

    public var connectTimeout: TimeAmount

    public init(
        address: Address,
        username: String,
        password: String = "",
        database: String? = nil,
        // `verifyFull`, matching the Postgres driver rather than
        // `libmysqlclient`'s `PREFERRED`. Two engines in one library with
        // opposite defaults is worse than either choice, and the two rungs that
        // make this expressible only arrived recently — before them the strongest
        // default available was "encrypted, whoever you are".
        //
        // A server with a self-signed or private-CA certificate needs either a
        // trust root in `tlsConfiguration` or an explicit lower rung. That is the
        // intended friction: it is a decision, not an accident.
        tls: TLSMode = .verifyFull,
        tlsConfiguration: TLSConfiguration? = nil,
        tlsServerName: String? = nil,
        maxAllowedPacket: Int = MySQLPacketDecoder.defaultMaxAllowedPacket,
        allowCleartextPlugin: Bool = false,
        statementCacheCapacity: Int = MySQLStatementCache.defaultCapacity,
        compression: Compression = .disabled,
        localInfile: LocalInfile = .disabled,
        reportsMatchedRows: Bool = false,
        timeZone: MySQLSessionTimeZone = .server,
        setupStatements: [String] = [],
        onProgress: (@Sendable (MySQLProgressReport) -> Void)? = nil,
        connectAttributes: [(key: String, value: String)] = MySQLConnectionConfiguration.defaultAttributes,
        capabilities: MySQLCapabilities = .swizzleDefault,
        mariaDBCapabilities: MySQLCapabilities = .swizzleMariaDBDefault,
        characterSet: UInt8 = MySQLHandshakeResponse41.defaultCharacterSet,
        connectTimeout: TimeAmount = .seconds(10),
        // Last on purpose. Swift requires arguments in declaration order, so a
        // parameter added in the middle of an established initialiser forces
        // every call site that passes anything after it to be reshuffled.
        serverPublicKey: ServerPublicKey = .refuse
    ) {
        self.address = address
        self.username = username
        self.password = password
        self.database = database
        self.tls = tls
        self.tlsConfiguration = tlsConfiguration ?? {
            var configuration = TLSConfiguration.makeClientConfiguration()
            configuration.certificateVerification = .none
            return configuration
        }()
        self.tlsServerName = tlsServerName
        self.maxAllowedPacket = maxAllowedPacket
        self.allowCleartextPlugin = allowCleartextPlugin
        self.statementCacheCapacity = statementCacheCapacity
        self.compression = compression
        self.localInfile = localInfile
        self.serverPublicKey = serverPublicKey
        self.reportsMatchedRows = reportsMatchedRows
        self.timeZone = timeZone
        self.setupStatements = setupStatements
        self.onProgress = onProgress
        self.connectAttributes = connectAttributes
        self.capabilities = capabilities
        self.mariaDBCapabilities = mariaDBCapabilities
        self.characterSet = characterSet
        self.connectTimeout = connectTimeout
    }

    /// Surfaced in the server's `performance_schema.session_connect_attrs`;
    /// cheap, and makes connections identifiable during incident triage.
    public static let defaultAttributes: [(key: String, value: String)] = [
        (key: "_client_name", value: "swizzle-mysql"),
        (key: "_client_version", value: "0.1.0"),
    ]

    public var hostname: String? {
        if case .hostname(let host, _) = address { return host }
        return nil
    }

    /// Auth-relevant notion of "secure": TLS in use, or a unix socket.
    func isSecureTransport(tlsActive: Bool) -> Bool {
        tlsActive || address.isSecureTransport
    }
}

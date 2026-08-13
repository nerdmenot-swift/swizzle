import Foundation
import NIOCore
import NIOSSL

/// A connection URL could not be understood.
public struct MySQLURLError: Error, Sendable, Equatable, CustomStringConvertible {
    public let url: String
    public let reason: String

    public var description: String { "invalid MySQL connection URL: \(reason)" }
}

extension MySQLConnectionConfiguration {

    /// Builds a configuration from a connection URL.
    ///
    /// ```swift
    /// let config = try MySQLConnectionConfiguration(
    ///     url: ProcessInfo.processInfo.environment["DATABASE_URL"]!
    /// )
    /// ```
    ///
    /// Every reference client takes one — `mysql_async` builds its `Opts` from a
    /// URL, go's driver parses a DSN, node-mysql2 and PyMySQL both accept
    /// connection strings — because it is how a deployed service is actually
    /// configured. Reading `DATABASE_URL` out of the environment should not
    /// require the caller to write a parser.
    ///
    /// ```
    /// mysql://user:password@host:3306/database?tls=require&compression=zstd
    /// mysql://user:password@localhost/database?socket=/tmp/mysql.sock
    /// ```
    ///
    /// A unix socket goes in the `socket` parameter rather than the path,
    /// because a path holding both a socket and a database name cannot be split
    /// unambiguously — `/var/run/mysqld/mysqld.sock/app` has no marker saying
    /// where one ends.
    ///
    /// The scheme may be `mysql` or `mariadb`; they are the same protocol and
    /// which one a deployment writes is a matter of taste. Anything else is
    /// rejected rather than assumed, because a `postgres://` URL reaching a
    /// MySQL driver is a configuration mistake worth failing loudly on.
    ///
    /// Username and password are percent-decoded, so a password containing `@`
    /// or `/` works as long as it was encoded — which is the same requirement
    /// every other client has, and the usual reason a URL "mysteriously" fails.
    ///
    /// Supported query parameters:
    ///
    /// | parameter | values |
    /// |---|---|
    /// | `tls` / `sslmode` | `disable`, `prefer`, `require` |
    /// | `compression` | `none`, `zlib`, `zstd` |
    /// | `socket` | path to a unix socket, overriding the host |
    /// | `statement_cache_size` | integer; `0` disables caching |
    /// | `connect_timeout` | seconds |
    /// | `max_allowed_packet` | bytes |
    /// | `allow_cleartext_plugin` | `true`/`false` |
    /// | `time_zone` | `utc`, `server`, `+05:30`, or a zone name |
    ///
    /// An unrecognised parameter is an error rather than being ignored: a
    /// silently dropped `tls=require` is a security failure that looks exactly
    /// like success.
    public init(url string: String) throws {
        guard let components = URLComponents(string: string) else {
            throw MySQLURLError(url: string, reason: "could not be parsed as a URL")
        }
        guard let scheme = components.scheme?.lowercased() else {
            throw MySQLURLError(url: string, reason: "no scheme — expected mysql:// or mariadb://")
        }
        guard scheme == "mysql" || scheme == "mariadb" else {
            throw MySQLURLError(
                url: string, reason: "unsupported scheme '\(scheme)' — expected mysql or mariadb"
            )
        }

        // The path is "/database"; a unix-socket URL puts the socket path there
        // instead and names the database in a query parameter.
        let path = components.path
        var database: String? = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if database?.isEmpty == true { database = nil }

        // Same default as the initialiser and as the Postgres driver: verify the
        // server unless told otherwise. See the initialiser for why this diverges
        // from `libmysqlclient`.
        var tls: TLSMode = .verifyFull
        var compression: Compression = .disabled
        var socketPath: String?
        var statementCacheCapacity = MySQLStatementCache.defaultCapacity
        var connectTimeout = TimeAmount.seconds(10)
        var maxAllowedPacket = MySQLPacketDecoder.defaultMaxAllowedPacket
        var allowCleartextPlugin = false
        var timeZone: MySQLSessionTimeZone = .server
        var serverPublicKey: ServerPublicKey = .refuse
        var rootCertificate: String?
        var clientCertificate: String?
        var clientKey: String?

        for item in components.queryItems ?? [] {
            let value = item.value ?? ""
            switch item.name.lowercased() {
            case "tls", "sslmode", "ssl-mode":
                switch value.lowercased() {
                case "disable", "disabled", "false": tls = .disable
                case "prefer", "preferred": tls = .prefer
                case "require", "required", "true": tls = .require
                // Both spellings again: `verify_ca` is `mysql_async`'s parameter
                // name, `verify-ca` is libpq's and our own Postgres driver's, and
                // `VERIFY_CA` is what `--ssl-mode` takes.
                case "verify_ca", "verify-ca", "verifyca": tls = .verifyCA
                case "verify_identity", "verify-identity", "verify-full",
                     "verify_full", "verifyidentity", "verifyfull":
                    tls = .verifyFull
                default:
                    throw MySQLURLError(
                        url: string,
                        reason: "tls must be disable, prefer or require — got '\(value)'"
                    )
                }

            case "compression", "compress":
                switch value.lowercased() {
                case "none", "false", "disabled": compression = .disabled
                case "zlib", "true": compression = .zlib()
                case "zstd": compression = .zstd()
                default:
                    throw MySQLURLError(
                        url: string,
                        reason: "compression must be none, zlib or zstd — got '\(value)'"
                    )
                }

            case "socket", "unix_socket":
                socketPath = value

            case "statement_cache_size", "stmt_cache_size":
                guard let size = Int(value), size >= 0 else {
                    throw MySQLURLError(
                        url: string, reason: "statement_cache_size must be a non-negative integer"
                    )
                }
                statementCacheCapacity = size

            case "connect_timeout":
                guard let seconds = Int64(value), seconds > 0 else {
                    throw MySQLURLError(
                        url: string, reason: "connect_timeout must be a positive number of seconds"
                    )
                }
                connectTimeout = .seconds(seconds)

            case "max_allowed_packet":
                guard let bytes = Int(value), bytes > 0 else {
                    throw MySQLURLError(
                        url: string, reason: "max_allowed_packet must be a positive integer"
                    )
                }
                maxAllowedPacket = bytes

            case "time_zone", "timezone", "tz":
                switch value.lowercased() {
                case "utc": timeZone = .utc
                case "server": timeZone = .server
                default:
                    // A leading sign means a numeric offset; anything else is a
                    // zone name for the server to resolve.
                    if value.hasPrefix("+") || value.hasPrefix("-"),
                       case let parts = value.dropFirst().split(separator: ":"),
                       let hours = Int(parts.first ?? ""), parts.count <= 2 {
                        let minutes = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
                        let sign = value.hasPrefix("-") ? -1 : 1
                        timeZone = .offset(hours: sign * hours, minutes: sign * minutes)
                    } else {
                        timeZone = .named(value)
                    }
                }

            case "allow_cleartext_plugin":
                allowCleartextPlugin = (value.lowercased() == "true" || value == "1")

            // Both spellings are the ecosystem's, deliberately: someone porting a
            // Connector/J JDBC URL or a `mysql` command line should not have to
            // discover a third name for the same thing. The switch lowercases, so
            // `allowPublicKeyRetrieval` arrives here too.
            case "allow_public_key_retrieval", "allowpublickeyretrieval",
                 "get_server_public_key":
                if value.lowercased() == "true" || value == "1" {
                    serverPublicKey = .requestFromServer
                }

            // The `mysql` client's `--ssl-ca` / `--ssl-cert` / `--ssl-key`.
            // These matter more since the default became `verify_identity`:
            // without them a URL-configured connection to a private-CA server
            // could not be made to work without dropping into code to build a
            // `TLSConfiguration`, and a URL in the environment is how most
            // deployments are configured.
            case "ssl_ca", "sslca", "ssl-ca":
                rootCertificate = value
            case "ssl_cert", "sslcert", "ssl-cert":
                clientCertificate = value
            case "ssl_key", "sslkey", "ssl-key":
                clientKey = value

            case "server_public_key_path", "serverpublickeypath",
                 "serverrsapublickeyfile":
                do {
                    serverPublicKey = try .pinned(contentsOfFile: value)
                } catch {
                    // A pin that failed to load must not fall back to anything —
                    // silently continuing without it is the whole failure this
                    // option exists to prevent.
                    throw MySQLURLError(
                        url: string,
                        reason: "could not read the server public key at '\(value)': \(error)"
                    )
                }

            default:
                throw MySQLURLError(url: string, reason: "unknown parameter '\(item.name)'")
            }
        }

        let address: Address
        if let socketPath {
            address = .unixDomainSocket(path: socketPath)
        } else if let host = components.host, !host.isEmpty {
            address = .hostname(host, port: components.port ?? 3306)
        } else {
            throw MySQLURLError(url: string, reason: "no host, and no socket parameter")
        }

        // Only built when the URL asked for something; otherwise the
        // configuration's own default applies, which the mode then adjusts.
        var tlsConfiguration: TLSConfiguration?
        if rootCertificate != nil || clientCertificate != nil || clientKey != nil {
            var configuration = TLSConfiguration.makeClientConfiguration()
            if let rootCertificate {
                configuration.trustRoots = try MySQLURLTLS.trustRoots(
                    at: rootCertificate, url: string
                )
            }
            if clientCertificate != nil || clientKey != nil {
                let (chain, key) = try MySQLURLTLS.clientIdentity(
                    certificate: clientCertificate, key: clientKey, url: string
                )
                configuration.certificateChain = chain
                configuration.privateKey = key
            }
            tlsConfiguration = configuration
        }

        self.init(
            address: address,
            username: components.user ?? "",
            password: components.password ?? "",
            database: database,
            tls: tls,
            tlsConfiguration: tlsConfiguration,
            maxAllowedPacket: maxAllowedPacket,
            allowCleartextPlugin: allowCleartextPlugin,
            statementCacheCapacity: statementCacheCapacity,
            compression: compression,
            timeZone: timeZone,
            connectTimeout: connectTimeout,
            serverPublicKey: serverPublicKey
        )
    }
}

/// Turning `ssl_ca` / `ssl_cert` / `ssl_key` into a `TLSConfiguration`.
///
/// Everything here fails at **parse** time rather than at connect time, matching
/// `server_public_key_path` above and the Postgres side. A mistyped path that
/// surfaced as a handshake failure three layers down would send the reader
/// looking at the network.
///
/// The URL is passed in for the error but never interpolated into it — a
/// connection URL carries the password, and an error message is exactly the sort
/// of string that ends up in a log.
enum MySQLURLTLS {

    static func trustRoots(at path: String, url: String) throws -> NIOSSLTrustRoots {
        guard FileManager.default.fileExists(atPath: path) else {
            throw MySQLURLError(url: url, reason: "ssl_ca: no file at '\(path)'")
        }
        // Parsed now, not merely existence-checked: a file that is not a
        // certificate would otherwise fail at the first connection.
        do {
            return .certificates(try NIOSSLCertificate.fromPEMFile(path))
        } catch {
            throw MySQLURLError(
                url: url, reason: "ssl_ca: '\(path)' is not a PEM certificate: \(error)"
            )
        }
    }

    static func clientIdentity(
        certificate: String?, key: String?, url: String
    ) throws -> ([NIOSSLCertificateSource], NIOSSLPrivateKeySource) {
        // Neither half is usable alone, and silently ignoring the one that was
        // given would leave the connection unauthenticated while looking
        // configured.
        guard let certificate else {
            throw MySQLURLError(url: url, reason: "ssl_key was given without ssl_cert")
        }
        guard let key else {
            throw MySQLURLError(url: url, reason: "ssl_cert was given without ssl_key")
        }

        let chain: [NIOSSLCertificate]
        do {
            chain = try NIOSSLCertificate.fromPEMFile(certificate)
        } catch {
            throw MySQLURLError(
                url: url, reason: "ssl_cert: '\(certificate)' could not be read: \(error)"
            )
        }

        let privateKey: NIOSSLPrivateKey
        do {
            privateKey = try NIOSSLPrivateKey(file: key, format: .pem)
        } catch {
            throw MySQLURLError(url: url, reason: "ssl_key: '\(key)' could not be read: \(error)")
        }
        return (chain.map { .certificate($0) }, .privateKey(privateKey))
    }
}

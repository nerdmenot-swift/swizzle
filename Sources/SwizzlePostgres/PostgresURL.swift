import Foundation
import NIOSSL
import NIOCore
import SwizzleMigrate
import SwizzlePostgresDriver

extension PostgresConnectionConfiguration {
    /// Builds a configuration from a `postgres://` URL.
    ///
    /// Same shape as the MySQL side, including the decision that an
    /// **unrecognised parameter is an error**: a silently dropped
    /// `sslmode=require` is a security failure that looks exactly like success.
    ///
    /// All five `sslmode` values are now distinct. The postgres-nio version
    /// collapsed `require`, `verify-ca` and `verify-full` into one — it had no
    /// way to express the difference — so a URL asking for hostname verification
    /// silently got a connection that verified nothing. That is precisely the
    /// class of failure the "unknown parameter is an error" rule exists to
    /// prevent, arriving through the parameter that *was* recognised.
    public init(swizzleURL string: String) throws {
        guard let components = URLComponents(string: string),
              let scheme = components.scheme?.lowercased(),
              scheme == "postgres" || scheme == "postgresql"
        else {
            throw PostgresURLError(reason: "expected a postgres:// or postgresql:// URL")
        }

        let path = components.path
        var database: String? = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if database?.isEmpty == true { database = nil }

        // libpq defaults to `prefer`; this driver defaults to `verify-full` and
        // says so. A URL that names a mode gets exactly that mode.
        //
        // This line used to read `.prefer`, directly under the comment claiming
        // otherwise — so the initialiser defaulted to `verify-full` and the URL
        // path, which is how nearly everyone configures a connection, quietly did
        // not. The advertised secure default applied to almost nobody.
        var tlsMode = PostgresTLSMode.verifyFull
        var socketDirectory: String?
        var parameters: [String: String] = [:]
        var connectTimeout = TimeAmount.seconds(10)
        var rootCertificate: String?
        var clientCertificate: String?
        var clientKey: String?

        for item in components.queryItems ?? [] {
            let value = item.value ?? ""
            switch item.name.lowercased() {
            case "sslmode", "tls":
                switch value.lowercased() {
                case "disable", "disabled", "false": tlsMode = .disable
                case "prefer", "preferred", "allow": tlsMode = .prefer
                case "require", "required", "true": tlsMode = .require
                case "verify-ca": tlsMode = .verifyCA
                case "verify-full": tlsMode = .verifyFull
                default:
                    throw PostgresURLError(
                        reason: "sslmode must be disable, prefer, require, verify-ca or "
                            + "verify-full — got '\(value)'"
                    )
                }
            case "host":
                // libpq spells a unix socket as the *directory* it lives in; the
                // filename is derived from the port.
                socketDirectory = value
            case "application_name":
                parameters["application_name"] = value
            case "search_path":
                parameters["search_path"] = value
            // libpq's own spellings. These matter more since the default became
            // `verify-full`: without them a URL-configured connection to a
            // private-CA server could not be made to work at all without
            // dropping into code to build a `TLSConfiguration`, and
            // `DATABASE_URL` is how most deployments are configured.
            case "sslrootcert":
                rootCertificate = value
            case "sslcert":
                clientCertificate = value
            case "sslkey":
                clientKey = value

            case "connect_timeout":
                // libpq's spelling, and its unit: **seconds**. A value of zero or
                // less means "no timeout" there, and the same here — expressed as
                // a very long one rather than as a special case.
                guard let seconds = Int64(value) else {
                    throw PostgresURLError(
                        reason: "connect_timeout must be a whole number of seconds — "
                            + "got '\(value)'"
                    )
                }
                connectTimeout = seconds > 0 ? .seconds(seconds) : .hours(24)
            default:
                throw PostgresURLError(reason: "unknown parameter '\(item.name)'")
            }
        }

        let port = components.port ?? 5432
        let address: Address = socketDirectory.map { .unixSocketDirectory($0, port: port) }
            ?? .tcp(host: components.host ?? "localhost", port: port)

        var tls = TLSConfiguration.makeClientConfiguration()
        if let rootCertificate {
            tls.trustRoots = try PostgresURLTLS.trustRoots(at: rootCertificate)
        }
        if clientCertificate != nil || clientKey != nil {
            let (chain, key) = try PostgresURLTLS.clientIdentity(
                certificate: clientCertificate, key: clientKey
            )
            tls.certificateChain = chain
            tls.privateKey = key
        }

        self.init(
            address: address,
            username: components.user ?? "postgres",
            password: components.password,
            database: database,
            parameters: parameters,
            tlsMode: tlsMode,
            tlsConfiguration: tls,
            connectTimeout: connectTimeout
        )
    }
}

/// Turning `sslrootcert` / `sslcert` / `sslkey` into a `TLSConfiguration`.
///
/// Everything here fails at **parse** time rather than at connect time. A
/// mistyped path that surfaced as a handshake failure three layers down would
/// send the reader looking at the network; failing where the path was written
/// says what is actually wrong. It matches how `server_public_key_path` behaves
/// on the MySQL side.
enum PostgresURLTLS {

    static func trustRoots(at path: String) throws -> NIOSSLTrustRoots {
        guard FileManager.default.fileExists(atPath: path) else {
            throw PostgresURLError(reason: "sslrootcert: no file at '\(path)'"
            )
        }
        // Parsed now, not merely existence-checked: a file that is not a
        // certificate would otherwise fail at the first connection.
        do {
            return .certificates(try NIOSSLCertificate.fromPEMFile(path))
        } catch {
            throw PostgresURLError(reason: "sslrootcert: '\(path)' is not a PEM certificate: \(error)"
            )
        }
    }

    static func clientIdentity(
        certificate: String?, key: String?
    ) throws -> ([NIOSSLCertificateSource], NIOSSLPrivateKeySource) {
        // Neither half is usable alone, and silently ignoring the one that was
        // given would leave the connection unauthenticated while looking
        // configured.
        guard let certificate else {
            throw PostgresURLError(reason: "sslkey was given without sslcert")
        }
        guard let key else {
            throw PostgresURLError(reason: "sslcert was given without sslkey")
        }

        let chain: [NIOSSLCertificate]
        do {
            chain = try NIOSSLCertificate.fromPEMFile(certificate)
        } catch {
            throw PostgresURLError(reason: "sslcert: '\(certificate)' could not be read: \(error)"
            )
        }

        let privateKey: NIOSSLPrivateKey
        do {
            privateKey = try NIOSSLPrivateKey(file: key, format: .pem)
        } catch {
            throw PostgresURLError(reason: "sslkey: '\(key)' could not be read: \(error)"
            )
        }
        return (chain.map { .certificate($0) }, .privateKey(privateKey))
    }
}

public struct PostgresURLError: Error, Sendable, CustomStringConvertible {
    public let reason: String
    public var description: String { "invalid Postgres URL: \(reason)" }
}

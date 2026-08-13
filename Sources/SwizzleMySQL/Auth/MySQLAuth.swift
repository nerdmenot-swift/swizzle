import Crypto
import Foundation
import NIOCore

/// Client-side authentication plugins.
///
/// Every scramble here is a pure function of (password, scramble) with no I/O,
/// which is what makes them testable against independently computed vectors
/// without a live server.
public enum MySQLAuthPlugin: Sendable, Equatable {
    case mysqlNativePassword
    case cachingSHA2Password
    /// The older MySQL 5.7 plugin, distinct from `caching_sha2_password`
    /// despite the similar name.
    case sha256Password
    /// MariaDB 11.6+: PBKDF2-SHA512 then standard ed25519, over two round trips.
    case parsec
    case ed25519
    case unknown(String)

    public init(name: String) {
        switch name {
        case "mysql_native_password": self = .mysqlNativePassword
        case "caching_sha2_password": self = .cachingSHA2Password
        case "sha256_password": self = .sha256Password
        case "parsec": self = .parsec
        case "client_ed25519", "ed25519": self = .ed25519
        default: self = .unknown(name)
        }
    }

    public var name: String {
        switch self {
        case .mysqlNativePassword: "mysql_native_password"
        case .cachingSHA2Password: "caching_sha2_password"
        case .sha256Password: "sha256_password"
        case .parsec: "parsec"
        case .ed25519: "client_ed25519"
        case .unknown(let name): name
        }
    }
}

public enum MySQLAuth {
    /// `SHA1(scramble || SHA1(SHA1(password))) XOR SHA1(password)`
    ///
    /// An empty password authenticates with an empty response, *not* a scramble
    /// of the empty string — servers reject the latter.
    public static func nativePassword(password: String, scramble: [UInt8]) -> [UInt8] {
        guard !password.isEmpty else { return [] }

        let passwordBytes = Array(password.utf8)
        let stage1 = sha1(passwordBytes)                       // SHA1(password)
        let stage2 = sha1(stage1)                              // SHA1(SHA1(password))
        let stage3 = sha1(scramble + stage2)                   // SHA1(scramble || stage2)
        return xor(stage3, stage1)
    }

    /// `SHA256(password) XOR SHA256(SHA256(SHA256(password)) || scramble)`
    ///
    /// This is only the *fast path*. If the server's cache misses it replies
    /// `perform_full_authentication` and the password must be sent either in
    /// cleartext over TLS or RSA-encrypted over a plaintext connection — handled
    /// by the connection state machine, not here.
    public static func cachingSHA2Password(password: String, scramble: [UInt8]) -> [UInt8] {
        guard !password.isEmpty else { return [] }

        let passwordBytes = Array(password.utf8)
        let stage1 = sha256(passwordBytes)                     // SHA256(password)
        let stage2 = sha256(stage1)                            // SHA256(SHA256(password))
        let stage3 = sha256(stage2 + scramble)                 // SHA256(stage2 || scramble)
        return xor(stage1, stage3)
    }

    // MARK: - Primitives

    static func sha1(_ bytes: [UInt8]) -> [UInt8] {
        Array(Insecure.SHA1.hash(data: bytes))
    }

    static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: bytes))
    }

    /// XOR truncated to the shorter operand. Both call sites pass equal-length
    /// digests; the `min` is defensive rather than meaningful.
    static func xor(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
        let count = min(lhs.count, rhs.count)
        var out = [UInt8]()
        out.reserveCapacity(count)
        for i in 0..<count { out.append(lhs[i] ^ rhs[i]) }
        return out
    }
}

// MariaDB `client_ed25519` lives in MySQLEd25519.swift. The derivation was
// confirmed against MariaDB's own stored public key — it seeds the standard
// ed25519 expansion with the *password bytes* rather than a 32-byte seed, which
// is exactly why swift-crypto cannot express it, and why the curve arithmetic
// is implemented directly in `Ed25519Core`.

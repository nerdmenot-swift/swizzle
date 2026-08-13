import Crypto
import Foundation
import _CryptoExtras

/// MariaDB's `parsec` authentication (11.6+).
///
/// Two round trips, unlike every other plugin:
///
/// 1. The server's `AuthSwitchRequest` carries a 32-byte scramble. The client
///    answers with an **empty packet** — it cannot do anything useful yet,
///    because the salt and iteration count have not been sent.
/// 2. The server then sends a 20-byte auth string: `'P'`, an iteration factor,
///    and an 18-byte salt. The client derives a key, signs, and replies.
///
/// ```
/// seed      = PBKDF2-HMAC-SHA512(password, salt, 1024 << factor, 32 bytes)
/// message   = server_scramble(32) || client_scramble(32, random)
/// signature = Ed25519(seed).sign(message)
/// response  = client_scramble || signature          // 96 bytes
/// ```
///
/// Unlike `client_ed25519`, the seed here is a proper 32 bytes, so this is
/// **standard** ed25519 and swift-crypto can sign it directly — no libsodium.
///
/// Ported from rust-mysql-common's `auth/plugins/parsec.rs`.
public enum MySQLParsec {

    public static let scrambleLength = 32
    public static let saltLength = 18
    /// `'P'` + factor + salt.
    public static let authStringLength = 2 + saltLength
    public static let responseLength = scrambleLength + 64

    /// The server's second challenge: algorithm, iteration factor, salt.
    public struct AuthString: Sendable, Equatable {
        public var factor: UInt8
        public var salt: [UInt8]

        /// `1024 << factor`. The factor is capped at 3, so at most 8192.
        public var iterations: Int { 1024 << Int(factor) }

        public static func parse(_ bytes: [UInt8]) throws -> AuthString {
            guard bytes.count == authStringLength else {
                throw MySQLProtocolError.malformedPacket(
                    "parsec: auth string must be \(authStringLength) bytes, got \(bytes.count)"
                )
            }
            guard bytes[0] == UInt8(ascii: "P") else {
                throw MySQLProtocolError.unsupportedAuthPlugin(
                    "parsec: unknown algorithm marker 0x\(String(bytes[0], radix: 16))"
                )
            }
            guard bytes[1] <= 3 else {
                throw MySQLProtocolError.malformedPacket(
                    "parsec: iteration factor \(bytes[1]) out of range"
                )
            }
            return AuthString(factor: bytes[1], salt: Array(bytes[2...]))
        }
    }

    /// Builds the second-round response.
    ///
    /// `clientScramble` is injectable so tests can be deterministic; production
    /// callers should let it default to fresh randomness, since reusing a client
    /// nonce across authentications weakens the exchange.
    public static func response(
        password: String,
        serverScramble: [UInt8],
        authString: AuthString,
        clientScramble: [UInt8]? = nil
    ) throws -> [UInt8] {
        guard serverScramble.count == scrambleLength else {
            throw MySQLProtocolError.malformedPacket(
                "parsec: server scramble must be \(scrambleLength) bytes"
            )
        }

        let clientNonce = clientScramble ?? randomScramble()
        guard clientNonce.count == scrambleLength else {
            throw MySQLProtocolError.malformedPacket(
                "parsec: client scramble must be \(scrambleLength) bytes"
            )
        }

        // `unsafeUncheckedRounds` is required, not a shortcut: the round count
        // comes from the server (at most 8192) and is far below the minimum the
        // checked API enforces. Refusing it would make the plugin unusable.
        let derived = try KDF.Insecure.PBKDF2.deriveKey(
            from: Array(password.utf8),
            salt: authString.salt,
            using: .sha512,
            outputByteCount: 32,
            unsafeUncheckedRounds: authString.iterations
        )
        let seed = derived.withUnsafeBytes { Array($0) }

        // A proper 32-byte seed, so this is ordinary ed25519.
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let message = serverScramble + clientNonce
        let signature = try key.signature(for: Data(message))

        return clientNonce + Array(signature)
    }

    /// The ed25519 public key parsec derives, which is what MariaDB stores.
    public static func publicKey(password: String, authString: AuthString) throws -> [UInt8] {
        let derived = try KDF.Insecure.PBKDF2.deriveKey(
            from: Array(password.utf8),
            salt: authString.salt,
            using: .sha512,
            outputByteCount: 32,
            unsafeUncheckedRounds: authString.iterations
        )
        let seed = derived.withUnsafeBytes { Array($0) }
        return try Array(Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            .publicKey.rawRepresentation)
    }

    static func randomScramble() -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<scrambleLength).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }
}

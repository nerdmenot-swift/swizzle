import CSodiumEd25519
import Crypto
import Foundation

/// MariaDB's `client_ed25519` authentication.
///
/// The client signs the server's scramble with an ed25519 key derived from the
/// password. It is *almost* standard ed25519 — the difference is that the
/// expansion is seeded with the **password bytes** rather than a 32-byte seed:
///
/// ```
/// h = SHA512(password)
/// s = clamp(h[0..<32])                 // secret scalar
/// r = scalar_reduce(SHA512(h[32...] || M))
/// R = scalarmult_base_noclamp(r)
/// A = scalarmult_base_noclamp(s)       // public key
/// k = scalar_reduce(SHA512(R || A || M))
/// S = scalar_add(scalar_mul(k, s), r)
/// signature = R || S
/// ```
///
/// That one difference is why swift-crypto cannot be used:
/// `Curve25519.Signing.PrivateKey` accepts only a 32-byte `rawRepresentation`
/// and performs the SHA-512 expansion internally, so there is no way to inject a
/// key expanded from an arbitrary-length password.
///
/// The arithmetic is **libsodium's ref10**, vendored as `CSodiumEd25519` — only
/// the ed25519 subset (~7.4k lines), which is portable C99 with no assembly and
/// no CPU-feature detection, so it builds for static musl as well as macOS and
/// glibc. libsodium's platform glue (`utils.c`: mlock, mprotect, guarded
/// allocation) is shimmed rather than vendored, since that is where portability
/// actually breaks. See `docs/platforms.md`.
///
/// A pure-Swift implementation of the same arithmetic lives in the test target
/// as `Ed25519Core`, and every value here is checked against it.
///
/// Structure verified against PyMySQL's `_auth.ed25519_password` (which names
/// its variables after RFC 8032 §5.1.6) and rust-mysql-common's
/// `client_ed25519`.
public enum MySQLEd25519 {

    /// Length of the signature MariaDB expects: `R || S`.
    public static let signatureLength = 64
    static let scalarLength = 32
    /// Wide input to `scalar_reduce` — a 64-byte value reduced mod L.
    static let nonReducedScalarLength = 64

    /// Signs `scramble` with a key derived from `password`.
    ///
    /// An empty password authenticates with an empty response, matching every
    /// other plugin.
    public static func sign(password: String, scramble: [UInt8]) throws -> [UInt8] {
        guard !password.isEmpty else { return [] }

        // h = SHA512(password); s = clamp(first half)
        let h = Array(SHA512.hash(data: Array(password.utf8)))
        let secret = clamp(Array(h[0..<scalarLength]))
        let noncePrefix = Array(h[scalarLength...])

        // r = scalar_reduce(SHA512(noncePrefix || M))
        let r = try reduce(Array(SHA512.hash(data: noncePrefix + scramble)))

        // R = [r]B, A = [s]B — both *unclamped*: the scalar is already clamped,
        // and clamping twice would yield a different point.
        let R = try scalarMultiplyBase(r)
        let A = try scalarMultiplyBase(secret)

        // k = scalar_reduce(SHA512(R || A || M))
        let k = try reduce(Array(SHA512.hash(data: R + A + scramble)))

        // S = (k * s + r) mod L
        let S = add(multiply(k, secret), r)

        return R + S
    }

    /// The ed25519 public key for a password, as MariaDB stores it.
    ///
    /// Useful for provisioning: `CREATE USER ... IDENTIFIED VIA ed25519 USING
    /// PASSWORD(...)` stores the base64 of exactly this.
    public static func publicKey(password: String) throws -> [UInt8] {
        let h = Array(SHA512.hash(data: Array(password.utf8)))
        return try scalarMultiplyBase(clamp(Array(h[0..<scalarLength])))
    }

    // MARK: - Primitives

    /// Standard ed25519 scalar clamping: clear the low 3 bits, clear the top
    /// bit, set bit 254.
    static func clamp(_ bytes: [UInt8]) -> [UInt8] {
        var out = bytes
        out[0] &= 248
        out[31] &= 127
        out[31] |= 64
        return out
    }

    static func reduce(_ wide: [UInt8]) throws -> [UInt8] {
        guard wide.count == nonReducedScalarLength else {
            throw MySQLProtocolError.malformedPacket("ed25519: scalar_reduce needs 64 bytes")
        }
        var input = wide
        var output = [UInt8](repeating: 0, count: scalarLength)
        swizzle_ed25519_scalar_reduce(&output, &input)
        return output
    }

    /// Note this can fail: libsodium refuses to return the identity or a
    /// small-order point. Unreachable here — every scalar comes out of SHA-512,
    /// and the secret is clamped so bit 254 is always set — but it is surfaced
    /// rather than silently coerced.
    static func scalarMultiplyBase(_ scalar: [UInt8]) throws -> [UInt8] {
        var input = scalar
        var output = [UInt8](repeating: 0, count: scalarLength)
        guard swizzle_ed25519_scalarmult_base_noclamp(&output, &input) == 0 else {
            throw MySQLProtocolError.malformedPacket(
                "ed25519: scalar multiplication produced a degenerate point"
            )
        }
        return output
    }

    static func multiply(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
        var a = lhs, b = rhs
        var output = [UInt8](repeating: 0, count: scalarLength)
        swizzle_ed25519_scalar_mul(&output, &a, &b)
        return output
    }

    static func add(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
        var a = lhs, b = rhs
        var output = [UInt8](repeating: 0, count: scalarLength)
        swizzle_ed25519_scalar_add(&output, &a, &b)
        return output
    }
}

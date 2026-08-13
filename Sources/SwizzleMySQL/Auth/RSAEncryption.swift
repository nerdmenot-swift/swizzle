import Foundation
import _CryptoExtras

/// RSA encryption for `caching_sha2_password` full authentication.
///
/// Used only on the plaintext path: when the server replies
/// `perform_full_authentication` and we are *not* on TLS or a unix socket, the
/// password must be encrypted under a public key the server sends us.
///
/// swift-crypto's `_CryptoExtras` provides this, so the reference's ~640-line
/// RSA/DER module does not need porting.
public enum MySQLRSA {
    /// Encrypts with PKCS#1 OAEP.
    ///
    /// OAEP means MySQL versions before 8.0.5 are unsupported on this path —
    /// they expect PKCS#1 v1.5. That matches `rust-mysql-common`, whose
    /// `crypto::encrypt` carries the same caveat, and 8.0.5 predates every
    /// server we target.
    ///
    /// - Parameter plaintext: the NUL-terminated password already XORed with
    ///   the nonce. That XOR is the caller's job — see `MySQLAuthStateMachine`.
    public static func encrypt(_ plaintext: [UInt8], publicKeyPEM: [UInt8]) throws -> [UInt8] {
        guard let pem = String(bytes: publicKeyPEM, encoding: .utf8) else {
            throw MySQLProtocolError.malformedPacket("RSA public key is not valid UTF-8")
        }
        let key: _RSA.Encryption.PublicKey
        do {
            key = try _RSA.Encryption.PublicKey(pemRepresentation: pem)
        } catch {
            throw MySQLProtocolError.malformedPacket("unparseable RSA public key: \(error)")
        }
        return try Array(key.encrypt(plaintext, padding: .PKCS1_OAEP))
    }

    /// The key's DER bytes, for comparing a received key against a pinned one.
    ///
    /// Comparing the PEM text would be wrong: the same key differs by line
    /// endings, trailing newline, wrapping width, and whether the header says
    /// `PUBLIC KEY` or `RSA PUBLIC KEY`. Two keys are the same key when their DER
    /// is the same, and nothing else.
    ///
    /// Throws ``MySQLProtocolError/malformedPacket(_:)`` on anything unparseable,
    /// which is the right answer for both sides of the comparison — a pin that
    /// cannot be parsed must fail loudly rather than compare unequal.
    public static func publicKeyDER(pem: [UInt8]) throws -> Data {
        guard let text = String(bytes: pem, encoding: .utf8) else {
            throw MySQLProtocolError.malformedPacket("RSA public key is not valid UTF-8")
        }
        do {
            return try _RSA.Encryption.PublicKey(pemRepresentation: text).derRepresentation
        } catch {
            throw MySQLProtocolError.malformedPacket("unparseable RSA public key: \(error)")
        }
    }
}

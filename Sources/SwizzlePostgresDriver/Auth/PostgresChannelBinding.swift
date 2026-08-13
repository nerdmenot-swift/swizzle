import Crypto
import NIOConcurrencyHelpers
import Foundation
import NIOSSL

/// `tls-server-end-point` channel binding data — RFC 5929 §4.
///
/// ## What binding actually buys
///
/// SCRAM already proves both sides know the password. What it does not prove is
/// that they are talking to *each other*: a man in the middle who terminates TLS
/// with a certificate the client accepts can relay the whole exchange and end up
/// authenticated on the real server.
///
/// Binding closes that by mixing a hash of the **server's certificate** into the
/// `c=` attribute, which is inside the signed AuthMessage. The relay presents a
/// different certificate, so its hash differs, so the proof it would need is over
/// data it cannot construct.
///
/// This is also why `scram_channel_binding=require` exists on the server side,
/// and why a client that supports binding must send `y` rather than `n` when the
/// server offers only the non-PLUS mechanism — see
/// ``SCRAMClient/ChannelBinding/supportedButServerDidNot``.
public enum PostgresChannelBinding {

    /// The hash of the certificate, using the hash from its **signature
    /// algorithm** — not SHA-256 unconditionally.
    ///
    /// RFC 5929 says to use the certificate's own signature hash, with one
    /// exception: MD5 and SHA-1 are upgraded to SHA-256, because binding to a
    /// broken hash would let an attacker with a collision substitute a
    /// certificate. Everything stronger is used as-is, so a SHA-384 certificate
    /// binds with SHA-384.
    public static func tlsServerEndPoint(
        certificate: NIOSSLCertificate
    ) throws -> [UInt8] {
        hash(der: try certificate.toDERBytes())
    }

    public static func hash(der: [UInt8]) -> [UInt8] {
        switch signatureHash(der: der) {
        case .sha384: [UInt8](SHA384.hash(data: der))
        case .sha512: [UInt8](SHA512.hash(data: der))
        // SHA-256 for SHA-256 signatures, and *also* the upgrade path for MD5 and
        // SHA-1 — RFC 5929 §4 is explicit that binding must not inherit a broken
        // hash, because an attacker with a collision could otherwise substitute a
        // certificate that binds identically.
        case .sha256: [UInt8](SHA256.hash(data: der))
        }
    }

    enum SignatureHash { case sha256, sha384, sha512 }

    /// Walks just enough DER to reach the certificate's signature algorithm.
    ///
    /// `NIOSSLCertificate` does not expose it, and it cannot be assumed: a
    /// SHA-384 certificate must bind with SHA-384, and hashing it with SHA-256
    /// produces a value the server will not agree with — an authentication
    /// failure with nothing in the message to suggest why.
    ///
    /// ```
    /// Certificate ::= SEQUENCE {
    ///     tbsCertificate       TBSCertificate,     -- skipped
    ///     signatureAlgorithm   AlgorithmIdentifier, -- the OID lives here
    ///     signatureValue       BIT STRING
    /// }
    /// ```
    ///
    /// Anything unrecognised falls back to SHA-256, which is both the common case
    /// and the RFC's answer for the weak algorithms.
    static func signatureHash(der: [UInt8]) -> SignatureHash {
        var index = 0
        guard readSequenceHeader(der, &index) else { return .sha256 }
        // tbsCertificate: read its header and step over the body entirely.
        guard let tbsLength = readHeader(der, &index, expecting: 0x30) else { return .sha256 }
        index += tbsLength
        // signatureAlgorithm, whose first element is the OID.
        guard readSequenceHeader(der, &index),
              let oidLength = readHeader(der, &index, expecting: 0x06),
              index + oidLength <= der.count
        else { return .sha256 }

        let oid = Array(der[index..<(index + oidLength)])
        // Last byte distinguishes the members of each family:
        // 1.2.840.113549.1.1.{11,12,13} = RSA with SHA-{256,384,512}
        // 1.2.840.10045.4.3.{2,3,4}     = ECDSA with SHA-{256,384,512}
        let rsa: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01]
        let ecdsa: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03]

        if oid.count == rsa.count + 1, Array(oid.dropLast()) == rsa {
            switch oid.last {
            case 0x0C: return .sha384
            case 0x0D: return .sha512
            default: return .sha256
            }
        }
        if oid.count == ecdsa.count + 1, Array(oid.dropLast()) == ecdsa {
            switch oid.last {
            case 0x03: return .sha384
            case 0x04: return .sha512
            default: return .sha256
            }
        }
        return .sha256
    }

    static func readSequenceHeader(_ der: [UInt8], _ index: inout Int) -> Bool {
        readHeader(der, &index, expecting: 0x30) != nil
    }

    /// Reads a tag and its length, leaving `index` on the first content byte.
    ///
    /// Handles the long form, where the low seven bits of the first length byte
    /// give how many bytes the length itself occupies — a certificate is always
    /// long enough to use it, so treating the short form as universal would fail
    /// on every real input.
    static func readHeader(_ der: [UInt8], _ index: inout Int, expecting tag: UInt8) -> Int? {
        guard index < der.count, der[index] == tag else { return nil }
        index += 1
        guard index < der.count else { return nil }

        let first = der[index]
        index += 1
        guard first & 0x80 != 0 else { return Int(first) }

        let byteCount = Int(first & 0x7F)
        guard byteCount > 0, byteCount <= 4, index + byteCount <= der.count else { return nil }
        var length = 0
        for _ in 0..<byteCount {
            length = length << 8 | Int(der[index])
            index += 1
        }
        return length
    }
}

/// Whether to attempt SCRAM-SHA-256-PLUS.
public enum PostgresChannelBindingMode: Sendable, Equatable {
    /// Never bind. The gs2 header stays `n`, and a server offering only `-PLUS`
    /// cannot be satisfied.
    case disabled
    /// Bind when the server offers `-PLUS`, and send the `y` downgrade tripwire
    /// when it does not. The default, because it costs nothing and detects a
    /// stripped mechanism list.
    case preferred
}

/// Holds the peer certificate between the TLS handshake and authentication.
///
/// A box because the two happen in different places: the certificate arrives in
/// a verification callback during the handshake, and the hash is needed when the
/// server later asks for SASL.
final class PostgresCertificateCapture: @unchecked Sendable {
    private let lock = NIOLock()
    private var certificate: NIOSSLCertificate?

    func store(_ certificate: NIOSSLCertificate) {
        lock.withLock { self.certificate = certificate }
    }

    /// The binding data, or nil when there is no certificate to bind to.
    var bindingData: [UInt8]? {
        guard let certificate = lock.withLock({ self.certificate }) else { return nil }
        return try? PostgresChannelBinding.tlsServerEndPoint(certificate: certificate)
    }
}

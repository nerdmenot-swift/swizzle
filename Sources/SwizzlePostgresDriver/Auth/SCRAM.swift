import Crypto
import Foundation
import _CryptoExtras

/// SCRAM-SHA-256, the mechanism modern Postgres actually uses.
///
/// RFC 5802 with RFC 7677's SHA-256 parameters. The exchange is four messages:
///
/// 1. client-first — `n,,n=,r=<nonce>`
/// 2. server-first — `r=<combined nonce>,s=<salt>,i=<iterations>`
/// 3. client-final — `c=<channel binding>,r=<combined nonce>,p=<proof>`
/// 4. server-final — `v=<server signature>`
///
/// The fourth message is not a formality. It proves the *server* knew the stored
/// key, which is what stops an impostor that captured a client's proof from
/// completing the handshake — so it is verified rather than skipped, and a
/// mismatch fails the connection.
///
/// The username defaults to empty, because Postgres takes it from the startup
/// message and RFC 5802 says to send an empty `n=` when the protocol carries it
/// separately. It is still a parameter rather than a constant, for one concrete
/// reason: RFC 7677's published test vector uses `n=user`, and a client that
/// cannot produce that vector cannot be checked against anything but itself.
public struct SCRAMClient: Sendable {
    /// The largest iteration count this client will accept from a server.
    ///
    /// **A security bound, not a tuning knob.** The count arrives from the server
    /// and drives a PBKDF2 loop, so an unbounded value lets a malicious or
    /// impersonating server make the client perform arbitrary work before
    /// authentication has even completed — a denial of service with no
    /// credentials required. 100,000 is roughly 24× Postgres's own default of
    /// 4,096, and is the cap pgjdbc adopted for CVE-2026-42198. Taken from the
    /// primary reference, which had already been through this.
    public static let maximumIterationCount = 100_000

    let password: [UInt8]
    let username: String
    let clientNonce: String
    /// The `gs2-header`, which also becomes the `c=` attribute. `n,,` means the
    /// client does not support channel binding.
    let gs2Header: String

    public init(
        password: String, username: String = "",
        nonce: String? = nil, channelBinding: ChannelBinding = .none
    ) {
        self.password = Self.normalize(password)
        self.username = Self.escape(username)
        self.clientNonce = nonce ?? Self.makeNonce()
        self.gs2Header = channelBinding.header
        self.channelBinding = channelBinding
    }

    public enum ChannelBinding: Sendable, Equatable {
        /// `n,,` — this client cannot bind. Sent when the connection is not TLS,
        /// because there is nothing to bind *to*.
        case none
        /// `y,,` — **the downgrade tripwire, and the reason `y` exists at all.**
        ///
        /// Sent when the client *could* bind but the server advertised only the
        /// non-PLUS mechanism. If a man in the middle stripped `-PLUS` from the
        /// mechanism list to force the weaker exchange, the `y` reaches a server
        /// that knows it does support binding, and the server aborts. Sending `n`
        /// here instead would make that attack silent.
        case supportedButServerDidNot
        /// `p=tls-server-end-point,,` plus the binding data, which is mixed into
        /// the `c=` attribute and therefore into the signature.
        case tlsServerEndPoint(certificateHash: [UInt8])

        var header: String {
            switch self {
            case .none: "n,,"
            case .supportedButServerDidNot: "y,,"
            case .tlsServerEndPoint: "p=tls-server-end-point,,"
            }
        }

        /// The mechanism name this binding implies.
        public var mechanism: String {
            switch self {
            case .none, .supportedButServerDidNot: "SCRAM-SHA-256"
            case .tlsServerEndPoint: "SCRAM-SHA-256-PLUS"
            }
        }

        var data: [UInt8] {
            switch self {
            case .none, .supportedButServerDidNot: []
            case .tlsServerEndPoint(let hash): hash
            }
        }
    }

    let channelBinding: ChannelBinding

    public var clientFirstBare: String { "n=\(username),r=\(clientNonce)" }
    public var clientFirstMessage: String { gs2Header + clientFirstBare }

    /// Everything derived once the server has replied.
    public struct Exchange: Sendable {
        public let clientFinalMessage: String
        /// Kept so the server's final message can be checked against it.
        let expectedServerSignature: [UInt8]
    }

    /// Consumes `server-first` and produces `client-final`.
    public func respond(toServerFirst message: String) throws -> Exchange {
        let attributes = try Self.parse(message)

        guard let combinedNonce = attributes["r"], combinedNonce.hasPrefix(clientNonce) else {
            // The server must echo our nonce as a prefix. Anything else means it
            // is replaying somebody else's exchange.
            throw SCRAMError.nonceMismatch
        }
        guard let saltText = attributes["s"], let salt = Data(base64Encoded: saltText) else {
            throw SCRAMError.malformed("server-first has no usable salt")
        }
        guard let iterationText = attributes["i"], let iterations = Int(iterationText) else {
            throw SCRAMError.malformed("server-first has no iteration count")
        }
        guard iterations > 0 else {
            throw SCRAMError.malformed("iteration count must be positive, got \(iterations)")
        }
        guard iterations <= Self.maximumIterationCount else {
            throw SCRAMError.iterationCountTooHigh(
                iterations, maximum: Self.maximumIterationCount
            )
        }

        // SaltedPassword := Hi(Normalize(password), salt, i)
        //
        // `unsafeUncheckedRounds` because swift-crypto's checked entry point
        // enforces an OWASP minimum of 210,000 — sound advice when *you* choose
        // the count, and inapplicable here: SCRAM's count is chosen by the
        // server, and Postgres's own default is 4,096. Refusing it would mean
        // refusing to authenticate against a default Postgres install.
        //
        // The risk that check exists to prevent runs the other way for us anyway.
        // A weak count is the server's decision about its own stored verifier; an
        // *enormous* one is an attack on this client, and that is what
        // `maximumIterationCount` above bounds.
        let saltedPassword = try KDF.Insecure.PBKDF2.deriveKey(
            from: password, salt: salt, using: .sha256, outputByteCount: 32,
            unsafeUncheckedRounds: iterations
        ).withUnsafeBytes { [UInt8]($0) }

        let clientKey = Self.hmac(key: saltedPassword, message: Array("Client Key".utf8))
        let storedKey = [UInt8](SHA256.hash(data: clientKey))
        let serverKey = Self.hmac(key: saltedPassword, message: Array("Server Key".utf8))

        // RFC 5802: `c=` is base64 of the gs2 header **followed by the binding
        // data**. With no binding the data is empty and this is just the header,
        // which is why the non-PLUS case looks like a base64 of `n,,`.
        //
        // Because `c=` is part of the AuthMessage, the certificate hash is inside
        // every signature — that is the whole mechanism. A man in the middle
        // terminating TLS presents a different certificate, so its hash differs,
        // so the proof it would have to forge is over data it cannot produce.
        let channelBindingAttribute = Data(
            Array(gs2Header.utf8) + channelBinding.data
        ).base64EncodedString()
        let clientFinalWithoutProof = "c=\(channelBindingAttribute),r=\(combinedNonce)"

        // AuthMessage is the three messages joined, and every signature is over
        // exactly this — which is why the bare forms are kept rather than the
        // wire ones.
        let authMessage = Array(
            "\(clientFirstBare),\(message),\(clientFinalWithoutProof)".utf8
        )

        let clientSignature = Self.hmac(key: storedKey, message: authMessage)
        let proof = zip(clientKey, clientSignature).map(^)

        return Exchange(
            clientFinalMessage: clientFinalWithoutProof
                + ",p=\(Data(proof).base64EncodedString())",
            expectedServerSignature: Self.hmac(key: serverKey, message: authMessage)
        )
    }

    /// Checks `server-final`.
    ///
    /// Skipping this is the difference between authenticating the server and
    /// merely talking to one. A constant-time comparison, because the value is a
    /// MAC and a timing leak on a MAC comparison is a real one.
    public func verify(serverFinal message: String, against exchange: Exchange) throws {
        let attributes = try Self.parse(message)
        if let error = attributes["e"] {
            throw SCRAMError.serverRejected(error)
        }
        guard let signatureText = attributes["v"],
              let signature = Data(base64Encoded: signatureText)
        else {
            throw SCRAMError.malformed("server-final has no verifier")
        }
        guard Self.constantTimeEquals([UInt8](signature), exchange.expectedServerSignature) else {
            throw SCRAMError.serverSignatureMismatch
        }
    }

    // MARK: - Primitives

    static func hmac(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var mac = HMAC<SHA256>(key: SymmetricKey(data: key))
        mac.update(data: message)
        return [UInt8](mac.finalize())
    }

    /// Compares without leaking where the difference is.
    static func constantTimeEquals(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }

    /// `a=value,b=value` — the SCRAM attribute syntax.
    ///
    /// Split on the *first* `=` only: a base64 salt routinely ends in padding and
    /// splitting on every `=` would truncate it.
    static func parse(_ message: String) throws -> [String: String] {
        var attributes: [String: String] = [:]
        for field in message.split(separator: ",") {
            guard let separator = field.firstIndex(of: "=") else {
                throw SCRAMError.malformed("attribute '\(field)' has no value")
            }
            let key = String(field[field.startIndex..<separator])
            attributes[key] = String(field[field.index(after: separator)...])
        }
        return attributes
    }

    /// `=` and `,` are the attribute delimiters, so a username containing either
    /// has to be escaped or it would be read as extra attributes. RFC 5802 §5.1
    /// spells the substitutions out; the `=` one must go first, or it would
    /// re-escape the `=` introduced by the comma rule.
    static func escape(_ username: String) -> String {
        username
            .replacingOccurrences(of: "=", with: "=3D")
            .replacingOccurrences(of: ",", with: "=2C")
    }

    /// 24 characters from the printable range SCRAM allows.
    ///
    /// `,` and `=` are excluded because they are the attribute delimiters — a
    /// nonce containing either would be parsed as two attributes by the server.
    static func makeNonce() -> String {
        let alphabet = Array(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/"
        )
        var bytes = [UInt8](repeating: 0, count: 24)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    /// SASLprep, to the extent it matters here.
    ///
    /// RFC 4013 asks for full stringprep: map some characters to nothing, map
    /// others to space, normalise to NFKC, and reject the prohibited ones. A
    /// Postgres password is not required to be valid UTF-8 at all, so the
    /// reference runs saslprep when it can and falls back to the raw bytes when it
    /// cannot — the same shape as here.
    ///
    /// This implementation does the NFKC normalisation and the space mapping,
    /// which is what changes the answer for real passwords. It does **not** reject
    /// prohibited characters: rejecting a password the server accepts would turn a
    /// working login into an unexplainable failure, and the server does its own
    /// preparation regardless. An ASCII password — which is very nearly all of
    /// them — passes through untouched either way.
    static func normalize(_ password: String) -> [UInt8] {
        if password.allSatisfy({ $0.isASCII && !$0.isWhitespace || $0 == " " }) {
            return Array(password.utf8)
        }
        // Non-ASCII space characters map to U+0020 before normalisation.
        let mapped = String(password.map { character in
            character.unicodeScalars.count == 1
                && CharacterSet.whitespaces.contains(character.unicodeScalars.first!)
                ? " " : character
        })
        return Array(mapped.precomposedStringWithCompatibilityMapping.utf8)
    }
}

public enum SCRAMError: Error, Sendable, Equatable {
    case malformed(String)
    /// The server did not echo our nonce — it is replaying someone else's
    /// exchange, or is not the server it claims to be.
    case nonceMismatch
    /// The server asked for more PBKDF2 work than this client will do. See
    /// ``SCRAMClient/maximumIterationCount``.
    case iterationCountTooHigh(Int, maximum: Int)
    /// The server could not prove it knew the stored key.
    case serverSignatureMismatch
    case serverRejected(String)
}

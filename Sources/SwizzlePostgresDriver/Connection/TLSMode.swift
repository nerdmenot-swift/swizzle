/// What to do about TLS, in libpq's vocabulary.
///
/// Named after `sslmode` because that is what every Postgres URL, tool and
/// runbook already says, and inventing different words for the same five choices
/// would make every existing connection string need translating.
public enum PostgresTLSMode: String, Sendable, Equatable, CaseIterable {
    /// Never. The connection is plaintext, and cleartext password authentication
    /// will be refused as a result.
    case disable
    /// Try TLS; fall back to plaintext if the server says no.
    ///
    /// **The one that surprises people.** It is libpq's default, and it provides
    /// no security guarantee whatsoever: a network attacker can strip the offer
    /// and the client will happily continue in the clear. It exists for
    /// compatibility with servers that have TLS switched off, and choosing it
    /// should be a decision rather than an accident — which is why it is not this
    /// driver's default.
    case prefer
    /// Require TLS, but do not check who is on the other end.
    ///
    /// Stops passive eavesdropping and does nothing about an active attacker,
    /// because an unverified certificate is one anybody can present.
    case require
    /// Require TLS and verify the certificate chain.
    case verifyCA = "verify-ca"
    /// Require TLS, verify the chain, and check the hostname matches.
    ///
    /// The only mode that resists an active attacker, and therefore the default
    /// here — libpq defaults to `prefer` for backwards compatibility it has to
    /// carry and this driver does not.
    case verifyFull = "verify-full"

    /// Whether to send `SSLRequest` at all.
    public var attemptsTLS: Bool { self != .disable }

    /// Whether a server refusing TLS is fatal.
    ///
    /// True for everything except `prefer`, whose entire purpose is to carry on
    /// regardless — and the reason it is a weak choice.
    public var requiresTLS: Bool {
        switch self {
        case .disable, .prefer: false
        case .require, .verifyCA, .verifyFull: true
        }
    }

    public var verifiesCertificate: Bool {
        self == .verifyCA || self == .verifyFull
    }

    public var verifiesHostname: Bool { self == .verifyFull }

    /// Whether a link in this mode is private enough for a cleartext password.
    ///
    /// `require` is deliberately included even though it does not authenticate
    /// the server: the alternative is refusing a configuration libpq accepts, and
    /// the eavesdropper this protects the password from is stopped by encryption
    /// alone. An active attacker who can present a certificate can also just read
    /// the password after authentication.
    public var isPrivate: Bool { requiresTLS }
}

/// The server answered the TLS offer.
public enum PostgresTLSNegotiation: Sendable, Equatable {
    case accepted
    case refused

    /// The single byte a server replies to `SSLRequest` with.
    public init?(byte: UInt8) {
        switch byte {
        case UInt8(ascii: "S"): self = .accepted
        case UInt8(ascii: "N"): self = .refused
        default: return nil
        }
    }
}

public enum PostgresTLSError: Error, Sendable, Equatable, CustomStringConvertible {
    case serverRefusedTLS(mode: PostgresTLSMode)
    case malformedResponse(UInt8)
    /// Bytes arrived behind the one-byte answer, which the server had no reason
    /// to send. See `PostgresTLSNegotiationHandler` — this is CVE-2021-23222.
    case unexpectedDataAfterNegotiation(Int)
    case connectionClosedDuringNegotiation

    public var description: String {
        switch self {
        case .serverRefusedTLS(let mode):
            "the server does not support TLS, and sslmode=\(mode.rawValue) requires it"
        case .malformedResponse(let byte):
            "the server answered the TLS request with 0x\(String(byte, radix: 16)), "
                + "expected 'S' or 'N'"
        case .unexpectedDataAfterNegotiation(let count):
            "\(count) unexpected byte(s) followed the TLS negotiation response; the server "
                + "had nothing to send at that point, so they were injected — refusing the "
                + "connection rather than processing them as though they arrived over TLS"
        case .connectionClosedDuringNegotiation:
            "the connection closed while negotiating TLS"
        }
    }
}

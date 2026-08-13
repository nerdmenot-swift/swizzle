import Foundation

/// Everything between "the socket is open" and "the connection is usable".
///
/// Wraps the authentication machine and adds what comes after it: the parameters
/// the server pushes, the key needed to cancel a query, and the `ReadyForQuery`
/// that actually ends the handshake. Pure, for the same reason authentication is.
public struct PostgresConnectionStateMachine: Sendable {

    public enum Action: Sendable, Equatable {
        case send(PostgresFrontendMessage)
        case wait
        /// The handshake is done and the connection may be used.
        case ready
        case fail(PostgresConnectionError)
    }

    enum Phase: Sendable {
        case authenticating
        /// Authenticated; collecting the parameters and key that arrive before
        /// `ReadyForQuery`.
        case settling
        case ready
        case failed
    }

    var authentication: PostgresAuthenticationStateMachine
    var phase: Phase = .authenticating

    /// What the server has told us about itself.
    ///
    /// Not decoration. `integer_datetimes` and `DateStyle` change how temporals
    /// decode, `server_version` gates syntax, and `TimeZone` changes what a
    /// `timestamptz` means — so these are kept rather than logged and discarded.
    /// They also arrive **mid-session**, not only during the handshake, because
    /// `SET` makes the server push a fresh one.
    public private(set) var parameters: [String: String] = [:]

    /// Needed to cancel a running query, which requires a *second* connection
    /// quoting this pair. Useless if it is not kept.
    public private(set) var backendKey: (processID: Int32, secretKey: Int32)?

    public private(set) var transactionStatus: PostgresTransactionStatus = .idle

    /// Notices are delivered rather than swallowed: `NOTICE` is how Postgres says
    /// "your index was not used" or "this column will be dropped".
    public private(set) var notices: [PostgresServerMessage] = []

    /// Which SASL mechanism authenticated, if any.
    ///
    /// Surfaced because "TLS is on and a password was accepted" does not tell a
    /// caller whether channel binding actually happened — and a test that cannot
    /// tell `SCRAM-SHA-256` from `SCRAM-SHA-256-PLUS` cannot verify it.
    public var saslMechanism: String? { authentication.saslMechanism }

    public init(configuration: PostgresAuthenticationStateMachine.Configuration) {
        self.authentication = PostgresAuthenticationStateMachine(configuration: configuration)
    }

    public mutating func start() -> Action {
        switch authentication.start() {
        case .send(let message): .send(message)
        case .fail(let error): .fail(.authentication(error))
        default: .wait
        }
    }

    public mutating func handle(_ message: PostgresBackendMessage) -> Action {
        // These three arrive in any phase and are never a reply to anything.
        switch message {
        case .parameterStatus(let name, let value):
            parameters[name] = value
            return .wait
        case .notice(let notice):
            notices.append(notice)
            return .wait
        case .backendKeyData(let processID, let secretKey):
            backendKey = (processID, secretKey)
            return .wait
        default:
            break
        }

        switch phase {
        case .authenticating:
            switch message {
            case .authentication(let request):
                switch authentication.handle(request) {
                case .send(let reply): return .send(reply)
                case .wait: return .wait
                case .authenticated:
                    phase = .settling
                    return .wait
                case .fail(let error):
                    phase = .failed
                    return .fail(.authentication(error))
                }
            case .error(let error):
                phase = .failed
                return .fail(.server(error))
            case .negotiateProtocolVersion(let newest, let unsupported):
                // The server speaks an older protocol than we asked for. Reported
                // rather than ignored, because carrying on would fail later with
                // something that looks unrelated.
                phase = .failed
                return .fail(.protocolVersion(newest: newest, unsupported: unsupported))
            default:
                phase = .failed
                return .fail(.unexpected(during: "authentication"))
            }

        case .settling:
            switch message {
            case .readyForQuery(let status):
                transactionStatus = status
                phase = .ready
                return .ready
            case .error(let error):
                phase = .failed
                return .fail(.server(error))
            default:
                // Anything else before ReadyForQuery is the server's business —
                // there is no fixed set, and refusing unknown-but-harmless
                // messages here would break against a future server.
                return .wait
            }

        case .ready:
            if case .readyForQuery(let status) = message {
                transactionStatus = status
            }
            return .wait

        case .failed:
            return .wait
        }
    }
}

public enum PostgresConnectionError: Error, Sendable, Equatable {
    case authentication(PostgresAuthenticationError)
    case server(PostgresServerMessage)
    case protocolVersion(newest: Int32, unsupported: [String])
    case unexpected(during: String)
}

extension PostgresConnectionError: CustomStringConvertible {
    /// The server's own words, with the fields that make them actionable.
    ///
    /// `detail` and `hint` are included because Postgres puts the genuinely
    /// useful part there — the message is often just "syntax error at or near
    /// …" while the hint says what to write instead.
    static func render(_ message: PostgresServerMessage) -> String {
        var text = "\(message.severity): \(message.message)"
        if !message.sqlState.isEmpty { text += " [\(message.sqlState)]" }
        if let detail = message.detail { text += "\n  detail: \(detail)" }
        if let hint = message.hint { text += "\n  hint: \(hint)" }
        return text
    }

    public var description: String {
        switch self {
        case .authentication(let error):
            error.description
        case .server(let message):
            Self.render(message)
        case .protocolVersion(let newest, let unsupported):
            "the server speaks protocol \(newest >> 16).\(newest & 0xFFFF) and rejected "
                + (unsupported.isEmpty ? "our request" : unsupported.joined(separator: ", "))
        case .unexpected(let phase):
            "the server sent an unexpected message during \(phase)"
        }
    }
}

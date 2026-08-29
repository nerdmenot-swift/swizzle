import Crypto
import Foundation

/// Drives authentication, without touching a socket.
///
/// A pure state machine for the same reason MySQL's is: the awkward paths — a
/// server demanding cleartext over a plaintext link, a server offering only a
/// mechanism we cannot do, a second authentication request after we thought we
/// were done — are exactly the ones hardest to reach against a real server and
/// most important to get right. Here they are three lines of test each.
public struct PostgresAuthenticationStateMachine: Sendable {

    public struct Configuration: Sendable {
        public var username: String
        public var password: String?
        public var database: String?
        /// Extra startup parameters — `application_name`, `search_path`, and
        /// anything else the caller wants set before the first query.
        public var parameters: [String: String]
        /// Whether the link cannot be read by a third party: TLS is up, or this
        /// is a unix socket.
        ///
        /// Gates cleartext password authentication. Postgres will happily ask for
        /// a plaintext password over a plaintext link, and a client that complies
        /// has posted the password to anyone listening.
        public var isSecureTransport: Bool
        /// `tls-server-end-point` binding data — the hash of the server's
        /// certificate — when the connection is TLS and the certificate was
        /// captured. Nil means binding is impossible, which is a different
        /// statement from "the server did not offer it".
        /// Read **lazily**, when the server asks for SASL.
        ///
        /// Not a value, because the certificate does not exist yet when the
        /// pipeline is built: the TLS negotiation promise resolves when the
        /// handler is *inserted*, and the handshake — and therefore the
        /// certificate — comes after. Capturing the bytes there captured nil, and
        /// the connection quietly fell back to the non-PLUS mechanism.
        public var channelBindingData: @Sendable () -> [UInt8]?

        public init(
            username: String, password: String? = nil, database: String? = nil,
            parameters: [String: String] = [:], isSecureTransport: Bool = false,
            channelBindingData: @escaping @Sendable () -> [UInt8]? = { nil }
        ) {
            self.channelBindingData = channelBindingData
            self.username = username
            self.password = password
            self.database = database
            self.parameters = parameters
            self.isSecureTransport = isSecureTransport
        }
    }

    public enum Action: Sendable, Equatable {
        case send(PostgresFrontendMessage)
        /// Nothing to do; the server owes us another message.
        case wait
        case authenticated
        case fail(PostgresAuthenticationError)
    }

    enum State: Sendable {
        case initial
        case awaitingAuthentication
        case awaitingCleartextResult
        case awaitingMD5Result
        case awaitingSASLContinue(SCRAMClient)
        case awaitingSASLFinal(SCRAMClient, SCRAMClient.Exchange)
        case authenticated
        case failed
    }

    let configuration: Configuration
    var state: State = .initial
    /// The mechanism actually negotiated, for callers that need to know whether
    /// channel binding took place.
    public private(set) var saslMechanism: String?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// The first thing on the wire after the (optional) TLS upgrade.
    public mutating func start() -> Action {
        var parameters: [(String, String)] = [("user", configuration.username)]
        if let database = configuration.database {
            parameters.append(("database", database))
        }
        // Sorted, so the startup packet is deterministic — which matters for
        // tests and for anyone reading a packet capture.
        //
        // The mutation sweep flips this `<` to `<=` and nothing catches it, which
        // is correct rather than a gap: `parameters` is a `[String: String]`, so
        // the comparator is never handed two equal keys and the two orderings are
        // indistinguishable. Recorded here rather than answered with a test,
        // because the test would assert nothing.
        for (key, value) in configuration.parameters.sorted(by: { $0.key < $1.key }) {
            parameters.append((key, value))
        }
        state = .awaitingAuthentication
        return .send(.startup(parameters: parameters))
    }

    public mutating func handle(_ request: PostgresAuthenticationRequest) -> Action {
        switch (state, request) {
        case (_, .ok):
            // Reached from any state: `AuthenticationOk` is how every method ends.
            state = .authenticated
            return .authenticated

        case (.awaitingAuthentication, .cleartextPassword):
            guard configuration.isSecureTransport else {
                state = .failed
                return .fail(.insecureCleartextRefused)
            }
            guard let password = configuration.password else {
                state = .failed
                return .fail(.passwordRequired)
            }
            state = .awaitingCleartextResult
            return .send(.password(password))

        case (.awaitingAuthentication, .md5Password(let salt)):
            guard let password = configuration.password else {
                state = .failed
                return .fail(.passwordRequired)
            }
            state = .awaitingMD5Result
            return .send(.password(Self.md5(
                password: password, username: configuration.username, salt: salt
            )))

        case (.awaitingAuthentication, .sasl(let mechanisms)):
            guard let password = configuration.password else {
                state = .failed
                return .fail(.passwordRequired)
            }
            // ── Mechanism selection, and the downgrade tripwire ───────────────
            //
            // `-PLUS` is preferred whenever binding data is available, because it
            // is the only variant that proves the two ends are talking to each
            // other rather than through a relay.
            //
            // When we *could* bind and the server offers only the plain
            // mechanism, the gs2 header is `y` rather than `n`. That is not a
            // formality: if a man in the middle stripped `-PLUS` from the list to
            // force the weaker exchange, the `y` reaches a server that knows it
            // does support binding, and the server aborts. Sending `n` would make
            // that attack silent, which is precisely what `y` exists to prevent.
            let binding: SCRAMClient.ChannelBinding
            let available = configuration.channelBindingData()
            if let data = available, mechanisms.contains("SCRAM-SHA-256-PLUS") {
                binding = .tlsServerEndPoint(certificateHash: data)
            } else if available != nil {
                binding = .supportedButServerDidNot
            } else {
                binding = .none
            }

            guard mechanisms.contains(binding.mechanism) else {
                state = .failed
                return .fail(.noSupportedMechanism(offered: mechanisms))
            }
            let client = SCRAMClient(password: password, channelBinding: binding)
            saslMechanism = binding.mechanism
            state = .awaitingSASLContinue(client)
            return .send(.saslInitialResponse(
                mechanism: binding.mechanism,
                data: Array(client.clientFirstMessage.utf8)
            ))

        case (.awaitingSASLContinue(let client), .saslContinue(let data)):
            guard let message = String(bytes: data, encoding: .utf8) else {
                state = .failed
                return .fail(.malformed("server-first is not valid UTF-8"))
            }
            do {
                let exchange = try client.respond(toServerFirst: message)
                state = .awaitingSASLFinal(client, exchange)
                return .send(.saslResponse(Array(exchange.clientFinalMessage.utf8)))
            } catch let error as SCRAMError {
                state = .failed
                return .fail(.scram(error))
            } catch {
                state = .failed
                return .fail(.malformed("\(error)"))
            }

        case (.awaitingSASLFinal(let client, let exchange), .saslFinal(let data)):
            guard let message = String(bytes: data, encoding: .utf8) else {
                state = .failed
                return .fail(.malformed("server-final is not valid UTF-8"))
            }
            do {
                // Verified rather than assumed: this is what proves the server
                // knew the stored key, and skipping it makes the exchange
                // one-directional.
                try client.verify(serverFinal: message, against: exchange)
                // `AuthenticationOk` still follows; this only clears the SASL
                // sub-exchange.
                state = .awaitingAuthentication
                return .wait
            } catch let error as SCRAMError {
                state = .failed
                return .fail(.scram(error))
            } catch {
                state = .failed
                return .fail(.malformed("\(error)"))
            }

        case (_, .unsupported(let code)):
            state = .failed
            return .fail(.unsupportedMethod(code: code, name: Self.methodName(code)))

        default:
            // A request that does not belong in this state. Refused rather than
            // handled, because an out-of-order authentication exchange is either a
            // broken server or an attempt to confuse the client into a weaker
            // method than it already agreed to.
            state = .failed
            return .fail(.unexpectedRequest)
        }
    }

    /// `md5(md5(password + username) + salt)`, hex, prefixed with `md5`.
    ///
    /// Postgres deprecated this and it is still everywhere. The inner digest is
    /// hex *text* before the salt is appended, not raw bytes — getting that wrong
    /// produces a plausible-looking hash the server rejects.
    static func md5(password: String, username: String, salt: [UInt8]) -> String {
        let inner = hex(Insecure.MD5.hash(data: Array((password + username).utf8)))
        let outer = hex(Insecure.MD5.hash(data: Array(inner.utf8) + salt))
        return "md5" + outer
    }

    static func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The names Postgres uses, so an unsupported method can say which.
    static func methodName(_ code: Int32) -> String {
        switch code {
        case 2: "Kerberos V5"
        case 6: "SCM credentials"
        case 7: "GSSAPI"
        case 8: "GSSAPI continue"
        case 9: "SSPI"
        default: "authentication method \(code)"
        }
    }
}

public enum PostgresAuthenticationError: Error, Sendable, Equatable {
    /// The server asked for a plaintext password over a link that is not private.
    case insecureCleartextRefused
    case passwordRequired
    case noSupportedMechanism(offered: [String])
    case unsupportedMethod(code: Int32, name: String)
    case unexpectedRequest
    case scram(SCRAMError)
    case malformed(String)
}

extension PostgresAuthenticationError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .insecureCleartextRefused:
            "the server asked for a cleartext password over an unencrypted connection — "
                + "enable TLS, use a unix socket, or configure the server for SCRAM"
        case .passwordRequired:
            "the server asked for a password and none was configured"
        case .noSupportedMechanism(let offered):
            "the server offered only \(offered.joined(separator: ", ")); "
                + "this client implements SCRAM-SHA-256 without channel binding"
        case .unsupportedMethod(_, let name):
            "the server asked for \(name), which this client does not implement"
        case .unexpectedRequest:
            "the server sent an authentication request out of order"
        case .scram(let error): "SCRAM failed: \(error)"
        case .malformed(let reason): reason
        }
    }
}

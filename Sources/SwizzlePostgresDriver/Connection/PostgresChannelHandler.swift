import Foundation
import NIOCore
import NIOTLS

/// Set SWIZZLE_POSTGRES_TRACE=1 to log message flow during the handshake.
let postgresTraceEnabled = ProcessInfo.processInfo.environment["SWIZZLE_POSTGRES_TRACE"] != nil

func postgresTrace(_ message: @autoclosure () -> String) {
    if postgresTraceEnabled { FileHandle.standardError.write(Data((message() + "\n").utf8)) }
}

/// Drives the handshake, then hands the channel over for queries.
///
/// **Read control is wired in from the first commit**, as it was for MySQL. The
/// handshake itself runs with `autoRead` on — a TLS handshake consumes bytes and
/// emits no plaintext, so `channelReadComplete` never fires and a demand-driven
/// pipeline stalls silently — and it is switched off the moment the connection
/// becomes usable, before anything can stream.
final class PostgresChannelHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = PostgresBackendMessage
    typealias OutboundIn = PostgresFrontendMessage
    typealias OutboundOut = PostgresFrontendMessage

    private enum Phase {
        case handshaking
        case established
        case failed
    }

    private let configuration: PostgresConnectionConfiguration
    private var machine: PostgresConnectionStateMachine
    private var phase: Phase = .handshaking
    private let isTLSActive: Bool

    private let readyPromise: EventLoopPromise<PostgresConnectionMetadata>
    private var readyResolved = false
    private var startupSent = false

    init(
        configuration: PostgresConnectionConfiguration,
        isTLSActive: Bool,
        channelBindingData: @escaping @Sendable () -> [UInt8]? = { nil },
        readyPromise: EventLoopPromise<PostgresConnectionMetadata>
    ) {
        self.configuration = configuration
        self.isTLSActive = isTLSActive
        self.readyPromise = readyPromise
        self.machine = PostgresConnectionStateMachine(
            configuration: configuration.authenticationConfiguration(
                isTLSActive: isTLSActive, channelBindingData: channelBindingData
            )
        )
    }

    // MARK: - Lifecycle

    /// When TLS is in play this handler is added *after* the channel is already
    /// active — the negotiation has to finish first, and NIO does not replay
    /// `channelActive` for a late arrival. So the startup is sent from whichever
    /// of the two happens, once.
    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive { sendStartup(context: context) }
    }

    func channelActive(context: ChannelHandlerContext) {
        sendStartup(context: context)
        context.fireChannelActive()
    }

    private func sendStartup(context: ChannelHandlerContext) {
        guard !startupSent else { return }
        startupSent = true
        // **Drive the machine; do not reproduce its output.**
        //
        // This used to build the StartupMessage from the configuration and write
        // it directly. The bytes were identical, so the connection worked — but
        // `start()` is also what moves the state machine into
        // `awaitingAuthentication`, and skipping it left the machine in its
        // initial state. Every authentication request the server then sent was
        // rejected as "out of order", so **SCRAM and MD5 could not authenticate
        // at all**. Only `trust` connected, because trust is the one flow that
        // never sends an authentication request.
        //
        // It survived every test because the fixture ran `--auth=trust`, and the
        // machine's own unit tests called `start()` the way this now does.
        handle(machine.start(), context: context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        failReady(PostgresConnectionError.unexpected(during: "handshake"))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        failReady(error)
        phase = .failed
        context.close(promise: nil)
    }

    // MARK: - Inbound

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)

        guard phase == .handshaking else {
            // Queries belong to the command handler behind this one.
            context.fireChannelRead(data)
            return
        }

        postgresTrace("← \(message)")
        handle(machine.handle(message), context: context)
    }

    private func handle(
        _ action: PostgresConnectionStateMachine.Action, context: ChannelHandlerContext
    ) {
        switch action {
        case .wait:
            break

        case .send(let message):
            send(message, context: context)

        case .ready:
            phase = .established
            // Demand-driven from here: nothing is read until a query or a row
            // stream asks for it.
            _ = context.channel.setOption(.autoRead, value: false)

            do {
                // In front of the command handler so the idle event arrives as an
                // inbound user event. Installed only when asked for: it schedules
                // a repeating task per connection.
                if let readTimeout = configuration.readTimeout {
                    try context.pipeline.syncOperations.addHandler(
                        IdleStateHandler(readTimeout: readTimeout), position: .after(self)
                    )
                }
                try context.pipeline.syncOperations.addHandler(
                    PostgresCommandHandler(
                        statementCacheCapacity: configuration.statementCacheCapacity,
                        readTimeout: configuration.readTimeout
                    ),
                    position: .last
                )
            } catch {
                fail(error, context: context)
                return
            }

            succeedReady(
                PostgresConnectionMetadata(
                    parameters: machine.parameters,
                    backendKey: machine.backendKey.map {
                        PostgresBackendKey(processID: $0.processID, secretKey: $0.secretKey)
                    },
                    transactionStatus: machine.transactionStatus,
                    isTLSActive: isTLSActive,
                    saslMechanism: machine.saslMechanism
                )
            )

        case .fail(let error):
            fail(error, context: context)
        }
    }

    private func send(_ message: PostgresFrontendMessage, context: ChannelHandlerContext) {
        postgresTrace("→ \(message)")
        context.writeAndFlush(wrapOutboundOut(message), promise: nil)
    }

    // MARK: - Promise plumbing

    private func fail(_ error: any Error, context: ChannelHandlerContext) {
        phase = .failed
        failReady(error)
        context.close(promise: nil)
    }

    private func succeedReady(_ metadata: PostgresConnectionMetadata) {
        guard !readyResolved else { return }
        readyResolved = true
        readyPromise.succeed(metadata)
    }

    private func failReady(_ error: any Error) {
        guard !readyResolved else { return }
        readyResolved = true
        readyPromise.fail(error)
    }
}

/// The pair a `CancelRequest` has to quote.
///
/// Kept rather than logged: cancelling a running query requires a **second**
/// connection presenting these exact values, so a driver that discards them
/// cannot cancel anything.
public struct PostgresBackendKey: Sendable, Equatable {
    public let processID: Int32
    public let secretKey: Int32
}

/// What the handshake established about a live connection.
public struct PostgresConnectionMetadata: Sendable {
    /// What the server said about itself.
    ///
    /// Not decoration: `integer_datetimes` and `DateStyle` change how temporals
    /// decode, `server_version` gates syntax, and `TimeZone` changes what a
    /// `timestamptz` means.
    public let parameters: [String: String]
    public let backendKey: PostgresBackendKey?
    public let transactionStatus: PostgresTransactionStatus
    public let isTLSActive: Bool
    /// The SASL mechanism that authenticated, if SASL was used at all.
    /// `SCRAM-SHA-256-PLUS` means channel binding was in force.
    public let saslMechanism: String?

    public var serverVersion: String? { parameters["server_version"] }

    /// True when the server sends temporals as 64-bit microsecond integers, which
    /// every server since 10 does and cannot be made not to.
    public var hasIntegerDatetimes: Bool { parameters["integer_datetimes"] != "off" }

    /// The session's standard-conforming-strings setting, which decides whether
    /// a backslash inside a literal escapes.
    public var standardConformingStrings: Bool {
        parameters["standard_conforming_strings"] != "off"
    }
}

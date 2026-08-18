import Foundation
import NIOCore
import NIOSSL
import NIOTLS

/// Set SWIZZLE_MYSQL_TRACE=1 to log packet flow during the handshake.
let mysqlTraceEnabled = ProcessInfo.processInfo.environment["SWIZZLE_MYSQL_TRACE"] != nil

func mysqlTrace(_ message: @autoclosure () -> String) {
    if mysqlTraceEnabled { FileHandle.standardError.write(Data((message() + "\n").utf8)) }
}

/// Drives the connection handshake, then hands the channel over for commands.
///
/// **Read control is wired in from the first commit.** `autoRead` is disabled on
/// the channel and every read is requested explicitly. This is the capability
/// MySQLNIO lacks and cannot retrofit — its `onRow` callback has no way to say
/// "stop" — and it is the reason this driver exists. Adding it later would mean
/// rewriting the pipeline, so it is here before there is anything to stream.
final class MySQLChannelHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = MySQLPacket
    typealias OutboundIn = MySQLPacket
    typealias OutboundOut = MySQLPacket

    private enum Phase {
        case handshaking
        case established
        case failed
    }

    private let configuration: MySQLConnectionConfiguration
    private var machine: MySQLAuthStateMachine
    private let sessionState: MySQLSessionState
    private var phase: Phase = .handshaking

    /// Next sequence ID to use when writing.
    ///
    /// MySQL requires each client packet to continue the server's sequence, so
    /// this is always `<last received sequence> + 1`. Getting it wrong makes the
    /// server drop the connection with no diagnostic.
    private var sequenceID: UInt8 = 0

    /// Fulfilled when authentication completes, or failed with the reason.
    private let readyPromise: EventLoopPromise<MySQLConnectionMetadata>
    private var readyResolved = false

    /// Set once the pipeline has an active TLS handler, so it is only inserted once.
    private var tlsHandler: NIOSSLClientHandler?
    /// Shared with the two frame handlers, which sit in the pipeline from
    /// connect but stay pass-through until this is switched on.
    private let compressionState: MySQLCompressionState
    private var isCompressionActive = false

    init(
        configuration: MySQLConnectionConfiguration,
        sessionState: MySQLSessionState,
        compressionState: MySQLCompressionState,
        readyPromise: EventLoopPromise<MySQLConnectionMetadata>
    ) {
        self.configuration = configuration
        self.compressionState = compressionState
        self.sessionState = sessionState
        self.readyPromise = readyPromise
        self.machine = MySQLAuthStateMachine(
            configuration: .init(
                username: configuration.username,
                password: configuration.password,
                database: configuration.database,
                isSecureTransport: configuration.address.isSecureTransport,
                tls: configuration.tls,
                allowCleartextPlugin: configuration.allowCleartextPlugin,
                serverPublicKey: configuration.serverPublicKey,
                desiredCapabilities: Self.desiredCapabilities(for: configuration)
            )
        )
    }

    /// Both of these are *opt-in* capability bits, so they are added to the
    /// baseline rather than living in it.
    ///
    /// `CLIENT_LOCAL_FILES` especially: advertising it tells the server it may
    /// ask us for a file, and the safe answer when the feature is off is never
    /// to claim it in the first place. Negotiation intersects with the server,
    /// so requesting compression against a server that lacks it simply yields an
    /// uncompressed connection.
    static func desiredCapabilities(
        for configuration: MySQLConnectionConfiguration
    ) -> MySQLCapabilities {
        var capabilities = configuration.capabilities
        // zlib and zstd are requested with *different* bits. Asking for
        // CLIENT_COMPRESS while meaning zstd gets a zlib stream, which then
        // fails to inflate — so the two are kept strictly apart.
        switch configuration.compression {
        case .disabled: break
        case .zlib: capabilities.insert(.compress)
        case .zstd: capabilities.insert(.zstdCompressionAlgorithm)
        }
        if configuration.localInfile.isEnabled { capabilities.insert(.localFiles) }
        if configuration.reportsMatchedRows { capabilities.insert(.foundRows) }
        // Requesting this is what makes the server send progress reports, and
        // it also changes how error code 0xFFFF is read — so it is only asked
        // for when someone is listening.
        if configuration.onProgress != nil { capabilities.insert(.progressObsolete) }
        return capabilities
    }

    // MARK: - Channel lifecycle

    // Read control, and why it is switched on only at the end of the handshake:
    //
    // Demand-driven reads are the whole reason for this driver — MySQLNIO's
    // push-only `onRow` cannot express backpressure. But the *handshake* must
    // run with `autoRead` on. During a TLS handshake NIOSSL consumes bytes and
    // emits no plaintext, so `channelReadComplete` never reaches this handler,
    // so no follow-up read is ever issued and the handshake stalls silently.
    //
    // So: `autoRead` stays on through connect and auth, then is turned off the
    // moment authentication succeeds — before anything can stream. The command
    // phase is fully demand-driven, which is where it matters.

    func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        failReady(MySQLProtocolError.connectionClosed("connection closed during handshake"))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        failReady(error)
        phase = .failed
        context.close(promise: nil)
    }

    // MARK: - Inbound

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let packet = unwrapInboundIn(data)

        guard phase == .handshaking else {
            // Command phase belongs to a later handler; pass it along.
            mysqlTrace("FWD ← seq=\(packet.sequenceID) len=\(packet.payload.readableBytes)")
            context.fireChannelRead(data)
            return
        }

        mysqlTrace(
            "← seq=\(packet.sequenceID) len=\(packet.payload.readableBytes) "
            + "first=0x\(String(packet.firstByte ?? 0, radix: 16)) state=\(machine.state)"
        )
        sequenceID = packet.sequenceID &+ 1
        handle(machine.receive(packet), context: context)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.fireChannelReadComplete()
    }

    // MARK: - Action handling

    private func handle(_ action: MySQLAuthStateMachine.Action, context: ChannelHandlerContext) {
        switch action {
        case .wait:
            break

        case .startTLS(let negotiated):
            startTLS(negotiated: negotiated, context: context)

        case .sendHandshakeResponse(let authResponse, let pluginName, let negotiated):
            var payload = ByteBuffer()
            MySQLHandshakeResponse41(
                capabilities: effectiveCapabilities(negotiated),
                mariaDBCapabilities: negotiated.mariaDBCapabilities,
                maxPacketSize: UInt32(configuration.maxAllowedPacket),
                characterSet: configuration.characterSet,
                username: configuration.username,
                authResponse: authResponse,
                database: configuration.database,
                authPluginName: pluginName,
                connectAttributes: configuration.connectAttributes
            ).serialize(into: &payload)
            write(payload, context: context)

        case .sendAuthData(let bytes):
            var payload = ByteBuffer()
            payload.writeBytes(bytes)
            write(payload, context: context)

        case .requestPublicKey:
            var payload = ByteBuffer()
            payload.writeInteger(UInt8(0x02), endianness: .little)
            write(payload, context: context)

        case .sendCleartextPassword(let bytes):
            var payload = ByteBuffer()
            payload.writeBytes(bytes)
            write(payload, context: context)

        case .encryptAndSend(let plaintext, let publicKeyPEM):
            do {
                let ciphertext = try MySQLRSA.encrypt(plaintext, publicKeyPEM: publicKeyPEM)
                var payload = ByteBuffer()
                payload.writeBytes(ciphertext)
                write(payload, context: context)
            } catch {
                fail(error, context: context)
            }

        case .authenticated(let ok):
            phase = .established
            sessionState.update(ok.statusFlags)
            // Hand the connection over demand-driven: from here nothing is read
            // until a command or a row stream asks for it.
            _ = context.channel.setOption(.autoRead, value: false)

            // Compression starts *after* authentication, not when the capability
            // is agreed: the whole handshake, including this OK packet, is
            // uncompressed. Enabling it a step early is a silent desync, because
            // a compressed frame header parses as a plausible packet header.
            let negotiatedZlib = machine.negotiated.capabilities.contains(.compress)
            let negotiatedZstd = machine.negotiated.capabilities.contains(.zstdCompressionAlgorithm)
            if configuration.compression.isEnabled, negotiatedZlib || negotiatedZstd {
                // Honour what was actually negotiated, not what was asked for: a
                // server that lacks zstd simply does not set the bit, and
                // compressing with an algorithm the peer did not agree to is
                // indistinguishable from corruption.
                let useZstd = configuration.compression.isZstd && negotiatedZstd
                compressionState.enable(
                    level: configuration.compression.level, zstd: useZstd
                )
                isCompressionActive = true
                mysqlTrace("   compression enabled (\(useZstd ? "zstd" : "zlib"))")
            }

            // Added only now, because it needs the negotiated capabilities —
            // DEPRECATE_EOF in particular changes how a result set terminates.
            do {
                try context.pipeline.syncOperations.addHandler(
                    MySQLCommandHandler(
                        capabilities: machine.negotiated.capabilities,
                        sessionState: sessionState,
                        localInfile: configuration.localInfile,
                        onProgress: configuration.onProgress,
                        readTimeout: configuration.readTimeout
                    ),
                    position: .last
                )
            } catch {
                fail(error, context: context)
                return
            }

            succeedReady(
                MySQLConnectionMetadata(
                    capabilities: machine.negotiated.capabilities,
                    mariaDBCapabilities: machine.negotiated.mariaDBCapabilities,
                    isMariaDB: machine.negotiated.isMariaDB,
                    isTLSActive: machine.isTLSActive,
                    isCompressionActive: isCompressionActive,
                    statusFlags: ok.statusFlags,
                    authPlugin: machine.plugin,
                    scramble: machine.nonce,
                    characterSet: configuration.characterSet,
                    connectionID: machine.connectionID
                )
            )

        case .fail(let error):
            fail(error, context: context)
        }
    }

    /// The single source of truth for the capability word, used by both the
    /// SSLRequest and the handshake response so they cannot drift apart.
    private func effectiveCapabilities(
        _ negotiated: MySQLNegotiatedCapabilities
    ) -> MySQLCapabilities {
        MySQLHandshakeResponse41.effectiveCapabilities(
            negotiated.capabilities,
            database: configuration.database,
            authPluginName: machine.plugin.name,
            hasConnectAttributes: !configuration.connectAttributes.isEmpty
        )
    }

    private func write(
        _ payload: ByteBuffer,
        context: ChannelHandlerContext,
        promise: EventLoopPromise<Void>? = nil
    ) {
        let packet = MySQLPacket(sequenceID: sequenceID, payload: payload)
        mysqlTrace(
            "→ seq=\(packet.sequenceID) len=\(payload.readableBytes) "
            + "head=\(payload.getBytes(at: payload.readerIndex, length: min(12, payload.readableBytes))?.map { String(format: "%02x", $0) }.joined(separator: " ") ?? "")"
        )
        sequenceID &+= 1
        context.writeAndFlush(wrapOutboundOut(packet), promise: promise)
    }

    // MARK: - TLS

    private func startTLS(
        negotiated: MySQLNegotiatedCapabilities, context: ChannelHandlerContext
    ) {
        // The SSLRequest itself goes out in the clear — it carries no secrets,
        // only the capability flags telling the server to switch.
        //
        // The write must *complete* before NIOSSL is inserted. Inserting it
        // first would place it closer to the head than this handler, so a
        // still-queued SSLRequest would be encrypted on its way out and the
        // server would reject it with "Bad handshake" (error 1043).
        var payload = ByteBuffer()
        MySQLSSLRequest(
            // Must match the handshake response exactly — see
            // `effectiveCapabilities`. A single differing bit yields
            // "Bad handshake" from a server that has already committed to
            // whatever this packet declared.
            capabilities: effectiveCapabilities(negotiated),
            mariaDBCapabilities: negotiated.mariaDBCapabilities,
            maxPacketSize: UInt32(configuration.maxAllowedPacket),
            characterSet: configuration.characterSet
        ).serialize(into: &payload)

        let written = context.eventLoop.makePromise(of: Void.self)
        write(payload, context: context, promise: written)

        written.futureResult.whenComplete { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                self.fail(error, context: context)
                return
            }
            do {
                // ── Why the shutdown timeout is shortened ──────────────────
                //
                // NIOSSL's graceful close sends `close_notify` and then waits for
                // the peer's, defaulting to **five seconds**. MySQL servers do
                // not send one: they answer `COM_QUIT` by closing the socket, so
                // the wait is for something that is never coming.
                //
                // Measured, on the MariaDB fixture: a TLS close took 5.0012s and
                // a plaintext close 0.0001s. Every finished TLS connection held a
                // socket, a server-side session and a pool slot for five seconds
                // after it was done with — and a `close()` that returns in five
                // seconds looks exactly like a hang.
                //
                // Short rather than zero, so a peer that *does* reciprocate still
                // gets a clean shutdown.
                var tlsConfiguration = self.configuration.tlsConfiguration
                tlsConfiguration.shutdownTimeout = self.configuration.tlsShutdownTimeout

                // The mode decides verification, overriding whatever the supplied
                // `tlsConfiguration` said, because the mode is the more specific
                // statement of intent: `require` means encrypt-don't-authenticate
                // and would otherwise reject self-signed servers that
                // `--ssl-mode=REQUIRED` accepts, while `verify_ca` must not be
                // silently downgraded by the default configuration's disabled
                // verification.
                if self.configuration.tls.verifiesHostname {
                    tlsConfiguration.certificateVerification = .fullVerification
                } else if self.configuration.tls.verifiesCertificate {
                    tlsConfiguration.certificateVerification = .noHostnameVerification
                } else {
                    tlsConfiguration.certificateVerification = .none
                }

                let sslContext = try NIOSSLContext(configuration: tlsConfiguration)
                let serverName = self.configuration.tlsServerName ?? self.configuration.hostname
                let sniName = serverName.flatMap { self.isIPAddress($0) ? nil : $0 }
                let handler = try NIOSSLClientHandler(context: sslContext, serverHostname: sniName)
                self.tlsHandler = handler

                // Inserted *before* the packet decoder: from here on everything
                // on the wire is ciphertext and must be decrypted before framing.
                try context.pipeline.syncOperations.addHandler(handler, position: .first)
                mysqlTrace("   TLS handler inserted (sni=\(sniName ?? "nil"))")
            } catch {
                self.fail(error, context: context)
            }
        }
    }

    /// NIOSSL reports handshake completion as an inbound user event rather than
    /// a future, so completion is picked up here.
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        mysqlTrace("   user event: \(event)")
        if let tlsEvent = event as? TLSUserEvent, case .handshakeCompleted = tlsEvent,
           phase == .handshaking {
            handle(machine.tlsEstablished(), context: context)
        }
        context.fireUserInboundEventTriggered(event)
    }

    /// An IP literal is not a valid SNI name and NIOSSL rejects it outright, so
    /// it is omitted rather than sent.
    private func isIPAddress(_ candidate: String) -> Bool {
        (try? SocketAddress(ipAddress: candidate, port: 0)) != nil
    }

    // MARK: - Promise plumbing

    private func fail(_ error: any Error, context: ChannelHandlerContext) {
        phase = .failed
        failReady(error)
        context.close(promise: nil)
    }

    private func succeedReady(_ metadata: MySQLConnectionMetadata) {
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

/// What the handshake established about a live connection.
public struct MySQLConnectionMetadata: Sendable {
    public let capabilities: MySQLCapabilities
    public let mariaDBCapabilities: MySQLCapabilities
    public let isMariaDB: Bool
    public let isTLSActive: Bool
    /// True when the compressed wire protocol is in effect. Distinct from the
    /// capability bit: the capability may be negotiated and the feature still
    /// off if the caller did not ask for it.
    public let isCompressionActive: Bool
    public let statusFlags: MySQLStatusFlags
    /// The plugin that authenticated this connection. `COM_CHANGE_USER` has to
    /// answer with the same one.
    public let authPlugin: MySQLAuthPlugin
    /// The handshake scramble, which `COM_CHANGE_USER` reuses rather than
    /// receiving a fresh one.
    public let scramble: [UInt8]
    public let characterSet: UInt8
    /// The server's connection id — the same value `SHOW PROCESSLIST` reports,
    /// which makes a pooled connection traceable to a server-side session.
    public let connectionID: UInt32

    /// True when the server runs in `ANSI_QUOTES` mode, where `"` is an
    /// identifier quote rather than a string delimiter.
    ///
    /// This matters beyond the driver: `SwizzleCore`'s renderer hardcodes a
    /// backtick for MySQL, so a query generated for an `ANSI_QUOTES` server
    /// could parse as something else rather than erroring. See
    /// `docs/mysql-protocol-checklist.md`.
    public var isANSIQuotes: Bool { statusFlags.contains(.ansiQuotes) }
}

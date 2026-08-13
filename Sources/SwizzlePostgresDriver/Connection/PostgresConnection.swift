import NIOCore
import NIOPosix
import NIOSSL
import SwizzleConnectionPool
import SwizzleCore

/// One authenticated connection to a Postgres server.
public final class PostgresConnection: Sendable {

    public let id: Int
    let channel: any Channel
    public let metadata: PostgresConnectionMetadata

    init(id: Int, channel: any Channel, metadata: PostgresConnectionMetadata) {
        self.id = id
        self.channel = channel
        self.metadata = metadata
    }

    public var isActive: Bool { channel.isActive }

    /// The pair a `CancelRequest` has to quote, if the server sent one.
    public var backendKey: PostgresBackendKey? { metadata.backendKey }

    // MARK: - Connecting

    /// Opens a connection and completes the handshake.
    ///
    /// The returned connection is authenticated; a failure here means the channel
    /// is already closed.
    public static func connect(
        configuration: PostgresConnectionConfiguration,
        id: Int = 0,
        on eventLoop: any EventLoop
    ) async throws -> PostgresConnection {
        let readyPromise = eventLoop.makePromise(of: PostgresConnectionMetadata.self)
        let attemptsTLS = configuration.tlsMode.attemptsTLS
        // Filled during the TLS handshake, read when the server asks for SASL.
        let capture = PostgresCertificateCapture()
        let tlsPromise = eventLoop.makePromise(of: PostgresTLSNegotiation.self)

        let bootstrap = ClientBootstrap(group: eventLoop)
            .connectTimeout(configuration.connectTimeout)
            .channelInitializer { channel in
                do {
                    if attemptsTLS {
                        // Only the negotiator, for now. Adding the rest here
                        // would let the handshake's StartupMessage go out in the
                        // clear before TLS was up — which is not a subtle bug so
                        // much as an entire absence of encryption.
                        try channel.pipeline.syncOperations.addHandler(
                            PostgresTLSNegotiationHandler(
                                mode: configuration.tlsMode,
                                negotiated: tlsPromise,
                                makeTLSHandler: {
                                    try Self.makeTLSHandler(
                                        configuration: configuration, capture: capture
                                    )
                                }
                            )
                        )
                    } else {
                        tlsPromise.succeed(.refused)
                        try Self.addProtocolHandlers(
                            to: channel, configuration: configuration,
                            isTLSActive: false, readyPromise: readyPromise
                        )
                    }
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        let channel: any Channel
        do {
            switch configuration.address {
            case .tcp(let host, let port):
                channel = try await bootstrap.connect(host: host, port: port).get()
            case .unixSocketDirectory:
                guard let path = configuration.address.socketPath else {
                    throw PostgresConnectionError.unexpected(during: "resolving the socket path")
                }
                channel = try await bootstrap.connect(unixDomainSocketPath: path).get()
            }
        } catch {
            // Nothing will ever fulfil these if the connect itself failed.
            tlsPromise.fail(error)
            readyPromise.fail(error)
            throw error
        }

        // Whether `readyPromise` has been handed to something that will complete
        // it. Until the protocol handlers are in the pipeline, nothing will —
        // and a promise that is dropped uncompleted is a `fatalError` in a debug
        // build of NIO, not a leak you find later.
        //
        // The reachable case is a **failed TLS handshake**: the TCP connect
        // succeeds, so the outer `catch` above does not run, and then
        // `tlsPromise` fails with the verification error while `readyPromise`
        // sits unowned. Untrusted certificates became far more reachable when
        // the default became `verify-full`, and this crashed the process rather
        // than throwing.
        var readyPromiseIsOwned = false
        do {
            if attemptsTLS {
                let outcome = try await tlsPromise.futureResult.get()
                // Now, and only now, is it safe to speak the protocol.
                try await channel.eventLoop.submit {
                    try Self.addProtocolHandlers(
                        to: channel, configuration: configuration,
                        isTLSActive: outcome == .accepted,
                        // Nil when the handshake produced no certificate, which
                        // is a different statement from "the server did not
                        // offer -PLUS" and drives a different gs2 header.
                        // A closure, not a value: the certificate arrives during the
                        // handshake, which has not happened yet.
                        channelBindingData: { outcome == .accepted ? capture.bindingData : nil },
                        readyPromise: readyPromise
                    )
                }.get()
            }

            // From here the handlers own it, so a later failure is *their*
            // failure arriving through the promise — failing it again would
            // complete it twice, which traps just as loudly.
            readyPromiseIsOwned = true
            let metadata = try await readyPromise.futureResult.get()
            return PostgresConnection(id: id, channel: channel, metadata: metadata)
        } catch {
            if !readyPromiseIsOwned { readyPromise.fail(error) }
            try? await channel.close().get()
            throw error
        }
    }

    private static func addProtocolHandlers(
        to channel: any Channel,
        configuration: PostgresConnectionConfiguration,
        isTLSActive: Bool,
        channelBindingData: @escaping @Sendable () -> [UInt8]? = { nil },
        readyPromise: EventLoopPromise<PostgresConnectionMetadata>
    ) throws {
        try channel.pipeline.syncOperations.addHandlers([
            ByteToMessageHandler(
                PostgresMessageDecoder(maximumMessageSize: configuration.maximumMessageSize)
            ),
            MessageToByteHandler(PostgresMessageEncoder()),
            PostgresChannelHandler(
                configuration: configuration,
                isTLSActive: isTLSActive,
                channelBindingData: channelBindingData,
                readyPromise: readyPromise
            ),
        ])
    }

    private static func makeTLSHandler(
        configuration: PostgresConnectionConfiguration,
        capture: PostgresCertificateCapture
    ) throws -> NIOSSLClientHandler {
        var tlsConfiguration = configuration.tlsConfiguration
        // `require` means encrypt, not authenticate. Leaving verification on
        // would make it behave as `verify-ca` and reject servers libpq accepts —
        // the mode's whole meaning is that the certificate is not checked.
        if !configuration.tlsMode.verifiesCertificate {
            // Left at the default when channel binding needs a callback: the
            // callback replaces verification entirely, and `.none` would make
            // NIOSSL skip calling it.
            // `.noHostnameVerification` rather than `.none`: the custom callback
            // below replaces chain verification, but `.none` makes NIOSSL skip
            // calling it at all — and the default would still check the hostname
            // against a certificate `require` says not to trust.
            tlsConfiguration.certificateVerification =
                configuration.channelBinding == .disabled ? .none : .noHostnameVerification
        } else if !configuration.tlsMode.verifiesHostname {
            tlsConfiguration.certificateVerification = .noHostnameVerification
        }
        // Postgres answers `Terminate` by closing the socket rather than sending
        // `close_notify`, so NIOSSL's five-second default is five seconds spent
        // waiting for something that is not coming. See the configuration
        // property for the measurement that prompted this.
        tlsConfiguration.shutdownTimeout = configuration.tlsShutdownTimeout

        let sslContext = try NIOSSLContext(configuration: tlsConfiguration)
        let serverName = configuration.tlsServerName ?? configuration.address.host
        // An IP literal is not a valid SNI name and NIOSSL rejects it outright,
        // so it is omitted rather than sent.
        let sniName = serverName.flatMap { isIPAddress($0) ? nil : $0 }

        guard configuration.channelBinding != .disabled else {
            return try NIOSSLClientHandler(context: sslContext, serverHostname: sniName)
        }

        // With `sslmode=require` the certificate is deliberately not verified, and
        // NIOSSL's *additional* verification hook refuses to run in that mode —
        // it asserts that verification is enabled.
        //
        // So that case takes the custom callback instead, which returns
        // `.certificateVerified` unconditionally. That is not a weakening: it is
        // exactly what `.none` already does. Channel binding still means something
        // here — arguably it means the most here — because binding to whatever
        // certificate the peer presented is what catches a relay that `require`
        // would otherwise wave through.
        guard configuration.tlsMode.verifiesCertificate else {
            return try NIOSSLClientHandler(
                context: sslContext,
                serverHostname: sniName,
                customVerificationCallback: { certificates, promise in
                    if let leaf = certificates.first { capture.store(leaf) }
                    promise.succeed(.certificateVerified)
                }
            )
        }

        // ── Capturing the peer certificate ───────────────────────────────────
        //
        // Channel binding needs the server's certificate, and `NIOSSLCertificate`
        // is not reachable from a plain handler. This hook runs **in addition to**
        // NIOSSL's own verification rather than replacing it — which matters:
        // the `customVerificationCallback` alternative would hand us the chain and
        // make certificate validation our problem, and a driver that
        // reimplements chain validation is a driver that gets it wrong.
        //
        // It is underscored, so it is not covered by NIOSSL's API stability
        // promise. That is a real cost, taken deliberately: the alternative is no
        // channel binding at all, and it fails at compile time if the API moves
        // rather than silently degrading.
        return try NIOSSLClientHandler._makeSSLClientHandler(
            context: sslContext,
            serverHostname: sniName,
            additionalPeerCertificateVerificationCallback: { certificate, channel in
                // The leaf is what RFC 5929 binds to — the chain above it is the
                // CA's business and is not what the peer proves possession of.
                capture.store(certificate)
                return channel.eventLoop.makeSucceededVoidFuture()
            }
        )
    }

    private static func isIPAddress(_ candidate: String) -> Bool {
        (try? SocketAddress(ipAddress: candidate, port: 0)) != nil
    }

    // MARK: - Statements

    /// The user-defined types this connection has resolved.
    ///
    /// Per connection rather than shared, because an OID means different things
    /// in different databases and a pool may span several.
    public let typeRegistry = PostgresTypeRegistry()

    /// Runs a statement, then resolves any user-defined types in the result and
    /// decodes the affected columns again.
    ///
    /// ## Why a second pass rather than resolving up front
    ///
    /// The column OIDs are not known until `RowDescription` arrives, which is
    /// after the rows. Resolving first would need an extra round trip on *every*
    /// query to ask about types most of them do not use; resolving after costs
    /// nothing for the common case and one round trip the first time a
    /// user-defined type is actually seen. After that the registry answers.
    ///
    /// The re-decode is why the raw bytes are kept on the result: a value cannot
    /// be un-decoded once it has become a `.blob`.
    public func queryResolvingTypes(
        _ sql: String, _ bindings: [SQLValue] = []
    ) async throws -> PostgresQueryResult {
        var result = try await query(sql, bindings)

        let unresolved = result.columns.map(\.dataTypeOID).filter {
            PostgresOID(rawValue: $0) == nil && typeRegistry.known($0) == nil
        }
        guard !unresolved.isEmpty else { return result }

        try await typeRegistry.resolve(unresolved, on: self)
        result.redecode(with: typeRegistry)
        return result
    }

    /// Runs a statement and collects its result.
    public func query(_ sql: String, _ bindings: [SQLValue] = []) async throws
        -> PostgresQueryResult
    {
        let mode: PostgresQueryStateMachine.Mode = bindings.isEmpty
            // No parameters means the simple protocol is available, and it costs
            // one round trip instead of four. Multi-statement SQL only works
            // here, which is what migrations need.
            ? .simple(sql)
            : .extended(sql: sql, bindings: try encode(bindings))
        return try await dispatch { .query(mode, $0) }
    }

    /// Runs a statement and reports how many rows it changed.
    ///
    /// Read from the command tag, which is the only place the number exists.
    /// Draining rows and counting them — the shape the borrowed driver forced —
    /// returns zero for every `UPDATE` and `DELETE`, because they send none.
    @discardableResult
    public func execute(_ sql: String, _ bindings: [SQLValue] = []) async throws -> Int {
        try await query(sql, bindings).affectedRows ?? 0
    }

    /// Runs a statement and delivers rows as they arrive.
    ///
    /// Returns once the columns are known — before the first row — so iteration
    /// can begin while the server is still producing.
    public func stream(_ sql: String, _ bindings: [SQLValue] = []) async throws
        -> PostgresRowSequence
    {
        let encoded = try encode(bindings)
        return try await dispatch { .stream(sql: sql, bindings: encoded, maxRows: 0, $0) }
    }

    /// Asks the server for a statement's shape **without running it**.
    ///
    /// The capability this driver was written for. A generator that had to
    /// execute the statements it analysed would delete rows to discover what
    /// `DELETE` returns.
    public func describe(_ sql: String) async throws -> PostgresStatementDescription {
        try await dispatch { .describe(sql, $0) }
    }

    /// Makes a promise, builds the request around it, sends, and waits.
    ///
    /// ## Why this is one function rather than four copies
    ///
    /// The four copies each did `makePromise` and *then* `try await send(…)`, and
    /// `send` throws when the connection is already closed. A promise created and
    /// never fulfilled is not a leak NIO tolerates: it trips a `fatalError` in
    /// debug builds — **"leaking promise created at …"** — so a query on a closed
    /// connection took the process down rather than throwing.
    ///
    /// It surfaced once in roughly six full test runs, because it needs a
    /// connection to die between the caller deciding to use it and the write
    /// going out. Here the promise is failed on the way out of every throwing
    /// path, so the ordering stops mattering.
    func dispatch<Result: Sendable>(
        _ makeRequest: (EventLoopPromise<Result>) -> PostgresRequest
    ) async throws -> Result {
        let promise = channel.eventLoop.makePromise(of: Result.self)
        let request = makeRequest(promise)

        guard channel.isActive else {
            let error = PostgresConnectionError.unexpected(during: "a closed connection")
            promise.fail(error)
            throw error
        }

        do {
            try await channel.writeAndFlush(request).get()
        } catch {
            // The write never reached the command handler, so nothing else will
            // ever fulfil this.
            promise.fail(error)
            throw error
        }

        return try await promise.futureResult.get()
    }

    /// Values become wire bytes here rather than SQL text, so a binding can never
    /// be an injection — there is no text for it to escape out of.
    func encode(_ bindings: [SQLValue]) throws -> [[UInt8]?] {
        bindings.map(PostgresValueEncoder.encode)
    }

    // MARK: - Lifecycle

    /// Says goodbye, then closes.
    public func shutdown() async throws {
        guard channel.isActive else { return }
        // `Terminate` is a courtesy that lets the server log a clean disconnect
        // rather than a lost connection. Its failure is not worth reporting —
        // the channel is going away either way.
        let sent = channel.eventLoop.makePromise(of: Void.self)
        do {
            try await channel.writeAndFlush(PostgresRequest.terminate(sent)).get()
        } catch {
            // `try?` here would swallow the failure *and* strand the promise,
            // which NIO turns into a `fatalError` rather than a leak. Failing it
            // explicitly is the difference between a quiet goodbye that did not
            // get through and a crash on the way out.
            sent.fail(error)
        }
        try await channel.close()
    }

    public func closeImmediately() {
        channel.close(promise: nil)
    }

    /// Waits until the channel is actually closed.
    ///
    /// The distinction matters when a connection is going back to a pool: closing
    /// is asynchronous, so "I asked it to close" and "it is closed" are different
    /// facts, and handing the pool a connection between the two is how the next
    /// borrower ends up with a dead socket.
    func waitForClose() async {
        try? await channel.closeFuture.get()
    }
}

extension PostgresConnection: PooledConnection {
    public typealias ID = Int

    public func onClose(_ closure: @escaping @Sendable ((any Error)?) -> Void) {
        channel.closeFuture.whenComplete { _ in closure(nil) }
    }

    /// The pool's close is synchronous and cannot wait for a goodbye, so this is
    /// the abrupt one. `shutdown()` is the polite version for a connection a
    /// caller owns outright.
    public func close() {
        channel.close(promise: nil)
    }
}

import NIOCore
import NIOPosix
import NIOSSL

/// Cancels a query running on another connection.
///
/// ## Why this needs a second connection
///
/// Postgres has no in-band cancel. The connection running the query is busy
/// producing results and will not read anything until it is done, so a cancel
/// sent down it would sit in the receive buffer being ignored — which is exactly
/// the case where cancelling matters.
///
/// So cancellation opens a **fresh** connection, sends a `CancelRequest` quoting
/// the target's process id and secret key, and closes. There is no handshake, no
/// authentication, and no reply: the secret key *is* the authorisation, which is
/// why `BackendKeyData` has to be retained rather than logged and discarded.
///
/// The server answers by raising `57014` — *canceling statement due to user
/// request* — on the target connection, which maps to `.timeout` in the error
/// taxonomy, the same as `statement_timeout`.
public enum PostgresCancellation {

    /// Sends a `CancelRequest` and closes.
    ///
    /// Best-effort by design, and by the protocol's design: the server may have
    /// finished the query before the request lands, and it sends nothing back
    /// either way. A caller that treats this as "the query has stopped" rather
    /// than "the server has been asked" will be wrong some of the time.
    public static func cancel(
        backendKey: PostgresBackendKey,
        configuration: PostgresConnectionConfiguration,
        on eventLoop: any EventLoop
    ) async throws {
        let bootstrap = ClientBootstrap(group: eventLoop)
            .channelInitializer { channel in
                channel.eventLoop.makeSucceededVoidFuture()
            }

        let channel: any Channel
        switch configuration.address {
        case .tcp(let host, let port):
            channel = try await bootstrap.connect(host: host, port: port).get()
        case .unixSocketDirectory:
            guard let path = configuration.address.socketPath else {
                throw PostgresConnectionError.unexpected(during: "resolving the socket path")
            }
            channel = try await bootstrap.connect(unixDomainSocketPath: path).get()
        }

        defer { channel.close(promise: nil) }

        // No TLS, and deliberately so.
        //
        // The `CancelRequest` carries no credentials and no query text — only two
        // opaque integers the server itself issued — so there is nothing in it for
        // an eavesdropper. libpq negotiates TLS here anyway when configured to;
        // the cost is a full handshake to protect eight bytes of nothing, on the
        // path that is by definition already in a hurry.
        var buffer = channel.allocator.buffer(capacity: 16)
        PostgresFrontendMessage.cancelRequest(
            processID: backendKey.processID, secretKey: backendKey.secretKey
        ).encode(into: &buffer)

        try await channel.writeAndFlush(buffer).get()
    }
}

extension PostgresConnection {
    /// Asks the server to cancel whatever this connection is running.
    ///
    /// Returns as soon as the request is sent. The statement fails with `57014`
    /// on the connection that was running it — `.timeout` in the shared taxonomy,
    /// the same kind `statement_timeout` produces, because from a caller's side
    /// they are the same event.
    ///
    /// Throws if the server never sent a `BackendKeyData`, which would make
    /// cancellation impossible rather than merely unsuccessful.
    public func cancelRunningQuery(
        configuration: PostgresConnectionConfiguration
    ) async throws {
        guard let key = backendKey else {
            throw PostgresConnectionError.unexpected(during: "cancellation without a backend key")
        }
        try await PostgresCancellation.cancel(
            backendKey: key, configuration: configuration, on: channel.eventLoop
        )
    }
}

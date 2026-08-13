import NIOCore

/// Decodes a `COM_STMT_PREPARE` response.
///
/// The shape differs from a result set: a 12-byte header, then the *parameter*
/// column definitions, then the *result* column definitions, each list closed by
/// an EOF when `DEPRECATE_EOF` was not negotiated. Both lists can be empty —
/// `INSERT ... VALUES (?)` has one parameter and no result columns, `SELECT 1`
/// the reverse — and the empty cases are where off-by-one state bugs hide.
public struct MySQLPrepareStateMachine: Sendable {

    public enum Action: Sendable, Equatable {
        case wait
        case prepared(
            MySQLPrepareOK,
            parameters: [MySQLColumnDefinition],
            columns: [MySQLColumnDefinition]
        )
        case fail(MySQLProtocolError)
    }

    enum State: Sendable, Equatable {
        case awaitingHeader
        case awaitingParameters(remaining: Int)
        case awaitingParameterEOF
        case awaitingColumns(remaining: Int)
        case awaitingColumnEOF
        case done
        case failed
    }

    private(set) var state: State = .awaitingHeader
    private var header: MySQLPrepareOK?
    private var parameters: [MySQLColumnDefinition] = []
    private var columns: [MySQLColumnDefinition] = []

    let capabilities: MySQLCapabilities

    public init(capabilities: MySQLCapabilities) {
        self.capabilities = capabilities
    }

    public mutating func receive(_ packet: MySQLPacket) -> Action {
        var buffer = packet.payload

        if packet.firstByte == 0xFF, state == .awaitingHeader {
            do {
                let error = try MySQLErrorPacket.parse(&buffer, capabilities: capabilities)
                return fail(error.asProtocolError)
            } catch let error as MySQLProtocolError {
                return fail(error)
            } catch {
                return fail(.malformedPacket("\(error)"))
            }
        }

        switch state {
        case .awaitingHeader:
            do {
                let parsed = try MySQLPrepareOK.parse(&buffer)
                header = parsed
                parameters.reserveCapacity(Int(parsed.parameterCount))
                columns.reserveCapacity(Int(parsed.columnCount))
                return advanceAfterHeader(parsed)
            } catch let error as MySQLProtocolError {
                return fail(error)
            } catch {
                return fail(.malformedPacket("\(error)"))
            }

        case .awaitingParameters(let remaining):
            do {
                parameters.append(try MySQLColumnDefinition.parse(&buffer))
            } catch let error as MySQLProtocolError {
                return fail(error)
            } catch {
                return fail(.malformedPacket("\(error)"))
            }
            if remaining - 1 > 0 {
                state = .awaitingParameters(remaining: remaining - 1)
                return .wait
            }
            return finishedParameters()

        case .awaitingParameterEOF:
            guard MySQLEOFPacket.isEOF(packet) else {
                return fail(.unexpectedPacket("expected EOF after parameter definitions"))
            }
            return startColumns()

        case .awaitingColumns(let remaining):
            do {
                columns.append(try MySQLColumnDefinition.parse(&buffer))
            } catch let error as MySQLProtocolError {
                return fail(error)
            } catch {
                return fail(.malformedPacket("\(error)"))
            }
            if remaining - 1 > 0 {
                state = .awaitingColumns(remaining: remaining - 1)
                return .wait
            }
            return finishedColumns()

        case .awaitingColumnEOF:
            guard MySQLEOFPacket.isEOF(packet) else {
                return fail(.unexpectedPacket("expected EOF after column definitions"))
            }
            return complete()

        case .done, .failed:
            return fail(.unexpectedPacket("packet received after prepare finished"))
        }
    }

    // MARK: - Transitions

    private mutating func advanceAfterHeader(_ header: MySQLPrepareOK) -> Action {
        if header.parameterCount > 0 {
            state = .awaitingParameters(remaining: Int(header.parameterCount))
            return .wait
        }
        return startColumns()
    }

    private mutating func finishedParameters() -> Action {
        if capabilities.contains(.deprecateEOF) {
            return startColumns()
        }
        state = .awaitingParameterEOF
        return .wait
    }

    private mutating func startColumns() -> Action {
        guard let header else { return fail(.malformedPacket("prepare header missing")) }
        if header.columnCount > 0 {
            state = .awaitingColumns(remaining: Int(header.columnCount))
            return .wait
        }
        return complete()
    }

    private mutating func finishedColumns() -> Action {
        if capabilities.contains(.deprecateEOF) {
            return complete()
        }
        state = .awaitingColumnEOF
        return .wait
    }

    private mutating func complete() -> Action {
        guard let header else { return fail(.malformedPacket("prepare header missing")) }
        state = .done
        return .prepared(header, parameters: parameters, columns: columns)
    }

    private mutating func fail(_ error: MySQLProtocolError) -> Action {
        state = .failed
        return .fail(error)
    }
}

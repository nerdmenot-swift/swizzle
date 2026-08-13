import NIOCore

/// Decodes a command response: OK, error, or a result set.
///
/// Pure — packets in, actions out — for the same reason as the auth machine:
/// the awkward cases (multi-resultset from a stored procedure, EOF-vs-OK
/// ambiguity, a server that omits DEPRECATE_EOF) become ordinary unit tests.
///
/// Emits rows **one at a time** rather than accumulating them. Phase 2 only
/// buffers, but shaping it this way now means Phase 5 streaming plugs in
/// without a rewrite.
public struct MySQLResultSetStateMachine: Sendable {

    public enum Action: Sendable, Equatable {
        /// Keep reading; nothing to report yet.
        case wait
        /// Command finished with no result set — INSERT, UPDATE, DDL.
        case finishedWithoutRows(MySQLOKPacket)
        /// Column metadata complete; rows follow.
        case columns([MySQLColumnDefinition])
        case row(MySQLRow)
        /// Result set finished and nothing more follows.
        case finished(MySQLOKPacket)
        /// A MariaDB progress update for a long-running statement.
        ///
        /// Purely informational and does **not** advance the result set — the
        /// same state is still expecting whatever it was expecting before.
        case progress(MySQLProgressReport)
        /// The server is asking for a local file (`LOAD DATA LOCAL INFILE`).
        ///
        /// The path comes from the **server**, so acting on it is gated on the
        /// caller's allow-list. Either way the transfer must be terminated with
        /// an empty packet and the server's reply consumed — see the command
        /// handler.
        case sendLocalFile(path: String)
        /// Result set finished but `SERVER_MORE_RESULTS_EXISTS` is set, so
        /// another one starts with the next packet. A stored procedure always
        /// produces at least one extra set carrying its status — mishandling
        /// this is MySQLNIO's open crash #118.
        case finishedWithMoreResults(MySQLOKPacket)
        case fail(MySQLProtocolError)
    }

    enum State: Sendable, Equatable {
        case awaitingFirstPacket
        case awaitingColumns(remaining: Int)
        /// Only reachable when DEPRECATE_EOF was **not** negotiated.
        case awaitingColumnListEOF
        case awaitingRows
        /// The file (or the bare terminator) has been sent; an OK or ERR follows.
        case awaitingLocalInfileResult
        case done
        case failed
    }

    private(set) var state: State = .awaitingFirstPacket
    private var columns: [MySQLColumnDefinition] = []
    private var collectedColumns: [MySQLColumnDefinition] = []

    /// Which wire format the rows use.
    ///
    /// `COM_QUERY` returns text rows; `COM_STMT_EXECUTE` returns binary rows.
    /// Everything else about the result set — column definitions, terminators,
    /// multi-resultset — is identical, which is why this is a mode rather than
    /// a second state machine.
    public enum RowFormat: Sendable { case text, binary }

    let capabilities: MySQLCapabilities
    let rowFormat: RowFormat

    public init(
        capabilities: MySQLCapabilities,
        rowFormat: RowFormat = .text,
        knownColumns: [MySQLColumnDefinition]? = nil
    ) {
        self.capabilities = capabilities
        self.rowFormat = rowFormat
        // A `COM_STMT_FETCH` reply is rows and a terminator only — the column
        // definitions came with the original `COM_STMT_EXECUTE`, so the machine
        // starts mid-result-set rather than expecting a header.
        if let knownColumns {
            self.columns = knownColumns
            self.state = .awaitingRows
        }
    }

    /// Built once when the first row arrives and shared by every row of this
    /// result set — see `MySQLRowSchema` for why rows must not each carry their
    /// own column list.
    private var cachedSchema: MySQLRowSchema?

    private mutating func rowSchema() -> MySQLRowSchema {
        if let cachedSchema { return cachedSchema }
        let schema = MySQLRowSchema(columns)
        cachedSchema = schema
        return schema
    }

    public var columnCount: Int { columns.count }
    public var isFinished: Bool { state == .done || state == .failed }

    /// Prepares for the next result set in a multi-resultset response.
    public mutating func reset() {
        state = .awaitingFirstPacket
        columns = []
        collectedColumns = []
        cachedSchema = nil
    }

    public mutating func receive(_ packet: MySQLPacket) -> Action {
        var buffer = packet.payload

        // Checked before anything else: a progress report can arrive at any
        // point during a long statement, and it must not be mistaken for the
        // error packet it is dressed up as, nor disturb the state.
        if MySQLProgressReport.isProgressReport(packet, capabilities: capabilities) {
            if let report = try? MySQLProgressReport.parse(&buffer) {
                return .progress(report)
            }
            return fail(.malformedPacket("malformed MariaDB progress report"))
        }

        switch state {
        case .awaitingFirstPacket:
            return handleFirstPacket(packet, &buffer)
        case .awaitingColumns(let remaining):
            return handleColumnDefinition(&buffer, remaining: remaining)
        case .awaitingColumnListEOF:
            // The EOF closing the column list carries nothing we need.
            guard MySQLEOFPacket.isEOF(packet) else {
                return fail(.unexpectedPacket("expected EOF after column definitions"))
            }
            state = .awaitingRows
            return .columns(columns)
        case .awaitingRows:
            return handleRow(packet, &buffer)
        case .awaitingLocalInfileResult:
            if packet.firstByte == 0xFF { return serverError(&buffer) }
            guard MySQLOKPacket.isOK(packet) else {
                return fail(.unexpectedPacket("expected OK after LOCAL INFILE transfer"))
            }
            return finishFromOK(&buffer, hasRows: false)
        case .done, .failed:
            return fail(.unexpectedPacket("packet received after the result set finished"))
        }
    }

    // MARK: - Steps

    private mutating func handleFirstPacket(
        _ packet: MySQLPacket, _ buffer: inout ByteBuffer
    ) -> Action {
        guard let first = packet.firstByte else {
            return fail(.malformedPacket("empty command response"))
        }

        if first == 0xFF {
            return serverError(&buffer)
        }

        // An OK terminator, in either of its forms.
        //
        // Checking only for a `0x00` header is not enough: with DEPRECATE_EOF
        // the OK header is `0xFE`, and commands like `COM_SET_OPTION` answer
        // with exactly that. Falling through would try to read `0xFE` as a
        // length-encoded column count and fail with a misleading
        // "invalid column count". A result set can never have zero columns, so
        // testing for OK first is unambiguous.
        if MySQLOKPacket.isOK(packet) {
            return finishFromOK(&buffer, hasRows: false)
        }

        // 0xFB here is a LOAD DATA LOCAL INFILE request: the rest of the packet
        // is a filename chosen by the *server*.
        //
        // Note this is position-dependent. The same 0xFB inside a row means SQL
        // NULL; it only means "send me a file" in the column-count slot, which
        // is why it is tested here and not in the row decoder.
        if first == 0xFB {
            buffer.moveReaderIndex(forwardBy: 1)
            let path = buffer.readString(length: buffer.readableBytes) ?? ""
            state = .awaitingLocalInfileResult
            return .sendLocalFile(path: path)
        }

        guard let count = buffer.readLengthEncodedInteger(), count > 0 else {
            return fail(.malformedPacket("invalid column count in command response"))
        }
        state = .awaitingColumns(remaining: Int(count))
        columns.reserveCapacity(Int(count))
        return .wait
    }

    private mutating func handleColumnDefinition(
        _ buffer: inout ByteBuffer, remaining: Int
    ) -> Action {
        do {
            columns.append(try MySQLColumnDefinition.parse(&buffer))
        } catch let error as MySQLProtocolError {
            return fail(error)
        } catch {
            return fail(.malformedPacket("\(error)"))
        }

        let left = remaining - 1
        if left > 0 {
            state = .awaitingColumns(remaining: left)
            return .wait
        }

        // Without DEPRECATE_EOF the server sends an EOF closing the column list.
        if capabilities.contains(.deprecateEOF) {
            state = .awaitingRows
            return .columns(columns)
        }
        state = .awaitingColumnListEOF
        return .wait
    }

    private mutating func handleRow(
        _ packet: MySQLPacket, _ buffer: inout ByteBuffer
    ) -> Action {
        guard let first = packet.firstByte else {
            return fail(.malformedPacket("empty row packet"))
        }

        if first == 0xFF {
            return serverError(&buffer)
        }

        // Terminator detection is the subtle part. `0xFE` starts both an
        // end-of-rows marker *and* a length-encoded value, so the payload
        // length decides: under 9 bytes it is a terminator, otherwise it is
        // row data whose first column happens to be large.
        if first == 0xFE, packet.payload.readableBytes < 9 {
            if capabilities.contains(.deprecateEOF) {
                return finishFromOK(&buffer, hasRows: true)
            }
            do {
                let eof = try MySQLEOFPacket.parse(&buffer)
                let ok = MySQLOKPacket(
                    affectedRows: 0, lastInsertID: 0,
                    statusFlags: eof.statusFlags, warningCount: eof.warningCount, info: nil
                )
                return finish(ok)
            } catch let error as MySQLProtocolError {
                return fail(error)
            } catch {
                return fail(.malformedPacket("\(error)"))
            }
        }

        do {
            switch rowFormat {
            case .text:
                return .row(try MySQLRow.parseText(&buffer, schema: rowSchema()))
            case .binary:
                return .row(try MySQLRow.parseBinary(&buffer, schema: rowSchema()))
            }
        } catch let error as MySQLProtocolError {
            return fail(error)
        } catch {
            return fail(.malformedPacket("\(error)"))
        }
    }

    // MARK: - Helpers

    private mutating func finishFromOK(_ buffer: inout ByteBuffer, hasRows: Bool) -> Action {
        do {
            let ok = try MySQLOKPacket.parse(&buffer, capabilities: capabilities)
            return hasRows ? finish(ok) : finishWithoutRows(ok)
        } catch let error as MySQLProtocolError {
            return fail(error)
        } catch {
            return fail(.malformedPacket("\(error)"))
        }
    }

    private mutating func finish(_ ok: MySQLOKPacket) -> Action {
        state = .done
        return ok.statusFlags.contains(.moreResultsExists)
            ? .finishedWithMoreResults(ok)
            : .finished(ok)
    }

    private mutating func finishWithoutRows(_ ok: MySQLOKPacket) -> Action {
        state = .done
        return ok.statusFlags.contains(.moreResultsExists)
            ? .finishedWithMoreResults(ok)
            : .finishedWithoutRows(ok)
    }

    private mutating func serverError(_ buffer: inout ByteBuffer) -> Action {
        do {
            let err = try MySQLErrorPacket.parse(&buffer, capabilities: capabilities)
            return fail(err.asProtocolError)
        } catch let error as MySQLProtocolError {
            return fail(error)
        } catch {
            return fail(.malformedPacket("\(error)"))
        }
    }

    private mutating func fail(_ error: MySQLProtocolError) -> Action {
        state = .failed
        return .fail(error)
    }
}

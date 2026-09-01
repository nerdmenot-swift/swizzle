import NIOCore
import Testing
@testable import SwizzleMySQL

@Suite("Result set state machine")
struct ResultSetStateMachineTests {

    static func packet(_ bytes: [UInt8]) -> MySQLPacket {
        var buffer = ByteBuffer()
        buffer.writeBytes(bytes)
        return MySQLPacket(sequenceID: 0, payload: buffer)
    }

    /// header, affected_rows, last_insert_id, status, warnings
    static func okPacket(status: MySQLStatusFlags = [], affectedRows: UInt8 = 0) -> MySQLPacket {
        packet([0x00, affectedRows, 0x00] + [UInt8(status.rawValue & 0xFF), UInt8(status.rawValue >> 8)] + [0x00, 0x00])
    }

    /// An OK packet in DEPRECATE_EOF form: header `0xFE`, payload under 9 bytes.
    static func eofStyleOK(status: MySQLStatusFlags = []) -> MySQLPacket {
        packet([0xFE, 0x00, 0x00] + [UInt8(status.rawValue & 0xFF), UInt8(status.rawValue >> 8)] + [0x00, 0x00])
    }

    static func errPacket(code: UInt16, sqlState: String, message: String) -> MySQLPacket {
        var bytes: [UInt8] = [0xFF, UInt8(code & 0xFF), UInt8(code >> 8)]
        bytes += [UInt8(ascii: "#")] + Array(sqlState.utf8)
        bytes += Array(message.utf8)
        return packet(bytes)
    }

    /// A minimal `ColumnDefinition41`.
    static func columnPacket(name: String, type: UInt8 = 0x03, charset: UInt16 = 45) -> MySQLPacket {
        var buffer = ByteBuffer()
        for field in ["def", "swizzle_test", "t", "t", name, name] {
            buffer.writeLengthEncodedString(field)
        }
        buffer.writeLengthEncodedInteger(0x0C)
        buffer.writeInteger(charset, endianness: .little)
        buffer.writeInteger(UInt32(11), endianness: .little)
        buffer.writeInteger(type, endianness: .little)
        buffer.writeInteger(UInt16(0), endianness: .little)
        buffer.writeInteger(UInt8(0), endianness: .little)
        buffer.writeBytes([0, 0])
        return MySQLPacket(sequenceID: 0, payload: buffer)
    }

    static func rowPacket(_ values: [String?]) -> MySQLPacket {
        var buffer = ByteBuffer()
        for value in values {
            if let value { buffer.writeLengthEncodedString(value) }
            else { buffer.writeInteger(UInt8(0xFB), endianness: .little) }
        }
        return MySQLPacket(sequenceID: 0, payload: buffer)
    }

    static func machine(deprecateEOF: Bool = true) -> MySQLResultSetStateMachine {
        MySQLResultSetStateMachine(
            capabilities: deprecateEOF ? [.protocol41, .deprecateEOF] : [.protocol41]
        )
    }

    // MARK: - No result set

    @Test func okPacketFinishesWithoutRows() {
        var sm = Self.machine()
        guard case .finishedWithoutRows(let ok) = sm.receive(Self.okPacket(affectedRows: 3)) else {
            Issue.record("expected finishedWithoutRows"); return
        }
        #expect(ok.affectedRows == 3)
        #expect(sm.isFinished)
    }

    @Test func errorPacketFails() {
        var sm = Self.machine()
        let action = sm.receive(Self.errPacket(code: 1146, sqlState: "42S02", message: "no table"))
        guard case .fail(let error) = action, case .server(let code, let state, _) = error else {
            Issue.record("expected server error"); return
        }
        #expect(code == 1146)
        #expect(state == "42S02")
    }

    // MARK: - Result sets

    @Test func fullResultSetWithDeprecateEOF() {
        var sm = Self.machine(deprecateEOF: true)

        #expect(sm.receive(Self.packet([0x02])) == .wait)          // 2 columns
        #expect(sm.receive(Self.columnPacket(name: "a")) == .wait)

        guard case .columns(let columns) = sm.receive(Self.columnPacket(name: "b")) else {
            Issue.record("expected columns"); return
        }
        #expect(columns.map(\.name) == ["a", "b"])

        guard case .row(let row) = sm.receive(Self.rowPacket(["1", "x"])) else {
            Issue.record("expected row"); return
        }
        #expect(row.string(at: 0) == "1")
        #expect(row.string(at: 1) == "x")

        guard case .finished = sm.receive(Self.eofStyleOK()) else {
            Issue.record("expected finished"); return
        }
    }

    /// Without DEPRECATE_EOF the server sends an EOF closing the column list
    /// *and* an EOF ending the rows.
    @Test func fullResultSetWithoutDeprecateEOF() {
        var sm = Self.machine(deprecateEOF: false)
        let eof = Self.packet([0xFE, 0x00, 0x00, 0x02, 0x00])

        #expect(sm.receive(Self.packet([0x01])) == .wait)
        #expect(sm.receive(Self.columnPacket(name: "a")) == .wait)

        guard case .columns = sm.receive(eof) else {
            Issue.record("expected columns after the closing EOF"); return
        }
        guard case .row = sm.receive(Self.rowPacket(["7"])) else {
            Issue.record("expected row"); return
        }
        guard case .finished = sm.receive(eof) else {
            Issue.record("expected finished"); return
        }
    }

    @Test func nullValuesAreDistinguishedFromEmptyStrings() {
        var sm = Self.machine()
        _ = sm.receive(Self.packet([0x02]))
        _ = sm.receive(Self.columnPacket(name: "a"))
        _ = sm.receive(Self.columnPacket(name: "b"))

        guard case .row(let row) = sm.receive(Self.rowPacket([nil, ""])) else {
            Issue.record("expected row"); return
        }
        #expect(row.values[0].isNull)
        #expect(!row.values[1].isNull)
        #expect(row.string(at: 1) == "")
    }

    /// `0xFE` starts both an end-of-rows marker and a length-encoded value.
    /// Only the payload length tells them apart: under 9 bytes it terminates,
    /// otherwise it is row data whose first value is large.
    @Test func largeFirstValueIsNotMistakenForTermination() {
        var sm = Self.machine()
        _ = sm.receive(Self.packet([0x01]))
        _ = sm.receive(Self.columnPacket(name: "big"))

        // 0xFE lenenc form: 8-byte length follows, so the payload exceeds 9 bytes.
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt8(0xFE), endianness: .little)
        buffer.writeInteger(UInt64(4), endianness: .little)
        buffer.writeString("abcd")
        let row = MySQLPacket(sequenceID: 0, payload: buffer)
        #expect(row.payload.readableBytes >= 9)

        guard case .row(let parsed) = sm.receive(row) else {
            Issue.record("a large first value must not read as termination"); return
        }
        #expect(parsed.string(at: 0) == "abcd")
    }

    // MARK: - Multi-resultset

    /// A stored procedure always trails at least one status result set.
    @Test func moreResultsFlagIsReported() {
        var sm = Self.machine()
        _ = sm.receive(Self.packet([0x01]))
        _ = sm.receive(Self.columnPacket(name: "a"))
        _ = sm.receive(Self.rowPacket(["1"]))

        guard case .finishedWithMoreResults = sm.receive(Self.eofStyleOK(status: .moreResultsExists))
        else {
            Issue.record("expected finishedWithMoreResults"); return
        }

        // After reset the machine accepts the next set.
        sm.reset()
        guard case .finishedWithoutRows = sm.receive(Self.okPacket()) else {
            Issue.record("expected the second result set to parse"); return
        }
    }

    @Test func nonSelectWithMoreResultsIsReported() {
        var sm = Self.machine()
        guard case .finishedWithMoreResults = sm.receive(Self.okPacket(status: .moreResultsExists))
        else {
            Issue.record("expected finishedWithMoreResults"); return
        }
    }

    // MARK: - Security

    /// `0xFB` as the first response byte is a LOAD DATA LOCAL INFILE request:
    /// the server naming a file for the client to upload.
    ///
    /// The state machine surfaces it rather than deciding on it — refusal lives
    /// in the command handler, because refusing correctly still requires
    /// answering the server (see `MySQLCommandHandler.sendLocalFile`). Failing
    /// here would skip that and desync the connection.
    @Test func localInfileRequestIsSurfacedWithItsPath() {
        var sm = Self.machine()
        guard case .sendLocalFile(let path) =
                sm.receive(Self.packet([0xFB] + Array("/etc/passwd".utf8)))
        else {
            Issue.record("expected a LOCAL INFILE request"); return
        }
        #expect(path == "/etc/passwd")
    }

    /// `0xFB` is only a file request in the column-count slot; inside a row it
    /// is SQL NULL. Reading it as a file request there would be a disaster, so
    /// the two positions are kept distinct.
    @Test func localInfileMarkerInsideARowIsJustNull() {
        var sm = Self.machine()
        _ = sm.receive(Self.packet([0x01]))              // one column
        _ = sm.receive(Self.columnPacket(name: "c"))     // its definition

        guard case .row(let row) = sm.receive(Self.rowPacket([nil])) else {
            Issue.record("expected a row containing NULL"); return
        }
        #expect(row[0].isNull)
    }

    @Test func packetAfterCompletionIsRejected() {
        var sm = Self.machine()
        _ = sm.receive(Self.okPacket())
        guard case .fail = sm.receive(Self.okPacket()) else {
            Issue.record("expected rejection after completion"); return
        }
    }

    // MARK: - LOAD DATA LOCAL INFILE

    /// `0xFB` in the **column-count slot** is not a value — it is the server
    /// asking the client to send it a file.
    ///
    /// The same byte inside a row means SQL NULL, which is why the test lives
    /// here and not in the row decoder, and why getting it wrong is not a
    /// decode error: the driver would read a filename as a column count and
    /// wait for column definitions that never come.
    ///
    /// It also matters for a reason beyond correctness. The path is chosen by
    /// the *server*, so a hostile one can ask for any file the client process
    /// can read — the vulnerability `local_infile` exists to gate. Recognising
    /// the request is what lets the driver refuse it.
    @Test func localInfileRequestIsRecognised() {
        var sm = Self.machine()
        let action = sm.receive(Self.packet([0xFB] + Array("/etc/passwd".utf8)))
        guard case .sendLocalFile(let path) = action else {
            Issue.record("expected sendLocalFile, got \(action)"); return
        }
        #expect(path == "/etc/passwd", "the path comes from the server, not the client")
        #expect(!sm.isFinished, "the exchange continues with the file's contents")
    }

    /// A bare `0xFB` with no path is still the request, not a column count.
    @Test func localInfileWithNoPath() {
        var sm = Self.machine()
        guard case .sendLocalFile(let path) = sm.receive(Self.packet([0xFB])) else {
            Issue.record("expected sendLocalFile"); return
        }
        #expect(path.isEmpty)
    }

    // MARK: - An error in the middle of the rows

    /// A result set can fail **after** its columns and some of its rows — a
    /// killed query, a lock timeout, a disk error partway through a scan. The
    /// error packet arrives where a row would, so the row phase has to test for
    /// it before treating the bytes as data.
    @Test func errorDuringRowsFails() {
        var sm = Self.machine(deprecateEOF: true)
        #expect(sm.receive(Self.packet([0x01])) == .wait)
        // The last definition completes the column phase, so this yields
        // the columns rather than waiting for more.
        guard case .columns = sm.receive(Self.columnPacket(name: "a")) else {
            Issue.record("expected the column phase to complete"); return
        }
        _ = sm.receive(Self.rowPacket(["1"]))

        let action = sm.receive(
            Self.errPacket(code: 1317, sqlState: "70100", message: "Query execution was interrupted")
        )
        guard case .fail(let error) = action, case .server(let code, _, _) = error else {
            Issue.record("expected a server error, got \(action)"); return
        }
        #expect(code == 1317)
        #expect(sm.isFinished, "a failed result set is finished")
    }

    /// And `isFinished` covers both terminal states, not just the happy one —
    /// a caller that only checks for `done` waits forever on a failure.
    @Test func bothTerminalStatesAreFinished() {
        var failed = Self.machine()
        _ = failed.receive(Self.errPacket(code: 1146, sqlState: "42S02", message: "no table"))
        #expect(failed.isFinished, "failed")

        var done = Self.machine()
        _ = done.receive(Self.okPacket())
        #expect(done.isFinished, "done")

        var running = Self.machine()
        #expect(!running.isFinished, "before anything arrives")
        _ = running.receive(Self.packet([0x01]))
        #expect(!running.isFinished, "awaiting columns")
    }

    // MARK: - The column count's bounds

    /// A column count of **zero** is not a result set, and it cannot be caught
    /// by the OK-packet test above it: a zero written as a one-byte
    /// length-encoded integer *is* `0x00`, which is an OK packet, so the only
    /// way to reach the guard is a redundantly-encoded zero.
    ///
    /// A peer can send one, and without the guard the machine waits for zero
    /// column definitions and then reads the next packet as a row.
    @Test func zeroColumnCountIsRefused() {
        var sm = Self.machine()
        // 0 encoded in the three-byte form, so the first byte is not 0x00.
        guard case .fail = sm.receive(Self.packet([0xFC, 0x00, 0x00])) else {
            Issue.record("a zero column count should not begin a result set"); return
        }
        #expect(sm.isFinished)
    }

    /// The upper bound, at the value it turns over on. Above it the conversion
    /// to `Int` is the problem; at it, the count is merely implausible and is
    /// allowed, because no policy here can say where "too many columns" begins
    /// without risking a legitimate wide result set.
    @Test func columnCountUpperBound() {
        var atLimit = Self.machine()
        var bytes: [UInt8] = [0xFE]
        let limit = UInt64(Int32.max)
        for shift in 0..<8 { bytes.append(UInt8((limit >> (8 * shift)) & 0xFF)) }
        #expect(atLimit.receive(Self.packet(bytes)) == .wait, "exactly at the bound is allowed")

        var past = Self.machine()
        var overBytes: [UInt8] = [0xFE]
        let over = UInt64(Int32.max) + 1
        for shift in 0..<8 { overBytes.append(UInt8((over >> (8 * shift)) & 0xFF)) }
        guard case .fail = past.receive(Self.packet(overBytes)) else {
            Issue.record("one past the bound should be refused"); return
        }
    }

    // MARK: - The 0xFE boundary in the row phase

    /// The row phase has its own copy of the terminator test, and it is the one
    /// that decides where a result set ends. A row whose first column needs an
    /// eight-byte length prefix begins with `0xFE` and must not be mistaken for
    /// the end of the rows.
    @Test func longRowIsNotATerminator() throws {
        var sm = Self.machine(deprecateEOF: true)
        #expect(sm.receive(Self.packet([0x01])) == .wait)
        guard case .columns = sm.receive(Self.columnPacket(name: "a", type: 0xFD)) else {
            Issue.record("expected the column phase to complete"); return
        }

        // 0xFE then an eight-byte length, then the value: a row, not a marker.
        var row: [UInt8] = [0xFE, 0x10, 0, 0, 0, 0, 0, 0, 0]
        row += [UInt8](repeating: 0x41, count: 16)
        let action = sm.receive(Self.packet(row))
        guard case .row = action else {
            Issue.record("a 17-byte 0xFE packet is row data, got \(action)"); return
        }
        #expect(!sm.isFinished)

        // And a short one does end it.
        #expect(sm.isFinished == false)
        _ = sm.receive(Self.eofStyleOK())
        #expect(sm.isFinished, "an 0xFE packet under nine bytes is the terminator")
    }

    /// Nine bytes exactly, which is where the rule turns over.
    ///
    /// The threshold is not arbitrary: a row beginning with `0xFE` uses the
    /// eight-byte length-encoded form, so it cannot be shorter than nine bytes,
    /// while an EOF packet is five. Nine is therefore the first length that must
    /// be read as data, and treating it as a terminator ends the result set one
    /// row early — silently, since a short result set looks like a small table.
    @Test func nineBytesIsRowDataNotATerminator() {
        var sm = Self.machine(deprecateEOF: true)
        #expect(sm.receive(Self.packet([0x01])) == .wait)
        guard case .columns = sm.receive(Self.columnPacket(name: "a", type: 0xFD)) else {
            Issue.record("expected the column phase to complete"); return
        }

        // 0xFE then eight length bytes: the shortest a row starting 0xFE can be.
        let action = sm.receive(Self.packet([0xFE, 0, 0, 0, 0, 0, 0, 0, 0]))
        guard case .row = action else {
            Issue.record("a nine-byte 0xFE packet is row data, got \(action)"); return
        }
        #expect(!sm.isFinished)

        // Eight bytes is one short, and is the terminator.
        var shorter = Self.machine(deprecateEOF: true)
        #expect(shorter.receive(Self.packet([0x01])) == .wait)
        guard case .columns = shorter.receive(Self.columnPacket(name: "a", type: 0xFD)) else {
            Issue.record("expected the column phase to complete"); return
        }
        _ = shorter.receive(Self.packet([0xFE, 0, 0, 0, 0, 0, 0, 0]))
        #expect(shorter.isFinished, "eight bytes is under the threshold")
    }
}

@Suite("Capability policy")
struct CapabilityPolicyTests {
    /// Never advertise a capability without an implementation behind it.
    ///
    /// Requesting `MARIADB_CLIENT_EXTENDED_METADATA` made MariaDB append extra
    /// fields to every column definition; with no parser for them, type,
    /// charset and length all decoded as plausible-looking garbage instead of
    /// failing loudly. These three are still unimplemented and must stay
    /// unrequested.
    @Test func unimplementedMariaDBExtensionsAreNotRequested() {
        let requested = MySQLCapabilities.swizzleMariaDBDefault
        #expect(!requested.contains(.mariaDBExtendedMetadata))
        #expect(!requested.contains(.mariaDBCacheMetadata))
        #expect(!requested.contains(.mariaDBBulkUnitResults))
    }

    /// Bulk execute *is* implemented, so its capability is requested — the
    /// server refuses `COM_STMT_BULK_EXECUTE` without it.
    @Test func bulkOperationsAreRequested() {
        #expect(MySQLCapabilities.swizzleMariaDBDefault.contains(.mariaDBStmtBulkOperations))
    }

    /// LOCAL INFILE and compression are opt-in per connection, so neither may
    /// sit in the baseline. Advertising `CLIENT_LOCAL_FILES` unconditionally
    /// would invite a file request we never intended to serve.
    @Test func optInCapabilitiesAreNotInTheBaseline() {
        #expect(!MySQLCapabilities.swizzleDefault.contains(.localFiles))
        #expect(!MySQLCapabilities.swizzleDefault.contains(.compress))
        #expect(!MySQLCapabilities.swizzleDefault.contains(.progressObsolete))
    }

    /// `CONNECT_WITH_DB` must be in the desired set, or the handshake response
    /// would add a flag the SSLRequest never advertised.
    @Test func connectWithDBIsInTheDesiredSet() {
        #expect(MySQLCapabilities.swizzleDefault.contains(.connectWithDB))
    }
}

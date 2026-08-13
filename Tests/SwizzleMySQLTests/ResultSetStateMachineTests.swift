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

import NIOCore
import Testing
@testable import SwizzleMySQL

@Suite("Bulk execute encoding")
struct BulkExecuteEncodingTests {

    static func encoded(_ request: MySQLBulkExecuteRequest) throws -> [UInt8] {
        var buffer = ByteBuffer()
        try request.serialize(into: &buffer)
        return buffer.getBytes(at: 0, length: buffer.readableBytes) ?? []
    }

    @Test func writesTheDocumentedHeader() throws {
        let bytes = try Self.encoded(
            MySQLBulkExecuteRequest(statementID: 0x0102_0304, rows: [[.int(1)]])
        )

        #expect(bytes[0] == 0xFA)                             // COM_STMT_BULK_EXECUTE
        #expect(Array(bytes[1...4]) == [0x04, 0x03, 0x02, 0x01])  // statement id, LE
        #expect(Array(bytes[5...6]) == [128, 0])              // SEND_TYPES_TO_SERVER
    }

    @Test func sendsOneTypePairPerParameter() throws {
        let bytes = try Self.encoded(
            MySQLBulkExecuteRequest(statementID: 1, rows: [[.int(1), .bytes([0x41])]])
        )
        // After the 7-byte header: two 2-byte type entries.
        #expect(bytes[7] == MySQLColumnType.longlong.rawValue)
        #expect(bytes[8] == 0)
        #expect(bytes[9] == MySQLColumnType.varString.rawValue)
        #expect(bytes[10] == 0)
    }

    @Test func unsignedIntegersCarryTheUnsignedFlag() throws {
        let bytes = try Self.encoded(
            MySQLBulkExecuteRequest(statementID: 1, rows: [[.uint(1)]])
        )
        #expect(bytes[7] == MySQLColumnType.longlong.rawValue)
        #expect(bytes[8] == 0x80)
    }

    @Test func nullValuesUseTheIndicatorAndNoPayload() throws {
        let bytes = try Self.encoded(
            MySQLBulkExecuteRequest(statementID: 1, rows: [[.null]], sendTypes: false)
        )
        // 7-byte header, then a single indicator byte and nothing else.
        #expect(bytes.count == 8)
        #expect(bytes[7] == MySQLBulkExecuteRequest.Indicator.null.rawValue)
    }

    // MARK: - Type widening

    /// The trap this whole mechanism exists for. Types are sent once for the
    /// batch, so a parameter that is NULL in the first row must still be
    /// announced with the type it takes later — otherwise the server is told
    /// `MYSQL_TYPE_NULL` for a column that carries values.
    @Test func aNullInTheFirstRowTakesTheTypeOfALaterRow() {
        let types = MySQLBulkExecuteRequest.columnTypes(for: [
            [.null],
            [.int(5)],
        ])
        #expect(types[0].0 == .longlong)
    }

    @Test func aNullInALaterRowDoesNotDowngradeTheType() {
        let types = MySQLBulkExecuteRequest.columnTypes(for: [
            [.int(5)],
            [.null],
        ])
        #expect(types[0].0 == .longlong)
    }

    @Test func allNullsStayNull() {
        let types = MySQLBulkExecuteRequest.columnTypes(for: [[.null], [.null]])
        #expect(types[0].0 == .null)
    }

    /// One unsigned value anywhere in the batch makes the parameter unsigned,
    /// since the flag is sent once for all rows.
    @Test func unsignedFlagIsUnionedAcrossRows() {
        let types = MySQLBulkExecuteRequest.columnTypes(for: [
            [.int(1)],
            [.uint(2)],
        ])
        #expect(types[0].0 == .longlong)
        #expect(types[0].1 == 0x80)
    }

    // MARK: - Validation

    @Test func rejectsAnEmptyRowSet() {
        var buffer = ByteBuffer()
        #expect(throws: MySQLBulkExecuteRequest.BulkError.noRows) {
            try MySQLBulkExecuteRequest(statementID: 1, rows: []).serialize(into: &buffer)
        }
    }

    /// MariaDB refuses a bulk request for a statement with no parameters, so it
    /// is caught before the round trip.
    @Test func rejectsRowsWithNoParameters() {
        var buffer = ByteBuffer()
        #expect(throws: MySQLBulkExecuteRequest.BulkError.noParameters) {
            try MySQLBulkExecuteRequest(statementID: 1, rows: [[]]).serialize(into: &buffer)
        }
    }

    @Test func rejectsMixedArity() {
        var buffer = ByteBuffer()
        #expect(throws: MySQLBulkExecuteRequest.BulkError.mixedArity(expected: 2, found: 1)) {
            try MySQLBulkExecuteRequest(
                statementID: 1, rows: [[.int(1), .int(2)], [.int(3)]]
            ).serialize(into: &buffer)
        }
    }

    // MARK: - Batching

    @Test func smallRowSetsFitInOneBatch() {
        let rows: [[MySQLValue]] = (1...100).map { [.int(Int64($0))] }
        let batches = MySQLBulkExecuteRequest.batches(rows: rows, maxAllowedPacket: 1 << 20)
        #expect(batches.count == 1)
        #expect(batches[0].count == 100)
    }

    @Test func oversizedRowSetsAreSplitAndLoseNothing() {
        let payload = [UInt8](repeating: 0x41, count: 1000)
        let rows: [[MySQLValue]] = (1...100).map { _ in [.bytes(payload)] }
        let batches = MySQLBulkExecuteRequest.batches(rows: rows, maxAllowedPacket: 8192)

        #expect(batches.count > 1)
        #expect(batches.reduce(0) { $0 + $1.count } == 100)
        // And every batch actually fits.
        for batch in batches {
            let request = MySQLBulkExecuteRequest(statementID: 1, rows: batch)
            #expect(request.estimatedSize <= 8192)
        }
    }

    @Test func batchingAnEmptyRowSetProducesNoBatches() {
        #expect(MySQLBulkExecuteRequest.batches(rows: [], maxAllowedPacket: 1024).isEmpty)
    }

    /// A row too large to ever fit still comes back rather than vanishing, so
    /// the server can name the problem.
    @Test func anUnsplittableRowIsStillReturned() {
        let huge = [UInt8](repeating: 0x41, count: 10_000)
        let batches = MySQLBulkExecuteRequest.batches(rows: [[.bytes(huge)]], maxAllowedPacket: 1024)
        #expect(batches.count == 1)
        #expect(batches[0].count == 1)
    }

    @Test func estimatedSizeMatchesTheEncodedSize() throws {
        let rows: [[MySQLValue]] = [
            [.int(1), .bytes(Array("hello".utf8))],
            [.null, .bytes(Array("world!".utf8))],
        ]
        let request = MySQLBulkExecuteRequest(statementID: 1, rows: rows)
        var buffer = ByteBuffer()
        try request.serialize(into: &buffer)
        #expect(request.estimatedSize == buffer.readableBytes)
    }
}

@Suite("MariaDB progress reports")
struct ProgressReportTests {

    static func packet(
        stage: UInt8 = 1, maxStage: UInt8 = 3, progress: UInt32 = 12_345, info: String = "copying"
    ) -> MySQLPacket {
        var payload = ByteBuffer()
        payload.writeInteger(UInt8(0xFF))
        payload.writeInteger(MySQLProgressReport.marker, endianness: .little)
        payload.writeInteger(stage)
        payload.writeInteger(maxStage)
        payload.writeInteger(UInt16(progress & 0xFFFF), endianness: .little)
        payload.writeInteger(UInt8((progress >> 16) & 0xFF))
        payload.writeLengthEncodedInteger(UInt64(info.utf8.count))
        payload.writeString(info)
        return MySQLPacket(sequenceID: 1, payload: payload)
    }

    @Test func parsesAProgressReport() throws {
        var buffer = Self.packet().payload
        let report = try MySQLProgressReport.parse(&buffer)

        #expect(report.stage == 1)
        #expect(report.maxStage == 3)
        #expect(report.progress == 12_345)
        #expect(report.stageInfo == "copying")
        #expect(abs(report.percentage - 12.345) < 0.0001)
    }

    /// The discrimination that keeps a real error from being swallowed. Without
    /// the capability, error code 65535 is just an error.
    @Test func isNotAProgressReportWithoutTheCapability() {
        #expect(!MySQLProgressReport.isProgressReport(Self.packet(), capabilities: []))
        #expect(
            MySQLProgressReport.isProgressReport(Self.packet(), capabilities: [.progressObsolete])
        )
    }

    /// An ordinary error must never be read as progress, even with the
    /// capability negotiated.
    @Test func anOrdinaryErrorIsNotProgress() {
        var payload = ByteBuffer()
        payload.writeInteger(UInt8(0xFF))
        payload.writeInteger(UInt16(1146), endianness: .little)      // table doesn't exist
        payload.writeString("#42S02")
        payload.writeString("Table 'x' doesn't exist")
        let packet = MySQLPacket(sequenceID: 1, payload: payload)

        #expect(!MySQLProgressReport.isProgressReport(packet, capabilities: [.progressObsolete]))
    }

    /// Progress arrives mid-statement and must leave the result set untouched —
    /// the machine is still waiting for whatever it was waiting for.
    @Test func progressDoesNotDisturbTheResultSet() {
        var machine = MySQLResultSetStateMachine(
            capabilities: [.protocol41, .deprecateEOF, .progressObsolete]
        )

        var columnCount = ByteBuffer()
        columnCount.writeInteger(UInt8(1))
        guard case .wait = machine.receive(MySQLPacket(sequenceID: 1, payload: columnCount)) else {
            Issue.record("expected to be awaiting column definitions"); return
        }

        guard case .progress(let report) = machine.receive(Self.packet()) else {
            Issue.record("expected a progress report"); return
        }
        #expect(report.stageInfo == "copying")

        // Still awaiting the column definition it wanted before the interruption.
        #expect(machine.state == .awaitingColumns(remaining: 1))
    }
}

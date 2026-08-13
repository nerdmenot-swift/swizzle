import Foundation
import NIOCore
import Testing
@testable import SwizzleMySQL

/// Decode throughput with no server and no socket involved.
///
/// The integration benchmarks measure what a caller gets, which is the honest
/// headline number — but it bundles the server's work and the loopback round
/// trip with ours, so a change to decoding shows up there diluted. This measures
/// the driver's own cost alone, which is what an optimisation is actually
/// moving.
///
/// **Opt-in**: set `SWIZZLE_BENCH=1`.
@Suite(
    "Decode benchmarks",
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["SWIZZLE_BENCH"] != nil,
        "Set SWIZZLE_BENCH=1 to run benchmarks"
    )
)
struct DecodeBenchmarkTests {

    static func column(
        name: String, type: MySQLColumnType, flags: MySQLColumnFlags = []
    ) -> MySQLColumnDefinition {
        MySQLColumnDefinition(
            catalog: "def", schema: "db", table: "t", originalTable: "t",
            name: name, originalName: name, characterSet: 33, columnLength: 255,
            type: type.rawValue, flags: flags, decimals: 0
        )
    }

    /// Five columns spanning the shapes that decode differently: two integers,
    /// a double, a string and a datetime.
    static let columns: [MySQLColumnDefinition] = [
        column(name: "id", type: .long),
        column(name: "score", type: .longlong),
        column(name: "ratio", type: .double),
        column(name: "name", type: .varString),
        column(name: "created", type: .datetime),
    ]

    static func textRowPacket(_ index: Int) -> ByteBuffer {
        var buffer = ByteBuffer()
        for text in [
            "\(index)", "\(index &* 7)", "\(Double(index) * 1.5)",
            "name-\(index)", "2024-03-17 12:34:56",
        ] {
            buffer.writeLengthEncodedInteger(UInt64(text.utf8.count))
            buffer.writeString(text)
        }
        return buffer
    }

    static func report(_ label: String, count: Int, seconds: Double) {
        let padded = label.padding(toLength: max(label.count, 34), withPad: " ", startingAt: 0)
        print("DECODE \(padded) \(String(format: "%11.0f", Double(count) / seconds))/s"
              + "  (\(count) in \(String(format: "%.4f", seconds))s)")
    }

    @Test("text-protocol row decoding")
    func textRowDecoding() throws {
        let schema = MySQLRowSchema(Self.columns)
        let packets = (0..<20_000).map { Self.textRowPacket($0) }

        // Warm, so first-call costs are not counted.
        for var packet in packets.prefix(500) {
            _ = try MySQLRow.parseText(&packet, schema: schema)
        }

        var checksum: Int64 = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for var packet in packets {
            let row = try MySQLRow.parseText(&packet, schema: schema)
            checksum &+= row[0].int ?? 0
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9

        #expect(checksum > 0)
        Self.report("text rows (5 columns)", count: packets.count, seconds: seconds)
        Self.report("text values", count: packets.count * 5, seconds: seconds)
    }

    /// Integers alone, because that is the case where the decoder used to do the
    /// most needless work: an array allocation and a `String` allocation per
    /// value, both discarded once the digits were parsed.
    @Test("integer column decoding")
    func integerDecoding() {
        let column = Self.column(name: "n", type: .long)
        let buffers = (0..<200_000).map { index -> ByteBuffer in
            var buffer = ByteBuffer()
            buffer.writeString("\(index)")
            return buffer
        }

        for buffer in buffers.prefix(1000) {
            _ = MySQLValue.decodeText(buffer, type: .long, flags: column.flags)
        }

        var checksum: Int64 = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for buffer in buffers {
            if case .int(let value) = MySQLValue.decodeText(
                buffer, type: .long, flags: column.flags
            ) { checksum &+= value }
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9

        #expect(checksum > 0)
        Self.report("integer values", count: buffers.count, seconds: seconds)
    }

    @Test("datetime column decoding")
    func datetimeDecoding() {
        let buffers = (0..<200_000).map { _ -> ByteBuffer in
            var buffer = ByteBuffer()
            buffer.writeString("2024-03-17 12:34:56.123456")
            return buffer
        }

        for buffer in buffers.prefix(1000) {
            _ = MySQLValue.decodeText(buffer, type: .datetime, flags: [])
        }

        var checksum = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for buffer in buffers {
            if case .dateTime(let value) = MySQLValue.decodeText(
                buffer, type: .datetime, flags: []
            ) { checksum &+= Int(value.year) }
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9

        #expect(checksum > 0)
        Self.report("datetime values", count: buffers.count, seconds: seconds)
    }

    @Test("string column decoding")
    func stringDecoding() {
        let buffers = (0..<200_000).map { index -> ByteBuffer in
            var buffer = ByteBuffer()
            buffer.writeString("some-name-\(index)")
            return buffer
        }

        for buffer in buffers.prefix(1000) {
            _ = MySQLValue.decodeText(buffer, type: .varString, flags: [])
        }

        var checksum = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for buffer in buffers {
            if case .bytes(let value) = MySQLValue.decodeText(
                buffer, type: .varString, flags: []
            ) { checksum &+= value.count }
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9

        #expect(checksum > 0)
        Self.report("string values", count: buffers.count, seconds: seconds)
    }
}

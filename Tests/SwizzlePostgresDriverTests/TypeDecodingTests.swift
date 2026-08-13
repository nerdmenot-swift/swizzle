import Foundation
import NIOCore
import SwizzleCore
import Testing
@testable import SwizzlePostgresDriver

@Suite("Postgres value decoding")
struct TypeDecodingTests {

    func binary(_ oid: PostgresOID, _ build: (inout ByteBuffer) -> Void) -> SQLValue {
        var buffer = ByteBufferAllocator().buffer(capacity: 32)
        build(&buffer)
        return PostgresValueDecoder.decode(
            buffer.readBytes(length: buffer.readableBytes), oid: oid.rawValue, format: 1
        )
    }

    func text(_ oid: PostgresOID, _ value: String) -> SQLValue {
        PostgresValueDecoder.decode(Array(value.utf8), oid: oid.rawValue, format: 0)
    }

    @Test("null is null in either format")
    func nulls() {
        #expect(PostgresValueDecoder.decode(nil, oid: PostgresOID.int4.rawValue, format: 1) == .null)
        #expect(PostgresValueDecoder.decode(nil, oid: PostgresOID.text.rawValue, format: 0) == .null)
        // An empty value is not a null.
        #expect(PostgresValueDecoder.decode([], oid: PostgresOID.text.rawValue, format: 0) == .text(""))
    }

    @Test("integers decode in both formats")
    func integers() {
        #expect(binary(.int2) { $0.writeInteger(Int16(-42)) } == .int(-42))
        #expect(binary(.int4) { $0.writeInteger(Int32(70_000)) } == .int(70_000))
        #expect(binary(.int8) { $0.writeInteger(Int64.max) } == .int(Int64.max))
        #expect(text(.int8, "-9223372036854775808") == .int(Int64.min))
    }

    @Test("booleans decode in both formats")
    func booleans() {
        #expect(binary(.bool) { $0.writeInteger(UInt8(1)) } == .bool(true))
        #expect(binary(.bool) { $0.writeInteger(UInt8(0)) } == .bool(false))
        // Text format is a single letter, not "true"/"false".
        #expect(text(.bool, "t") == .bool(true))
        #expect(text(.bool, "f") == .bool(false))
    }

    @Test("floats decode from their bit patterns")
    func floats() {
        #expect(binary(.float8) { $0.writeInteger(Double(1.5).bitPattern) } == .double(1.5))
        #expect(binary(.float4) { $0.writeInteger(Float(0.5).bitPattern) } == .double(0.5))
        #expect(text(.float8, "2.25") == .double(2.25))
    }

    // MARK: - numeric, the one that must not go through Double

    /// `numeric` is the money type, and in binary the server sends base-10000
    /// digits rather than text. Getting the reconstruction wrong does not fail —
    /// it produces a number that is merely incorrect, which is the worst kind.
    @Test("numeric reconstructs its decimal text")
    func numericReconstruction() {
        // 1234.5678 → digits [1234, 5678], weight 0, scale 4.
        #expect(
            binary(.numeric) {
                $0.writeInteger(Int16(2)); $0.writeInteger(Int16(0))
                $0.writeInteger(UInt16(0)); $0.writeInteger(Int16(4))
                $0.writeInteger(Int16(1234)); $0.writeInteger(Int16(5678))
            } == .text("1234.5678")
        )

        // A negative value: sign 0x4000.
        #expect(
            binary(.numeric) {
                $0.writeInteger(Int16(1)); $0.writeInteger(Int16(0))
                $0.writeInteger(UInt16(0x4000)); $0.writeInteger(Int16(2))
                $0.writeInteger(Int16(42))
            } == .text("-42.00")
        )

        // Zero has no digits at all.
        #expect(
            binary(.numeric) {
                $0.writeInteger(Int16(0)); $0.writeInteger(Int16(0))
                $0.writeInteger(UInt16(0)); $0.writeInteger(Int16(0))
            } == .text("0")
        )
    }

    /// The display scale is why `1.10` comes back as `1.10` and not `1.1` — for
    /// money, the trailing zero is information.
    @Test("the display scale is honoured")
    func displayScaleIsHonoured() {
        #expect(
            binary(.numeric) {
                $0.writeInteger(Int16(2)); $0.writeInteger(Int16(0))
                $0.writeInteger(UInt16(0)); $0.writeInteger(Int16(2))
                $0.writeInteger(Int16(1)); $0.writeInteger(Int16(1000))
            } == .text("1.10")
        )
    }

    /// A group the server omitted is a zero group, not a missing one — dropping
    /// it would shift every digit after it.
    @Test("omitted trailing groups are treated as zero")
    func omittedGroupsAreZero() {
        // weight 1 means the first group is the 10000s, so 20000 with scale 0.
        #expect(
            binary(.numeric) {
                $0.writeInteger(Int16(1)); $0.writeInteger(Int16(1))
                $0.writeInteger(UInt16(0)); $0.writeInteger(Int16(0))
                $0.writeInteger(Int16(2))
            } == .text("20000")
        )
    }

    @Test("the special numeric signs decode")
    func numericSpecials() {
        func special(_ sign: UInt16) -> SQLValue {
            binary(.numeric) {
                $0.writeInteger(Int16(0)); $0.writeInteger(Int16(0))
                $0.writeInteger(sign); $0.writeInteger(Int16(0))
            }
        }
        #expect(special(0xC000) == .text("NaN"))
        #expect(special(0xD000) == .text("Infinity"))
        #expect(special(0xF000) == .text("-Infinity"))
    }

    /// The generator must never route an exact numeric through binary floating
    /// point — the same contract MySQL's DECIMAL and SQLite's NUMERIC make.
    @Test("numeric maps to a decimal string, never a Double")
    func numericSwiftType() {
        #expect(PostgresOID.numeric.swiftType == .decimalString)
        #expect(PostgresOID.float8.swiftType == .double)
    }

    // MARK: - Temporals, and the epoch that is not 1970

    /// Postgres counts from **2000-01-01**. Thirty years out is a plausible-looking
    /// date, which is what makes it a silent error rather than a loud one.
    @Test("timestamps are counted from the Postgres epoch")
    func postgresEpoch() {
        // Zero microseconds is exactly 2000-01-01 00:00:00.
        #expect(binary(.timestamp) { $0.writeInteger(Int64(0)) } == .text("2000-01-01 00:00:00"))

        // One day later.
        #expect(
            binary(.timestamp) { $0.writeInteger(Int64(86_400) * 1_000_000) }
                == .text("2000-01-02 00:00:00")
        )

        // And before the epoch, which is negative.
        #expect(
            binary(.timestamp) { $0.writeInteger(Int64(-86_400) * 1_000_000) }
                == .text("1999-12-31 00:00:00")
        )
    }

    @Test("dates are days from the same epoch")
    func dates() {
        #expect(binary(.date) { $0.writeInteger(Int32(0)) } == .text("2000-01-01"))
        #expect(binary(.date) { $0.writeInteger(Int32(366)) } == .text("2001-01-01"))
    }

    @Test("sub-second precision survives")
    func microseconds() {
        #expect(
            binary(.timestamp) { $0.writeInteger(Int64(123_456)) }
                == .text("2000-01-01 00:00:00.123456")
        )
    }

    // MARK: - The rest

    @Test("a uuid is formatted, not handed back as bytes")
    func uuids() {
        let bytes: [UInt8] = [
            0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0,
            0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0,
        ]
        #expect(
            PostgresValueDecoder.decode(bytes, oid: PostgresOID.uuid.rawValue, format: 1)
                == .text("12345678-9abc-def0-1234-56789abcdef0")
        )
    }

    /// `jsonb` carries a leading version byte that is not part of the document,
    /// and `json` does not. That single byte is the only wire difference.
    @Test("jsonb's version byte is stripped and json's absence respected")
    func jsonVersionByte() {
        let document = #"{"a":1}"#
        #expect(
            PostgresValueDecoder.decode(
                [1] + Array(document.utf8), oid: PostgresOID.jsonb.rawValue, format: 1
            ) == .text(document)
        )
        #expect(
            PostgresValueDecoder.decode(
                Array(document.utf8), oid: PostgresOID.json.rawValue, format: 1
            ) == .text(document)
        )
    }

    @Test("bytea decodes from both formats")
    func bytea() {
        #expect(
            PostgresValueDecoder.decode([0xDE, 0xAD], oid: PostgresOID.bytea.rawValue, format: 1)
                == .blob([0xDE, 0xAD])
        )
        // Text format is `\x` then hex.
        #expect(text(.bytea, "\\xdead") == .blob([0xDE, 0xAD]))
    }

    /// A new server type must not break a query that never touches it.
    @Test("an unknown OID degrades rather than failing")
    func unknownOIDs() {
        #expect(
            PostgresValueDecoder.decode(Array("hello".utf8), oid: 999_999, format: 0)
                == .text("hello")
        )
        #expect(
            PostgresValueDecoder.decode([0xFF, 0xFE], oid: 999_999, format: 1) == .blob([0xFF, 0xFE])
        )
    }

    @Test("array OIDs report their element type")
    func arrayTypes() {
        #expect(PostgresOID.textArray.elementType == .text)
        #expect(PostgresOID.int8Array.swiftType == .array(.int64))
        #expect(PostgresOID.numericArray.swiftType == .array(.decimalString))
        #expect(PostgresOID.text.elementType == nil)
    }

    /// The lockfile records names, never OIDs: OIDs for user types are
    /// per-database and the shadow is recreated each run, so storing them would
    /// churn the lockfile on every generate.
    @Test("types report a stable name")
    func stableNames() {
        #expect(PostgresOID.timestamptz.name == "timestamptz")
        #expect(PostgresOID.numeric.name == "numeric")
    }
}

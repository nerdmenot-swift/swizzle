import Foundation
import Testing
@testable import Swizzle

/// `UInt64` had no home before pillar 3 needed one.
///
/// `SQLValue.int` is `Int64`, so `BIGINT UNSIGNED` above 2^63 cannot be an `.int`.
/// The MySQL driver already did the right thing on the way in — `Int64(exactly:)`
/// falling back to `.text` rather than wrapping — but nothing on the Swift side
/// could accept both halves, so the column simply could not be declared.
@Test func unsignedSixtyFourBitRoundTripsAcrossTheBoundary() throws {
    // Comfortably inside Int64: travels as an integer.
    #expect(UInt64(42).sqlValue == .int(42))
    #expect(try UInt64(sqlValue: .int(42)) == 42)

    // Above Int64.max: the driver hands it over as text, and it must survive.
    let huge = UInt64(Int64.max) + 1
    #expect(huge.sqlValue == .text("9223372036854775808"))
    #expect(try UInt64(sqlValue: .text("9223372036854775808")) == huge)
    #expect(try UInt64(sqlValue: UInt64.max.sqlValue) == UInt64.max)
}

@Test func aNegativeIntegerIsNotAnUnsignedOne() {
    #expect(throws: SQLDecodeError.self) { _ = try UInt64(sqlValue: .int(-1)) }
    #expect(throws: SQLDecodeError.self) { _ = try UInt64(sqlValue: .text("banana")) }
}

/// The lockfile stores signatures verbatim, so every part of one has to survive a
/// round trip — including the nested `SwiftType`, which is indirect.
@Test func aSignatureRoundTripsThroughTheLockfileEncoding() throws {
    let signature = QuerySignature(
        name: "OrderTotals",
        sql: "SELECT u.id, o.total FROM users u LEFT JOIN orders o ON o.user_id = u.id",
        cardinality: .many,
        parameters: [
            ParameterInfo(ordinal: 1, name: "userID", sqlType: "int8",
                          swiftType: .int64, source: .verified)
        ],
        columns: [
            ColumnInfo(name: "id", sqlType: "int8", swiftType: .int64, isOptional: false,
                       nullability: .baseColumnNotNull,
                       origin: ColumnOrigin(table: "users", column: "id")),
            ColumnInfo(name: "total", sqlType: "numeric(10,2)", swiftType: .decimalString,
                       isOptional: true, nullability: .outerJoinWidened,
                       origin: ColumnOrigin(table: "orders", column: "total")),
            ColumnInfo(name: "tags", sqlType: "_text", swiftType: .array(.string),
                       isOptional: true, nullability: .expression, origin: nil),
        ],
        hasOuterJoin: true
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(signature)
    #expect(try JSONDecoder().decode(QuerySignature.self, from: data) == signature)
}

/// The reason a column is optional is what makes a `--verify` diff readable, so
/// the pessimistic ones have to be distinguishable from the confident ones.
@Test func pessimisticReasonsAreDistinguishable() {
    #expect(NullabilityReason.outerJoinWidened.isPessimistic)
    #expect(NullabilityReason.expression.isPessimistic)
    #expect(NullabilityReason.unknownOrigin.isPessimistic)

    #expect(!NullabilityReason.engineFlag.isPessimistic)
    #expect(!NullabilityReason.baseColumnNotNull.isPessimistic)
    #expect(!NullabilityReason.annotationNotNull.isPessimistic)
}

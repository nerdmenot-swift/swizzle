import NIOCore
import Testing
@testable import SwizzleMySQL

/// The binary protocol's **parameter** encoders, which are the half no result
/// test reaches.
///
/// ## Why this needs its own suite
///
/// `COM_STMT_EXECUTE` writes a parameter's length and its bytes in two separate
/// passes over the same values: `binaryLength` sums the sizes to decide whether
/// the request fits in one packet, and `encodeBinary` writes the bytes. Nothing
/// checks that the two agree, and for temporals they each re-derive the width
/// from the value's contents — DATETIME picks 0, 4, 7 or 11 bytes depending on
/// which fields are non-zero, TIME picks 0, 8 or 12.
///
/// That duplication is the defect shape. If the two passes ever disagree the
/// packet is not merely wrong for that parameter: **every parameter after it is
/// misaligned**, because the values section has no per-value framing to
/// resynchronise on. The server reads the next parameter's type byte from the
/// middle of this one.
///
/// The mutation sweep left thirteen survivors across these two functions —
/// every branch of both width decisions — because the existing tests bind
/// integers and strings, and the temporal parameters were only ever exercised
/// through a server that accepted whatever it was sent.
///
/// ## Where the ground truth comes from
///
/// Agreement between the two passes is necessary but **not sufficient**: if both
/// derived the same wrong width the property still holds. That is exactly the
/// trap the Postgres pass hit three times — a test comparing the code against
/// itself and unable to fail. So the widths are also pinned as literal byte
/// counts from the protocol definition, and the encoded bytes are asserted
/// field by field, so a change to both passes still fails here.
@Suite("MySQL parameter encoding")
struct ParameterEncodingTests {

    static func encoded(_ value: MySQLValue) -> ByteBuffer {
        var buffer = ByteBuffer()
        MySQLStatementCommands.encodeBinary(value, into: &buffer)
        return buffer
    }

    // MARK: - The shapes

    /// Every combination that changes which branch the width decision takes,
    /// plus the boundaries within each field.
    static let dateTimes: [MySQLDateTime] = [
        .init(),                                                       // the zero date
        .init(year: 2024, month: 3, day: 5),                           // date only
        .init(year: 2024, month: 3, day: 5, hour: 14),                 // hour alone
        .init(year: 2024, month: 3, day: 5, minute: 30),               // minute alone
        .init(year: 2024, month: 3, day: 5, second: 7),                // second alone
        .init(year: 2024, month: 3, day: 5, hour: 14, minute: 30, second: 7),
        .init(year: 2024, month: 3, day: 5, microsecond: 1),           // micros, no time
        .init(year: 2024, month: 3, day: 5, hour: 14, minute: 30, second: 7,
              microsecond: 999_999),
        .init(year: 1000, month: 1, day: 1),                           // MySQL's minimum
        .init(year: 9999, month: 12, day: 31, hour: 23, minute: 59, second: 59,
              microsecond: 999_999),                                   // and its maximum
        // A time with no date. Not something a caller should bind, but the width
        // decision has a branch for it and the encoder must not disagree.
        .init(hour: 5),
        .init(microsecond: 1),
    ]

    static let times: [MySQLTime] = [
        .init(),                                                       // zero
        .init(isNegative: true),                                       // negative zero
        .init(seconds: 1),
        .init(minutes: 1),
        .init(hours: 1),
        .init(days: 1),
        .init(microseconds: 1),                                        // micros alone
        .init(isNegative: true, hours: 12, minutes: 34, seconds: 56),
        .init(days: 34, hours: 22, minutes: 59, seconds: 59, microseconds: 999_999),
        // 838:59:59 is the documented limit, which is 34 days and 22 hours.
        .init(isNegative: true, days: 34, hours: 22, minutes: 59, seconds: 59),
    ]

    // MARK: - The two passes must agree

    /// The property the whole suite exists for, stated over every shape.
    @Test("the declared length equals the bytes written, for every temporal shape")
    func declaredLengthMatchesBytesWritten() {
        for value in Self.dateTimes.map(MySQLValue.dateTime)
            + Self.times.map(MySQLValue.time)
        {
            let written = Self.encoded(value).readableBytes
            #expect(
                MySQLStatementCommands.binaryLength(value) == written,
                """
                \(value): binaryLength says \
                \(MySQLStatementCommands.binaryLength(value)), encode wrote \(written) — \
                every parameter after this one in the packet would be misaligned
                """
            )
        }
    }

    /// And over the non-temporal cases, which have fixed widths but are cheap to
    /// include and would catch a new case added to only one of the two switches.
    @Test("the declared length matches for every value case")
    func declaredLengthMatchesForEveryCase() {
        let values: [MySQLValue] = [
            .null, .int(0), .int(.min), .int(.max), .uint(0), .uint(.max),
            .float(0), .float(.infinity), .double(0), .double(.nan),
            .bytes([]), .bytes([1, 2, 3]),
            .bytes([UInt8](repeating: 7, count: 0xFB)),      // just past the 1-byte lenenc
            .bytes([UInt8](repeating: 7, count: 0x1_0000)),  // and past the 3-byte one
            .dateTime(.init(year: 2024, month: 1, day: 1)),
            .time(.init(hours: 1)),
        ]
        for value in values {
            #expect(
                MySQLStatementCommands.binaryLength(value) == Self.encoded(value).readableBytes,
                "\(value)"
            )
        }
    }

    // MARK: - The widths themselves

    /// The four DATETIME widths, as literal numbers rather than as whatever the
    /// code computes. This is the assertion that still fails if both passes are
    /// changed together.
    ///
    /// From the protocol definition: the body is 0 bytes for the zero date,
    /// 4 for a date, 7 with a time, and 11 with microseconds — each preceded by
    /// a length byte carrying that count.
    @Test("DATETIME uses the four widths the protocol defines")
    func dateTimeWidths() {
        let cases: [(MySQLDateTime, UInt8)] = [
            (.init(), 0),
            (.init(year: 2024, month: 3, day: 5), 4),
            (.init(year: 2024, month: 3, day: 5, second: 7), 7),
            (.init(year: 2024, month: 3, day: 5, microsecond: 1), 11),
        ]
        for (value, body) in cases {
            var buffer = Self.encoded(.dateTime(value))
            #expect(buffer.readableBytes == Int(body) + 1, "\(value) is length byte + body")
            #expect(buffer.readInteger(endianness: .little, as: UInt8.self) == body,
                    "\(value) declares its body length")
            #expect(buffer.readableBytes == Int(body), "\(value) then writes exactly that many")
        }
    }

    /// TIME's are 0, 8 and 12 — **not** DATETIME's 7 and 11, because the body
    /// carries a sign byte and a four-byte day count where DATETIME carries a
    /// two-byte year.
    @Test("TIME uses the three widths the protocol defines")
    func timeWidths() {
        let cases: [(MySQLTime, UInt8)] = [
            (.init(), 0),
            (.init(isNegative: true), 0),
            (.init(seconds: 1), 8),
            (.init(microseconds: 1), 12),
        ]
        for (value, body) in cases {
            var buffer = Self.encoded(.time(value))
            #expect(buffer.readableBytes == Int(body) + 1, "\(value) is length byte + body")
            #expect(buffer.readInteger(endianness: .little, as: UInt8.self) == body)
            #expect(buffer.readableBytes == Int(body))
        }
    }

    /// The field order and endianness, spelled out once. A width that is right
    /// with the fields in the wrong order is still a broken parameter.
    @Test("a full DATETIME writes its fields in protocol order")
    func dateTimeFieldOrder() {
        let value = MySQLDateTime(
            year: 2024, month: 3, day: 5, hour: 14, minute: 30, second: 7,
            microsecond: 123_456
        )
        var buffer = Self.encoded(.dateTime(value))
        #expect(buffer.readInteger(endianness: .little, as: UInt8.self) == 11)
        #expect(buffer.readInteger(endianness: .little, as: UInt16.self) == 2024)
        #expect(buffer.readInteger(endianness: .little, as: UInt8.self) == 3)
        #expect(buffer.readInteger(endianness: .little, as: UInt8.self) == 5)
        #expect(buffer.readInteger(endianness: .little, as: UInt8.self) == 14)
        #expect(buffer.readInteger(endianness: .little, as: UInt8.self) == 30)
        #expect(buffer.readInteger(endianness: .little, as: UInt8.self) == 7)
        #expect(buffer.readInteger(endianness: .little, as: UInt32.self) == 123_456)
        #expect(buffer.readableBytes == 0)
    }

    /// TIME's body leads with the sign, which is the field DATETIME has no
    /// equivalent of and the one a shared encoder would drop.
    @Test("a full TIME writes its sign, days and fields in protocol order")
    func timeFieldOrder() {
        let value = MySQLTime(
            isNegative: true, days: 34, hours: 22, minutes: 59, seconds: 59,
            microseconds: 123_456
        )
        var buffer = Self.encoded(.time(value))
        #expect(buffer.readInteger(endianness: .little, as: UInt8.self) == 12)
        #expect(buffer.readInteger(endianness: .little, as: UInt8.self) == 1, "negative")
        #expect(buffer.readInteger(endianness: .little, as: UInt32.self) == 34)
        #expect(buffer.readInteger(endianness: .little, as: UInt8.self) == 22)
        #expect(buffer.readInteger(endianness: .little, as: UInt8.self) == 59)
        #expect(buffer.readInteger(endianness: .little, as: UInt8.self) == 59)
        #expect(buffer.readInteger(endianness: .little, as: UInt32.self) == 123_456)
        #expect(buffer.readableBytes == 0)
    }

    // MARK: - Round trip

    /// Encoding then decoding returns the value, which is the end-to-end
    /// statement of the two widths agreeing: the decoder reads the length byte
    /// and trusts it, so a body shorter than declared leaves it reading the next
    /// parameter's bytes as this one's microseconds.
    @Test("every temporal shape survives an encode/decode round trip")
    func roundTrip() throws {
        for value in Self.dateTimes {
            var buffer = Self.encoded(.dateTime(value))
            #expect(try MySQLValue.decodeBinaryDateTime(&buffer) == value, "\(value)")
            #expect(buffer.readableBytes == 0, "\(value): the decoder consumed exactly the body")
        }
        for value in Self.times {
            var buffer = Self.encoded(.time(value))
            var expected = value
            // The zero body carries no sign, so negative zero decodes as zero.
            // Those denote the same duration; nothing else may differ.
            if value.days == 0 && value.hours == 0 && value.minutes == 0
                && value.seconds == 0 && value.microseconds == 0
            {
                expected.isNegative = false
            }
            #expect(try MySQLValue.decodeBinaryTime(&buffer) == expected, "\(value)")
            #expect(buffer.readableBytes == 0, "\(value): the decoder consumed exactly the body")
        }
    }

    /// The same property over random field values, seeded so a failure
    /// reproduces. The hand-picked shapes above cover the branches; this covers
    /// the combinations nobody thought to list.
    @Test("random temporal values round trip and declare their own length",
          arguments: fuzzSeeds(8))
    func randomTemporalsRoundTrip(seed: UInt64) throws {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1
        func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        for _ in 0..<300 {
            // Deliberately biased towards zero in each field, because zero is
            // what every width decision branches on — uniform values would
            // almost never produce a date-only or a zero value.
            func field(_ bound: UInt64) -> UInt64 { next() % 3 == 0 ? 0 : next() % bound }

            let dateTime = MySQLDateTime(
                year: UInt16(field(10000)), month: UInt8(field(13)), day: UInt8(field(32)),
                hour: UInt8(field(24)), minute: UInt8(field(60)), second: UInt8(field(60)),
                microsecond: UInt32(field(1_000_000))
            )
            var dateTimeBuffer = Self.encoded(.dateTime(dateTime))
            #expect(
                MySQLStatementCommands.binaryLength(.dateTime(dateTime))
                    == dateTimeBuffer.readableBytes,
                "seed \(seed): \(dateTime)"
            )
            #expect(try MySQLValue.decodeBinaryDateTime(&dateTimeBuffer) == dateTime,
                    "seed \(seed): \(dateTime)")

            let time = MySQLTime(
                isNegative: next() % 2 == 0, days: UInt32(field(35)),
                hours: UInt8(field(24)), minutes: UInt8(field(60)),
                seconds: UInt8(field(60)), microseconds: UInt32(field(1_000_000))
            )
            let timeBuffer = Self.encoded(.time(time))
            #expect(
                MySQLStatementCommands.binaryLength(.time(time)) == timeBuffer.readableBytes,
                "seed \(seed): \(time)"
            )
        }
    }

    // MARK: - The assembled request

    /// The lengths are summed to size the request, so the sum has to match the
    /// values section of the packet it produces. A per-value agreement that did
    /// not add up would still misframe the request.
    @Test("the summed parameter lengths match the request's values section")
    func summedLengthsMatchTheRequest() {
        let parameters: [MySQLValue] = [
            .int(-1), .null, .bytes(Array("hello".utf8)),
            .dateTime(.init(year: 2024, month: 3, day: 5, microsecond: 1)),
            .time(.init(isNegative: true, days: 1, hours: 2)),
            .null,
            .dateTime(.init()),
            .double(1.5),
        ]
        let (buffer, requiresLongData) =
            MySQLStatementCommands.execute(statementID: 1, parameters: parameters)
        #expect(!requiresLongData)

        // header(10) + null bitmap + NEW_PARAMS_BOUND(1) + two type bytes each
        let bitmapBytes = (parameters.count + 7) / 8
        let header = 10 + bitmapBytes + 1 + parameters.count * 2
        let declared = parameters
            .filter { !$0.isNull }
            .reduce(0) { $0 + MySQLStatementCommands.binaryLength($1) }
        #expect(buffer.readableBytes == header + declared)
    }

    /// NULL parameters contribute nothing to the values section — they are
    /// carried entirely by the bitmap — so a length of zero has to mean zero
    /// bytes written, not a zero-length placeholder.
    @Test("a NULL parameter occupies no bytes in the values section")
    func nullOccupiesNoBytes() {
        #expect(MySQLStatementCommands.binaryLength(.null) == 0)
        #expect(Self.encoded(.null).readableBytes == 0)

        let withNulls = MySQLStatementCommands.execute(
            statementID: 1, parameters: [.null, .null, .null]
        ).buffer
        let withoutValues = 10 + 1 + 1 + 3 * 2
        #expect(withNulls.readableBytes == withoutValues)
    }

    // MARK: - The long-data boundary

    /// `requiresLongData` is what routes a large parameter through
    /// `COM_STMT_SEND_LONG_DATA` instead of inline, and it turns over at exactly
    /// one packet's payload. Both sides of that boundary, because "fits" and
    /// "does not fit" differ by a single byte and the comparison is the kind
    /// that gets written as `>=` by accident.
    @Test("the long-data threshold turns over at exactly one packet payload")
    func longDataBoundary() {
        // header(10) + bitmap(1) + bound(1) + types(2) + lenenc(4) = 18
        let overhead = 18
        let exact = MySQLStatementCommands.maxInlineRequestSize - overhead

        let fits = MySQLStatementCommands.execute(
            statementID: 1, parameters: [.bytes([UInt8](repeating: 0, count: exact))]
        )
        #expect(fits.buffer.readableBytes == MySQLStatementCommands.maxInlineRequestSize,
                "the arithmetic above must actually land on the boundary")
        #expect(!fits.requiresLongData, "a request of exactly one payload still fits in one")

        let overflows = MySQLStatementCommands.execute(
            statementID: 1, parameters: [.bytes([UInt8](repeating: 0, count: exact + 1))]
        )
        #expect(overflows.requiresLongData, "one byte more does not")
    }

    /// And when the caller re-encodes after shipping the long data, the byte
    /// values are gone from the packet but their type bytes remain — otherwise
    /// the server cannot tell what it was sent.
    @Test("re-encoding without byte values keeps the parameter types")
    func omittingByteValuesKeepsTypes() {
        let parameters: [MySQLValue] = [.bytes(Array("hello".utf8)), .int(7)]
        let full = MySQLStatementCommands.execute(statementID: 1, parameters: parameters).buffer
        let omitted = MySQLStatementCommands.execute(
            statementID: 1, parameters: parameters, omittingByteValues: true
        ).buffer

        // Only the string's own bytes go: its length prefix goes with them.
        #expect(omitted.readableBytes == full.readableBytes - (1 + 5))
        #expect(omitted.readableBytes > 10 + 1 + 1 + 4, "the type bytes stay")
    }
}

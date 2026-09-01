import NIOCore
import SwizzleCore
import Testing
@testable import SwizzleMySQL

@Suite("Column types")
struct ColumnTypeTests {

    @Test func rawValuesMatchTheProtocol() {
        #expect(MySQLColumnType.decimal.rawValue == 0)
        #expect(MySQLColumnType.tiny.rawValue == 1)
        #expect(MySQLColumnType.longlong.rawValue == 8)
        #expect(MySQLColumnType.typedArray.rawValue == 20)
        // The gap between 20 and 242 is real; MySQL reuses the high byte range
        // for later types.
        #expect(MySQLColumnType.vector.rawValue == 242)
        #expect(MySQLColumnType.json.rawValue == 245)
        #expect(MySQLColumnType.newdecimal.rawValue == 246)
        #expect(MySQLColumnType.geometry.rawValue == 255)
    }

    /// A type we don't know must degrade to raw bytes, not fail the result set.
    @Test func unknownTypeDegradesGracefully() {
        #expect(MySQLColumnType(rawValueOrUnknown: 200) == .unknown)
        #expect(MySQLColumnType.unknown.isBinaryEncodedAsBytes)
    }

    /// DECIMAL must never route through binary floating point.
    @Test func decimalsAreExactAndByteEncoded() {
        #expect(MySQLColumnType.decimal.isExactNumeric)
        #expect(MySQLColumnType.newdecimal.isExactNumeric)
        #expect(MySQLColumnType.newdecimal.isBinaryEncodedAsBytes)
        #expect(MySQLColumnType.double.isExactNumeric == false)
    }
}

@Suite("Text value decoding")
struct TextValueTests {

    static func buffer(_ text: String) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeString(text)
        return buffer
    }

    static func decode(
        _ text: String, _ type: MySQLColumnType, _ flags: MySQLColumnFlags = []
    ) -> MySQLValue {
        MySQLValue.decodeText(buffer(text), type: type, flags: flags)
    }

    @Test func signedAndUnsignedIntegersDifferByFlag() {
        #expect(Self.decode("-5", .long) == .int(-5))
        #expect(Self.decode("5", .long, .unsigned) == .uint(5))
        // 2^63 doesn't fit Int64; only the UNSIGNED flag makes it decodable.
        #expect(Self.decode("9223372036854775808", .longlong, .unsigned)
            == .uint(9_223_372_036_854_775_808))
    }

    /// The whole point of keeping DECIMAL textual.
    @Test func decimalKeepsFullPrecision() {
        let value = Self.decode("12345678901234567890.123456789", .newdecimal)
        #expect(value.string == "12345678901234567890.123456789")
        guard case .bytes = value else {
            Issue.record("DECIMAL must stay bytes, never a Double")
            return
        }
    }

    @Test func floatsAndDoublesParse() {
        #expect(Self.decode("1.5", .double) == .double(1.5))
        #expect(Self.decode("1.5", .float) == .float(1.5))
    }

    @Test func dateTimeParses() {
        guard case .dateTime(let value) = Self.decode("2024-01-15 13:45:30", .datetime) else {
            Issue.record("expected a datetime"); return
        }
        #expect(value.year == 2024)
        #expect(value.month == 1)
        #expect(value.day == 15)
        #expect(value.hour == 13)
        #expect(value.minute == 45)
        #expect(value.second == 30)
    }

    @Test func dateWithoutTimeParses() {
        guard case .dateTime(let value) = Self.decode("2024-06-01", .date) else {
            Issue.record("expected a date"); return
        }
        #expect(value.year == 2024)
        #expect(value.hour == 0)
    }

    /// MySQL's zero date is a legal column value, which is why we don't convert
    /// eagerly to `Foundation.Date`.
    @Test func zeroDateIsRepresentable() {
        guard case .dateTime(let value) = Self.decode("0000-00-00 00:00:00", .datetime) else {
            Issue.record("expected a datetime"); return
        }
        #expect(value.isZero)
    }

    /// A fractional second is scaled to microseconds — ".5" is 500000, not 5.
    @Test func fractionalSecondsScaleToMicroseconds() {
        guard case .dateTime(let half) = Self.decode("2024-01-01 00:00:00.5", .datetime),
              case .dateTime(let full) = Self.decode("2024-01-01 00:00:00.123456", .datetime)
        else {
            Issue.record("expected datetimes"); return
        }
        #expect(half.microsecond == 500_000)
        #expect(full.microsecond == 123_456)
    }

    /// TIME is a signed duration, not a clock time — it can exceed 24 hours and
    /// can be negative.
    @Test func timeIsADurationNotAClock() {
        guard case .time(let value) = Self.decode("-838:59:59", .time) else {
            Issue.record("expected a time"); return
        }
        #expect(value.isNegative)
        #expect(value.totalHours == 838)
        #expect(value.days == 34)          // 838 / 24
        #expect(value.hours == 22)         // 838 % 24
        #expect(value.minutes == 59)
        #expect(value.seconds == 59)
    }

    @Test func blobsAndJSONStayAsBytes() {
        guard case .bytes = Self.decode("{\"a\":1}", .json) else {
            Issue.record("JSON must stay bytes"); return
        }
        guard case .bytes = Self.decode("\u{01}\u{02}", .blob) else {
            Issue.record("BLOB must stay bytes"); return
        }
    }
}

@Suite("Binary value decoding")
struct BinaryValueTests {

    static func decode(
        _ bytes: [UInt8], _ type: MySQLColumnType, _ flags: MySQLColumnFlags = []
    ) throws -> MySQLValue {
        var buffer = ByteBuffer()
        buffer.writeBytes(bytes)
        return try MySQLValue.decodeBinary(&buffer, type: type, flags: flags)
    }

    @Test func integerWidthsAndSignedness() throws {
        #expect(try Self.decode([0xFF], .tiny) == .int(-1))
        #expect(try Self.decode([0xFF], .tiny, .unsigned) == .uint(255))
        #expect(try Self.decode([0xFF, 0xFF], .short) == .int(-1))
        #expect(try Self.decode([0xFF, 0xFF, 0xFF, 0xFF], .long) == .int(-1))
        #expect(try Self.decode([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], .longlong)
            == .int(-1))
        #expect(try Self.decode([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], .longlong, .unsigned)
            == .uint(UInt64.max))
    }

    /// INT24 occupies 4 bytes on the wire despite being a 3-byte column type.
    @Test func int24OccupiesFourBytes() throws {
        var buffer = ByteBuffer()
        buffer.writeBytes([0x01, 0x00, 0x00, 0x00, 0xAA])
        let value = try MySQLValue.decodeBinary(&buffer, type: .int24, flags: [])
        #expect(value == .int(1))
        #expect(buffer.readableBytes == 1)   // only the trailing 0xAA remains
    }

    @Test func floatsUseIEEEBitPatterns() throws {
        var floatBuffer = ByteBuffer()
        floatBuffer.writeInteger(Float(1.5).bitPattern, endianness: .little)
        var f = floatBuffer
        #expect(try MySQLValue.decodeBinary(&f, type: .float, flags: []) == .float(1.5))

        var doubleBuffer = ByteBuffer()
        doubleBuffer.writeInteger(Double(2.25).bitPattern, endianness: .little)
        var d = doubleBuffer
        #expect(try MySQLValue.decodeBinary(&d, type: .double, flags: []) == .double(2.25))
    }

    /// DATETIME is length-prefixed and variable: 0, 4, 7 or 11 bytes.
    @Test func dateTimeLengthVariants() throws {
        // 0 bytes -> zero date
        guard case .dateTime(let zero) = try Self.decode([0x00], .datetime) else {
            Issue.record("expected datetime"); return
        }
        #expect(zero.isZero)

        // 4 bytes -> date only
        guard case .dateTime(let dateOnly) =
                try Self.decode([0x04, 0xE8, 0x07, 0x01, 0x0F], .datetime) else {
            Issue.record("expected datetime"); return
        }
        #expect(dateOnly.year == 2024 && dateOnly.month == 1 && dateOnly.day == 15)
        #expect(dateOnly.hour == 0)

        // 7 bytes -> date + time
        guard case .dateTime(let withTime) =
                try Self.decode([0x07, 0xE8, 0x07, 0x01, 0x0F, 0x0D, 0x2D, 0x1E], .datetime) else {
            Issue.record("expected datetime"); return
        }
        #expect(withTime.hour == 13 && withTime.minute == 45 && withTime.second == 30)
        #expect(withTime.microsecond == 0)

        // 11 bytes -> + microseconds
        guard case .dateTime(let withMicros) = try Self.decode(
            [0x0B, 0xE8, 0x07, 0x01, 0x0F, 0x0D, 0x2D, 0x1E, 0x40, 0xE2, 0x01, 0x00], .datetime
        ) else {
            Issue.record("expected datetime"); return
        }
        #expect(withMicros.microsecond == 123_456)
    }

    /// TIME uses 8/12-byte lengths, **not** DATETIME's 7/11, and carries a sign
    /// plus a whole-days field.
    @Test func timeUsesItsOwnLengths() throws {
        guard case .time(let value) = try Self.decode(
            [0x08, 0x01, 0x22, 0x00, 0x00, 0x00, 0x16, 0x3B, 0x3B], .time
        ) else {
            Issue.record("expected time"); return
        }
        #expect(value.isNegative)
        #expect(value.days == 34)
        #expect(value.hours == 22)
        #expect(value.minutes == 59)
        #expect(value.seconds == 59)
        #expect(value.totalHours == 838)
    }

    /// An unfamiliar length must not desynchronise the rest of the row: the
    /// payload is consumed as a fixed-size slice.
    @Test func unexpectedTemporalLengthDoesNotDesync() throws {
        var buffer = ByteBuffer()
        buffer.writeBytes([0x05, 0xE8, 0x07, 0x01, 0x0F, 0x63])   // length 5
        buffer.writeBytes([0xAB])                                  // next value
        _ = try MySQLValue.decodeBinary(&buffer, type: .datetime, flags: [])
        #expect(buffer.readableBytes == 1)
        #expect(buffer.readInteger(endianness: .little, as: UInt8.self) == 0xAB)
    }

    @Test func byteTypesAreLengthEncoded() throws {
        var buffer = ByteBuffer()
        buffer.writeLengthEncodedString("hello")
        let value = try MySQLValue.decodeBinary(&buffer, type: .varString, flags: [])
        #expect(value.string == "hello")
    }
}

@Suite("NULL bitmap")
struct NullBitmapTests {

    /// The byte length depends on the side's bit offset, so a client-side
    /// bitmap can be one byte shorter than a server-side one for the same
    /// column count.
    @Test func lengthDependsOnSide() {
        #expect(MySQLNullBitmap.byteCount(columnCount: 1, side: .client) == 1)
        #expect(MySQLNullBitmap.byteCount(columnCount: 1, side: .server) == 1)
        #expect(MySQLNullBitmap.byteCount(columnCount: 7, side: .client) == 1)
        #expect(MySQLNullBitmap.byteCount(columnCount: 7, side: .server) == 2)
        #expect(MySQLNullBitmap.byteCount(columnCount: 9, side: .client) == 2)
    }

    /// Server-side rows reserve the first two bits, so column 0 is bit 2.
    @Test func serverSideIsOffsetByTwoBits() {
        var bitmap = MySQLNullBitmap(columnCount: 4, side: .server)
        bitmap.setNull(0)
        #expect(bitmap.bytes[0] == 0b0000_0100)
        #expect(bitmap.isNull(0))
        #expect(bitmap.isNull(1) == false)
    }

    @Test func clientSideStartsAtBitZero() {
        var bitmap = MySQLNullBitmap(columnCount: 4, side: .client)
        bitmap.setNull(0)
        #expect(bitmap.bytes[0] == 0b0000_0001)
        #expect(bitmap.isNull(0))
    }

    /// Reading a server bitmap with client-side rules shifts every column by
    /// two — the kind of mistake that silently returns the wrong values rather
    /// than erroring.
    @Test func wrongSideMisreadsColumns() {
        var server = MySQLNullBitmap(columnCount: 4, side: .server)
        server.setNull(2)
        let misread = MySQLNullBitmap(bytes: server.bytes, columnCount: 4, side: .client)
        #expect(server.isNull(2))
        #expect(misread.isNull(2) == false)
        #expect(misread.isNull(4))     // shifted by the two reserved bits
    }
}

@Suite("Binary row")
struct BinaryRowTests {

    static func column(_ name: String, _ type: MySQLColumnType, unsigned: Bool = false)
        -> MySQLColumnDefinition
    {
        MySQLColumnDefinition(
            catalog: "def", schema: "s", table: "t", originalTable: "t",
            name: name, originalName: name,
            characterSet: 45, columnLength: 11, type: type.rawValue,
            flags: unsigned ? .unsigned : [], decimals: 0
        )
    }

    /// NULL columns occupy **no bytes** in the payload, so a mis-parsed bitmap
    /// corrupts every value after it rather than just one.
    @Test func nullColumnsConsumeNoPayloadBytes() throws {
        let columns = [Self.column("a", .long), Self.column("b", .long), Self.column("c", .long)]

        var bitmap = MySQLNullBitmap(columnCount: 3, side: .server)
        bitmap.setNull(1)

        var buffer = ByteBuffer()
        buffer.writeInteger(UInt8(0x00), endianness: .little)
        buffer.writeBytes(bitmap.bytes)
        buffer.writeInteger(UInt32(10), endianness: .little)   // a
        buffer.writeInteger(UInt32(30), endianness: .little)   // c — b is absent

        let row = try MySQLBinaryRow.parse(&buffer, columns: columns)
        #expect(row.values[0] == .int(10))
        #expect(row.values[1] == .null)
        #expect(row.values[2] == .int(30))
        #expect(buffer.readableBytes == 0)
    }

    @Test func mixedTypesRoundTrip() throws {
        let columns = [
            Self.column("i", .long),
            Self.column("s", .varString),
            Self.column("d", .newdecimal),
        ]
        let bitmap = MySQLNullBitmap(columnCount: 3, side: .server)

        var buffer = ByteBuffer()
        buffer.writeInteger(UInt8(0x00), endianness: .little)
        buffer.writeBytes(bitmap.bytes)
        buffer.writeInteger(UInt32(7), endianness: .little)
        buffer.writeLengthEncodedString("hi")
        buffer.writeLengthEncodedString("1.25")

        let row = try MySQLBinaryRow.parse(&buffer, columns: columns)
        #expect(row.values[0] == .int(7))
        #expect(row.values[1].string == "hi")
        // DECIMAL stays textual even in the binary protocol.
        #expect(row.values[2] == .bytes(Array("1.25".utf8)))
    }
}

@Suite("SwizzleCore bridging")
struct ValueBridgingTests {

    @Test func scalarsBridge() {
        #expect(MySQLValue.null.sqlValue == SQLValue.null)
        #expect(MySQLValue.int(5).sqlValue == SQLValue.int(5))
        #expect(MySQLValue.double(1.5).sqlValue == SQLValue.double(1.5))
        #expect(MySQLValue.bytes(Array("hi".utf8)).sqlValue == SQLValue.text("hi"))
    }

    /// A UInt64 above Int64.max cannot become an `.int` without wrapping, so it
    /// crosses as text rather than silently going negative.
    @Test func hugeUnsignedCrossesAsText() {
        #expect(MySQLValue.uint(UInt64.max).sqlValue == SQLValue.text("18446744073709551615"))
        #expect(MySQLValue.uint(5).sqlValue == SQLValue.int(5))
    }

    /// Temporals cross as text; converting a DECIMAL to Double here would
    /// defeat keeping it textual on the wire.
    @Test func temporalsCrossAsText() {
        let value = MySQLValue.dateTime(
            MySQLDateTime(year: 2024, month: 1, day: 15, hour: 13, minute: 45, second: 30)
        )
        #expect(value.sqlValue == SQLValue.text("2024-01-15 13:45:30"))
    }

    /// Non-UTF-8 bytes must not be lost to a lossy string conversion.
    @Test func invalidUTF8BecomesBlob() {
        let value = MySQLValue.bytes([0xFF, 0xFE, 0x00])
        #expect(value.sqlValue == SQLValue.blob([0xFF, 0xFE, 0x00]))
    }
}

/// Edge cases of the byte-level text parsers.
///
/// These parsers replaced `String` + `split` versions for speed — a `DATETIME`
/// went from 907 ns to 19 ns — and a rewrite of a parser is exactly the kind of
/// change that keeps the common case working while quietly breaking the ends of
/// the range. Everything here is a boundary: the widest and narrowest legal
/// value, the malformed input, and the input that used to be accepted and
/// should not be.
@Suite("Text parsing edges")
struct TextParsingEdgeTests {

    static func decode(
        _ text: String, _ type: MySQLColumnType, _ flags: MySQLColumnFlags = []
    ) -> MySQLValue {
        TextValueTests.decode(text, type, flags)
    }

    // MARK: Integers

    /// `Int64.min` has no positive counterpart, so a parser that reads the
    /// magnitude and negates it overflows on exactly this one value.
    @Test func int64MinParses() {
        #expect(Self.decode("-9223372036854775808", .longlong) == .int(Int64.min))
        #expect(Self.decode("9223372036854775807", .longlong) == .int(Int64.max))
    }

    /// Out of range falls back to the raw bytes rather than wrapping — the
    /// caller gets the server's literal text and can see it did not fit.
    @Test func outOfRangeIntegersFallBackToBytes() {
        #expect(Self.decode("9223372036854775808", .longlong) == .bytes(Array("9223372036854775808".utf8)))
        #expect(Self.decode("-9223372036854775809", .longlong) == .bytes(Array("-9223372036854775809".utf8)))
        #expect(
            Self.decode("18446744073709551616", .longlong, [.unsigned])
                == .bytes(Array("18446744073709551616".utf8))
        )
    }

    @Test func unsignedRangeReachesTheTop() {
        #expect(
            Self.decode("18446744073709551615", .longlong, [.unsigned]) == .uint(UInt64.max)
        )
    }

    /// A negative value in an unsigned column is not silently reinterpreted.
    @Test func negativeIsRejectedForUnsigned() {
        #expect(Self.decode("-1", .long, [.unsigned]) == .bytes(Array("-1".utf8)))
    }

    @Test(arguments: ["", " 1", "1 ", "1.5", "0x10", "12a", "--1", "+"])
    func malformedIntegersFallBackToBytes(text: String) {
        #expect(Self.decode(text, .long) == .bytes(Array(text.utf8)))
    }

    @Test func leadingZerosAndSignsParse() {
        #expect(Self.decode("0007", .long) == .int(7))
        #expect(Self.decode("+7", .long) == .int(7))
        #expect(Self.decode("-0", .long) == .int(0))
    }

    // MARK: Temporals

    @Test func dateWithoutAClockParses() {
        guard case .dateTime(let value) = Self.decode("2024-03-17", .date) else {
            Issue.record("expected a datetime"); return
        }
        #expect(value == MySQLDateTime(year: 2024, month: 3, day: 17))
    }

    @Test func theZeroDateParses() {
        guard case .dateTime(let value) = Self.decode("0000-00-00 00:00:00", .datetime) else {
            Issue.record("expected a datetime"); return
        }
        #expect(value.isZero)
    }

    /// `.5` is half a second — 500000 microseconds, not 5. The scale depends on
    /// how many digits the server wrote, which is the part that is easy to get
    /// backwards.
    @Test(arguments: [
        ("5", UInt32(500_000)), ("50", 500_000), ("05", 50_000),
        ("123456", 123_456), ("000001", 1), ("1", 100_000),
    ])
    func fractionalSecondsScaleByDigitCount(digits: String, expected: UInt32) {
        guard case .dateTime(let value) =
            Self.decode("2024-01-01 00:00:00.\(digits)", .datetime)
        else {
            Issue.record("expected a datetime for .\(digits)"); return
        }
        #expect(value.microsecond == expected)
    }

    /// MySQL caps fractional seconds at microseconds, so a seventh digit is
    /// dropped rather than shifting the value by a factor of ten.
    @Test func extraFractionalDigitsAreDropped() {
        guard case .dateTime(let value) =
            Self.decode("2024-01-01 00:00:00.1234567", .datetime)
        else {
            Issue.record("expected a datetime"); return
        }
        #expect(value.microsecond == 123_456)
    }

    /// The old `split`-based parser accepted these, decoding a value that was
    /// partly invented — `12:34:56.9z` became 12:34:56 with the microseconds
    /// silently zeroed. Falling back to bytes hands the caller what the server
    /// actually sent.
    @Test(arguments: [
        "2024-03-17 12:34:56.9z", "2024-03-17 12:34", "2024-03-17T12:34:56",
        "2024-03-17 12:34:56 ", "2024-03", "2024-03-17 12:34:56.",
        "not-a-date", "",
    ])
    func malformedDateTimesFallBackToBytes(text: String) {
        #expect(Self.decode(text, .datetime) == .bytes(Array(text.utf8)))
    }

    /// TIME is a duration, so it is signed and its hours run past 24 — the
    /// documented range is ±838:59:59.
    @Test func timeCarriesSignAndOverflowingHours() {
        guard case .time(let value) = Self.decode("-838:59:59", .time) else {
            Issue.record("expected a time"); return
        }
        #expect(value.isNegative)
        #expect(value.totalHours == 838)
        #expect(value.days == 34)
        #expect(value.hours == 22)
        #expect(value.minutes == 59)
        #expect(value.seconds == 59)
    }

    @Test func positiveTimeWithFraction() {
        guard case .time(let value) = Self.decode("01:02:03.5", .time) else {
            Issue.record("expected a time"); return
        }
        #expect(!value.isNegative)
        #expect(value.totalHours == 1)
        #expect(value.microseconds == 500_000)
    }

    @Test(arguments: ["12:34", "12:34:56:78", "-", "12:34:56x", "::"])
    func malformedTimesFallBackToBytes(text: String) {
        #expect(Self.decode(text, .time) == .bytes(Array(text.utf8)))
    }

    /// Rendering is what `.string` gives a caller, so it has to invert parsing.
    @Test(arguments: [
        "2024-03-17 12:34:56.123456", "0000-00-00 00:00:00", "2024-03-17 00:00:00",
    ])
    func dateTimesRoundTripThroughText(text: String) {
        guard case .dateTime(let value) = Self.decode(text, .datetime) else {
            Issue.record("expected a datetime"); return
        }
        #expect(MySQLValue.render(value) == text)
    }
}

/// Decoding a column into `Bool`, which has no MySQL type of its own.
///
/// `BOOL` and `BOOLEAN` are spellings of `TINYINT(1)`, so the value arrives as
/// an integer and "non-zero is true" is exactly what the server does. That part
/// is unambiguous.
///
/// The byte-shaped arm is not, and the boundary is worth stating because it
/// cannot be resolved where the decoding happens.
@Suite("Bool decoding")
struct BoolDecodingTests {

    @Test("a signed integer is true when non-zero")
    func signedIntegers() throws {
        #expect(try Bool(mysqlValue: .int(0)) == false)
        #expect(try Bool(mysqlValue: .int(1)) == true)
        #expect(try Bool(mysqlValue: .int(-1)) == true, "non-zero, not positive")
        #expect(try Bool(mysqlValue: .int(2)) == true)
        #expect(try Bool(mysqlValue: .int(.min)) == true)
        #expect(try Bool(mysqlValue: .int(.max)) == true)
    }

    @Test("an unsigned integer is true when non-zero")
    func unsignedIntegers() throws {
        #expect(try Bool(mysqlValue: .uint(0)) == false)
        #expect(try Bool(mysqlValue: .uint(1)) == true)
        #expect(try Bool(mysqlValue: .uint(.max)) == true)
    }

    /// A single byte is how `BIT(1)` arrives — 0x00 or 0x01 — and the rule that
    /// works for it is the same non-zero rule.
    @Test("a single byte is true when non-zero")
    func singleByte() throws {
        #expect(try Bool(mysqlValue: .bytes([0x00])) == false)
        #expect(try Bool(mysqlValue: .bytes([0x01])) == true)
        #expect(try Bool(mysqlValue: .bytes([0xFF])) == true)
    }

    /// **A known ambiguity, pinned so a change to it is deliberate.**
    ///
    /// `BIT(8)` holding 48 and `CHAR(1)` holding `'0'` are the *same value* by
    /// the time they reach here: `.bytes([0x30])`. MySQL evaluates them
    /// oppositely — the bit field is 48, which is true; the string `'0'`
    /// converts to the number 0, which is false — and nothing in `MySQLValue`
    /// distinguishes them, because `MySQLDecodable` is handed a value and not
    /// the column it came from.
    ///
    /// So this is not a decision the decoder can get right. It takes the bit
    /// field reading, which is correct for `BIT` and wrong for a legacy
    /// `CHAR(1)` flag column storing `'0'` — that decodes as `true`.
    ///
    /// Resolving it means widening the protocol to carry the column type, which
    /// is an API change rather than a fix, so it is recorded here rather than
    /// guessed at.
    @Test("an ASCII digit byte takes the bit-field reading, not the string one")
    func asciiDigitIsAmbiguous() throws {
        #expect(
            try Bool(mysqlValue: .bytes([0x30])) == true,
            "ASCII '0' is a non-zero byte; MySQL would read the string as false"
        )
        #expect(try Bool(mysqlValue: .bytes([0x31])) == true)
    }

    /// Anything that is not one of those shapes throws rather than guessing —
    /// including a multi-byte string, which is where a caller who wanted the
    /// string reading would find out.
    @Test("other shapes throw rather than guessing")
    func otherShapesThrow() {
        for value: MySQLValue in [
            .null, .bytes([]), .bytes([0x30, 0x30]), .bytes(Array("true".utf8)),
            .double(1), .float(1), .dateTime(.init()), .time(.init()),
        ] {
            #expect(throws: MySQLDecodingError.self, "\(value)") {
                try Bool(mysqlValue: value)
            }
        }
    }
}

import Testing

@testable import SwizzleMySQL

/// DECIMAL column metadata that a peer can send but MySQL would never produce.
///
/// ## Where the numbers come from
///
/// A binlog table map event describes each DECIMAL column with a single 16-bit
/// metadata word: the high byte is the precision, the low byte the scale. They
/// are two independent bytes. Nothing in the encoding constrains one against
/// the other, so `scale > precision` is expressible — and a real MySQL server
/// will never send it, which is exactly why it was never considered.
///
/// The decoder computed `precision - scale` and used the result as a digit
/// count. Negative, that is not a small number of digits: it indexes a lookup
/// table at a negative offset and builds a `Range` whose bounds are reversed.
/// Both crash the process, on the decode path for any row event a replication
/// peer sends.
///
/// This is the same audit that found five overflow traps in the connection
/// pool, pointed at a driver rather than at the pool.
///
/// ## How it stayed hidden with a test sitting on top of it
///
/// `BinlogTests.truncatedPackedDecimal` already drives this decoder with
/// deliberately hostile input — every truncation of every buffer length. But
/// its loop reads `for scale in [0, 2, 6, 9] where scale <= precision`. The
/// filter is there because those are the only combinations a real server
/// sends, which is the same reason nobody looked: the test asked what happens
/// when the *bytes* are wrong and never what happens when the *description of
/// the bytes* is wrong.
///
/// That is the shape to watch for. A hostile-input test constrained to inputs
/// a well-behaved peer would produce is testing the happy path with extra
/// steps. The sweep below removes the filter entirely rather than widening it,
/// because both bytes are unconstrained on the wire and the whole 16-bit space
/// is cheap to walk.
@Suite("Binlog DECIMAL metadata")
struct BinlogDecimalMetadataTests {

    /// **The byte-count helper must not index a table at a negative offset.**
    /// `precision 0, scale 255` gives `-255` integer digits, and `-255 % 9` is
    /// `-3` in Swift — an out-of-bounds read on a ten-element array.
    @Test("a scale larger than the precision does not index out of bounds")
    func byteCountWithScaleAbovePrecision() {
        let count = MySQLBinlogRowDecoder.decimalByteCount(precision: 0, scale: 255)
        #expect(count >= 0, "a byte count cannot be negative")
    }

    /// The decoder itself builds `0..<(integerDigits / 9)` from the same
    /// quantity, which is a reversed range when it is negative.
    @Test("a scale larger than the precision does not build a reversed range")
    func decodeWithScaleAbovePrecision() {
        let decoded = MySQLBinlogRowDecoder.decodeDecimal(
            [0x80, 0x00, 0x00, 0x00], precision: 0, scale: 255
        )
        #expect(!decoded.isEmpty)
    }

    /// A sweep of the whole expressible metadata space. Both bytes are
    /// unconstrained, so every one of these 65536 words can arrive; none may
    /// crash. This is cheap and total, which beats picking interesting values.
    @Test("no metadata word in the whole 16-bit space crashes the decoder")
    func everyMetadataWordIsSurvivable() {
        for word in 0...UInt16.max {
            let precision = Int(word >> 8)
            let scale = Int(word & 0xFF)
            let count = MySQLBinlogRowDecoder.decimalByteCount(precision: precision, scale: scale)
            #expect(count >= 0, "negative byte count for metadata \(word)")
        }
    }

    /// **The control.** Clamping must not have quietly changed what a valid
    /// DECIMAL decodes to. `DECIMAL(10,2)` is one partial integer group plus
    /// one partial fraction group, and its size and value are both fixed.
    @Test("a valid DECIMAL still measures and decodes exactly as before")
    func validDecimalUnchanged() {
        // Worked from the documented packing, not from what the code returns:
        // nine digits per four bytes, with a partial group at each end sized by
        // dig2bytes = [0,1,1,2,2,3,3,4,4,4]. Asserting whatever the
        // implementation happens to produce would compare it against itself.
        //
        //   (10,2): intg 8, frac 2 -> 0*4 + d[8] + 0*4 + d[2] = 4 + 1 = 5
        //   (65,30): intg 35, frac 30 -> 3*4 + d[8] + 3*4 + d[3] = 12+4+12+2 = 30
        //   (1,0): intg 1, frac 0 -> d[1] + d[0] = 1 + 0 = 1
        #expect(MySQLBinlogRowDecoder.decimalByteCount(precision: 10, scale: 2) == 5)
        #expect(MySQLBinlogRowDecoder.decimalByteCount(precision: 65, scale: 30) == 30)
        #expect(MySQLBinlogRowDecoder.decimalByteCount(precision: 1, scale: 0) == 1)

        // 1234.56 at DECIMAL(6,2): intg 4 -> d[4] = 2 bytes holding 1234
        // (0x04D2), frac 2 -> d[2] = 1 byte holding 56 (0x38), and the sign bit
        // of the first byte set because the value is positive.
        let packed: [UInt8] = [0x04 | 0x80, 0xD2, 0x38]
        #expect(MySQLBinlogRowDecoder.decodeDecimal(packed, precision: 6, scale: 2) == "1234.56")
    }

    /// A scale equal to the precision is legitimate — `DECIMAL(2,2)` holds
    /// values below one — so the guard must admit it rather than rejecting the
    /// boundary along with what is past it.
    @Test("a scale equal to the precision is accepted")
    func scaleEqualToPrecisionIsValid() {
        #expect(MySQLBinlogRowDecoder.decimalByteCount(precision: 2, scale: 2) == 1)
        let decoded = MySQLBinlogRowDecoder.decodeDecimal([0x80 | 0x2A], precision: 2, scale: 2)
        #expect(decoded.hasPrefix("0."), "a value below one, got \(decoded)")
    }
}

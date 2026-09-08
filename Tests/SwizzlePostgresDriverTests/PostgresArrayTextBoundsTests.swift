import Testing

@testable import SwizzlePostgresDriver

/// Array bounds in the *text* format, which is a separate parser from the
/// binary one and had none of its guards.
///
/// ## Why there are two parsers
///
/// Postgres sends an array either as a binary header plus elements or as a
/// string like `{a,b,c}`. Which one arrives depends on the result format of the
/// query, so both are on the ordinary path and both take their numbers from the
/// server.
///
/// The binary decoder was hardened earlier: it caps the dimension count, checks
/// the element product for overflow, and refuses a header claiming more elements
/// than the remaining bytes could hold. The text decoder was not touched, and it
/// parses an explicit-bounds prefix — `[3:5]={a,b,c}` — by computing
/// `upper - lower + 1` on two `Int32` values it read out of the string.
///
/// Nothing constrains those two against each other. `[-2147483648:2147483647]`
/// overflows `Int32` and traps; `[5:3]` gives a negative length, which is not a
/// small array but an invalid `Range` and a negative `reserveCapacity`.
@Suite("Postgres array text bounds")
struct PostgresArrayTextBoundsTests {

    static func decode(_ text: String) -> PostgresArray? {
        PostgresArrayDecoder.decodeText(Array(text.utf8), elementOID: 25)
    }

    /// **The overflow.** The two bounds are independent `Int32`s parsed from the
    /// string, and their difference does not fit.
    @Test("bounds spanning the whole Int32 range do not trap")
    func fullRangeBoundsDoNotTrap() {
        _ = Self.decode("[-2147483648:2147483647]={}")
    }

    /// An upper bound below the lower one gives a negative length — an invalid
    /// range to iterate and a negative capacity to reserve.
    @Test("an upper bound below the lower bound is rejected")
    func invertedBoundsRejected() {
        // Survival is not the property. A dimension carrying a negative length
        // is a corrupt value that traps somewhere else later, so this asserts
        // no such dimension is produced at all.
        if let array = Self.decode("[5:3]={}") {
            #expect(
                array.dimensions.allSatisfy { $0.length >= 0 },
                "a dimension of negative length escaped the parser"
            )
        }
    }

    /// A span that fits in `Int32` but describes two billion elements must not
    /// become a two-billion-element reservation on the strength of a 24-byte
    /// string.
    @Test("an enormous but representable span does not become an enormous allocation")
    func enormousSpanDoesNotAllocate() {
        // This one cannot be checked by running it. `reserveCapacity` on two
        // billion elements is roughly sixteen gigabytes, and macOS overcommits
        // and carries on while Linux aborts — the same asymmetry that hid a
        // 32 GB allocation in the geometry decoders until a Linux job saw it.
        //
        // So the assertion is on the number, not on the outcome: a 24-byte
        // string cannot describe two billion elements, and the parser must say
        // so rather than reserving for them.
        guard let array = Self.decode("[0:2000000000]={a}") else { return }
        for dimension in array.dimensions {
            #expect(
                Int(dimension.length) <= 64,
                "a dimension of \(dimension.length) from a 17-character array body"
            )
        }
    }

    /// Several dimensions, each individually fine, whose product is not.
    @Test("multiple dimensions with an overflowing product are rejected")
    func overflowingDimensionProductRejected() {
        guard let array = Self.decode("[0:2000000000][0:2000000000][0:2000000000]={a}")
        else { return }
        var total = 1
        for dimension in array.dimensions {
            let (product, overflowed) = total.multipliedReportingOverflow(by: Int(dimension.length))
            #expect(!overflowed, "the dimension product overflows Int")
            if overflowed { return }
            total = product
        }
    }

    /// **The control.** The ordinary explicit-bounds form still parses, so the
    /// guards did not simply reject everything.
    @Test("an ordinary explicit-bounds array still parses")
    func ordinaryBoundsStillParse() {
        guard let array = Self.decode("[3:5]={a,b,c}") else {
            Issue.record("a valid explicit-bounds array was rejected")
            return
        }
        #expect(array.dimensions.count == 1)
        #expect(array.dimensions.first?.length == 3)
        #expect(array.dimensions.first?.lowerBound == 3)
        #expect(array.elements.count == 3)
    }

    /// And the form without an explicit prefix, which is what most arrays are.
    @Test("an array without an explicit bounds prefix still parses")
    func implicitBoundsStillParse() {
        guard let array = Self.decode("{a,b,c}") else {
            Issue.record("a plain array was rejected")
            return
        }
        #expect(array.elements.count == 3)
    }
}

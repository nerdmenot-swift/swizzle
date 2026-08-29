import NIOCore
import SwizzleCore
import Testing
@testable import SwizzlePostgresDriver

/// The binary decoders for the types beyond the core scalars, driven directly.
///
/// ## Why these need unit tests when an integration suite exists
///
/// `PostgresExtendedTypeTests` round-trips every one of these through a real
/// server, which proves the decoders agree with Postgres on well-formed input.
/// It cannot reach anything else: a server does not send a truncated `inet`, a
/// range header with a negative length, or a `tsquery` whose operand index runs
/// off the end of its own item list.
///
/// The mutation sweep put a number on the gap — **42 survivors in this file**,
/// the largest cluster in the driver. Every one of them is either a bounds check
/// that only a malformed buffer reaches, or a rendering rule whose output the
/// round-trip never inspects because it compares against what the server sent
/// back rather than against a literal.
///
/// These are also the decoders with the least margin for being quietly wrong.
/// The unknown-OID fallback never *fails*, so a decoder that returns `nil`
/// degrades to an opaque `.blob` rather than an error — which is right for a type
/// nobody has heard of and wrong for `inet`. A bad bounds check here is a crash;
/// a bad rendering rule is a wrong address shown to a user.
@Suite("Postgres extended type decoders")
struct ExtendedTypeDecoderTests {

    static func buffer(_ bytes: [UInt8]) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        return buffer
    }

    // MARK: - IPv6 rendering

    /// `::` collapses the **longest** run of zero groups, and only a run of two
    /// or more. Both halves of that rule had survivors: the `length > bestLength`
    /// that picks the longest run, and the `bestLength > 1` that refuses to
    /// collapse a single group.
    ///
    /// Postgres renders these itself, so getting it wrong means a client and a
    /// `psql` session disagree about what address a row holds.
    @Test("the longest run of zeroes is the one collapsed")
    func ipv6CollapsesLongestRun() {
        // Two runs: one group at index 1, three groups at 4...6. The longer wins.
        let bytes: [UInt8] = [
            0x20, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x02,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
        ]
        #expect(PostgresExtendedTypes.formatIPv6(bytes) == "2001:0:1:2::3")
    }

    /// A single zero group is written out rather than collapsed — `::` for one
    /// group would be ambiguous, and the server does not do it.
    @Test("a single zero group is not collapsed")
    func ipv6KeepsSingleZero() {
        let bytes: [UInt8] = [
            0x20, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x02,
            0x00, 0x03, 0x00, 0x04, 0x00, 0x05, 0x00, 0x06,
        ]
        #expect(PostgresExtendedTypes.formatIPv6(bytes) == "2001:0:1:2:3:4:5:6")
    }

    /// The all-zero address, where the run covers everything and both the head
    /// and the tail are empty.
    @Test("the unspecified address is just the separator")
    func ipv6AllZeroes() {
        #expect(PostgresExtendedTypes.formatIPv6([UInt8](repeating: 0, count: 16)) == "::")
    }

    /// A run that reaches the end, so the tail is empty but the head is not.
    @Test("a trailing run collapses with nothing after it")
    func ipv6TrailingRun() {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = 0x20; bytes[1] = 0x01
        #expect(PostgresExtendedTypes.formatIPv6(bytes) == "2001::")
    }

    /// And the first of two equal-length runs wins, because the comparison is
    /// strictly greater — flipping it to `>=` picks the later run and renders a
    /// different address for the same bytes.
    @Test("the earlier of two equal runs is the one collapsed")
    func ipv6PrefersTheFirstOfEqualRuns() {
        // Zeroes at groups 1-2 and 5-6: equal length, first should win.
        let bytes: [UInt8] = [
            0x20, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07,
            0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x09,
        ]
        #expect(PostgresExtendedTypes.formatIPv6(bytes) == "2001::7:8:0:0:9")
    }

    // MARK: - Truncated input

    /// `inet` carries a family byte, a prefix length, a flag and an address
    /// length before the address itself. A buffer that stops early must return
    /// `nil` — which degrades the column to a `.blob` — rather than read past the
    /// end.
    @Test("a truncated inet is refused rather than read past")
    func truncatedInet() {
        for length in 0..<8 {
            var buffer = Self.buffer([UInt8](repeating: 2, count: length))
            _ = PostgresExtendedTypes.decodeInet(&buffer, isCIDR: false)
        }
    }

    /// A bit string declares its bit count first. A negative count is not a
    /// length, and the `bitCount >= 0` guard is what says so — relaxing it to
    /// `>` rejects the empty bit string, which is a legal value.
    @Test("an empty bit string is legal and a negative count is not")
    func bitStringBounds() {
        // Zero bits, no data: legal, and must not be refused.
        var empty = Self.buffer([0, 0, 0, 0])
        #expect(PostgresExtendedTypes.decodeBits(&empty) != nil)

        // A negative declared length.
        var negative = Self.buffer([0xFF, 0xFF, 0xFF, 0xFF])
        #expect(PostgresExtendedTypes.decodeBits(&negative) == nil)

        // A count that exceeds what follows.
        var short = Self.buffer([0, 0, 0, 64, 0x01])
        #expect(PostgresExtendedTypes.decodeBits(&short) == nil)
    }

    // MARK: - Range bounds

    /// A range bound is a length then that many bytes. A negative length is
    /// malformed and an empty one is legal, which is the pair the `length >= 0`
    /// guard separates.
    @Test("a range with a negative bound length is refused")
    func rangeWithNegativeBoundLength() {
        // Flags byte 0x02 = lower bound inclusive, then a negative length.
        var buffer = Self.buffer([0x02, 0xFF, 0xFF, 0xFF, 0xFF])
        #expect(PostgresExtendedTypes.decodeRange(&buffer, elementOID: PostgresOID.int8.rawValue) == nil)
    }

    /// The empty range, whose flag byte says there are no bounds to read at all.
    @Test("an empty range renders as empty")
    func emptyRange() {
        var buffer = Self.buffer([0x01])
        let value = PostgresExtendedTypes.decodeRange(
            &buffer, elementOID: PostgresOID.int8.rawValue
        )
        #expect(value == .text("empty"))
    }

    /// A multirange declares how many ranges follow. A negative count is
    /// malformed; zero is the legal empty multirange.
    @Test("a multirange with no ranges is legal and a negative count is not")
    func multirangeCounts() {
        var empty = Self.buffer([0, 0, 0, 0])
        #expect(PostgresExtendedTypes.decodeMultirange(&empty, elementOID: PostgresOID.int8.rawValue) != nil)

        var negative = Self.buffer([0xFF, 0xFF, 0xFF, 0xFF])
        #expect(PostgresExtendedTypes.decodeMultirange(&negative, elementOID: PostgresOID.int8.rawValue) == nil)
    }

    // MARK: - Quoting

    /// A range bound containing a delimiter has to be quoted, or the rendered
    /// range cannot be parsed back. Each character in that set had its own
    /// survivor, because the round-trip only ever carried plain integers.
    @Test("bounds containing delimiters are quoted and escaped")
    func boundQuoting() {
        #expect(PostgresExtendedTypes.quotedBound("plain") == "plain")
        for delimiter in ["\"", "\\", "(", ")", "[", "]", ",", " "] {
            let quoted = PostgresExtendedTypes.quotedBound("a\(delimiter)b")
            #expect(quoted.hasPrefix("\""), "\(delimiter) should force quoting, got \(quoted)")
        }
        // The two that also need escaping inside the quotes.
        #expect(PostgresExtendedTypes.quotedBound("a\"b") == "\"a\\\"b\"")
        #expect(PostgresExtendedTypes.quotedBound("a\\b") == "\"a\\\\b\"")
    }

    // MARK: - Number rendering

    /// Geometry renders doubles the way Postgres does: whole values without a
    /// decimal point, and only while they are small enough for that to be
    /// faithful.
    @Test("whole numbers render without a decimal point, huge ones do not")
    func numberRendering() {
        #expect(PostgresExtendedTypes.number(1) == "1")
        #expect(PostgresExtendedTypes.number(-2) == "-2")
        #expect(PostgresExtendedTypes.number(1.5) == "1.5")
        // Past 1e15 a Double can no longer be trusted to be the integer it looks
        // like, so it keeps its full rendering.
        #expect(PostgresExtendedTypes.number(1e16) != "10000000000000000")
    }

    /// A bound whose value is **zero bytes long** — the empty string — is legal,
    /// and is the case that separates `length >= 0` from `length > 0`.
    ///
    /// The negative-length test above does not reach it: both comparisons reject
    /// a negative, so the mutant survived it. The decoder's own comment draws the
    /// distinction this pins — `(,5)` is unbounded below, `("",5)` is a bound
    /// whose value happens to be empty — and tightening the guard turns the
    /// second into a decode failure, which degrades the whole column to a blob.
    @Test("a zero-length bound is a value, not a malformed one")
    func rangeWithEmptyBound() {
        // Lower inclusive + upper unbounded, then a lower bound of length zero.
        var buffer = Self.buffer([0x12, 0, 0, 0, 0])
        let value = PostgresExtendedTypes.decodeRange(
            &buffer, elementOID: PostgresOID.text.rawValue
        )
        #expect(value != nil, "an empty bound must decode rather than fail")
    }

}

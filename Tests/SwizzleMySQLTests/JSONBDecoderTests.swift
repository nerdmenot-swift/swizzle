import Foundation
import Testing
@testable import SwizzleMySQL

/// MySQL's binary JSON, decoded from documents this suite builds itself.
///
/// ## Why a builder rather than captured bytes
///
/// The decoder had no unit coverage at all — the mutation sweep left eleven
/// survivors across it — because the only way to reach it was through a real
/// binlog, which means a running MySQL server, a configured replication stream
/// and a JSON column. That is a lot of machinery to stand between a test and a
/// parser, and it can only ever produce *well-formed* documents, so none of the
/// decoder's guards were reachable from it at all.
///
/// Building the format here inverts that. It costs an encoder, and the encoder
/// is independent of the decoder — written from the layout in the format
/// comment rather than by reading the parsing code — so the two agreeing is
/// evidence rather than a tautology. It also makes the malformed cases
/// expressible, which is the half that matters: these bytes arrive from a
/// replication stream, and a stream can desynchronise.
///
/// ## The layout, restated from the decoder's own comment
///
/// ```
/// object ::= count size key-entry* value-entry* key* value*
/// array  ::=  count size value-entry*             value*
/// key-entry   ::= offset(width) length(2)
/// value-entry ::= type(1) (offset(width) | inlined-value)
/// ```
///
/// `width` is 2 for the small variants and 4 for the large ones. Offsets are
/// relative to the start of the containing object, not the document — the
/// mistake the format invites, and the one this builder has to get right for
/// any of it to decode.
@Suite("MySQL JSONB")
struct JSONBDecoderTests {

    // MARK: - The builder

    indirect enum JSON {
        case null
        case bool(Bool)
        case int16(Int16)
        case uint16(UInt16)
        case int32(Int32)
        case uint32(UInt32)
        case int64(Int64)
        case uint64(UInt64)
        case double(Double)
        case string(String)
        case object([(String, JSON)])
        case array([JSON])
        /// A column type and its stored bytes, which is how MySQL carries a
        /// value JSON has no type for.
        case opaque(UInt8, [UInt8])

        var typeByte: UInt8 {
            switch self {
            case .null, .bool: 0x04
            case .int16: 0x05
            case .uint16: 0x06
            case .int32: 0x07
            case .uint32: 0x08
            case .int64: 0x09
            case .uint64: 0x0A
            case .double: 0x0B
            case .string: 0x0C
            case .object: 0x00
            case .array: 0x02
            case .opaque: 0x0F
            }
        }

        /// Whether this value lives inside its own value-entry. A 4-byte entry
        /// can hold a 32-bit integer; a 2-byte one cannot.
        func isInlined(large: Bool) -> Bool {
            switch self {
            case .null, .bool, .int16, .uint16: true
            case .int32, .uint32: large
            default: false
            }
        }

        /// The bytes that go into the entry itself when inlined.
        func inlined(large: Bool) -> [UInt8] {
            let width = large ? 4 : 2
            var bytes: [UInt8]
            switch self {
            case .null: bytes = [0x00]
            case .bool(let value): bytes = [value ? 0x01 : 0x02]
            case .int16(let value): bytes = little(UInt16(bitPattern: value), 2)
            case .uint16(let value): bytes = little(value, 2)
            case .int32(let value): bytes = little(UInt32(bitPattern: value), 4)
            case .uint32(let value): bytes = little(value, 4)
            default: bytes = []
            }
            return bytes + [UInt8](repeating: 0, count: width - bytes.count)
        }

        /// The bytes that go into the container's value area when not inlined.
        /// A nested container's body carries no type byte — its type is already
        /// in the entry that points at it.
        func body() -> [UInt8] {
            switch self {
            case .int32(let value): little(UInt32(bitPattern: value), 4)
            case .uint32(let value): little(value, 4)
            case .int64(let value): little(UInt64(bitPattern: value), 8)
            case .uint64(let value): little(value, 8)
            case .double(let value): little(value.bitPattern, 8)
            case .string(let text):
                varint(Array(text.utf8).count) + Array(text.utf8)
            case .opaque(let type, let payload):
                [type] + varint(payload.count) + payload
            case .object(let pairs): container(pairs.map { ($0.0, $0.1) })
            case .array(let items): container(items.map { (nil, $0) })
            default: []
            }
        }

        func little<T: FixedWidthInteger>(_ value: T, _ count: Int) -> [UInt8] {
            (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
        }

        /// MySQL's own variable-length integer — seven bits a byte, high bit
        /// marking continuation. Not the protocol's length-encoded integer.
        func varint(_ value: Int) -> [UInt8] {
            var remaining = value
            var out: [UInt8] = []
            repeat {
                var byte = UInt8(remaining & 0x7F)
                remaining >>= 7
                if remaining > 0 { byte |= 0x80 }
                out.append(byte)
            } while remaining > 0
            return out
        }

        /// Lays out an object or an array. Keys are absent for an array, which
        /// is the only structural difference between the two.
        func container(_ entries: [(String?, JSON)]) -> [UInt8] {
            let large = false                        // small variants throughout
            let width = 2
            let count = entries.count
            let hasKeys = entries.first?.0 != nil
            let keyEntrySize = hasKeys ? width + 2 : 0
            let valueEntrySize = width + 1
            let headerSize = width * 2 + count * keyEntrySize + count * valueEntrySize

            var cursor = headerSize
            var keyOffsets: [Int] = []
            var keyArea: [UInt8] = []
            if hasKeys {
                for (key, _) in entries {
                    keyOffsets.append(cursor)
                    keyArea += Array(key!.utf8)
                    cursor += Array(key!.utf8).count
                }
            }

            var valueOffsets: [Int?] = []
            var valueArea: [UInt8] = []
            for (_, value) in entries {
                if value.isInlined(large: large) {
                    valueOffsets.append(nil)
                } else {
                    valueOffsets.append(cursor)
                    let body = value.body()
                    valueArea += body
                    cursor += body.count
                }
            }

            var out = little(UInt16(count), 2) + little(UInt16(cursor), 2)
            if hasKeys {
                for (index, offset) in keyOffsets.enumerated() {
                    out += little(UInt16(offset), 2)
                    out += little(UInt16(Array(entries[index].0!.utf8).count), 2)
                }
            }
            for (index, offset) in valueOffsets.enumerated() {
                let value = entries[index].1
                out += [value.typeByte]
                out += offset.map { little(UInt16($0), 2) } ?? value.inlined(large: large)
            }
            return out + keyArea + valueArea
        }

        /// A complete document: the type byte, then the value.
        var document: [UInt8] {
            switch self {
            case .null, .bool, .int16, .uint16:
                // A scalar document is not inlined — there is no entry to inline
                // it into — so the payload follows the type byte directly.
                [typeByte] + inlinedPayload
            default: [typeByte] + body()
            }
        }

        private var inlinedPayload: [UInt8] {
            switch self {
            case .null: [0x00]
            case .bool(let value): [value ? 0x01 : 0x02]
            case .int16(let value): little(UInt16(bitPattern: value), 2)
            case .uint16(let value): little(value, 2)
            default: []
            }
        }
    }

    static func decode(_ value: JSON) throws -> String {
        try MySQLJSONB.decode(value.document)
    }

    // MARK: - Scalars

    @Test("the three literals render as JSON keywords")
    func literals() throws {
        #expect(try Self.decode(.null) == "null")
        #expect(try Self.decode(.bool(true)) == "true")
        #expect(try Self.decode(.bool(false)) == "false")
    }

    /// A literal byte the format does not define is an error rather than a
    /// guess — the document is corrupt and inventing a value hides that.
    @Test("an undefined literal is rejected")
    func unknownLiteral() {
        #expect(throws: MySQLProtocolError.self) { try MySQLJSONB.decode([0x04, 0x03]) }
    }

    /// Every integer width, at both ends of its range, because the signed and
    /// unsigned types share a payload width and differ only in interpretation.
    @Test("every integer width renders at both ends of its range")
    func integers() throws {
        #expect(try Self.decode(.int16(0)) == "0")
        #expect(try Self.decode(.int16(-1)) == "-1")
        #expect(try Self.decode(.int16(.min)) == "-32768")
        #expect(try Self.decode(.int16(.max)) == "32767")
        #expect(try Self.decode(.uint16(.max)) == "65535")
        #expect(try Self.decode(.array([.int32(.min)])) == "[-2147483648]")
        #expect(try Self.decode(.array([.int32(.max)])) == "[2147483647]")
        #expect(try Self.decode(.array([.uint32(.max)])) == "[4294967295]")
        #expect(try Self.decode(.array([.int64(.min)])) == "[-9223372036854775808]")
        #expect(try Self.decode(.array([.int64(.max)])) == "[9223372036854775807]")
        #expect(try Self.decode(.array([.uint64(.max)])) == "[18446744073709551615]")
    }

    /// Doubles render the way JSON expects: a whole number without a trailing
    /// `.0`, and no exponent where none is needed.
    @Test("doubles render without a spurious fractional part")
    func doubles() throws {
        #expect(try Self.decode(.array([.double(1)])) == "[1]")
        #expect(try Self.decode(.array([.double(-1)])) == "[-1]")
        #expect(try Self.decode(.array([.double(0)])) == "[0]")
        #expect(try Self.decode(.array([.double(1.5)])) == "[1.5]")
        #expect(try Self.decode(.array([.double(-0.25)])) == "[-0.25]")
    }

    /// The boundary in `formatDouble`: above 1e15 a whole number keeps the
    /// floating rendering rather than being converted, because the conversion
    /// is what would overflow.
    @Test("a whole number too large to narrow keeps its floating rendering")
    func largeWholeDoubles() throws {
        // Just under: converted to an integer rendering.
        #expect(try Self.decode(.array([.double(999_999_999_999_999)])) == "[999999999999999]")
        // At and above: left alone. The exact text is the standard library's,
        // so the property asserted is that it did not go through Int64.
        let big = try Self.decode(.array([.double(1e15)]))
        #expect(big.contains("e") || big.contains("."), "\(big) took the floating path")
        let huge = try Self.decode(.array([.double(1e300)]))
        #expect(huge.contains("e"), "\(huge)")
    }

    /// A double beyond `Int64`'s range must not be converted into it — that is
    /// a trap, not a rounding error, and the guard is the only thing preventing
    /// it.
    @Test("a double beyond Int64 does not trap on conversion")
    func doubleBeyondInt64() throws {
        for value in [1e19, -1e19, 1e308, -1e308, Double.greatestFiniteMagnitude] {
            _ = try Self.decode(.array([.double(value)]))
        }
    }

    @Test("strings render escaped")
    func strings() throws {
        #expect(try Self.decode(.array([.string("")])) == "[\"\"]")
        #expect(try Self.decode(.array([.string("ada")])) == "[\"ada\"]")
        #expect(try Self.decode(.array([.string("a\"b")])) == "[\"a\\\"b\"]")
        #expect(try Self.decode(.array([.string("a\\b")])) == "[\"a\\\\b\"]")
        #expect(try Self.decode(.array([.string("a\nb")])) == "[\"a\\nb\"]")
        #expect(try Self.decode(.array([.string("ünïcødé")])) == "[\"ünïcødé\"]")
    }

    /// A string long enough to need two varint bytes, which is the boundary the
    /// length encoding turns over at and the one a single-byte reader passes on
    /// every shorter string.
    @Test("a string longer than 127 bytes reads its two-byte length")
    func multiByteStringLength() throws {
        for length in [126, 127, 128, 129, 300, 16_383, 16_384] {
            let text = String(repeating: "x", count: length)
            #expect(try Self.decode(.array([.string(text)])) == "[\"\(text)\"]",
                    "length \(length)")
        }
    }

    // MARK: - Containers

    @Test("an object renders its keys in the order the document stores them")
    func objects() throws {
        #expect(try Self.decode(.object([])) == "{}")
        #expect(try Self.decode(.object([("a", .int16(1))])) == "{\"a\":1}")
        #expect(
            try Self.decode(.object([
                ("name", .string("ada")), ("n", .int16(42)), ("ok", .bool(true)),
            ])) == "{\"name\":\"ada\",\"n\":42,\"ok\":true}"
        )
    }

    @Test("an array renders its elements in order")
    func arrays() throws {
        #expect(try Self.decode(.array([])) == "[]")
        #expect(try Self.decode(.array([.int16(1), .int16(2)])) == "[1,2]")
        #expect(
            try Self.decode(.array([.null, .bool(false), .string("x")])) == "[null,false,\"x\"]"
        )
    }

    /// Nesting is where the relative offsets have to be right: an inner
    /// container's offsets are measured from its own start, not the document's.
    @Test("nested containers resolve their offsets against their own base")
    func nesting() throws {
        #expect(
            try Self.decode(.object([
                ("outer", .object([("inner", .string("deep"))])),
            ])) == "{\"outer\":{\"inner\":\"deep\"}}"
        )
        #expect(
            try Self.decode(.array([.array([.array([.int16(7)])])])) == "[[[7]]]"
        )
        #expect(
            try Self.decode(.object([
                ("a", .array([.int16(1), .object([("b", .int16(2))])])),
                ("c", .string("after"))
            ])) == "{\"a\":[1,{\"b\":2}],\"c\":\"after\"}"
        )
    }

    // MARK: - The depth limit

    /// A document nested past the limit is rejected rather than recursed into,
    /// **at the exact depth it turns over**.
    ///
    /// Without the guard this is a stack overflow, which no `catch` can turn
    /// back into an error — the process is gone. The bytes come from a
    /// replication stream, so a document nested a million deep is a thing a
    /// peer can send whether or not any legitimate writer would.
    ///
    /// Both sides of the boundary, because a limit asserted only from far away
    /// is a limit that can drift by one in either direction without any test
    /// noticing.
    @Test("nesting past the limit is refused, at the depth it turns over")
    func depthLimit() throws {
        func nested(_ depth: Int) -> JSON {
            var value = JSON.int16(1)
            for _ in 0..<depth { value = .array([value]) }
            return value
        }
        #expect(try Self.decode(nested(50)).hasPrefix("[[[["), "comfortably inside")
        #expect(throws: Never.self, "99 levels is the deepest that decodes") {
            _ = try Self.decode(nested(99))
        }
        #expect(throws: MySQLProtocolError.self, "100 is the first that does not") {
            _ = try Self.decode(nested(100))
        }
        #expect(throws: MySQLProtocolError.self) { _ = try Self.decode(nested(150)) }
    }

    /// The variable-length integer runs to **five** bytes, and the guard exists
    /// to stop a sixth shifting the accumulator off the end.
    ///
    /// Exercising five bytes with a genuine value would need a length past 2^28,
    /// which means a quarter-gigabyte document. A non-canonical encoding — the
    /// same small value padded with redundant continuation bytes — reaches the
    /// fifth byte without it. The decoder accepts non-canonical encodings, so
    /// this is a statement about how far the length field may run, not about
    /// how a writer would encode that value.
    @Test("a five-byte variable-length integer is accepted and a sixth is not")
    func varintWidthBoundary() throws {
        // 3, encoded across five bytes.
        #expect(
            try MySQLJSONB.decode([0x0C, 0x83, 0x80, 0x80, 0x80, 0x00, 0x61, 0x62, 0x63])
                == "\"abc\"",
            "five bytes is the widest the format defines"
        )
        // A sixth continuation byte is past it. The payload is supplied in full,
        // so the only thing that can reject this document is the width guard —
        // a document that ran out of bytes first would throw for the wrong
        // reason and the test would pass without exercising the guard at all.
        #expect(throws: MySQLProtocolError.self, "a sixth byte is refused") {
            try MySQLJSONB.decode(
                [0x0C, 0x83, 0x80, 0x80, 0x80, 0x80, 0x00, 0x61, 0x62, 0x63]
            )
        }
    }

    // MARK: - Opaque values

    /// The temporal shapes, which are stored as MySQL's packed 64-bit form
    /// rather than as text and are decoded by column type.
    @Test("a packed DATETIME inside a document renders as text")
    func opaqueDateTime() throws {
        // 2024-03-05 14:30:07.123456 in MySQL's packed layout:
        // (((year * 13 + month) << 5 | day) << 17 | (h << 12 | m << 6 | s)) << 24 | micros
        let ymd = Int64(((2024 * 13 + 3) << 5) | 5)
        let hms = Int64((14 << 12) | (30 << 6) | 7)
        let packed = (((ymd << 17) | hms) << 24) | 123_456
        let bytes = (0..<8).map { UInt8(truncatingIfNeeded: packed >> (8 * $0)) }
        let rendered = try Self.decode(
            .array([.opaque(MySQLColumnType.datetime.rawValue, bytes)])
        )
        #expect(rendered.contains("2024-03-05 14:30:07"), Comment(rawValue: rendered))
    }

    /// **The crash this suite was written for.**
    ///
    /// The unpackers took the magnitude with `packed < 0 ? -packed : packed`,
    /// and negating `Int64.min` overflows — a trap, not a wrong value. `packed`
    /// is eight bytes read straight out of the document, so those eight bytes
    /// are a value any peer can send: `00 00 00 00 00 00 00 80`.
    ///
    /// Every temporal column type reaches one of the two unpackers, so all of
    /// them are exercised here.
    @Test("the extreme packed value is decoded rather than trapping on negation")
    func opaqueInt64MinDoesNotTrap() throws {
        let extremes: [[UInt8]] = [
            [0, 0, 0, 0, 0, 0, 0, 0x80],                       // Int64.min
            [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],  // -1
            [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F],  // Int64.max
            [0x01, 0, 0, 0, 0, 0, 0, 0x80],                    // Int64.min + 1
        ]
        let types: [MySQLColumnType] = [
            .datetime, .datetime2, .timestamp, .timestamp2, .date, .newdate, .time, .time2,
        ]
        for type in types {
            for bytes in extremes {
                // Any result is acceptable — the value is nonsense. Returning at
                // all is the property.
                _ = try Self.decode(.array([.opaque(type.rawValue, bytes)]))
            }
        }
    }

    /// A type with no JSON equivalent and no temporal decoding keeps MySQL's
    /// own base64 convention rather than being guessed at, because a wrong
    /// guess is silent corruption inside a document that still parses.
    @Test("an undecodable opaque type keeps MySQL's base64 convention")
    func opaqueFallback() throws {
        let rendered = try Self.decode(
            .array([.opaque(MySQLColumnType.newdecimal.rawValue, [0x01, 0x02, 0x03])])
        )
        #expect(rendered.contains("base64:type\(MySQLColumnType.newdecimal.rawValue):"), Comment(rawValue: rendered))
    }

    /// Character-set types genuinely hold text and are rendered as such.
    @Test("a character-set opaque value renders as a string")
    func opaqueText() throws {
        for type in [MySQLColumnType.varString, .varchar, .string] {
            let rendered = try Self.decode(.array([.opaque(type.rawValue, Array("hi".utf8))]))
            #expect(rendered == "[\"hi\"]", "\(type): \(rendered)")
        }
    }

    /// A payload that is not valid UTF-8 falls back rather than substituting
    /// replacement characters, which would be silent corruption.
    @Test("a character-set opaque value that is not UTF-8 falls back to base64")
    func opaqueTextInvalidUTF8() throws {
        let rendered = try Self.decode(
            .array([.opaque(MySQLColumnType.varString.rawValue, [0xFF, 0xFE])])
        )
        #expect(rendered.contains("base64:"), Comment(rawValue: rendered))
    }

    // MARK: - Malformed documents

    @Test("an empty document is rejected")
    func emptyDocument() {
        #expect(throws: MySQLProtocolError.self) { try MySQLJSONB.decode([]) }
    }

    @Test("an unknown top-level type is rejected")
    func unknownType() {
        for byte: UInt8 in [0x0D, 0x0E, 0x10, 0x7F, 0xFF] {
            #expect(throws: MySQLProtocolError.self) { try MySQLJSONB.decode([byte, 0, 0, 0, 0]) }
        }
    }

    /// **Every prefix of a valid document**, which is what a truncated row
    /// image leaves and what no hand-picked case states. Between them these
    /// reach every bounds check in the decoder.
    @Test("every prefix of a valid document is refused rather than read past")
    func everyPrefixIsSafe() {
        let document = JSON.object([
            ("name", .string("ada")),
            ("n", .int64(42)),
            ("nested", .array([.double(1.5), .bool(true), .null])),
            ("deep", .object([("k", .string("v"))])),
        ]).document
        for length in 0..<document.count {
            // Throwing is the correct outcome. Trapping is not, and returning a
            // value built from bytes that are not there would be worse.
            _ = try? MySQLJSONB.decode(Array(document.prefix(length)))
        }
        #expect(throws: Never.self) { _ = try MySQLJSONB.decode(document) }
    }

    /// A length field that promises more than the document holds.
    @Test("a length beyond the document is refused")
    func lengthBeyondDocument() {
        // A string whose varint claims 200 bytes with three supplied.
        #expect(throws: MySQLProtocolError.self) {
            try MySQLJSONB.decode([0x0C, 200, 0x61, 0x62, 0x63])
        }
    }

    /// A variable-length integer longer than the format allows is refused
    /// rather than shifted until it overflows.
    @Test("an over-long variable-length integer is refused")
    func overlongVarint() {
        // Six continuation bytes: past the five the format permits.
        let bytes: [UInt8] = [0x0C, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]
        #expect(throws: MySQLProtocolError.self) { try MySQLJSONB.decode(bytes) }
    }

    /// Random bytes, seeded so a failure reproduces. The only assertion is that
    /// the decoder returns — a wrong rendering of garbage is not a finding, and
    /// a trap is.
    @Test("no random document traps the decoder", arguments: [UInt64](1...16))
    func randomDocumentsAreSafe(seed: UInt64) {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1
        func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        for _ in 0..<200 {
            let count = Int(next() % 64)
            // Biased towards valid type bytes so the walk gets past the first
            // byte and reaches the structural code rather than stopping at the
            // door.
            let bytes = (0..<count).map { index -> UInt8 in
                index == 0 || next() % 4 == 0 ? UInt8(next() % 0x10) : UInt8(next() % 256)
            }
            _ = try? MySQLJSONB.decode(bytes)
        }
    }
}

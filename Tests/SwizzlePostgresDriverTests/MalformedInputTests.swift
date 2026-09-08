import Foundation
import NIOCore
import SwizzleCore
import Testing
@testable import SwizzlePostgresDriver

/// Random and hostile bytes through every Postgres binary decoder.
///
/// ## Why this suite did not exist, and why that was the gap
///
/// The MySQL driver has three suites of this shape and they found six process
/// crashes between them — every one a length or a count taken off the wire and
/// used to index, allocate, or multiply. The Postgres driver had none. Not a
/// smaller version: none.
///
/// That asymmetry was not a judgement about Postgres being safer. It was an
/// accident of which driver got attention, and it hid the same class of bug:
/// `PostgresArrayDecoder` multiplied its dimension lengths into an `Int` and a
/// header claiming three dimensions of `Int32.max` **overflowed and trapped** —
/// a crash any peer could trigger, found within minutes of looking.
///
/// ## What is being asserted
///
/// Only that the decoder **returns**. A wrong value from garbage input is not a
/// finding; the oracle suites cover correctness against a real server. A trap
/// is, because it takes the process with it and no `catch` sees it — and these
/// decoders are the first thing that touches bytes a server sent.
///
/// The generator is seeded, so a failure reproduces from the seed in the
/// message rather than "sometimes".
@Suite("Postgres malformed input")
struct PostgresMalformedInputTests {

    struct Seeded {
        var state: UInt64
        init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        mutating func bytes(upTo limit: Int) -> [UInt8] {
            let count = Int(next() % UInt64(limit + 1))
            return (0..<count).map { _ in UInt8(next() % 256) }
        }
    }

    static func buffer(_ bytes: [UInt8]) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        return buffer
    }

    /// Every decoder that takes a buffer, run against the same bytes.
    static func runEveryDecoder(_ bytes: [UInt8]) {
        for isCIDR in [true, false] {
            var b = Self.buffer(bytes)
            _ = PostgresExtendedTypes.decodeInet(&b, isCIDR: isCIDR)
        }
        for width in [6, 8] {
            _ = PostgresExtendedTypes.decodeMACAddress(bytes, width: width)
        }
        var money = Self.buffer(bytes); _ = PostgresExtendedTypes.decodeMoney(&money)
        var bits = Self.buffer(bytes); _ = PostgresExtendedTypes.decodeBits(&bits)
        var lsn = Self.buffer(bytes); _ = PostgresExtendedTypes.decodeLSN(&lsn)
        var tid = Self.buffer(bytes); _ = PostgresExtendedTypes.decodeTID(&tid)
        var tsv = Self.buffer(bytes); _ = PostgresExtendedTypes.decodeTSVector(&tsv)
        _ = PostgresExtendedTypes.decodeIntVector(bytes)

        var range = Self.buffer(bytes)
        _ = PostgresExtendedTypes.decodeRange(&range, elementOID: 23, decodeElement: nil)
        var multirange = Self.buffer(bytes)
        _ = PostgresExtendedTypes.decodeMultirange(&multirange, elementOID: 23, decodeElement: nil)

        for oid in [PostgresOID.point, .line, .lseg, .box, .path, .polygon, .circle] {
            var geometry = Self.buffer(bytes)
            _ = PostgresExtendedTypes.decodeGeometry(&geometry, type: oid)
        }

        _ = PostgresArrayDecoder.decodeBinary(bytes)

        // Four decoders were absent from this sweep entirely. `decodeNumeric` is
        // the one that matters: its four `Int16` headers are the widest
        // peer-controlled arithmetic surface in the driver, and a DECIMAL
        // metadata word of exactly this shape was a crash in the MySQL binlog
        // decoder. Being absent from the sweep is why nobody looked.
        var numeric = Self.buffer(bytes)
        _ = PostgresValueDecoder.decodeNumeric(&numeric)
        var tsquery = Self.buffer(bytes)
        _ = PostgresExtendedTypes.decodeTSQuery(&tsquery)
        var interval = Self.buffer(bytes)
        _ = PostgresExtendedTypes.decodeInterval(&interval)
        _ = PostgresExtendedTypes.decodeJSONPath(bytes)
    }

    // MARK: - Random input

    @Test("no random input traps any binary decoder", arguments: fuzzSeeds(16))
    func randomBytesAreSafe(seed: UInt64) {
        var generator = Seeded(seed: seed)
        for _ in 0..<300 {
            Self.runEveryDecoder(generator.bytes(upTo: 48))
        }
    }

    /// Lengths and counts specifically, since a random byte rarely lands on the
    /// values that matter: the extremes of `Int32`, and the boundaries either
    /// side of zero.
    @Test("no extreme length or count traps any decoder")
    func extremeLengthsAreSafe() {
        let words: [Int32] = [
            .min, .min + 1, -2, -1, 0, 1, 2, 1 << 16, 1 << 24, .max - 1, .max,
        ]
        for first in words {
            for second in words {
                var bytes: [UInt8] = []
                func be32(_ value: Int32) {
                    let raw = UInt32(bitPattern: value)
                    for shift in (0..<4).reversed() {
                        bytes.append(UInt8((raw >> (8 * shift)) & 0xFF))
                    }
                }
                be32(first)
                be32(second)
                be32(first)
                bytes += [UInt8](repeating: 0xAB, count: 16)
                Self.runEveryDecoder(bytes)
            }
        }
    }

    // MARK: - The crash this suite was written for

    /// **The array dimension overflow, pinned by name.**
    ///
    /// The binary array header is a dimension count and then a `(length,
    /// lowerBound)` pair per dimension, and the element count is their product.
    /// Three dimensions of `Int32.max` overflow `Int` — a trap, not a wrong
    /// answer, and one any peer can send in twenty-eight bytes.
    ///
    /// The bound that replaced it is derived rather than picked: every element
    /// carries at least a four-byte length prefix, so a claim larger than the
    /// remaining bytes allow is malformed by arithmetic rather than by policy.
    @Test("an array header whose dimensions overflow is refused, not multiplied")
    func arrayDimensionOverflow() {
        func header(dimensions: [Int32]) -> [UInt8] {
            var bytes: [UInt8] = []
            func be32(_ value: Int32) {
                let raw = UInt32(bitPattern: value)
                for shift in (0..<4).reversed() { bytes.append(UInt8((raw >> (8 * shift)) & 0xFF)) }
            }
            be32(Int32(dimensions.count))
            be32(0)                                            // has-nulls flag
            be32(23)                                           // element OID: int4
            for length in dimensions { be32(length); be32(1) }
            return bytes
        }

        #expect(PostgresArrayDecoder.decodeBinary(header(dimensions: [.max, .max, .max])) == nil)
        #expect(PostgresArrayDecoder.decodeBinary(header(dimensions: [.max, .max])) == nil)
        #expect(PostgresArrayDecoder.decodeBinary(header(dimensions: [1 << 20, 1 << 20])) == nil)
        // A single enormous dimension does not overflow but still claims more
        // elements than the buffer could hold.
        #expect(PostgresArrayDecoder.decodeBinary(header(dimensions: [.max])) == nil)
    }

    /// And a well-formed array still decodes, so the bound did not simply
    /// reject everything.
    @Test("a well-formed array still decodes")
    func wellFormedArrayStillDecodes() throws {
        var bytes: [UInt8] = []
        func be32(_ value: Int32) {
            let raw = UInt32(bitPattern: value)
            for shift in (0..<4).reversed() { bytes.append(UInt8((raw >> (8 * shift)) & 0xFF)) }
        }
        be32(1)                                                // one dimension
        be32(0)                                                // has-nulls
        be32(23)                                               // int4
        be32(3); be32(1)                                       // three elements, lower bound 1
        for value in Int32(1)...3 { be32(4); be32(value) }      // each: length 4, then the value

        let array = try #require(PostgresArrayDecoder.decodeBinary(bytes))
        #expect(array.elements.count == 3)
        #expect(array.dimensions.first?.length == 3)
    }

    /// An empty array carries nothing after its header, which is the boundary
    /// the dimension bound must not reject.
    @Test("an empty array decodes to no elements")
    func emptyArray() throws {
        let bytes: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 23]
        let array = try #require(PostgresArrayDecoder.decodeBinary(bytes))
        #expect(array.elements.isEmpty)
    }

    // MARK: - Truncation

    /// Every prefix of a well-formed value of each shape, which is what a short
    /// read leaves and what no hand-picked case states.
    @Test("every prefix of a well-formed value is refused rather than read past")
    func everyPrefixIsSafe() {
        let shapes: [[UInt8]] = [
            // A one-dimensional int4 array of three elements.
            [0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 23, 0, 0, 0, 3, 0, 0, 0, 1,
             0, 0, 0, 4, 0, 0, 0, 1, 0, 0, 0, 4, 0, 0, 0, 2, 0, 0, 0, 4, 0, 0, 0, 3],
            // An inet: family, bits, is-cidr, length, then the address.
            [2, 32, 0, 4, 192, 168, 0, 1],
            // A TID: block then offset.
            [0, 0, 0, 5, 0, 7],
            // An LSN.
            [0, 0, 0, 1, 0, 0, 0, 2],
        ]
        for shape in shapes {
            for length in 0...shape.count {
                Self.runEveryDecoder(Array(shape.prefix(length)))
            }
        }
    }

    // MARK: - NUMERIC headers, swept

    /// **Every interesting combination of NUMERIC's four headers.**
    ///
    /// `decodeNumeric` reads four `Int16`s — digit count, weight, sign, display
    /// scale — and derives loop bounds and string lengths from them. That is the
    /// widest peer-controlled arithmetic surface in this driver, and it is the
    /// exact analogue of the MySQL DECIMAL metadata word, where two independent
    /// bytes with no constraint between them indexed a lookup table at a
    /// negative offset.
    ///
    /// Random bytes reach this space only by luck: the values that matter are
    /// the extremes and the boundaries around zero, and four independent
    /// sixteen-bit fields make them vanishingly unlikely to co-occur. So this
    /// walks the product of the interesting values directly.
    ///
    /// `weight` and `displayScale` are swept over a narrower set than the other
    /// two, and the extremes are covered separately below. They only set loop
    /// lengths, and a large one is legitimately expensive: `weight` is the power
    /// of 10000 of the leading group, so a value with 131072 integer digits —
    /// which Postgres permits — genuinely renders 32768 groups. Sweeping the
    /// full product spent three minutes proving that repeatedly. The fields
    /// where a bug would hide are the ones that go *negative*, and those are
    /// swept in full.
    @Test("no combination of NUMERIC headers traps the decoder")
    func numericHeaderCombinations() {
        let interesting: [Int16] = [.min, .min + 1, -2, -1, 0, 1, 9, 10, .max - 1, .max]
        let loopBounds: [Int16] = [.min, -1, 0, 1, 9]
        let bodies: [[UInt8]] = [
            [],
            [0x00, 0x01],
            [UInt8](repeating: 0xFF, count: 8),
        ]

        for digitCount in interesting {
            for weight in loopBounds {
                for sign in interesting {
                    for displayScale in loopBounds {
                        for body in bodies {
                            var bytes: [UInt8] = []
                            for header in [digitCount, weight, sign, displayScale] {
                                bytes.append(UInt8(truncatingIfNeeded: header >> 8))
                                bytes.append(UInt8(truncatingIfNeeded: header))
                            }
                            bytes.append(contentsOf: body)

                            var buffer = Self.buffer(bytes)
                            // Any result is acceptable, including nil. Not
                            // trapping and not looping forever is the property.
                            _ = PostgresValueDecoder.decodeNumeric(&buffer)
                        }
                    }
                }
            }
        }
    }

    /// The extremes of the two loop-length fields, which the sweep above leaves
    /// out because they are slow rather than interesting. A handful is enough:
    /// what could go wrong here is an overflow or a reversed range, and that
    /// does not depend on running the combination four thousand times.
    @Test("the extremes of NUMERIC weight and display scale do not trap")
    func numericExtremeLoopBounds() {
        let extremes: [Int16] = [.min, .max, .max - 1, 16383]
        for weight in extremes {
            for displayScale in extremes {
                var bytes: [UInt8] = []
                for header in [Int16(0), weight, Int16(0), displayScale] {
                    bytes.append(UInt8(truncatingIfNeeded: header >> 8))
                    bytes.append(UInt8(truncatingIfNeeded: header))
                }
                var buffer = Self.buffer(bytes)
                _ = PostgresValueDecoder.decodeNumeric(&buffer)
            }
        }
    }

    /// **The control.** A real NUMERIC still decodes to its exact digits, so the
    /// sweep above is not passing because the decoder gave up on everything.
    ///
    /// `1234.5` at weight 0 with one display digit: one base-10000 group holding
    /// 1234, then one holding 5000, which renders as `.5` once truncated to the
    /// display scale.
    @Test("a well-formed NUMERIC still decodes exactly")
    func wellFormedNumericDecodes() {
        var buffer = Self.buffer([
            0x00, 0x02,   // two digit groups
            0x00, 0x00,   // weight 0 — the first group is the units
            0x00, 0x00,   // sign: positive
            0x00, 0x01,   // display scale 1
            0x04, 0xD2,   // 1234
            0x13, 0x88,   // 5000
        ])
        #expect(PostgresValueDecoder.decodeNumeric(&buffer) == "1234.5")
    }

    /// And the special signs, which carry no digits at all — a decoder that read
    /// groups anyway would run off the end of a two-word buffer.
    @Test("the NUMERIC special signs decode without reading digits")
    func numericSpecialSigns() {
        for (sign, expected) in [(0xC000, "NaN"), (0xD000, "Infinity"), (0xF000, "-Infinity")] {
            var buffer = Self.buffer([
                0x00, 0x00,
                0x00, 0x00,
                UInt8(sign >> 8), UInt8(sign & 0xFF),
                0x00, 0x00,
            ])
            #expect(PostgresValueDecoder.decodeNumeric(&buffer) == expected)
        }
    }
}

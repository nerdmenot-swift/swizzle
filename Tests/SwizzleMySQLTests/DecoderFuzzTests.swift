import NIOCore
import Testing
@testable import SwizzleMySQL

/// Random bytes through every decoder, asserting only that none of them traps.
///
/// ## What this is for, and what it is not
///
/// It is not checking that anything decodes *correctly* — the oracle suites do
/// that, against a real server. This asks a narrower question that no
/// correctness test can: **does malformed input crash the process?**
///
/// That distinction matters because the two failure modes need different
/// evidence. A wrong value shows up as a mismatch and is caught by comparing
/// against the server. An out-of-range read shows up as a trap, takes the whole
/// process with it, and cannot be caught by any test that only ever supplies
/// well-formed input — which is every test that goes through a server, because a
/// server does not send malformed rows.
///
/// The Postgres pass found two of these by accident: `row[-1]` and
/// `array(at:)` both trapped, and both were reachable from the public API. They
/// were found by a mutation survivor pointing at the guard, not by any test
/// exercising it. Random bytes find that class directly.
///
/// ## Why the decoders are the right target
///
/// Everything here parses bytes the *server* chose — lengths, counts, and
/// offsets that the driver then indexes with. A hostile or desynchronised peer
/// is the threat model, and "the server would never send that" is exactly the
/// assumption that makes a guard untested.
///
/// Deterministic: the generator is seeded, so a failure reproduces from the
/// seed printed in the message rather than "sometimes".
@Suite("MySQL decoder fuzzing")
struct DecoderFuzzTests {

    /// A small deterministic PRNG, so a failure is reproducible from its seed.
    ///
    /// `SystemRandomNumberGenerator` would make each run explore new input,
    /// which sounds better and is worse: a failure that cannot be reproduced is
    /// a failure that cannot be fixed, and this suite runs on every CI job.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    static func bytes(_ generator: inout Seeded, upTo length: Int) -> [UInt8] {
        let count = Int(generator.next() % UInt64(length + 1))
        return (0..<count).map { _ in UInt8(generator.next() % 256) }
    }

    /// Every column type the driver can be handed, including the ones a server
    /// never sends — a desynchronised stream can put any byte in that field.
    static let types = MySQLColumnType.allCases

    // MARK: - Text protocol

    /// `decodeText` takes the bytes between length prefixes, so its input is
    /// arbitrary by construction: a `DECIMAL` column can carry anything the
    /// server put there, and the driver parses it.
    @Test("no random input traps the text decoder", arguments: [UInt64](1...12))
    func textDecoderSurvivesRandomBytes(seed: UInt64) {
        var generator = Seeded(seed: seed)
        for _ in 0..<400 {
            let type = Self.types[Int(generator.next() % UInt64(Self.types.count))]
            let flags = MySQLColumnFlags(rawValue: UInt16(generator.next() % 65536))
            var buffer = ByteBufferAllocator().buffer(capacity: 32)
            buffer.writeBytes(Self.bytes(&generator, upTo: 24))
            // The only assertion is that this returns. A wrong value here is not
            // a finding; a trap is.
            _ = MySQLValue.decodeText(buffer, type: type, flags: flags)
        }
    }

    // MARK: - Binary protocol

    /// `decodeBinary` reads its own lengths from the buffer, which is the shape
    /// that goes wrong: a length byte says eleven and four bytes remain.
    @Test("no random input traps the binary decoder", arguments: [UInt64](1...12))
    func binaryDecoderSurvivesRandomBytes(seed: UInt64) {
        var generator = Seeded(seed: seed)
        for _ in 0..<400 {
            let type = Self.types[Int(generator.next() % UInt64(Self.types.count))]
            let flags = MySQLColumnFlags(rawValue: UInt16(generator.next() % 65536))
            var buffer = ByteBufferAllocator().buffer(capacity: 32)
            buffer.writeBytes(Self.bytes(&generator, upTo: 24))
            // Throwing is a correct outcome — the packet was malformed and the
            // decoder said so. Trapping is not.
            _ = try? MySQLValue.decodeBinary(&buffer, type: type, flags: flags)
        }
    }

    /// The temporal decoders specifically, because their length prefix is the
    /// thing that decides how many further reads happen — the classic shape for
    /// reading past the end.
    @Test("no random input traps the temporal decoders", arguments: [UInt64](1...12))
    func temporalDecodersSurviveRandomBytes(seed: UInt64) {
        var generator = Seeded(seed: seed)
        for _ in 0..<400 {
            var buffer = ByteBufferAllocator().buffer(capacity: 24)
            buffer.writeBytes(Self.bytes(&generator, upTo: 16))
            _ = try? MySQLValue.decodeBinaryDateTime(&buffer)

            var other = ByteBufferAllocator().buffer(capacity: 24)
            other.writeBytes(Self.bytes(&generator, upTo: 16))
            _ = try? MySQLValue.decodeBinaryTime(&other)
        }
    }

    // MARK: - Deliberate shapes

    /// A length prefix that promises more than the buffer holds, at every width
    /// the temporal encodings use. Random bytes reach this eventually; naming it
    /// means it is reached every run.
    @Test("a length prefix longer than the buffer is refused, not read past")
    func lyingLengthPrefix() {
        for promised in [UInt8(4), 7, 11, 8, 12, 255] {
            for supplied in 0..<4 {
                var buffer = ByteBufferAllocator().buffer(capacity: 8)
                buffer.writeInteger(promised, endianness: .little)
                buffer.writeBytes([UInt8](repeating: 0xFF, count: supplied))
                _ = try? MySQLValue.decodeBinaryDateTime(&buffer)

                var other = ByteBufferAllocator().buffer(capacity: 8)
                other.writeInteger(promised, endianness: .little)
                other.writeBytes([UInt8](repeating: 0xFF, count: supplied))
                _ = try? MySQLValue.decodeBinaryTime(&other)
            }
        }
    }

    /// An empty buffer for every type, which is what a truncated packet leaves.
    @Test("an empty buffer is refused by every decoder")
    func emptyBuffer() {
        for type in Self.types {
            let empty = ByteBufferAllocator().buffer(capacity: 0)
            _ = MySQLValue.decodeText(empty, type: type, flags: MySQLColumnFlags(rawValue: 0))

            var binary = ByteBufferAllocator().buffer(capacity: 0)
            _ = try? MySQLValue.decodeBinary(
                &binary, type: type, flags: MySQLColumnFlags(rawValue: 0)
            )
        }
    }

    /// The bug this suite found on its first run, pinned by name.
    ///
    /// `0xFE` introduces an **eight-byte** length-encoded integer, so the peer
    /// chooses a `UInt64`. `readLengthEncodedSlice` converted it with
    /// `Int(length)`, which traps above `Int64.max` — and every length-encoded
    /// string in the protocol comes through that function, so any packet on any
    /// connection could take the process down.
    ///
    /// Kept as its own test rather than left to the random pass: a seeded fuzzer
    /// that finds something should hand the finding to a test that always runs
    /// it, or the coverage depends on nobody changing the seed.
    @Test("a length-encoded integer above Int64.max is refused, not converted")
    func hugeLengthEncodedIntegerIsRefused() {
        // 0xFE then eight bytes whose value exceeds Int64.max.
        var buffer = ByteBufferAllocator().buffer(capacity: 16)
        buffer.writeBytes([0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        #expect(buffer.readLengthEncodedSlice() == nil)
        #expect(buffer.readerIndex == 0, "a refused read must not consume anything")

        // And the exact bytes the fuzzer produced.
        var found = ByteBufferAllocator().buffer(capacity: 16)
        found.writeBytes([254, 183, 142, 71, 217, 144, 23, 197, 136, 51, 7])
        _ = try? MySQLValue.decodeBinary(
            &found, type: .typedArray, flags: MySQLColumnFlags(rawValue: 41144)
        )
    }

    /// A length that fits in an `Int` but exceeds the buffer is also malformed,
    /// and must be refused rather than clamped.
    @Test("a length longer than the buffer is refused")
    func lengthBeyondTheBuffer() {
        var buffer = ByteBufferAllocator().buffer(capacity: 16)
        buffer.writeBytes([0xFC, 0xFF, 0xFF, 0x01, 0x02])  // claims 65535, supplies 2
        #expect(buffer.readLengthEncodedSlice() == nil)
        #expect(buffer.readerIndex == 0)
    }

}

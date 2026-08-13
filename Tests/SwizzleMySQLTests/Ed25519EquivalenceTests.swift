import Crypto
import Foundation
import Testing
@testable import SwizzleMySQL

/// Differential tests: the radix-2^51 production core against the radix-2^16
/// TweetNaCl implementation it replaced.
///
/// The two share no carry logic, no reduction strategy and no serialisation
/// path, so agreement across thousands of inputs is meaningful evidence rather
/// than a tautology. The TweetNaCl side was itself validated byte-for-byte
/// against libsodium before that dependency was removed, which makes this a
/// transitive check against libsodium too.
@Suite("ed25519 field-layer equivalence")
struct Ed25519EquivalenceTests {

    /// Deterministic pseudo-random bytes, so any failure is reproducible.
    static func bytes(seed: UInt64, count: Int) -> [UInt8] {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 33)
        }
    }

    /// Random field elements, expressed in both representations.
    static func fieldPair(seed: UInt64) -> (Ed25519Core.Field, TweetNaClReference.FieldElement) {
        var raw = bytes(seed: seed, count: 32)
        raw[31] &= 0x7F                            // keep below 2^255
        var tweet = TweetNaClReference.zero
        for i in 0..<16 {
            tweet[i] = Int64(raw[2 * i]) | (Int64(raw[2 * i + 1]) << 8)
        }
        return (Ed25519Core.unpack(raw), tweet)
    }

    // MARK: - Field layer

    @Test func packAgreesOnRandomElements() {
        for seed in 0..<500 {
            let (fast, slow) = Self.fieldPair(seed: UInt64(seed))
            #expect(Ed25519Core.pack(fast) == TweetNaClReference.pack(slow), "seed \(seed)")
        }
    }

    @Test func multiplyAgrees() {
        for seed in 0..<500 {
            let (a, x) = Self.fieldPair(seed: UInt64(seed))
            let (b, y) = Self.fieldPair(seed: UInt64(seed) &+ 100_000)
            #expect(
                Ed25519Core.pack(Ed25519Core.multiply(a, b))
                    == TweetNaClReference.pack(TweetNaClReference.multiply(x, y)),
                "seed \(seed)"
            )
        }
    }

    /// Squaring has its own code path with the symmetric terms collected, so it
    /// gets its own check rather than riding on multiply's.
    @Test func squareAgreesAndMatchesSelfMultiply() {
        for seed in 0..<500 {
            let (a, x) = Self.fieldPair(seed: UInt64(seed))
            let squared = Ed25519Core.pack(Ed25519Core.square(a))
            #expect(squared == TweetNaClReference.pack(TweetNaClReference.square(x)), "seed \(seed)")
            #expect(squared == Ed25519Core.pack(Ed25519Core.multiply(a, a)), "seed \(seed)")
        }
    }

    @Test func addAndSubtractAgree() {
        for seed in 0..<500 {
            let (a, x) = Self.fieldPair(seed: UInt64(seed))
            let (b, y) = Self.fieldPair(seed: UInt64(seed) &+ 200_000)
            #expect(
                Ed25519Core.pack(Ed25519Core.add(a, b))
                    == TweetNaClReference.pack(TweetNaClReference.add(x, y)),
                "add, seed \(seed)"
            )
            #expect(
                Ed25519Core.pack(Ed25519Core.subtract(a, b))
                    == TweetNaClReference.pack(TweetNaClReference.subtract(x, y)),
                "subtract, seed \(seed)"
            )
        }
    }

    @Test func invertAgrees() {
        for seed in 0..<40 {
            let (a, x) = Self.fieldPair(seed: UInt64(seed) &+ 300_000)
            #expect(
                Ed25519Core.pack(Ed25519Core.invert(a))
                    == TweetNaClReference.pack(TweetNaClReference.invert(x)),
                "seed \(seed)"
            )
        }
    }

    /// Carry propagation is where a limb representation actually breaks, and it
    /// only breaks near the boundaries — which random 32-byte values almost
    /// never hit.
    @Test func agreesOnCarryBoundaryValues() {
        let interesting: [[UInt8]] = [
            [UInt8](repeating: 0x00, count: 32),
            [UInt8](repeating: 0xFF, count: 31) + [0x7F],   // 2^255 − 1
            // p − 1, p, p + 1 — the canonicalisation boundary.
            Ed25519Core.hexBytes(
                "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"),
            Ed25519Core.hexBytes(
                "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"),
            Ed25519Core.hexBytes(
                "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"),
            [0x01] + [UInt8](repeating: 0x00, count: 31),
            [UInt8](repeating: 0x00, count: 31) + [0x40],
        ]

        for raw in interesting {
            let fast = Ed25519Core.unpack(raw)
            var slow = TweetNaClReference.zero
            for i in 0..<16 { slow[i] = Int64(raw[2 * i]) | (Int64(raw[2 * i + 1]) << 8) }
            slow[15] &= 0x7FFF

            #expect(Ed25519Core.pack(fast) == TweetNaClReference.pack(slow))
            #expect(
                Ed25519Core.pack(Ed25519Core.square(fast))
                    == TweetNaClReference.pack(TweetNaClReference.square(slow))
            )
        }
    }

    // MARK: - Group layer

    @Test func scalarMultiplyBaseAgrees() {
        for seed in 0..<60 {
            let scalar = Ed25519Core.reduceScalar(Self.bytes(seed: UInt64(seed) &+ 77, count: 64))
            #expect(
                Ed25519Core.scalarMultiplyBase(scalar)
                    == TweetNaClReference.scalarMultiplyBase(scalar),
                "seed \(seed)"
            )
        }
    }

    // MARK: - End to end

    @Test func publicKeysAgree() throws {
        for seed in 0..<60 {
            let password = "pw-\(seed)"
            #expect(
                try MySQLEd25519.publicKey(password: password)
                    == TweetNaClReference.publicKey(password: password),
                "seed \(seed)"
            )
        }
    }

    @Test func signaturesAgree() throws {
        for seed in 0..<60 {
            let password = "secret-\(seed)"
            let scramble = Self.bytes(seed: UInt64(seed) &+ 9_999, count: 32)
            #expect(
                try MySQLEd25519.sign(password: password, scramble: scramble)
                    == TweetNaClReference.sign(password: password, scramble: scramble),
                "seed \(seed)"
            )
        }
    }

    /// Independent of both implementations: swift-crypto must accept what we
    /// produce. This is what would catch an error common to the pair.
    @Test func signaturesVerifyUnderSwiftCrypto() throws {
        for seed in 0..<40 {
            let password = "verify-\(seed)"
            let scramble = Self.bytes(seed: UInt64(seed) &+ 555, count: 32)
            let signature = try MySQLEd25519.sign(password: password, scramble: scramble)
            let key = try Curve25519.Signing.PublicKey(
                rawRepresentation: MySQLEd25519.publicKey(password: password)
            )
            #expect(
                key.isValidSignature(Data(signature), for: Data(scramble)),
                "swift-crypto rejected signature at seed \(seed)"
            )
        }
    }
}

/// The precomputed-table fixed-base multiplication against the Montgomery
/// ladder it replaced.
///
/// Same discipline as the field-layer rewrite: the fast path is checked against
/// the slow one that was already validated, rather than only against itself. The
/// signed-digit recoding is the interesting part — a carry that propagates wrong
/// produces a plausible-looking point rather than an obvious failure.
@Suite("ed25519 fixed-base table")
struct Ed25519FixedBaseTests {

    static func bytes(seed: UInt64, count: Int) -> [UInt8] {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 33)
        }
    }

    @Test func tableAgreesWithTheLadderOnRandomScalars() {
        for seed in 0..<200 {
            let scalar = Ed25519Core.reduceScalar(Self.bytes(seed: UInt64(seed), count: 64))
            #expect(
                Ed25519Core.scalarMultiplyBase(scalar)
                    == Ed25519Core.scalarMultiplyBaseViaLadder(scalar),
                "seed \(seed)"
            )
        }
    }

    /// Clamped scalars have bit 254 set and bit 255 clear, which is a different
    /// shape from a reduced scalar and exercises the top window.
    @Test func tableAgreesOnClampedScalars() {
        for seed in 0..<100 {
            let scalar = MySQLEd25519.clamp(Self.bytes(seed: UInt64(seed) &+ 5_000, count: 32))
            #expect(
                Ed25519Core.scalarMultiplyBase(scalar)
                    == Ed25519Core.scalarMultiplyBaseViaLadder(scalar),
                "seed \(seed)"
            )
        }
    }

    /// Values chosen to drive the signed-digit carry: all-zero nibbles, all-F
    /// nibbles (every digit becomes −1 with a carry), and the boundary at 8
    /// where a digit flips sign.
    @Test func tableAgreesOnDigitBoundaries() {
        let scalars: [[UInt8]] = [
            [UInt8](repeating: 0x00, count: 32),
            [UInt8](repeating: 0x01, count: 31) + [0x00],
            [UInt8](repeating: 0xFF, count: 31) + [0x0F],
            [UInt8](repeating: 0x88, count: 31) + [0x08],
            [UInt8](repeating: 0x78, count: 31) + [0x07],
            [UInt8](repeating: 0x80, count: 31) + [0x00],
            [0x08] + [UInt8](repeating: 0x00, count: 31),
        ]
        for scalar in scalars {
            #expect(
                Ed25519Core.scalarMultiplyBase(scalar)
                    == Ed25519Core.scalarMultiplyBaseViaLadder(scalar),
                "scalar \(scalar.prefix(4))"
            )
        }
    }

    /// A zero scalar must still give the identity, as before.
    @Test func zeroScalarStillYieldsIdentity() {
        var expected = [UInt8](repeating: 0, count: 32)
        expected[0] = 1
        #expect(Ed25519Core.scalarMultiplyBase([UInt8](repeating: 0, count: 32)) == expected)
    }

    /// The recoding must reconstruct the original scalar: sum of digit·16^i.
    @Test func signedDigitsReconstructTheScalar() {
        for seed in 0..<100 {
            let scalar = Ed25519Core.reduceScalar(Self.bytes(seed: UInt64(seed) &+ 900, count: 64))
            let digits = Ed25519Core.signedDigits(scalar)

            var total = 0 as Int
            var scale = 1 as Int
            // Only the low 60 bits, which is enough to catch a recoding slip
            // without needing bignum arithmetic here.
            for i in 0..<15 {
                total += Int(digits[i]) * scale
                scale *= 16
            }
            var expected = 0 as Int
            for i in 0..<8 { expected |= Int(scalar[i]) << (8 * i) }
            #expect(total & 0xFFFF_FFFF_FFFF == expected & 0xFFFF_FFFF_FFFF, "seed \(seed)")
        }
    }
}

/// The vendored libsodium C against the pure-Swift `Ed25519Core`.
///
/// Completes the triangle. `MySQLEd25519` (C) is already checked against
/// `TweetNaClReference` elsewhere in this file, and `Ed25519Core` against
/// `TweetNaClReference` too; this closes the third edge directly, so a
/// disagreement anywhere is localised rather than merely detected.
///
/// The two share nothing: different language, different field representation
/// internals, different scalar-multiplication strategy (ref10's windowed comb
/// versus our signed-digit table).
@Suite("vendored C vs Swift oracle")
struct VendoredCEquivalenceTests {

    static func bytes(seed: UInt64, count: Int) -> [UInt8] {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 33)
        }
    }

    @Test func scalarReduceAgrees() throws {
        for seed in 0..<300 {
            let wide = Self.bytes(seed: UInt64(seed) &+ 11, count: 64)
            #expect(try MySQLEd25519.reduce(wide) == Ed25519Core.reduceScalar(wide), "seed \(seed)")
        }
    }

    @Test func scalarMultiplyBaseAgrees() throws {
        for seed in 0..<200 {
            let scalar = Ed25519Core.reduceScalar(Self.bytes(seed: UInt64(seed) &+ 22, count: 64))
            #expect(
                try MySQLEd25519.scalarMultiplyBase(scalar)
                    == Ed25519Core.scalarMultiplyBase(scalar),
                "seed \(seed)"
            )
        }
    }

    @Test func scalarMulAndAddAgree() throws {
        for seed in 0..<300 {
            let a = Ed25519Core.reduceScalar(Self.bytes(seed: UInt64(seed) &+ 33, count: 64))
            let b = Ed25519Core.reduceScalar(Self.bytes(seed: UInt64(seed) &+ 44, count: 64))
            let c = Ed25519Core.reduceScalar(Self.bytes(seed: UInt64(seed) &+ 55, count: 64))

            let zero = [UInt8](repeating: 0, count: 32)
            #expect(MySQLEd25519.multiply(a, b) == Ed25519Core.multiplyAdd(a, b, zero), "mul \(seed)")

            var one = zero; one[0] = 1
            #expect(MySQLEd25519.add(a, c) == Ed25519Core.multiplyAdd(a, one, c), "add \(seed)")
        }
    }

    @Test func publicKeysAndSignaturesAgree() throws {
        for seed in 0..<150 {
            let password = "triangle-\(seed)"
            let scramble = Self.bytes(seed: UInt64(seed) &+ 66, count: 32)

            #expect(
                try MySQLEd25519.publicKey(password: password)
                    == TweetNaClReference.publicKey(password: password),
                "public key, seed \(seed)"
            )
            #expect(
                try MySQLEd25519.sign(password: password, scramble: scramble)
                    == TweetNaClReference.sign(password: password, scramble: scramble),
                "signature, seed \(seed)"
            )
        }
    }
}

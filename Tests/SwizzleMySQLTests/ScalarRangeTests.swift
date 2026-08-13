import Crypto
import Foundation
import Testing
@testable import SwizzleMySQL

/// The precondition the fixed-base table depends on, and proof that every real
/// caller satisfies it.
///
/// Signed-digit recoding needs `scalar[31] <= 127`. Above that the final carry
/// pushes the top digit to 16, which no table entry matches — so that window
/// contributes nothing and the answer is **silently wrong** rather than
/// erroring. That was demonstrated during review, which is why the recoding now
/// traps instead of trusting its callers.
///
/// The two real inputs are a clamped secret and a scalar reduced mod L. Both are
/// swept here over many values rather than argued about, because the whole point
/// is that a future third caller must not quietly violate it.
@Suite("ed25519 scalar range")
struct ScalarRangeTests {

    static func bytes(seed: UInt64, count: Int) -> [UInt8] {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 33)
        }
    }

    /// Clamping clears bit 255, so the top byte is always <= 127.
    @Test func clampedSecretsAreInRange() {
        for seed in 0..<500 {
            let clamped = MySQLEd25519.clamp(Self.bytes(seed: UInt64(seed), count: 32))
            #expect(clamped[31] <= 127, "seed \(seed) produced \(clamped[31])")
            #expect(clamped[31] & 0x40 != 0, "bit 254 must be set")
            #expect(clamped[0] & 0x07 == 0, "low three bits must be clear")
        }
    }

    /// A scalar reduced mod L is below 2^253, so its top byte is at most 0x1F.
    @Test func reducedScalarsAreInRange() {
        for seed in 0..<500 {
            let reduced = Ed25519Core.reduceScalar(Self.bytes(seed: UInt64(seed), count: 64))
            #expect(reduced[31] <= 0x1F, "seed \(seed) produced \(reduced[31])")
        }
    }

    /// The two scalars an actual signature feeds to the table, taken from the
    /// real derivation rather than constructed.
    @Test func bothScalarsInARealSignatureAreInRange() throws {
        for seed in 0..<100 {
            let password = "pw-\(seed)"
            let scramble = Self.bytes(seed: UInt64(seed) &+ 4_242, count: 32)

            let h = Array(SHA512.hash(data: Array(password.utf8)))
            let secret = MySQLEd25519.clamp(Array(h[0..<32]))
            let nonce = try MySQLEd25519.reduce(
                Array(SHA512.hash(data: Array(h[32...]) + scramble))
            )

            #expect(secret[31] <= 127, "secret scalar out of range at seed \(seed)")
            #expect(nonce[31] <= 127, "nonce scalar out of range at seed \(seed)")
        }
    }

    /// The boundary itself: 127 is the largest acceptable top byte, and its top
    /// digit must stay within the table's 1...8.
    @Test func theBoundaryValueIsAccepted() {
        var scalar = [UInt8](repeating: 0xFF, count: 32)
        scalar[31] = 127
        let digits = Ed25519Core.signedDigits(scalar)
        #expect(abs(Int(digits[63])) <= 8, "top digit \(digits[63]) exceeds the table")

        #expect(
            Ed25519Core.scalarMultiplyBase(scalar)
                == Ed25519Core.scalarMultiplyBaseViaLadder(scalar)
        )
    }

    /// Every digit must land inside the table for any in-range scalar — the
    /// property the selection loop silently depends on.
    @Test func everyDigitFitsTheTableForInRangeScalars() {
        for seed in 0..<300 {
            var scalar = Self.bytes(seed: UInt64(seed), count: 32)
            scalar[31] &= 0x7F
            for (index, digit) in Ed25519Core.signedDigits(scalar).enumerated() {
                #expect(abs(Int(digit)) <= 8, "digit \(index) = \(digit) at seed \(seed)")
            }
        }
    }
}

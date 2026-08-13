import Crypto
import Foundation
import Testing
@testable import SwizzleMySQL

/// Performance guard for `client_ed25519` signing.
///
/// This exists because the first working implementation was **21.5 ms per
/// signature** — 500× swift-crypto's BoringSSL — and nothing in the correctness
/// suite noticed. Signing happens on the event loop during authentication, so
/// that would have stalled every other connection sharing the loop for the
/// duration.
///
/// The bound is deliberately loose. The point is to catch a return to
/// tens-of-milliseconds, not to police a few hundred microseconds on a shared
/// CI box.
@Suite("ed25519 performance")
struct Ed25519Bench {

    /// Roughly 10× the measured cost on a development machine (~1.7 ms), so
    /// ordinary machine-to-machine variation cannot trip it but a regression to
    /// the array-based representation would.
    static let signBudget: Double = 20.0

    static func milliseconds(iterations: Int, _ body: () throws -> Void) rethrows -> Double {
        for _ in 0..<3 { try body() }                    // warm up
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { try body() }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        return Double(elapsed) / Double(iterations) / 1_000_000.0
    }

    @Test func signingStaysWithinBudget() throws {
        let scramble = [UInt8](repeating: 0x5A, count: 32)
        let perSign = try Self.milliseconds(iterations: 20) {
            _ = try MySQLEd25519.sign(password: "ed25519pass", scramble: scramble)
        }
        print(String(format: "BENCH ed25519 sign: %.3f ms/op", perSign))
        #expect(
            perSign < Self.signBudget,
            "ed25519 signing took \(perSign) ms — a representation regression?"
        )
    }

    /// Printed for context rather than asserted: the gap to BoringSSL is
    /// expected and understood. BoringSSL uses precomputed base-point tables and
    /// hand-written assembly; this is a portable Swift Montgomery ladder with no
    /// tables. Closing that gap is possible but buys nothing — the operation
    /// happens once per connection, inside a handshake already dominated by
    /// round trips.
    @Test func reportsTheGapToSwiftCrypto() throws {
        let key = Curve25519.Signing.PrivateKey()
        let message = Data([UInt8](repeating: 0x5A, count: 32))
        let reference = try Self.milliseconds(iterations: 200) {
            _ = try key.signature(for: message)
        }
        print(String(format: "BENCH swift-crypto sign (reference): %.3f ms/op", reference))
    }
}

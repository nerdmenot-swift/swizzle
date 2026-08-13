import Foundation
import Testing
@testable import SwizzleMySQL

/// The base-point table is an 80 KB `static let` built on first use.
///
/// In a connection pool several connections can authenticate at once, on
/// different event loops, and all reach it simultaneously — so "first use" is
/// genuinely concurrent in production. Swift guarantees `static let` runs its
/// initialiser exactly once, but the table is built by calling back into the
/// same type's point arithmetic, which is worth exercising rather than assuming.
@Suite("ed25519 concurrency")
struct Ed25519ConcurrencyTests {

    @Test func concurrentFirstUseProducesConsistentResults() async throws {
        let scramble = [UInt8](repeating: 0x5A, count: 32)
        let expected = try MySQLEd25519.sign(password: "ed25519pass", scramble: scramble)

        let results = await withTaskGroup(of: [UInt8].self, returning: [[UInt8]].self) { group in
            for index in 0..<64 {
                group.addTask {
                    // Vary the work so tasks are not lock-stepped.
                    let password = index % 2 == 0 ? "ed25519pass" : "other-\(index)"
                    let signature = (try? MySQLEd25519.sign(
                        password: password, scramble: scramble
                    )) ?? []
                    return password == "ed25519pass" ? signature : []
                }
            }
            var collected: [[UInt8]] = []
            for await value in group where !value.isEmpty { collected.append(value) }
            return collected
        }

        #expect(results.count == 32)
        for signature in results {
            #expect(signature == expected, "concurrent signing diverged")
        }
    }

    /// Public keys are the pure-derivation half; same check, different path.
    @Test func concurrentPublicKeyDerivationIsConsistent() async throws {
        let expected = try MySQLEd25519.publicKey(password: "ed25519pass")
        let results = await withTaskGroup(of: [UInt8].self, returning: [[UInt8]].self) { group in
            for _ in 0..<64 {
                group.addTask {
                    (try? MySQLEd25519.publicKey(password: "ed25519pass")) ?? []
                }
            }
            var collected: [[UInt8]] = []
            for await value in group { collected.append(value) }
            return collected
        }
        #expect(results.allSatisfy { $0 == expected })
    }
}

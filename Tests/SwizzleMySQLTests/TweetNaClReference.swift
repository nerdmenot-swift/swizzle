import Crypto
import Foundation

/// The TweetNaCl-based Edwards25519 implementation that `Ed25519Core` replaced,
/// kept as a **differential oracle**.
///
/// It is here rather than deleted because it was validated byte-for-byte
/// against libsodium while libsodium was still a dependency. That makes it a
/// second, independently-structured witness: it uses sixteen limbs of radix
/// 2^16 where the production code uses five of radix 2^51, so the two share no
/// carry logic, no reduction strategy and no serialisation path. A bug that
/// produced matching wrong answers in both would have to be a bug in the shared
/// *algebra*, which is the part that has not changed.
///
/// Port of TweetNaCl's signing path (Bernstein, van Gastel, Janssen, Lange,
/// Schwabe, Smetsers), placed by its authors in the **public domain**.
///
/// Test-target only: never compiled into the library.
enum TweetNaClReference {

    typealias FieldElement = [Int64]

    static let zero: FieldElement = [Int64](repeating: 0, count: 16)
    static var one: FieldElement {
        var element = zero
        element[0] = 1
        return element
    }

    static let d2: FieldElement = [
        0xf159, 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283, 0x149a, 0x00e0,
        0xd130, 0xeef3, 0x80f2, 0x198e, 0xfce7, 0x56df, 0xd9dc, 0x2406,
    ]
    static let baseX: FieldElement = [
        0xd51a, 0x8f25, 0x2d60, 0xc956, 0xa7b2, 0x9525, 0xc760, 0x692c,
        0xdc5c, 0xfdd6, 0xe231, 0xc0a4, 0x53fe, 0xcd6e, 0x36d3, 0x2169,
    ]
    static let baseY: FieldElement = [
        0x6658, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666,
        0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666,
    ]

    static let groupOrder: [Int64] = [
        0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58,
        0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0x10,
    ]

    // MARK: - Field arithmetic

    static func carry(_ element: inout FieldElement) {
        for i in 0..<16 {
            element[i] += 1 << 16
            let c = element[i] >> 16
            if i < 15 {
                element[i + 1] += c - 1
            } else {
                element[0] += 38 * (c - 1)
            }
            element[i] -= c << 16
        }
    }

    static func conditionalSwap(
        _ p: inout FieldElement, _ q: inout FieldElement, _ swap: Int64
    ) {
        let mask = ~(swap - 1)
        for i in 0..<16 {
            let t = mask & (p[i] ^ q[i])
            p[i] ^= t
            q[i] ^= t
        }
    }

    static func add(_ a: FieldElement, _ b: FieldElement) -> FieldElement {
        var out = zero
        for i in 0..<16 { out[i] = a[i] + b[i] }
        return out
    }

    static func subtract(_ a: FieldElement, _ b: FieldElement) -> FieldElement {
        var out = zero
        for i in 0..<16 { out[i] = a[i] - b[i] }
        return out
    }

    static func multiply(_ a: FieldElement, _ b: FieldElement) -> FieldElement {
        var product = [Int64](repeating: 0, count: 31)
        for i in 0..<16 {
            for j in 0..<16 {
                product[i + j] += a[i] * b[j]
            }
        }
        for i in 0..<15 { product[i] += 38 * product[i + 16] }

        var out = zero
        for i in 0..<16 { out[i] = product[i] }
        carry(&out)
        carry(&out)
        return out
    }

    static func square(_ a: FieldElement) -> FieldElement { multiply(a, a) }

    static func invert(_ a: FieldElement) -> FieldElement {
        var c = a
        for i in stride(from: 253, through: 0, by: -1) {
            c = square(c)
            if i != 2 && i != 4 { c = multiply(c, a) }
        }
        return c
    }

    static func pack(_ n: FieldElement) -> [UInt8] {
        var t = n
        carry(&t)
        carry(&t)
        carry(&t)

        for _ in 0..<2 {
            var m = zero
            m[0] = t[0] - 0xffed
            for i in 1..<15 {
                m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1)
                m[i - 1] &= 0xffff
            }
            m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1)
            let b = (m[15] >> 16) & 1
            m[14] &= 0xffff
            conditionalSwap(&t, &m, 1 - b)
        }

        var out = [UInt8](repeating: 0, count: 32)
        for i in 0..<16 {
            out[2 * i] = UInt8(truncatingIfNeeded: t[i])
            out[2 * i + 1] = UInt8(truncatingIfNeeded: t[i] >> 8)
        }
        return out
    }

    static func parity(_ a: FieldElement) -> UInt8 { pack(a)[0] & 1 }

    // MARK: - Group arithmetic

    typealias Point = [FieldElement]

    static var identity: Point { [zero, one, one, zero] }
    static var basePoint: Point { [baseX, baseY, one, multiply(baseX, baseY)] }

    static func addPoints(_ p: Point, _ q: Point) -> Point {
        var a = subtract(p[1], p[0])
        var t = subtract(q[1], q[0])
        a = multiply(a, t)

        var b = add(p[0], p[1])
        t = add(q[0], q[1])
        b = multiply(b, t)

        var c = multiply(p[3], q[3])
        c = multiply(c, d2)

        var d = multiply(p[2], q[2])
        d = add(d, d)

        let e = subtract(b, a)
        let f = subtract(d, c)
        let g = add(d, c)
        let h = add(b, a)

        return [multiply(e, f), multiply(h, g), multiply(g, f), multiply(e, h)]
    }

    static func conditionalSwapPoints(_ p: inout Point, _ q: inout Point, _ swap: Int64) {
        for i in 0..<4 { conditionalSwap(&p[i], &q[i], swap) }
    }

    static func packPoint(_ p: Point) -> [UInt8] {
        let zInverse = invert(p[2])
        let x = multiply(p[0], zInverse)
        let y = multiply(p[1], zInverse)
        var out = pack(y)
        out[31] ^= parity(x) << 7
        return out
    }

    static func scalarMultiply(_ q: Point, by scalar: [UInt8]) -> Point {
        var p = identity
        var q = q
        for i in stride(from: 255, through: 0, by: -1) {
            let bit = Int64((scalar[i / 8] >> UInt8(i & 7)) & 1)
            conditionalSwapPoints(&p, &q, bit)
            q = addPoints(q, p)
            p = addPoints(p, p)
            conditionalSwapPoints(&p, &q, bit)
        }
        return p
    }

    static func scalarMultiplyBase(_ scalar: [UInt8]) -> [UInt8] {
        packPoint(scalarMultiply(basePoint, by: scalar))
    }

    // MARK: - Scalar arithmetic mod L

    static func reduceScalar(_ input: [UInt8]) -> [UInt8] {
        var x = [Int64](repeating: 0, count: 64)
        for i in 0..<min(64, input.count) { x[i] = Int64(input[i]) }
        return modL(&x)
    }

    static func multiplyAdd(_ a: [UInt8], _ b: [UInt8], _ c: [UInt8]) -> [UInt8] {
        var x = [Int64](repeating: 0, count: 64)
        for i in 0..<32 { x[i] = Int64(c[i]) }
        for i in 0..<32 {
            for j in 0..<32 { x[i + j] += Int64(a[i]) * Int64(b[j]) }
        }
        return modL(&x)
    }

    static func modL(_ x: inout [Int64]) -> [UInt8] {
        var carryValue: Int64 = 0
        for i in stride(from: 63, through: 32, by: -1) {
            carryValue = 0
            var j = i - 32
            while j < i - 12 {
                x[j] += carryValue - 16 * x[i] * groupOrder[j - (i - 32)]
                carryValue = (x[j] + 128) >> 8
                x[j] -= carryValue << 8
                j += 1
            }
            x[j] += carryValue
            x[i] = 0
        }
        carryValue = 0
        for j in 0..<32 {
            x[j] += carryValue - (x[31] >> 4) * groupOrder[j]
            carryValue = x[j] >> 8
            x[j] &= 255
        }
        for j in 0..<32 { x[j] -= carryValue * groupOrder[j] }

        var out = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 {
            x[i + 1] += x[i] >> 8
            out[i] = UInt8(truncatingIfNeeded: x[i])
        }
        return out
    }

    // MARK: - The full plugin algorithm, for end-to-end comparison

    static func clamp(_ bytes: [UInt8]) -> [UInt8] {
        var out = bytes
        out[0] &= 248
        out[31] &= 127
        out[31] |= 64
        return out
    }

    static func sign(password: String, scramble: [UInt8]) -> [UInt8] {
        guard !password.isEmpty else { return [] }
        let h = Array(SHA512.hash(data: Array(password.utf8)))
        let secret = clamp(Array(h[0..<32]))
        let noncePrefix = Array(h[32...])

        let r = reduceScalar(Array(SHA512.hash(data: noncePrefix + scramble)))
        let R = scalarMultiplyBase(r)
        let A = scalarMultiplyBase(secret)
        let k = reduceScalar(Array(SHA512.hash(data: R + A + scramble)))
        return R + multiplyAdd(k, secret, r)
    }

    static func publicKey(password: String) -> [UInt8] {
        let h = Array(SHA512.hash(data: Array(password.utf8)))
        return scalarMultiplyBase(clamp(Array(h[0..<32])))
    }
}

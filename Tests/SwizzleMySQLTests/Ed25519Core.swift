import Foundation

/// Edwards25519 arithmetic in pure Swift — **test-only differential oracle**.
///
/// This was the production implementation until the ed25519 subset of
/// libsodium's ref10 was vendored (`CSodiumEd25519`). It is kept, and kept
/// running, because an independent second implementation is worth far more as a
/// test than as dead code: it shares no line of source with the C, so agreement
/// between them is real evidence rather than a tautology.
///
/// It was itself validated byte-for-byte against libsodium while libsodium was
/// a package dependency, and against swift-crypto at the one input length where
/// the two schemes coincide.
///
/// ## Why the C exists
///
/// MariaDB's `client_ed25519` seeds the ed25519 expansion with the *password
/// bytes* rather than a 32-byte seed. swift-crypto's
/// `Curve25519.Signing.PrivateKey` only accepts a 32-byte seed which it expands
/// itself, so there is no way to inject an already-expanded key — which is why
/// this needs raw scalar and group arithmetic that swift-crypto does not expose.
///
/// That was previously supplied by libsodium, which turned out to be the
/// **single** thing preventing a fully-static Linux build. Everything else in
/// the driver cross-compiled cleanly. See `docs/platforms.md`.
///
/// ## Representation
///
/// Field elements are five 51-bit limbs in a `struct` — the standard
/// "donna-c64" layout — with 128-bit accumulators for the products.
///
/// The accumulator is a hand-rolled pair of `UInt64`s rather than Swift's
/// `UInt128`, which requires macOS 15. Raising the deployment floor of the
/// whole library for an internal detail is a poor trade;
/// `multipliedFullWidth(by:)` compiles to the same single multiply instruction
/// and is available everywhere, Linux included.
///
/// The first working version of this file used TweetNaCl's 16 limbs of radix
/// 2^16 in an `[Int64]`, chosen for auditability. It was correct but **21.5 ms
/// per signature**, against 0.043 ms for swift-crypto's BoringSSL. Two causes:
/// radix 2^16 needs 256 limb products per field multiply where radix 2^51 needs
/// 25, and an `[Int64]` heap-allocates twice on every one of the ~5,000 field
/// multiplies in a scalar multiplication. Since signing happens on the event
/// loop during authentication, that stall would have blocked every other
/// connection sharing that loop.
///
/// The point-level algebra below is unchanged from the version that was
/// validated against libsodium; only the field layer was replaced. The
/// TweetNaCl implementation now lives in the test target as a differential
/// oracle (`TweetNaClReference`), so the rewrite is checked against the
/// implementation it replaced rather than only against itself.
///
/// ## On writing this by hand
///
/// Hand-written curve arithmetic in a database driver deserves scepticism. It
/// is defensible here only because the result is checkable against oracles that
/// cannot be talked into agreeing with a wrong implementation:
///
/// 1. Byte-identical to **libsodium** across randomised inputs, frozen into
///    `Ed25519VectorTests` as known-answer vectors before it was removed.
/// 2. Byte-identical to the **TweetNaCl** implementation this replaced, across
///    randomised inputs, in `Ed25519EquivalenceTests`.
/// 3. The derived public key equals the one **MariaDB stores** for a password.
/// 4. **swift-crypto** verifies every signature produced.
/// 5. Live authentication against MariaDB 11.4, 11.8 and 12.2.
enum Ed25519Core {

    /// A field element mod 2^255 − 19: five limbs of radix 2^51.
    ///
    /// A `struct` of fixed fields rather than an array, so it lives in
    /// registers and on the stack. That is not a micro-optimisation — the
    /// allocation traffic from an array representation was half the reason the
    /// first version was 500× slower than BoringSSL.
    struct Field: Equatable {
        var l0: UInt64, l1: UInt64, l2: UInt64, l3: UInt64, l4: UInt64

        init(_ l0: UInt64, _ l1: UInt64, _ l2: UInt64, _ l3: UInt64, _ l4: UInt64) {
            self.l0 = l0; self.l1 = l1; self.l2 = l2; self.l3 = l3; self.l4 = l4
        }

        static let mask: UInt64 = (1 << 51) - 1
        static let zero = Field(0, 0, 0, 0, 0)
        static let one = Field(1, 0, 0, 0, 0)
    }

    // MARK: - Field arithmetic

    @inline(__always)
    static func add(_ a: Field, _ b: Field) -> Field {
        Field(a.l0 &+ b.l0, a.l1 &+ b.l1, a.l2 &+ b.l2, a.l3 &+ b.l3, a.l4 &+ b.l4)
    }

    /// Adds `2p` before subtracting so the limbs never underflow.
    ///
    /// `0xFFFFFFFFFFFDA` is 2·(2^51 − 19) and `0xFFFFFFFFFFFFE` is 2·(2^51 − 1),
    /// which is 2p spread across the limbs — a multiple of p, so the value is
    /// unchanged mod p.
    @inline(__always)
    static func subtract(_ a: Field, _ b: Field) -> Field {
        Field(
            a.l0 &+ 0xF_FFFF_FFFF_FFDA &- b.l0,
            a.l1 &+ 0xF_FFFF_FFFF_FFFE &- b.l1,
            a.l2 &+ 0xF_FFFF_FFFF_FFFE &- b.l2,
            a.l3 &+ 0xF_FFFF_FFFF_FFFE &- b.l3,
            a.l4 &+ 0xF_FFFF_FFFF_FFFE &- b.l4
        )
    }

    /// A 128-bit accumulator as two 64-bit halves.
    ///
    /// Only the three operations the field multiply needs: accumulate a product,
    /// carry in a shifted value, and split off the low 51 bits.
    struct Wide {
        var low: UInt64 = 0
        var high: UInt64 = 0

        @inline(__always)
        mutating func addProduct(_ a: UInt64, _ b: UInt64) {
            let (productHigh, productLow) = a.multipliedFullWidth(by: b)
            let (sum, carried) = low.addingReportingOverflow(productLow)
            low = sum
            high = high &+ productHigh &+ (carried ? 1 : 0)
        }

        @inline(__always)
        mutating func add(_ other: Wide) {
            let (sum, carried) = low.addingReportingOverflow(other.low)
            low = sum
            high = high &+ other.high &+ (carried ? 1 : 0)
        }

        /// The accumulators stay below 2^114, so `high` is under 2^50 and the
        /// `<< 13` here cannot lose bits.
        @inline(__always)
        var shiftedRight51: Wide {
            Wide(low: (low >> 51) | (high << 13), high: high >> 51)
        }

        @inline(__always)
        var low51: UInt64 { low & Field.mask }
    }

    /// Schoolbook multiply with the reduction folded in.
    ///
    /// Terms that would land above limb 4 are multiplied by 19 and wrapped down,
    /// because 2^255 ≡ 19 (mod 2^255 − 19). The `19 * g` values are precomputed
    /// once per call rather than per term.
    @inline(__always)
    static func multiply(_ f: Field, _ g: Field) -> Field {
        let g1_19 = 19 &* g.l1
        let g2_19 = 19 &* g.l2
        let g3_19 = 19 &* g.l3
        let g4_19 = 19 &* g.l4

        var t0 = Wide(); var t1 = Wide(); var t2 = Wide(); var t3 = Wide(); var t4 = Wide()

        t0.addProduct(f.l0, g.l0); t0.addProduct(f.l1, g4_19); t0.addProduct(f.l2, g3_19)
        t0.addProduct(f.l3, g2_19); t0.addProduct(f.l4, g1_19)

        t1.addProduct(f.l0, g.l1); t1.addProduct(f.l1, g.l0); t1.addProduct(f.l2, g4_19)
        t1.addProduct(f.l3, g3_19); t1.addProduct(f.l4, g2_19)

        t2.addProduct(f.l0, g.l2); t2.addProduct(f.l1, g.l1); t2.addProduct(f.l2, g.l0)
        t2.addProduct(f.l3, g4_19); t2.addProduct(f.l4, g3_19)

        t3.addProduct(f.l0, g.l3); t3.addProduct(f.l1, g.l2); t3.addProduct(f.l2, g.l1)
        t3.addProduct(f.l3, g.l0); t3.addProduct(f.l4, g4_19)

        t4.addProduct(f.l0, g.l4); t4.addProduct(f.l1, g.l3); t4.addProduct(f.l2, g.l2)
        t4.addProduct(f.l3, g.l1); t4.addProduct(f.l4, g.l0)

        return carryReduce(&t0, &t1, &t2, &t3, &t4)
    }

    /// Squaring with the symmetric terms collected, which removes ten of the
    /// twenty-five products. Worth it: inversion is a long chain of squarings.
    @inline(__always)
    static func square(_ f: Field) -> Field {
        let d0 = f.l0 &* 2
        let d1 = f.l1 &* 2
        let d2 = f.l2 &* 2 &* 19
        let d419 = f.l4 &* 19
        let d4 = d419 &* 2

        var t0 = Wide(); var t1 = Wide(); var t2 = Wide(); var t3 = Wide(); var t4 = Wide()

        t0.addProduct(f.l0, f.l0); t0.addProduct(d4, f.l1); t0.addProduct(d2, f.l3)
        t1.addProduct(d0, f.l1); t1.addProduct(d4, f.l2); t1.addProduct(f.l3, f.l3 &* 19)
        t2.addProduct(d0, f.l2); t2.addProduct(f.l1, f.l1); t2.addProduct(d4, f.l3)
        t3.addProduct(d0, f.l3); t3.addProduct(d1, f.l2); t3.addProduct(f.l4, d419)
        t4.addProduct(d0, f.l4); t4.addProduct(d1, f.l3); t4.addProduct(f.l2, f.l2)

        return carryReduce(&t0, &t1, &t2, &t3, &t4)
    }

    /// Shared carry chain: narrow the accumulators back to 51-bit limbs,
    /// wrapping the top carry into limb 0 scaled by 19.
    @inline(__always)
    static func carryReduce(
        _ t0: inout Wide, _ t1: inout Wide, _ t2: inout Wide,
        _ t3: inout Wide, _ t4: inout Wide
    ) -> Field {
        var r0 = t0.low51
        t1.add(t0.shiftedRight51)
        var r1 = t1.low51
        t2.add(t1.shiftedRight51)
        var r2 = t2.low51
        t3.add(t2.shiftedRight51)
        let r3 = t3.low51
        t4.add(t3.shiftedRight51)
        let r4 = t4.low51
        let carry = t4.shiftedRight51.low

        r0 &+= carry &* 19
        r1 &+= r0 >> 51
        r0 &= Field.mask
        r2 &+= r1 >> 51
        r1 &= Field.mask

        return Field(r0, r1, r2, r3, r4)
    }

    /// Branch-free conditional swap — the ladder's secret-dependent step.
    ///
    /// Written without an `if` on purpose: branching on a scalar bit is the
    /// classic way a curve implementation leaks the private key through timing.
    @inline(__always)
    static func conditionalSwap(_ p: inout Field, _ q: inout Field, _ swap: UInt64) {
        let mask = ~(swap &- 1)          // swap == 1 → all ones; 0 → all zeros
        var t = mask & (p.l0 ^ q.l0); p.l0 ^= t; q.l0 ^= t
        t = mask & (p.l1 ^ q.l1); p.l1 ^= t; q.l1 ^= t
        t = mask & (p.l2 ^ q.l2); p.l2 ^= t; q.l2 ^= t
        t = mask & (p.l3 ^ q.l3); p.l3 ^= t; q.l3 ^= t
        t = mask & (p.l4 ^ q.l4); p.l4 ^= t; q.l4 ^= t
    }

    /// Inversion by Fermat: a^(p−2). The skipped squarings at 2 and 4 are the
    /// standard addition chain, not an optimisation to be tidied away.
    static func invert(_ a: Field) -> Field {
        var c = a
        for i in stride(from: 253, through: 0, by: -1) {
            c = square(c)
            if i != 2 && i != 4 { c = multiply(c, a) }
        }
        return c
    }

    // MARK: - Serialisation

    static func unpack(_ bytes: [UInt8]) -> Field {
        func load(_ offset: Int) -> UInt64 {
            var value: UInt64 = 0
            for i in 0..<8 { value |= UInt64(bytes[offset + i]) << (8 * i) }
            return value
        }
        return Field(
            load(0) & Field.mask,
            (load(6) >> 3) & Field.mask,
            (load(12) >> 6) & Field.mask,
            (load(19) >> 1) & Field.mask,
            (load(24) >> 12) & Field.mask
        )
    }

    /// Fully reduces and serialises to 32 little-endian bytes.
    ///
    /// The repeated carry rounds plus the `+19` trick bring a value that is
    /// merely *congruent* to its canonical representative — without them two
    /// equal keys could serialise differently.
    static func pack(_ n: Field) -> [UInt8] {
        var f = n

        @inline(__always)
        func carryRound() {
            f.l1 &+= f.l0 >> 51; f.l0 &= Field.mask
            f.l2 &+= f.l1 >> 51; f.l1 &= Field.mask
            f.l3 &+= f.l2 >> 51; f.l2 &= Field.mask
            f.l4 &+= f.l3 >> 51; f.l3 &= Field.mask
            f.l0 &+= 19 &* (f.l4 >> 51); f.l4 &= Field.mask
        }

        carryRound()
        carryRound()

        // Now in [0, 2^255 − 1]. Adding 19 pushes anything in
        // [2^255 − 19, 2^255 − 1] over the top so the final carry removes it,
        // which is what forces the canonical representative.
        f.l0 &+= 19
        carryRound()

        f.l0 &+= 0x8_0000_0000_0000 - 19
        f.l1 &+= 0x8_0000_0000_0000 - 1
        f.l2 &+= 0x8_0000_0000_0000 - 1
        f.l3 &+= 0x8_0000_0000_0000 - 1
        f.l4 &+= 0x8_0000_0000_0000 - 1

        f.l1 &+= f.l0 >> 51; f.l0 &= Field.mask
        f.l2 &+= f.l1 >> 51; f.l1 &= Field.mask
        f.l3 &+= f.l2 >> 51; f.l2 &= Field.mask
        f.l4 &+= f.l3 >> 51; f.l3 &= Field.mask
        f.l4 &= Field.mask

        // Bit-cursor serialisation. Called a handful of times per signature, so
        // clarity beats cleverness here.
        let limbs = [f.l0, f.l1, f.l2, f.l3, f.l4]
        var out = [UInt8](repeating: 0, count: 32)
        for byteIndex in 0..<32 {
            var value: UInt64 = 0
            for bit in 0..<8 {
                let position = byteIndex * 8 + bit
                let limb = position / 51
                guard limb < 5 else { break }
                value |= ((limbs[limb] >> (position % 51)) & 1) << bit
            }
            out[byteIndex] = UInt8(truncatingIfNeeded: value)
        }
        return out
    }

    /// Low bit of x, which becomes the sign bit of a packed point.
    static func parity(_ a: Field) -> UInt8 { pack(a)[0] & 1 }

    // MARK: - Curve constants
    //
    // Given as their canonical encodings and expanded at load, rather than
    // hand-transcribed into radix 2^51. These bytes were produced by packing the
    // constants from the TweetNaCl implementation this replaced, so a
    // transcription slip cannot survive.

    /// Base point x.
    static let baseX = unpack(
        hexBytes("1ad5258f602d56c9b2a7259560c72c695cdcd6fd31e2a4c0fe536ecdd3366921")
    )
    /// Base point y, 4/5.
    static let baseY = unpack(
        hexBytes("5866666666666666666666666666666666666666666666666666666666666666")
    )
    /// 2·d, the twisted-Edwards curve constant.
    static let d2 = unpack(
        hexBytes("59f1b226949bd6eb56b183829a14e00030d1f3eef2808e19e7fcdf56dcd90624")
    )

    static func hexBytes(_ text: String) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            out.append(UInt8(text[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    /// The group order L = 2^252 + 27742317777372353535851937790883648493,
    /// little-endian by byte.
    static let groupOrder: [Int64] = [
        0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58,
        0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0x10,
    ]

    // MARK: - Group arithmetic

    /// A point in extended twisted Edwards coordinates.
    struct Point {
        var x: Field, y: Field, z: Field, t: Field
    }

    static let identity = Point(x: .zero, y: .one, z: .one, t: .zero)
    static var basePoint: Point {
        Point(x: baseX, y: baseY, z: .one, t: multiply(baseX, baseY))
    }

    @inline(__always)
    static func addPoints(_ p: Point, _ q: Point) -> Point {
        let a = multiply(subtract(p.y, p.x), subtract(q.y, q.x))
        let b = multiply(add(p.x, p.y), add(q.x, q.y))
        let c = multiply(multiply(p.t, q.t), d2)
        let dd = { let v = multiply(p.z, q.z); return add(v, v) }()

        let e = subtract(b, a)
        let f = subtract(dd, c)
        let g = add(dd, c)
        let h = add(b, a)

        return Point(
            x: multiply(e, f),
            y: multiply(h, g),
            z: multiply(g, f),
            t: multiply(e, h)
        )
    }

    @inline(__always)
    static func conditionalSwapPoints(_ p: inout Point, _ q: inout Point, _ swap: UInt64) {
        conditionalSwap(&p.x, &q.x, swap)
        conditionalSwap(&p.y, &q.y, swap)
        conditionalSwap(&p.z, &q.z, swap)
        conditionalSwap(&p.t, &q.t, swap)
    }

    /// Serialises a point: y with x's parity in the top bit.
    static func packPoint(_ p: Point) -> [UInt8] {
        let zInverse = invert(p.z)
        let x = multiply(p.x, zInverse)
        let y = multiply(p.y, zInverse)
        var out = pack(y)
        out[31] ^= parity(x) << 7
        return out
    }

    /// Montgomery ladder. Every iteration does the same work regardless of the
    /// bit, with the branch replaced by a conditional swap.
    static func scalarMultiply(_ q: Point, by scalar: [UInt8]) -> Point {
        var p = identity
        var q = q
        for i in stride(from: 255, through: 0, by: -1) {
            let bit = UInt64((scalar[i / 8] >> UInt8(i & 7)) & 1)
            conditionalSwapPoints(&p, &q, bit)
            q = addPoints(q, p)
            p = addPoints(p, p)
            conditionalSwapPoints(&p, &q, bit)
        }
        return p
    }

    // MARK: - Fixed-base multiplication

    /// Constant-time conditional copy: `dest = mask == 0 ? dest : source`.
    @inline(__always)
    static func conditionalMove(_ dest: inout Field, _ source: Field, _ mask: UInt64) {
        dest.l0 ^= mask & (dest.l0 ^ source.l0)
        dest.l1 ^= mask & (dest.l1 ^ source.l1)
        dest.l2 ^= mask & (dest.l2 ^ source.l2)
        dest.l3 ^= mask & (dest.l3 ^ source.l3)
        dest.l4 ^= mask & (dest.l4 ^ source.l4)
    }

    @inline(__always)
    static func conditionalMovePoint(_ dest: inout Point, _ source: Point, _ mask: UInt64) {
        conditionalMove(&dest.x, source.x, mask)
        conditionalMove(&dest.y, source.y, mask)
        conditionalMove(&dest.z, source.z, mask)
        conditionalMove(&dest.t, source.t, mask)
    }

    /// All-ones when `a == b`, all-zeros otherwise — no branch.
    @inline(__always)
    static func equalityMask(_ a: UInt8, _ b: UInt8) -> UInt64 {
        let difference = UInt64(a ^ b)
        let isZero = ((difference &- 1) >> 63) & 1     // 1 iff difference == 0
        return ~(isZero &- 1)
    }

    /// Negation in extended coordinates: (X, Y, Z, T) → (−X, Y, Z, −T).
    @inline(__always)
    static func negate(_ p: Point) -> Point {
        Point(x: subtract(.zero, p.x), y: p.y, z: p.z, t: subtract(.zero, p.t))
    }

    /// Precomputed odd-signed-digit table: `baseTable[i][j] == (j + 1) · 16^i · B`.
    ///
    /// 64 windows × 8 multiples × 4 field elements ≈ 80 KB, built once on first
    /// use. It is *computed* from `basePoint` with the already-verified ladder
    /// rather than transcribed from published constants — a table this size is
    /// exactly where a typo hides, and the mistyped 2^51 literal earlier in this
    /// file is the argument for not hand-entering large constants.
    ///
    /// `static let` gives lazy, once-only, thread-safe initialisation.
    static let baseTable: [[Point]] = {
        var table: [[Point]] = []
        table.reserveCapacity(64)
        var windowBase = basePoint                      // 16^i · B
        for _ in 0..<64 {
            var row: [Point] = []
            row.reserveCapacity(8)
            var multiple = windowBase
            for _ in 0..<8 {
                row.append(multiple)                    // (j + 1) · 16^i · B
                multiple = addPoints(multiple, windowBase)
            }
            table.append(row)
            for _ in 0..<4 { windowBase = addPoints(windowBase, windowBase) }
        }
        return table
    }()

    /// Recodes a scalar into 64 signed nibbles in −8...8.
    ///
    /// Signed digits are what let the table hold only multiples 1…8 instead of
    /// 1…15: a digit of, say, 12 becomes −4 with a carry into the next window.
    ///
    /// Requires `scalar[31] <= 127`, and **enforces it**.
    ///
    /// Above that the final carry pushes the top digit to 16, which no table
    /// entry matches, so that window contributes nothing and the answer is
    /// silently wrong — verified: it diverges from the ladder with no error
    /// raised. A wrong signature is worse than a crash, and this is an internal
    /// invariant rather than user input, so it traps.
    ///
    /// Both callers satisfy it: `clamp` clears bit 255, and a scalar reduced
    /// mod L is below 2^253. `ScalarRangeTests` pins both.
    static func signedDigits(_ scalar: [UInt8]) -> [Int8] {
        precondition(
            scalar.count == 32 && scalar[31] <= 127,
            "ed25519: signed-digit recoding needs a 32-byte scalar below 2^255"
        )
        var digits = [Int8](repeating: 0, count: 64)
        for i in 0..<32 {
            digits[2 * i] = Int8(scalar[i] & 15)
            digits[2 * i + 1] = Int8((scalar[i] >> 4) & 15)
        }
        var carry: Int8 = 0
        for i in 0..<63 {
            digits[i] += carry
            carry = (digits[i] + 8) >> 4
            digits[i] -= carry << 4
        }
        digits[63] += carry
        return digits
    }

    /// Multiplies the base point — note **no clamping** is applied here. The
    /// caller decides, which is exactly what `client_ed25519` requires: the
    /// secret scalar is clamped, the nonce is not.
    ///
    /// Uses the precomputed table: 64 additions rather than the ladder's 512.
    /// Both scalar multiplications in a signature are of the base point, so this
    /// applies to the whole operation.
    ///
    /// **The table lookup is constant-time and must stay that way.** Indexing
    /// `baseTable[i][digit]` directly would be far faster to write and would
    /// leak the secret scalar through cache-timing — the standard attack on
    /// windowed fixed-base multiplication. Instead every one of the eight
    /// candidates is touched on every window and selected with a mask.
    static func scalarMultiplyBasePoint(_ scalar: [UInt8]) -> Point {
        let digits = signedDigits(scalar)
        var accumulator = identity

        for window in 0..<64 {
            // Branchless sign and magnitude. `digit < 0 ? -digit : digit` would
            // be a source-level branch on the secret scalar — the exact thing
            // the masked selection below exists to avoid, so it cannot be left
            // in the line that computes the index.
            let digit = digits[window]
            let signMask = digit >> 7                                 // -1 if negative, else 0
            let isNegative = UInt64(bitPattern: Int64(signMask))       // all ones if negative
            let magnitude = UInt8(bitPattern: (digit ^ signMask) &- signMask)

            // Scan all eight entries; a magnitude of 0 leaves the identity.
            var selected = identity
            let row = baseTable[window]
            for candidate in 0..<8 {
                conditionalMovePoint(
                    &selected, row[candidate], equalityMask(magnitude, UInt8(candidate + 1))
                )
            }

            var negated = negate(selected)
            conditionalMovePoint(&negated, selected, ~isNegative)
            accumulator = addPoints(accumulator, negated)
        }
        return accumulator
    }

    static func scalarMultiplyBase(_ scalar: [UInt8]) -> [UInt8] {
        packPoint(scalarMultiplyBasePoint(scalar))
    }

    /// The unaccelerated path, retained as the differential oracle for the
    /// table-driven one above.
    static func scalarMultiplyBaseViaLadder(_ scalar: [UInt8]) -> [UInt8] {
        packPoint(scalarMultiply(basePoint, by: scalar))
    }

    // MARK: - Scalar arithmetic mod L

    /// Reduces a 512-bit little-endian value mod L, returning 32 bytes.
    static func reduceScalar(_ input: [UInt8]) -> [UInt8] {
        var x = [Int64](repeating: 0, count: 64)
        for i in 0..<min(64, input.count) { x[i] = Int64(input[i]) }
        return modL(&x)
    }

    /// `(a * b + c) mod L` — the one combined operation signing needs.
    static func multiplyAdd(_ a: [UInt8], _ b: [UInt8], _ c: [UInt8]) -> [UInt8] {
        var x = [Int64](repeating: 0, count: 64)
        for i in 0..<32 { x[i] = Int64(c[i]) }
        for i in 0..<32 {
            for j in 0..<32 {
                x[i + j] += Int64(a[i]) * Int64(b[j])
            }
        }
        return modL(&x)
    }

    /// Barrett-style reduction mod L, folding the high limbs down one at a time.
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
        for j in 0..<32 {
            x[j] -= carryValue * groupOrder[j]
        }

        var out = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 {
            x[i + 1] += x[i] >> 8
            out[i] = UInt8(truncatingIfNeeded: x[i])
        }
        return out
    }
}

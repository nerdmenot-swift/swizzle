import Testing

@testable import SwizzleConnectionPool

/// The two hand-rolled sequences every pool action is carried in.
///
/// ## Why these deserve tests of their own
///
/// `TinyFastSequence` and `Max2Sequence` exist to avoid a heap allocation for
/// the common case of nought, one, or two elements — which the pool hits on
/// almost every transition, since most actions carry a single connection or a
/// single timer. The cost of that optimisation is that each holds **four and
/// three separate representations** respectively, with distinct code for each,
/// and switches between them as elements are appended.
///
/// That is the shape an off-by-one hides in, and a wrong answer here is not a
/// local bug: these are what `Action` is made of, so a dropped element is a
/// connection never closed or a timer never cancelled. Neither type had a test.
///
/// Every case is exercised at each boundary — 0, 1, 2, 3 — because the
/// boundaries are exactly where one representation becomes another.
@Suite("Pool sequences")
struct PoolSequenceTests {

    // MARK: - TinyFastSequence

    /// Built from a collection, at each size where the representation changes.
    @Test("a tiny sequence built from a collection has the right count and contents")
    func tinyFromCollection() {
        for size in 0...5 {
            let source = Array(0..<size)
            let sequence = TinyFastSequence(source)
            #expect(sequence.count == size, "count for \(size)")
            #expect(sequence.isEmpty == (size == 0), "isEmpty for \(size)")
            #expect(sequence.first == source.first, "first for \(size)")
            #expect(Array(sequence) == source, "iteration for \(size)")
        }
    }

    /// The two dedicated initialisers, which take different paths from the
    /// collection one above.
    @Test("the empty and single-element initialisers agree with the collection one")
    func tinyDedicatedInitialisers() {
        let empty = TinyFastSequence<Int>()
        #expect(empty.count == 0)
        #expect(empty.isEmpty)
        #expect(empty.first == nil)
        #expect(Array(empty).isEmpty)

        let single = TinyFastSequence(element: 7)
        #expect(single.count == 1)
        #expect(!single.isEmpty)
        #expect(single.first == 7)
        #expect(Array(single) == [7])
    }

    /// **Appending is where one representation becomes the next**, and where a
    /// dropped element would mean a connection the pool forgets to close.
    @Test("appending grows through every representation without losing anything")
    func tinyAppendCrossesRepresentations() {
        var sequence = TinyFastSequence<Int>()
        var expected: [Int] = []

        for value in 0..<8 {
            sequence.append(value)
            expected.append(value)
            #expect(sequence.count == expected.count, "after appending \(value)")
            #expect(Array(sequence) == expected, "after appending \(value)")
            #expect(sequence.first == expected.first, "after appending \(value)")
            #expect(!sequence.isEmpty)
        }
    }

    /// Appending onto a sequence that was *built* from a collection, rather
    /// than grown from empty — a different starting representation each time.
    @Test("appending onto each starting representation keeps every element")
    func tinyAppendOntoEachRepresentation() {
        for size in 0...4 {
            var sequence = TinyFastSequence(Array(0..<size))
            var expected = Array(0..<size)
            for extra in 100..<103 {
                sequence.append(extra)
                expected.append(extra)
            }
            #expect(Array(sequence) == expected, "starting from \(size)")
        }
    }

    /// `reserveCapacity` is a hint and must not change what the sequence holds.
    /// It has a branch per representation, and the `.n` case deliberately
    /// clears `base` first to avoid a copy-on-write — the one place it mutates
    /// something other than a capacity.
    @Test("reserving capacity changes nothing observable")
    func tinyReserveCapacity() {
        for size in 0...4 {
            var sequence = TinyFastSequence(Array(0..<size))
            let before = Array(sequence)
            sequence.reserveCapacity(64)
            #expect(Array(sequence) == before, "contents for \(size)")
            #expect(sequence.count == before.count, "count for \(size)")

            // And it still appends correctly afterwards, which is what would
            // break if the copy-on-write dance dropped the array.
            sequence.append(999)
            #expect(Array(sequence) == before + [999], "append after reserve, \(size)")
        }
    }

    /// Built from a `Max2Sequence`, which is its own initialiser and the way
    /// the state machine converts timer lists into action payloads.
    @Test("a tiny sequence built from a Max2Sequence carries the same elements")
    func tinyFromMax2() {
        #expect(Array(TinyFastSequence(Max2Sequence<Int>())).isEmpty)
        #expect(Array(TinyFastSequence(Max2Sequence(1))) == [1])
        #expect(Array(TinyFastSequence(Max2Sequence(1, 2))) == [1, 2])
    }

    // MARK: - Max2Sequence

    /// Its whole contract is in the name: it holds at most two, and the second
    /// cannot exist without the first.
    @Test("a Max2Sequence reports what it holds at each size")
    func max2Counts() {
        let empty = Max2Sequence<Int>()
        #expect(empty.count == 0)
        #expect(empty.isEmpty)
        #expect(Array(empty).isEmpty)

        let one = Max2Sequence(1)
        #expect(one.count == 1)
        #expect(!one.isEmpty)
        #expect(Array(one) == [1])

        let two = Max2Sequence(1, 2)
        #expect(two.count == 2)
        #expect(Array(two) == [1, 2])
    }

    /// A second element with no first is the one construction that would make
    /// `count` and iteration disagree, so it is pinned rather than assumed.
    @Test("a second element with no first is not a sequence of one hole")
    func max2SecondWithoutFirst() {
        let odd = Max2Sequence(nil, 2)
        #expect(odd.count == Array(odd).count, "count and iteration must agree")
    }

    @Test("appending fills the first slot, then the second")
    func max2Append() {
        var sequence = Max2Sequence<Int>()
        sequence.append(1)
        #expect(Array(sequence) == [1])
        sequence.append(2)
        #expect(Array(sequence) == [1, 2])
        #expect(sequence.count == 2)
    }

    @Test("mapping preserves the size and transforms every element")
    func max2Map() {
        #expect(Array(Max2Sequence<Int>().map { $0 * 2 }).isEmpty)
        #expect(Array(Max2Sequence(1).map { $0 * 2 }) == [2])
        #expect(Array(Max2Sequence(1, 2).map { $0 * 2 }) == [2, 4])
    }

    @Test("the array literal form matches the initialiser")
    func max2ArrayLiteral() {
        let empty: Max2Sequence<Int> = []
        #expect(Array(empty).isEmpty)
        let one: Max2Sequence<Int> = [1]
        #expect(Array(one) == [1])
        let two: Max2Sequence<Int> = [1, 2]
        #expect(Array(two) == [1, 2])
    }

    /// Iterating twice yields the same thing both times — an iterator that
    /// mutated shared state would not, and the pool iterates action payloads
    /// more than once in places.
    @Test("iterating twice yields the same elements")
    func repeatedIteration() {
        let tiny = TinyFastSequence([1, 2, 3])
        #expect(Array(tiny) == Array(tiny))

        let max2 = Max2Sequence(1, 2)
        #expect(Array(max2) == Array(max2))
    }

    // MARK: - The general representation

    /// **Three or more elements from a non-array collection.** `TinyFastSequence`
    /// stores nothing, one, or two elements inline and falls back to an array
    /// beyond that — and the fallback has two paths: an `Array` source is
    /// adopted as-is, anything else is copied. Only the first was exercised,
    /// because every caller in the module passes an array.
    ///
    /// A `Set` is a fair stand-in for the other path: no integer indices, no
    /// contiguous storage, and an order of its own.
    @Test("three or more elements from a non-array collection are all carried")
    func generalRepresentationFromNonArray() {
        let source: Set<Int> = [10, 20, 30, 40]
        let sequence = TinyFastSequence(source)

        #expect(sequence.count == 4)
        #expect(Set(sequence) == source, "every element survived the copy")
    }

    /// A range is the other shape worth checking: a collection with no storage
    /// at all behind it.
    @Test("three or more elements from a computed collection are all carried")
    func generalRepresentationFromRange() {
        let sequence = TinyFastSequence(1..<6)
        #expect(sequence.count == 5)
        #expect(Array(sequence) == [1, 2, 3, 4, 5])
    }

    /// An array source takes the other branch — adopted rather than copied —
    /// and must agree element for element with the copying one.
    @Test("an array source and a copied source agree")
    func generalRepresentationAgreesAcrossSources() {
        let elements = [1, 2, 3, 4, 5]
        #expect(Array(TinyFastSequence(elements)) == Array(TinyFastSequence(elements[...])))
    }

    /// The array-literal form has the same size split, and its own general
    /// branch. Three elements is the smallest literal that reaches it.
    @Test("an array literal of three or more elements carries them all")
    func generalRepresentationFromLiteral() {
        let sequence: TinyFastSequence<Int> = [1, 2, 3, 4]
        #expect(sequence.count == 4)
        #expect(Array(sequence) == [1, 2, 3, 4])
        #expect(
            Array(sequence) == Array(TinyFastSequence([1, 2, 3, 4])),
            "the literal and the initialiser agree past the inline sizes too"
        )
    }
}

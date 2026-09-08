import Testing
import NIOCore

@testable import SwizzlePostgresDriver

/// Element counts that the buffer cannot possibly back.
///
/// ## The class, not the crash
///
/// Several decoders in this driver read a count and then reserve capacity for
/// it. Three of them were given buffer-derived bounds when a 32 GB allocation
/// in the geometry decoders aborted a Linux job. Three others were not, because
/// they had not crashed — they capped the count at a round million instead,
/// which is not a bound at all when the message is five bytes long.
///
/// A million `String`s is roughly sixteen megabytes reserved from a five-byte
/// header. That is not a process death, which is exactly why it survived a pass
/// that was looking for process deaths. It is still an amplification a peer
/// chooses, and it multiplies by the number of values in a result set.
///
/// ## What these tests do and do not establish
///
/// They pin that such a header is **rejected**. They do **not** verify the
/// bound, and cannot: the decoder returns nil either way. With the old constant
/// it reserved sixteen megabytes and then failed on the first read; with the
/// buffer-derived bound it fails before reserving. The return value is
/// identical, so no assertion here distinguishes them — reverting the fix
/// leaves all five green, which is how I found that out.
///
/// The allocation bound is therefore a hardening change with no test behind it,
/// and it is recorded that way in `docs/verification.md` rather than counted as
/// covered. What would catch a regression is the same thing that caught the
/// 32 GB one: a Linux job aborting on a reservation macOS would have absorbed —
/// which works at gigabytes and not at megabytes.
///
/// The floor used for each element is what the format guarantees: a tsvector
/// lexeme cannot be under three bytes, a tsquery item under one.
@Suite("Postgres count rejection")
struct PostgresCountBoundsTests {

    static func buffer(_ bytes: [UInt8]) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        return buffer
    }

    /// A tsvector header claiming a million lexemes with nothing behind it.
    @Test("a tsvector count larger than the buffer allows is rejected")
    func tsVectorCountRejected() {
        var buffer = Self.buffer([0x00, 0x0F, 0x42, 0x3F])  // 999_999 lexemes, no body
        #expect(PostgresExtendedTypes.decodeTSVector(&buffer) == nil)
    }

    /// A tsquery header doing the same.
    @Test("a tsquery count larger than the buffer allows is rejected")
    func tsQueryCountRejected() {
        var buffer = Self.buffer([0x00, 0x0F, 0x42, 0x3F])
        #expect(PostgresExtendedTypes.decodeTSQuery(&buffer) == nil)
    }

    /// A lexeme claiming 65535 positions with none of them present.
    @Test("a tsvector position count larger than the buffer allows is rejected")
    func tsVectorPositionCountRejected() {
        // One lexeme: the word "a", then a position count of 65535 and no
        // positions at all.
        var buffer = Self.buffer([
            0x00, 0x00, 0x00, 0x01,   // one lexeme
            0x61, 0x00,               // "a"
            0xFF, 0xFF,               // 65535 positions
        ])
        #expect(PostgresExtendedTypes.decodeTSVector(&buffer) == nil)
    }

    /// **The control.** A real tsvector still decodes, so the bounds did not
    /// simply reject the format.
    @Test("an ordinary tsvector still decodes")
    func ordinaryTSVectorDecodes() {
        var buffer = Self.buffer([
            0x00, 0x00, 0x00, 0x02,   // two lexemes
            0x63, 0x61, 0x74, 0x00,   // "cat"
            0x00, 0x00,               // no positions
            0x64, 0x6F, 0x67, 0x00,   // "dog"
            0x00, 0x00,               // no positions
        ])
        guard case .text(let rendered)? = PostgresExtendedTypes.decodeTSVector(&buffer)
        else {
            Issue.record("a valid tsvector was rejected")
            return
        }
        #expect(rendered == "'cat' 'dog'", "got \(rendered)")
    }

    /// And one carrying positions, which is the path the position bound sits on.
    @Test("a tsvector with positions still decodes")
    func tsVectorWithPositionsDecodes() {
        var buffer = Self.buffer([
            0x00, 0x00, 0x00, 0x01,   // one lexeme
            0x63, 0x61, 0x74, 0x00,   // "cat"
            0x00, 0x01,               // one position
            0x00, 0x01,               // position 1, weight D (omitted)
        ])
        guard case .text(let rendered)? = PostgresExtendedTypes.decodeTSVector(&buffer)
        else {
            Issue.record("a valid tsvector with positions was rejected")
            return
        }
        #expect(rendered == "'cat':1", "got \(rendered)")
    }
}

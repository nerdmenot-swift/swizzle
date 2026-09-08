import Foundation
import NIOCore
import Testing

@testable import SwizzleMySQL

/// Declared uncompressed sizes that the compressed payload cannot justify.
///
/// ## The two compression paths, and why only one was bounded
///
/// MySQL compresses in two places, and they were not audited together. The
/// connection-level path checks the inflated size against `maxAllowedPacket`
/// before doing anything. The **binlog** path does not: `decompressTail` reads a
/// length field of up to four bytes straight out of the event and hands it to
/// the decompressor as the buffer size.
///
/// The buffer is allocated from the *declared* count and filled afterwards, so
/// zlib rejecting the data does not help — the allocation has already happened.
/// Ten bytes of payload declaring `0xFFFFFFFF` asks for 4.29 GB before anything
/// looks at the bytes. Confirmed at a smaller size first: a three-byte length
/// field claiming 16 MB from ten bytes of payload allocated and then failed with
/// `zlib uncompress returned -3`.
///
/// ## Why 1032
///
/// The bound is DEFLATE's theoretical maximum expansion, reached only by a
/// stream of maximally back-referenced blocks. It is a property of the format
/// rather than a number someone chose, which matters: a policy limit has to be
/// argued about and tuned, while a format ceiling cannot reject anything a real
/// compressor could have produced.
@Suite("MySQL compression bounds")
struct CompressionBoundsTests {

    /// Asserts the tail is rejected **by the bound**, not by zlib afterwards.
    ///
    /// The distinction is the entire point and it is invisible to
    /// `#expect(throws: MySQLProtocolError.self)`: zlib refusing the data raises
    /// the same error type, so that assertion passes whether or not the buffer
    /// was allocated first. Two tests here were written that way and passed with
    /// the bound removed.
    static func expectRejectedBeforeAllocating(
        marker: UInt8, lengthBytes: [UInt8], payload: [UInt8],
        _ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        var buffer = tail(marker: marker, lengthBytes: lengthBytes, payload: payload)
        do {
            _ = try MySQLBinlogEventDecoder.decompressTail(&buffer)
            Issue.record("\(comment): an impossible expansion was accepted", sourceLocation: sourceLocation)
        } catch let error as MySQLProtocolError {
            guard case .malformedPacket = error else {
                Issue.record(
                    "\(comment): rejected by \(error), which is zlib refusing the data after the buffer was allocated",
                    sourceLocation: sourceLocation
                )
                return
            }
        } catch {
            Issue.record("\(comment): unexpected error \(error)", sourceLocation: sourceLocation)
        }
    }

    static func tail(marker: UInt8, lengthBytes: [UInt8], payload: [UInt8]) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeInteger(marker)
        buffer.writeBytes(lengthBytes)
        buffer.writeBytes(payload)
        return buffer
    }

    /// **The bomb.** A three-byte length field claiming 16 MB behind ten bytes.
    @Test("a binlog tail claiming more than DEFLATE can produce is rejected")
    func binlogTailRejectsImpossibleExpansion() {
        Self.expectRejectedBeforeAllocating(
            marker: 0x83, lengthBytes: [0xFF, 0xFF, 0xFF],
            payload: [UInt8](repeating: 0, count: 10),
            "16 MB from ten bytes"
        )
    }

    /// The rejection must happen **before** the allocation, which is the whole
    /// point — so the error has to be the malformed-packet one raised by the
    /// bound, not the compression failure zlib raises afterwards. Getting
    /// `compressionFailed` here would mean the 16 MB was allocated first.
    @Test("the rejection happens before the allocation, not after zlib fails")
    func rejectionPrecedesAllocation() {
        var buffer = Self.tail(
            marker: 0x83, lengthBytes: [0xFF, 0xFF, 0xFF],
            payload: [UInt8](repeating: 0, count: 10)
        )
        do {
            _ = try MySQLBinlogEventDecoder.decompressTail(&buffer)
            Issue.record("an impossible expansion was accepted")
        } catch let error as MySQLProtocolError {
            guard case .malformedPacket = error else {
                Issue.record("rejected by \(error) — that is zlib refusing the data after the buffer was allocated")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    /// The same at the largest field width, which is where the number gets
    /// genuinely dangerous rather than merely wasteful.
    @Test("a four-byte length field claiming gigabytes is rejected")
    func fourByteLengthRejected() {
        Self.expectRejectedBeforeAllocating(
            marker: 0x84, lengthBytes: [0xFF, 0xFF, 0xFF, 0xFF],
            payload: [UInt8](repeating: 0, count: 10),
            "4.29 GB from ten bytes"
        )
    }

    /// **The control.** Real compressed data still inflates. A bound that
    /// rejected everything would satisfy every test above.
    @Test("genuinely compressed data still decompresses")
    func realDataStillDecompresses() throws {
        // Highly compressible, but nowhere near the format ceiling.
        let original = [UInt8](repeating: 0x41, count: 4096)
        let compressed = try MySQLCompression.compress(original)
        let restored = try MySQLCompression.decompress(
            compressed, expectedCount: original.count
        )
        #expect(restored == original)
        #expect(
            compressed.count * 1032 >= original.count,
            "the control itself exceeds the bound, so it proves nothing"
        )
    }

    /// And a payload that compresses hard — closer to the ceiling — must not be
    /// caught by the bound, or the guard would reject legitimate traffic.
    @Test("a highly compressible payload is not rejected by the bound")
    func highlyCompressiblePayloadAccepted() throws {
        let original = [UInt8](repeating: 0, count: 200_000)
        let compressed = try MySQLCompression.compress(original)
        let restored = try MySQLCompression.decompress(
            compressed, expectedCount: original.count
        )
        #expect(restored.count == original.count)
        #expect(
            compressed.count * 1032 >= original.count,
            "this payload exceeds the format ceiling, so it cannot show the bound admits real data"
        )
    }
}

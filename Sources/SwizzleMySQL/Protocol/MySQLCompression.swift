import CZlib
import CZstd
import NIOCore

/// zlib compression for the compressed wire protocol.
///
/// MySQL frames each chunk independently in zlib format (RFC 1950), so the
/// one-shot `compress2`/`uncompress` entry points are a complete fit — there is
/// no compression state carried between packets. That is worth stating because
/// it is *not* how most compressed protocols work, and it is why a connection
/// can be decompressed packet-by-packet without a persistent inflate stream.
public enum MySQLCompression {

    /// Below this, compressing costs more than it saves and the payload is sent
    /// stored. 50 follows `rust-mysql-common`'s `MIN_COMPRESS_LENGTH`;
    /// go-sql-driver uses 150. Either is a client-side heuristic — the server
    /// accepts a stored payload of any size — so the primary reference wins.
    public static let minimumCompressLength = 50

    /// zlib's default (6). The reference exposes a level; we follow suit but do
    /// not chase go-sql-driver's 2, since a database client is far more often
    /// bandwidth-bound than CPU-bound on this path.
    public static let defaultLevel: Int32 = 6

    public static func compress(_ source: [UInt8], level: Int32 = defaultLevel) throws -> [UInt8] {
        guard !source.isEmpty else { return [] }

        var destinationCount = uLongf(compressBound(uLong(source.count)))
        var destination = [UInt8](repeating: 0, count: Int(destinationCount))

        let status = destination.withUnsafeMutableBufferPointer { out in
            source.withUnsafeBufferPointer { input in
                compress2(
                    out.baseAddress, &destinationCount,
                    input.baseAddress, uLong(input.count),
                    level
                )
            }
        }
        guard status == Z_OK else {
            throw MySQLProtocolError.compressionFailed("zlib compress2 returned \(status)")
        }
        return Array(destination[0..<Int(destinationCount)])
    }

    // MARK: - Zstandard

    /// zstd's own default. MySQL's `zstd_compression_level` ranges 1–22 and
    /// also defaults to 3.
    public static let defaultZstdLevel: Int32 = 3

    public static func compressZstd(
        _ source: [UInt8], level: Int32 = defaultZstdLevel
    ) throws -> [UInt8] {
        guard !source.isEmpty else { return [] }

        var destination = [UInt8](repeating: 0, count: swizzle_zstd_compress_bound(source.count))
        let written = destination.withUnsafeMutableBytes { out in
            source.withUnsafeBytes { input in
                swizzle_zstd_compress(
                    out.baseAddress, out.count, input.baseAddress, input.count, level
                )
            }
        }
        guard written > 0 else {
            throw MySQLProtocolError.compressionFailed("zstd compression failed")
        }
        return Array(destination[0..<written])
    }

    /// Decompresses a zstd frame.
    ///
    /// `expectedCount` comes from the packet header. It is checked against the
    /// frame's own recorded content size where the frame carries one — a frame
    /// that disagrees with its envelope is corrupt or hostile, and sizing the
    /// buffer from the envelope alone would let a frame claiming a small size
    /// expand into a much larger one.
    public static func decompressZstd(_ source: [UInt8], expectedCount: Int) throws -> [UInt8] {
        guard expectedCount > 0 else { return [] }

        let declared = source.withUnsafeBytes { input in
            swizzle_zstd_decompressed_size(input.baseAddress, input.count)
        }
        if declared != swizzle_zstd_unknown_size(), declared != expectedCount {
            throw MySQLProtocolError.malformedPacket(
                "zstd frame declares \(declared) bytes, packet header says \(expectedCount)"
            )
        }

        var destination = [UInt8](repeating: 0, count: expectedCount)
        let written = destination.withUnsafeMutableBytes { out in
            source.withUnsafeBytes { input in
                swizzle_zstd_decompress(
                    out.baseAddress, out.count, input.baseAddress, input.count
                )
            }
        }
        guard written == expectedCount else {
            throw MySQLProtocolError.malformedPacket(
                "zstd inflated to \(written) bytes, expected \(expectedCount)"
            )
        }
        return destination
    }

    /// `expectedCount` comes from the packet header, so the output buffer is
    /// sized exactly rather than grown. A payload that inflates to a different
    /// length than advertised is a corrupt or hostile packet, not something to
    /// accommodate — hence the equality check.
    public static func decompress(_ source: [UInt8], expectedCount: Int) throws -> [UInt8] {
        guard expectedCount > 0 else { return [] }

        var destinationCount = uLongf(expectedCount)
        var destination = [UInt8](repeating: 0, count: expectedCount)

        let status = destination.withUnsafeMutableBufferPointer { out in
            source.withUnsafeBufferPointer { input in
                uncompress(
                    out.baseAddress, &destinationCount,
                    input.baseAddress, uLong(input.count)
                )
            }
        }
        guard status == Z_OK else {
            throw MySQLProtocolError.compressionFailed("zlib uncompress returned \(status)")
        }
        guard Int(destinationCount) == expectedCount else {
            throw MySQLProtocolError.malformedPacket(
                "compressed packet claimed \(expectedCount) bytes, inflated to \(destinationCount)"
            )
        }
        return destination
    }
}

/// The 7-byte compressed-packet header.
///
/// ```
/// 3 bytes  compressed payload length
/// 1 byte   compression sequence id   (a counter of its own, not the packet one)
/// 3 bytes  uncompressed length       (0 ⇒ the payload is stored, not deflated)
/// ```
///
/// The two traps here are that the sequence id is a *separate* counter from the
/// plain packet sequence, and that a zero uncompressed length means "stored"
/// rather than "empty".
public struct MySQLCompressedPacketHeader: Sendable, Equatable {
    public static let byteCount = 7

    public var compressedLength: Int
    public var sequenceID: UInt8
    /// Zero means the payload was not worth deflating and is stored verbatim.
    public var uncompressedLength: Int

    public var isStored: Bool { uncompressedLength == 0 }

    public init(compressedLength: Int, sequenceID: UInt8, uncompressedLength: Int) {
        self.compressedLength = compressedLength
        self.sequenceID = sequenceID
        self.uncompressedLength = uncompressedLength
    }

    public static func parse(_ buffer: inout ByteBuffer) -> MySQLCompressedPacketHeader? {
        guard buffer.readableBytes >= byteCount,
              let low = buffer.getInteger(at: buffer.readerIndex, endianness: .little, as: UInt16.self),
              let high = buffer.getInteger(at: buffer.readerIndex + 2, as: UInt8.self),
              let sequence = buffer.getInteger(at: buffer.readerIndex + 3, as: UInt8.self),
              let uncompressedLow = buffer.getInteger(
                  at: buffer.readerIndex + 4, endianness: .little, as: UInt16.self
              ),
              let uncompressedHigh = buffer.getInteger(at: buffer.readerIndex + 6, as: UInt8.self)
        else { return nil }

        return MySQLCompressedPacketHeader(
            compressedLength: Int(low) | (Int(high) << 16),
            sequenceID: sequence,
            uncompressedLength: Int(uncompressedLow) | (Int(uncompressedHigh) << 16)
        )
    }

    public func serialize(into buffer: inout ByteBuffer) {
        buffer.writeInteger(UInt16(compressedLength & 0xFFFF), endianness: .little)
        buffer.writeInteger(UInt8((compressedLength >> 16) & 0xFF))
        buffer.writeInteger(sequenceID)
        buffer.writeInteger(UInt16(uncompressedLength & 0xFFFF), endianness: .little)
        buffer.writeInteger(UInt8((uncompressedLength >> 16) & 0xFF))
    }
}

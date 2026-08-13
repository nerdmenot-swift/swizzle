#ifndef SWIZZLE_ZSTD_H
#define SWIZZLE_ZSTD_H

#include <stddef.h>

/*
 * Zstandard, vendored (BSD — see ZSTD-LICENSE).
 *
 * A narrow surface rather than re-exporting `zstd.h`: Swift sees four
 * functions, and zstd's macros and opaque types never enter the module. The
 * vendored tree can then be updated without anything downstream noticing.
 *
 * The file selection and build flags follow the recipe in `compressionz`
 * (Apache 2.0, github.com/NerdMeNot/compressionz) — in particular
 * `ZSTD_DISABLE_ASM`, which is what keeps this building on musl and on every
 * architecture rather than only where zstd ships hand-written assembly.
 */

/* Upper bound on the compressed size of `sourceSize` bytes. */
size_t swizzle_zstd_compress_bound(size_t sourceSize);

/*
 * Returns the compressed size, or 0 on failure.
 * `level` follows zstd's own scale; 3 is its default.
 */
size_t swizzle_zstd_compress(void *destination, size_t destinationCapacity,
                             const void *source, size_t sourceSize, int level);

/*
 * The sentinel `swizzle_zstd_decompressed_size` returns when a frame records no
 * size. Exposed as a function because `SIZE_MAX` is not visible to Swift on
 * every platform — it resolves on Darwin and not on musl, which turned a
 * working macOS build into a static-Linux failure.
 */
size_t swizzle_zstd_unknown_size(void);

/*
 * The decompressed size recorded in the frame header, or
 * `swizzle_zstd_unknown_size()` when the frame does not carry one (a streaming
 * producer may omit it).
 */
size_t swizzle_zstd_decompressed_size(const void *source, size_t sourceSize);

/* Returns the decompressed size, or 0 on failure. */
size_t swizzle_zstd_decompress(void *destination, size_t destinationCapacity,
                               const void *source, size_t sourceSize);

/* Non-zero when a returned size is one of zstd's error codes. */
int swizzle_zstd_is_error(size_t code);

#endif /* SWIZZLE_ZSTD_H */

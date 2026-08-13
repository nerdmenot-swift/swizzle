/*
 * Thin wrappers forming this target's public surface. All real work is the
 * vendored zstd under vendor/.
 */

#include <stdint.h>
#include "zstd.h"
#include "include/swizzle_zstd.h"

size_t
swizzle_zstd_compress_bound(size_t sourceSize)
{
    return ZSTD_compressBound(sourceSize);
}

size_t
swizzle_zstd_compress(void *destination, size_t destinationCapacity,
                      const void *source, size_t sourceSize, int level)
{
    size_t written = ZSTD_compress(destination, destinationCapacity,
                                   source, sourceSize, level);
    return ZSTD_isError(written) ? 0 : written;
}

size_t
swizzle_zstd_unknown_size(void)
{
    return SIZE_MAX;
}

size_t
swizzle_zstd_decompressed_size(const void *source, size_t sourceSize)
{
    unsigned long long size = ZSTD_getFrameContentSize(source, sourceSize);
    /*
     * ZSTD_CONTENTSIZE_UNKNOWN and ZSTD_CONTENTSIZE_ERROR are sentinel values,
     * not sizes. Both are collapsed to SIZE_MAX so the caller has one thing to
     * test rather than two magic numbers to remember.
     */
    if (size == ZSTD_CONTENTSIZE_UNKNOWN || size == ZSTD_CONTENTSIZE_ERROR) {
        return SIZE_MAX;
    }
    return (size_t) size;
}

size_t
swizzle_zstd_decompress(void *destination, size_t destinationCapacity,
                        const void *source, size_t sourceSize)
{
    size_t written = ZSTD_decompress(destination, destinationCapacity,
                                     source, sourceSize);
    return ZSTD_isError(written) ? 0 : written;
}

int
swizzle_zstd_is_error(size_t code)
{
    return ZSTD_isError(code);
}

/*
 * Platform glue for the vendored libsodium ref10 subset, plus the thin wrappers
 * that form this target's public surface.
 *
 * ## Why these five functions are shimmed rather than vendored
 *
 * `ed25519_ref10.c`, `core_ed25519.c` and `scalarmult_ed25519_ref10.c` reference
 * six symbols from outside the ed25519 tree: `sodium_memzero`, `sodium_is_zero`,
 * `sodium_add`, `sodium_sub`, `crypto_verify_32` and `randombytes_buf`. Five of
 * them live in libsodium's `sodium/utils.c`, which is 810 lines of guarded heap
 * allocation, `mlock`, `mprotect` and page-size probing — none of it needed
 * here, and precisely the kind of platform coupling that breaks a static musl
 * build. `randombytes_buf` pulls in an entire platform-specific RNG subsystem.
 *
 * So the split is: **vendor the cryptography, shim the platform glue.** The
 * arithmetic — the part that must be battle-tested — is libsodium's, untouched.
 * These five functions are libsodium's own portable fallbacks, copied verbatim
 * from `utils.c` with the `configure`-gated inline-assembly branches omitted,
 * which is exactly the code path an unconfigured build would take anyway.
 *
 * `crypto_verify_32` is vendored properly (`vendor/verify.c`); only the utils
 * helpers and the RNG are here.
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "crypto_core_ed25519.h"
#include "crypto_scalarmult_ed25519.h"
#include "include/swizzle_ed25519.h"

/* ------------------------------------------------------------------ *
 * libsodium utils.c portable fallbacks
 * ------------------------------------------------------------------ */

/*
 * A `volatile` function pointer to `memset` so the compiler cannot reason about
 * the call and optimise the zeroing away — libsodium's portable strategy when
 * no `explicit_bzero`/`memset_s` is available.
 */
static void *(*const volatile swizzle_memset_ptr)(void *, int, size_t) = memset;

void
sodium_memzero(void *const pnt, const size_t len)
{
    swizzle_memset_ptr(pnt, 0, len);
}

int
sodium_is_zero(const unsigned char *n, const size_t nlen)
{
    size_t                 i;
    volatile unsigned char d = 0U;

    for (i = 0U; i < nlen; i++) {
        d |= n[i];
    }
    return 1 & ((d - 1) >> 8);
}

void
sodium_add(unsigned char *a, const unsigned char *b, const size_t len)
{
    size_t        i;
    uint_fast16_t c = 0U;

    for (i = 0U; i < len; i++) {
        c += (uint_fast16_t) a[i] + (uint_fast16_t) b[i];
        a[i] = (unsigned char) c;
        c >>= 8;
    }
}

void
sodium_sub(unsigned char *a, const unsigned char *b, const size_t len)
{
    uint_fast16_t c = 0U;
    size_t        i;

    for (i = 0U; i < len; i++) {
        c = (uint_fast16_t) a[i] - (uint_fast16_t) b[i] - c;
        a[i] = (unsigned char) c;
        c = (c >> 8) & 1U;
    }
}

/* ------------------------------------------------------------------ *
 * randombytes
 * ------------------------------------------------------------------ */

/*
 * Referenced only by `crypto_core_ed25519_random` and
 * `crypto_core_ed25519_scalar_random`, neither of which this driver calls —
 * MariaDB's scheme derives every scalar from SHA-512. It must still resolve at
 * link time, so it is implemented properly rather than stubbed: a stub that
 * returned predictable bytes would be a loaded gun if anything ever did call it.
 *
 * Apple platforms use `arc4random_buf` and everything else uses `getentropy`.
 *
 * The Apple half was `<sys/random.h>` + `getentropy`, which is right for macOS
 * and does not build for iOS at all: that header is in the macOS SDK and not in
 * the iPhoneOS one, so the first compile ever attempted against the iOS SDK
 * stopped here. `Package.swift` had declared `.iOS(.v17)` the whole time.
 *
 * `arc4random_buf` is in `<stdlib.h>` on every Apple platform, is seeded from
 * the kernel CSPRNG, has no 256-byte cap, and returns void because it cannot
 * fail — so the loop and the `abort()` are needed only on the getentropy side.
 */
#if defined(__APPLE__)
# include <stdlib.h>
#else
# include <unistd.h>
#endif

void
randombytes_buf(void *const buf, const size_t size)
{
#if defined(__APPLE__)
    arc4random_buf(buf, size);
#else
    unsigned char *p = (unsigned char *) buf;
    size_t         remaining = size;

    /* getentropy is capped at 256 bytes per call, hence the loop. */
    while (remaining > 0U) {
        size_t chunk = remaining > 256U ? 256U : remaining;
        if (getentropy(p, chunk) != 0) {
            /* The OS entropy source failing is not something a caller can
             * meaningfully recover from, and returning weak bytes would be
             * worse than stopping. */
            abort();
        }
        p += chunk;
        remaining -= chunk;
    }
#endif
}

/* ------------------------------------------------------------------ *
 * Public surface
 * ------------------------------------------------------------------ */

void
swizzle_ed25519_scalar_reduce(unsigned char *out, const unsigned char *wide)
{
    crypto_core_ed25519_scalar_reduce(out, wide);
}

void
swizzle_ed25519_scalar_mul(unsigned char *z, const unsigned char *x,
                           const unsigned char *y)
{
    crypto_core_ed25519_scalar_mul(z, x, y);
}

void
swizzle_ed25519_scalar_add(unsigned char *z, const unsigned char *x,
                           const unsigned char *y)
{
    crypto_core_ed25519_scalar_add(z, x, y);
}

int
swizzle_ed25519_scalarmult_base_noclamp(unsigned char *q, const unsigned char *n)
{
    return crypto_scalarmult_ed25519_base_noclamp(q, n);
}

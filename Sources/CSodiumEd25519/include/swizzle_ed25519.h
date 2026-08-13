#ifndef SWIZZLE_ED25519_H
#define SWIZZLE_ED25519_H

#include <stddef.h>

/*
 * The four Edwards25519 operations MariaDB's `client_ed25519` needs, backed by
 * libsodium's ref10 implementation (vendored under `vendor/`, ISC licensed —
 * see LIBSODIUM-LICENSE).
 *
 * Deliberately a narrow surface rather than re-exporting libsodium's headers:
 * Swift sees exactly four functions, and libsodium's public macros and type
 * names never enter the module. It also means the vendored tree can be updated
 * without anything downstream noticing.
 *
 * All buffers are 32 bytes except `scalar_reduce`, whose input is 64.
 */

/* Reduces a 64-byte little-endian value mod L into 32 bytes. */
void swizzle_ed25519_scalar_reduce(unsigned char *out, const unsigned char *wide);

/* z = x * y mod L */
void swizzle_ed25519_scalar_mul(unsigned char *z, const unsigned char *x,
                                const unsigned char *y);

/* z = x + y mod L */
void swizzle_ed25519_scalar_add(unsigned char *z, const unsigned char *x,
                                const unsigned char *y);

/*
 * q = [n]B, with **no clamping** of n.
 *
 * Returns 0 on success, -1 if the result is the identity or a small-order
 * point, which libsodium refuses to produce.
 */
int swizzle_ed25519_scalarmult_base_noclamp(unsigned char *q, const unsigned char *n);

#endif /* SWIZZLE_ED25519_H */

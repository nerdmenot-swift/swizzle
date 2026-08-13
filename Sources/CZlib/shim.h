// A shim so SwiftPM has a header to hang the module map on.
//
// Only the one-shot entry points are needed: MySQL's compressed protocol frames
// each chunk independently in zlib format (RFC 1950 — the 2-byte header and
// trailing adler32, not raw deflate), which is exactly what `compress2` emits
// and `uncompress` consumes. The streaming `deflate`/`inflate` API would add
// nothing, and `deflateInit`/`inflateInit` are macros that Swift cannot import.
#include <zlib.h>

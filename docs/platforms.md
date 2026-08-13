# Platform support

Verified, not assumed — every claim here was produced by building or running,
and the command is given so it can be re-checked.

| target | status | verified by |
|---|---|---|
| macOS (arm64) | ✅ builds, 1375 tests pass | `swift test` (with `./Scripts/test-servers.sh up`) |
| Linux glibc (Swift 6.3.3) | ✅ builds, 784 run + 591 skipped, 0 failures | `docker run --rm -v "$PWD":/src -w /src swift:6.3.3 swift test --scratch-path .build-linux` |
| Linux static musl, aarch64 | ✅ library builds | `swift build --swift-sdk aarch64-swift-linux-musl` |
| Linux static musl, x86_64 | ✅ library builds | `swift build --swift-sdk x86_64-swift-linux-musl` |
| iOS | ⬜ untested | declared in `Package.swift`, never built |
| Windows | ⬜ untested | — |

## System dependencies

**None beyond a Swift toolchain.** libsodium is vendored, not linked from the
system; zlib is the only external C library and it is present everywhere that
matters.

The zlib detail: for the compressed wire protocol, and it is
already present everywhere that matters: the macOS SDK, the official Swift
Docker images (`zlib1g-dev` is preinstalled — Foundation itself links it), and
the static Linux SDK's musl sysroot (`libz.a` for both aarch64 and x86_64). A
distribution that somehow lacks it gets a named package to install rather than a
bare "file not found", via SwiftPM `providers` on the `CZlib` target.

## ed25519: vendored libsodium

MariaDB's `client_ed25519` seeds the ed25519 expansion with the *password
bytes* rather than a 32-byte seed, so it needs raw scalar and group arithmetic
that swift-crypto does not expose. (`parsec`, despite also being ed25519, never
did — PBKDF2 hands it a proper 32-byte seed, so `Curve25519.Signing` covers it.)

That was originally the swift-sodium package, which turned out to be the single
thing blocking a fully-static Linux build: it resolves to a system library
everywhere except Apple platforms, and the static SDK's musl sysroot has no
libsodium. Its own shim also warns `Using a system installation of libsodium -
This is unsupported.` on every non-Apple build.

The fix is to **vendor libsodium's ref10 ed25519 subset** — `CSodiumEd25519`,
ISC licensed, see `Sources/CSodiumEd25519/LIBSODIUM-LICENSE`.

### Why only a subset, and why it is portable

ref10 is portable C99: no assembly, no CPU-feature detection, no runtime
initialisation. That is exactly what makes it build for static musl as well as
macOS and glibc — and it is why vendoring *all* of libsodium would have been the
wrong move.

| | |
|---|---|
| vendored C (unmodified libsodium) | ~9,000 lines |
| our shim | 156 lines |
| external system dependencies | none |

The split is deliberate: **vendor the cryptography, shim the platform glue.**

The three ed25519 sources reference six symbols from outside their tree —
`sodium_memzero`, `sodium_is_zero`, `sodium_add`, `sodium_sub`,
`crypto_verify_32` and `randombytes_buf`. `crypto_verify_32` is vendored
properly. The rest live in libsodium's `sodium/utils.c`: 810 lines of guarded
heap allocation, `mlock`, `mprotect` and page-size probing, none of it needed
here and all of it precisely the platform coupling that breaks a static musl
build. `randombytes_buf` would drag in an entire platform-specific RNG
subsystem, and is only referenced by `crypto_core_ed25519_random`, which this
driver never calls.

So those five are shimmed with libsodium's **own portable fallbacks**, copied
from `utils.c` minus the `configure`-gated inline assembly — which is the code
path an unconfigured build takes anyway. `randombytes_buf` is implemented over
`getentropy` rather than stubbed: a stub returning predictable bytes would be a
loaded gun if anything ever did call it.

Two build settings, both matching what `configure` would set: `CONFIGURED=1`
silences libsodium's "undocumented build method" warning, and `HAVE_TI_MODE`
selects the `fe_51` field implementation (radix 2^51 over `__int128`) instead of
`fe_25_5`. **Caveat:** `HAVE_TI_MODE` assumes a 64-bit target. The platform list
covers macOS, iOS and Linux, all of which are 64-bit here; a 32-bit target such
as armv7 would need that define dropped so it falls back to `fe_25_5`.

### Performance

| implementation | ms/signature | vs swift-crypto |
|---|---|---|
| TweetNaCl in Swift, radix 2^16 in `[Int64]` | 21.5 | 500× |
| Swift, radix 2^51 in a struct | 1.72 | 40× |
| Swift, + precomputed fixed-base table | 0.41 | 9× |
| **vendored libsodium ref10** | **0.25** | **5.6×** |
| swift-crypto (BoringSSL, reference) | 0.045 | 1× |

Faster than the hand-written Swift, as expected — ref10 uses a windowed comb
over a precomputed table and a well-tuned field layer. The remaining gap to
BoringSSL is assembly.

### What verifies it

The pure-Swift implementation was **kept**, moved into the test target as
`Ed25519Core`. An independent second implementation is worth far more as a
permanent differential oracle than as deleted code — it shares no line of source
with the C, and no strategy either: different language, different field
internals, different scalar-multiplication method.

Five oracles now hold simultaneously:

1. **Vendored C against the Swift oracle**, across randomised inputs —
   `VendoredCEquivalenceTests`.
2. **Against TweetNaCl**, a third independent implementation with radix 2^16 —
   `Ed25519EquivalenceTests`.
3. **Frozen known-answer vectors** that have now held across three different
   implementations of the same maths — `Ed25519VectorTests`.
4. **swift-crypto at 32-byte passwords**, where the two schemes coincide exactly
   and BoringSSL becomes a byte-for-byte oracle over the whole signing path —
   `SwiftCryptoEquivalenceTests`.
5. **MariaDB's own stored public key**, plus live authentication against 11.4,
   11.8 and 12.2, plaintext and TLS, with a wrong-password rejection.

### Findings from reviewing the Swift implementation

Recorded because they are the kind that recur, and because the oracle code is
still live and must stay correct.

**A branch on secret data.** The window index was computed with
`digit < 0 ? -digit : digit` — a source-level branch on the secret scalar, sitting
directly above the masked table selection that exists to avoid exactly that.
Replaced with a branchless absolute value; measurably free.

**A silent wrong answer for out-of-range scalars.** Signed-digit recoding
requires `scalar[31] <= 127`; above it the top digit becomes 16, matches no table
entry, and the result diverges from the ladder with no error raised. Both real
callers satisfy the invariant, so it was latent — but it now traps, and
`ScalarRangeTests` sweeps both real inputs plus the boundary.

Also checked and sound: the 80 KB table is a `static let`, so construction is
once-only under concurrent first use — exercised by `Ed25519ConcurrencyTests`
rather than assumed.

### One deliberate divergence, pinned from both sides

For a **zero scalar**, libsodium refuses — `crypto_scalarmult_ed25519_base_noclamp`
returns −1 rather than a point, rejecting identity and small-order outputs. The
Swift oracle returns the mathematically correct identity encoding (`01` followed
by 31 zero bytes).

Unreachable in this protocol: every scalar comes out of SHA-512, and the secret
is clamped so bit 254 is always set. Vendoring the C restored libsodium's
stricter behaviour, which is the safer of the two — a degenerate point now
surfaces as an error rather than a silently useless signature. Both sides are
pinned by tests so it stays a recorded decision.

### Known limitation

The static Linux SDK cannot build the **test** target, because it ships no
swift-testing module. The library itself builds, which is what deployment needs;
tests are run on glibc Linux instead.

## A Swift-version difference worth knowing

macOS here runs Swift 6.3; the current Linux toolchain is 6.1. They disagree
about **parameter packs at the use site**.

An `AsyncSequence` whose `Element` is a pack expansion — `(repeat each V)`, which
is what a typed row stream naturally wants to be — compiles on both but cannot
be *iterated* on 6.1: every `for try await` over it fails with "value pack
expansion can only appear inside a function argument list". Binding the tuple
whole instead of destructuring does not help; the restriction is on iterating at
all.

So the typed streaming API is a callback, `forEach(on:)`, because a closure
parameter *is* a function argument list. Backpressure is unaffected — the body
still runs per row as it arrives — and `streamRows(on:)` returns an ordinary
`AsyncSequence` of untyped `SQLRow` for callers who want to iterate.

Worth noting the shape of the mistake: this compiled and passed the full suite on
macOS. Only running on Linux caught it, which is the same lesson as the
`SOCK_STREAM` bug below.

## A portability bug this found

`TestServers.canConnect` passed `SOCK_STREAM` straight to `socket(2)`. That is
an `Int32` on Darwin, but glibc declares the socket types as an enum, so on
Linux it is a `__socket_type` and the test target would not compile. Normalised
per platform alongside the other POSIX shims in `TestServers.swift`.

Worth noting it was in the *test* target — the library was already clean — and
that it only surfaced because the suite was actually run on Linux rather than
reasoned about.

## What the Linux run does and does not cover

591 of the 1375 tests **skip** on Linux, and the reason is the fixtures rather
than the platform: the servers `./Scripts/test-servers.sh` starts bind to the
*host's* loopback, so a container cannot reach them. What runs there is every
unit test, every protocol state machine, every codec, the whole SQLite suite —
784 tests. What does not is anything needing MySQL, MariaDB or Postgres.

To cover those on Linux the servers have to live in the same network namespace as
the tests. That is a CI shape, not a laptop one.

### Three defects the first Linux run found

The record above said "359 tests pass" and had not been re-checked in a long
time — the suite had grown roughly fourfold underneath it.

1. **`stderr` is a global `var` in glibc**, so Swift 6 strict concurrency refuses
   to let a `@Sendable` closure reference it: *"reference to var 'stderr' is not
   concurrency-safe"*. Darwin and musl import the same symbol in a form that does
   not trip the check, which is why this compiled on macOS **and** on both
   static-musl cross-builds and failed only here. `SQLDiagnostics` now writes to
   `STDERR_FILENO` directly — same destination, no global, and no `fflush`
   because descriptor writes are not buffered.

2. **The Postgres suites had no availability gate.** Every MySQL suite carries
   `.enabled(if: TestServers.isAvailable)` and skips cleanly without servers; the
   Postgres ones never grew the equivalent, so each test opened a connection and
   waited out the ten-second acquisition timeout. The first Linux run produced
   **172 failures in 124 seconds**, none of which said anything about Linux — and
   a contributor without fixtures running saw the same wall of red. Four MySQL
   suites written with a single-line `@Suite` had slipped through the same gap.

3. **A timing bound calibrated on one fast machine.** The interrupt test asserted
   that a runaway statement is cut off inside two seconds; in a container the
   interrupt landed at 2.95 s. The behaviour was correct — that CTE runs for
   minutes uninterrupted — but the bound was measuring the machine. Now ten
   seconds, which still discriminates by orders of magnitude.

Only the first is a bug in the library. The other two are bugs in the
*verification*, which is the same pattern the driver audits kept turning up: the
code was fine and the thing checking it was not.

## CI

`.github/workflows/ci.yml`, on every push and pull request:

| job | what it proves |
|---|---|
| `linux` | builds and tests on glibc, plus `test-hygiene.sh` |
| `musl` (aarch64, x86_64) | the static SDK still links — no glibc-shaped symbol crept in |
| `macos` | the Darwin halves of every `#if canImport(Darwin)`, plus the 17 compile-error gates |

Locally, `./Scripts/linux-tests.sh` runs the Linux job's core in the same
container image.

The static SDK is installed with a **pinned checksum**. `--checksum` is optional
and the install works without it, which would mean a 300 MB unverified download
on every run.

Verified to build on Swift 6.1 as well as 6.3.3, so the macOS runner's default
toolchain lagging behind is not a problem.

### What CI does not cover

The integration suites — anything needing MySQL, MariaDB or Postgres. They skip,
because `./Scripts/test-servers.sh` starts native binaries bound to the host's
loopback and CI has no equivalent. That is ~590 of 1375 tests, and it means **the
protocol work is only ever verified on a developer machine**.

Stated plainly rather than left implicit: it is the largest remaining hole in the
verification story, and closing it means running the fixtures inside the CI
network namespace.

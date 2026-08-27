# Platform support

Verified, not assumed — every claim here was produced by building or running,
and the command is given so it can be re-checked.

| target | status | verified by |
|---|---|---|
| macOS (arm64) | ✅ builds, 1440 tests pass | `swift test` (with `./Scripts/test-servers.sh up`) |
| Linux glibc (Swift 6.3.3) | ✅ builds, 784 run + 591 skipped, 0 failures | `docker run --rm -v "$PWD":/src -w /src swift:6.3.3 swift test --scratch-path .build-linux` |
| Linux glibc (Swift 6.0.3) | ✅ builds, 1440 tests pass | `docker run --rm -v "$PWD":/src:ro swift:6.0.3 …` — the floor `swift-tools-version` claims |
| Linux static musl, aarch64 | ✅ library builds | `swift build --swift-sdk aarch64-swift-linux-musl` |
| Linux static musl, x86_64 | ✅ library builds | `swift build --swift-sdk x86_64-swift-linux-musl` |
| iOS (arm64, v17) | ✅ library targets build | `swift build --target … -Xswiftc -sdk -Xswiftc "$(xcrun --sdk iphoneos --show-sdk-path)" …`, in CI |
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

Verified to build on Swift 6.0.3, 6.1 and 6.3.3 — but building was never the
question. A query timeout reported on time and failed to bound the statement on
6.1 and nowhere else, for fifty seconds against a fifty-millisecond deadline, and
it took six CI rounds to find because the only job that could see it was the only
job nobody had pinned.

So the matrix now runs both ends: `minimum-toolchain` on `swift:6.0.3`, and the
macOS job on the newest Xcode the runner image carries. Pinning only the newest
would have removed the coverage that found the bug — which is exactly what the
first attempt at this did.

That floor was itself wrong for a while, and worth recording. The job pinned
`swift:6.1` on the belief that it was the oldest image published for this
platform; `swift:6.0.3` exists, so the version the package actually advertises
was the one version nothing ever compiled. It did not hold when finally tried:

  - Ten `EventLoopFuture.wait()` calls sat inside `async` test functions. 6.0
    rejects them and later toolchains do not — and it is right to. `wait()`
    blocks the calling thread, which inside an `async` function belongs to the
    cooperative pool, and the suite runs its tests in parallel.
  - `#require(x.first?[1].string)` takes the macro's property-access path, and
    the macro shipped with 6.0 cannot expand it through an optional subscript.

Both were fixed rather than floored away.

### What CI does not cover

**The integration suites on macOS.** `linux-integration` runs all seven fixtures
on x86_64 Linux and the suite three times over, so the protocol work is no longer
verified only on a developer machine — but the macOS job still skips every
integration suite, and macOS is the one platform where the drivers compile a
different set of branches. `TCPKeepalive.swift` reaches for different socket
option constants under `#if canImport(Darwin)`, and those are only exercised
against a real connection. Closing this means starting the fixtures on the macOS
runner, which the script already supports.

**Anything not arm64 or x86_64**, and anything not macOS or Linux. Windows is
untested and unclaimed. iOS is compiled but never run — there is no simulator
step, so the claim is "it builds", not "it works".

**MariaDB 10.11 and Postgres other than 16.** The fixture matrix now covers
MariaDB 11.4/11.8/12.2, MySQL 8.0/8.4/9.1 and Postgres 16. The index publishes
Postgres 14 through 18, so widening that is cheap and has not been done.

## Integration tests on Linux

The fixtures now run there. That took six fixes to `Scripts/test-servers.sh`,
every one of which blocked the whole stack:

| | what was wrong |
|---|---|
| binary cache had no platform tag | a container on a macOS host found the host's arm64-darwin `mariadbd` and died with `cannot execute binary file` |
| `fetch_index` printed to **stdout** | `base="$(ensure_binaries …)"` captured the progress line, so `base` became `"Fetching binary index…\n/path"` and the next line reported `mariadb-install-db: No such file or directory` for a file that was present and executable. **Broke the first run on any machine** — invisible afterwards, because the index is then cached |
| no `--user=root` | MariaDB and MySQL refuse to run as root, which a CI container is |
| Postgres run as root | `initdb: cannot be run as root`, and unlike MySQL there is no flag for it — everything Postgres now goes through `setpriv` as an unprivileged user |
| the TLS key owned by root | generated after the `chown`, so `chmod 600` locked it to the wrong account and the postmaster reported `could not load private key file: Permission denied` |
| MySQL's Linux archive is `.tar.xz` | the script assumed `.tar.gz` for every platform, so **every** Linux download 404'd — on x86_64 as well as aarch64 |

`SWIZZLE_TESTSERVERS_ROOT` also moves the fixtures off the checkout, which is
needed when the checkout is a bind mount rather than a local filesystem.

Reproduce the whole thing:

```
docker run --rm -v "$PWD":/src:ro swift:6.3.3 bash -c '
  apt-get update -qq && apt-get install -y -qq curl libaio1t64 libncurses6 libnuma1 unzip xz-utils
  ARCH=$(uname -m); ln -sf /usr/lib/$ARCH-linux-gnu/libaio.so.1t64 /usr/lib/$ARCH-linux-gnu/libaio.so.1
  cp -r /src /work && cd /work && rm -rf .testservers .build
  ./Scripts/test-servers.sh up && swift test'
```

The `libaio` symlink is Ubuntu 24.04's `t64` transition: MySQL wants
`libaio.so.1` and noble ships `libaio.so.1t64`.

### Failures that appear only on Linux: 15, then 6

With the fixtures up, the integration suites ran on a second platform for the
first time and 15 tests failed:

| file | count | symptom |
|---|---|---|
| `BinlogJSONTests` | 11 | a row event short: `rows.count → 4` where 5 are expected |
| `ClosedConnectionTests` | 3 | `Already closed` **at connect**, on the TLS path |
| `BinlogTests` | 3 | `.uncleanShutdown` |
| `PostgresSessionTests` | 2 | `Already closed` |
| `MySQLKeepAliveTests` | 1 | `Already closed` |

Pinning the certificate — see below — took that to **6**, with `BinlogTests`
clearing entirely and `BinlogJSONTests` going from 11 failures to 1 whose shape
also changed, from `4 of 5` documents to `11 of 12`:

| file | count | symptom |
|---|---|---|
| `ClosedConnectionTests` | 3 | `Already closed`, `.uncleanShutdown` |
| `PostgresSessionTests` | 1 | `Already closed` |
| `MySQLKeepAliveTests` | 1 | `.uncleanShutdown` |
| `BinlogJSONTests` | 1 | `decoded.count → 11` where 12 are expected |

The five remaining connection failures are all in the **close** path, not the
connect path as first recorded, and their durations say so: 5.6 s and 5.9 s
against a 5-second NIOSSL `close_notify` wait. `.uncleanShutdown` is what NIOSSL
reports when a peer drops the TCP connection without sending `close_notify`, so
the question is whether the Linux servers close differently or our shutdown
races them. That is a real client-side difference and a genuinely narrow one —
which is what the certificate work bought: 1408 of 1414 tests now agree across
platforms, so what is left is signal rather than noise.

**The diagnosis above was wrong, and worth recording as written.** It said this
was "a genuine platform difference rather than a fixture gap — NIOSSL against a
MariaDB-generated certificate behaving differently on Linux than on Darwin."

`swift-nio-ssl` **statically vendors BoringSSL on every platform**. It does not
use OpenSSL on Linux and does not use SecureTransport on Darwin. The client TLS
stack is identical on both machines, so it could not have been the client, and
the reasoning that got there — "the server reports `have_ssl = YES`, therefore
the server is fine, therefore it is the client" — skipped the possibility that
the server was fine *and different*.

It was. The fixtures served **three** certificates, none of them written down:

| fixture | where its certificate came from |
|---|---|
| Postgres | `openssl req` with only `-subj`, so key size, digest and extensions came from the host's `openssl.cnf` — **LibreSSL 3.3.6** on macOS, **OpenSSL 3.0.2** in the container |
| MariaDB 11.4+ | the server's own **ephemeral** self-signed certificate: never written to disk, regenerated on every restart |
| MySQL 8+ | the server's auto-generated `ca.pem` and cert, written to the data directory by that platform's build |

So "TLS behaves differently on Linux" was three different certificates from three
different TLS libraries, compared against one client. `testservers/tls.cnf` now
issues a single certificate for every fixture — RSA 2048, SHA-256, `CA:TRUE`, and
a SAN covering `localhost` and `127.0.0.1` — generated by a config file rather
than by host defaults, since `-addext` needs OpenSSL 1.1.1 and macOS ships
LibreSSL.

Pinning it made the strictest rung testable for the first time: `verify_identity`
against both MariaDB and MySQL, hostname verification included. It had been
`verify_ca` against MySQL only, because MySQL's generated certificate is named
`MySQL_Server_..._Auto_Generated_Server_Certificate` and MariaDB left nothing on
disk to trust at all.

**The lesson is the general one.** A difference between platforms is only
evidence about the code if everything else is held equal, and here almost nothing
was: three certificate sources, plus a `down` that silently never stopped
Postgres, so a "restart and retry" did not restart it.

### `down` never stopped Postgres, and `reset` deleted its data underneath it

Found while pinning the certificates above: Postgres kept serving the old one
after a full `down`/`up` cycle.

`down`, `reset` and `clean` all iterated the server list as
`while read -r name _ _ _`, which discards everything after the name — including
the **flavour**. `stop_server` therefore defaulted to `mariadb` for every server,
took the pidfile branch, found no `postgres16.pid` because Postgres is stopped
through `pg_ctl` and writes no pidfile of ours, and returned success without
stopping anything. Only `up` passed the full row, so the script knew about
flavours in one direction and not the other.

`down` leaving a postmaster running is the mild version. `reset` and `clean` then
run `rm -rf` over the data directory of a **live** postmaster — so the command
you reach for when the fixtures are broken was able to break them further. Both
now go through `each_server`, which passes all five fields.

`each_server` itself was piping into `while`, which runs the loop in a subshell,
so a `return 1` inside it set only the subshell's status: `each_server
start_server || exit 1` reported whatever the *last* server did, and a failure in
the middle was invisible. It reads from a process substitution now.

And `status` hardcoded the flavour, so it reported `postgres16 mariadb 16.4.0`.

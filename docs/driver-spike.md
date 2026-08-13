# Driver spike: MySQL/MariaDB is the real risk, and it's bigger than "less maintained"

Static analysis of `vapor/mysql-nio`, `vapor/mysql-kit` and `vapor/postgres-nio`
at their current heads. Written to answer: can we build Swizzle's executor —
streaming from day one, prepared-statement caching, built-in pooling — on the
existing Swift drivers?

**Answer: on Postgres, yes, comfortably. On MySQL/MariaDB, not without forking.**

The static findings turned out to be more decisive than a live connection test
would have been, so the live auth test is still outstanding — see §6.

---

## 1. Verdict table

| capability | PostgresNIO | MySQLNIO |
|---|---|---|
| async/await API | yes | **none — 0 occurrences of `async` in `Sources/`** |
| streaming `AsyncSequence` | `PostgresRowSequence: AsyncSequence` | **none** |
| backpressure | `NIOThrowingAsyncSequenceProducer` + `AdaptiveRowBuffer` | **none — push-only `onRow` callback** |
| prepared-statement reuse | yes | **no — PREPARE/EXECUTE/CLOSE every query** |
| built-in connection pool | `PostgresClient` + `ConnectionPoolModule` | **none** (pool lives in MySQLKit via AsyncKit) |
| `caching_sha2_password` | n/a | **yes**, incl. RSA public-key full-auth path |
| MariaDB `ed25519` | n/a | **no — `throw MySQLError.unsupportedAuthPlugin`** |
| size | 20,017 lines | 7,587 lines |
| license | MIT | MIT |

Both are actively maintained — MySQLNIO was pushed 2026-08-03, released 1.9.1 in
Feb 2026. "Abandoned" was the wrong worry. The right worry is that it's a
*generation behind* architecturally.

---

## 2. MySQLNIO: four concrete gaps

### 2.1 No async/await at all

```
$ grep -rn "async" mysql-nio/Sources | wc -l
0
```

The package is `swift-tools-version:6.0` and has 16 `Sendable` annotations, so it
compiles under Swift 6 — but the entire API is `EventLoopFuture` plus a callback:

```swift
public func query(_ sql: String, _ binds: [MySQLData],
                  onRow: @escaping (MySQLRow) throws -> ()) -> EventLoopFuture<Void>
```

### 2.2 `onRow` is push-only — there is no backpressure hook

`onRow` is invoked as rows arrive. There is no way to say "stop, I'm not ready."
Confirming this, there are zero references to `autoRead` or `context.read()`
anywhere in `Sources/MySQLNIO/`.

Bridging this to an `AsyncSequence` without read control means buffering the
entire result set in memory — which defeats the point of streaming. **The day-one
streaming requirement cannot be met on MySQL with MySQLNIO as it stands.**

Contrast, from PostgresNIO:

```swift
public struct PostgresRowSequence: AsyncSequence, Sendable {
    typealias BackingSequence =
        NIOThrowingAsyncSequenceProducer<DataRow, any Error, AdaptiveRowBuffer, PSQLRowStream>
```

That's a real adaptive high/low-watermark buffer — exactly the thing we need,
already built and battle-tested.

The one piece of good news: `MySQLConnectionHandler` is a `ChannelDuplexHandler`,
so it *can* intercept `read()`. Adding read-control is architecturally feasible
rather than requiring a rewrite.

### 2.3 Every query does PREPARE → EXECUTE → CLOSE

From `MySQLQueryCommand.swift` — the statement is closed as soon as the result set
finishes:

```swift
MySQLProtocol.COM_STMT_CLOSE(statementID: self.ok!.statementID).encode(into: &packet)
self.statementID = nil
```

Three round trips per query, and the statement is never reused. Open issue #46,
"Support re-using prepared statements," is unresolved.

This directly blocks pillar 3. A prepared-statement cache cannot be built *on top
of* this API, because the driver closes the statement itself before returning.

### 2.4 No MariaDB `ed25519`

`doInitialAuthPluginHandling` handles exactly two plugins:

```swift
case "caching_sha2_password":  ...
case "mysql_native_password":  ...
default:
    throw MySQLError.unsupportedAuthPlugin(name: authPluginName)
```

Scope of the damage is narrower than it first appears: MariaDB still defaults to
`mysql_native_password` over TCP, so a default MariaDB install connects fine.
`ed25519` must be explicitly enabled — but it is exactly what security-conscious
deployments turn on, so "we don't support hardened MariaDB" is a bad look.

`caching_sha2_password` — MySQL 8+/9's default, and the thing I was most worried
about — is **fully implemented**, including the hard part: `AuthMoreData`,
`fast_auth_success`, `perform_full_authentication`, cleartext-over-TLS, and RSA
public-key request over an insecure channel.

---

## 3. Pooling: one generic pool covers all three databases

This is the best news in the spike, and it lands on the "pooling built in"
requirement.

`postgres-nio` ships `ConnectionPoolModule` as a **separate target** whose only
imports are `Atomics`, `DequeModule` and platform libc:

```
$ grep -rh "^import" Sources/ConnectionPoolModule/ | sort -u
import Atomics
import DequeModule
import Darwin / Glibc / Musl / ucrt / WinSDK / WASILibc / Bionic
```

**No SwiftNIO. No Postgres.** 4,525 lines, MIT, fully generic:

```swift
public protocol PooledConnection: AnyObject, Sendable { associatedtype ID: Hashable & Sendable }
public protocol ConnectionKeepAliveBehavior: Sendable
public protocol ConnectionPoolObservabilityDelegate: Sendable
public struct ConnectionPoolConfiguration: Sendable
public final class ConnectionPool<...>
```

Complete with a pool state machine, request queue, keep-alive behaviour, lease
semantics and an observability delegate.

So Swizzle can have **one modern async pool for Postgres, MySQL and SQLite** by
conforming each connection type to `PooledConnection`. We do not write a pool.

Caveat: PostgresNIO imports it as `_ConnectionPoolModule` — the underscore means
no API-stability promise. Two options: depend on it and accept churn, or vendor
it (MIT, self-contained, 4.5k lines). Vendoring is defensible here.

Meanwhile MySQL's only pooling story is MySQLKit → AsyncKit's
`EventLoopConnectionPool` / `EventLoopGroupConnectionPool` — future-based,
per-event-loop, and a generation older. Not something to build on.

---

## 4. What this means

The three pillars are not equally blocked. Postgres and SQLite can be built
exactly as designed. MySQL/MariaDB cannot, on any of the three axes that matter
most: streaming, statement caching, and pooling.

Four ways forward:

**A. Use MySQLNIO as-is.** Cheapest. Costs the day-one streaming requirement on
MySQL, and pillar 3's statement cache on MySQL. Effectively ships a second-class
MySQL.

**B. Fork MySQLNIO and modernise it.** Add read-control backpressure + an
`AsyncSequence`, statement reuse, and `ed25519`. The protocol layer (5,304 lines)
is the hard, tedious part and it already works — we would be changing the
connection/command layer (2,033 lines) and adding one auth plugin. This is the
option I'd estimate at weeks, not months, and it's made plausible by
`MySQLConnectionHandler` already being a `ChannelDuplexHandler`. Upstreaming is
possible; issues #46 and #96 suggest the maintainers would take it.

**C. Write our own MySQL protocol implementation.** ~7.5k lines to match, against
a wire protocol with real edge cases (auth switch, multi-resultset, stored
procedures, `SERVER_MORE_RESULTS_EXISTS`). Full control, highest cost. Hard to
justify when B gets most of it.

**D. Ship Postgres + SQLite first; MySQL later.** Both support everything we want
today. Defers the fork without compromising the design, and lets the builder and
migration work proceed at full speed.

**Recommendation was D-then-B. Decision taken was C: write our own driver.**
Recorded 2026-08-05. Work has started — see §7.

---

## 5. Reusable decisions from this spike

- Use `ConnectionPoolModule` (vendored or depended on) as Swizzle's single pool
  across all three databases. Do not write a pool.
- Model the streaming API on `PostgresRowSequence` + `AdaptiveRowBuffer`. It is
  the reference implementation for what we want, and it sets the bar MySQL must
  be brought up to.
- Any MySQL work must fix read-control first — statement caching and streaming
  both depend on it.

## 6. Not yet tested — live connections

No live server was provisioned (no Docker CLI, no MySQL/MariaDB installed). The
static findings above are definitive for streaming, pooling, statement reuse and
ed25519 — they're determined by what the source does and doesn't contain.

What a live test would still add:
- Confirm `caching_sha2_password` works end-to-end against real MySQL 8.4 and 9.x,
  including the RSA path on a non-TLS connection.
- Confirm default MariaDB (11.x/12.x) connects via `mysql_native_password`.
- Measure the actual round-trip cost of PREPARE/EXECUTE/CLOSE per query.

That needs either Docker (`brew install docker` + `colima start`, which is
already installed but not running) or `brew install mysql mariadb` on
non-conflicting ports.

Deferred by decision — provisioning will happen when the connection state machine
needs an integration target.

---

## 7. `SwizzleMySQL` — what exists now

Building our own driver. Started with the layer that is both highest-risk and
fully testable without a server.

**Done, 36 tests passing:**

- `Protocol/LengthEncoded.swift` — length-encoded integers and strings, the
  encoding every other packet is built from. Truncated reads restore the reader
  index so they can be retried when more bytes arrive; NULL (`0xFB`) is
  distinguishable from truncation.
- `Protocol/MySQLPacket.swift` — framing, including the 16 MiB split-packet rule
  in both directions. A payload of exactly `0xFFFFFF` means another packet
  follows; a payload that is an exact multiple needs a trailing empty packet or
  the peer waits forever. Both are tested directly.
- `Protocol/Capabilities.swift` — capability flags as a 64-bit set, because
  MariaDB reuses the upper 32 bits of a space MySQL documents as 32-bit.
- `Protocol/Handshake.swift` — HandshakeV10 parsing, including the three real
  bug sources: scramble split across two fields, part 2's trailing NUL not being
  scramble material, and MariaDB's extended capabilities hiding in MySQL's
  reserved bytes.
- `Auth/MySQLAuth.swift` — `mysql_native_password` and `caching_sha2_password`.

**On test oracles.** The auth vectors are taken verbatim from
`go-sql-driver/mysql`'s `auth_test.go` — a driver in wide production use whose
outputs demonstrably authenticate against real servers. Their `scramblePassword`
and `scrambleSHA256Password` were read alongside and match ours step for step.
This matters: re-deriving the same formula ourselves in a second language would
only catch transcription slips, never a misunderstood algorithm.

**Deliberately not written: `client_ed25519`.** MariaDB signs the scramble with
an ed25519 key derived from the password. The derivation *appears* to be the
standard expansion (SHA-512, clamp the lower half as scalar, upper half as nonce
prefix) but seeded with the password bytes rather than a 32-byte seed. If that is
right, Swift Crypto cannot express it — `Curve25519.Signing.PrivateKey` accepts
only a 32-byte `rawRepresentation` and performs the expansion internally, leaving
no way to inject a pre-expanded key.

Two things must happen first, in order: confirm the derivation against MariaDB's
`plugin/auth_ed25519` reference implementation (the above is inferred, not
verified), then choose a crypto path that can sign with an externally expanded
key. Until then it fails with an actionable error rather than a wrong signature.

**Next:** connection state machine with read-control from the start — the thing
MySQLNIO can't retrofit — then the row `AsyncSequence` modelled on
`PostgresRowSequence`, then prepared-statement caching, then `PooledConnection`
conformance.

# MySQL/MariaDB protocol completeness checklist

Derived by surveying four mature clients (see `references/README.md`). The point
is to know the full surface *before* building, so gaps are deliberate choices
rather than discoveries made in production.

Status: ✅ done · 🔜 planned · ⬜ not started · ❌ deliberately out of scope

Primary reference is `rust-mysql-common` + `mysql_async`; see
`references/README.md` for why and for how the others are used.

---

## 0. Audit log

Existing code re-verified line by line against the primary reference before
adding anything new.

**Confirmed correct** — length-encoded int/string boundaries (`<= 0xFA` direct;
251 / 65 536 / 16 777 216 write widths; `0xFB`/`0xFF` invalid), encoder split
behaviour across all four cases (empty, exact-max, exact multiple, max+1),
handshake field layout including `Skip<6>` before MariaDB's extended
capabilities in the last 4 reserved bytes, trailing-NUL stripping on scramble
part 2, the "missing trailing 0 is a known bug in mysql" plugin-name fallback,
MariaDB capability bit positions (PROGRESS 1<<32, STMT_BULK 1<<34,
EXTENDED_METADATA 1<<35, CACHE_METADATA 1<<36), and both auth scramble
compositions including the empty-password rule.

**Two real bugs found and fixed:**

1. **Unbounded reassembly buffer.** The decoder had no `max_allowed_packet`
   limit, so a peer streaming endless 16 MiB continuation chunks would be
   buffered until OOM, with no error. Now bounded (default 4 MiB, matching
   `DEFAULT_MAX_ALLOWED_PACKET`) and applied to the *accumulated* length, not
   per chunk — otherwise a split packet slips past one chunk at a time.
2. **Wrong sequence ID on reassembled packets.** We reported the *first*
   chunk's sequence ID; the peer expects continuation from the *last* one
   (`ChunkInfo::Last(seq_id)`). Every payload over 16 MiB would have
   desynchronised the sequence.

**Two defensive refinements adopted:** auth-plugin-data length is now read as
*signed* (`as i8`), so a server claiming > 127 falls back to 13 instead of
letting us swallow the plugin name into the scramble; and a short scramble is
padded to 20 bytes rather than producing a truncated auth response that fails
for an unrelated-looking reason.

**Three capability flags added** that were missing: `CLIENT_PROGRESS_OBSOLETE`,
`CLIENT_SSL_VERIFY_SERVER_CERT`, `CLIENT_REMEMBER_OPTIONS`, plus MariaDB's
`BULK_UNIT_RESULTS` and `RESERVED_1`.

Auth vectors now come from **two independent projects** (go-sql-driver and
rust-mysql-common), which agree.

### Second increment — auth state machine

Three more things the reference caught that the spec alone would not have:

1. **Capabilities are negotiated as an intersection**, never a union. Asking for
   a capability the server lacks makes it misparse our handshake response.
2. **MariaDB signals that its extended capability block is meaningful by *not*
   setting `CLIENT_LONG_PASSWORD`.** Reading those bits whenever they happen to
   be non-zero would misread a MySQL server with junk in its reserved bytes.
   Extended capabilities are now parsed unconditionally into their own field,
   and honouring them is a negotiation decision.
3. **The password is XORed with the nonce (cyclically) before RSA encryption**,
   after appending a NUL. Omitting this makes the server reject an otherwise
   correctly encrypted password — a failure that looks like a crypto bug.

The state machine is **pure**: packets in, actions out, no I/O and no asymmetric
crypto. That is what makes `perform_full_authentication` over a plaintext socket
— awkward to provoke against a real server — an ordinary unit test.

### Third increment — connection lifecycle (Phase 1)

Two bugs that only real servers could have found.

**1. The SSLRequest and the handshake response must carry an *identical*
capability word.** The server commits to whatever the SSLRequest declares, so a
response differing by even one bit fails to parse. Ours differed by exactly
`CLIENT_CONNECT_WITH_DB`, derived later from the presence of a database name —
and the server answered `ERROR 1043 (08S01): Bad handshake`, which points
nowhere near the cause. Both packets are now built through
`MySQLHandshakeResponse41.effectiveCapabilities`, which only ever *removes*
flags, so it can never claim something the server did not offer.

**2. `autoRead` must stay on for the handshake.** During a TLS handshake NIOSSL
consumes bytes and emits no plaintext, so `channelReadComplete` never reaches
our handler, no follow-up read is issued, and the handshake stalls silently.
Read control is switched on the moment authentication succeeds — before anything
can stream, which is the only place it matters.

Also worth recording: `Ssl_accepts` on the server is **not** evidence that our
TLS worked. The container healthchecks use the mysql CLI, which defaults to TLS,
and inflate that counter continuously.

Set `SWIZZLE_MYSQL_TRACE=1` to log packet flow; it found both bugs in minutes
after theorising had failed for far longer.

### Fourth increment — command phase (Phase 2)

**A latent Phase 1 bug that only a Phase 2 test could expose.** On
`caching_sha2_password` *fast_auth_success* (`0x01 0x03`) we were replying with
an empty packet. The correct behaviour is **silence** — the reference's
`drop_packet` reads and never writes. The extra packet consumed a sequence
number the server never expected, and the desync was invisible until the *next*
command, which failed with `ERROR 1156 Got packets out of order`.

Authentication itself still succeeded, so every Phase 1 test passed. Worth
remembering: a handshake that completes is not proof the handshake was correct.
MariaDB was unaffected because its users authenticate with native password and
never reach that branch — the divergence between flavours is what localised it.

**Never advertise a capability without an implementation behind it.** We
requested `MARIADB_CLIENT_EXTENDED_METADATA`, which makes MariaDB append extra
fields to every `ColumnDefinition41`. With no parser for them, every subsequent
field was read at the wrong offset, so column type, charset and length came back
as plausible-looking garbage rather than an error. `swizzleMariaDBDefault` is now
empty, with each extension to be enabled alongside its implementation.

Also confirmed against real servers: `SERVER_MORE_RESULTS_EXISTS` handling — a
stored procedure returns its rows plus a trailing status set, and the connection
stays usable afterwards because both are drained.

### Sixth increment — streaming (Phase 5)

The requirement this driver exists for. `MySQLRowSequence` is an `AsyncSequence`
over `NIOThrowingAsyncSequenceProducer`, with backpressure ported from
PostgresNIO's `AdaptiveRowBuffer`.

The strategy's shape matters more than its constants:

- **`didYield` always returns false.** Production never resumes just because
  rows arrived — only because the consumer took some. That single rule is what
  makes delivery demand-driven rather than a race between socket and consumer.
- Draining to empty **doubles** the window, so a fast consumer stops paying a
  round trip per batch; overshooting **halves** it, but only after a yield has
  been seen since the last growth, so one burst cannot collapse it.

**Proving backpressure is real needed a specific test.** Streaming rows and
counting them proves nothing — an unbounded producer passes that too. The
evidence is an *unconsumed* stream: with 10,000 rows and zero consumption, the
producer stalls at its window, so the connection stays busy and a concurrent
command is still rejected after a deliberate delay. Had it run away, everything
would have buffered, the stream would have completed, and the connection would
be idle.

**Abandoning a stream drains it.** MySQL cannot abort a result set mid-flight,
so a `break`, a thrown error or task cancellation triggers a background drain.
Skipping it would leave rows queued for whatever command ran next on that
connection — silent cross-talk rather than an error.

Two of the failures here were fixture bugs worth noting: generating rows with
`LIMIT` over a cross join yields an *arbitrary* slice (we got 500–999, not
0–499), and asserting serial semantics after consuming a row is racy, because
consuming can let a small result set finish and legitimately free the
connection.

### Seventh increment — wiring the leftovers

A sweep to close everything that existed only as an encoder or a config field.
Cursor streaming (`COM_STMT_FETCH`), `COM_STMT_RESET`, `COM_SET_OPTION`,
`COM_CHANGE_USER`, `sha256_password`, session-state tracking and connection
attributes are now all exercised against real servers.

Four bugs this surfaced, each invisible until something actually used the code:

1. **An OK terminator was only recognised with a `0x00` header.** Under
   `DEPRECATE_EOF` the OK header is `0xFE`, which `COM_SET_OPTION` replies with —
   so it fell through and tried to read `0xFE` as a length-encoded column count,
   failing with a misleading "invalid column count".
2. **`COM_CHANGE_USER` needs the full auth-switch exchange.** The server answers
   with an `AuthSwitchRequest` carrying a *fresh* scramble, because the target
   account's plugin and salt are unknown until the username is read. It also
   requires the same three auth-response encodings as the handshake **and** the
   connect-attribute block, since we advertised `CLIENT_CONNECT_ATTRS`. Missing
   the attributes produced `Access denied ... (using password: NO)` — which
   reads like a credentials problem, not a truncated packet.
3. **`SESSION_TRACK` was negotiated but not parsed.** With it, the OK packet's
   `info` field is length-encoded and may be followed by a state-change block;
   parsing the non-tracking form swallows the changes into the info string.
4. **`sha256_password` has no fast path** — unlike `caching_sha2_password` it
   always goes cleartext-over-TLS or through the RSA exchange, and its
   `AuthMoreData` *is* the public key rather than a `0x03`/`0x04` marker.

Cursor mode is deliberately **not** the default. It is genuinely row-bounded, but
MySQL frequently materialises a temp table to hold the cursor open — trading
server memory for client memory. Socket backpressure remains the default.

### Eighth increment — pooling (Phase 6)

`MySQLClient` owns a `ConnectionPool` and hands out connections for the duration
of a closure. The pool is **vendored** from postgres-nio rather than depended on
— see `Sources/SwizzleConnectionPool/README.md` for why, and for the one edit
that was unavoidable.

**Session hygiene is the point.** `COM_RESET_CONNECTION` runs before a connection
goes back to the pool, clearing temp tables, session variables and user
variables — and the prepared-statement cache with them, since the server
deallocates every statement. Two tests rather than one: state does *not* leak
with reset enabled, and *does* leak with it disabled. Without the second, the
first would pass just as well if the pool happened to open a fresh connection.

Two API details worth recording:

1. **`PooledConnection.id` must be the pool's id, not the server's.** The pool
   assigns an id, passes it to the connection factory, then looks the connection
   up by `connection.id`. Returning the server's `CONNECTION_ID()` instead trips
   `preconditionFailure("There is a new connection that we didn't request!")` —
   a crash, because the pool treats the mismatch as an invariant violation
   rather than a lookup miss.
2. **`maximalStreamsOnConnection` is 1.** MySQL has no pipelining, so a
   connection can never serve two borrowers concurrently.

Connections are returned after an *application* error but closed after a
`MySQLProtocolError`, since the latter can leave unread packets queued and the
damage would land on the next borrower.

**Observability is real, not a no-op.** `MySQLPoolMetrics` implements the
delegate, emitting `swift-metrics` counters and gauges *and* keeping a live
`MySQLPoolStatistics` snapshot. `MySQLClient` fixes its delegate to that concrete
type rather than becoming generic, so it stays spellable while callers still get
metrics out — configuration happens through the sinks, not a type parameter. The
snapshot matters for testing: connection and keep-alive counts can be asserted
directly instead of inferred from a metrics backend.

**Writing that test exposed a production bug.** With an unreachable database the
pool retries with backoff and keeps waiters queued indefinitely, so a single
query took **78 seconds** to fail — meaning a real outage would hang every
request rather than failing fast. `connectionAcquisitionTimeout` (10s default)
now bounds the wait, and cancelling the race cancels the lease request so a
timed-out waiter cannot leave a connection checked out to nobody. The suite went
from 70 seconds back to 3.

### Ninth increment — transactions (Phase 7)

`withTransaction` commits on success and rolls back on any throw; savepoints
provide nesting. Isolation level and access mode are applied as separate
`SET TRANSACTION` statements *before* `START TRANSACTION`, because they configure
the next transaction rather than the current one.

**"Am I in a transaction" is read from the server, never tracked locally.**
`MySQLSessionState` mirrors `SERVER_STATUS_IN_TRANS` from every command's
terminator. Local bookkeeping would drift precisely where it matters: MySQL has
no transactional DDL, so `CREATE`/`DROP`/`ALTER`/`TRUNCATE` commit the
transaction where they stand. Because the server is authoritative, that implicit
commit is *detected* and surfaced as
`transactionEndedUnexpectedly` rather than leaving the caller believing earlier
work is still provisional.

**Nesting is rejected, not flattened.** A second `START TRANSACTION` commits the
outer one in MySQL, so a nested call that appeared to work would silently commit
work the caller thought was provisional. `withSavepoint` is the explicit
alternative.

Savepoint names are backtick-quoted and internal backticks doubled — they are
identifiers spliced into SQL, and MySQL accepts no placeholder there, so a
caller-supplied name is otherwise an injection point.

**A test verifying the wrong thing.** Isolation level was first checked by
reading `@@SESSION.transaction_isolation`, which reports `REPEATABLE READ` for
every level: `SET TRANSACTION ISOLATION LEVEL` without a scope keyword applies to
the next transaction only and deliberately leaves the session variable alone. It
is now verified behaviourally — `READ UNCOMMITTED` can dirty-read another
connection's uncommitted row and `REPEATABLE READ` cannot, which tests the
semantics rather than a variable.

Tables are created `ENGINE=InnoDB` explicitly; MyISAM ignores transactions
entirely and would make every test here pass for the wrong reason.

### Fixtures moved to native MariaDB binaries

Docker and the colima VM are gone. `./Scripts/test-servers.sh` downloads
SHA256-verified MariaDB binaries from the `doze-dev/doze-binaries` release and
runs three versions on separate ports: **11.4.12** (LTS, ed25519 only),
**11.8.8** (LTS, + parsec) and **12.2.2** (current, + parsec). No VM, ~4.3s
suite, and better MariaDB version coverage than before.

**Accepted cost:** MariaDB implements neither `caching_sha2_password` nor
`sha256_password`, so those paths — and the RSA full-authentication exchange —
have no live server here. They remain implemented and covered by known-answer
unit tests from go-sql-driver and rust-mysql-common vectors, but are no longer
exercised end to end. Restoring that means putting a MySQL server back in the
matrix.

Three differences between a raw install and a Docker image cost real time:

- **Anonymous accounts.** `mariadb-install-db` leaves `''@'localhost'`, which
  match *before* any `'%'` host pattern for localhost connections — so a
  correctly seeded user is rejected with "Access denied for user
  'native'@'localhost'" despite existing. The images run that hardening for you.
- **`performance_schema` is OFF by default** in MariaDB, so the connection
  attribute test read nothing until it was enabled explicitly.
- **Unix socket paths cap at 103 bytes on macOS**, and a socket inside the
  project directory silently aborts startup with "socket file path is too long".

### Test-infrastructure fixes found here

Two problems surfaced that had nothing to do with transactions:

1. **`defer { Task { try? await connection.close() } }` leaks connections.** The
   detached task may run long after the test ends, so connections accumulate
   across parallel tests — `max_used_connections` reached 97 of 151. Replaced
   throughout with `defer { connection.closeImmediately() }`, which initiates
   teardown synchronously.
2. **The containers were OOM-killed (exit 137).** The colima VM is 2 GiB — an
   earlier `colima start --memory 4` printed "already running, ignoring", so the
   sizing never applied — and four servers with default InnoDB buffer pools do
   not fit. All four now run `--innodb-buffer-pool-size=64M`.

Worth noting the availability gate earned its keep: requiring **all four**
servers meant a dead `mysql84` skipped 112 tests loudly instead of quietly
testing three servers and reporting green.

Note one inconsistency in the reference itself: `Column`'s *serializer* writes
`column_length` before `character_set`, the reverse of its own *parser* and of
the MySQL documentation. The parser is authoritative for a client, so that is
what we follow.

### Fifth increment — prepared statements (Phase 4)

Text and binary rows now share one `MySQLRow` type. The formats differ entirely
on the wire but produce the same values, and a prepared statement returning the
same data as a plain query should be indistinguishable to a caller.

**Statement lifetime is a protocol concern, not a memory one.** A prepared
statement is a server-side allocation, so the cache hands back whatever it
evicts and the caller sends `COM_STMT_CLOSE`. Three bugs came out of taking that
seriously:

1. **`COM_RESET_CONNECTION` deallocates every statement server-side**, so the
   cache has to be dropped with it. Ours wasn't, and the failure surfaced as
   `ERROR 1243 Unknown prepared statement handler` on a later, unrelated query —
   exactly what the code comment predicted before the call site was written.
2. **With caching disabled, `insert` was returning the statement as "evicted"**,
   so `prepare` closed the very statement it was about to return. The test that
   should have caught it only compared statement ids; it took *executing* the
   statement to expose it. Comparing identity is not the same as using it.
3. **`MySQLValue.string` returned nil for temporals.** A DATETIME read back over
   the binary protocol must stringify the same way it does over the text one.

**A test of ours was unsound**, separately from the bugs: it asserted against
`Prepared_stmt_count`, which is a **global** status variable rather than
per-session, so parallel test connections polluted it. Replaced with
connection-local statement identity, which proves the same property
deterministically.

---

## 1. Auth plugins

| plugin | status | notes |
|---|---|---|
| `mysql_native_password` | ✅ | known-answer tested against two independent projects |
| `caching_sha2_password` (fast path) | ✅ | known-answer tested; `fast_auth_success` handled |
| `caching_sha2_password` (full auth) | ✅ | RSA-OAEP via swift-crypto's `_RSA`. **Live-verified on MySQL 8.4 and 9.1**, both branches: cold cache over plaintext (`perform_full_authentication` → request public key → XOR with nonce → RSA encrypt → OK) and cold cache over TLS (cleartext inside the session, RSA skipped). The cache is cleared with `FLUSH PRIVILEGES` from a second connection, which is the only way to force the cold path from outside |
| `sha256_password` | ✅ | **distinct from caching_sha2** — the older MySQL 5.7 plugin, with no fast path at all. Live-verified on MySQL 8.4 and 9.1: plaintext, TLS, and a unix socket. The socket case is not the same as caching_sha2's — see §7 |
| `mysql_clear_password` | ✅ | gated: refused unless explicitly enabled **and** the transport is TLS or a unix socket |
| `client_ed25519` (MariaDB) | ✅ | pure Swift (`Ed25519Core`), no C dependency. Verified two ways: the public key we derive from the password matches the one MariaDB stores in `mysql.global_priv`, and swift-crypto validates our signature. Live against 11.4 / 11.8 / 12.2, plaintext and TLS — see §2 |
| `parsec` (MariaDB 11.6+) | ✅ | PBKDF2-SHA512(1024 << factor) → 32-byte seed → *standard* ed25519, so swift-crypto signs it directly — no libsodium. The only two-round-trip plugin: empty first response, then `AuthMoreData` carries the salt. Live against 11.8 and 12.2 |
| `mysql_old_password` (pre-4.1) | ❌ | removed from MySQL 8.0; insecure |
| `dialog` / Kerberos / LDAP SASL / OCI | ❌ | enterprise plugins, out of scope |

### Auth-switch mid-handshake ✅

The server can demand a different plugin *after* the greeting, with a fresh
scramble (packet `0xFE` during auth). Not optional — MySQL 8 sends it routinely
when the account's plugin differs from the default.

Handled, and **permitted at most once**: `mysql_async` treats a second switch as
unreachable, and allowing repeats would let a server walk a client down to a
weaker plugin. The response is recomputed with the *new* scramble.

### Only two plugins are honoured from the greeting ✅

The initial handshake may name a plugin, but we accept only
`caching_sha2_password` and `mysql_native_password` there; anything else falls
back to native. This matches `rust-mysql-async` `conn/mod.rs` line by line,
including the reasoning: `sha256_password` is deprecated as a server default,
and every other plugin — `client_ed25519`, `parsec`, `mysql_clear_password` —
reaches the client through an `AuthSwitchRequest` instead.

Worth writing down because it is counter-intuitive: a unit test that hands the
state machine a greeting naming `sha256_password` and expects the sha256 flow is
testing a path that cannot occur. Falling back rather than failing also means a
server naming something unknown still connects, instead of erroring on a plugin
it was never going to use.

---

## 2. `client_ed25519` — done, in pure Swift

The earlier inference was right. From PyMySQL's `_auth.py` (RFC 8032 §5.1.6):

```
h = SHA512(password)
s = clamp(h[:32])                      # scalar
r = SHA512(h[32:] || scramble)         # nonce
r = scalar_reduce(r)
R = scalarmult_base_noclamp(r)
A = scalarmult_base_noclamp(s)         # public key
k = scalar_reduce(SHA512(R || A || scramble))
S = scalar_add(scalar_mul(k, s), r)
signature = R || S                     # 64 bytes
```

So it *is* standard ed25519 seeded with password bytes rather than a 32-byte seed.

**Confirmed blocker:** this needs raw group/scalar operations —
`scalar_reduce`, `scalar_mul`, `scalar_add`, `scalarmult_base_noclamp`.
swift-crypto exposes none of them: `Curve25519.Signing.PrivateKey` only takes a
32-byte `rawRepresentation` and expands internally, `_CryptoExtras` is an export
shim, and the BoringSSL internals aren't public.

How the references solve it:
- PyMySQL → **pynacl** (libsodium `crypto_core_ed25519_*`)
- rust-mysql-common → **curve25519-dalek**

**Resolved twice.** First with libsodium (via swift-sodium's `Clibsodium`),
which worked but cost a C dependency — and that dependency turned out to be the
*single* thing blocking a fully-static Linux build, since the static SDK's musl
sysroot has no libsodium.

So it was replaced with `Ed25519Core.swift`, a Swift port of TweetNaCl's signing
path (public domain). The driver now has no C dependency here and builds
identically on macOS, glibc Linux and static musl Linux.

swift-crypto covers every other primitive the driver needs — SHA-1/256/512,
PBKDF2, `Curve25519.Signing` for `parsec`, `_RSA` OAEP for caching_sha2 full
auth. `client_ed25519` is the sole exception, and only because
`Curve25519.Signing.PrivateKey` takes a 32-byte seed it expands itself, with no
entry point for an already-expanded key. Proven rather than asserted: at exactly
32 bytes the two schemes coincide, and `SwiftCryptoEquivalenceTests` shows our
output is byte-identical to BoringSSL's.

Writing curve arithmetic by hand is normally a bad idea in a database driver.
What made it acceptable was that libsodium was still present at the time, so the
two could be compared directly across ~900 randomised inputs — byte-identical
throughout — and libsodium's outputs frozen as permanent known-answer vectors
before it was removed. Full reasoning and the one deliberate divergence (zero
scalar) in `docs/platforms.md`.

`Sources/SwizzleMySQL/Auth/MySQLEd25519.swift`. Verifying this needed care,
because a signature that is merely *well-formed* looks identical to a correct
one until a server rejects it. Three independent checks:

1. The public key we derive for password `ed25519pass` equals the value MariaDB
   itself stores in `mysql.global_priv`
   (`/JMmQAHuIaOsVNKyutTNtcJOKU9Js5bt8LwRQGRyYB8`) — this pins the *derivation*.
2. swift-crypto verifies the signature we produce — this pins the *signing*.
3. Live authentication against 11.4 / 11.8 / 12.2, plaintext and TLS, with a
   wrong-password case that must be rejected — without that negative test, checks
   1 and 2 would still pass if we sent a valid signature over the wrong message.

### `parsec` — no libsodium needed

Worth stating plainly, since the two plugins are easy to conflate: parsec runs
the password through PBKDF2-HMAC-SHA512 first, which produces a *proper 32-byte
seed*. From there it is ordinary ed25519, so `Curve25519.Signing.PrivateKey`
handles it and the libsodium path is not involved. The scalar-arithmetic problem
above is specific to `client_ed25519` seeding the expansion with password bytes.

Its distinguishing feature is the round trip count. Every other plugin answers a
challenge in one packet; parsec cannot, because the `AuthSwitchRequest` carries
only the scramble — the salt and iteration factor arrive in a *second* server
message. So the client sends an **empty packet** first and waits. Sending
anything else there is a protocol error, the same trap as `fast_auth_success`
(§0).

---

## 3. Commands

| command | status | notes |
|---|---|---|
| `COM_QUERY` | ✅ | text protocol, all four servers |
| `COM_STMT_PREPARE` / `EXECUTE` / `CLOSE` | ✅ | binary protocol, all four servers |
| `COM_STMT_RESET` | ✅ | wired via `resetStatement`; clears an open cursor before re-execute |
| `COM_STMT_FETCH` | ✅ | **cursor-based streaming.** Encoder in place; `CURSOR_TYPE_READ_ONLY` wiring lands in Phase 5 |
| `COM_STMT_SEND_LONG_DATA` | ✅ | oversized byte parameters are chunked automatically when a request would exceed one packet |
| `COM_PING` | ✅ | pool keep-alive |
| `COM_RESET_CONNECTION` | ✅ | **pool hygiene** — clears temp tables, session vars, prepared statements when a connection returns to the pool. Wired up; used by the pool in Phase 6 |
| `COM_CHANGE_USER` | ✅ | heavier reset; also re-authenticates |
| `COM_INIT_DB` | ✅ | `USE <db>` |
| `COM_QUIT` | ✅ | graceful close. The opcode existed from the start and **nothing ever sent it** — this row was ✅ for a year on the strength of the enum case alone. See the audit note below |
| TLS shutdown timeout | ✅ 250 ms | NIOSSL waits 5 s for a `close_notify` MySQL never sends. Measured: 5.0012 s per TLS close, 0.0001 s plaintext |
| `COM_STMT_BULK_EXECUTE` | ✅ | MariaDB-only, gated on `MARIADB_CLIENT_STMT_BULK_OPERATIONS`. Rows are auto-split to fit `max_allowed_packet`. Verified against the server's `Com_stmt_execute` counter — 500 rows must not raise it 500 times |
| `COM_SET_OPTION` | ✅ | toggles multi-statements |
| `COM_SHUTDOWN`, `COM_DEBUG`, `COM_PROCESS_KILL` | ❌ | admin commands, not a driver concern. (`COM_BINLOG_DUMP`, `COM_BINLOG_DUMP_GTID` and `COM_REGISTER_SLAVE` **are** implemented — see §5b) |

---

## 4. Column types ✅

All 36 type codes modelled in `MySQLColumnType`, including `VECTOR` (MySQL 9.0)
and `TYPED_ARRAY`. Text decoding verified against all four servers; binary
decoding is unit-tested and gets its end-to-end run with prepared statements in
Phase 4.

Decisions worth keeping:

- **`DECIMAL`/`NEWDECIMAL` never touch `Double`.** They travel as text and stay
  `.bytes`. `12345678901234567890.1234567890` round-trips exactly; via `Double`
  it would not. A silently lossy money column is the kind of bug that surfaces
  in an audit rather than a test.
- **Temporal values are not `Foundation.Date`.** MySQL permits `0000-00-00` and
  zero months/days, which `Date` cannot represent, so eager conversion would
  either throw on legal data or invent a value. `MySQLDateTime` keeps the
  components.
- **`TIME` is a signed duration, not a clock time** — range ±838:59:59, so it
  carries a sign and a whole-days field. Its binary form uses **8/12**-byte
  lengths, *not* DATETIME's 7/11.
- **DATETIME binary length is 0/4/7/11** by precision. The payload is consumed
  as a fixed-size slice so an unfamiliar length cannot desynchronise the row.
- **`INT24` occupies 4 bytes on the wire** despite being a 3-byte column type.
- **Signedness comes from the `UNSIGNED` *flag*, not the type.** `YEAR` is
  unsigned on every server tested; `BIGINT UNSIGNED` holding 2^64-1 is only
  decodable because of it.
- **A BLOB is told from a TEXT solely by charset 63 (`binary`)** — they share a
  column type. Same for VARBINARY vs VARCHAR.
- Unknown type codes degrade to `.unknown` and raw bytes rather than failing the
  result set, so a newer server type does not break an entire query.

### NULL bitmap

Offset **2** for server-side result rows (the first two bits are reserved),
offset **0** for client-side `COM_STMT_EXECUTE` parameters, with
`byteCount = (columns + 7 + offset) / 8`. NULL columns occupy **no payload
bytes**, so reading the bitmap with the wrong side shifts every subsequent value
and returns plausible wrong data rather than erroring.

---

## 5. Connection features

| feature | status | notes |
|---|---|---|
| TLS | ✅ | including the capability-flag handshake upgrade before auth |
| Connection attributes | ✅ | `_client_name` etc. Shows up in `performance_schema`; cheap and good for ops |
| Session state tracking | ✅ | `SESSION_TRACK` — how you learn autocommit/schema/charset changed |
| Multi-resultset | ✅ | `SERVER_MORE_RESULTS_EXISTS`. **Stored procedures always return an extra status resultset** — MySQLNIO issue #118 is a crash from exactly this |
| `LOAD DATA LOCAL INFILE` | ✅ | **security-relevant.** Defaults OFF and needs an explicit allow-list; the capability is not even advertised unless enabled. Paths are compared standardised, so `/tmp/./x` cannot slip past a list containing `/tmp/x` |
| Compression (zlib) | ✅ | Off by default. Verified by the server's own `Compression = ON` session status, not just by queries succeeding |
| Compression (zstd) | ✅ | MySQL 8.0.18+. Vendored zstd (BSD). Verified against the server's own `Compression_algorithm` status variable, which also distinguishes it from zlib. On MariaDB the capability is simply never advertised and the connection stays uncompressed rather than failing |
| MariaDB progress reports | ✅ | Opt-in via `onProgress`. Requesting the capability is what makes error code `0xFFFF` mean "progress" instead of an error, so it is only asked for when someone is listening |
| Prepared-statement cache | ✅ | LRU keyed on query text, default capacity 256, configurable (0 disables). Eviction closes the evicted statement server-side |

### zstd: why vendoring was the only option

zlib is free everywhere — the macOS SDK, the Swift Docker image, and (verified)
the static musl sysroot all carry it, so `CZlib` is a two-line `systemLibrary`.

**zstd is available nowhere.** Not in the macOS SDK, not in Apple's
`Compression` framework (LZFSE/LZ4/LZMA/ZLIB/BROTLI only — no ZSTD), not in the
musl sysroot, not in the Swift Docker image. A `systemLibrary` target has
nothing to link against, so vendoring the C is the only route that preserves
"no system dependencies, builds on static musl".

The file selection and flags follow the recipe in
[`compressionz`](https://github.com/NerdMeNot/compressionz) (Apache 2.0): 26
sources from `lib/{common,compress,decompress}` and three defines —
`ZSTD_MULTITHREAD=0`, `ZSTD_LEGACY_SUPPORT=0`, and critically
`ZSTD_DISABLE_ASM`, which skips zstd's hand-written amd64 assembly so the same
sources build for aarch64, x86_64 and musl alike. That is the same lesson as
libsodium's ref10: choose the portable implementation, not the fast one, when
the constraint is "must build everywhere".

One portability trap it did not cover: `SIZE_MAX` resolves for Swift on Darwin
but **not on musl**, so a sentinel that compiled on macOS broke the static Linux
build. It is now returned by a C accessor instead.

### The original reasoning, kept for the record

1. **No reference implements it.** `rust-mysql-common` defines
   `CLIENT_ZSTD_COMPRESSION_ALGORITHM` as a constant, but its codec only ever
   constructs a `ZlibEncoder`; go-sql-driver, node-mysql2 and PyMySQL have
   nothing. So there was no port to check against — which is why the
   implementation is verified purely against the server's own
   `Compression_algorithm` status variable.
2. **MariaDB has no zstd connection compression at all** — it is MySQL 8.0.18+,
   and at the time the matrix was MariaDB-only. That argument dissolved once
   MySQL 8.4 and 9.1 joined the matrix.
3. It needs libzstd, which zlib does not. Still true — hence vendoring.

That prediction held exactly: the frame header carries a length and a stored
flag but no algorithm, so adding zstd was one branch in `MySQLCompression` plus
a capability bit — and a single trailing byte in the handshake response carrying
the compression level, which is the only payload difference between requesting
zlib and requesting zstd.

### The compression trap worth remembering

Compression wraps the **byte stream**, not individual packets: one frame can
carry several packets, and one packet can span frames. A packet-to-packet
implementation works for small queries and fails the moment a result set crosses
a frame boundary — which is why the decoder emits `ByteBuffer` into the ordinary
packet decoder rather than producing packets itself.

Two smaller ones: the compression sequence id is a **separate counter** from the
packet sequence, and a zero `uncompressed_length` means *stored*, not *empty*.

### The LOCAL INFILE trap worth remembering

Refusing a file request does **not** mean staying silent. The server is
mid-transfer and waiting, so the terminating empty packet must be sent even on
refusal, and the server's reply consumed, before the error is reported. Skipping
that leaves the connection permanently one reply out of step — every later query
returns the previous one's answer. This is why the refusal lives in the command
handler and not in the result-set state machine, and why there is a test that
runs five queries *after* a refusal.

---

## 5b. Binlog / replication (Phase 10)

| piece | status | notes |
|---|---|---|
| `COM_REGISTER_SLAVE` | ✅ | host/user/password left empty, as real clients do |
| `COM_BINLOG_DUMP` | ✅ | file + position; position clamped to ≥ 4 since every binlog opens with a 4-byte magic |
| `COM_BINLOG_DUMP_GTID` | ✅ | MySQL only. **MariaDB has no such command** — it takes the position from `@slave_connect_state` and issues an ordinary dump |
| CRC32 checksums | ✅ | verified and stripped on every event, via zlib's `crc32` (already linked for compression) |
| Event header (19 bytes) | ✅ | including the `artificial` flag, which marks the synthetic ROTATE/FDE a dump opens with |
| `FORMAT_DESCRIPTION` | ✅ | announces the checksum algorithm **in its own last byte** — a bootstrap: it must be parsed before the algorithm it declares is known |
| `ROTATE` | ✅ | tracks the current filename |
| `QUERY` | ✅ | status variables skipped, not parsed |
| `XID` | ✅ | transaction commit |
| `TABLE_MAP` | ✅ | 6-byte table id, per-column type metadata, null bitmap |
| Row events v1 + v2 | ✅ | WRITE/UPDATE/DELETE; UPDATE carries both before and after images |
| GTID events | ✅ | both dialects — MySQL UUID + sequence, MariaDB domain/server/sequence |
| Heartbeat | ✅ | does **not** advance the resume position; treating it as progress skips events |
| `AsyncSequence` + backpressure | ✅ | fixed window rather than the row buffer's adaptive one — a binlog is an open-ended tail, and events vary hugely in size |
| MariaDB compressed events (`log_bin_compress`) | ✅ | row events **and** `QUERY_COMPRESSED`. Only the variable-length tail is deflated — the post-header, column count and bitmaps stay in the clear. A fixture runs with compression on permanently |
| MySQL binary JSON (JSONB) | ✅ | **The bigger half of the "partial JSON" item, and it was hiding underneath it.** MariaDB stores `JSON` as text; MySQL stores a compact binary tree, and both report `MYSQL_TYPE_JSON`. Without decoding it, *every* JSON column in a MySQL CDC stream was unreadable bytes — on the default configuration. Round-tripped through both flavours across nesting, all scalar types, escaping, multi-byte UTF-8, 70 KB documents and 200-key objects |
| `PARTIAL_UPDATE_ROWS_EVENT` | ✅ | Diffs decoded and surfaced per row and column. **No reference client parses this** — `rust-mysql-common` hands the rows blob back raw — so the layout was established from the wire; see below |
| `TRANSACTION_PAYLOAD` (compressed txns) | ✅ | A whole transaction — table maps, row events, XID — arrives as one zstd-compressed container and is **expanded into its constituent events**, so a consumer never sees the container. Toggled per-connection in the tests rather than baked into the fixture, so the uncompressed path stays covered too |
| LOAD DATA event family | ❌ | **cannot occur** under `binlog_format=ROW` — verified: `LOAD DATA LOCAL INFILE` produced ordinary write row events for all 20 rows. Those events are a STATEMENT-format artefact |

### Two bugs this phase found

**`YEAR` is one byte in a row image, not two.** It is a `SMALLINT` in a result
set, and grouping it with `SMALLINT` here consumed a byte belonging to the next
column — silently misaligning every column after it. A row image is positional
with no delimiters, so a width error corrupts everything downstream rather than
failing where it happens. It only surfaced when the *full* suite ran and a binlog
stream encountered a table another suite had created. `BinlogColumnTypeTests` now
sweeps all 24 types with a **trailing sentinel column**, because a wrong width
still "passes" when the bad column happens to be last.

**A one-in-256 authentication failure**, found by the load this phase put through
the ed25519 path. `AuthSwitchRequest` stripped a trailing NUL unconditionally.
That is right for the classic plugins, which send `scramble || 0x00` — but
MariaDB's `client_ed25519` and `parsec` send a bare **32-byte** scramble. Any
scramble whose last random byte was `0x00` got truncated to 31, producing a
signature over the wrong message and an "Access denied" indistinguishable from a
wrong password. Sequential connections never showed it; 1 in 120 concurrent ones
did, which made it look like a concurrency bug rather than a framing one. Two
existing unit tests had encoded the wrong shape by appending a NUL the server
never sends.

### MySQL joined the matrix, and immediately paid for itself

The four deferrals were originally defended with "MariaDB doesn't have it".
That was the wrong test: **we target MySQL too**, so the honest statement was
"our matrix has no MySQL server" — one systemic gap wearing four disguises, and
it also left `caching_sha2_password` full auth, `sha256_password`, zstd,
MySQL-dialect GTIDs and `COM_BINLOG_DUMP_GTID` permanently unverifiable.

Two MySQL fixtures now run alongside the three MariaDB ones (8.4 LTS and 9.1,
native binaries, no Docker). What that immediately produced:

- **`caching_sha2_password` full auth and `sha256_password` are now live**, both
  over plaintext and TLS, including the cold-cache RSA exchange — the most
  intricate path in the handshake, previously unit-tested only.
- **A real driver bug**: `binlogPosition()` used `SHOW BINLOG STATUS` falling
  back to `SHOW MASTER STATUS`. MySQL 8.4 **renamed** it to `SHOW BINARY LOG
  STATUS` *and removed* the old name, so binlog positioning failed outright on
  every current MySQL.
- **A crash across a dozen suites**: tests force-unwrapped a
  `mysql_native_password` fixture user. MySQL 9.0 removed that plugin entirely,
  so no such user can exist there. Tests now ask for `primaryUser` unless they
  are specifically exercising a plugin.
- **Confirmation that two of the four deferrals are real gaps, not
  hypotheticals** — see the table above. Both are non-default settings, so the
  fixtures run stock and the gaps are recorded rather than papered over.

Two more MySQL-side facts worth knowing: 9.0 removed `mysql_native_password`, and
`SHOW MASTER STATUS` is gone from 8.4 — a client written against MySQL 5.7/8.0
assumptions breaks on both counts.

### `PARTIAL_UPDATE_ROWS_EVENT`, reverse-engineered

No reference client parses this event — `rust-mysql-common` treats it as a plain
rows event and returns the blob — so the layout came from bytes. A captured
event, MySQL 8.4, one `JSON_SET` on a 2 KB document:

```
b4 02 00 00 00 00   table id
01 00               flags
02 00               extra-data length (2 ⇒ none)
02                  column count
ff ff               before- and after-image bitmaps
00                  null bitmap        ← the before-image starts here
01 00 00 00         id = 1
f0 07 00 00         JSON length prefix = 2032
…2032 bytes…        the before document
                    ── after-image, 27 bytes ──
01                  value_options = PARTIAL_JSON_UPDATES
01                  partial bitmap: JSON column 0 is a diff
00                  null bitmap
01 00 00 00         id = 1
10 00 00 00         diff-list length = 16   (the JSON column's own 4-byte prefix)
00                  operation = REPLACE
06 "$.name"         lenenc path
07 0c 05 "grace"    lenenc value → JSONB string
```

Two things are easy to get wrong and both were:

1. **`value_options` and the partial bitmap precede *each after-image*, not the
   event.** Putting them in the header — which is how the field is usually
   described — mis-frames the very first row. The multi-row test exists
   specifically to pin this: with a per-event reading, row two decodes as
   nonsense.
2. **The diff list is length-prefixed by the JSON column's own prefix width**
   (normally 4 bytes), *not* a length-encoded integer. Reading it as lenenc
   works for diffs under 251 bytes and then silently mis-frames everything
   after — the same shape of bug as the big-endian compressed length.

Bit 0 of `value_options` being clear is normal, not an error: MySQL falls back to
a full after-image whenever a diff would not be smaller than the document.

The diffs are **surfaced, not applied**. `rows` carries the complete
before-image and `jsonDiffs` the changes, keyed by row then column. Applying them
needs a JSON path evaluator and a mutable document model, and a consumer
forwarding changes downstream generally wants the diffs themselves — so
collapsing them would discard information that cannot be recovered.

### A fixture-capacity finding

The suite outgrew MySQL's default `max_connections` of 151: cases run in
parallel across five servers and legitimately open hundreds of short-lived
connections, which surfaced as *unrelated* tests failing with "Too many
connections" about one run in three. The fixtures now run with 512.

Worth noting the error was legible at all only because of the earlier handshake
fix — a server refusing a connection sends an ERR packet *instead of* a
greeting, and before that change this read as "unsupported protocol version
255".

### Re-examining the deferrals

The four items originally written off as deferred were not equally justified,
and checking them rather than asserting them changed one outcome:

- **LOAD DATA family** — confirmed unreachable. Under `binlog_format=ROW` a
  `LOAD DATA LOCAL INFILE` emits ordinary write row events; the LOAD DATA event
  types only appear in STATEMENT format, which no CDC consumer uses.
- **Partial JSON** and **`TRANSACTION_PAYLOAD`** — confirmed MySQL-only. Neither
  `binlog_row_value_options` nor `binlog_transaction_compression` exists on
  MariaDB, so the MariaDB-only matrix has no server that can produce them.
  Shipping unverifiable decoders for either would repeat the zstd mistake.
- **MariaDB compressed events** — **this one was wrong, and has been fixed.**
  `log_bin_compress` does exist, is a legitimate production setting, and was
  trivially enabled on a fixture. With it on, the driver was returning *zero row
  changes and no error*: events flowed, nothing failed, every change was lost.
  Silent data loss is the worst outcome for CDC, and "surfaced as `.other`" was
  a euphemism for it.

The layout, once looked at rather than assumed: table id, flags, column count
and the column bitmaps are **not** compressed; only the rows section is, behind
a one-byte header whose top bits mark zlib and whose low three bits give the
width of the uncompressed-length field. `QUERY_COMPRESSED` is the same idea with
only the statement text deflated.

### A test-infrastructure bug this found

macOS ships **bash 3.2**, where `"${arr[@]}"` on an *empty* array is an
"unbound variable" error under `set -u`. Adding a per-server flags array
therefore stopped the two servers that receive no extra flags — with no error
message pointing at the cause. The 3.2-safe form is `${arr[@]+"${arr[@]}"}`.

### A diagnostic improvement

A server refusing a connection sends an **ERR packet instead of a greeting**.
Reading its `0xFF` as a protocol version reported "unsupported protocol version
255" — which cost real time here when a test run exhausted `max_connections`.
The handshake now parses that packet and surfaces the server's actual message.

---

## 6. ANSI_QUOTES — resolved, and it was a false alarm

The plan flagged this as an open risk: the renderer hardcodes a backtick for
MySQL, so under `ANSI_QUOTES` a generated query might parse as *something else*
rather than erroring. The proposed fix was to detect the mode and **reject the
connection**.

Tested instead of assumed, on MariaDB 12.2 and MySQL 9.1 with `ANSI_QUOTES`
active:

| what | result |
|---|---|
| Backtick-quoted identifiers | ✅ still work |
| Bound parameters (`?`) | ✅ still work |
| Double-quoted string literal | ❌ becomes an identifier and errors |

`ANSI_QUOTES` **adds** `"` as an identifier quote; it does not remove the
backtick. And the builder never emits a string literal — every value goes
through a bound parameter, which is what makes it injection-safe in the first
place. So the two properties that already existed for other reasons make the
generated SQL `ANSI_QUOTES`-safe, and rejecting the connection would have
refused a perfectly workable server for no benefit.

**Decision: no rejection, no connection-dependent quoting.** Backtick quoting
stays, and the risk is closed.

`MySQLConnectionMetadata.isANSIQuotes` is kept, and verified to work — a
connection to a server with `ANSI_QUOTES` in its **global** `sql_mode` reports
`true`. Two caveats worth knowing, since both made it look broken at first:

- It is a **connect-time snapshot**. Setting `sql_mode` on the session
  afterwards does not update it.
- The flag (`SERVER_STATUS_ANSI_QUOTES`, `0x8000`) is **MariaDB-only**; MySQL
  never sets it, so `isANSIQuotes` is always `false` there regardless of the
  server's actual mode.

Neither matters now that nothing depends on it, but a future feature that does
would need to query `@@sql_mode` rather than trust the flag.


### Closing a connection — two bugs behind one symptom

Found by a shadow database calling `destroy()` twice, which hung. Both are worth
recording because neither produced an error, and both had been shipping.

**1. A command on a closed connection hung forever.** `send` wrote its request
with `promise: nil`:

```swift
channel.write(request, promise: nil)
return try await promise.futureResult.get()
```

On a closed channel that write fails, the failure is discarded, the request never
reaches the command handler — so nothing ever fulfils the command promise and the
`await` never returns. A pooled connection that died between being handed out and
being used would hang the request with no timeout underneath and nothing in a log
to explain it; `ping` goes through the same path, so a keep-alive could take the
pool's maintenance loop with it. Fixed by giving the write a promise that fails
the command promise. The two outcomes are mutually exclusive — write succeeds and
the handler owns the request, or write fails and the handler never saw it — so
there is no double-fulfil.

**2. Every TLS connection took five seconds to close.** The checklist said
`COM_QUIT` was done. The opcode was defined; nothing sent it. Without the
goodbye, the server sees the socket vanish and never sends a TLS `close_notify` —
and NIOSSL's graceful shutdown waits five seconds for one. Measured on the
MariaDB fixture: **5.0012 s** with TLS, **0.0001 s** without.

`COM_QUIT` alone did not fix it, which was the useful part of the investigation:
MariaDB answers `COM_QUIT` by closing the socket rather than by shutting TLS down
politely, so the wait was for something that was never coming regardless. Both
changes landed — the goodbye because the protocol asks for it, and
`shutdownTimeout = 250 ms` because that is what actually reclaimed the five
seconds. Short rather than zero, so a peer that *does* reciprocate still gets a
clean shutdown.

The symptom was a suite that hung. Individually every test passed. A `close()`
that returns in five seconds is indistinguishable from a hang, and a `close()`
that never returns looks the same again — which is why one investigation turned
up two unrelated defects.

---

## 7. The RSA public key, and the channel binding MySQL does not have

The starting question was whether to implement channel binding for
`caching_sha2_password`, which an earlier note in this project claimed it
supported. **It does not, and neither does anything else in MySQL.** No auth
plugin in either server carries a channel-binding step, and none of the five
reference clients — `go-sql-driver`, `mysql_async`, `rust-mysql-common`,
`node-mysql2`, `pymysql` — contains the string. The earlier note was wrong.

What MySQL has instead is a hole in the same place, and a different way of
closing it.

### The hole

`caching_sha2_password` on a cold cache, and `sha256_password` always, need the
*cleartext* password at the server. Over TLS or a unix socket it travels inside
the secure channel. Over a plaintext socket it is RSA-encrypted — under a public
key **the server sends during the handshake**. A key that arrives over an
unauthenticated channel authenticates nothing: an attacker in the path answers
with their own key, decrypts the password, re-encrypts it under the server's real
key and forwards it. Both ends see an ordinary successful login.

### What we do about it

`MySQLConnectionConfiguration.serverPublicKey`, defaulting to `.refuse`:

| | our spelling | `mysql` client | Connector/J |
|---|---|---|---|
| know the key in advance | `.pinned(pem:)` / `.pinned(contentsOfFile:)` | `--server-public-key-path` | `serverRSAPublicKeyFile` |
| accept what arrives | `.requestFromServer` | `--get-server-public-key` | `allowPublicKeyRetrieval=true` |
| decline | `.refuse` (default) | the default | the default |

URL parameters carry the ecosystem's own spellings —
`allow_public_key_retrieval` / `allowPublicKeyRetrieval` /
`get_server_public_key`, and `server_public_key_path` / `serverRSAPublicKeyFile`
— because someone porting a JDBC URL or a command line should not have to learn a
third name for the same thing.

With a pin the key is still *requested* and then compared. Encrypting under the
pinned key without asking would be equally safe — a substituted key never gets
used — but it would also be silent, and a mismatch means someone is in the path.
That is worth an error rather than a successful login. Comparison is on parsed
DER, so line width, CRLF and a missing trailing newline do not matter.

Verified against MySQL 8.4 and 9.1, with the cache cleared each time: the default
refuses a real cold-cache exchange; the server's own `public_key.pem` pinned
authenticates; **one fixture's key pinned against the other fixture's server is
refused**, which is a genuine substitution using two genuine keys rather than a
synthetic mismatch; and over TLS even a wrong pin is irrelevant, because no key
is exchanged.

### One deliberate divergence from `libmysqlclient`

Measured, not assumed, on MySQL 8.4 over TCP with `--ssl-mode=DISABLED`:

| plugin | no key option | `--get-server-public-key` |
|---|---|---|
| `caching_sha2_password`, cold cache | `ERROR 2061 … Authentication requires secure connection` | authenticates |
| `sha256_password` | authenticates | authenticates |

So `--get-server-public-key` governs `caching_sha2_password` only;
`sha256_password` retrieves the key unconditionally. Our default refuses **both**.
The exposure is identical either way — the same key over the same unauthenticated
channel — and the asymmetry looks like history rather than a security argument,
`sha256_password` predating the option. Connector/J's `allowPublicKeyRetrieval`
also covers both.

### And a real bug, found because two references disagreed

`go-sql-driver` says "unlike caching_sha2_password, sha256_password does not
accept cleartext password on unix transport". `pymysql` treats the socket as
secure for both. We had followed pymysql. Asked directly, on MySQL 8.4 over the
socket with `--ssl-mode=DISABLED`:

| account | `--server-public-key-path` | result |
|---|---|---|
| `sha256_password` | the server's own key | authenticates |
| `sha256_password` | another server's key | **access denied** |
| `caching_sha2_password` | none at all | authenticates |

A client sending cleartext cannot be denied for holding the wrong key. So
`sha256_password` takes the RSA exchange even over a unix socket, and
`caching_sha2_password` does not — go-sql-driver is right.

Ours had therefore **never worked**: it sent cleartext over the socket and the
server rejected it as a bad password. Nothing caught it because nothing had ever
connected to a socket with that plugin, and the unit test that looked like
coverage asserted the wrong behaviour — `secure: true` there meant a unix socket,
and the test was encoding the bug.

The policy stands aside on a unix socket: the exchange runs, but there is no
network to interpose on, and refusing an *encrypted* exchange there while sending
cleartext over the same socket for the other plugin would be incoherent. A pin, if
one is configured, is still checked.

---

## 8. Line-by-line audit against `rust-mysql-common` + `mysql_async`

References re-fetched first: `rust-mysql-common` was current, `mysql_async` was
11 commits behind and pulled forward — including, as it happens,
`sha256_password` support and `Opts::server_key_path`, which is the same pin §7
had just added independently.

### Enumerable surfaces, compared entry by entry

| surface | reference | ours | |
|---|---|---|---|
| `Command` | 34 | the 15 we issue | the rest are server-internal or removed |
| `ColumnType` | 34 | 34 | exact match, including `VECTOR` and `TYPED_ARRAY` |
| `CapabilityFlags` | 31 | **38** | all 31, plus `MULTI_FACTOR_AUTHENTICATION` (which the reference lacks) and 6 MariaDB flags |
| `StatusFlags` | 15 | 15 | exact |
| `SessionStateType` | 6 | 6 + `unknown` | |
| binlog `EventType` | 41 | **57** | superset; we decode `HEARTBEAT_LOG_EVENT_V2`, which rust marks unsupported |
| JSONB type codes | 10 groups | 14 | ours is more granular, and decodes opaque temporals rather than base64-ing them |
| packets in `packets/mod.rs` | 29 | 26 | the three below |

### Four defects found, all fixed

**1. `BIT` metadata was transposed.** Two bytes, `bits % 8` then `bits / 8`; we
computed `bytes_in_rec + bit_len * 8` where the reference computes
`col_meta[1] * 8 + col_meta[0]`. BIT(1) and BIT(8) survive either reading — both
give one byte — and everything between them does not. BIT(12) is
`bit_len = 4, bytes_in_rec = 1`: correct is 12 bits and two bytes, transposed is
33 bits and five, so the decoder ate three bytes belonging to the next column and
the rest of the row decoded as nonsense. The suite tested `BIT(8)` and nothing
else.

**2. `VECTOR` broke the binlog outright.** MySQL 9's type is metadata-carrying
like a blob — one byte giving the width of the length prefix — and we read no
metadata byte for it, so every column *after* a VECTOR had its metadata read one
byte early. The value itself then hit the decoder's `default:` and failed the
stream. Verified against MySQL 9.1 with a real `VECTOR(4)` column.

**3. `NEWDATE` had no decoder.** Three packed bytes with a different packing from
`DATE` (five bits of day, four of month, the rest year). Old MySQL and MariaDB
still emit it; it failed the stream.

**4. `TYPED_ARRAY` and raw `ENUM`/`SET` metadata widths were wrong**, by 1 + inner
and 2 bytes respectively — alignment bugs of the same shape as the VECTOR one.
`VARCHAR` inside a typed array carries a third metadata byte, which is handled.

### Three packets the reference has and we did not

- **`OldAuthSwitchRequest`** — a bare `0xFE`, meaning "switch to
  `mysql_old_password`". We parsed it as an ordinary switch and reported
  *"missing plugin name"*, which reads like a corrupt packet rather than an
  account on an algorithm MySQL removed in 8.0. Now named, with the `ALTER USER`
  that fixes it. `mysql_async` refuses the same plugin under `secure_auth`; we
  have no opt-out because no supported server still offers it.
- **`ComTableDump`** — `COM_TABLE_DUMP`, deprecated and unused by `mysql_async`
  too. Out of scope.
- **`SemiSyncAckPacket`** — a semi-sync replica ACK. `mysql_async` does not
  implement it either, and the master only sends the semi-sync header to a client
  that asked for it with `SET @rpl_semi_sync_slave = 1`, which we never send. Out
  of scope, and recorded here so it stays a decision.

### The `--ssl-mode` ladder was two rungs short

`mysql_async` has `require_ssl` / `verify_ca` / `verify_identity` and
`libmysqlclient` the same as `--ssl-mode`; we had disable / prefer / require, so a
MySQL connection string could ask for an *encrypted* server but never a
*verified* one. Our own Postgres driver has had the full ladder since it was
written, so this was an inconsistency between our two drivers as much as a gap.

`verifyCA` and `verifyFull` now exist, in the configuration and in the URL under
every ecosystem spelling. Both are tested against real servers, both flavours:
the fixtures present certificates signed by nobody the client trusts, so the
verifying rungs must *reject* them while `require` accepts — and trusting MySQL's
own generated `ca.pem` makes `verify_ca` succeed, which is the half that proves
the mode verifies rather than refuses.

### Checked and found already correct

`TCP_NODELAY`, which every reference client sets explicitly: SwiftNIO's
`ClientBootstrap` sets it by default, so both our drivers already had it. Worth
recording that it was checked rather than assumed — the cost of being wrong is a
40 ms Nagle delay on every small write.

### A divergence from `rust-mysql-common`: the pre-5.6 `TIME` is signed

Found by the mutation sweep, which flagged a comparison that could never be
true. `BinlogRowDecoder` assembled the old `MYSQL_TYPE_TIME` row image from its
three bytes as **unsigned**, which made the `isNegative` test immediately below
it dead code. A negative time therefore decoded as a large positive one:
`-00:00:01` came back as `69 09:56:00`, and `-12:34:56` as `69 09:56:00` — a
plausible-looking value, not an error.

The reference does the same thing. `references/rust-mysql-common/src/binlog/
value.rs:100` reads the field as `RawInt<LeU24>` and passes `false` for the sign
unconditionally, so it carries the identical defect. This is the second time
a reference has been wrong in the same place we were — and the second time
copying it faithfully would have preserved the bug rather than avoided it.

That the field is signed is settled by its own range, which is the kind of
evidence that does not depend on any implementation: the largest legal `TIME`
is `838:59:59`, which packs to `838 * 10000 + 59 * 100 + 59` = 8385959 — just
under 2^23. Unsigned, that headroom has no purpose. Signed, it is exactly a
symmetric range about zero, which is what a duration type needs.

Reachability is narrow: the format only appears in binlogs written before 5.6,
or where `avoid_temporal_upgrade` preserved an old column definition. No fixture
here can produce one, so the decoding is exercised from constructed bytes in
`BinlogTests.oldTimeFormatIsSigned`, with the byte values derived from the
format rather than from our own encoder.

Same sweep, same file, a second finding: `JSONBDecoder` took a packed temporal's
magnitude with `packed < 0 ? -packed : packed`. Negating `Int64.min` overflows
and **traps** — and `packed` is eight bytes read straight out of a JSON document
in a row image, so `00 00 00 00 00 00 00 80` from any peer took the process
down. Now `packed.magnitude`, which is a `UInt64` and has no such edge.

### The same length-conversion trap, in five more places

Fixing `readLengthEncodedSlice` fixed one call site. Grepping for the shape
once it was known found five others, all reachable from a peer:

| site | field |
|---|---|
| `ResultSetStateMachine` | the **column count of every result set** |
| `BinlogRowDecoder` | a JSON diff value's length in a partial-update image |
| `BinlogEvents` ×2 | length fields skipped in the compressed-event header |
| `BinlogEvents` | the uncompressed size in that same header |

A `0xFE`-prefixed length-encoded integer carries a full `UInt64`. `Int(x)` above
`Int64.max` traps — the process ends, and no `catch` sees it. Two of the binlog
sites wrote `min(Int(length), readableBytes)`, where the clamp reads as a bound
and is not one: the conversion happens before `min` is called. They now clamp in
`UInt64` and convert after.

The column count is the one that matters most, because it is not a binlog corner
at all — it is the first length read of every command response, so any query on
any connection reached it.

Confirmed the same way each time: revert the guard, run the suite, observe
`Fatal error: Not enough bits to represent the passed value` and signal 5.

The lesson is about the *shape* rather than the site. Anywhere a width comes off
the wire and is converted before being compared, the comparison is decoration.
`Tests/SwizzleMySQLTests/WireLengthBoundsTests.swift` groups these by defect
rather than by component, so a new call site has an obvious place to be tested.

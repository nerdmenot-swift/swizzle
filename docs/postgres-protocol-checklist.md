# Postgres protocol completeness checklist

Derived by surveying four mature clients (see `references/README.md`). The point
is to know the full surface *before* building, so gaps are deliberate choices
rather than discoveries made in production — the same discipline that produced
`mysql-protocol-checklist.md`, and the reason that driver has no surprises left
in it.

Status: ✅ done · 🔜 planned · ⬜ not started · ❌ deliberately out of scope

Primary reference is `postgres-protocol` + `tokio-postgres`; see
`references/README.md` for why and for how the others are used.

---

## Why this driver exists

Swizzle adopted postgres-nio rather than writing a driver, and that was the right
call at the time: unlike MySQLNIO it is async-native, streams with real
backpressure, and pools. The reasoning is recorded in `driver-spike.md`.

What changed is pillar 3. Prepare-and-describe needs the output of a `Describe`
message, and postgres-nio keeps all of it internal — `RowDescription` is not
public, `PreparedQuery`'s payload is not reachable, and the state machine
*discards* `ParameterDescription.dataTypes` because its promise type has nowhere
to put them. The wire carries everything; the library hands over nothing.

That is the second time borrowing has cost us. `executeUpdate` returned a drained
row count for months because `PostgresClient` does not surface the command tag,
and the fix was to drop to `PostgresConnection`. Each time, the answer was
already on the wire and the library's access control was in the way.

So the choice is between maintaining a fork of an actively developed package
forever, or owning the protocol the way we own MySQL's. The protocol is
**smaller** than MySQL's — no capability-negotiation matrix, no 16 MiB packet
splitting, no five auth plugins — and the surrounding machinery already exists:
the connection pool is vendored and generic, TLS upgrade and `autoRead`
backpressure are solved, swift-crypto has the SCRAM primitives, and the
`SQLExecutor` seams are in place.

---

## 1. Framing and startup

| item | status | note |
|---|---|---|
| Message framing: 1-byte tag + Int32 length | ✅ | Simpler than MySQL — no split packets, no sequence IDs |
| `StartupMessage` (no tag, version 3.0) | ✅ | Untagged, which is the one framing exception |
| `SSLRequest` + TLS upgrade | ✅ | Own pre-framing handler; `NIOSSLClientHandler` inserted at the head |
| CVE-2021-23222 — no bytes behind the `S`/`N` | ✅ refused | Anything following the answer was injected; see the audit log |
| `sslmode` semantics | ✅ | `disable`/`prefer`/`require`/`verify-ca`/`verify-full` — `prefer` is the trap: it must fall back |
| `CancelRequest` on a second connection | ✅ sent | Needs `BackendKeyData` from the first; a real feature, not an extra |
| `Terminate` | ✅ | |
| Startup parameters (`application_name`, `search_path`, …) | ✅ | |
| `ParameterStatus` tracking | ✅ incl. mid-session | Server pushes these mid-session; `DateStyle`/`TimeZone`/`integer_datetimes` change decoding |
| `BackendKeyData` | ✅ retained | Retained for cancellation |
| `NegotiateProtocolVersion` | ✅ decoded | Rare, but the graceful path when we ask for something new |

## 2. Authentication

| item | status | note |
|---|---|---|
| `AuthenticationOk` / trust | ✅ | |
| Cleartext password | ✅ gated on secure transport | Must be gated on TLS or a unix socket, as MySQL's is |
| MD5 password | ✅ RFC vectors **and** a real server | Deprecated by Postgres but ubiquitous in the wild |
| **SCRAM-SHA-256** | ✅ RFC 7677 vectors **and** a real server | The modern default. The fixture ran `--auth=trust` until the ✅ audit, so this had never once authenticated for real — and did not work when it was finally asked to |
| SCRAM-SHA-256-PLUS (channel binding) | ✅ end to end over TLS | `tls-server-end-point`. The fixture gained a self-signed certificate so this could be verified rather than reasoned about |
| gs2 `y` downgrade tripwire | ✅ | Sent when we could bind and the server offered only the plain mechanism — the server aborts, which is how a stripped mechanism list is caught |
| GSSAPI / SSPI | ❌ | Kerberos. Enormous, and rare outside enterprise AD |

## 3. Simple query protocol

| item | status | note |
|---|---|---|
| `Query` → `RowDescription`/`DataRow`/`CommandComplete` | ✅ | |
| Multiple statements in one `Query` | ✅ | Each gets its own result; this is how migrations run |
| `EmptyQueryResponse` | ✅ | |
| `CommandComplete` tag → affected rows | ✅ | The only place the count exists. `INSERT` carries an extra OID field |
| `ReadyForQuery` transaction status (`I`/`T`/`E`) | ✅ | The `E` state is how a failed transaction is detected |

## 4. Extended query protocol

| item | status | note |
|---|---|---|
| `Parse` / `Bind` / `Execute` / `Sync` | ✅ driven | |
| **`Describe` (statement) → `ParameterDescription` + `RowDescription`** | ✅ both sides, and never executes | **The reason this driver exists.** Both halves must be public |
| Error → discard until `Sync` | ✅ | The rule that desynchronises a client that reports early |
| `Describe` (portal) → `RowDescription` | ✅ **required, not optional** | A portal describes only when asked; without it there is no column metadata at all |
| `Close` (statement and portal) | ✅ driven | Explicit `closeStatement(named:)` / `closePortal(named:)`, plus cache eviction |
| `Flush` | ✅ driven | The one shape `Sync` cannot express: results pushed out with the implicit transaction left **open**, so dependent statements stay atomic together. `withPipelineSession` |
| `PortalSuspended` + row-limited `Execute` | ✅ driven | `PostgresCursor`. A resumed Execute sends no RowDescription — the columns must be carried forward |
| `NoData` | ✅ | A statement returning no rows still completes a describe |
| Prepared statement cache | ✅ | LRU keyed on SQL, as MySQL's is; eviction sends `Close` |
| Stale cached plan (`0A000`) → drop cache and retry once | ✅ | Without it, one `ALTER TABLE` poisons a pooled connection permanently |
| Pipelining | ✅ | Multiple `Parse`/`Bind`/`Execute` before one `Sync`. **It is an implicit transaction** — see the tests |
| Parameter type hints | ✅ | And the statement cache key includes them, or a hinted query silently reuses an unhinted statement |

## 5. Values and types

| item | status | note |
|---|---|---|
| Text format decoding | ✅ | |
| Binary format decoding | ✅ core types | The default for extended queries, and where the work is |
| Core scalars: `int2/4/8`, `float4/8`, `bool`, `text`, `bytea` | ✅ | |
| `numeric` | ✅ base-10000 reconstruction, stays text | **Text, never `Double`.** Same contract as MySQL's DECIMAL |
| Temporals: `date`, `time`, `timetz`, `timestamp`, `timestamptz`, `interval` | ✅ date/timestamp(tz); time/interval keep bytes | Postgres epoch is 2000-01-01, not 1970 — a classic off-by-30-years |
| `uuid`, `json`, `jsonb` | ✅ incl. the jsonb version byte | `jsonb` binary has a leading version byte |
| Arrays | ✅ binary and text, nested, nulls, explicit bounds | Dimensions, lower bounds, and a `-1` length for null |
| `oid`, `name`, `char` | ✅ | Catalogue types, needed for introspection |
| `inet`, `cidr`, `macaddr`, `macaddr8` | ✅ | Found by the reference diff; were arriving as opaque bytes |
| `money`, `bit`, `varbit`, `pg_lsn`, `xid`, `cid`, `tid` | ✅ | Same. `money` is exact, like `numeric` |
| Range types (int4/int8/num/ts/tstz/date) | ✅ binary | The brackets carry the inclusivity and must survive |
| Geometric (point, lseg, box, path, polygon, line, circle) | ✅ binary | Each prints with different punctuation |
| Composites, domains, enums **at runtime** | ✅ | `PostgresTypeRegistry`, resolved on demand and cached per connection |
| `tsvector`, `jsonpath` | ✅ binary | `tsvector` grounded on `pgx/pgtype/tsvector.go`: weight in the top two bits, position in the low fourteen |
| `reg*` family | ✅ OID | **The one family where binary and text cannot agree** — the wire carries an OID, the text form the name. `::text` is how to ask for a name |
| `tsquery` | ✅ binary | Prefix tree, operands stored **right before left**, and the server's minimal parenthesisation reproduced exactly. Verified over a corpus covering every precedence pairing in both orders |
| Unknown OID handling | ✅ degrades, never fails | Degrade to raw bytes, never fail the result set |
| `integer_datetimes` / `DateStyle` sensitivity | ✅ | `DateStyle=ISO` requested at startup so the two wire formats agree; `integer_datetimes` read rather than assumed |
| `interval` | ✅ binary | Microseconds, days and months — three fields, because a month is not a fixed number of days |

## 6. Streaming and backpressure

| item | status | note |
|---|---|---|
| `AsyncSequence` row stream on `NIOThrowingAsyncSequenceProducer` | ✅ | Same machinery as `MySQLRowSequence`, same adaptive buffer |
| `autoRead = false` from the first commit | ✅ | The lesson from the MySQL driver: retrofitting read control is what sank MySQLNIO |
| Read gate closes *and* reopens | ✅ both directions tested | A gate that closes and stays shut is a hang, not backpressure |
| Row-limited `Execute` for true row-bounded fetch | ✅ | `PostgresCursor` — the server sits idle between batches rather than blocked |
| Abandoning a stream drains or cancels cleanly | ✅ closes the connection | Unlike MySQL: the remaining rows are unbounded and the server is blocked writing them |

## 7. Errors and notices

| item | status | note |
|---|---|---|
| `ErrorResponse` field parsing (S, C, M, D, H, P, …) | ✅ every field kept | |
| SQLSTATE → `SQLErrorKind` | ✅ code, then class | Short table by design — SQLSTATE is hierarchical, so unknown codes still classify |
| `NoticeResponse` | ✅ delivered | Delivered, not swallowed |
| Retry-safety classification | ✅ | `mayHaveApplied` is answerable here, unlike MySQL — see the audit log |
| Constraint name on a violation | ✅ | Postgres names it; MySQL only puts it in the message text |

## 8. Beyond querying

| item | status | note |
|---|---|---|
| `COPY IN` / `COPY OUT`, text and binary | ✅ | Streaming both ways; `CopyFail` on a throwing writer, so a half-written import aborts rather than committing |
| `LISTEN` / `NOTIFY` (`NotificationResponse`) | ✅ | Needs a standing read on an idle connection — see the audit log |
| Logical replication / `CopyBothResponse` | ❌ for v1 | The binlog equivalent: large, unrelated to querying, and the natural cut line |
| `FunctionCall` | ❌ | Deprecated by Postgres itself |

## 9. Pooling and lifecycle

| item | status | note |
|---|---|---|
| `PostgresConnection` — connect, query, execute, stream, describe | ✅ | |
| **Transactions** — `withTransaction`, isolation level, `READ ONLY`, `DEFERRABLE`, savepoints | ✅ | At parity with `MySQLTransaction`, plus `DEFERRABLE`, which MySQL has no equivalent for. `COMMIT` is refused on an aborted transaction, because Postgres turns it into a silent rollback |
| `PooledConnection` conformance | ✅ | `SwizzleConnectionPool` already generic; MySQL did this |
| Keep-alive | ✅ | An empty `Query` — no planner, no `pg_stat_statements` noise, unlike `SELECT 1` |
| Session reset on return | ✅ `ROLLBACK` then `DISCARD ALL` | The analogue of `COM_RESET_CONNECTION`; also clears our statement cache |
| Pool wiring (`PostgresClient`) | ✅ | |
| `ServiceLifecycle` graceful shutdown | ✅ | |
| Pool metrics | ✅ | `PostgresPoolMetrics`, deliberately the same metric names as MySQL's so an operator running both needs one vocabulary |

---

## Audit log

### Framing and message encoding — confirmed against `postgres-protocol`

**Confirmed correct.** The length prefix counts itself and excludes the tag;
`len < 4` is invalid because the body length would go negative; the three
pre-handshake messages carry no tag and identify themselves by a magic `Int32`
(`80877103` SSL, `80877102` cancel, `0x00030000` version 3.0); the startup
parameter list ends with an empty key; `-1` is a null parameter and `0` an empty
one; embedded NULs in C strings are refused rather than written, because the
truncation they cause is invisible.

**Adopted from the reference.** Refusing an embedded NUL rather than writing it —
`write_cstr` errors for the same reason, and the alternative silently shifts every
field after it.

**Divergences, deliberate.** The body is decoded from a *slice* rather than the
shared buffer, so a message that under-reads cannot consume the next one's bytes;
the reference relies on its callers reading exactly. This costs nothing and turns
one malformed message into one error instead of a desynchronised stream — the
same class of bug the MySQL audit found in sequence-ID handling.

Bounds are checked per field with the field named in the error, rather than a
single "not enough bytes". A protocol decoder that cannot say *where* the stream
went wrong is very hard to debug against a real server.

### SCRAM-SHA-256 — confirmed against `postgres-protocol/src/authentication/sasl.rs`

**Adopted, and would have been missed.** The reference caps the iteration count at
100,000. It arrives *from the server* and drives a PBKDF2 loop, so an unbounded
value lets an impersonating server force arbitrary work out of the client before
authentication completes — a denial of service needing no credentials. pgjdbc
capped it for CVE-2026-42198 and the reference followed. This is exactly what
reading the reference first is for: nothing about the RFC suggests a cap, and a
correct-looking implementation would have shipped without one.

**Confirmed correct.** The four-message exchange and every derivation
(`SaltedPassword`, `ClientKey`, `StoredKey`, `ServerKey`, the `AuthMessage`
composition); the empty `n=` for Postgres, which carries the username in the
startup message instead; `=`/`,` escaping in usernames with the `=` rule applied
first; base64 attributes split on the *first* `=` only, since a salt routinely
ends in padding.

**Divergence, deliberate.** `saslprep` is partial — NFKC normalisation and the
non-ASCII-space mapping, but prohibited characters are not rejected. The reference
runs full stringprep and falls back to raw bytes when it fails. Rejecting a
password the server accepts turns a working login into an unexplainable failure,
and the server prepares its own copy regardless; an ASCII password is untouched by
either path.

**One thing swift-crypto forced.** `KDF.Insecure.PBKDF2.deriveKey` enforces an
OWASP minimum of 210,000 rounds and throws below it. Sound when *you* choose the
count, inapplicable here: SCRAM's count is the server's, and Postgres's default is
4,096 — so the checked entry point cannot authenticate against a default install.
The unchecked variant is used, with the real risk bounded by the cap above.

**The server's final message is verified.** Skipping it is the difference between
authenticating the server and merely talking to one, and the comparison is
constant-time because the value is a MAC.

### Authentication flow — the security rules, and where they came from

**Cleartext is gated on transport.** Postgres will ask for a plaintext password
over a plaintext link, and a client that complies has handed the password to
anyone listening. Refused unless TLS is up or the socket is a unix one — the same
rule `SwizzleMySQL` applies, for the same reason.

**MD5 is not gated**, deliberately. The salt is what makes it not a replayable
plaintext secret, which is the whole reason the method exists. Gating it would
refuse connections that are no less safe than the alternative.

**Out-of-order requests are refused rather than obeyed.** A server that asks for a
cleartext password halfway through a SASL exchange is either broken or walking the
client into a weaker method than it already agreed to. The state machine has no
transition for it.

**A server offering only `SCRAM-SHA-256-PLUS` is refused with an explanation**
rather than sent a message it will reject — channel binding is not implemented
yet, and "the server offered only SCRAM-SHA-256-PLUS; this client implements
SCRAM-SHA-256 without channel binding" is a message somebody can act on.

**Confirmed correct.** MD5 is `md5(md5(password + username) + salt)` where the
inner digest is appended as hex *text*, not raw bytes — a detail that produces a
plausible-looking hash the server rejects if reversed.

### Framing over a channel, and the bound MySQL taught us

**A message size limit, from the first commit.** Postgres has no equivalent of
MySQL's 16 MiB chunking — one message declares one length, up to four gigabytes —
so a hostile or broken server can declare an enormous message and watch the client
reserve it. The MySQL driver shipped with exactly that hole and the audit found
it; here the length is checked *before* the decoder is allowed to accumulate,
defaulting to 512 MiB.

**`.continue`, not `.needMoreData`, after each message.** A handshake arrives as a
burst, and returning early would deliver one message per read and stall until the
next packet.

**A truncated message at EOF is an error.** "The connection closed" and "the
connection closed mid-message" are different problems and only one of them is the
server's fault.

### Connection lifecycle

**The handshake ends at `ReadyForQuery`, not `AuthenticationOk`.** Between them
arrive the parameters and the cancellation key, and a connection used before that
point is missing both.

**`ParameterStatus` is tracked mid-session, not only during the handshake.** `SET`
makes the server push a fresh one, and `integer_datetimes`, `DateStyle` and
`TimeZone` all change how values decode. A machine that only collected them at
startup would go stale the first time somebody ran `SET TIME ZONE`.

**`BackendKeyData` is retained**, because cancelling a query needs a *second*
connection quoting that pair. Dropping it makes cancellation quietly impossible.

**`sslmode=prefer` is modelled but is not the default.** It is libpq's default and
provides no guarantee at all — a network attacker strips the offer and the client
continues in the clear. libpq carries that for backwards compatibility; this driver
does not have to, so it defaults to `verify-full`.

### Values — confirmed against `pgtype/numeric.go`

**`numeric` is reconstructed, not reinterpreted.** It is the money type, and in
binary the server sends base-10000 groups rather than text: four `Int16` headers
(digit count, weight, sign, display scale) then the groups. Getting the
reconstruction wrong does not fail — it produces a number that is merely
incorrect. Three details are load-bearing and each has a test: `weight` places the
decimal point and can imply groups the server did not send (which are zeros, not
absent); the display scale is why `1.10` comes back as `1.10` rather than `1.1`,
and for money the trailing zero is information; and the three special signs
(`0xC000` NaN, `0xD000` +∞, `0xF000` −∞) carry no digits at all.

The value stays **text** on the way out. Routing an exact numeric through `Double`
is the same mistake MySQL's DECIMAL and SQLite's NUMERIC contracts already forbid.

**The epoch is 2000-01-01, not 1970.** Thirty years and change, and the failure is
silent because the wrong answer is a plausible-looking date. Tested at the epoch,
a day either side of it, and with sub-second precision.

**`jsonb` carries a leading version byte** that is not part of the document, and
`json` does not — that single byte is the only difference between them on the
wire.

**Text format is not a fallback.** The extended-query protocol defaults to text
unless the client asks for binary, so both paths are real and both are tested. A
`bool` is `t`/`f` in text and `0x01`/`0x00` in binary; a `bytea` is `\x`-prefixed
hex in text and raw in binary.

**Unrecognised OIDs degrade rather than failing the result set.** A new server type
should not break a query that never touches it.

---

## Verification

The same three-part discipline the MySQL driver was held to:

**Unit** — pure state machines and codecs, no server, must stay green.

**Integration** — the embedded Postgres fixture already exists
(`PostgresFixture`), so the matrix is versions × auth methods × TLS on/off. Must
cover SCRAM with and without channel binding, a cache-cleared prepared statement,
and an array round-trip.

**Conformance** — read the primary reference for each area *before* writing it,
and record confirmations and divergences in an audit log here, exactly as §0 of
the MySQL checklist does. That log is what turned two real framing bugs up last
time.

### Query flow — confirmed against `tokio-postgres/src/query.rs` and `simple_query.rs`

**Confirmed correct.** The unnamed statement and unnamed portal are replaced on
every use and need no `Close`, which is why the ordinary path is
Parse/Bind/Execute/Sync with no cleanup round trip. `RowDescription` precedes the
first `DataRow`, so column metadata is available before any row — that is what
lets `PostgresRowSequence.columns` be non-optional. A row-limited `Execute` ends
in `PortalSuspended` *instead of* `CommandComplete`, so there is no command tag
and therefore no affected-row count for a suspended portal.

**Adopted, and the rule most worth having written down.** After an
`ErrorResponse`, the server **discards every subsequent message until `Sync`**.
A client that reports the failure and returns immediately will read this
statement's discarded tail as the next statement's replies — the failure surfaces
one query later, attached to an innocent statement. The machine therefore keeps
consuming to `ReadyForQuery` and reports only then.

**Divergence, deliberate.** Column format is read per column from
`RowDescription` rather than assumed to be whatever the `Bind` requested. A
server may answer a binary request with text for a type that has no binary
representation, and decoding those bytes as binary produces a value that is
merely wrong. The cost is one array; the reference is stricter about what it
requests and can afford the assumption.

**Divergence, deliberate.** `affectedRows` is `nil` rather than `0` for commands
that carry no count (`BEGIN`, `COMMIT`, `SET`, DDL). "No count" and "changed
nothing" are different answers and only one of them is a number — and the borrowed
driver returning `0` for everything is precisely the bug that made `executeUpdate`
useless for months.

### TLS negotiation — confirmed against libpq's `PQconnectPoll`

**Confirmed correct.** TLS is negotiated *before* message framing begins: an
untagged 8-byte `SSLRequest`, answered by one raw byte with no length prefix.
That is why it needs its own handler ahead of the frame decoder — the decoder
would read `S` as a message tag and then wait forever for a length that never
comes. MySQL needs no equivalent, because there the SSLRequest is an ordinary
packet inside the normal framing.

**Adopted, and would have been missed — CVE-2021-23222.** libpq rejects the
connection if any buffered data remains after the negotiation byte. The reasoning
is not obvious until stated: having answered, the server is *waiting* — for our
ClientHello if it said `S`, for our StartupMessage if it said `N`. It has nothing
to send. So bytes arriving behind the answer did not come from the server's
protocol state machine; they were injected by whoever is in the middle,
specifically so the client will process them as though they had arrived over the
TLS session about to be established. The check is three lines and it is the
difference between a secure handshake and a decorative one.

### Streaming — divergence from the MySQL driver, recorded because it does not transfer

MySQL's cursor mode has a **protocol-level** fetch: `COM_STMT_FETCH` asks for N
rows and the server sends N. Postgres's ordinary path has no equivalent — once
`Execute` goes out with a row limit of zero, the server streams the whole result
as fast as the socket takes it, and there is no message meaning "pause".

So backpressure here is `autoRead = false`: the channel stops reading, the receive
buffer fills, and TCP flow control stalls the server in its own write. It works,
and it is a level lower than MySQL's. The consequence worth stating: a stalled
consumer holds a *server backend* blocked in a write, so an abandoned stream must
be drained or the connection closed — dropping it silently is worse here than on
MySQL. Row-limited `Execute` with `PortalSuspended` is the protocol-level
alternative, at a round trip per batch.

### Statement caching — confirmed against `tokio-postgres/src/prepare.rs` and pgx's `stmtcache`

**Confirmed correct.** A named statement lives for the session and is bound
without re-parsing; the unnamed one is replaced on every use. Eviction is a
*protocol* concern rather than a memory one — the statement is a server-side
allocation, so an evicted name has to be `Close`d or it leaks until the
connection dies.

**Adopted, and the reason caching is safe to turn on at all.** After `ALTER
TABLE`, executing a cached statement fails with `0A000` — *cached plan must not
change result type* — and then **fails again every time after that**, because the
cache keeps handing back the same stale statement. On a long-lived pooled
connection that means one deploy poisons a connection until something closes it.
pgx and asyncpg both recognise the error, drop the cache and retry once; a driver
that caches without this has traded a round trip for an outage. Retry is capped at
one, because a second identical failure is a real error and retrying forever turns
it into a spin.

**Divergence, deliberate.** `Describe` is never cached. It is a generator's
one-off question about a statement's shape, and caching those would fill the
connection's statement table with things nobody will execute.

**Divergence, deliberate.** Statement names are prefixed `swizzle_`. The
namespace is shared with statements the application created itself via `PREPARE`,
and a collision would be silent.

### The bug the integration tests found — `Describe` is not optional

Written down because every unit test passed while it was wrong, and because the
failure mode is the quiet kind.

The extended-query flow was Parse → Bind → Execute → Sync. That is the sequence
every summary of the protocol gives, and it is **incomplete**: a portal sends a
`RowDescription` only if something asks it to. Without a `Describe`, the server
replies with bare `DataRow`s and no column metadata whatsoever.

Nothing fails. The rows arrive, the counts are right, and every value goes through
the unknown-OID path — where valid UTF-8 becomes text. So
`SELECT pg_try_advisory_lock($1)` returned `.text("\u{01}")` instead of
`.bool(true)`, the migrator read that as falsy, and the lock "timed out" after
thirty seconds against a database that had granted it immediately.

Two things made it survive unit testing. The state-machine tests *fed* the machine
a `RowDescription`, so they proved decoding rather than that the server would send
one. And the **simple** protocol has no such trap — an unbound query describes
itself — so every unparameterised query looked perfectly fine.

`Describe(portal)` now goes out between `Bind` and `Execute` on every extended
query, cached statement or not, with a test asserting the message is present and
precedes the `Execute`.

### The second bug the integration tests found — a struct iterator has no `deinit`

`SQLStreamingExecutor.stream` leases a connection for the sequence's whole life,
so something has to give it back. Releasing from the iterator's `next()` covers
the two tidy endings — the rows ran out, or the statement failed — and misses the
untidy one entirely: **a consumer that `break`s never calls `next()` again**.

An `AsyncIteratorProtocol` iterator is a struct, so there is no `deinit` to fall
back on. The lease leaked, and with the migrator's single-connection pool the next
query waited out the ten-second acquisition timeout and failed.

The fix is a small class the iterator holds, whose `deinit` is the backstop; the
eager release in `next()` stays, because an idle connection should go back now
rather than whenever ARC gets round to it. `deinit` cannot be `async`, so it is the
one place a detached task is the only option — safe here because the lease is
still exclusively ours until it is handed back.

### Cancellation and session reset

**Confirmed against libpq's `PQcancel`.** Cancellation needs a *second*
connection: the one running the query is busy producing results and will not read
anything until it is done — which is precisely the case where cancelling matters.
The `CancelRequest` carries the target's process id and secret key, gets no reply,
and is authorised by the secret key alone. That is why `BackendKeyData` is
retained rather than logged.

**Divergence, deliberate.** No TLS on the cancel connection. libpq negotiates it
when configured to; the request carries no credentials and no query text, only two
opaque integers the server itself issued, so a full TLS handshake would protect
eight bytes of nothing on the path that is by definition already in a hurry.

**Confirmed, and worth stating because the failure is invisible.** `DISCARD ALL`
deallocates every prepared statement, so the driver's own cache must be cleared
with it. Leaving it populated has the next query bind a name the server just threw
away — every statement failing with "prepared statement does not exist" on a
connection that otherwise looks healthy. `ROLLBACK` goes first because `DISCARD
ALL` cannot run inside a transaction, and a connection being returned may well be
in one — that being the case the reset exists for.

**Keep-alive uses the empty query**, not `SELECT 1`. The server answers
`EmptyQueryResponse` without planning anything; `SELECT 1` goes through the
planner and shows up in `pg_stat_statements` as noise for every idle connection in
the pool.

### Arrays — confirmed against `postgres-protocol/src/types.rs` and `pgtype/array.go`

**Confirmed correct.** The binary layout is dimension count, a has-nulls flag, the
element OID, then a `(length, lowerBound)` pair per dimension, then each element
length-prefixed with `-1` for NULL. The element OID being *on the wire* is what
lets the decoder work without being told what it is reading — which matters for a
domain over an array, where the column's own OID says nothing useful. Zero
dimensions is the empty array and carries nothing after the header, not even a
dimension entry, so a decoder that assumes one runs off the end.

**Confirmed, and the two text-format rules that fail silently.** An *unquoted*
`NULL` is a SQL null while a *quoted* `"NULL"` is the four-character string;
losing the distinction turns a null into a word or a word into a null. And
backslash escapes apply outside quotes as well as inside. `'[3:5]={a,b,c}'` is a
one-dimensional array based at 3 — dropping the prefix silently rebases every
index.

**Divergence, deliberate, and a design decision rather than a shortcut.** An array
lands in `SQLValue` as the text Postgres itself would print, not as a new
`SQLValue` case. `SQLValue` is the *neutral* type the three engines share, and an
array case only one of them can produce does not belong in that vocabulary — it
would force MySQL and SQLite to carry a case they must refuse. The elements are
still reachable through `PostgresRow.array(at:)`, and rendering to Postgres's own
text form keeps binary and text formats agreeing, which is the contract `numeric`
and the temporals already keep.

### LISTEN/NOTIFY — the interaction nobody warns about

**`NOTIFY` is the only message a connection receives that nobody asked for.**
Everything else is a reply, and that has two consequences worth stating:

1. **An idle connection must keep reading.** The driver runs with
   `autoRead = false`, so nothing is read unless something asks — and an idle
   connection asks for nothing. Without a standing read, `LISTEN` registers
   successfully and then delivers nothing at all, which is the worst kind of
   broken because it looks like it works. The standing read exists only while
   there is a listener, so a connection nobody is listening on stays fully
   demand-driven.
2. **It arrives at any message boundary, including inside a result set.** So it is
   handled ahead of the query state machine rather than only when idle, and it
   must not be mistaken for part of the result.

**`pg_notify` rather than the `NOTIFY` statement.** `NOTIFY` takes an identifier
and a literal, neither of which can be a bound parameter; `pg_notify` is a
function, so both arguments bind and neither is spliced into SQL. `LISTEN` has no
function equivalent, so its channel name is quoted with `"` doubling — Postgres's
own escape.

### Errors — confirmed against `postgres/src/error/sqlstate.rs`

**Divergence, deliberate, and the reason our table is 40 lines rather than 349.**
The reference enumerates every SQLSTATE as a typed constant. We map exact codes
where the distinction changes what a caller *does*, then fall back to the
two-character class. SQLSTATE is hierarchical by design, so a code Postgres adds
tomorrow in class `23` is an integrity violation today — enumerating them all buys
nothing the class fallback does not already give, and the full list has to be
maintained forever.

**Confirmed, and better than MySQL can manage.** `mayHaveApplied` is genuinely
answerable here: any error aborts the surrounding transaction and there is no
non-transactional storage engine to leave half a statement behind, so a server
error that arrived means nothing applied. The exceptions are the classes where the
server was *leaving* — `08`, `57`, `58`, `XX` — where the reply can arrive after a
commit and the wire cannot say which side of it we are on. MySQL has to be
conservative about far more than this.

### The ✅ audit — what "done" was actually worth

Prompted by `COM_QUIT` on the MySQL side, which had been ticked for a year on the
strength of an enum case nothing ever sent. The question asked of every ✅ row was
**"what test proves this, and could that test pass if the feature were absent?"**

Four defects fell out, all in code that had passed its own unit tests.

**1. Authentication never ran.** The fixture used `initdb --auth=trust`, so the
server never asked for a password — which meant **SCRAM-SHA-256, the default for
every modern Postgres, had never authenticated against a real server**. The
checklist said "RFC 7677 vectors pass", which was true and is a different claim:
the vectors prove the maths, not the exchange.

Adding a `pg_hba.conf` rule per mechanism exposed the bug immediately. The channel
handler built the `StartupMessage` from configuration and wrote it directly rather
than calling `machine.start()`. The bytes were identical, so connections worked —
but `start()` is also what moves the auth machine into `awaitingAuthentication`,
so it sat in its initial state and rejected every authentication request as *out
of order*. **SCRAM and MD5 could not authenticate at all.** Only `trust` worked,
because trust is the one flow that never sends an authentication request. The
machine's own tests called `start()`; only the handler skipped it.

**2. A crash in the notification API.** `syncOperations` must be called on the
event loop, and `listen`/`notifications` reached it from `async` code that is not.
That is a `preconditionFailure` inside NIO — a hard crash in a public API. It
survived the handler tests because `EmbeddedChannel` runs its loop on the calling
thread, so `inEventLoop` is always true there. Only a real socket has a real loop
to be off.

**3. `57014` was in the wrong retry class.** Class `57` is operator intervention,
which mostly means the server is leaving and the statement's fate is unknown — but
`57014` means *cancelled*, which Postgres implements by aborting. Left in the
class, every cancelled or timed-out statement looked like it might have landed, so
`isSafeToRetry` said no to the one family of failures that is unambiguously safe
to retry. Found by cancelling a real `pg_sleep`.

**4. A leaking promise crashed the process.** Every entry point made its promise
and *then* sent; the send throws when the connection is already closed, and NIO
turns an unfulfilled promise into a `fatalError`. So a query on a closed
connection took the process down instead of throwing. It appeared once in about
six full runs — often enough to be dismissed as a flake, rare enough to survive.

**And one that took two attempts.** Abandoning a row stream kills the connection
by design, and the executor handed it back to the pool anyway. The first fix
checked `isActive` at release time and still failed about one run in eight: the
close is *in flight*, so a connection about to die reports itself alive. The
working version has the borrower say `discard: true` and awaits the close before
releasing — telling the pool beats asking the socket. Eight consecutive full runs
green after that, against two failures in eight before.

The pattern across all six: **every one passed its unit tests, and every one
needed a real server, a real socket, or a real race to show up.** A test that
feeds a state machine the message it expects proves decoding, not that the server
sends it.

---

## Line-by-line verification against `rust-postgres`

A deliberate sweep of the primary reference, area by area, to find what was left
out rather than what was got wrong.

### Complete, and in two places a superset

| area | reference | ours | verdict |
|---|---|---|---|
| Frontend messages | 17 | 18 | **superset** — all 17, plus `CopyData` |
| Backend message tags | 21 | 23 | **superset** — all 21, plus `v` (`NegotiateProtocolVersion`) and `W` (`CopyBothResponse`) |
| Authentication sub-codes | 0,2,3,5,6,7,8,9,10,11,12 | same | Every unsupported code is *named* rather than lumped into one error |
| Framing, startup, TLS negotiation | — | — | Verified earlier; we additionally refuse CVE-2021-23222 |

### The type table — 24 types added as a result

Diffing our OIDs against `postgres-types/src/type_gen.rs` found the real gap.
Because an unrecognised OID degrades to bytes rather than failing, **every one of
these was silently arriving as an opaque `.blob`** — an `inet` column as four raw
bytes, a `daterange` as a flag byte and two lengths.

Added, with binary decoders: `inet`, `cidr`, `macaddr`, `macaddr8`, `money`,
`bit`, `varbit`, `pg_lsn`, `xid`, `cid`, `tid`, the six range types, and the seven
geometric types.

**How they were verified.** Not against hand-written expectations — those only
prove a format description was copied correctly. Each value is fetched twice, once
through a bound parameter (extended protocol, binary) and once as a literal
(simple protocol, text), and the two renderings must be **identical**. That makes
Postgres its own oracle, and it caught the class of error a hand-written
expectation enshrines: `1.0` where the server prints `1`, `::` for a single zero
group, a box carrying the brackets an lseg uses.

It also caught a wrong *test*: the first version compared against `::text`, which
for `inet` always appends the prefix while the type's output function omits it for
a full-width host. Two different functions, and only one of them is what comes
down the wire.

**Deliberately still absent:** `tsvector`, `tsquery`, `jsonpath`, and the `reg*`
catalogue types. Adding an OID *without* a decoder is a regression — the decoder's
default arm returns `.blob` for a known OID, where an unknown one would at least
try UTF-8 first. An entry has to earn its place with a decoder.

### What the reference has that we still do not

Established by diffing `tokio-postgres/src/client.rs` and its module list.

| gap | consequence | reference |
|---|---|---|
| **Transactions** | No `withTransaction`, no isolation level, no `READ ONLY`/`DEFERRABLE`, no savepoints. Callers hand-write `BEGIN`/`COMMIT` and own the rollback-on-error themselves. **MySQL has all of this**, so the two engines are not equal | `transaction.rs`, `transaction_builder.rs` |
| **COPY IN / OUT** | No bulk load path; a million-row import goes through `INSERT` | `copy_in.rs`, `copy_out.rs`, `binary_copy.rs` |
| **Runtime typeinfo cache** | Enums, composites and domains decode as text at *runtime*. The analyzer resolves them for codegen; the driver does not | `prepare.rs` typeinfo queries |
| Row-limited `Execute` resumption | `maxRows` is flagged when a portal suspends, but nothing asks for the next batch | `portal.rs` |
| Pipelining | One statement at a time | `client.rs` |
| Parameter type hints (`query_typed`) | We send untyped and let the server infer, which is right by default and gives no override | `query_typed` |
| `Close` / `Flush` driven | Encoded, but only eviction sends `Close` | — |

**Transactions are the one that matters most**, and are the only gap where the two
engines this project ships are not at parity.

---

## Performance pass

Benchmarks live in `Tests/SwizzlePostgresTests/PostgresBenchmarks.swift`, opt-in
with `SWIZZLE_BENCH=1`. Loopback to Postgres 16 on an M-series Mac — absolute
numbers mean nothing elsewhere, ratios are the point.

### The bug it existed to find

Collecting a result set was **quadratic in the row count**. `channelRead` began
with `guard var state = running`, which copies the struct and with it a *second
reference* to the growing rows array; every subsequent `append` then found the
buffer shared and copied the whole thing.

Nothing failed and no test noticed, because the shape only shows up once results
get big:

| rows | before | after |
|---|---|---|
| 10 000 | 230 ms | **47 ms** |
| 50 000 | 4 670 ms | **242 ms** |

5× the rows had cost 20× the time; now it costs 5.1×. Both sizes land at roughly
**210 000 rows/sec**. The fix is to mutate through `running!` so the array stays
uniquely referenced — CoW turning an `append` loop quadratic is an ordinary Swift
hazard, and a driver that accumulates rows is exactly where it bites.

### Where the numbers landed

| measurement | result | reading |
|---|---|---|
| simple protocol round trip | ~9 900 op/s | The round-trip ceiling on loopback |
| extended protocol round trip | ~8 600 op/s | 0.87× simple — four more messages, same round trip |
| statement cache hit vs miss | **1.10×** | Honest: on loopback, `Parse` on a trivial statement is cheap. The cache earns its keep on complex statements and on real latency, not here |
| 10k narrow rows | ~210k rows/s | |
| 10k wide rows (6 cols) | ~52k rows/s | Roughly linear in *columns*, as expected |
| stream vs collect, 50k rows | 0.75× | Streaming costs ~25%, which buys bounded memory |
| **pipeline vs serial, 50 statements** | **1.88×** | On loopback, where latency is near zero — this is the floor, and the gap widens with every millisecond of real network |
| **COPY vs INSERT-per-row, 5k rows** | **3.3×** | And pipelined INSERT gets most of the way there (2.7×) |
| cursor vs stream, 10k rows | 0.97× at batch 100, 1.13× at batch 1000 | A cursor is not slower in practice; batch size barely matters at this scale |

### What the numbers say about the design

- **Pipelining and COPY earn their complexity**; the statement cache does not
  earn it *on this benchmark*, and the doc comment now says so rather than
  implying a speed-up nobody measured.
- **Streaming's 25% is the price of bounded memory**, not a defect — and it is
  measured rather than assumed.
- Wide rows cost per column, which points at value decoding rather than framing
  as the next thing worth optimising if anyone needs it.

---

## Line-by-line audit against `postgres-protocol` + `tokio-postgres`

Reference was already current. Done the same way as the MySQL audit in
`mysql-protocol-checklist.md §8`: enumerate the reference's surfaces, compare
entry by entry, and check every claim against a live server rather than against a
reading of the format.

### Messages and types

| surface | reference | ours | |
|---|---|---|---|
| frontend messages | 17 | 17 | exact |
| backend messages | 29 | **31** | superset — we also carry `CopyBothResponse` and `NegotiateProtocolVersion` |
| authentication requests | 12 codes | in-scope ones decoded, rest carried as `.unsupported(code:)` | GSS/SSPI/Kerberos/SCM stay out of scope, but the code reaches the error |
| type OIDs | 185 | 147 + the 15 below | |

### Fifteen types added

Six **multiranges** (`int4multirange` and friends, Postgres 14+), the catalog
types `int2vector`, `oidvector`, `aclitem`, `gtsvector`, `txid_snapshot`, plus
`xid8`, `refcursor`, `regcollation` and `cstring`. Every one of them used to
arrive as opaque bytes.

`rust-postgres` knows multiranges only as a *kind* — it records the element type
and ships no codec — so we are ahead of the reference there rather than level
with it. Which is exactly why the binary/text oracle mattered: there was no
second implementation to cross-check, and the oracle rejected two of my readings
immediately.

### What the oracle caught

Each value is fetched twice, once through the extended protocol (binary) and once
through the simple protocol (text), and the two must agree. It found four
mistakes in the new code and **two pre-existing bugs**:

**1. Range bounds were not quoted.** `range_out` quotes a bound whose text is
empty or contains any of `"` `\` `(` `)` `[` `]` `,` or whitespace. A timestamp
contains a space, so **every** `tsrange` and `tstzrange` was rendered
`[2024-01-01 00:00:00,…)` where the server renders
`["2024-01-01 00:00:00",…)`. Missed because the range tests covered `int4range`,
`daterange` and `numrange` — not one of which has a bound needing quotes.

**2. Binary and text disagreed for the system integer types.** `decodeBinary`
returned `.int` for `xid`, `cid` and `xid8` while `decodeText` returned `.text`,
so `row[0].int` was non-nil or nil depending on whether the query happened to
carry a bound parameter. Nothing in the SQL suggests that difference. The `reg*`
family is the one place the formats genuinely cannot agree — binary carries the
OID, text carries the name — and `Int64(text)` picks correctly between them.

And two facts about the server, learned by being contradicted:

- **`int2vector` and `oidvector` are arrays on the wire**, header and all, with a
  lower bound of 0. They only *look* like a bare run of integers because of how
  they print. The first implementation returned the array header as data.
- **`aclitem` has no binary output function.** `SELECT $1::aclitem` fails with
  `no binary output function available for type aclitem`, so it can only ever
  arrive as text.

### `connect_timeout`

`libpq` has it, `tokio-postgres` has it, our MySQL driver has had one since it was
written, and this driver had no way to set one.

Measured rather than assumed: with the setting removed a black-holed host
(`192.0.2.1`, RFC 5737 TEST-NET-1, guaranteed unroutable) fails in **10.003 s**,
because NIO's `ClientBootstrap` applies its own ten-second default. So
connections were never unbounded — the gap was configurability, and a service
that would rather fail over in 500 ms had no way to ask.

### Client features, compared to `tokio-postgres`

`copy_in`, `copy_out`, `cancel_query`, `prepare`, `transaction`, `savepoint`,
`simple_query`, `cancel_token` — all present. `query_portal` is our
`PostgresCursor`, `check_connection` is `ping()`, `clear_type_cache` is the type
registry's `removeAll()`.

Config options still absent, and deliberately: `target_session_attrs`,
`load_balance_hosts` and `hostaddr` all presuppose multi-host configurations,
which this driver does not have; `ssl_negotiation` is Postgres 17's direct-TLS
handshake. `application_name` and `options` are reachable through
`parameters`, and `application_name` has its own URL parameter.

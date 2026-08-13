# Parity audit against the reference

The plan committed to *"full parity with `mysql_async`"*, grounded on
`rust-mysql-common` + `mysql_async`. Everything until now was measured against
our own checklist, which is not the same claim. This is the audit against the
reference itself.

Method: diff the reference's enums and public option surface against ours
programmatically, not by reading. Where the two disagree, say which way and why.

## Commands

The reference's `Command` enum lists 34 values, but most are server-internal or
removed (`COM_SLEEP`, `COM_CONNECT`, `COM_TIME`, `COM_DAEMON`, `COM_END`…). The
meaningful comparison is what the client can actually *send* — the ones it issues
directly plus the ones its packet builders construct: **15**.

| | |
|---|---|
| In the reference, not in ours | `COM_FIELD_LIST`, `COM_TABLE_DUMP` |
| In ours, not in the reference | `COM_INIT_DB`, `COM_SET_OPTION`, `COM_STMT_RESET`, `COM_STMT_FETCH` |

Both of theirs are deprecated: `COM_FIELD_LIST` was deprecated in MySQL 5.7 and
is unusable on 8.0+, and `COM_TABLE_DUMP` is a pre-GTID replication relic. The
four extras are not padding — `COM_STMT_FETCH` is what makes cursor-based
streaming work, and `COM_STMT_RESET` is required to reuse a statement after a
partially-consumed cursor.

**Verdict: at parity, plus four.**

## Binlog event types

| reference | ours |
|---|---|
| 42 | **54** |

Missing exactly one, now added: `GTID_TAGGED_LOG_EVENT` (0x2A), MySQL 8.4's
tagged GTID, which lets one server maintain several independent GTID sequences.

The other twelve are ours alone: `HEARTBEAT_LOG_EVENT_V2` and the **entire
MariaDB block** (0xA0–0xAB) — annotate-rows, binlog checkpoint, MariaDB GTID and
GTID list, start-encryption, and the six compressed query/row events. The
reference's `EventType` does not enumerate them.

**Verdict: beyond parity**, and materially so on MariaDB.

## Column types

No gaps. Every type the reference lists is present, plus MySQL 9's
`MYSQL_TYPE_VECTOR` and `MYSQL_TYPE_TYPED_ARRAY`.

## Authentication plugins

At parity except `mysql_old_password`, which is a **deliberate** exclusion: the
pre-4.1 hash is broken and was removed from MySQL 8.0 entirely. Implementing it
would mean shipping an algorithm no supported server accepts.

`mysql_clear_password` is supported but gated behind an explicit opt-in *and* a
secure transport, which the reference also does (`enable_cleartext_plugin`).

## Client options — where the real gaps were

Comparing `mysql_async`'s `Opts` surface against our configuration found four
genuine gaps. Two were worth closing and are now done:

- **`client_found_rows`** → `reportsMatchedRows`. Changes what an UPDATE
  reports: matched rows rather than changed rows. The distinction only shows on
  an update that changes nothing — which is exactly the case callers get wrong,
  and why "did my update apply?" logic misbehaves without it.
- **`init` / `setup`** → `setupStatements`. Statements run on every new
  connection before it is handed out (`SET time_zone`, `SET NAMES`, a required
  `sql_mode`). A pool needs this: without it every borrower must re-apply them,
  and a connection reset silently undoes them. A failure fails the *connect*,
  because a half-configured connection surfaces later as wrong results rather
  than as an error.

Still absent, and judged not worth it:

| option | why not |
|---|---|
| `tcp_keepalive` | TCP-level keepalive. We keep connections alive with `COM_PING` at the pool layer, which also proves the *session* is usable rather than just the socket |
| `conn_ttl` / `abs_conn_ttl` / jitter | The pool retires by idle time, not absolute age. Absolute-age retirement matters mainly for rolling failovers behind a proxy |
| `prefer_socket` | We take an explicit address; there is no hostname-to-socket inference to prefer |
| `secure_auth` | Rejects pre-4.1 auth, which we do not implement at all |
| `disable_tls_resumption`, `root_certs`, `skip_domain_validation` … | Covered by handing a full `TLSConfiguration` to NIOSSL rather than re-exposing each knob |
| `resolved_ips` | DNS pre-resolution; NIO's resolver handles this |

## Where we exceed the reference

Not padding — each is something the reference cannot do:

- **zstd connection compression.** `rust-mysql-common` defines
  `CLIENT_ZSTD_COMPRESSION_ALGORITHM` as a constant but its codec only ever
  builds a `ZlibEncoder`. No reference client implements it.
- **`TRANSACTION_PAYLOAD` expansion.** The reference exposes the compressed
  container; we expand it into its constituent events, without which a consumer
  silently receives no row changes.
- **`PARTIAL_UPDATE_ROWS_EVENT`.** The reference treats it as a plain rows event
  and hands back the raw blob. We decode the JSON diffs.
- **MariaDB compressed binlog events** (`log_bin_compress`), likewise.
- **Cursor-based streaming** via `COM_STMT_FETCH`.
- **Backpressure.** The whole reason this driver exists.

## Against go-sql-driver

Added after the rust audit, because go is the other client people actually
compare against. Its full DSN surface was diffed against our configuration.

**Where go has nothing:** zstd compression (zlib only), `parsec` auth,
server-side cursors (`comStmtFetch` is a declared constant that is never sent —
every execute writes `CURSOR_TYPE_NO_CURSOR`), binlog (`comBinlogDump` is
likewise a constant only), MariaDB bulk execute, and backpressure.

**Where go had something we did not, now closed:**

| go | ours |
|---|---|
| `loc` + `time_zone` DSN variable | `timeZone` — see below |
| DSN connection string | `MySQLConnectionConfiguration(url:)` |

**Declined, with reasons:**

| go | why not |
|---|---|
| `interpolateParams` | Client-side interpolation of values into SQL text, to skip a round trip. Our interpolation binds instead; adding a mode that does the opposite would undo the guarantee |
| `allowOldPasswords` | pre-4.1 hash, removed from MySQL 8.0 |
| `readTimeout` / `writeTimeout` | Open — see the note on timeouts in `docs/performance.md`. No client can cancel a running command, and go's own answer is to destroy the connection |
| `serverPubKey` | Pre-registered RSA key to skip fetching it during caching_sha2 full auth. A round trip, once per connection, over an already-secure channel |
| `columnsWithAlias`, `timeTruncate`, `rejectReadOnly` | Niche; none changes what is representable |

## Time zones — the one temporal gap, now closed

`TIMESTAMP` is MySQL's only timezone-aware type, and the distinction is
invisible on the wire: a `TIMESTAMP` and a `DATETIME` arrive in the identical
format, a broken-down wall clock with no zone. Only the column type byte
separates them (7 vs 12). The difference is that the server converts a
`TIMESTAMP` through `@@session.time_zone` in both directions.

Measured on one stored row across all five servers:

| session `time_zone` | `TIMESTAMP` | `DATETIME` |
|---|---|---|
| `+00:00` | 12:00:00 | 12:00:00 |
| `+05:30` | **17:30:00** | 12:00:00 |
| `-08:00` | **04:00:00** | 12:00:00 |

So a `TIMESTAMP` value alone is uninterpretable — a wall clock in a zone it does
not name.

`mysql_async` does not handle this at all: values arrive as `Value::Date(…)`, a
naive wall clock, and the zone is the caller's problem. go-sql-driver splits it
into **two** settings that must agree — `loc` labels the naive value the driver
received, while the server-side conversion is controlled separately by passing
`time_zone` as a DSN variable. Its own README warns that `loc` *"does not change
MySQL's time_zone setting"*. Set one without the other and every instant is
silently wrong by the difference.

Ours is one setting: `MySQLSessionTimeZone`, applied to the server at connect
and remembered on the connection, so `MySQLDateTime.date(in:)` can convert.
`MySQLColumnDefinition.isTimeZoneAware` reports which columns it is meaningful
for. The default is `.server` — inherit, changing nothing unless asked — because
moving `time_zone` also moves `NOW()` and `CURDATE()`.

## Two further rust gaps, now closed

**Temporals inside JSON documents.** MySQL stores a `DATETIME` in a JSON value
as an opaque blob: a type byte plus MySQL's packed 64-bit representation, not
text. We rendered it by guessing — string if the bytes looked like printable
ASCII, base64 otherwise — which is wrong in a way that is hard to notice, since
the eight bytes of a packed datetime can be entirely printable and the result is
convincing garbage inside a document that still parses. Now unpacked by type
(`DATE`, `TIME`, `DATETIME`, `TIMESTAMP`), matching
`MysqlTime::from_int64_datetime_packed`; anything still undecoded keeps MySQL's
own `base64:typeN:` convention rather than being guessed at.

**`QUERY_EVENT` status variables.** Skipped wholesale before, on the reasoning
that a consumer replaying DDL needs the text and not the session state. True for
DDL, wrong for everything else: `NOW()` depends on the time zone, comparison on
the collation, and a zero date on `sql_mode`. Now parsed — time zone, sql_mode,
charset triple, auto-increment, utf8mb4 collation, updated databases.

One finding worth recording for consumers: `Q_TIME_ZONE_CODE` is written only
when a statement actually consulted the zone. Across the five servers, MySQL 8.4
and 9.1 emit it on the `BEGIN` preceding a row-based `INSERT` into a `TIMESTAMP`;
the three MariaDB versions never emit it in row-based mode. A consumer cannot
rely on it being present.

## Summary

| dimension | verdict |
|---|---|
| Commands | parity + 4 |
| Binlog events | parity + 12 |
| Column types | parity |
| Auth plugins | parity (minus one deliberately removed algorithm) |
| Client options | parity on everything load-bearing; six knobs declined with reasons |
| Beyond the reference | zstd, transaction payload, partial JSON, MariaDB compression, cursors, backpressure |

The honest caveat: this audits **surface**, not behaviour. Equivalent coverage
of event types is not proof of equivalent decoding. What backs the behaviour is
the 452-test suite against five live servers — three MariaDB, two MySQL — not
this table.

## TLS, across the three engines

| | MySQL | Postgres | SQLite |
|---|---|---|---|
| transport encryption | ✅ | ✅ | n/a — in-process |
| `disable` / `prefer` / `require` | ✅ | ✅ | n/a |
| `verify_ca` / `verify-ca` | ✅ | ✅ | n/a |
| `verify_identity` / `verify-full` | ✅ | ✅ | n/a |
| custom trust roots, client certificates | ✅ `tlsConfiguration` | ✅ `tlsConfiguration` | n/a |
| channel binding | ✗ — none exists in MySQL | ✅ SCRAM-SHA-256-PLUS | n/a |
| RSA public-key pinning | ✅ `serverPublicKey` | n/a | n/a |

**The default is `verify-full` on both network engines, on both the initialiser
and the URL path.** That diverges from `libpq` and `libmysqlclient`, which both
default to `prefer` for backwards compatibility they have to carry and this
library does not. A server with a self-signed or private-CA certificate needs
either a trust root in `tlsConfiguration` or an explicit lower rung; that friction
is the point.

Trust roots and client certificates are configured in code rather than through
the URL. That matches both Rust references — `tokio-postgres` and `mysql_async`
do the same — though `libpq` does accept `sslrootcert` in a connection string.

### How the default was found to be wrong

Postgres's initialiser defaulted to `verify-full`, its documentation said
`verify-full`, and its **URL parser set `prefer`** — with the comment claiming
otherwise on the line directly above. URLs are how nearly every caller configures
a connection, so the advertised secure default applied to almost nobody. MySQL
meanwhile defaulted to `prefer` everywhere, which meant two engines in one library
with opposite postures.

Both now default to `verify-full`, and `PostgresTLSDefaultTests` /
`MySQLTLSModeTests.defaultVerifies` assert it **separately for the initialiser and
the URL**, because that is precisely the gap the original defect fell through.

### SQLite

There is no transport to secure — the library is in-process, so there is no
socket, no handshake and no certificate. The analogous feature is encryption *at
rest* (SQLCipher or the SQLite Encryption Extension), which is a different thing
and is not supported: it needs a differently-built amalgamation, and the vendored
one is stock.

### Certificates from the URL

Added after the default became `verify-full`, because that change created the
gap: with verification on and no way to name a CA in a URL, a `DATABASE_URL`
pointing at a private-CA server could not be made to work at all without
abandoning the URL and building a `TLSConfiguration` in code — and an
environment variable is how most deployments are configured.

| | MySQL | Postgres |
|---|---|---|
| trust root | `ssl_ca` | `sslrootcert` |
| client certificate | `ssl_cert` | `sslcert` |
| client key | `ssl_key` | `sslkey` |

Each engine takes its own ecosystem's spelling — the `mysql` client's
`--ssl-ca` and libpq's `sslrootcert`. `libpq` has had these all along;
`tokio-postgres` has not, so this is one place we go past the reference because
our own default made it necessary.

All of them are read and **parsed** when the URL is parsed, not at connect time:
a mistyped path that surfaced as a handshake failure three layers down would send
the reader looking at the network. Existence alone is not enough, since a file
that is present but is not a certificate would fail at the first connection
instead. A certificate without its key — or the reverse — is refused rather than
half-applied, which would leave the connection unauthenticated while looking
configured. And no error interpolates the URL, because a connection URL carries
the password and error strings end up in logs.

### A crash the new default made reachable

Adding the control case for those tests — connect to a server whose certificate
is *not* trusted — turned up a leaked promise that aborts the process in a debug
build of NIO. `PostgresConnection.connect` creates `readyPromise` before the
channel exists and hands it to the protocol handlers only *after* TLS negotiates.
A failed handshake happens between the two: the TCP connect succeeded so the
outer error path did not run, and nothing owned the promise.

It was always a bug; `verify-full` as a default made untrusted certificates a
routine occurrence rather than a rare one. Now failed explicitly, guarded so it
cannot be completed twice on the path where the handlers *do* own it. Verified by
mutation — removing the guard aborts the full suite.

# Reference clients

Read-only references for porting `SwizzleMySQL`. Gitignored — recreate with
`./Scripts/fetch-references.sh`.

## Grounding decision

**`rust-mysql-common` + `mysql_async` are the primary reference. Everything else
is a consultant.**

They are by the same author and `mysql_async` depends on `mysql_common`, so they
are one coherent design split into protocol primitives and async client — the
same split Swizzle already has. Rust's semantics (value types, enums with
payloads, `Result`, real async) map onto Swift; Python and JS idioms do not.
MIT/Apache, so portable without qualification.

Consult the others only for a *named question*, never for architecture:

- **PyMySQL** — when an algorithm is unclear. Best ed25519 explanation anywhere.
- **node-mysql2** — real-world edge cases and TLS.
- **go-sql-driver** — behaviour sanity check only (MPL, see below).

Where two references disagree, the Rust pair wins unless there is a specific
reason recorded in the code.

## Licensing — read before copying anything

| reference | language | license | how it may be used |
|---|---|---|---|
| `pymysql` | Python | MIT | read closely, port freely |
| `node-mysql2` | JS | MIT | read closely, port freely |
| `rust-mysql-common` | Rust | MIT OR Apache-2.0 | read closely, port freely |
| `rust-mysql-async` | Rust | MIT OR Apache-2.0 | read closely, port freely |
| `go-sql-driver-mysql` | Go | **MPL-2.0** | **behaviour cross-checks only** |

MPL-2.0 is file-level copyleft. A close line-by-line port of an MPL file is
plausibly a derivative work, so go-sql-driver is here to answer "what does a
working client actually do in this case", not to port from. Its *test vectors*
are numeric facts about a published algorithm and are used as such in
`Tests/SwizzleMySQLTests/AuthTests.swift`.

Deliberately **not** cloned: MySQL Connector/J, MariaDB Connector/C and
MariaDB Connector/J. They are the most complete references in existence and they
are GPL/LGPL. Don't bring them into this project.

## What each is best for

**`pymysql`** — clearest prose-like implementation, best first read for any
algorithm. `pymysql/_auth.py` is the single best explanation of every auth plugin
including `client_ed25519`, with RFC 8032 variable names in the comments.

**`rust-mysql-common`** — the protocol crate. Strongest typed modelling of
packets, column types and value encoding; closest in spirit to what we want in
Swift. Note it is *only* the protocol — connection, pool and statement cache live
in `mysql_async`.

**`rust-mysql-async`** — the closest architectural analogue to Swizzle's
executor: async connection, connection pool (`src/conn/pool/` has `recycler.rs`,
`waitlist.rs`, `ttl_check_inerval.rs`, `metrics.rs`) and statement caching in
`src/queryable/stmt.rs`. Read this before writing our pool integration or
statement cache.

**`node-mysql2`** — broadest real-world feature coverage and the most TLS
handling. Has a prepared-statement cache (`maxPreparedStatements`, default
16000). Also the driver Drizzle uses, so its behaviour is what a lot of
production traffic actually exercises.

**`go-sql-driver-mysql`** — smallest and most readable end-to-end flow. Good for
sanity-checking state transitions and for its test suite's known-answer vectors.


---

# Postgres

## Grounding decision

**`postgres-protocol` + `tokio-postgres` are the primary reference. Everything
else is a consultant.**

The same reasoning that picked the Rust pair for MySQL applies here, and more
neatly: `rust-postgres` is one repository split into `postgres-protocol` (3.5k
lines of wire primitives), `postgres-types` (the type system) and
`tokio-postgres` (9k lines of async client). That is precisely Swizzle's own
split — protocol, values, connection — so the seams line up and a question about
"where should this live" usually already has an answer. MIT/Apache, so portable
without qualification.

Consult the others only for a *named question*, never for architecture:

- **`jackc/pgx`** — the best-engineered Postgres driver in any language. Go to
  `pgproto3` for message framing questions and `pgtype` for the type registry.
  MIT, so unlike the MySQL side there is no license asterisk.
- **`asyncpg`** — binary codec completeness. It implements more of the type
  system than anything else and its prepared-statement handling is careful.
- **`postgres-nio`** — Swift and NIO idioms, and a specific negative example:
  its access control is what made this driver necessary, so it is also the
  record of what *not* to keep internal.
- **libpq**, in the PostgreSQL source tree, is the authority when two references
  disagree. Not cloned by the script — read it online.

Where two references disagree, the Rust pair wins unless there is a specific
reason recorded in the code.

## Licensing

Unlike the MySQL ecosystem, there is no copyleft corner here to route around.
Every reference below may be read closely and ported from.

| reference | language | license | how it may be used |
|---|---|---|---|
| `rust-postgres` | Rust | MIT OR Apache-2.0 | primary; port freely |
| `go-pgx` | Go | MIT | read closely, port freely |
| `asyncpg` | Python | Apache-2.0 | read closely, port freely |
| `swift-postgres-nio` | Swift | MIT | read closely, port freely |
| libpq | C | PostgreSQL License | authority; BSD-style, portable |

The one thing to be careful about is not licensing but *provenance*: this driver
exists because postgres-nio would not expose what pillar 3 needs. Copying its
structure wholesale would reproduce the decisions that got us here.

## `rusqlite` — the SQLite reference

Cloned for the SQLite audit, and kept for the same reason the others are: it is
the Rust binding that plays the same role for SQLite that `rust-mysql-common` and
`postgres-protocol` play for their engines. MIT, so portable without
qualification.

SQLite differs from the other two in one important way: **there is no wire
protocol**, so the authority is the C API itself — `Sources/CSQLite/include/sqlite3.h`,
which we vendor, currently 3.50.4. `rusqlite` is the second opinion on how that
API should be *used*, which is where the interesting mistakes live: statement
lifetimes, the `prepare_v2` tail pointer, reading text by length rather than as a
C string. Every defect the audit found was of that shape rather than a missing
feature.

## `goose` — the migration reference

Cloned for the migration comparison. The `-- +swizzle Up` file format is
modelled on goose's `-- +goose Up`, so it is the reference for pillar 1 the way
`rust-mysql-common` is for the MySQL driver. MIT.

Read it for the *shape* of a migration tool rather than for code: the directive
vocabulary, how Go-code migrations register, and what the journal table records
(`version_id`, `is_applied`, `tstamp` — no checksum, which is where the two
designs part company). See `docs/migrations.md` for the full comparison.

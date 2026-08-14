# Swizzle

Migrations + typed query builder + query cache/executor for Postgres, MySQL/MariaDB
and SQLite, in one Swift package.

**Status: all three pillars are built.** Migrations, the query builder, and
code generation, over three drivers written in this repo.

| pillar | state | read |
|---|---|---|
| 1. SQL-first migrations | built | [`docs/migrations.md`](docs/migrations.md), [`examples/migrations`](examples/migrations) |
| 2. Typed query builder — *not* an ORM | built | [`docs/ergonomics.md`](docs/ergonomics.md), [`docs/drizzle-study.md`](docs/drizzle-study.md) |
| 3. sqlc-style code generation | built | [`docs/codegen.md`](docs/codegen.md), [`examples/codegen`](examples/codegen) |

| driver | state | read |
|---|---|---|
| MySQL / MariaDB | ours, including binlog | [`docs/mysql-protocol-checklist.md`](docs/mysql-protocol-checklist.md) |
| Postgres | ours, replacing postgres-nio | [`docs/postgres-protocol-checklist.md`](docs/postgres-protocol-checklist.md) |
| SQLite | ours, over the amalgamation | [`docs/sqlite-audit.md`](docs/sqlite-audit.md) |

Not done, and tracked rather than implied: 15 integration failures that appear
only on Linux ([`docs/platforms.md`](docs/platforms.md)), a thin server-version
matrix, and no fuzzing of the binlog and JSONB decoders.

The sections below are the original type-checker spike, kept because its results
are still the reason the builder is shaped the way it is.

---

## Spike results

Run them yourself:

```
./Scripts/typecheck-bench.sh    # per-construct type-check cost, tuned vs naive
./Scripts/scale-bench.sh 400    # does cost grow linearly with query count?
./Scripts/negative-tests.sh     # does capability gating actually reject?
swift test                      # generated SQL is correct per dialect
```

### 1. The type checker is not the risk

Worst realistic query (4-table join, aggregates, `GROUP BY`, `HAVING`, nested
boolean predicate, `ORDER BY`, `LIMIT`/`OFFSET`) — `q04_fourTableAggregate`:

| design | per-query type-check |
|---|---|
| tuned (`SwizzleQuery`) | **~5 ms** |
| naive control (`SwizzleNaiveSpike`) | ~20 ms |

The pain threshold where an editor feels broken is ~500 ms. We're two orders of
magnitude under it. This was the single biggest risk to the whole project and it
did not materialise.

### 2. Growth is linear, not exponential

Identical 4-table aggregate query, replicated N times in one module:

| queries | tuned total | tuned per-query | naive total | naive per-query |
|---:|---:|---:|---:|---:|
| 50  | 0.33 s | 6.6 ms | 0.67 s | 13.4 ms |
| 100 | 0.53 s | 5.3 ms | 1.17 s | 11.7 ms |
| 200 | 0.92 s | 4.6 ms | 2.10 s | 10.5 ms |
| 400 | 1.74 s | 4.4 ms | 4.14 s | 10.3 ms |

Per-query cost *decreases* as fixed overhead amortises. A 400-query module
type-checks in under two seconds. No superlinear cliff anywhere.

### 3. The design choices still buy a real 2.4×

The naive control is not a strawman — it's what you get transliterating Drizzle
directly, and it's what I'd have written first. Four differences:

| | tuned | naive |
|---|---|---|
| expression types | `SQLExpression<Bool>` — flat, phantom `Value`, structure in a dynamic `SQLNode` | `NBin<NBin<NCol<Int64>, NLit<Int64>>, …>` — grows with tree depth |
| operators | LHS *determines* RHS type | generic on both operands |
| chain | one `SelectQuery` type, every method returns `Self` | new type per join |
| projection | parameter pack `each V` | arity overloads |

The load-bearing one is the operator shape. `users.age > 18` binding `V := Int64`
from the LHS means the integer literal resolves in one step instead of the solver
enumerating every `ExpressibleByIntegerLiteral` type.

### 4. Capability gating works, and the diagnostics are self-documenting

```
error: referencing instance method 'returning' on 'InsertQuery'
       requires that 'MySQL' conform to 'SupportsReturning'
```

All 8 negative cases reject at compile time — `RETURNING` on MySQL, `DISTINCT ON`
off Postgres, `ON DUPLICATE KEY UPDATE` on Postgres, `INSERT OR IGNORE` on
Postgres, `FULL OUTER JOIN` on MySQL, plus column-type and result-tuple mismatches.

This is the design's main advantage over Drizzle, which ships three near-duplicate
packages (`pg-core`, `mysql-core`, `sqlite-core`) to get the same effect.

### 5. Two things the spike found that need fixing

**Optional lifting was missing.** `avg(posts.score)` is `SQLExpression<Double?>`,
and there was no overload comparing a nullable expression to a plain literal, so
`avg(posts.score) > 3.5` didn't compile. Added six lifting overloads. Note the SQL
semantics differ from Swift's — under three-valued logic a NULL LHS yields NULL,
not `false`.

**Those overloads degraded one diagnostic.** `users.age == "not a number"` now
reports `cannot convert 'SQLExpression<Int64>' to 'SQLExpression<String?>'` — the
solver reaches for the optional-lifting overload and surfaces a `String?` the user
never wrote. Correct rejection, confusing message. Worth revisiting with
`@_disfavoredOverload` on the lifting variants.

---

---

## `SwizzleMySQL` — our own MySQL/MariaDB driver

MySQLNIO cannot meet the streaming or prepared-statement-cache requirements: it
has no async/await at all, `onRow` is a push callback with no backpressure hook,
and it does PREPARE/EXECUTE/CLOSE on every query. Full analysis and the
alternatives considered are in [`docs/driver-spike.md`](docs/driver-spike.md).

Built: length-encoded primitives, packet framing including the 16 MiB split rule
in both directions, capability flags as a 64-bit set (MariaDB reuses the upper
half), the full handshake with TLS, `mysql_native_password`,
`caching_sha2_password` including RSA full authentication with key pinning,
`sha256_password`, `client_ed25519`, prepared statements with a reused cache,
streaming with real backpressure, and binlog replication with a row decoder.

Auth vectors come from `go-sql-driver/mysql`'s test suite rather than being
self-generated — an external oracle whose outputs are known to authenticate
against real servers. The wire protocol is grounded on `rust-mysql-common` and
`mysql_async`; an audit against them is recorded in
[`docs/mysql-protocol-checklist.md`](docs/mysql-protocol-checklist.md) and found
real framing bugs.

## What the spike did *not* de-risk, and what happened to each

The spike deliberately tested the thing most likely to kill the project. It
wasn't. Here is where the risks it left open actually landed:

- **MySQL/MariaDB drivers.** Called "the top schedule risk". We wrote our own —
  `MySQLNIO` has no async/await, no backpressure hook on `onRow`, and does
  PREPARE/EXECUTE/CLOSE on every query. `caching_sha2_password`, `sha256_password`
  and RSA key pinning are in; `client_ed25519` is in via a vendored primitive.
  Then the same argument took the Postgres driver too, for a different reason:
  `postgres-nio` keeps `RowDescription` internal, which made pillar 3 impossible
  through it.
- **Macro expansion cost.** Did not arise. There is no `@Table` macro: table
  declarations are **generated** by `swizzle generate schema` and committed, so
  they cost a compile of plain structs and are reviewable in a diff.
- **No network in macro plugins.** Correct, and it decided the design. A sqlc-style
  `#sql("SELECT …")` cannot introspect a live database at compile time, and a
  SwiftPM build-tool plugin cannot either — the sandbox has no network. So the
  generator is a **CLI you run**, whose output you commit, with a lockfile so
  `--verify` needs no database in CI. See [`docs/codegen.md`](docs/codegen.md).
- **MySQL has no transactional DDL.** Still true, and handled: MySQL gets the
  dirty-flag recovery model while Postgres and SQLite get all-or-nothing.

## Layout

```
Sources/
  SwizzleCore/         SQL IR, dialects, capability protocols, renderer
  SwizzleQuery/        typed builder — the target whose compile time matters
  Swizzle/             umbrella re-export
  SwizzleMigrate/      pillar 1: sources, journal, lock, splitter, lints
  SwizzleGenerate/     pillar 3: query files, emitters, lockfile
  SwizzleOnlineDDL/    MySQL shadow-table copy
  SwizzleCLI/          the `swizzle` binary

  SwizzleMySQL/        driver — wire protocol, auth, binlog
  SwizzlePostgresDriver/  driver — wire protocol v3, SCRAM, type registry
  SwizzleSQLite/       driver — over the vendored amalgamation
  SwizzleMySQLEngine/  \
  SwizzlePostgres/      | engine seams: URL parsing, executor, introspector,
  SwizzleSQLiteEngine/ /  migration dialect, query analyzer
  SwizzleConnectionPool/  vendored from postgres-nio

  SwizzleSpike/        realistic worst-case queries, one per function body
  SwizzleNaiveSpike/   A/B control; separate module so its operator overloads
                       cannot contaminate the measurement
examples/
  migrations/          the SQL migration form, one file per directive
  swift-migrations/    the Swift migration form, plus a runner
  codegen/             a schema, queries, and the Swift they generate
Scripts/
  test-servers.sh      native MariaDB/MySQL/Postgres fixtures, no Docker
  test-hygiene.sh      no ungated server-touching suites, no python
  linux-tests.sh       the suite in a Linux container
  typecheck-bench.sh   per-construct cost, tuned vs naive
  scale-bench.sh       linearity check
  negative-tests.sh    compile-time rejection tests
```

Each driver is written to be **extractable** — it depends on `SwizzleCore` and
nothing else of ours, with the engine seam in a separate target — so any of the
three could become its own package without a rewrite. `docs/architecture.md` has
the separation rules and `docs/adding-a-database.md` is what a fourth engine
would follow.

The schema in `SwizzleSpike/Schema.swift` is hand-written in exactly the shape the
future `@Table` macro will emit. For a type-checker spike that's the correct
methodology — macro output is plain structs, so expanding a macro would only add
build latency without changing what the solver sees at the call site.

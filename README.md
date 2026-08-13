# Swizzle

Migrations + typed query builder + query cache/executor for Postgres, MySQL/MariaDB
and SQLite, in one Swift package.

**Status: type-checker spike only.** No drivers, no migrations, no macros yet. What
exists is enough to answer one question — *can Swift's type system express a
Drizzle-class query builder without melting the compiler?* — and that question is
now answered.

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

Built so far (36 tests): length-encoded primitives, packet framing including the
16 MiB split rule in both directions, capability flags as a 64-bit set (MariaDB
reuses the upper half), HandshakeV10 parsing, and the
`mysql_native_password` / `caching_sha2_password` scrambles.

Auth vectors come from `go-sql-driver/mysql`'s test suite rather than being
self-generated — an external oracle whose outputs are known to authenticate
against real servers.

`client_ed25519` is deliberately unimplemented and fails with an actionable
error; see the driver spike doc for why Swift Crypto can't currently express it.

## What this does *not* de-risk

The spike deliberately tested the thing I thought was most likely to kill the
project. It wasn't. The remaining risks are unchanged and mostly not about types:

- **MySQL/MariaDB drivers.** `MySQLNIO` is far less maintained than `PostgresNIO`.
  `caching_sha2_password`, MariaDB `ed25519` auth, prepared-statement quirks. This
  is now the top schedule risk.
- **Macro expansion cost.** `@Table` doesn't exist yet. Macros are slow and a
  200-table schema is a different measurement than this one. Needs its own spike.
- **No network in macro plugins.** A sqlc-style `#sql("SELECT …")` cannot introspect
  a live DB at compile time. Planned path: migrations are the schema source of
  truth → CLI applies them to a scratch DB → dumps a schema IR → a SwiftPM
  build-tool plugin (declared inputs/outputs, sandbox-legal) generates Swift.
- **MySQL has no transactional DDL.** Migrations need a dirty-flag recovery model
  there while Postgres and SQLite get all-or-nothing.

## Layout

```
Sources/
  SwizzleCore/         SQL IR, dialects, capability protocols, renderer
  SwizzleQuery/        typed builder — the target whose compile time matters
  Swizzle/             umbrella re-export
  SwizzleSpike/        realistic worst-case queries, one per function body
  SwizzleNaiveSpike/   A/B control; separate module so its operator overloads
                       cannot contaminate the measurement
Scripts/
  typecheck-bench.sh   per-construct cost, tuned vs naive
  scale-bench.sh       linearity check
  negative-tests.sh    compile-time rejection tests
```

The schema in `SwizzleSpike/Schema.swift` is hand-written in exactly the shape the
future `@Table` macro will emit. For a type-checker spike that's the correct
methodology — macro output is plain structs, so expanding a macro would only add
build latency without changing what the solver sees at the call site.

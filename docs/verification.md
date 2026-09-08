# What has actually been verified

This file exists because "is it clean?" kept getting answered with an opinion.
It is not a status report and it is not a plan. It is a list of claims, the
method that backs each one, and — the column that was always missing — the ones
nothing backs yet.

Every number here comes from a command in the last section. If a number and the
prose disagree, the number is right.

## How to read it

A verdict like "the driver is sound" is not a claim this file will ever make,
because no method available to us establishes it. What the methods establish is
narrower, and each is blind to something specific:

| method | what it shows | what it cannot see |
|---|---|---|
| **Coverage** | which lines ran | whether the answer was right. A line that runs and returns nonsense is covered |
| **Mutation** | which lines are *checked*, not merely run | anything absent — a missing bound, an unhandled message, a feature not written |
| **Differential oracle** | our answer matches an independent one | anything both sides get wrong the same way, and anything neither is asked |
| **Fuzzing** | we survive inputs in the shapes the generator makes | shapes it does not make. Ours are seeded, so the shapes are fixed |
| **Integration suite** | it works against real servers, real versions | versions not in the matrix; states those servers were not driven into |
| **Hostile-input review** | reading each peer-controlled value and asking what a malicious or buggy peer could set it to | whatever the reader did not think of |

The last one has no automation behind it. It is a person reading code. It is
also, by a wide margin, the method that has found the most serious bugs here —
so its coverage is worth tracking explicitly, because nothing else will notice
when it has not been applied.

## Ledger

Status is one of **verified** (a named method backs it), **partial** (backed for
some of the surface), or **unverified** (nothing backs it — not "probably fine").

### Hostile input from the peer

The question: for every value that arrives from the network, what happens if it
is absent, zero, enormous, or smaller than a value derived from it earlier?

| area | status | method | notes |
|---|---|---|---|
| MySQL wire lengths | verified | bounds review + `WireLengthBoundsTests` | length-encoded integers, column counts |
| Postgres malformed input | verified | bounds review + `MalformedInputTests` | array dimensions, extended types |
| SQLite argument bounds | verified | bounds review + `SQLiteBoundsTests` | blob size, busy timeout |
| Connection pool stream counts | verified | bounds review + `PoolStreamAccountingTests` | found 5 traps + 1 false assertion |
| MySQL binlog column metadata | verified | bounds review + `BinlogDecimalMetadataTests` | found 2 crashes: DECIMAL `scale > precision` |
| MySQL compression | verified | bounds review + `CompressionBoundsTests` | found a decompression bomb on the binlog path |
| MySQL handshake, auth, binary temporal | verified | bounds review | signed auth-data length, `xor` length mismatch, `UInt8`-bounded temporal slices — all already guarded |
| MySQL prepare / result state machines | verified | bounds review | counts held as `Int`, so the decrements cannot trap |
| Postgres array bounds, text format | verified | bounds review + `PostgresArrayTextBoundsTests` | found an `Int32` overflow crash and 3 unbounded lengths |
| Postgres array bounds, binary format | verified | bounds review + `MalformedInputTests` | dimension product, element count |
| **Postgres `reserveCapacity` sizing** | **unverified** | hardened, but untested | the decoder returns nil either way, so no assertion distinguishes bounded from unbounded. See `PostgresCountBoundsTests` |
| Postgres NUMERIC headers | verified | `MalformedInputTests` header sweep | 4 `Int16` fields; the negative-capable ones swept in full |
| Postgres bit / geometry / range decoding | verified | `MalformedInputTests` fuzz + extreme lengths | already in the sweep |
| Postgres tsquery / interval / jsonpath | verified | `MalformedInputTests` | were absent from the sweep entirely until now |

### Correctness of values on the wire

| area | status | method | notes |
|---|---|---|---|
| MySQL parameters, results, binlog, DECIMAL | verified | 4 differential oracle suites | see `Tests/SwizzleMySQLIntegrationTests/*Oracle*` |
| Postgres parameters | partial | 2 oracle suites | narrower than MySQL's |
| SQLite values, all six kinds | verified | `SQLiteValueOracleTests`, bound vs literal | 19 subjects x typeof/quote, plus 6 column affinities |
| **SQLite signed zero** | **not testable** | — | SQLite exposes no expression that distinguishes -0.0 from 0.0; division by zero is NULL and printf renders both the same. Driver round-trip only |

### Coverage and checkedness

| module | region coverage | mutation score |
|---|---|---|
| SwizzleConnectionPool | 85.6% | 70.0% |
| SwizzleMySQL | 85.2% | 82.3% |
| SwizzlePostgresDriver | 86.6% | **unknown** |
| SwizzleSQLite | 85.2% | **unknown** |
| SwizzleQuery | 66.0% | 53.6% (filter reaching 56% of the module) |
| SwizzleMySQLEngine | 69.6% | **unknown** |

A mutation score of "unknown" is the interesting cell. Coverage says the lines
ran; only mutation says anything checked them.

### Flakiness

| claim | status | method |
|---|---|---|
| The suite is deterministic under parallel load | partial | nightly runs it 5x; timing-sensitive suites are gated out and run alone |
| No test asserts on wall-clock duration in the parallel run | verified | the six that did were rewritten to assert the mechanism |
| Pool tests are capable of failing | verified | `Scripts/pool-test-lint.sh`, in CI |

## Known bias in how this file gets written

Every incorrect claim made about this project so far has been optimistic. Not
one has been a false alarm. When a row here is uncertain, it belongs in
**unverified**, not in **partial** — the error has never gone the other way.

Related: the six pool crashes fixed on 2026-09-08 were found by pointing an
audit that already existed at a module that had already been declared done.
The gap was not capability. It was that nothing tracked which modules the audit
had been applied to. That is what the first table is for.

## Reproducing every number

```sh
# Coverage, per module
swift test --enable-code-coverage
llvm-cov report "$(find .build -name 'SwizzlePackageTests*' -type f -perm -u+x ! -path '*dSYM*' | head -1)" \
  -instr-profile "$(find .build -name default.profdata | head -1)" | grep Sources/Swizzle

# Mutation score for a module
./Scripts/mutation-sweep.sh Sources/<Module> <TestTarget>

# Oracle suites per driver
find Tests -name '*Oracle*.swift' -o -name '*Grounding*.swift'

# Integration servers
./Scripts/test-servers.sh up && swift test

# Pool tests can fail
./Scripts/pool-test-lint.sh

# Compile-time gates
./Scripts/negative-tests.sh
```

## Caveats on the numbers above

**Mutation scores count timeouts as kills.** A mutant that hangs is recorded as
killed, which is usually right — a hang is a test noticing — but not always. The
`SwizzleConnectionPool` run had 6 such out of 98, so the true score is somewhere
in `[63.6%, 70.0%]`. An earlier sweep reported 90.3% almost entirely on
timeouts, because its bound was shorter than the suite itself; the bound is now
derived from a measured baseline, which is why this one is believable.

**A survivor is not automatically a gap.** Of the 42 in that run, 9 mutate a
`#elseif` compile condition in vendored NIO code and cannot change the built
binary. One mutates `max >= used ? max - used : 0` to `>` — at `max == used`
both yield zero, so it is an equivalent mutant, not a hole.

But one was real, and is the reason this section exists: every circuit-breaker
test set the trip threshold to zero so the trip was reachable without waiting,
which meant the whole suite agreed with a pool that ignored the threshold
entirely. Mutating the comparison left it green. There is now a negative control
that fails when the threshold is ignored, checked by ignoring it on purpose.

That is the failure mode this whole file is about, in miniature: eight passing
tests about a feature, none of which could tell whether half of it worked.

## Triage of the SwizzleConnectionPool survivors

All 42 from the run above, so the next person does not re-derive it.

**Cannot change the built binary (9).** `NIOLock.swift` lines 56, 74, 86, 98 —
every one mutates the `#elseif (compiler(<6.1) && !os(WASI)) || ...` condition.
That is a compile-time selection in vendored NIO code, not runtime logic.

**Equivalent at the boundary (roughly a dozen).** Comparisons where both
operators compute the same answer at the only value that differs. Examples:
`closedAction.maxStreams >= closedAction.usedStreams` and
`max >= used ? max - used : 0` both yield zero at equality; `maxStreams >=
info.oldMaxStreams` adds zero on one branch and subtracts zero on the other;
`connections.count > softLimit` relaxed to `>=` searches an empty range.

**Dead by construction (2).** `if retry || self.stats.active < minimum` — the
only caller passes `retry: true`, so the right-hand side never runs. Recorded
rather than "fixed": the branch is reachable if a second caller ever appears.

**Never driven (1).** `if running == 100` in `ConnectionPool.run` — the
concurrency valve. No test drives a hundred simultaneous pool events.

**Real gaps, now covered** — see `PoolSurvivorTests`. Each is verified by
applying the mutation and watching the test fail, because four of the five did
not bite when first written:

- the connection lookups in `rescheduleIdleTimer` and
  `destroyBackingOffConnection`, where inverting `==` finds the first connection
  that is *not* the one asked about. Invisible with one connection in the pool,
  which is what every existing test had;
- `isConnected && !isDraining` in the promotion search — relaxed to `||` it
  promotes a connection that is on its way out;
- `keepAlive.usedStreams < maxStreams` at a maximum of zero, which a server may
  set mid-session;
- `connections.count < minimum` on close, which relaxed to `<=` replaces a
  connection the pool did not lose.

**Already fixed before this triage (1).** The circuit-breaker threshold
comparison, covered by the negative control described above.

The lesson worth keeping: a survivor list is mostly noise, and reading it is the
work. Three of the four real gaps were invisible to every existing test for the
same reason — the tests used a pool with one connection in it.

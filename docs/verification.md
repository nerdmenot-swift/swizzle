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
| **MySQL driver arithmetic on peer values** | **unverified** | — | the pool audit has not been pointed here |
| **Postgres driver arithmetic on peer values** | **unverified** | — | same |

### Correctness of values on the wire

| area | status | method | notes |
|---|---|---|---|
| MySQL parameters, results, binlog, DECIMAL | verified | 4 differential oracle suites | see `Tests/SwizzleMySQLIntegrationTests/*Oracle*` |
| Postgres parameters | partial | 2 oracle suites | narrower than MySQL's |
| **SQLite value round-trip** | **unverified** | — | no differential oracle exists |

### Coverage and checkedness

| module | region coverage | mutation score |
|---|---|---|
| SwizzleConnectionPool | 85.6% | in progress |
| SwizzleMySQL | 85.2% | 82.3% |
| SwizzlePostgresDriver | 86.6% | **unknown** |
| SwizzleSQLite | 85.2% | **unknown** |
| SwizzleQuery | 66.0% | **unknown** |
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

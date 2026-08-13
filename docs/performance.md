# Performance audit

A driver is the floor everything above it stands on, so "fast enough" should be
a measurement rather than an opinion. This records what was found, what it cost,
and what was done about it.

Reproduce with `SWIZZLE_BENCH=1 swift test -c release --filter Benchmark`.
Numbers below are an M-series Mac against a local MariaDB 12.2 over loopback.

## The headline

A 50,000-row `SELECT` against a five-column table, warm connection:

| | 50k rows |
|---|---|
| before | 10.2 s |
| after | **0.028 s** |

**~370× faster.** Two independent bugs, one algorithmic and one
allocation-driven; both are described below.

## How that compares to the `mysql` client

Worth stating carefully, because an earlier version of this document got it
wrong. It compared our warm in-memory query against the CLI's *total* wall clock
— which includes `fork`/`exec`, connecting, authenticating, and formatting every
row back into text — and concluded we were "ahead of the CLI". That was not a
like-for-like comparison and it flattered us.

The client is C++ (`client/mysql.cc` in the server source, in a C-ish style)
linked against `libmysqlclient`, which is C. Measured on the same table, same
server, same machine, best of 7, output to `/dev/null`:

| | total | minus fixed overhead |
|---|---|---|
| CLI, fixed overhead (`fork`/`exec` + connect + auth) | 0.0069 s | — |
| CLI, default boxed-table output | 0.0404 s | 0.0334 s |
| CLI, `-B --quick` (fastest mode) | 0.0328 s | **0.0258 s** |
| Swizzle, connect + auth | 0.0003 s | — |
| Swizzle, buffered into typed values | — | **0.0283 s** |
| Swizzle, streaming | — | 0.0320 s |

So: **the same class, within about 10% either way.** The CLI's fastest mode is
marginally ahead of our buffered decode (25.8 ms vs 28.3 ms); we are ahead of the
mode a person actually types (33.4 ms). Nobody is 2× anybody.

Two caveats that keep even this from being exact:

- **The work differs.** The CLI parses the text protocol and formats the values
  straight back out as text. We parse the text protocol and decode into typed
  Swift values — `Int64`, `Double`, `String` — which are retained in memory.
  Comparable magnitude, genuinely different jobs.
- **Connect is not a real win.** Ours looks 23× cheaper, but almost all of the
  CLI's 6.9 ms is process startup and dynamic linking, which a library does not
  pay. Ignore that row except as a reminder to subtract it from the others.

Reproduce with `Scripts/cli-comparison.sh` for the CLI side and
`SWIZZLE_BENCH=1 swift test -c release --filter CLIComparison` for ours. The
script reports a **mean** over 20 runs rather than the minimums tabulated above —
`time -p` cannot resolve a single 30 ms run — so it reads a few milliseconds
higher across the board. Compare like with like.

## 1. Result-set buffering was quadratic

The one that mattered. Rows accumulated into a `struct` held inside the
handler's `activity` enum, extracted per packet with `case .buffering(var
state)`, mutated, and written back. The enum kept its own reference to the row
array throughout, so every single `append` saw a refcount above one and
**copied the entire array**. O(n) per row, O(n²) per query.

Nothing failed. Every correctness test passed the whole time — the driver
returned exactly the right rows, just slower and slower as the result set grew.
It only showed up against a stopwatch:

```
 5000 rows   0.105s
10000 rows   0.399s   3.79x
20000 rows   1.577s   3.95x
40000 rows   6.422s   4.07x    ← time quadruples per doubling
```

The accumulators (`Buffering`, `Streaming`, `Binlog`) are now `final class`, so
extracting one from the enum yields a reference rather than a second owner:

```
10000 rows   0.005s
40000 rows   0.021s   ~1.9x per doubling — linear
```

**~300× on this path alone.** `ResultSetScalingTests` guards the *shape* rather
than a throughput number: 4× the rows must not cost more than 8× the time.
A threshold would be machine-dependent; the exponent is not.

## 2. The text protocol allocated twice per value and discarded both

`decodeText` copied the value into a `[UInt8]`, built a `String` from it, and
parsed that — two heap allocations for every value that is not itself a string.
The temporal parsers, built on `split`, then paid for an array of `Substring`s
per field on top.

Per-value cost, decoding only, no server involved:

| | before | after | |
|---|---|---|---|
| `DATETIME` | 907 ns | 19 ns | **48×** |
| integer | 44 ns | 13.6 ns | 3.2× |
| string | 32 ns | 32 ns | unchanged — it has to allocate |
| whole 5-column row | 1301 ns | 266 ns | 4.9× |

A single `DATETIME` column had been roughly **70% of the time to decode a row**.

Values are now parsed straight out of the packet through
`withUnsafeReadableBytes`, allocating only when the result genuinely is bytes.
Floating point still goes through `Double(String:)`: decimal-to-binary
conversion has to round correctly across the whole exponent range, and that is
not worth re-deriving to save a few nanoseconds on a rare column type.

The rewrite is *stricter* than what it replaced. `12:34:56.9z` used to decode as
12:34:56 with the microseconds silently zeroed; it is now refused, so
`decodeText` falls back to `.bytes` and the caller receives the server's literal
text rather than a value that is quietly wrong. `TextParsingEdgeTests` pins the
boundaries — `Int64.min`, the top of `UInt64`, the zero date, ±838:59:59,
fractional-second scaling, and every malformed shape that must fall back.

## 3. Column lookup by name was linear, per access

Each row carried the column array and `row["name"]` scanned it. Invisible on
five columns. On sixty, reading *every* column by name — which is exactly what
mapping a row onto a model does — was quadratic in the table's width, and cost
**more than decoding the rows off the wire**.

There is now one `MySQLRowSchema` per result set, holding a name→index map built
once, referenced by every row. Reading a full 60-column row by name went from
357k to 1,054k rows/s, and no longer degrades as tables get wider.

Duplicate column names keep the first occurrence, because `SELECT a.id, b.id`
is legal and a linear search returned the first — a map built with
`updateValue` would have kept the last and silently changed which column a
caller reads.

For the fastest path, resolve once with `schema.index(of:)` and then read by
index; that is what a generated mapper should do.

## 4. The binlog table-map cache grew without bound

Row events carry no schema — they cite a table id and the decoder must already
hold the map. So the cache cannot be dropped eagerly. But table ids are not
stable either: the server mints a new one whenever a table definition re-enters
its cache, and nothing on the wire ever says an id is dead. A long-running CDC
consumer accumulated dead maps forever, each holding a full column list.

The reference has the same problem and bounds it by clearing on rotate, with the
comment *"we'll keep table map size within reasonable bounds — TODO: This value
is arbitrary"*. We clear on a real rotate too, but a rotate is driven by
`max_binlog_size` (1 GB by default) and may be hours apart. A hard bound of 1024
entries, evicted oldest-first, is what actually makes the growth impossible —
and sits far above any real statement's needs, since MySQL's own join limit is
61 tables.

## 5. Prepared statements leaked on the *server*

Not a client-memory leak, which is why the memory numbers below missed it
entirely. `COM_STMT_PREPARE` allocates a statement **on the server**, and it
lives until `COM_STMT_CLOSE` or the connection dies. The statement cache
normally owns that lifetime — but with caching disabled
(`statementCacheCapacity: 0`) nothing did.

The buffered path looked like it handled this:

```swift
defer { Task { try? await connection.closeStatement(statement) } }
```

It does not. MySQL connections are strictly serial and the handler *rejects* a
command that arrives while one is in flight — deliberately, so an overlapping
command cannot corrupt the stream. So the detached task races the next query,
and whichever loses is rejected with the error swallowed by `try?`. Measured
against `Prepared_stmt_count`: **50 uncached queries left 24 statements
allocated forever**. The streaming paths did not even attempt a close, and
leaked one per call.

`max_prepared_stmt_count` is a *global* server setting defaulting to 16382, so
this does not degrade gradually — it works, and then every client of that
server starts getting *"Can't create more than max_prepared_stmt_count
statements"*.

The fix is a `deferredClose` command kind that the handler **queues instead of
rejecting**, safe to queue precisely because the server sends no reply to
`COM_STMT_CLOSE`. Every return to idle now flushes the queue, which for a stream
is exactly the moment it ends — the one moment the caller cannot observe. The
cursor path needs more, because the connection falls idle *between* fetches, so
its close hangs off `CursorState.deinit`: that covers draining to the end,
abandoning mid-way, and dropping the sequence unread.

`StatementLifetimeTests` measures `Prepared_stmt_count` directly rather than by
proxy, and polls rather than sampling once — the distinction being tested is
*slow to clean up* versus *never cleans up*.

## Memory

No client-side leaks found.

| | growth |
|---|---|
| 200 × 2,000-row queries | +0.0 MB |
| 2,000 distinct prepared statements (bounded cache) | +0.2 MB |
| streaming 400,000 × 240-byte rows (~100 MB) | **+0.9 MB peak** |

That last one is the load-bearing number. The backpressure tests prove the
mechanism — an unconsumed stream stalls rather than draining the socket — but
until now nothing measured the consequence. Reading a result set an order of
magnitude larger than the process holds costs under a megabyte.

## Where things stand

| path | rows/s |
|---|---|
| text protocol, buffered | 2,258,802 |
| binary protocol, buffered | 2,408,299 |
| streaming | 2,050,760 |
| binlog row decoding | 3,482,550 |
| decoding alone, no server | 3,752,844 |

End-to-end is now within striking distance of pure decode, which means the
remaining time is mostly the server and the loopback round trip rather than us.

## SQLite: one connection is a ~6× ceiling

SQLite has no server, so the interesting question is not throughput but
*concurrency*. `SQLiteConnection` serialises every call through one queue —
correct for a single handle, since SQLite's own threading rules demand it — while
WAL allows readers to run concurrently with each other and with the writer. Eight
tasks, six scanning queries each, over 20,000 rows:

| | elapsed |
|---|---|
| one shared connection | 57 ms |
| `SQLiteReaderPool` | **10 ms** |
| opening a read-only connection | 21 µs |

Reproduce with
`SWIZZLE_BENCH=1 swift test --filter SQLiteConcurrencyBenchmark`.

That third row is why the pool is not built on `SwizzleConnectionPool`. Pooling
usually exists to avoid the cost of connecting; here connecting costs 21 µs, with
no socket, handshake, or authentication to pay for. The value is parallelism, so
the type is a fixed set of read-only connections plus one writer, and none of the
keep-alive, backoff, or ageing machinery a network pool needs.

The writer is deliberately singular: SQLite permits one writer regardless, so a
pool of writers would not add concurrency — it would replace a fair FIFO queue
with a race for the write lock, and `SQLITE_BUSY` after the busy timeout.

## On unsafe Swift and C

Worth answering directly, since it was the obvious place to reach.

**Neither bug that mattered was an arithmetic problem.** The quadratic one was
ownership — a `struct` where a `class` belonged — and C would have made it
neither better nor easier to find. The second was allocation, and C would have
saved nothing that not allocating did not already save.

Where **unsafe Swift** earned its place is precisely where it was used:
`withUnsafeReadableBytes` and a cursor over `UnsafeRawBufferPointer` to walk
ASCII without materialising a `String`. That is bounded, non-escaping, and
checked by the same tests as everything else.

Where **C** earned its place is where there is a real algorithm to import rather
than a loop to tighten: zstd, zlib, and libsodium's ed25519 are all vendored,
and all three are cases where hand-writing the thing would be slower *and*
worse. Nothing left in the hot path looks like that.

What remains is the `[UInt8]` allocation behind `.bytes`, at 32 ns. It could be
removed by having values borrow a slice of the packet buffer — but a slice keeps
the whole buffer alive, so one short string out of a 16 MiB packet would pin
16 MiB. That trade is not worth taking in a driver whose headline feature is
bounded memory.

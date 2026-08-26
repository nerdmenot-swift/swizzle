# SQLite audit, against `sqlite3.h` and `rusqlite`

The same treatment as `mysql-protocol-checklist.md §8` and the Postgres
checklist's audit section, for the engine that has no protocol to check.

## What the reference is

SQLite has no wire format, so the authority is the **C API** —
`Sources/CSQLite/include/sqlite3.h`, vendored, currently **3.50.4**. That says
what is possible; it does not say what a correct client does with it. For that
the audit used **`rusqlite` 0.40.1**, cloned into `references/` for this pass: it
is the Rust binding that plays the same role for SQLite that
`rust-mysql-common` and `postgres-protocol` play for their engines.

That shifted where the defects were. MySQL and Postgres yielded framing and
codec bugs; every SQLite defect was about **how the API is used** — statement
lifetimes, a tail pointer, a length. None of them was a missing feature, and all
four were silent.

## Four defects, all fixed

### 1. Everything after the first statement was silently discarded

`sqlite3_prepare_v2`'s fifth argument is the *tail*: it compiles one statement
and points at what follows. We passed `nil`, so

```sql
INSERT INTO t VALUES (1); INSERT INTO t VALUES (2)
```

inserted **one** row, returned `SQLITE_OK`, and told the caller nothing.
`rusqlite` refuses the same input with `Error::MultipleStatement`.

Now refused, with the remainder handed back to SQLite rather than scanned here —
a `;` inside a string literal or a quoted identifier is not a statement boundary,
and SQLite is the authority on which is which. Trailing whitespace, comments and
a final `;` compile to nothing and stay legal. Migrations were never affected;
they go through `SQLStatementSplitter` and arrive one statement at a time.

Both compile sites now share the check, including `describe`, which codegen uses
— a query file entry holding two statements would otherwise have been described
by its first alone.

**A second bug hid inside the first.** The obvious fix reads the tail after the
call returns, and the tail points into the temporary buffer Swift creates for
implicit `String` → `UnsafePointer<CChar>` bridging, which is dead by then. It
*appeared* to work: it read a zero byte, so the check never fired, and the tests
still failed. `withCString` is what makes the pointer outlive the call.

### 2. Text was read as a C string, truncating at an embedded NUL

`sqlite3_column_text` returns a NUL-terminated pointer, and `String(cString:)`
takes it at its word. SQLite text may contain NUL bytes, and
`sqlite3_column_bytes` is what says how long the value really is:
`'a' || char(0) || 'b'` arrived as `"a"`.

`rusqlite` builds its `&str` from `from_raw_parts(text, sqlite3_column_bytes(…))`
and quotes the SQLite book on calling `column_text` *first* and `column_bytes`
after — the conversion can change the length, so the order matters. We now do the
same, decoding with `String(decoding:as:)` so invalid UTF-8 is repaired rather
than costing the caller a whole row.

### 3. The same truncation on the way in

`sqlite3_bind_text(…, -1, …)` means "up to the NUL". Binding
`"before\0after"` stored six characters. The round trip looked correct only
because the read side truncated identically — the two bugs concealed each other.

Now bound with an explicit byte count, with two details that matter: a NULL
pointer binds SQL `NULL`, so an empty string needs a real pointer, and a length
over `Int32.max` is refused rather than trapping.

**The test's first version was wrong about the server.** `length()` on a *text*
value is documented to count "characters prior to the first NUL", so it truncates
in exactly the way being tested for and cannot be the instrument.
`length(CAST(v AS BLOB))` counts bytes.

### 4. Corruption was indistinguishable from a typo

`SQLITE_CORRUPT` fell into `SQLErrorKind.other`, alongside syntax errors — while
being the one failure where retrying is pointless and the answer is a backup.

`dataCorrupted` is now its own kind, and the blind spot was not SQLite's alone:
Postgres `XX001`/`XX002` and MySQL's "table is marked as crashed" family were
folded into `.other` too. All three now report it. Proved by damaging a real
database file and reading it back, not by asserting a table lookup.

Also newly classified: `SQLITE_NOMEM` → `.outOfSpace` (matching Postgres's
`53200`), `SQLITE_MISMATCH` → `.checkViolation` (a rejected value, which is what
`STRICT` tables raise), `SQLITE_PROTOCOL` → `.lockTimeout`.

## Transactions, which did not exist

MySQL and Postgres both grew `withTransaction` early. SQLite was left telling
callers to issue `BEGIN` themselves, while `rusqlite` has
`Connection::transaction` with the same three behaviours — a gap against the
reference and an inconsistency between our own three engines at once.

`withTransaction`, `withSavepoint` and `isInTransaction` now exist, with SQLite's
three `BEGIN` flavours. Two decisions worth recording:

- **State comes from `sqlite3_get_autocommit`**, not from counting `BEGIN`s — the
  same rule the MySQL driver follows in reading the server's status word. SQLite
  drifts in a specific way: some errors make it roll the transaction back
  *itself*, after which a client's `ROLLBACK` fails with "cannot rollback - no
  transaction is active", turning one error into two and hiding the first. The
  commit path checks too, so a body that provoked an automatic rollback and then
  returned normally is reported rather than being told its work committed.
- **Nesting is refused** rather than flattened. SQLite has no nested `BEGIN`, and
  swallowing an inner one would make the inner scope's commit end the *outer*
  transaction. The error names `withSavepoint`.

## Measured, and deliberately not built

A **prepared-statement cache**. Both other drivers have one and `rusqlite` has
`prepare_cached`, so its absence is a real difference. For MySQL and Postgres a
prepare is a network round trip; for SQLite it is a local parse, so the question
was measured (`SWIZZLE_BENCH=1 swift test --filter SQLitePrepareCostBenchmark`):

| | µs |
|---|---|
| `query`: hop + prepare + bind + step + finalise | 6.4 |
| reuse: two hops + step + reset | 8.1 |
| floor: hop + trivial statement | 4.7 |

Reusing a prepared statement is **slower**, because every call hops to the
connection's serial queue and `query` does the whole cycle inside one hop while
reuse costs two. The fixed per-call cost is ~4.7 µs of a 6.4 µs query, leaving
~1.7 µs of parsing for a cache to compete for. `sqlite3_reset` was added for the
measurement and is kept, being the one statement-lifecycle call the driver never
made.

## Deliberately out of scope, with reasons

`rusqlite` is a general-purpose binding; Swizzle is a query builder, a migration
runner and a code generator. These are its features that are not ours, and why:

| feature | why not |
|---|---|
| `backup` | file-level operations, not query execution — `VACUUM INTO` covers the common need in SQL |
| incremental blob I/O | streams a single blob by offset; nothing in the query builder can express it |
| user-defined functions, aggregates, collations | would need a Swift callback surviving into C, per connection — a real feature, and a different one |
| `update`/`commit`/`rollback` hooks, authorizer, trace | same shape, same answer |
| `serialize`/`deserialize` | in-memory database images |
| session extension | changeset capture; the binlog's analogue, and out of scope there too |
| `sqlite3_limit`, `db_config` | per-connection tuning nothing above it exposes |

The `SQLITE_OPEN_READONLY` reader pool covers what `stmt_readonly` would have
been used for, and more strongly: the connection cannot write at all rather than
the statement being checked.

## Cancellation, which the first pass never looked at

The audit above covers statement compilation, text encoding, the error taxonomy and
transactions. It does not mention `sqlite3_interrupt`, progress handlers, or timeouts —
not in the findings and not in the out-of-scope table. That omission cost six CI rounds:
a query timeout that reported on time and did not stop the statement, chased through the
driver four times before the cause turned out to be a toolchain difference.

So this is the pass that was missing, against **rusqlite** (the closest analogue — a typed
wrapper over the same C API) and **GRDB** (the Swift one, and therefore the one whose
absence a Swift user actually notices).

### Where the three agree

| | Swizzle | rusqlite | GRDB |
|---|---|---|---|
| check for cancellation *before* stepping | `cancelled.isSet` guard | — | `checkCancellation()` |
| `sqlite3_interrupt` on cancellation | yes | `InterruptHandle` | yes |
| interrupt lock **not** held across the query | yes | yes, deliberately | yes |

That third row is worth dwelling on, because rusqlite documents the trap in the code:

> It's unsafe to call `sqlite3_close` while another thread is performing a
> `sqlite3_interrupt`, and vice versa, so we take this mutex during those functions. This
> protects a copy of the `db` pointer … however the main copy, `db`, is unprotected.
> **Otherwise, a long-running query would prevent calling interrupt, as interrupt would
> only acquire the lock after the query's completion.**

Which is precisely the failure this driver spent a week not having. `interruptLock` is
held in `close()` and `interrupt()` and nowhere else — correct, and now correct on
purpose rather than by luck.

### Where we are ahead

**Neither reference uses a progress handler for cancellation.** Both rely on the
pre-flight check plus `sqlite3_interrupt`, and that combination has a documented hole:
the interrupt does nothing if no statement is running, and does not apply to one begun
afterwards. So a cancellation landing between `prepare` and the first `step` is spent on
nothing.

`sqlite3_progress_handler` is polled by the statement itself every 2000 VDBE
instructions, so there is no window to miss. Swizzle installs one and reads the same flag
the interrupt path sets, which makes the bound a guarantee rather than best-effort. GRDB
would exhibit the same latency under the same conditions.

### Where they are ahead

**A public way to interrupt.** GRDB exposes `interrupt()` on `Database`, `DatabaseQueue`,
`DatabasePool` and `DatabaseReader`; rusqlite hands out an `InterruptHandle` that is
`Send + Sync` precisely so another thread can stop a running query. Swizzle's `interrupt()`
is internal — reachable only through task cancellation. That covers most Swift code, and
does not cover a pool aborting in-flight work at shutdown, or a UI cancel button holding a
connection rather than a `Task`.

**A way to opt out of it.** GRDB carries `interruptsWhenCancelled` on its suspension state
and an `ignoringCancellation { }` scope, which it uses for its own transaction-observer
callbacks. Swizzle always interrupts. That is the right default and the wrong absolute: a
cleanup write inside a cancelled task is exactly the statement you want to finish, and
today there is no way to say so.

### A deliberate divergence

GRDB's `busyMode` defaults to `.immediateError` — contention fails straight away — with
`.timeout` and `.callback` as opt-ins. Swizzle waits five seconds by default, configurable
per connection. Ours is the friendlier default for the common case and the less flexible
surface; GRDB's is the safer one for an app that must never block its main thread. Neither
is wrong, and the difference should be a choice rather than a discovery.

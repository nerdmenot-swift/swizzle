# The executor bridge

Connects the query builder to a driver. Before this, the two halves had never
met: the builder was tested by rendering SQL to a string, the driver by
hand-written SQL, and nothing proved the generated SQL was *executable*.

```swift
let db = try connection.executor(MariaDB.self)
let u = Users()

let rows = try await db.select(u.id, u.name)
    .from(u)
    .where(u.score > 100)
    .fetch(on: db)                      // [(Int64, String)]
```

## The design

`SQLExecutor` lives in `SwizzleCore` and is deliberately narrow — the builder
produces text plus an ordered binding list, and that is all an executor needs.
A driver conforms without knowing anything about the builder; the builder gains
database access without depending on any driver.

```swift
public protocol SQLExecutor: Sendable {
    associatedtype Dialect: SQLDialect
    func execute(sql: String, bindings: [SQLValue]) async throws -> [SQLRow]
    func executeUpdate(sql: String, bindings: [SQLValue]) async throws -> Int
}
```

### Why `Dialect` is an associated type

Every execution entry point is constrained `where Executor.Dialect == D`, so
running a query on the wrong database is a **compile** error. A
`SelectQuery<Postgres, …>` renders `$1` placeholders and `"quoted"` identifiers;
handing it to a MySQL connection would otherwise produce a server-side syntax
error hundreds of milliseconds later, with nothing pointing at the dialect.

This extends the bet the capability protocols already make — `.returning()` on
MySQL fails to compile — to the execution boundary.

### The runtime half of that bet

`MySQL` and `MariaDB` are different dialects but the same wire protocol and the
same connection type: the dialect is chosen at compile time, the actual server
flavour is only known at runtime. `MySQLConnection.executor(_:)` checks they
agree and throws otherwise.

Without that check the type-level design would be a fiction — a `MariaDB`-typed
query using `RETURNING` would compile happily and fail on a MySQL server, which
is precisely what the capability protocols exist to prevent.

## Surfaces

| | |
|---|---|
| `fetch(on:)` | all rows, decoded into the projection's tuple |
| `fetchFirst(on:)` | first row or `nil`; does **not** add `LIMIT 1` |
| `forEach(on:)` | streams, decoded, one row at a time |
| `streamRows(on:)` | streams raw `SQLRow`s as an `AsyncSequence` |
| `InsertQuery.execute(on:)` | rows affected |
| `ReturningInsert.execute(on:)` | decoded `RETURNING` rows (MariaDB, not MySQL) |
| `MySQLClient.withExecutor(_:_:)` | borrow from the pool |
| `MySQLClient.withTransaction(_:options:_:)` | borrow and open a transaction |
| `MySQLExecutor.withTransaction(_:_:)` | transaction on an existing connection |

A single-column projection decodes to the **bare value**, not a one-element
tuple — `select(u.name).fetch(...)` gives `[String]` — because a one-element
parameter pack collapses.

## Why typed streaming is a callback

`forEach(on:)` takes a closure rather than returning an `AsyncSequence` of
tuples. That is not a style choice: an `AsyncSequence` whose `Element` is a pack
expansion (`(repeat each V)`) compiles on Swift 6.3 but **cannot be iterated on
Swift 6.1**, the current Linux toolchain — every `for try await` over it fails
with *"value pack expansion can only appear inside a function argument list"*.
Binding the tuple whole instead of destructuring does not help; the restriction
is on iterating at all.

A closure parameter *is* a function argument list, so the callback form works on
both. Backpressure is unaffected — the body runs per row as it arrives — and
`streamRows(on:)` returns an ordinary `AsyncSequence` for callers who prefer to
decode themselves.

This compiled and passed the full suite on macOS; only running on Linux caught
it.

## Value bridging uses column metadata, not guesswork

`MySQLValue.sqlValue` has to guess `.text` vs `.blob` from whether the bytes
happen to be valid UTF-8 — and that guess is wrong for real binary data:
`[0x01, 0x02, 0x03]` is perfectly good UTF-8, so a BLOB came back as `.text`.

The row-level bridge uses the server's own answer instead: character set 63 is
`binary`. It falls back to guessing only when a column definition is missing.

Two asymmetries worth knowing:

- **`.bool` binds as an integer.** MySQL has no boolean type — `BOOL` is an
  alias for `TINYINT(1)` — so `0`/`1` is what the server stores and returns.
- **`SELECT ?` cannot distinguish blob from text**, whatever the client does:
  for a bare parameter the *server* decides the result column's type, and it
  types a bound byte string as a string. A declared `BLOB` column round-trips
  correctly.

## Not done here

`stream` with bindings is refused rather than silently downgraded — the driver's
`stream(_:)` takes no parameters, so a parameterised query would need a prepared
statement and cursor fetch. Interpolating the bindings instead would be an
injection hole, so it throws instead.

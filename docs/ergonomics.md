# Ergonomics, measured against the reference clients

The brief was to take the best of `mysql_async`, go-sql-driver, node-mysql2 and
PyMySQL, express it in Swift, and keep ours where ours is already better. This
records what was taken, what was left, and why.

## The scoreboard

| | mysql_async | go-sql-driver | node-mysql2 | PyMySQL | Swizzle |
|---|---|---|---|---|---|
| binding | `?` + `:named` via `params!` | `?` positional | `?`, `:named` opt-in | `%s`, `%(name)s` | **interpolation** |
| `IN (…)` list | by hand | by hand | by hand | by hand | **`\(list:)`** |
| typed rows | `FromRow` derive | `Scan(&a, &b)` | untyped objects | untyped tuples | **pack tuples** |
| nullability | `Option<T>` | `sql.NullString` | `null` | `None` | **`String?`** |
| first row | `query_first` | `QueryRow` | `rows[0]` | `fetchone()` | `executeFirst` |
| ignore result | `query_drop` | `Exec` | — | — | `@discardableResult` |
| batch | `exec_batch` | — | — | `executemany` | `executeBatch` |
| streaming | `query_stream` | `rows.Next()` | `.stream()` | `SSCursor` | **backpressured** |
| column by name | — | — | objects | `DictCursor` | `row["name"]` |
| connection URL | ✅ | ✅ DSN | ✅ | ✅ | ✅ *(added)* |

## Taken from them

**`query` vs `execute`.** node-mysql2 and `mysql_async` both split the text
protocol from the prepared one by name (`query`/`execute`, `query`/`exec`). We
now do the same: `query(_ sql: String)` is unchanged and goes out as text;
`execute(_ query: MySQLQuery)` binds and prepares. Keeping the parameter types
distinct is what stops a string literal silently picking the wrong one.

**The `Queryable` suffix matrix.** `mysql_async`'s `_first`, `_batch` and
friends exist because those are the shapes people actually need.
`executeFirst`, `executeUpdate`, `executeInsert` and `executeBatch` are the same
idea; `query_drop` needs no equivalent because `@discardableResult` already
covers it.

**Connection URLs.** All four accept one, because `DATABASE_URL` is how a
deployed service is configured. `MySQLConnectionConfiguration(url:)` parses
`mysql://` and `mariadb://`, percent-decodes credentials, and takes the tuning
parameters as query items.

One deliberate difference: an **unknown parameter is an error**, where the
others ignore what they don't recognise. A dropped `tls=require` is a security
failure that looks exactly like success, and `?tsl=require` should not connect
in plaintext.

## Where Swift beats all four

**Interpolation is the binding.**

```swift
let rows = try await connection.execute(
    "SELECT name FROM users WHERE id = \(id) AND active = \(true)"
)
```

`\(id)` appends `?` to the SQL and the value to a separate bind list. What
reaches the server is `... WHERE id = ? AND active = ?`. There is no code path
from an interpolated value into the SQL text, so injection is not discouraged —
it is unrepresentable.

Every reference client wants this and no other language lets them have it.
`mysql_async` needs a `params!` macro plus `:named` markers; go and PyMySQL make
you keep a positional argument list in sync with the `?`/`%s` markers by hand;
node-mysql2 offers named placeholders behind a config flag. All four separate
the query from its values, which is exactly where mistakes live.

Three things can't be parameters, and each has an escape hatch that is visible
at the call site: `\(identifier:)` quotes a table or column name (doubling any
backtick, so a name cannot terminate its own quoting), `\(unescaped:)` splices
raw SQL, and `MySQLQuery(unsafeSQL:binds:)` takes a statement you built.

**`IN` lists.** The single most common place hand-written binding goes wrong,
and none of the four has an answer — you build the `?, ?, ?` run yourself and
hope it matches the array:

```swift
"SELECT * FROM users WHERE id IN (\(list: ids))"
```

An empty list renders `NULL`, because `IN ()` is a *syntax error* in MySQL while
`IN (NULL)` is valid and matches nothing — which is what an empty candidate set
means.

**Typed rows without pointers or macros.**

```swift
let (id, name, email) = try row.decode(Int.self, String.self, String?.self)
```

Go makes you pre-declare every variable and pass pointers, plus `sql.NullString`
wherever a column is nullable. `mysql_async` gets there with a `FromRow` derive
macro. PyMySQL hands back an untyped tuple. Here the types *are* the argument
list, and a nullable column is just `String?` — Swift's optionals do for free
what `sql.NullString` exists to work around.

Integer decoding deliberately accepts any integral representation, because the
same column arrives as `.int` over the binary protocol and as digits over
`COM_QUERY`, and a `COUNT(*)` is `.uint` on one server and `.int` on another.
Insisting on one would make the protocol a caller's problem. It will not lose
information, though: a value outside the target's range throws rather than
wrapping.

**Streaming.** Ours is the only one with real backpressure — 400,000 rows at
+0.9 MB peak. `forEach(_:as:_:)` decodes per row as it arrives, so the typed
form keeps the bounded-memory guarantee.

It is a callback rather than an `AsyncSequence` for a concrete reason: an
`AsyncSequence` whose `Element` is a pack expansion cannot be iterated by Swift
6.1, which is the current Linux toolchain — it compiles and then fails at every
use site. `SelectQuery.forEach(on:)` had already hit this; the same shape works
on both.

## Left alone

- **`query_fold`** — Swift has `reduce` on the returned array, and `forEach`
  covers the streaming case.
- **`fetchmany(size:)`** — streaming with backpressure is a better answer than
  pulling fixed-size batches.
- **`rowsAsArray`** — rows already carry a plain `values` array; nothing to
  toggle.
- **`Date` binding.** Deliberately absent, and the one place I would rather ask
  than guess. MySQL `DATETIME` is a wall clock with no zone; `TIMESTAMP` is an
  instant. Mapping Swift's `Date` onto either requires choosing a timezone, and
  choosing wrong corrupts data silently. `mysql_async` gates this behind
  optional `chrono`/`time` features for the same reason. `MySQLDateTime` and
  `MySQLTime` are the honest representations; a `Date` bridge should be an
  explicit decision about which zone it means.

## What did not change

`query(_:)`, `stream(_:)`, `prepare`/`execute`, the pool, and the binlog API are
untouched. Everything above is additive — a caller holding SQL it has already
assembled keeps working exactly as before.

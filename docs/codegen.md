# Code generation

Pillar 3. Typed Swift functions from `.sql` query files, in the sqlc lineage —
with one deliberate divergence that changes almost everything downstream.

`examples/codegen` is the whole thing in files you can open: a schema, a query
file, the generated Swift, and the lockfile.

## The divergence: ask the database

sqlc never connects to anything. You give it `engine:`, your schema SQL and your
query SQL, and it *parses* both — building a catalog from the DDL and resolving
types over a query AST. The cost is a real SQL parser per engine:
[`libpg_query`](https://github.com/pganalyze/libpg_query) (the actual PostgreSQL
parser, vendored) for Postgres, Vitess's `sqlparser` for MySQL, and a
hand-written ANTLR grammar for SQLite. That asymmetry is why sqlc's Postgres
support is markedly better than its MySQL and SQLite support: the three back ends
are three different amounts of parser.

Swizzle asks the database. Every engine can describe a statement at prepare time
without running it:

| engine | how |
|---|---|
| MySQL | `COM_STMT_PREPARE`, which returns column and parameter definitions |
| SQLite | `sqlite3_prepare_v2` plus the column-metadata calls |
| Postgres | `Parse` / `Describe` / `Sync`, which returns `ParameterDescription` and `RowDescription` |

What that buys:

- **No parser to write or maintain.** Three engines, zero grammars.
- **Correctness by construction.** The answer is whatever the engine says, so
  there is no class of "the parser disagrees with the server" bug.
- **Every type the drivers already know.** Postgres ranges, multiranges, arrays,
  `int2vector` — all of it arrives through the same decoders the driver uses at
  runtime, because it *is* the same code.

What it costs: **a live database at generation time.** That is paid on a
developer's machine, and the lockfile means CI never needs one.

## What each engine can actually tell us

This table is the whole design constraint.

| | parameter count | parameter types | column names | column types | column **nullability** |
|---|---|---|---|---|---|
| **MySQL** | yes | placeholders only — useless | yes | yes | **yes, genuinely** |
| **SQLite** | yes | none — dynamically typed | yes | base columns only | base columns only |
| **Postgres** | yes | yes (OIDs) | yes | yes | **not on the wire at all** |

Three consequences worth stating plainly, because each shaped the format:

**Parameters are the weak half everywhere.** MySQL reports every placeholder as
`VAR_STRING` regardless of use; SQLite has no concept of a parameter type. Only
Postgres genuinely infers them. So parameters are **declared by the author** in
the query file and *verified* against the engine where the engine can verify
them. Deriving what the databases know well and declaring what they do not is
more honest than pretending all three are equal.

**MySQL is the one that gets nullability right,** and it is not close. It
computes `NOT_NULL` for the *projected expression*, so it stays correct through a
`LEFT JOIN`. SQLite and Postgres can only answer for columns traceable to a base
table, so for those two a statement containing an outer join widens everything
that would otherwise be non-optional — knowing which *side* a column sits on
needs a parser, and pessimism on a few columns is the cheaper failure. That
widening is deliberately **not** applied to MySQL: doing so would make the one
engine that gets this right the worst of the three.

**Postgres has no nullability on the wire.** `RowDescription` carries no null
flag — not for us, not for `libpq`, not for anyone. It comes from a
`pg_attribute` lookup instead.

## The query file

Directives follow the migration convention exactly — `-- +swizzle <Keyword>` —
including its stated principle that the file **stays runnable by hand**. So
placeholders are the engine's native form (`?` on MySQL and SQLite, `$1` on
Postgres) rather than a portable invention. A query file is written against one
database, exactly as a migration is.

```sql
-- +swizzle Query GetUser(id: Int64) :one
SELECT id, email, name FROM users WHERE id = ?;

-- +swizzle Query StreamAll :stream
SELECT id, email FROM users;

-- +swizzle NotNull total
-- +swizzle Query OrderTotals(userID: Int64) :many
SELECT u.id, o.total FROM users u LEFT JOIN orders o ON o.user_id = u.id
WHERE u.id = ?;

-- +swizzle Type n Int64
-- +swizzle Query CountUsers :one
SELECT COUNT(*) AS n FROM users;
```

| cardinality | returns |
|---|---|
| `:one` | `T?` — or the bare scalar when the projection is a single non-optional column |
| `:many` | `[T]` |
| `:stream` | an `AsyncSequence` of `T` — **no sqlc equivalent** |
| `:exec` | `Int`, rows affected |

| directive | effect |
|---|---|
| `-- +swizzle NotNull <column>` | the column cannot be null, whatever the engine widened it to |
| `-- +swizzle Nullable <column>` | the column can be null |
| `-- +swizzle Type <column> <T>` | the column's Swift type, optionality included: `Int64`, or `String?` |

`NotNull` / `Nullable` correct optionality the engine reported pessimistically.
`Type` supplies a type the engine could not report **at all** — and on SQLite
that is not an edge case: `decltype` is null for every expression, aggregate and
literal, so `SELECT COUNT(*)` is genuinely unknowable and generates as `SQLValue`
without one. MySQL and Postgres type the same query themselves.

The `Type` spelling carries the optionality because the author is naming a
*Swift* type, and in Swift `Int64` and `Int64?` are different types. `NotNull` /
`Nullable` still apply afterwards and still win.

A directive that names no column in the result set is an **error**, not a no-op.
A typo in an override is otherwise silent: the column keeps whatever the engine
said and the author believes they fixed it.

## Generated output

```swift
public struct Queries<Executor: SQLExecutor>: Sendable
where Executor.Dialect == SQLite { … }

extension Queries {
    public func getUser(id: Int64) async throws -> GetUserRow?
    public func countUsers() async throws -> Int64?
    public func deactivate(id: Int64) async throws -> Int
}

// Streaming needs more of an executor than running does.
extension Queries where Executor: SQLStreamingExecutor {
    public func streamAll() async throws
        -> AsyncThrowingMapSequence<Executor.RowSequence, StreamAllRow>
}
```

Two things there are load-bearing.

`Queries` is **pinned to the dialect it was generated against**, so running
generated Postgres queries on a MySQL connection is a compile error rather than a
syntax error from a server — the same bet the query builder makes.

`:stream` queries land in a **separate extension** constrained to
`SQLStreamingExecutor`, so a `:stream` query simply does not exist as a method on
a backend that cannot stream, rather than failing when it is called. That is how
every other capability in this library is gated.

Emission is plain string building, following the `swizzle migrate embed`
precedent. swift-syntax is not a dependency and should not become one: it is a
large build-time cost for a package already sensitive to compile time, and the
shape of generated code is fixed.

## Shadow databases

By default the migrations are run into a throwaway database and the queries
described *there*, so generated code follows the migrations rather than whatever
state a server happens to be in. `--no-shadow` describes against the URL
directly.

SQLite in memory is a free shadow, which is why the generator was built there
first and why the whole pipeline is unit-testable on any machine with no server.
MySQL and Postgres create and drop a real database; `destroy()` refuses to drop
anything not matching `^swizzle_shadow_`. MySQL must **reconnect** with the
database in the URL rather than issuing `USE`, because the statement cache is per
session and would otherwise resolve against the wrong schema.

## The lockfile and `--verify`

```
swizzle generate queries --verify
```

Needs **no database at all**. It recomputes each query's key from the files on
disk and compares against `swizzle.lock.json`, then re-emits Swift from the
stored signatures and diffs that against the committed output. That catches the
three ways a tree goes stale: a query edited without regenerating, a migration
added without regenerating, and generated code edited by hand.

The key covers the query text, its cardinality, its parameter declarations, every
`NotNull` / `Nullable` / `Type` directive, the engine, the generator version, and
a **schema fingerprint**.

The fingerprint is what makes the no-database claim work: it hashes the ordered
`(identifier, checksum)` pairs of the *migration files*, not an introspected
schema. Fingerprinting the introspected schema would need a connection, and would
churn with server version. Postgres OIDs are never stored — they are
per-database, and the shadow is recreated on every run.

## Where the drift used to be

The query builder documents a gap it could not close on its own: in a
hand-written `SQLTable`, the SQL type in `varchar("email", 255)` is a comment
nothing verifies, and it drifts from the migration that created the column.

`swizzle generate schema` closes it. Table declarations come from what the server
reports, so the type is a fact rather than an assertion.

## What is deliberately not here

- **A build-tool plugin.** A SwiftPM plugin runs in a sandbox with no network, so
  a macro or plugin cannot describe a statement against a live database. The
  generator is a CLI you run and whose output you commit — which is also what
  makes the output reviewable in a diff.
- **A portable placeholder syntax.** See above: the file stays runnable by hand.
- **Query rewriting.** Swizzle does not modify your SQL. It reads it, asks the
  database about it, and emits a function that sends exactly what you wrote.

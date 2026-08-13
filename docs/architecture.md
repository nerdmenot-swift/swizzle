# Structure — how a new database gets added

Written after being asked whether Swizzle is built for pluggable engines. The
honest answer is *partly*: the seams are in the right places, the wiring on top
of them is not, and pillar 3 has no design yet. This records what is actually
true today and what has to change.

## What is genuinely pluggable

These are protocol seams a new database conforms to, with no edits to shared
code:

| seam | members | what it buys |
|---|---|---|
| `SQLDialect` | 3 | identifier quoting, placeholder style |
| capability protocols | 8 marker protocols | `.returning()` on MySQL is a **compile** error |
| `SQLExecutor` / `SQLStreamingExecutor` | 3 | the builder runs on any driver |
| `MigrationDialect` | 6 | the whole migrator works |
| `SchemaIntrospector` | 1 | linting and drift |
| `MigrationSource` | 1 | directory, in-memory, generated |
| `OnlineDDLRunner` | 1 | engine-specific, optional |
| `SQLStatementSplitter.Syntax` | value type | new presets are *data*, not code |

The capability protocols are the strongest idea in the codebase and the reason
Drizzle ships three near-duplicate packages where we ship one builder. That part
of the bet is paying off.

## The structural work — done

All three steps are in. Measured rather than asserted:

| | before | after |
|---|---|---|
| concrete dialect references outside the MySQL modules | 20 | **0** |
| non-comment `MySQL` references inside `SwizzleMigrate` | many | **0** |
| places to edit to add an engine | 8+ across CLI and migrator | **1 line in the registry** |

### `AnySQLExecutor` and `AnyMigrationDialect`

`Migrator` is no longer generic. It holds an erased executor and a dialect
*value*, because migrations are raw SQL: the dialect has to be **known**, not
**typed**. The generic `SQLExecutor` is untouched — the query builder's whole
value is that a `SelectQuery<Postgres, …>` cannot reach a MySQL connection, and
erasing that would throw away the best idea in the library.

Generic for the builder, erased for the runtime path. `AnyMigrator` — the
two-case enum with six methods switching over it — is deleted.

### `DatabaseEngine` and the registry

An engine supplies a connection, and the connection supplies everything else:
executor, dialect, introspector, and optionally an online runner. The CLI names
no database at all; the URL scheme picks the engine.

```
Error: cannot connect: no registered engine handles that scheme
       — known: mariadb, mysql
```

Adding Postgres is now: a module, and one line in the registry.

### Where things live

```
SwizzleCore ────────── protocols, dialects, values, schema types, AnySQLExecutor
├── SwizzleQuery ───── builder (generic — compile-time dialect safety)
├── SwizzleMigrate ─── migrator, linter, DatabaseEngine (knows no database)
├── SwizzleMySQL ───── driver + introspector (standalone; no migrator dependency)
├── SwizzleOnlineDDL ─ binlog-driven ALTER
└── SwizzleMySQLEngine ─ the only place the two are joined
SwizzleCLI ─────────── SwizzleMigrate + whichever engines it ships
```

The engine module exists so the driver stays usable on its own: a service that
just runs queries should not link the migrator, and the migrator should not know
MySQL exists.

## Pillar 3 — the sqlc-style codegen, which does not exist yet

Zero lines today, and it is the pillar with the **most** engine-specific surface,
so its shape should be decided before it is built rather than after.

sqlc works by parsing SQL — it embeds a Postgres parser, and its MySQL support is
weaker precisely because that means a second parser. Copying that would mean
writing and maintaining a SQL parser per dialect, permanently incomplete, which
is the same trap the migration linter deliberately avoided.

**We have a shortcut nobody else does: ask the database.**

Both protocols already answer the question at prepare time:

- MySQL's `COM_STMT_PREPARE` returns the **parameter count** and the full
  **column definitions** — name, type, nullability, charset — before a single row
  is fetched. We decode all of that today.
- Postgres's `Parse`/`Describe` returns parameter type OIDs and row description.
- SQLite has `sqlite3_column_decltype` and `sqlite3_bind_parameter_count`.

So the analyser can be *the driver we already wrote*: prepare the query against a
real database (or a schema built by running the migrations into a scratch one),
read back the metadata, and emit Swift types. No parser, correct by construction,
and it inherits every type the driver already understands.

That suggests:

```swift
public protocol QueryAnalyzer: Sendable {
    /// Prepare-and-describe, without executing.
    func analyze(_ sql: String) async throws -> QuerySignature
}

public struct QuerySignature: Sendable {
    public var parameters: [ParameterInfo]   // position, inferred type
    public var columns: [ColumnInfo]         // name, type, nullability
}
```

with one shared emitter turning a `QuerySignature` into Swift. The engine-specific
part is `analyze`; everything downstream is common.

Open questions worth settling before building it:

- **Where does the schema come from?** Running the migrations into a scratch
  database is the honest answer and matches Prisma's shadow database. It also
  means codegen validates the migrations for free.
- **Nullability.** MySQL's column flags report it for base-table columns but not
  reliably through joins and expressions; sqlc has annotations for this. We may
  need the same escape hatch.
- **Is a build plugin viable?** It would need a database at build time, which is
  hostile in CI. More likely a `swizzle generate` command committing generated
  code, which is what sqlc does.

## What I would do, in order

1. **Move `MySQLIntrospector` out of `SwizzleMigrate`.** Small, obvious, no
   design needed.
2. **Add `AnySQLExecutor` and delete `AnyMigrator`.** Unblocks everything else
   and removes the twenty concrete references.
3. **Introduce `DatabaseEngine` + registry**, move the dialect conformances to
   the engine side.
4. **Then add Postgres**, as the first real test of whether the seams hold —
   adding an engine should touch no shared code. If it does, the abstraction is
   wrong and better to learn it at engine two than engine three.
5. **Design pillar 3 around prepare-and-describe**, not a SQL parser.

Doing 1–3 before Postgres rather than after is the whole point: the abstraction
is only proven by the second implementation, and it is much cheaper to shape it
now than to unpick two engines' worth of assumptions later.

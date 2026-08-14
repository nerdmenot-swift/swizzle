# Adding a database

Written by auditing what the existing three actually do, not by describing an
intention. Every protocol named here has three conformances already.

## The shape

Two targets per database, and the split is load-bearing:

```
Sources/SwizzleFoo/          the driver — wire protocol or C binding
Sources/SwizzleFooEngine/    the seam — migrations, codegen, shadow databases
```

The **driver** may import `SwizzleCore` and nothing else from this package. That
is checked rather than hoped for:

| target | imports from this package |
|---|---|
| `SwizzleMySQL` | `SwizzleCore`, `SwizzleConnectionPool` |
| `SwizzlePostgresDriver` | `SwizzleCore`, `SwizzleConnectionPool` |
| `SwizzleSQLite` | `SwizzleCore` |

`SwizzleConnectionPool` is vendored from postgres-nio and has no Swizzle
dependencies of its own. So any driver can be lifted into its own package by
taking `SwizzleCore` with it — that is the whole reason the rule exists.

The **engine** target is where `SwizzleMigrate` may be imported. Nothing in
`SwizzleCore`, `SwizzleQuery`, `SwizzleMigrate` or `SwizzleGenerate` imports a
driver, so the shared layers never learn a database exists.

## What to implement

### 1. A dialect — `SQLCore.SQLDialect`

Ten lines: a name, an identifier quote, and how to write a placeholder.
Capabilities are opt-in protocols rather than booleans, so the builder refuses
unsupported syntax **at compile time**:

```swift
public enum Foo: SQLDialect, SupportsReturning, SupportsOnConflict {
    public static let dialectName = "foo"
    public static let identifierQuote: Character = "\""
    @inlinable
    public static func writePlaceholder(index: Int, into sql: inout String) {
        sql.append("?")
    }
}
```

The existing three live in `SwizzleCore/Dialect.swift` for convenience, but
nothing requires that — `SQLDialect` is public, so a dialect declared in your own
module works identically. Shared code never switches on a concrete dialect.

### 2. An executor — `SQLCore.SQLExecutor`

Runs a rendered statement. Add `SQLStreamingExecutor` if the database can stream
rows; a `:stream` generated query simply does not exist as a method on an
executor that cannot, rather than failing at run time.

### 3. `SwizzleMigrate.MigrationDialect`

Lock table, journal table, and the statement-splitter syntax (quoting rules,
whether `BEGIN … END` bodies nest).

### 4. `SwizzleCore.SchemaIntrospector`

Reads the live schema into `DatabaseSchema`. Feeds `swizzle generate schema` and
the drift check.

### 5. `SwizzleCore.QueryAnalyzer` — optional

Prepare-and-describe: parameter and column shapes without executing. Absent it,
the code generator skips this engine rather than guessing. This is the interesting
one, and the three differ sharply in what the database can tell you — see
`docs/architecture.md`.

### 6. `SwizzleMigrate.DatabaseEngine`

The registration point: name, URL schemes, lint rules, `connect(url:)`, and
optionally `makeShadow`. One line in `Sources/SwizzleCLI/Support.swift` adds it to
the registry:

```swift
let engines = EngineRegistry([MySQLEngine.self, PostgresEngine.self, SQLiteEngine.self])
```

That line is the only place in shared code that names the engines, and the CLI
picks between them by URL scheme.

## What this audit changed

Three defects, all of the same kind — declared coupling that was not real:

- **`SwizzlePostgresDriver` depended on `SwizzleQuery`** and referenced it
  nowhere. A driver that pulled in the query builder to compile.
- **`SwizzleMySQL` and `SwizzleSQLite` each had one `import SwizzleQuery`** that
  the compiler did not need — verified by deleting it and rebuilding.
- **SQLite had no driver/engine split.** One target held the connection, the
  migration dialect, the analyzer and the `DatabaseEngine` conformance, so it
  depended on `SwizzleMigrate` and could not be extracted without dragging the
  migrator along. Now `SwizzleSQLite` (driver) and `SwizzleSQLiteEngine` (seam),
  matching MySQL and Postgres.

## Still inconsistent, deliberately not changed

Where the executor and introspector live differs by engine: MySQL keeps both in
the driver, Postgres puts both in the engine, SQLite now keeps the executor and
introspector in the driver. All three compile and all three respect the import
rule above — `SQLExecutor` and `SchemaIntrospector` are `SwizzleCore` protocols,
so either side is legitimate.

Unifying it would be churn for symmetry rather than for a property anybody can
observe. Recorded here so the next person knows it is a shrug and not an
oversight.

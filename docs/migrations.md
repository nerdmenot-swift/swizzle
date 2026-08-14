# Migrations

Pillar 1. SQL-first, in the goose lineage rather than Drizzle's: the `.sql` file
*is* the source of truth, and nothing generates or regenerates it. That is why
hand-editing a migration is normal here — see `drizzle-study.md` §3 for why the
schema-diff direction makes it awkward.

## The format

```sql
-- +swizzle Up
CREATE TABLE users (id INT PRIMARY KEY, email VARCHAR(255) NOT NULL);
CREATE UNIQUE INDEX users_email ON users (email);

-- +swizzle Down
DROP TABLE users;
```

Files are named `<version>_<name>.sql`. The version is any positive integer, so
both conventions work without the library caring: `001_init.sql` counts up and
`20240615120000_init.sql` is a timestamp. Prefer timestamps on a team — two
branches both adding `004_` collide, whereas two timestamps merely interleave.

| directive | effect |
|---|---|
| `-- +swizzle Up` | begins the apply section |
| `-- +swizzle Down` | begins the revert section |
| `-- +swizzle StatementBegin` / `StatementEnd` | the enclosed text is **one** statement (rarely needed — see below) |
| `-- +swizzle NoTransaction` | do not wrap this migration in a transaction |

## Two kinds of migration

`<version>_<name>.sql` is **versioned**: applied once, in order.

`R__<name>.sql` is **repeatable**: re-applied whenever its content changes,
after every versioned migration, in name order. Flyway's spelling, kept because
it is the one people recognise.

Repeatable migrations are for objects that are *replaced* rather than altered —
views, stored procedures, functions, triggers, grants. Without them, changing a
view means writing a new migration containing the whole `CREATE OR REPLACE`,
every time, forever, so the current definition is smeared across a dozen files
and no single file shows what it is now. Here it lives in one file that reads
like source code and the checksum decides when to re-run it.

They have no `Down` — reverting one means changing the file back — and `down`
skips them. Running last is load-bearing: a view almost always depends on tables
a versioned migration just created.

A changed repeatable migration reports as `changed`, not `MODIFIED`. Editing one
is how you work; editing an applied *versioned* migration is a problem.

The directive syntax is goose's on purpose: a file with comment directives stays
runnable by `mysql` or `psql` directly, which matters when a migration goes wrong
at 3am and someone has to apply half of it by hand.

A migration with no `Down` is legal and simply not reversible. Dropping a column
cannot be undone once the data is gone, and a fake `Down` that pretends
otherwise is worse than admitting it — `down()` refuses rather than silently
skipping.

## Splitting is a lexer, not a `split(on: ";")`

`SQLStatementSplitter` tracks what it is inside and only treats `;` as a boundary
at the top level. This is not fussiness: every one of these appears in real
migrations, and the failure mode is that *half* a statement runs — which on MySQL
cannot be rolled back.

Handled: string literals with `''` doubling, MySQL backslash escapes, quoted and
backticked identifiers, `--`/`#`/`/* */` comments, and Postgres dollar quoting
including tags (`$fn$ … $fn$`), which is how every function body is written.

The rules are per-dialect rather than a permissive superset, because permissive
is not safe. Postgres treats a backslash in an ordinary literal as a literal
backslash, so consuming `\'` as an escape there runs past the true end of the
string and swallows the rest of the file. `SplitterTests` asserts the two
dialects split the same text at *different* places.

Compound bodies are **detected**, so a trigger or stored procedure needs no
directive:

```sql
-- +swizzle Up
CREATE TRIGGER posts_touch BEFORE UPDATE ON posts FOR EACH ROW
BEGIN
    IF NEW.status <> OLD.status THEN
        SET NEW.updated_at = NOW();
    END IF;
END;
```

That is one statement, not four. Flyway detects these; goose requires a
directive, and following goose here was the wrong call — forgetting it silently
cut a body into fragments, which is the exact corruption the splitter exists to
prevent.

The detection is a depth counter, not a flag, and four things stop it being
naive:

| | |
|---|---|
| `BEGIN;` outside a routine | a **transaction** — counting it would swallow the file |
| `END IF`, `END WHILE`, `END LOOP`, `END CASE`, `END REPEAT` | contain `END`, close nothing |
| `DROP TRIGGER` | only a *definition* has a body |
| `CREATE TRIGGER … FOR EACH ROW SET NEW.a = 1;` | no block at all — that `;` really is the end |

`BEGIN NOT ATOMIC` — MariaDB's anonymous block — is recognised too, because that
token pair is unambiguous.

**Where detection stops.** A routine body need not be a block: any single
compound statement is legal, so `CREATE PROCEDURE p() IF … THEN …; END IF;`
splits wrongly. That is what `StatementBegin`/`StatementEnd` is still for.

It is not fixed by counting `IF`/`CASE` as openers, because `IF(a, b, c)` is a
function and `CASE … END` an expression — a false positive there would swallow
migrations that work today, which is a worse failure than needing a directive in
a rare case. `DetectionLimitsTests` records exactly where the line falls, so the
escape hatch is a documented boundary rather than a mystery.

## The two things Drizzle lacks

**A lock.** `up()` and `down()` hold an advisory lock for their whole run
(`GET_LOCK` on MySQL). Without one, two pods rolling out together both read an
empty journal and both apply migration 1; the second fails on "table already
exists", mid-deploy. `MigrationTests` runs two migrators concurrently and asserts
one applies everything and the other applies nothing.

**Real down migrations.** `down(count:)` and `down(to:)` revert newest-first and
remove the journal rows. Drizzle's runtime migrator has no notion of reverting at
all.

## Checksums

Every migration's source text is hashed and the hash recorded. On later runs a
changed file is *detected*: `status()` reports `.modified` and `up()` refuses.

Editing an applied migration is a real and common mistake — fixing a typo in a
migration that shipped last week leaves every existing database on the old
version of it and every new database on the new one, with nothing in the schema
to say so. goose does not check this at all; Drizzle hashes files only to decide
what to run. `verifyChecksums: false` overrides it when the edit was deliberate.

## Ordering

`requireOrdered` (default on) refuses to apply a migration numbered below one
already applied. The case it catches is a branch merge: two developers write 5
and 6, 6 lands and deploys, then 5 merges. Applying 5 now runs it against a
schema it was never written for.

## MySQL cannot roll back DDL, and the migrator says so

The most consequential difference between the three databases, and the reason a
migrator cannot promise atomicity everywhere.

Postgres and SQLite roll DDL back. **MySQL and MariaDB commit implicitly before
and after every DDL statement** — `BEGIN; ALTER TABLE …; ROLLBACK;` leaves the
ALTER applied. MySQL 8.0 made some individual data-dictionary changes atomic, but
a multi-statement migration still cannot be rolled back as a unit.

So `MigrationDialect.hasTransactionalDDL` is false for MySQL and MariaDB, and the
migrator **does not wrap** their migrations. Wrapping them would produce a
migrator that reports an atomicity it does not have, which is what turns a failed
migration into a silently half-migrated database. Instead a failure names the
statement and states plainly what happened:

```
migration 3_add_indexes failed at statement 2: CREATE INDEX …
  Earlier statements in this migration were already committed and CANNOT be
  rolled back — this database has DDL outside a transaction. Fix the schema by
  hand, or write a migration that repairs it.
```

The failed migration is *not* recorded, so it is retried on the next run — which
is why a migration that may partially fail should be written to be re-runnable
(`CREATE TABLE IF NOT EXISTS`, `DROP INDEX IF EXISTS`).

On a dialect with transactional DDL the same failure says the opposite: *"The
migration was rolled back; the database is unchanged."*

## Swift migrations

For a data transformation needing logic SQL does not have — re-encrypting a
column, backfilling a computed value, reshaping JSON by application rules.

```swift
struct BackfillSlugs: SwiftMigration {
    static let version: Int64 = 20_240_615_120_000
    static let name = "backfill_slugs"

    func up(_ db: some MigrationContext) async throws {
        try await db.batches(over: "posts", selecting: "id, title") { rows in
            for row in rows { /* … */ }
        }
    }
}

let source = CombinedMigrations([
    MigrationDirectory(path: "migrations", syntax: .mysql),
    SwiftMigrations([BackfillSlugs()]),
])
```

**Read this before reaching for one.** The reason people usually want a code
migration is a backfill, and a large backfill inside a migration is an
anti-pattern regardless of language: it holds the deploy open, cannot be
throttled against replica lag, times out, and cannot be resumed. The right shape
is a separate idempotent, resumable job, with a migration doing only the schema
change that enables it. If you are moving a few million rows, write the job.

They share the **version space**, journal, lock and `status` with SQL
migrations, so ordering is one mechanism rather than two — a Swift migration at
2 and a SQL one at 3 run in that order, and claiming a version another migration
already has is an error rather than something resolved by load order.

Everything else about them is worse, knowingly:

- **Not readable by `mysql`.** A SQL migration can be opened and applied by hand
  during an incident. This cannot, and `--dry-run` can only name it.
- **Not meaningfully checksummed.** The checksum covers the declared version and
  name, not the compiled body — editing an applied Swift migration is
  undetectable, exactly what checksums catch for SQL.
- **A failure is opaque.** No statement index, no way to know how far it got.
  The error says so instead of implying the precision the SQL path has.
- **Schema changes belong in SQL** — advice, not a rule. Blocking DDL here was
  considered and rejected: the check would be keyword matching, so it would be
  wrong at the edges, and it would break legitimate uses like a temp table during
  a transformation or an index dropped and recreated around a bulk update. goose
  and Alembic do not restrict their code migrations either. The property you give
  up by writing schema here is the readable, reviewable, hand-appliable one.

Irreversible by default — `down` refuses, matching a SQL migration with no
`Down`. Conform to `ReversibleSwiftMigration` to declare a real revert. A
separate protocol rather than a flag, because a defaulted `down` makes "did you
write one?" unanswerable, and silently doing nothing would be the worst of the
three outcomes.

`batches(over:)` walks a table by **keyset** — `WHERE key > ? ORDER BY key LIMIT
n` — not by offset, because offset makes the database walk and discard every
skipped row, so the last batch of a ten-million-row table costs ten million rows
of work. Keyset stays flat and does not lose or repeat rows when the table is
written to mid-walk.

## Linting

Atlas's best idea, and separable from being declarative — the checks work on
migration files.

```
swizzle migrate validate    parses and lints, no database needed (CI)
swizzle migrate lint        connects, so size-dependent checks can fire
```

| rule | fires on |
|---|---|
| `destructive-table` | `DROP TABLE` |
| `destructive-column` | `ALTER … DROP COLUMN` |
| `truncate` | `TRUNCATE` |
| `not-null-no-default` | `ADD COLUMN … NOT NULL` with no default |
| `rename-column` | `RENAME COLUMN` |
| `blocking-index` | an index added to a table over 100k rows |
| `column-type-change` | `MODIFY COLUMN` |
| `no-primary-key` | `CREATE TABLE` with no key |

Every finding carries a **remedy**, because a linter that only says "no" gets
switched off. Rules are named so one can be silenced without silencing the rest
(`--disable blocking-index`).

**Why introspection is worth the round trips.** The same statement deserves a
different verdict depending on the data. `DROP TABLE users` against an empty
table is cleanup — a warning. Against 2,000 rows it is data loss — an error.
`ADD COLUMN … NOT NULL` with no default is completely fine on a new table and
breaks every running instance of the old code on a populated one. Without the
schema, either every one of those fires (and people stop reading) or none does.

Row counts come from the optimiser's estimate rather than `COUNT(*)`:
counting every row of every table to lint a migration would cost more than the
migration, and the estimate is closest where it matters — on big tables.

Size-dependent rules **stay quiet** when there is no database, which is what
makes `validate` usable in CI rather than noisy.

Swift migrations produce no findings. A closure has no SQL to read — one more
thing the code path gives up.

## Online DDL

`ALTER TABLE` on a large MySQL table holds it, and that is an outage. The
established fix is a shadow-table copy — gh-ost or pt-online-schema-change — and
every migration tool that offers it shells out to one of those.

```sql
-- +swizzle Online
-- +swizzle Up
ALTER TABLE users ADD COLUMN nickname VARCHAR(64) NULL;
```

**Why we can do this natively.** The two established tools differ in how they
keep the shadow in sync. pt-osc installs **triggers**, adding write latency to
every statement on the table. gh-ost reads the **binary log** instead, so the
original is untouched. Swizzle already ships a production binlog client with
backpressure, GTIDs and row-event decoding — so the gh-ost approach is available
to us directly rather than as a subprocess. That is the whole reason this is
worth building here rather than shelling out.

How it runs: create `_<table>_gho` and apply the `ALTER` to it; note the binlog
position; copy rows in chunks with `INSERT IGNORE`; concurrently replay the
original's row events into the ghost with `REPLACE`/`DELETE`; then swap.

`INSERT IGNORE` on the copy and `REPLACE` on the applier are what make the race
safe in both directions — whichever gets there second yields to the newer value.

**Cutover is genuinely atomic, not merely quick.** The obvious approach — wait
for the applier to catch up, then `RENAME` — leaves a window where writes land
in the old table and are lost. Instead: one connection takes `LOCK TABLES …
WRITE`, a second issues the `RENAME` which queues *behind that lock but ahead of
every later write*, the applier drains, then the lock is released and the rename
runs first.

The drain waits on a **changelog marker**, not a binlog position. Positions
cannot work: on a table nobody is writing to, no events arrive, the applier's
position never moves, and the wait can only time out. That is exactly how the
empty-table case hung during development. A marker row written after writers are
blocked is guaranteed to be behind every change to the original, so seeing it
means everything before it has been applied.

Refused rather than guessed at:

- **No single-column primary key** — the copy and the applier both key on it.
- **Foreign keys** on or referencing the table — the rename would leave them
  pointing at the retired table.
- **Column renames** — the copy matches columns by name, so a renamed one would
  arrive empty.
- **`binlog_format` other than ROW** — STATEMENT format carries SQL text, not
  changed rows, and text cannot be replayed into a differently-shaped table.

A migration marked `Online` with no runner configured is an **error**, not a
fallback: asking for online and silently getting a locking ALTER is an outage
nobody agreed to.

The original is renamed to `_<table>_del` and kept. It is the only copy of the
pre-migration data, and dropping it automatically would make a mistake
unrecoverable.

## The journal migrates itself

The journal's shape has already changed once, gaining `id` and `kind` when
repeatable migrations arrived. `CREATE TABLE IF NOT EXISTS` does nothing to a
table that already exists in an older shape, so the first symptom of an outdated
journal was an unrelated `Unknown column 'id'` error from a later query — found
by running the new CLI against a database the old one had touched.

`ensureJournal` now checks the columns and upgrades in place, preserving every
recorded row. A tool whose whole job is migrating schemas cannot fail to migrate
its own.

## Where it sits

`SwizzleMigrate` depends on `SwizzleCore` only — not on any driver — so the same
migrator runs against all three databases through `SQLExecutor`. Only four things
are dialect-specific, behind `MigrationDialect`: the lexer rules, whether DDL is
transactional, the journal DDL, and the advisory-lock SQL.

## The CLI

```
swizzle migrate status              what is applied, pending, or drifted
swizzle migrate up   [--to N]       apply pending migrations
swizzle migrate down [--count N | --to N] [--yes]
swizzle migrate redo   [--yes]      revert and re-apply the newest — the dev loop
swizzle migrate baseline <version>  adopt an existing database
swizzle migrate create <name>       write a new timestamped migration
swizzle migrate validate            parse everything, no database needed
```

`up --dry-run` prints the exact statements that would run and changes nothing.

`redo` is the development loop: you apply a migration, find it wrong, edit it,
and want to run it again — which the checksum check otherwise refuses, correctly,
because on a shared database that edit is a real problem. Every tool lacking
`redo` grows a folk workflow of hand-deleting journal rows.

`baseline` is how an existing database adopts Swizzle at all. Write migrations
describing the schema you already have, baseline to the last of them, and
everything after runs normally. Repeatable migrations are deliberately not
baselined — they are cheap to re-apply, and re-applying proves they match.

The connection comes from `--url` or `$DATABASE_URL`, so in CI or a container
you usually pass nothing. The dialect is **detected**, not configured — asking
an operator which flavour their own database is would be a question the tool can
answer itself.

`validate` needs no database and reports **every** problem rather than stopping
at the first, which is what makes it useful in CI. `create` writes a UTC
timestamped file, stepping the version forward if one already exists — creating
two migrations in the same second is normal and used to produce a duplicate-version
pair the loader then rejected.

`down` is destructive, so it prints the plan and asks before touching anything
unless `--yes` is passed. It also checks for drift *before* showing the plan:
doing it the other way round printed a plan and then failed the checksum check,
which reads as though the revert half-happened.

Exit codes: `0` success, `1` a runtime problem (drift, a failed migration, a
declined confirmation), `64` a malformed command line.

## Status

Done: format, lexer, sources (directory and in-memory), journal, locking,
checksums, ordering, `up`/`down`/`status`, MySQL and MariaDB dialects, and the
`swizzle migrate` CLI. 45 tests, of which 10 run against all five live servers.

Not yet:

- **Postgres and SQLite conformances** — a few lines each, but they need those
  drivers to exist first (`pg_advisory_lock`, and SQLite's single-writer model
  where a lock table is the only option).
- **Embedding** — a build plugin that compiles a migrations directory into a
  generated `InMemoryMigrations`, so a single-binary deployment has no directory
  to point at. `InMemoryMigrations(files:syntax:)` already takes exactly the
  shape such a plugin would emit.

## Compared to `goose`

The file format here is modelled on goose's, down to the `-- +swizzle Up` /
`Down` directive shape, so the comparison is worth making explicitly.
`references/goose` is cloned for it.

### Both tools have both forms

| | goose | swizzle |
|---|---|---|
| SQL file | `-- +goose Up` / `Down` | `-- +swizzle Up` / `Down` |
| statement grouping | `StatementBegin` / `StatementEnd` | same, plus a scanner that recognises `BEGIN … END` bodies without them |
| skip the transaction | `-- +goose NO TRANSACTION` | `-- +swizzle NoTransaction` |
| code migration | a `.go` file registering `Up`/`Down` in `func init()` | a type conforming to `SwiftMigration` |
| code, no transaction | `AddMigrationNoTxContext` | `static let usesTransaction = false` |
| env substitution | `-- +goose ENVSUB ON` | — |
| online DDL | — | `-- +swizzle Online` |
| per-migration lint waiver | — | `-- +swizzle Allow <rule> <reason>` |
| checksums | none — the journal is `version_id`, `is_applied`, `tstamp` | recorded and verified per migration |

### Where the designs differ, and why

**Registration.** goose registers by side effect: a `.go` file calls
`goose.AddMigrationContext(Up, Down)` from `func init()`, and the *filename*
supplies the version. That is less typing and two failure modes: a file nobody
imports registers nothing and the migration silently does not exist, and the
version lives in the filename while the code lives in the body.

Swizzle asks for the version and name as static properties and for the migration
to be handed to a `SwiftMigrations` source explicitly. More typing; a missing
registration is a value you did not pass rather than an import you forgot.

**One version space.** Both interleave SQL and code migrations by version.
`CombinedMigrations` validates the merged set, so two migrations claiming one
version is an error rather than something resolved by source order.

**Checksums.** goose does not have them. Swizzle records one per migration and
verifies it, and is explicit that a Swift migration's checksum covers only its
declared identity — editing the body of an applied one is undetectable. That is
written down in `SwiftMigration`'s doc comment rather than left to be discovered.

### What this comparison found

`SwiftMigration` had no way to opt out of the wrapping transaction, where both
the SQL path and goose's code path do. It made `CREATE INDEX CONCURRENTLY`
unreachable from Swift on Postgres — the statement cannot run inside a
transaction block at all — and it quietly defeated the `batches(over:selecting:)`
helper, which exists to keep transactions short and was running every chunk
inside one long one. Only on Postgres and SQLite: MySQL's DDL is
non-transactional, so nothing was wrapped there and the gap was invisible.

`static var usesTransaction: Bool` now exists, defaulting to `true`.

### Not adopted

`ENVSUB`, goose's environment-variable substitution inside migration SQL. A
migration whose text depends on the environment is a migration whose checksum
depends on the environment, and the checksum is load-bearing here in a way it is
not in goose. If the need arises the answer is a parameter with a recorded value,
not a substitution at read time.

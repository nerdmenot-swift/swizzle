# Migration DX — what the field does, and what we should do

Research across the tools that matter, then an actual position. The one fixed
constraint is **SQL-syntax migrations**; everything else here is open.

## The three models

Everything in the space is one of these, and they are not compatible
philosophies.

| model | tools | you write | tool produces |
|---|---|---|---|
| **Versioned / imperative** | Flyway, goose, dbmate, golang-migrate, Sqitch | the SQL | ordering + tracking |
| **Declarative / schema-as-code** | Atlas, Skeema, Prisma, Drizzle | desired end state | the SQL, by diffing |
| **Code-first ORM** | Alembic, ActiveRecord, Ecto | schema in the host language | the SQL, by diffing |

Swizzle is model 1 and should stay there. That is already decided, but it is
worth knowing what we are giving up: Atlas's pitch is that versioned tools
"rely on the user to plan schema changes," and that views and dependent objects
get recreated out of order because nothing understands the dependency graph.
That criticism is fair. The answer is not to switch models — it is to steal the
parts of Atlas that are *separable* from being declarative, which turns out to
be most of the valuable ones (linting, drift detection).

## What the good tools have that we don't

### Flyway's migration kinds

Flyway distinguishes four, by filename prefix:

| | |
|---|---|
| `V__` versioned | applied once, in order — what we have |
| `U__` undo | reverts the matching version — our `Down` |
| `R__` repeatable | **re-applied whenever its checksum changes**, after all versioned ones |
| `B__` baseline | marks an existing database as already at version N |

**Repeatable is the one we are missing and should have.** It exists for objects
that are *replaced* rather than altered: views, stored procedures, functions,
triggers, grants. Today, changing a view means writing a new migration with the
whole `CREATE OR REPLACE VIEW` in it, every time, forever — so the definition is
smeared across a dozen files and no one file shows the current one. With
repeatable migrations the view lives in one file that reads like source code,
and the checksum machinery we already built decides when to re-run it.

**Baseline is table stakes for adoption.** Without it you cannot point Swizzle at
an existing production database — it would try to run migration 1 against a
schema that already has those tables. Every serious tool has this.

### Atlas's linting

50+ analyzers that read a migration and flag destructive changes, backward-
incompatible changes, table locks and rewrites, before it ever runs. This is the
single best idea in the modern generation of these tools, and it is *entirely
separable* from Atlas being declarative — it works on migration files.

For MySQL specifically the checks that matter are brutal and mechanical:
dropping a column or table; adding a `NOT NULL` column with no default; adding
an index to a large table; a type change that forces a full table rewrite; a
table with no primary key. Every one is a production incident that a linter
catches in CI for free.

### Sqitch's dependency graph, and its view of editing

Sqitch orders by **declared dependencies**, not version numbers, and uses a
Merkle tree over the change history for integrity. It also explicitly permits
editing a change *until you tag a release*.

The dependency model is more correct and considerably more machinery; I do not
think it earns its keep for us. The editing point, though, is a direct criticism
of what we built — see below.

### The dev loop

goose has `redo` (revert then re-apply the latest). Every tool that lacks it
grows a folk workflow of hand-deleting journal rows. This is the single most
common thing a developer does while writing a migration and we have no answer
for it.

## What people actually complain about

The failure reports converge on three things, and only one of them is about
features.

1. **Rollback rarely works in production.** Down migrations that drop a column
   cannot restore its data. The reported real-world rollback is "restore from
   backup" — one team's documented procedure would have lost 12 hours of orders.
   Flyway put undo behind a paid tier. Drizzle does not implement reverting at
   all.
2. **Scripts run out of order, or get skipped**, per environment.
3. **Migrations tested against sanitised sample data** behave differently
   against years of production quirks.

We already handle (2) with the ordering guard and the lock. (3) is not something
a library can fix. (1) deserves an honest reframe rather than a feature.

## Position

### Down migrations: keep, but stop selling them as a production feature

I claimed real down-migrations as a differentiator over Drizzle. Half right.
They are genuinely valuable in **development and test** — `redo` while iterating,
resetting a test database — and close to useless in **production**, because the
irreversible part is the data, not the schema.

So: keep them, keep refusing when a migration declares itself irreversible, and
document plainly that production recovery is roll-forward or restore. Selling
`down` as a production rollback story would be the dishonest kind of feature.

### Code-based migrations: yes, narrowly — but they are not the answer to the
### problem people reach for them with

The real case is unarguable: a data transformation that needs logic SQL does not
have. Re-encrypting a column under a new key. Backfilling a field from a value
that must be computed. Reshaping JSON with rules that live in the application.
goose supports Go migrations for exactly this.

But the reason people reach for them is usually **backfills**, and a large
backfill inside a migration is an anti-pattern regardless of language: it holds
the deploy open, cannot be batched or throttled safely, times out, and cannot be
resumed. The right shape for that is a separate idempotent, resumable job — with
the migration doing only the schema change that makes it possible.

Recommendation: support Swift migrations, but deliberately asymmetric.

- Registered in the **same version space** as SQL files, so ordering, the
  journal, the lock and `status` are one mechanism rather than two.
- Scoped to **data**, not schema. Schema stays SQL, which keeps the "readable and
  runnable by `mysql` at 3am" property that motivated the format.
- Given a **batching helper**, because the failure mode is known in advance.
- Documented with the advice above, prominently: most backfills should not be
  migrations at all.

The cost is real and worth stating: a Swift migration is not readable by `mysql`,
cannot be applied by hand during an incident, and cannot be checksummed
meaningfully (the compiled behaviour can change while the file does not). That is
why it should be the exception with a narrow shape, not a peer of the SQL path.

### Declarative: no

It is the opposite direction from the fixed constraint, and Drizzle's version of
it is what `drizzle-study.md` already argued against. But **drift detection is
separable** — comparing a live schema against what the migrations imply needs an
introspector, not a declarative model, and it is worth having on its own.

### The thing only we can build

gh-ost — GitHub's zero-downtime MySQL schema tool — works by **reading the
binlog** to keep a shadow table in sync while it copies, rather than using
triggers. That is precisely the machinery we already shipped: a production
binlog client with backpressure, GTIDs, and row events.

No Swift migration tool has online DDL. Almost no migration tool in any language
has it *built in* — Skeema shells out to gh-ost or pt-online-schema-change.
An `-- +swizzle Online` directive on an `ALTER TABLE`, executed as a
binlog-driven copy, would be a genuine differentiator rather than a catch-up
feature.

It is also a large build and should not block anything else.

## Proposed order

**Now — clearly right, small:**

1. **Repeatable migrations** — `-- +swizzle Repeatable`, re-applied on checksum
   change, after the versioned ones. Reuses machinery we have.
2. **Baseline** — `swizzle migrate baseline <version>`, so an existing database
   can adopt Swizzle at all.
3. **Dry run** — `--dry-run` prints the exact statements without executing.
   Cheap; makes review and incident work possible.
4. **`redo`** — revert and re-apply the newest migration. The dev loop.
5. **Better drift ergonomics** — Sqitch is right that you iterate before release.
   Keep refusing by default, but have the error name the exact command that
   fixes it (`swizzle migrate redo`) rather than only explaining the danger.

**Next — high value, more work:**

6. **Linting**, run by `validate` so CI gets it free. Start with the MySQL checks
   listed above.
7. **Schema introspection**, which unlocks drift detection and is needed by the
   linter anyway to know table sizes and existing indexes.

**Decide, then maybe:**

8. **Swift data migrations**, in the narrow shape above.
9. **Online DDL over our own binlog client.**

**Not doing:** declarative schema-as-code; a dependency DAG instead of versions;
`down` sold as production rollback.

## Sources

- [Bytebase — evolution of schema change tools](https://www.bytebase.com/blog/top-database-schema-change-tool-evolution/)
- [Atlas vs Flyway, Liquibase and ORMs](https://atlasgo.io/atlas-vs-others)
- [Atlas migration analyzers](https://atlasgo.io/lint/analyzers)
- [Flyway — migration types](https://documentation.red-gate.com/fd/migrations-271585107.html)
- [Flyway — repeatable migrations](https://documentation.red-gate.com/fd/repeatable-migrations-273973335.html)
- [Sqitch — about](https://sqitch.org/about/)
- [goose](https://github.com/pressly/goose)
- [Database rollbacks in CI/CD — strategies and pitfalls](https://medium.com/@jasminfluri/database-rollbacks-in-ci-cd-strategies-and-pitfalls-f0ffd4d4741a)
- [Migration horror stories](https://medium.com/the-tech-draft/database-migration-horror-stories-lessons-from-10-companies-that-got-it-wrong-and-right-71857e3319da)
- [gh-ost for MySQL schema migrations](https://oneuptime.com/blog/post/2026-03-31-mysql-gh-ost-schema-migrations/view)

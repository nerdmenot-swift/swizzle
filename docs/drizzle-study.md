# Drizzle: what they solved, how deep, and where the gaps are

Study of `drizzle-team/drizzle-orm` @ main (shallow clone, ~30 MB). Written to
answer three questions: what did they get right, how wide is the surface really,
and where is the room for Swizzle to be better rather than merely different.

---

## 1. The shape of the thing

40 packages under `src/`. Five *dialect cores* and ~30 driver adapters on top.

| dialect core | LOC | its `select.ts` | its `dialect.ts` |
|---|---:|---:|---:|
| `pg-core` | 11,402 | 1,346 | 1,445 |
| `gel-core` | 9,126 | — | — |
| `mysql-core` | 8,780 | 1,379 | 1,337 |
| `singlestore-core` | 8,157 | — | — |
| `sqlite-core` | 7,417 | 1,101 | 1,047 |

**~45k LOC of near-duplicate dialect code.** The SELECT builder is written five
times. `dialect.ts` — the actual SQL generator — is written five times. This is
not incidental; it's forced by the architecture. TypeScript can't express
"this method exists only when the dialect supports RETURNING" cleanly across a
shared builder, so they forked the builder per dialect.

Driver adapters: `node-postgres`, `postgres-js`, `neon-http`, `neon-serverless`,
`pglite`, `vercel-postgres`, `supabase`, `aws-data-api`, `xata-http`, `pg-proxy`,
`mysql2`, `planetscale-serverless`, `tidb-serverless`, `mysql-proxy`,
`better-sqlite3`, `bun-sqlite`, `bun-sql`, `libsql`, `d1`, `durable-sqlite`,
`expo-sqlite`, `op-sqlite`, `sql-js`, `sqlite-proxy`, `prisma`, `knex`, `kysely`,
`netlify-db`, `gel`, `singlestore`.

That driver breadth is the actual moat, and it is mostly serverless-platform
adapters — not something Swizzle needs to match.

---

## 2. What they got right

### The `sql` template is a first-class citizen, not an escape hatch of last resort

`sql.ts` (1,821 LOC across `sql/`) gives a composable tagged template with
`sql.raw`, `sql.identifier`, `sql.join`, `sql.fromList`, `.if()`, `.append()`,
`.inlineParams()`, and per-value `mapToDriverValue` / `mapFromDriverValue`
encoders. Crucially it composes *with* the builder — an `SQL` fragment is a valid
argument almost anywhere a column is.

This is the single most important ergonomic decision in the library. **The builder
is never a dead end.** Anything you can't express, you drop to `sql` for, and you
don't lose the surrounding structure or the parameter binding.

### Prepared statements with named placeholders

`placeholder('name')` + `fillPlaceholders()` + `.prepare()`. The query is built,
type-checked and SQL-generated once, then re-executed with different values. This
is what makes the builder viable in a hot path — you don't pay SQL generation per
request.

### The result cache is well designed — but Swizzle is deliberately not building one

Recorded decision: **Swizzle ships no result cache.** Documented here because the
design is genuinely good and will otherwise keep getting re-proposed. See §4 for
why it's out of scope.

`cache/core/cache.ts` is only 78 LOC but the model is right:

```ts
abstract strategy(): 'explicit' | 'all'
abstract get(key, tables, isTag, isAutoInvalidate?): Promise<any[] | undefined>
abstract put(hashedQuery, response, tables, isTag, config?): Promise<void>
abstract onMutate({ tags, tables }): Promise<void>
```

Key is `SHA-256(sql + JSON(params))`. Every query records **which tables it
touched**; every mutation calls `onMutate` with its tables, invalidating dependent
entries automatically. Opt-in per query via `.$withCache()`, or global via
`strategy: 'all'`. Pluggable backend (`cache/upstash` ships).

Note this is a **result cache**, not a prepared-statement cache and not sqlc.
Those are three genuinely different things — and only the latter two are in
Swizzle's scope.

### The relational query API is the best thing in the library, and it is not an ORM

`db.query.users.findMany({ with: { posts: { with: { comments: true } } } })`

It compiles to **one round trip** using lateral joins plus JSON aggregation —
no N+1, no identity map, no lazy loading, no dirty tracking. Per dialect:

- Postgres: `json_build_array` + `coalesce(json_agg(...))` + `lateral` join
- SQLite: `coalesce(json_group_array(...), json_array())`
- MySQL: `json_array` + `coalesce(json_arrayagg(...))`, **plus** an entire second
  code path — `buildRelationalQueryWithoutLateralSubqueries` (~240 LOC) — for
  MySQL versions without lateral support

This is worth having in Swizzle. It's a *typed join+aggregate macro*, which is
exactly the thing a query builder should make easy and hand-written SQL makes
tedious. It doesn't violate the no-ORM position.

### Genuine SQL depth, not a toy

- **Joins**: `innerJoin`, `leftJoin`, `rightJoin`, `fullJoin`, `crossJoin`, plus
  `innerJoinLateral`, `leftJoinLateral`, `crossJoinLateral`
- **Set ops**: `union`, `unionAll`, `intersect`, `intersectAll`, `except`, `exceptAll`
- **Row locking**: `.for('update' | 'share', { of, noWait, skipLocked })`
- **Transactions**: `isolationLevel` (all four), `accessMode` (read only/write),
  `deferrable`, nested transactions via savepoints, `tx.rollback()`
- **Views**: regular + materialized, with `refreshMaterializedView()`
- **Postgres RLS**: `pgPolicy`, `pgRole` — first-class row-level security
- **Column breadth**: pg 28 types including `cidr`, `inet`, `macaddr`, `macaddr8`,
  `interval`, `point`, `line`, `numeric`, `jsonb`, plus `vector` and `postgis`
  extension modules. mysql 24. sqlite 6 (which is correct — SQLite has 5 storage
  classes).
- **Vector distance functions**: `cosineDistance`, `innerProduct`,
  `hammingDistance`, `jaccardDistance`, `l1Distance`/`l2Distance`

### `$dynamic` — an honest answer to a real tension

Their builder normally lets you call `.where()` **once** (calling it twice
silently replaces). `$dynamic()` flips a phantom flag that unlocks repeated calls
for programmatic query building. It's a decent escape hatch for a self-inflicted
problem — see §4.

### `--> statement-breakpoint`

Their workaround for MySQL's non-transactional DDL: a migration file is split on
that marker so statements can be applied and tracked individually. Small detail,
correct instinct.

---

## 3. Where the gaps are — Swizzle's actual openings

### Streaming barely exists, and fails at runtime when absent

This is the big one, and it lands directly on the "streaming from day one"
requirement.

| dialect | streaming |
|---|---|
| Postgres (`pg-core`) | **none — no `iterator`, no cursor, nothing** |
| SQLite (`sqlite-core`) | **none** |
| MySQL (`mysql-core`) | `abstract iterator(): AsyncGenerator` |

And within MySQL, only `mysql2` and `singlestore` actually implement it. The
others declare the method and **throw at runtime**:

```ts
// planetscale-serverless/session.ts
override iterator(): AsyncGenerator<T['iterator']> {
  throw new Error('Streaming is not supported by the PlanetScale Serverless driver');
}
// tidb-serverless: same. prisma/mysql: 'Method not implemented.'
```

This is precisely the runtime-capability-failure pattern Swizzle's capability
protocols exist to eliminate. It's also a real functional hole: you cannot stream
a large Postgres result set through Drizzle at all.

The `mysql2` implementation is also instructive as a *warning*. It manually
pauses/resumes the underlying stream and races three promises per row:

```ts
const row = await Promise.race([onEnd, onError, new Promise(r => stream.once('data', r))]);
```

A promise allocation and a race per row. Swift's `AsyncSequence` with proper
backpressure will be dramatically better here — this is a place where Swizzle can
win on performance, not just ergonomics.

### Migrations are the weakest pillar

Runtime `migrator.ts` is **60 lines**. It reads `meta/_journal.json`, hashes each
`.sql` file, and applies unapplied ones inside a transaction against a
`__drizzle_migrations` table (`id`, `hash`, `created_at`).

Three real gaps:

1. **No locking.** No `pg_advisory_lock`, no `GET_LOCK` — grep confirms zero hits
   repo-wide. Two pods rolling out simultaneously will race.
2. **No down migrations.** The runtime migrator has no notion of reverting.
   `drizzle-kit drop` removes a migration *file*; it doesn't roll back the DB.
3. **Schema-diff-first, not SQL-first.** The TS schema is the source of truth;
   `drizzle-kit generate` diffs it against a JSON snapshot
   (`snapshotsDiffer.ts`, `jsonStatements.ts`, `sqlgenerator.ts`) and *emits* SQL.
   Plus `push` (apply diff directly) and `introspect` (DB → TS schema).

That third point is a genuine architectural fork, not a defect — but it's the
**opposite direction** from goose-style SQL-first migrations. It also means
Drizzle's schema and migrations are coupled in a way that makes hand-editing
migrations awkward.

### The triplication is structural

45k LOC of forked dialect code is the cost of not having conditional conformance.
The measured Swizzle spike already shows the alternative works: one builder,
capability protocols, and `.returning()` on MySQL is a compile error with a
self-documenting diagnostic.

### `.where()` semantics

Drizzle's `.where()` *replaces* rather than ANDs, which is why it must be
restricted to one call and why `$dynamic` exists. Swizzle's `.where()` already
ANDs and returns `Self`, so the restriction and the escape hatch are both
unnecessary. Worth keeping.

---

## 4. Implications for Swizzle

**Steal:**
- `sql` template as a composable first-class citizen that interoperates with the
  builder everywhere. Non-negotiable for a builder to feel good.
- Prepared statements with named placeholders and build-once/execute-many.
- The relational query API (lateral + JSON aggregation, one round trip).
- Transaction config breadth: isolation level, access mode, deferrable, savepoints.

**Beat:**
- **Streaming across all three dialects from v1** — Drizzle has it for one, and
  throws for the rest. All three databases support server-side streaming; there is
  no reason to gate it.
- **One builder, not five.** Capability protocols instead of forked packages.
- **Migrations with locking and real down-migrations**, SQL-first.
- Compile-time capability errors instead of runtime `throw new Error('not supported')`.

**Explicitly not building — result caching.**

Drizzle's cache memoizes result *rows* in an external store (Redis/Upstash) and
invalidates by table on mutation. Swizzle does not do this, for three reasons:

1. **It's the hardest correctness problem in the space and it isn't ours.**
   Invalidation has to be right across every process touching the database —
   including ones that never went through Swizzle (psql, a cron job, another
   service, a replica). A library-level cache can only invalidate what it
   observes, so it is silently wrong exactly when it matters. Drizzle's
   `onMutate` is correct only under the assumption that all writes flow through
   Drizzle, which is an assumption a library cannot enforce.
2. **It forces an external dependency into a library that otherwise has none.**
   Useful caching means Redis or equivalent. That's an infrastructure decision
   belonging to the application, not to a query builder.
3. **It muddies what pillar 3 is.** With result caching gone, "query cache and
   executor" resolves cleanly to two things that *are* ours: compile-time query
   compilation (sqlc-style, from the schema IR) and prepared-statement caching
   keyed off a stable builder-derived hash. Both are in-process, both are
   invisible to the user, and neither can be silently wrong.

Applications that want result caching should build it above Swizzle, where they
know their own invalidation boundaries.

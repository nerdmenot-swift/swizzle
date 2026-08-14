# `swizzle generate` — the third pillar, end to end

A schema, a query file, and the Swift both produce. Everything here is committed
so it can be read without running anything, and everything here is checked so it
cannot rot.

| path | what it is |
|---|---|
| `migrations/` | the schema, in the ordinary migration form |
| `queries/notes.sql` | the queries, and every directive that exists |
| `Generated/Queries.swift` | **generated.** Committed, compiled, and diffed |
| `swizzle.lock.json` | what `--verify` checks in CI, with no database |

## Regenerating

```
swizzle generate queries \
    --url sqlite:notes.db -q queries -d migrations \
    -o Generated/Queries.swift --lockfile swizzle.lock.json
```

The migrations are run into a throwaway database and the queries described
there — prepared, never executed — so the types follow the migrations rather
than whatever state a server happens to be in.

## The part that is not like sqlc

sqlc parses your SQL. It carries `libpg_query` (the real PostgreSQL parser) for
Postgres, Vitess's parser for MySQL, and a hand-written grammar for SQLite — and
that asymmetry is exactly why its Postgres support is so much better than its
other two.

Swizzle asks the database instead. Every engine can describe a statement at
prepare time without running it, so there is no parser to write or maintain, and
the answer is whatever the engine actually says. The cost is a live database at
generation time, paid on a developer's machine; CI runs `--verify`, which needs
none.

The cost shows up honestly in `queries/notes.sql`: SQLite cannot type `COUNT(*)`,
so it takes a `-- +swizzle Type` directive, while MySQL and Postgres type the same
query themselves. A parser would have had the same answer everywhere — and would
have been three parsers.

## These are checked

An example that no longer works is worse than no example, because it is the first
thing a newcomer copies.

- `Generated/Queries.swift` is in the **`SwizzleExamples` target**, so `swift
  build` compiles it. That is not a formality: it caught the emitter writing
  `some AsyncSequence<Row, any Error>`, whose second parameter needs macOS 15
  while this package targets 14. The only test until then compared the emitter's
  output to a string, which is a test that the emitter agrees with itself.
- `CodegenGoldenTests` regenerates from these files and **diffs**, so an emitter
  change cannot leave the committed output behind.
- The same suite **runs** the generated functions against a real database. That
  the compiler accepted them does not mean they return the right rows.

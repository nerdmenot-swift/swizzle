# Examples

Files you can open, which the format did not have before this. The two forms are
the same two `goose` offers, and the directive vocabulary is deliberately its
own — see `docs/migrations.md` for the full comparison.

## `migrations/` — the SQL form

| file | what it shows |
|---|---|
| `00001_create_users.sql` | the ordinary case: `Up`, `Down`, nothing special |
| `00002_add_slug.sql` | adding a column, and a revert that undoes exactly it |
| `00003_concurrent_index.sql` | `NoTransaction`, and a per-migration lint waiver |
| `00004_function_body.sql` | a body full of semicolons, and why it needs no directive |

The filename supplies the version and the name: `<version>_<name>.sql`.

A plain SQL file with comment directives stays runnable by `psql` or `mysql`
directly. That is the property the format is built around — when a migration goes
wrong at 3am, somebody can open it and apply half of it by hand.

## `swift-migrations/` — the code form

For a data transformation SQL cannot express: a value computed by application
rules, a column re-encrypted under a new key, JSON reshaped by logic that lives
in Swift.

`BackfillSlugs.swift` shows both halves worth knowing — chunked iteration, and
`usesTransaction = false`, which is what keeps the chunking honest. Batching
exists to keep transactions short; without that line every chunk lands inside one
long-running transaction.

**Read the caveats in `SwiftMigration`'s doc comment before reaching for this.**
A large backfill inside a migration is an anti-pattern regardless of language,
and the doc says so at length.

## These are checked

An example that no longer works is worse than no example, because it is the first
thing a newcomer copies.

- The Swift files are a **build target** (`SwizzleExamples`), so `swift build`
  compiles them. No `.library` product — they exist to be read, not imported.
- The SQL files are parsed by the real parser in
  `Tests/SwizzleMigrateTests/ExampleMigrationTests.swift`, which asserts what
  each directive does.

Both caught something while being written. Deleting `NoTransaction` from
`00003` fails the suite, as it should. Deleting `StatementBegin`/`StatementEnd`
from what is now `00004` changed **nothing** — the splitter already handled the
dollar-quoted body — so that example was demonstrating an escape hatch on a case
that does not need one. It was rewritten to show the truth instead.

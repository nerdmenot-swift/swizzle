---
title: Quick start
description: A table, a migration, and a query — in about five minutes.
---

We will make a table, migrate it, and read from it. No configuration files, no code
generation step you have to run first, and nothing to register.

## 1. Write a migration

Migrations are `.sql` files with two comment directives. That is the entire format.

```sql
-- migrations/00001_create_notes.sql

-- +swizzle Up
CREATE TABLE notes (
    id     INTEGER PRIMARY KEY,
    title  TEXT NOT NULL,
    body   TEXT
);

-- +swizzle Down
DROP TABLE notes;
```

The file stays runnable by hand. Paste it into `psql` and it works — which matters more
than it sounds like it does, because the moment you need that is the moment something has
gone wrong and nobody wants to learn a tool.

## 2. Run it

```
swift run swizzle migrate up --url sqlite:app.db
```

## 3. Query it

```swift
let rows = try await connection.execute(
    select(notes.id, notes.title)
        .from(notes)
        .where(notes.body.isNotNull)
        .orderBy(notes.id.desc)
        .limit(10)
)
```

`notes.id` is an `SQLExpression<Int64>` and `notes.title` is an `SQLExpression<String>`,
so comparing one to the other does not compile. That is most of the value: the mistakes
you would otherwise find in a stack trace, you find in the editor instead.

## What next

- [Migrations](/guides/migrations/) — the format in full, including the awkward cases
- [Querying](/guides/querying/) — joins, aggregates, and what is deliberately missing
- [Codegen](/guides/codegen/) — write SQL, get typed Swift functions

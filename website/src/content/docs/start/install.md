---
title: Install
description: Add Swizzle to a Swift package, and pick the engines you actually use.
---

Add the package:

```swift
.package(url: "https://github.com/nerdmenot-swift/swizzle", from: "0.1.0")
```

Then take only the parts you need. Swizzle ships each database as its own product, so a
project that only talks to Postgres never builds the MySQL driver:

```swift
.target(name: "App", dependencies: [
    .product(name: "SwizzlePostgres", package: "swizzle"),
])
```

| Product | What it gets you |
|---|---|
| `Swizzle` | the query builder and core types, no driver |
| `SwizzlePostgres` | Postgres, driver and engine |
| `SwizzleMySQLEngine` | MySQL and MariaDB |
| `SwizzleSQLiteEngine` | SQLite, with the amalgamation vendored |
| `SwizzleMigrate` | migrations, engine-agnostic |

## The CLI

Migrations and codegen run through a small binary:

```
swift run swizzle migrate up --url postgres://localhost/app
```

You can also install it once and forget about it. It is the same binary either way —
there is no separate "server" component and nothing to keep running.

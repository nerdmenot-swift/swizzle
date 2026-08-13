# SwizzleConnectionPool

**Vendored from [postgres-nio](https://github.com/vapor/postgres-nio)'s
`ConnectionPoolModule`.** MIT licensed — see `LICENSE-postgres-nio.txt`.

## The only edit

Three module-qualified self-references were rewritten from
`_ConnectionPoolModule.ConnectionIDGenerator()` to
`SwizzleConnectionPool.ConnectionIDGenerator()`. The qualification is load-bearing
rather than stylistic: `ConnectionPool` has a *generic parameter* also named
`ConnectionIDGenerator`, which shadows the concrete type, so dropping the module
prefix does not compile.

The target could not simply be renamed to `_ConnectionPoolModule` to avoid even
that edit — an application depending on both Swizzle and PostgresNIO would then
have two modules with the same name.

## Why vendored rather than depended on

`_ConnectionPoolModule` *is* a public product of postgres-nio, so depending on it
would work. It was vendored anyway for two reasons:

1. **A MySQL driver should not depend on the Postgres driver package.** Even
   though SwiftPM would link only this one target, the package graph — and
   therefore `Package.resolved` — would pull in postgres-nio, swift-nio-ssl,
   swift-nio-transport-services and swift-metrics. That is a lot of surface to
   explain for a pool.
2. **The leading underscore means no API-stability promise.** A minor postgres-nio
   release may change it freely.

It is genuinely self-contained: the only non-platform imports are `Atomics` and
`DequeModule`. No SwiftNIO, nothing Postgres-specific.

## Why not write one

A correct async connection pool is weeks of subtle work — fairness under
contention, keep-alive, leak detection, graceful shutdown, backpressure on
acquisition. This one is battle-tested behind `PostgresClient`, and it is generic
over the connection type, so **one pool serves Postgres, MySQL and SQLite**.

## Updating

Re-copy `Sources/ConnectionPoolModule/*.swift` from postgres-nio and re-run the
test suite. Keep it unmodified so that stays a mechanical operation — Swizzle's
own code lives in `SwizzleMySQL`, not here.

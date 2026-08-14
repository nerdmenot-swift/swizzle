-- The two directives that exist for the awkward cases.
--
-- `NoTransaction` is required here rather than tidy: Postgres refuses
-- `CREATE INDEX CONCURRENTLY` inside a transaction block, and the migrator wraps
-- every migration by default on an engine with transactional DDL.
--
-- `Allow` waives one lint rule for one migration, with a reason recorded in the
-- file. The alternative — a CLI flag — turns the rule off for the whole run and
-- every migration in it, which is how a linter ends up switched off for good.

-- +swizzle NoTransaction
-- +swizzle Allow slow-index building the index concurrently is the point

-- +swizzle Up
CREATE INDEX CONCURRENTLY users_created_at_idx ON users (created_at);

-- +swizzle Down
DROP INDEX CONCURRENTLY users_created_at_idx;

-- Adding a column, with the revert that undoes exactly it.
--
-- A `Down` section is optional. Leaving it out is the honest choice for
-- something that genuinely cannot be reverted; writing one that quietly does
-- nothing is the worst of the three options.

-- +swizzle Up
ALTER TABLE users ADD COLUMN slug TEXT;

-- +swizzle Down
ALTER TABLE users DROP COLUMN slug;

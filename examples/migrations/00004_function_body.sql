-- A body full of semicolons, and **no** grouping directive — because the
-- splitter does not need one.
--
-- It recognises dollar-quoted bodies (`$$ … $$`, and named tags like
-- `$body$ … $body$`), single-quoted function bodies, and `BEGIN … END` compound
-- bodies in MySQL and SQLite triggers. All of those arrive as one statement on
-- their own. Verified, not assumed: `ExampleMigrationTests` asserts this file
-- parses to exactly one `Up` statement.
--
-- `-- +swizzle StatementBegin` / `StatementEnd` exists for the case that defeats
-- that detection — a body whose end the scanner cannot find. Reach for it then,
-- and not before. Wrapping something that did not need it is harmless but
-- teaches the next reader to do it everywhere.

-- +swizzle Up
CREATE FUNCTION user_display(u users) RETURNS TEXT AS $$
BEGIN
    RETURN COALESCE(u.display_name, u.email);
END;
$$ LANGUAGE plpgsql;

-- +swizzle Down
DROP FUNCTION user_display(users);

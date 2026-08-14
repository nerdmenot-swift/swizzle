-- The query file, and every directive that exists.
--
-- Placeholders are SQLite's own `?` rather than a portable invention, for the
-- same reason the migration format keeps its SQL plain: this file stays runnable
-- by hand. Paste any statement below into `sqlite3` and it works.

-- The ordinary case. `id` and `title` are `NOT NULL` in the schema and come back
-- non-optional; `body` is not and comes back `String?`. Nobody wrote that down —
-- the database was asked.
-- +swizzle Query GetNote(id: Int64) :one
SELECT id, title, body FROM notes WHERE id = ?;

-- +swizzle Query ListByAuthor(authorID: Int64) :many
SELECT id, title FROM notes WHERE author_id = ? ORDER BY id;

-- `Type`, and the query that makes it necessary. SQLite's `decltype` is null for
-- every expression, so `COUNT(*)` is genuinely unknowable — it would otherwise
-- generate as `SQLValue`. MySQL and Postgres type this themselves and need no
-- directive, which is why it is a directive rather than a config setting.
--
-- The spelling carries the optionality: `Int64` here, `Int64?` if it could be
-- null. That is Swift's vocabulary rather than one of ours.
-- +swizzle Type n Int64
-- +swizzle Query CountNotes :one
SELECT COUNT(*) AS n FROM notes;

-- `NotNull`, and the query that makes it necessary.
--
-- SQLite cannot say which side of an outer join a column came from without a
-- parser, so a statement containing one widens *everything* to optional — the
-- cheaper failure, but wrong for `id` and `title`, which sit on the left. Both
-- are narrowed back. `name` is left alone, because on the right of a `LEFT JOIN`
-- it genuinely can be null, and that is the case the widening exists for.
-- +swizzle NotNull id
-- +swizzle NotNull title
-- +swizzle Query NotesWithAuthor :many
SELECT n.id, n.title, a.name
FROM notes n
LEFT JOIN authors a ON a.id = n.author_id
ORDER BY n.id;

-- `:stream` has no sqlc equivalent. It generates into a separate extension
-- constrained to `SQLStreamingExecutor`, so on a backend that cannot stream the
-- method does not exist rather than failing when it is called.
-- +swizzle Query StreamTitles :stream
SELECT title FROM notes ORDER BY id;

-- `:exec` returns the rows affected.
-- +swizzle Query DeleteNote(id: Int64) :exec
DELETE FROM notes WHERE id = ?;

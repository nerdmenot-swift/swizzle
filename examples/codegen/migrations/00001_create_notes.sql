-- The schema the generated code is typed against.
--
-- SQLite-flavoured, unlike `examples/migrations`, because these are *run*: the
-- generator migrates them into a throwaway database and describes the queries
-- there, so what comes out follows the migrations rather than whatever state a
-- server happens to be in.

-- +swizzle Up
CREATE TABLE authors (
    id   INTEGER PRIMARY KEY,
    name TEXT NOT NULL
);

CREATE TABLE notes (
    id        INTEGER PRIMARY KEY,
    author_id INTEGER NOT NULL REFERENCES authors (id),
    title     TEXT NOT NULL,
    body      TEXT
);

-- +swizzle Down
DROP TABLE notes;
DROP TABLE authors;

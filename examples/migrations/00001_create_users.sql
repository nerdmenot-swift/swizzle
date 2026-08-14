-- The ordinary case: a schema change, reversible, nothing special.
--
-- The directive form is goose's, deliberately. A plain SQL file with comment
-- directives stays runnable by `psql` or `mysql` directly, which is what matters
-- when a migration goes wrong at 3am and somebody has to apply half of it by
-- hand.

-- +swizzle Up
CREATE TABLE users (
    id          BIGINT PRIMARY KEY,
    email       TEXT NOT NULL,
    display_name TEXT,
    created_at  TIMESTAMP NOT NULL
);

CREATE UNIQUE INDEX users_email_idx ON users (email);

-- +swizzle Down
DROP TABLE users;

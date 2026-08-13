-- MySQL 9.x fixture users.
--
-- Separate from mysql.sql because **9.0 removed `mysql_native_password`
-- outright** — the plugin does not exist, so a CREATE USER naming it fails and
-- takes the whole seed with it. 9.x ships only caching_sha2_password (the
-- default) and sha256_password.
--
-- That absence is itself worth having in the matrix: it is the configuration a
-- client meets on any current MySQL, where the classic plugin is simply gone.

CREATE DATABASE IF NOT EXISTS swizzle_test;

-- Idempotent: the seed may run again against a datadir that already has
-- these users, and CREATE USER on an existing name aborts the whole script.
DROP USER IF EXISTS 'caching'@'%';
DROP USER IF EXISTS 'sha256'@'%';
DROP USER IF EXISTS 'nopass'@'%';

CREATE USER 'caching'@'%' IDENTIFIED WITH caching_sha2_password BY 'cachingpass';
CREATE USER 'sha256'@'%'  IDENTIFIED WITH sha256_password       BY 'sha256pass';
CREATE USER 'nopass'@'%'  IDENTIFIED WITH caching_sha2_password BY '';

GRANT ALL PRIVILEGES ON swizzle_test.* TO 'caching'@'%';
GRANT ALL PRIVILEGES ON swizzle_test.* TO 'sha256'@'%';
GRANT ALL PRIVILEGES ON swizzle_test.* TO 'nopass'@'%';

GRANT PROCESS ON *.* TO 'caching'@'%';
GRANT SELECT ON performance_schema.* TO 'caching'@'%';
GRANT REPLICATION CLIENT, REPLICATION SLAVE ON *.* TO 'caching'@'%';

-- FLUSH PRIVILEGES clears the server's caching_sha2 password cache, which is
-- the only way to force the RSA full-authentication path from the client side.
-- Without this grant that path stays untested — which is most of the reason
-- this fixture exists.
GRANT RELOAD ON *.* TO 'caching'@'%';

-- SESSION_VARIABLES_ADMIN lets a test toggle binlog_transaction_compression for
-- its own connection, which is how the compressed-transaction path is exercised
-- without baking a non-default setting into the fixture.
GRANT SESSION_VARIABLES_ADMIN ON *.* TO 'caching'@'%';

FLUSH PRIVILEGES;

-- Shadow databases for `swizzle generate`.
--
-- Codegen prepares statements against a throwaway database rather than the real
-- one, so the fixture users need rights across the whole `swizzle_shadow_`
-- namespace. `_` is a single-character wildcard in a grant, so it is escaped:
-- an unescaped `swizzle_shadow_%` would match names nobody intended.
GRANT ALL PRIVILEGES ON `swizzle\_shadow\_%`.* TO 'caching'@'%';
GRANT ALL PRIVILEGES ON `swizzle\_shadow\_%`.* TO 'sha256'@'%';
GRANT ALL PRIVILEGES ON `swizzle\_shadow\_%`.* TO 'nopass'@'%';
FLUSH PRIVILEGES;

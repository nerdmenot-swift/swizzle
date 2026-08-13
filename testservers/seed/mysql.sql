-- MySQL fixture users.
--
-- The point of having MySQL in the matrix at all: caching_sha2_password (both
-- the fast path and the RSA full-auth exchange) and sha256_password exist only
-- here. MariaDB implements neither, so without this server those code paths —
-- and zstd, MySQL GTID and COM_BINLOG_DUMP_GTID — cannot be verified.

CREATE DATABASE IF NOT EXISTS swizzle_test;

-- Idempotent: the seed may run again against a datadir that already has
-- these users, and CREATE USER on an existing name aborts the whole script.
DROP USER IF EXISTS 'native'@'%';
DROP USER IF EXISTS 'nopass'@'%';
DROP USER IF EXISTS 'caching'@'%';
DROP USER IF EXISTS 'sha256'@'%';

CREATE USER 'native'@'%'   IDENTIFIED WITH mysql_native_password BY 'nativepass';
CREATE USER 'nopass'@'%'   IDENTIFIED WITH mysql_native_password BY '';
CREATE USER 'caching'@'%'  IDENTIFIED WITH caching_sha2_password BY 'cachingpass';
CREATE USER 'sha256'@'%'   IDENTIFIED WITH sha256_password       BY 'sha256pass';

GRANT ALL PRIVILEGES ON swizzle_test.* TO 'native'@'%';
GRANT ALL PRIVILEGES ON swizzle_test.* TO 'nopass'@'%';
GRANT ALL PRIVILEGES ON swizzle_test.* TO 'caching'@'%';
GRANT ALL PRIVILEGES ON swizzle_test.* TO 'sha256'@'%';

GRANT PROCESS ON *.* TO 'native'@'%';
GRANT SELECT ON performance_schema.* TO 'native'@'%';

-- Replication, for the binlog tests. MySQL spells these differently from
-- MariaDB: REPLICATION CLIENT rather than BINLOG MONITOR.
GRANT REPLICATION CLIENT, REPLICATION SLAVE ON *.* TO 'native'@'%';

-- FLUSH PRIVILEGES clears the server's caching_sha2 password cache, which is
-- the only way to force the RSA full-authentication path from the client side.
-- Without this grant that path stays untested — which is most of the reason
-- this fixture exists.
GRANT RELOAD ON *.* TO 'native'@'%';

-- SESSION_VARIABLES_ADMIN lets a test toggle binlog_transaction_compression for
-- its own connection, which is how the compressed-transaction path is exercised
-- without baking a non-default setting into the fixture.
GRANT SESSION_VARIABLES_ADMIN ON *.* TO 'native'@'%';

FLUSH PRIVILEGES;

-- Shadow databases for `swizzle generate`.
--
-- Codegen prepares statements against a throwaway database rather than the real
-- one, so the fixture users need rights across the whole `swizzle_shadow_`
-- namespace. `_` is a single-character wildcard in a grant, so it is escaped:
-- an unescaped `swizzle_shadow_%` would match names nobody intended.
GRANT ALL PRIVILEGES ON `swizzle\_shadow\_%`.* TO 'native'@'%';
GRANT ALL PRIVILEGES ON `swizzle\_shadow\_%`.* TO 'nopass'@'%';
GRANT ALL PRIVILEGES ON `swizzle\_shadow\_%`.* TO 'caching'@'%';
GRANT ALL PRIVILEGES ON `swizzle\_shadow\_%`.* TO 'sha256'@'%';
FLUSH PRIVILEGES;

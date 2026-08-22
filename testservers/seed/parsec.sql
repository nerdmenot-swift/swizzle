-- Everything in base.sql plus ed25519.
--
-- PARSEC used to be here and is now in `optional-parsec.sql`, applied separately
-- and allowed to fail. The x86_64 Linux builds ship the *client* plugin
-- (`parsec.so`) without the *server* one (`auth_parsec.so`), so on that platform
-- the plugin cannot be installed at all — and because the seed is one script,
-- one failing `INSTALL SONAME` aborted everything after it and left two servers
-- with no users whatsoever.

-- See base.sql: a raw install leaves anonymous ''@'localhost' accounts that
-- shadow every '%' user for localhost connections.
DELETE FROM mysql.global_priv WHERE User = '';
FLUSH PRIVILEGES;

INSTALL SONAME 'auth_ed25519';

CREATE DATABASE IF NOT EXISTS swizzle_test;

CREATE USER 'native'@'%'  IDENTIFIED BY 'nativepass';
CREATE USER 'nopass'@'%'  IDENTIFIED BY '';
CREATE USER 'ed25519'@'%' IDENTIFIED VIA ed25519 USING PASSWORD('ed25519pass');

GRANT ALL PRIVILEGES ON swizzle_test.* TO 'native'@'%';
GRANT ALL PRIVILEGES ON swizzle_test.* TO 'nopass'@'%';
GRANT ALL PRIVILEGES ON swizzle_test.* TO 'ed25519'@'%';

GRANT PROCESS ON *.* TO 'native'@'%';
GRANT SELECT ON performance_schema.* TO 'native'@'%';

-- Replication, for the binlog/CDC tests. BINLOG MONITOR is MariaDB 10.5+'s
-- name for the old REPLICATION CLIENT and is what SHOW BINLOG STATUS needs;
-- REPLICATION SLAVE is what COM_BINLOG_DUMP needs. Both are required — having
-- only one produces an "Access denied" that names the other.
GRANT BINLOG MONITOR, REPLICATION SLAVE ON *.* TO 'native'@'%';

FLUSH PRIVILEGES;

-- Shadow databases for `swizzle generate`.
--
-- Codegen prepares statements against a throwaway database rather than the real
-- one, so the fixture users need rights across the whole `swizzle_shadow_`
-- namespace. `_` is a single-character wildcard in a grant, so it is escaped:
-- an unescaped `swizzle_shadow_%` would match names nobody intended.
GRANT ALL PRIVILEGES ON `swizzle\_shadow\_%`.* TO 'native'@'%';
GRANT ALL PRIVILEGES ON `swizzle\_shadow\_%`.* TO 'nopass'@'%';
GRANT ALL PRIVILEGES ON `swizzle\_shadow\_%`.* TO 'ed25519'@'%';
FLUSH PRIVILEGES;

-- Everything in base.sql plus parsec (PBKDF2-SHA512 + ed25519), MariaDB 11.6+.

-- See base.sql: a raw install leaves anonymous ''@'localhost' accounts that
-- shadow every '%' user for localhost connections.
DELETE FROM mysql.global_priv WHERE User = '';
FLUSH PRIVILEGES;

INSTALL SONAME 'auth_ed25519';
INSTALL SONAME 'auth_parsec';

CREATE DATABASE IF NOT EXISTS swizzle_test;

CREATE USER 'native'@'%'  IDENTIFIED BY 'nativepass';
CREATE USER 'nopass'@'%'  IDENTIFIED BY '';
CREATE USER 'ed25519'@'%' IDENTIFIED VIA ed25519 USING PASSWORD('ed25519pass');
CREATE USER 'parsec'@'%'  IDENTIFIED VIA parsec  USING PASSWORD('parsecpass');

GRANT ALL PRIVILEGES ON swizzle_test.* TO 'native'@'%';
GRANT ALL PRIVILEGES ON swizzle_test.* TO 'nopass'@'%';
GRANT ALL PRIVILEGES ON swizzle_test.* TO 'ed25519'@'%';
GRANT ALL PRIVILEGES ON swizzle_test.* TO 'parsec'@'%';

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
GRANT ALL PRIVILEGES ON `swizzle\_shadow\_%`.* TO 'parsec'@'%';
FLUSH PRIVILEGES;

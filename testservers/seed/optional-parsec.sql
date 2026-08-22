-- PARSEC (PBKDF2-SHA512), MariaDB 11.6+ — and only where the build ships it.
--
-- Applied separately from `parsec.sql` and allowed to fail, because whether it
-- can be installed is a property of the *build* rather than the version. The
-- macOS and aarch64 tarballs carry both `auth_parsec.so` (server) and
-- `parsec.so` (client); the x86_64 Linux tarball carries only the client one.
--
-- Verified by listing the plugin directory of every x86_64 tarball rather than
-- inferred from a version number, after `INSTALL SONAME 'parsec'` failed with
-- "Can't find symbol '_mysql_plugin_interface_version_'" — the giveaway that
-- the file present is a client library, not a server plugin.
--
-- When this does not apply the fixture simply has no `parsec` user, and
-- `TestServers.withParsec` is empty for that server, so the parsec suites skip.
INSTALL SONAME 'auth_parsec';

CREATE USER 'parsec'@'%' IDENTIFIED VIA parsec USING PASSWORD('parsecpass');
GRANT ALL PRIVILEGES ON swizzle_test.* TO 'parsec'@'%';
GRANT ALL PRIVILEGES ON `swizzle\_shadow\_%`.* TO 'parsec'@'%';
FLUSH PRIVILEGES;

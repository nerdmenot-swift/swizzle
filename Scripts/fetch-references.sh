#!/usr/bin/env bash
# Fetch reference client implementations for porting.
#
# These are read-only references, never vendored into the build. They are
# gitignored — run this script to (re)create them.
#
# LICENSE NOTE, read before copying anything:
#   Permissive, safe to read closely while porting:
#     PyMySQL            MIT
#     node-mysql2        MIT
#     rust-mysql-common  MIT OR Apache-2.0
#     mysql_async        MIT OR Apache-2.0
#   Weak copyleft, behaviour cross-checks only, do NOT port code from:
#     go-sql-driver      MPL-2.0  (file-level copyleft)
#   Deliberately absent — strong copyleft, do not clone into this project:
#     MySQL Connector/J, MariaDB Connector/C, MariaDB Connector/J (GPL/LGPL)
#
# SQLite references, both permissive:
#     rusqlite    MIT   — the closest analogue: a typed wrapper over the C API
#     GRDB.swift  MIT   — the Swift one, and therefore the one whose absence a
#                         Swift user will actually notice
#
# Postgres references are uniformly permissive — unlike MySQL, there is no
# MPL/GPL corner of that ecosystem to route around:
#     postgres-protocol / tokio-postgres  MIT OR Apache-2.0
#     jackc/pgx                           MIT
#     asyncpg                             Apache-2.0
#     postgres-nio                        MIT
#     libpq (in postgres/postgres)        PostgreSQL License (BSD-style)

set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p references
cd references

fetch() {
  local repo="$1" dir="$2" license="$3"
  if [[ -d "$dir/.git" ]]; then
    printf "  %-22s already present (%s)\n" "$dir" "$license"
    return
  fi
  printf "  %-22s cloning… " "$dir"
  if git clone --depth 1 -q "https://github.com/$repo.git" "$dir" 2>/dev/null; then
    echo "ok ($license)"
  else
    echo "FAILED"
  fi
}

echo "Fetching MySQL client references into references/"
fetch PyMySQL/PyMySQL            pymysql            "MIT"
fetch sidorares/node-mysql2      node-mysql2        "MIT"
fetch blackbeam/rust_mysql_common rust-mysql-common "MIT OR Apache-2.0"
fetch blackbeam/mysql_async      rust-mysql-async   "MIT OR Apache-2.0"
fetch go-sql-driver/mysql        go-sql-driver-mysql "MPL-2.0 — cross-check only"

echo
echo "Fetching Postgres client references into references/"
fetch sfackler/rust-postgres      rust-postgres      "MIT OR Apache-2.0"
fetch jackc/pgx                   go-pgx             "MIT"
fetch MagicStack/asyncpg          asyncpg            "Apache-2.0"
fetch vapor/postgres-nio          swift-postgres-nio "MIT"
echo
echo "Fetching SQLite client references into references/"
fetch rusqlite/rusqlite         rusqlite           "MIT"
fetch groue/GRDB.swift           grdb               "MIT"
echo
echo "Done. See references/README.md for what each is good for."

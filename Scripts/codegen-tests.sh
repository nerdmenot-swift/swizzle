#!/usr/bin/env bash
# Generated code has to *compile*.
#
# Every other check on the generator asserts something about the text it emits,
# which proves the text is plausible. Only the compiler proves it is Swift — that
# the constructors exist, the optionality lines up, and the columns can actually
# be used in a query. `Scripts/negative-tests.sh` established the pattern of
# driving swiftc out of band; this is the same idea pointed the other way.
set -uo pipefail
cd "$(dirname "$0")/.."

MODULES=.build/debug/Modules
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

echo ""
echo "═══ Generated schema must compile and be usable"

swift build --product swizzle >/dev/null 2>&1 || { echo "  ✗ could not build the CLI"; exit 1; }

mkdir -p "$WORK/migrations"
cat > "$WORK/migrations/00001_init.sql" <<'EOF'
-- +swizzle Up
CREATE TABLE user_accounts (
    id         INTEGER PRIMARY KEY,
    email      VARCHAR(255) NOT NULL,
    nickname   TEXT,
    balance    DECIMAL(10,2) NOT NULL,
    is_active  BOOLEAN NOT NULL DEFAULT 1,
    created_at TIMESTAMP,
    avatar     BLOB,
    class      TEXT,
    api_url    TEXT
);
CREATE TABLE orders (
    id      INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL,
    total   NUMERIC(12,2) NOT NULL
);
-- +swizzle Down
DROP TABLE orders;
DROP TABLE user_accounts;
EOF

./.build/debug/swizzle migrate up \
  --url "sqlite:$WORK/app.db" --dir "$WORK/migrations" >/dev/null 2>&1 \
  || { echo "  ✗ migration failed"; exit 1; }

./.build/debug/swizzle generate schema \
  --url "sqlite:$WORK/app.db" --out "$WORK/Schema.swift" 2>/dev/null \
  || { echo "  ✗ generation failed"; exit 1; }

# Exercises the declarations the way real code would: a join whose predicate only
# type-checks if both sides came out the same width, an optional that must be
# optional, and a keyword column that must have been escaped.
cat > "$WORK/use.swift" <<'EOF'
import SwizzleCore
import SwizzleQuery

func useGeneratedSchema() -> (String, [SQLValue]) {
    let u = UserAccounts()
    let o = Orders(tableAlias: "o")
    return QueryBuilder<SQLite>()
        .select(u.id, u.email, u.nickname, u.balance, u.apiURL)
        .from(u)
        .leftJoin(o, on: o.userID == u.id)
        .where(u.isActive == true && u.`class` == "gold")
        .orderBy(u.createdAt.desc)
        .build()
}
EOF

if output=$(swiftc -typecheck -swift-version 6 -I "$MODULES" \
    "$WORK/Schema.swift" "$WORK/use.swift" 2>&1); then
  echo "  ✓ generated schema compiles and is usable in a query"
  ((pass++))
else
  echo "  ✗ generated schema does not compile"
  echo "$output" | grep "error:" | head -5 | sed 's/^/      /'
  ((fail++))
fi

# Regeneration must be byte-identical, or `--verify` reports drift that is only
# dictionary ordering.
./.build/debug/swizzle generate schema \
  --url "sqlite:$WORK/app.db" --out "$WORK/Schema2.swift" 2>/dev/null
if cmp -s "$WORK/Schema.swift" "$WORK/Schema2.swift"; then
  echo "  ✓ regeneration is byte-identical"
  ((pass++))
else
  echo "  ✗ regeneration differs from the first run"
  ((fail++))
fi

echo ""
echo "═══ Generated queries must compile and be usable"

mkdir -p "$WORK/queries"
cat > "$WORK/queries/users.sql" <<'EOF'
-- +swizzle Query GetUser(id: Int64) :one
SELECT id, email, nickname FROM user_accounts WHERE id = ?;

-- +swizzle Query CountUsers :one
SELECT COUNT(*) AS total FROM user_accounts;

-- +swizzle Query ListActive(max: Int64) :many
SELECT id, email FROM user_accounts WHERE is_active = 1 ORDER BY email LIMIT ?;

-- +swizzle Query StreamAll :stream
SELECT id, email FROM user_accounts;

-- +swizzle NotNull total
-- +swizzle Query OrderTotals(userID: Int64) :many
SELECT u.id, o.total FROM user_accounts u
LEFT JOIN orders o ON o.user_id = u.id WHERE u.id = ?;

-- +swizzle Query Deactivate(id: Int64) :exec
UPDATE user_accounts SET is_active = 0 WHERE id = ?;
EOF

./.build/debug/swizzle generate queries \
  --url "sqlite:$WORK/app.db" -q "$WORK/queries" -d "$WORK/migrations" \
  --out "$WORK/Queries.swift" --lockfile "$WORK/first.lock.json" 2>/dev/null \
  || { echo "  ✗ query generation failed"; exit 1; }

# A stand-in executor, so the generated code is checked on its own terms rather
# than through a driver — and so the check proves `Queries` asks for nothing more
# than an `SQLExecutor` pinned to its dialect.
cat > "$WORK/usequeries.swift" <<'EOF'
import SwizzleCore

struct FakeExecutor: SQLStreamingExecutor {
    typealias Dialect = SQLite
    func execute(sql: String, bindings: [SQLValue]) async throws -> [SQLRow] { [] }
    func executeUpdate(sql: String, bindings: [SQLValue]) async throws -> Int { 0 }
    func stream(sql: String, bindings: [SQLValue]) async throws
        -> AsyncThrowingStream<SQLRow, any Error> { AsyncThrowingStream { $0.finish() } }
}

func useGeneratedQueries() async throws {
    let q = Queries(FakeExecutor())
    let user = try await q.getUser(id: 1)
    _ = user?.nickname                 // optional, because the column is
    _ = user?.email.count              // not optional, because the column is not
    for row in try await q.orderTotals(userID: 1) {
        _ = row.total.count            // NotNull narrowed it
        _ = row.id ?? 0                // the outer join widened this one
    }
    let affected: Int = try await q.deactivate(id: 1)
    _ = affected
    for try await row in try await q.streamAll() { _ = row.email }
}
EOF

if output=$(swiftc -typecheck -swift-version 6 -I "$MODULES" \
    "$WORK/Queries.swift" "$WORK/usequeries.swift" 2>&1); then
  if [[ -n "$output" ]]; then
    # Generated code that warns is generated code people start editing.
    echo "  ✗ generated queries compile but emit diagnostics"
    echo "$output" | grep -E "warning:" | head -3 | sed 's/^/      /'
    ((fail++))
  else
    echo "  ✓ generated queries compile clean and are usable"
    ((pass++))
  fi
else
  echo "  ✗ generated queries do not compile"
  echo "$output" | grep "error:" | head -5 | sed 's/^/      /'
  ((fail++))
fi

./.build/debug/swizzle generate queries \
  --url "sqlite:$WORK/app.db" -q "$WORK/queries" -d "$WORK/migrations" \
  --out "$WORK/Queries2.swift" --lockfile "$WORK/second.lock.json" 2>/dev/null
if cmp -s "$WORK/Queries.swift" "$WORK/Queries2.swift"; then
  echo "  ✓ query regeneration is byte-identical"
  ((pass++))
else
  echo "  ✗ query regeneration differs from the first run"
  ((fail++))
fi

echo ""
echo "═══ The lockfile must let CI verify with no database"

./.build/debug/swizzle generate queries \
  --url "sqlite:$WORK/app.db" -q "$WORK/queries" -d "$WORK/migrations" \
  -o "$WORK/Q.swift" --lockfile "$WORK/swizzle.lock.json" 2>/dev/null \
  || { echo "  ✗ generation with a lockfile failed"; exit 1; }

# The shadow database is the point: generation must never read the database the
# URL names, because that one may have drifted from the migrations.
if [[ ! -f "$WORK/shadowproof.db" ]]; then
  ./.build/debug/swizzle generate queries \
    --url "sqlite:$WORK/shadowproof.db" -q "$WORK/queries" -d "$WORK/migrations" \
    -o "$WORK/Q2.swift" --lockfile "$WORK/l2.json" 2>/dev/null
  if [[ -f "$WORK/shadowproof.db" ]]; then
    echo "  ✗ generation created the database named by --url; it should use a shadow"
    ((fail++))
  else
    echo "  ✓ generation used a shadow, never touching the named database"
    ((pass++))
  fi
fi

verify() {
  ./.build/debug/swizzle generate queries \
    --url "sqlite:/nonexistent/nope.db" -q "$WORK/queries" -d "$WORK/migrations" \
    -o "$WORK/Q.swift" --lockfile "$WORK/swizzle.lock.json" --verify 2>&1
}

# Captured first rather than piped: `verify` exits non-zero by design when the
# tree is stale, and `set -o pipefail` would make the pipeline fail even when the
# grep matched — which is how these checks silently passed nothing.
output=$(verify)
if grep -qE "current" <<<"$output"; then
  echo "  ✓ verify passes with no database at all"
  ((pass++))
else
  echo "  ✗ verify failed on a clean tree"
  verify | head -3 | sed 's/^/      /'
  ((fail++))
fi

# The three ways a tree goes stale.
stale_check() {
  local what="$1" out
  out=$(verify)
  if grep -qE "stale|does not match" <<<"$out"; then
    echo "  ✓ verify catches $what"
    ((pass++))
  else
    echo "  ✗ verify missed $what"
    ((fail++))
  fi
}

cp "$WORK/queries/users.sql" "$WORK/users.bak"
printf '\n-- +swizzle Query Extra :many\nSELECT id FROM user_accounts;\n' >> "$WORK/queries/users.sql"
stale_check "a query added without regenerating"
cp "$WORK/users.bak" "$WORK/queries/users.sql"

printf -- '-- +swizzle Up\nALTER TABLE user_accounts ADD COLUMN city TEXT;\n-- +swizzle Down\nSELECT 1;\n' \
  > "$WORK/migrations/00002_more.sql"
stale_check "a migration added without regenerating"
rm "$WORK/migrations/00002_more.sql"

echo "// edited by hand" >> "$WORK/Q.swift"
stale_check "generated code edited by hand"


echo ""
echo "═══ Postgres: the same pipeline, against a real server"

# Postgres is where the generator has the most to work with — genuinely typed
# parameters, nullability from `pg_attribute`, and types SQLite does not have.
# It also needs a live server, so the whole section is skipped rather than failed
# when one is not running.
PGURL="postgres://swizzle:swizzlepass@127.0.0.1:5432/swizzle_test?sslmode=require"
mkdir -p "$WORK/pg/migrations" "$WORK/pg/queries"
cat > "$WORK/pg/migrations/00001_init.sql" <<'MIGRATION'
-- +swizzle Up
CREATE TABLE pg_users (
    id         bigint PRIMARY KEY,
    email      varchar(255) NOT NULL,
    nickname   text,
    balance    numeric(10,2) NOT NULL,
    is_active  boolean NOT NULL DEFAULT true,
    created_at timestamptz,
    tags       text[]
);
CREATE TABLE pg_orders (
    id      bigint PRIMARY KEY,
    user_id bigint NOT NULL,
    total   numeric(12,2) NOT NULL
);
-- +swizzle Down
DROP TABLE pg_orders;
DROP TABLE pg_users;
MIGRATION

# The section needs a live server; skipped rather than failed without one.
#
# `generate schema` is the probe because it only connects and introspects.
# `migrate status` was the obvious choice and is the wrong one: it also validates
# checksums against the journal, so a fixture carrying an edited migration from
# some earlier run reports failure — and the whole section silently skipped for a
# reason that had nothing to do with whether Postgres was up.
if ! ./.build/debug/swizzle generate schema \
    --url "$PGURL" --out "$WORK/pg/probe.swift" >/dev/null 2>&1; then
  echo "  – skipped (no Postgres on :5432)"
else
  cat > "$WORK/pg/queries/users.sql" <<'EOF'
-- +swizzle Query GetUser(id: Int64) :one
SELECT id, email, nickname, balance, tags FROM pg_users WHERE id = $1;

-- +swizzle Query ListActive(max: Int64) :many
SELECT id, email FROM pg_users WHERE is_active ORDER BY email LIMIT $1;

-- +swizzle Query StreamAll :stream
SELECT id, email FROM pg_users;

-- +swizzle Query OrderTotals(userID: Int64) :many
SELECT u.id, o.total FROM pg_users u
LEFT JOIN pg_orders o ON o.user_id = u.id WHERE u.id = $1;

-- +swizzle Query Deactivate(id: Int64) :exec
UPDATE pg_users SET is_active = false WHERE id = $1;
EOF

  if ./.build/debug/swizzle generate queries \
      --url "$PGURL" -q "$WORK/pg/queries" -d "$WORK/pg/migrations" \
      --out "$WORK/pg/Queries.swift" --lockfile "$WORK/pg/first.lock.json" >/dev/null 2>&1; then
    echo "  ✓ Postgres query generation ran against a shadow database"
    ((pass++))
  else
    echo "  ✗ Postgres query generation failed"
    ((fail++))
  fi

  cat > "$WORK/pg/use.swift" <<'EOF'
import SwizzleCore

struct PGFakeExecutor: SQLStreamingExecutor {
    typealias Dialect = Postgres
    func execute(sql: String, bindings: [SQLValue]) async throws -> [SQLRow] { [] }
    func executeUpdate(sql: String, bindings: [SQLValue]) async throws -> Int { 0 }
    func stream(sql: String, bindings: [SQLValue]) async throws
        -> AsyncThrowingStream<SQLRow, any Error> { AsyncThrowingStream { $0.finish() } }
}

func usePostgresQueries() async throws {
    let q = Queries(PGFakeExecutor())
    let user = try await q.getUser(id: 1)
    _ = user?.email.count        // NOT NULL, so not optional
    _ = user?.nickname           // nullable, so optional
    // `numeric` must be a string: routed through Double it loses the cents.
    let balance: String? = user?.balance
    _ = balance
    for row in try await q.orderTotals(userID: 1) {
        // The outer join widened both sides, including the NOT NULL one.
        _ = row.id ?? 0
        _ = row.total ?? ""
    }
    let affected: Int = try await q.deactivate(id: 1)
    _ = affected
    for try await row in try await q.streamAll() { _ = row.email }
}
EOF

  if output=$(swiftc -typecheck -swift-version 6 -I "$MODULES" \
      "$WORK/pg/Queries.swift" "$WORK/pg/use.swift" 2>&1); then
    if [[ -n "$output" ]]; then
      echo "  ✗ generated Postgres queries compile but emit diagnostics"
      echo "$output" | grep -E "warning:" | head -3 | sed 's/^/      /'
      ((fail++))
    else
      echo "  ✓ generated Postgres queries compile clean, with the right types"
      ((pass++))
    fi
  else
    echo "  ✗ generated Postgres queries do not compile"
    echo "$output" | grep "error:" | head -5 | sed 's/^/      /'
    ((fail++))
  fi

  # The dialect is a compile-time pin: a Postgres query on a MySQL connection has
  # to be a type error, not a syntax error from a server.
  cat > "$WORK/pg/wrongdialect.swift" <<'EOF'
import SwizzleCore

struct MySQLFake: SQLExecutor {
    typealias Dialect = MySQL
    func execute(sql: String, bindings: [SQLValue]) async throws -> [SQLRow] { [] }
    func executeUpdate(sql: String, bindings: [SQLValue]) async throws -> Int { 0 }
}
func misuse() { _ = Queries(MySQLFake()) }
EOF
  if swiftc -typecheck -swift-version 6 -I "$MODULES" \
      "$WORK/pg/Queries.swift" "$WORK/pg/wrongdialect.swift" >/dev/null 2>&1; then
    echo "  ✗ Postgres queries accepted a MySQL executor"
    ((fail++))
  else
    echo "  ✓ a MySQL executor is rejected at compile time"
    ((pass++))
  fi

  ./.build/debug/swizzle generate queries \
    --url "$PGURL" -q "$WORK/pg/queries" -d "$WORK/pg/migrations" \
    --out "$WORK/pg/Queries2.swift" --lockfile "$WORK/pg/second.lock.json" >/dev/null 2>&1
  if cmp -s "$WORK/pg/Queries.swift" "$WORK/pg/Queries2.swift"; then
    echo "  ✓ Postgres regeneration is byte-identical"
    ((pass++))
  else
    echo "  ✗ Postgres regeneration differs from the first run"
    ((fail++))
  fi

  # No database at all, so the lockfile is doing the work.
  pgverify() {
    ./.build/debug/swizzle generate queries \
      --url "postgres://nobody@127.0.0.1:1/none" -q "$WORK/pg/queries" \
      -d "$WORK/pg/migrations" -o "$WORK/pg/Queries.swift" \
      --lockfile "$WORK/pg/first.lock.json" --verify 2>&1
  }
  output=$(pgverify)
  if grep -qE "current" <<<"$output"; then
    echo "  ✓ Postgres verify passes with no database at all"
    ((pass++))
  else
    echo "  ✗ Postgres verify failed on a clean tree"
    echo "$output" | head -3 | sed 's/^/      /'
    ((fail++))
  fi
fi
echo ""
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]

#!/usr/bin/env bash
# Verifies that dialect capability gating produces real COMPILE errors.
#
# The central claim of the design is that `.returning()` on MySQL cannot be
# written, not that it throws at runtime. That claim is only worth anything if
# it's tested — and it can't be tested from inside a compiling test target,
# so we compile snippets out-of-band and assert they fail.

set -uo pipefail
cd "$(dirname "$0")/.."

swift build >/dev/null 2>&1 || { echo "base build failed"; exit 1; }

MODULES=".build/debug/Modules"
[[ -d "$MODULES" ]] || MODULES=".build/debug"

WORK="${TMPDIR:-/tmp}/swizzle-negative"
mkdir -p "$WORK"

pass=0
fail=0

expect_error() {
  local name="$1" expected="$2" body="$3"
  local file="$WORK/${name}.swift"
  { echo "import Swizzle"; echo "$body"; } > "$file"

  local output
  output=$(swiftc -typecheck -swift-version 6 -I "$MODULES" \
    Sources/SwizzleSpike/Schema.swift "$file" 2>&1)

  if [[ $? -eq 0 ]]; then
    echo "  ✗ $name — COMPILED, but should not have"
    ((fail++))
    return
  fi

  if echo "$output" | grep -q "$expected"; then
    echo "  ✓ $name — rejected: $expected"
    ((pass++))
  else
    echo "  ✗ $name — failed, but not for the expected reason"
    echo "$output" | grep "error:" | head -3 | sed 's/^/      /'
    ((fail++))
  fi
}

echo ""
echo "═══ Capability gating must be compile-time"

expect_error "mysql_no_returning" "SupportsReturning" '
func f() { _ = InsertQuery<MySQL, Users>(into: users).returning(users.id) }'

expect_error "mysql_no_distinct_on" "SupportsDistinctOn" '
func f() { _ = my.select(users.id).from(users).distinctOn(users.id) }'

expect_error "postgres_no_on_duplicate_key" "SupportsOnDuplicateKeyUpdate" '
func f() { _ = InsertQuery<Postgres, Users>(into: users).onDuplicateKeyUpdate { _ in } }'

expect_error "postgres_no_insert_ignore" "SupportsInsertIgnore" '
func f() { _ = InsertQuery<Postgres, Users>(into: users).orIgnore() }'

expect_error "mysql_no_full_outer_join" "SupportsFullOuterJoin" '
func f() { _ = my.select(users.id).from(users).fullOuterJoin(posts, on: posts.authorId == users.id) }'

expect_error "postgres_no_update_limit" "SupportsWriteLimit" '
func f() { _ = UpdateQuery<Postgres, Users>(users).set(users.name, to: "x").limit(1) }'

expect_error "postgres_no_delete_limit" "SupportsWriteLimit" '
func f() { _ = DeleteQuery<Postgres, Users>(from: users).limit(1) }'

expect_error "sqlite_no_row_locking" "SupportsRowLocking" '
func f() { _ = lite.select(users.id).from(users).forUpdate() }'

expect_error "mysql_no_weak_locking" "SupportsWeakRowLocking" '
func f() { _ = my.select(users.id).from(users).forKeyShare() }'

echo ""
echo "═══ Upsert sub-expressions belong to their own engine"

# EXCLUDED and VALUES() mean the same thing and are spelled differently, so each
# is gated by the same capability as the clause that contains it. Reaching for
# the other engine'"'"'s spelling has to fail here rather than at the server.
expect_error "mysql_no_excluded" "SupportsOnConflict" '
func f() {
  _ = InsertQuery<MySQL, Users>(into: users)
      .onDuplicateKeyUpdate { $0.set(users.name, to: $0.excluded(users.name)) }
}'

expect_error "postgres_no_values_function" "SupportsOnDuplicateKeyUpdate" '
func f() {
  _ = InsertQuery<Postgres, Users>(into: users)
      .onConflict(users.email).doUpdate { $0.set(users.name, to: $0.values(users.name)) }
}'

echo ""
echo "═══ SQLite lacks things, and the gates have to know"

expect_error "sqlite_no_on_duplicate_key" "SupportsOnDuplicateKeyUpdate" '
func f() { _ = InsertQuery<SQLite, Users>(into: users).onDuplicateKeyUpdate { _ in } }'

expect_error "sqlite_no_distinct_on" "SupportsDistinctOn" '
func f() { _ = lite.select(users.id).from(users).distinctOn(users.id) }'

expect_error "sqlite_no_write_limit" "SupportsWriteLimit" '
func f() { _ = DeleteQuery<SQLite, Users>(from: users).limit(1) }'

echo ""
echo "═══ Column types must be enforced"

expect_error "wrong_literal_type" "error:" '
func f() { _ = pg.select(users.id).from(users).where(users.age == "not a number") }'

expect_error "mismatched_column_comparison" "error:" '
func f() { _ = pg.select(users.id).from(users).where(users.name == users.age) }'

expect_error "wrong_decoded_tuple" "error:" '
func f() throws { let _: (String, String) = try pg.select(users.id, users.name).from(users).decode(SQLRow(values: [])) }'

echo ""
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]

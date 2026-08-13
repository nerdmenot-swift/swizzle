#!/usr/bin/env bash
# Scale spike: how does type-check cost grow with query count in one module?
#
# A single 5ms query is meaningless on its own — real apps have hundreds. This
# generates N realistic 4-table aggregate queries in both the tuned and naive
# styles and type-checks each file, so we can see whether cost is linear
# (fine) or superlinear (fatal).
#
# ## No Python
#
# This used `python3` for two things, and needed neither. Timing is bash's own
# `time` builtin with `TIMEFORMAT='%R'`, which gives three decimal places of
# seconds on the system bash 3.2 — no `$EPOCHREALTIME` (bash 5) and no external
# clock. Float arithmetic is `awk`, which is POSIX and present everywhere. The
# code generation is a shell loop; it was only ever string concatenation.

set -uo pipefail
cd "$(dirname "$0")/.."

N="${1:-200}"
OUT="${TMPDIR:-/tmp}/swizzle-scale"
mkdir -p "$OUT"

swift build >/dev/null 2>&1 || { echo "base build failed"; exit 1; }

# ── Generation ───────────────────────────────────────────────────────────────
#
# Unquoted heredocs, so `$(( ))` arithmetic expands. The generated Swift
# deliberately contains no `$` or backticks of its own, which is what makes that
# safe — check that before adding to these bodies.

{
  echo "import Swizzle"
  for ((i = 0; i < N; i++)); do
    cat <<EOF

func genTuned$i() -> (sql: String, bindings: [SQLValue]) {
    pg.select(users.id, users.name, countDistinct(posts.id), avg(posts.score), max(comments.createdAt))
        .from(users)
        .innerJoin(posts, on: posts.authorId == users.id)
        .leftJoin(comments, on: comments.postId == posts.id)
        .leftJoin(postTags, on: postTags.postId == posts.id)
        .where(
            users.isActive == true
                && posts.isPublished == true
                && (comments.isDeleted == false || comments.isDeleted.isNull)
                && users.countryCode.in(["US", "GB"])
                && users.age > $((20 + i % 40))
                && posts.viewCount < $((1000 + i))
        )
        .groupBy(users.id, users.name)
        .having(countDistinct(posts.id) > $((i % 10)) && avg(posts.score) > 3.5)
        .orderBy(users.name.asc, users.id.desc)
        .limit($((10 + i % 90)))
        .build()
}
EOF
  done
} > "$OUT/GeneratedTuned.swift"

{
  echo "import SwizzleCore"
  for ((i = 0; i < N; i++)); do
    cat <<EOF

func genNaive$i() -> (sql: String, bindings: [SQLValue]) {
    nSelect(
        Postgres.self,
        nusers.id, nusers.name, nCountDistinct(nposts.id), nAvg(nposts.score), nMax(ncomments.createdAt)
    )
    .from(nusers)
    .innerJoin(nposts, on: nposts.authorId == nusers.id)
    .leftJoin(ncomments, on: ncomments.postId == nposts.id)
    .leftJoin(npostTags, on: npostTags.postId == nposts.id)
    .where(
        nusers.isActive == true
            && nposts.isPublished == true
            && (ncomments.isDeleted == false || ncomments.isDeleted.nIsNull)
            && nusers.countryCode.nIn(["US", "GB"])
            && nusers.age > $((20 + i % 40))
            && nposts.viewCount < $((1000 + i))
    )
    .groupBy(nusers.id, nusers.name)
    .having(nCountDistinct(nposts.id) > $((i % 10)) && nAvg(nposts.score) > 3.5)
    .orderBy(nusers.name.nAsc, nusers.id.nDesc)
    .limit($((10 + i % 90)))
    .build()
}
EOF
  done
} > "$OUT/GeneratedNaive.swift"

echo "generated $N queries per style in $OUT"

# ── Timing ───────────────────────────────────────────────────────────────────

MODULES=".build/debug/Modules"
[[ -d "$MODULES" ]] || MODULES=".build/debug"

time_typecheck() {
  local label="$1"; shift
  local log="$OUT/$label.log"

  # The command's own output goes to a file so that what `time` writes to the
  # subshell's stderr is the only thing captured here.
  local elapsed status
  TIMEFORMAT='%R'
  elapsed=$( { time swiftc -typecheck -swift-version 6 -I "$MODULES" "$@" >"$log" 2>&1; } 2>&1 )
  status=$?

  if [[ $status -ne 0 ]]; then
    echo "  $label: FAILED"
    grep -E "error:" "$log" | head -5
    return
  fi

  awk -v label="$label" -v elapsed="$elapsed" -v n="$N" 'BEGIN {
    printf "  %s: %.2fs total  |  %.1fms per query\n", label, elapsed, elapsed * 1000 / n
  }'
}

echo ""
echo "═══ Scale: $N queries in a single module"
time_typecheck "tuned" Sources/SwizzleSpike/Schema.swift "$OUT/GeneratedTuned.swift"
time_typecheck "naive" Sources/SwizzleNaiveSpike/Naive.swift Sources/SwizzleNaiveSpike/NaiveSchema.swift "$OUT/GeneratedNaive.swift"
echo ""

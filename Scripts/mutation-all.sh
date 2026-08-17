#!/usr/bin/env bash
#
# The whole sweep, target by target, cheapest first.
#
# Ordered so the fast targets report before the slow ones start: `SwizzleCore`
# is 41 sites and `SwizzleMySQL` is 444, and there is no reason to wait six hours
# to learn something the first twenty minutes would have said.
#
# Targets with a unit-test filter use it — a mutant only has to be shown to the
# tests that could plausibly catch it, and running 1421 tests to check a change
# in the SQL renderer wastes twenty seconds per mutant. The drivers get the whole
# suite, because their coverage *is* the integration suites.
#
# Expect this to take hours. That is the point: it is the only measurement that
# answers "would a bug have been caught" rather than "did a test fail".
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/mutation-report.txt}"
: > "$OUT"

# target<TAB>filter — an empty filter means the full suite.
TARGETS=(
  "Sources/SwizzleCore	"
  "Sources/SwizzleGenerate	SwizzleGenerateTests"
  "Sources/SwizzleSQLite	SwizzleSQLiteTests"
  "Sources/SwizzleQuery	"
  "Sources/SwizzleMigrate	SwizzleMigrateTests"
  "Sources/SwizzlePostgresDriver	"
  "Sources/SwizzleMySQL	"
)

started=$(date +%s)
for entry in "${TARGETS[@]}"; do
  target="${entry%%	*}"
  filter="${entry##*	}"
  echo "════ $target ════" | tee -a "$OUT"
  "$ROOT/Scripts/mutation-sweep.sh" "$target" "$filter" 2>&1 | tee -a "$OUT"
  echo | tee -a "$OUT"
done

echo "swept in $(( ($(date +%s) - started) / 60 )) minutes" | tee -a "$OUT"
echo
echo "Report: $OUT"

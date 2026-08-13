#!/usr/bin/env bash
# Type-checker spike harness.
#
# Reports per-function and per-expression type-check cost for the tuned builder
# (SwizzleSpike) and the deliberately naive control (SwizzleNaiveSpike).
#
# The number that matters is the *worst single function body*. Anything over
# ~500ms means a real query in a real app makes the editor feel broken; anything
# that fails to converge means the design is dead.
#
# Timing is bash's own `time` builtin with `TIMEFORMAT='%R'` — three decimals of
# seconds on the system bash 3.2, no external clock and no `python3`. `awk` does
# the millisecond conversion and the comparison, floats being beyond the shell's
# arithmetic.

set -uo pipefail
cd "$(dirname "$0")/.."

THRESHOLD="${1:-1}"   # ms; report anything slower
RUNS="${2:-3}"

bench_target() {
  local target="$1"
  local best_total=""
  local warnings=""

  local log="${TMPDIR:-/tmp}/swizzle-typecheck-$target.log"

  for _ in $(seq 1 "$RUNS"); do
    swift package clean >/dev/null 2>&1

    # The build's own output goes to a file, so the only thing captured from the
    # subshell's stderr is what `time` wrote there.
    local elapsed
    TIMEFORMAT='%R'
    elapsed=$( { time swift build --target "$target" \
      -Xswiftc -Xfrontend -Xswiftc "-warn-long-function-bodies=${THRESHOLD}" \
      -Xswiftc -Xfrontend -Xswiftc "-warn-long-expression-type-checking=${THRESHOLD}" \
      >"$log" 2>&1; } 2>&1 )
    warnings=$(cat "$log")

    # Seconds to whole milliseconds, and the best-of comparison — both in awk,
    # since the shell cannot compare `1.234` to `0.987`.
    local milliseconds
    milliseconds=$(awk -v e="$elapsed" 'BEGIN { printf "%.0f", e * 1000 }')
    if [[ -z "$best_total" ]] || (( milliseconds < best_total )); then
      best_total="$milliseconds"
    fi
  done

  echo ""
  echo "═══ $target"
  echo "    best clean build ($RUNS run$([[ $RUNS -eq 1 ]] || echo s)): ${best_total}ms"
  echo ""

  local rows
  rows=$(echo "$warnings" \
    | grep -oE "(function|method|initializer|expression|getter|setter)[^:]*took [0-9]+ms to type-check" \
    | sed -E 's/ to type-check$//' \
    | sort -t' ' -k2 -rn -u)

  # Extract "<ms>  <what>" sorted descending.
  echo "$warnings" \
    | grep -oE "warning: (.*)took [0-9]+ms to type-check" \
    | sed -E 's/^warning: //; s/took ([0-9]+)ms to type-check/\1/' \
    | awk '{ ms=$NF; $NF=""; printf "%8s ms  %s\n", ms, $0 }' \
    | sort -rn \
    | head -25

  if [[ -z "$rows" ]]; then
    echo "    (nothing exceeded ${THRESHOLD}ms — every construct type-checks below the reporting floor)"
  fi
}

echo "Swizzle type-checker spike — threshold ${THRESHOLD}ms, best of ${RUNS} runs"
bench_target SwizzleSpike
bench_target SwizzleNaiveSpike
echo ""

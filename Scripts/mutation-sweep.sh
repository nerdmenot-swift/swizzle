#!/usr/bin/env bash
#
# Mutation testing: break the code on purpose, and see whether the suite notices.
#
# ## Why this exists
#
# Every silent-failure bug this project has had was invisible to a green suite,
# and greenness was the reason nobody looked:
#
#   - `BinlogTests.collect` capped a stream at 500 events and returned what it
#     had. Three suites asserted over half their data for months.
#   - The query emitter's `:stream` return type did not compile, and its test
#     compared the emitter's output to a string — a test that the emitter agrees
#     with itself.
#   - A splitter test read `sql.contains("SELECT 1")` while the value under test
#     was the statement *plus four lines of prose*.
#   - **This script**, which bounded each mutant at a fixed 180 seconds covering
#     build *and* test. As the suite grew, a healthy run crossed the bound and
#     was killed at it — tallied as a hang, which counts as a kill. The score
#     rose because the suite got slower. It reported 90.3% when 187 of its 408
#     kills were unverified, and gave itself away by listing hangs in value
#     types with no loop in them. The bound is derived from a measured baseline
#     now; a tool that grades other code has to be gradeable itself.
#
# A passing suite says "no test failed". It does not say "a bug would have been
# caught", and those are different claims. This measures the second one: change
# a comparison, a boundary, a constant — if every test still passes, nothing was
# checking that line.
#
# ## Reading the output
#
# A **survivor** is a mutant the suite did not catch. Each one is a specific,
# located gap: this line can be wrong and nobody will know. Not every survivor
# is worth a test — some lines genuinely do not affect behaviour — but every
# survivor is a question worth answering, and the answer belongs in a comment if
# it is not a test.
#
# Usage:
#   Scripts/mutation-sweep.sh <path-under-Sources> [test-filter]
#   Scripts/mutation-sweep.sh Sources/SwizzleCore
#   Scripts/mutation-sweep.sh Sources/SwizzleGenerate SwizzleGenerateTests
#
set -uo pipefail

TARGET="${1:?usage: mutation-sweep.sh <path-under-Sources> [test-filter]}"
FILTER="${2:-}"

# **Never mutate the working tree.** The first version of this edited files in
# place and restored them after each mutant, which is fine right up until it is
# not: a `sed` delimiter collided with a `"""` literal, the substitution blanked
# `var out = """` instead of replacing an operator, and the damage landed in a
# tree holding uncommitted work. A tool whose whole job is breaking code must
# break a copy.
#
# `git worktree` rather than `cp -r`: it gives a clean checkout of HEAD with no
# `.build` to copy, and removing it cannot touch the original.
# **The fixtures are shared, so nothing else may run tests while this does.**
#
# The arena is a private checkout, but it talks to the *same* database servers as
# everything else — the `.testservers` symlink below is what makes the
# integration suites reachable at all. Two suites against one server fight over
# fixed-name tables and fail with 1050 "table already exists" and 1146 "table
# doesn't exist".
#
# That is not hypothetical: running `swift test` during a sweep produced 44
# failures that looked exactly like a broken commit, and the tree was fine. If
# you need to run the suite, pause the sweep first —
#
#     pkill -STOP -f mutation-sweep   # …run tests…
#     pkill -CONT -f mutation-sweep
#
# Separate servers per sweep would fix it properly and cost a second full set of
# fixtures; the pause is cheaper and this is not a thing anyone does often.

# The arena is **per target**, so two sweeps can run at once.
#
# It was one shared path, so starting a MySQL sweep while a Postgres one was
# still going failed with "fatal: … already exists" from `git worktree add` —
# and the failure came *after* `rm -rf "$ARENA"` had already deleted the running
# sweep's checkout out from under it. One tool, two invocations, and the second
# quietly destroys the first.
#
# The target path is turned into a name rather than hashed, so the directory says
# which sweep owns it when something goes wrong at three in the morning.
SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="${TMPDIR:-/tmp}"
SLUG="$(echo "$TARGET" | tr '/' '-' | tr -cd 'A-Za-z0-9-')"
WORK="${TMPROOT%/}/swizzle-mutation-$SLUG"
ARENA="$WORK/tree"
rm -rf "$ARENA"
mkdir -p "$WORK"

if [[ -n "$(git -C "$SOURCE_ROOT" status --porcelain)" ]]; then
  echo "The working tree has uncommitted changes." >&2
  echo "This sweep runs against a clean checkout of HEAD, so those changes" >&2
  echo "would not be tested. Commit or stash them first." >&2
  exit 1
fi

# A killed run never reaches its cleanup trap, so git keeps the worktree
# registered even though `rm -rf` above has taken the directory away. Every
# later run then fails to create it — the tool could not recover from its own
# interruption, which for something that runs for hours is not a detail.
git -C "$SOURCE_ROOT" worktree prune >/dev/null 2>&1 || true

if ! git -C "$SOURCE_ROOT" worktree add --detach "$ARENA" HEAD 2>"$WORK/worktree.err"; then
  echo "could not create a scratch worktree at $ARENA:" >&2
  # The reason, not just the fact. The first version swallowed git's message
  # into /dev/null and reported seven identical failures with no cause.
  sed 's/^/  /' "$WORK/worktree.err" >&2
  exit 1
fi
# The fixtures live outside the checkout and the tests find them relative to
# `#filePath`, which inside a worktree points at the worktree. Without this the
# four TLS suites cannot read `server.crt` and the baseline is red before a
# single mutation is applied — the sweep refuses to start and says only "baseline
# is RED", which is true and useless.
#
# A symlink rather than a copy: `.testservers` holds running servers' data
# directories, and duplicating those would mean two servers' worth of state and
# a second set of certificates, which is the variance this whole day was spent
# removing.
if [[ -d "$SOURCE_ROOT/.testservers" ]]; then
  ln -sfn "$SOURCE_ROOT/.testservers" "$ARENA/.testservers"
fi

cleanup() {
  cd "$SOURCE_ROOT" || return
  # The symlink first: `git worktree remove` refuses to touch a tree holding
  # anything it does not know about.
  rm -f "$ARENA/.testservers"
  git -C "$SOURCE_ROOT" worktree remove --force "$ARENA" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
# Normalised from the filesystem rather than from the string that built it,
# so the guard below compares like with like no matter what $TMPDIR looked
# like — a symlinked or doubly-slashed temp directory included.
ARENA="$(cd "$ARENA" && pwd)"
cd "$ARENA" || exit 1

REPORT="$WORK/survivors.txt"
: > "$REPORT"

# Where a mutation may be applied is decided by `mutation-sites.awk`, which masks
# string literals and comments first. The first version of this used `sed` over
# raw lines and 178 of its 184 survivors were operators inside strings, comments
# and the emitter's own code templates — a report that is 97% noise is read once
# and never again.
SITES="$(dirname "${BASH_SOURCE[0]}")/mutation-sites.awk"
[[ -f "$SITES" ]] || SITES="$SOURCE_ROOT/Scripts/mutation-sites.awk"

total=0; survived=0; killed=0; uncompilable=0; hung=0

echo "Mutation sweep over $TARGET"
echo "  the fixtures are shared — do not run the suite while this runs" >&2
[[ -n "$FILTER" ]] && echo "  test filter: $FILTER"
echo

run_suite() {
  if [[ -n "$FILTER" ]]; then swift test --filter "$FILTER" 2>&1
  else swift test 2>&1; fi
}

# A mutant can **hang** rather than fail, and without a bound one of them stops
# the entire sweep.
#
# Found the hard way: inverting `guard code == SQLITE_ROW` in the SQLite driver
# turns row-stepping into an infinite loop. The suite never returned, and a run
# of 1078 mutants sat on that one mutant for 23 minutes before anybody looked.
# Any of the remaining thousand could do the same.
#
# A timeout counts as **killed** — the suite did not pass, which is the only
# question being asked — but it is tallied separately, because "this line is
# checked" and "changing this line hangs the process" are different facts, and
# the second is worth knowing on its own.
#
# macOS ships no `timeout`, so this polls. The kill is by arena path rather than
# by process name: `pkill -f swiftpm-testing-helper` would take out a test run
# the user happened to start in another window.
MUTATION_TIMEOUT_SET="${MUTATION_TIMEOUT:-}"
MUTATION_TIMEOUT="${MUTATION_TIMEOUT:-180}"

run_suite_bounded() {
  run_suite >/dev/null 2>&1 &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null && (( waited < MUTATION_TIMEOUT )); do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
    pkill -9 -f "$ARENA" 2>/dev/null
    wait "$pid" 2>/dev/null
    return 124
  fi
  wait "$pid"
}

# The bound is **derived from a measured baseline**, not a constant.
#
# It was a constant, 180 seconds, and that quietly stopped meaning what it said.
# The bound covers build *and* test, and as the suite grew a healthy mutant run
# crossed it — so a run that would have failed honestly was killed at the bound
# and tallied as a hang, which counts as a kill. The score went up because the
# suite got slower.
#
# It showed as 187 "hangs" in 456 mutants, spread across `MySQLConnectionURL`,
# `MySQLSessionTimeZone` and `StatementCache` — value types with no loop in
# them. Code that cannot hang appearing in a hang tally is what gave it away.
#
# Measuring the baseline is what keeps this honest as the suite grows, and it
# costs nothing: the green check below has to run anyway.
echo "Checking the suite is green before mutating…"
baseline_start=$SECONDS
run_suite >/dev/null 2>&1 || { echo "baseline is RED — fix that first" >&2; exit 1; }
baseline_elapsed=$((SECONDS - baseline_start))
echo "  green in ${baseline_elapsed}s."

# Three times the baseline, floored at the old constant. A genuine hang runs
# forever, so any generous multiple separates it from a slow build; the point is
# only that the bound tracks the suite rather than a number someone typed once.
if [[ -z "${MUTATION_TIMEOUT_SET:-}" ]]; then
  derived=$((baseline_elapsed * 3))
  (( derived > MUTATION_TIMEOUT )) && MUTATION_TIMEOUT=$derived
fi
echo "  bounding each mutant at ${MUTATION_TIMEOUT}s."
echo

# Refuse to write outside the arena, checked per file rather than assumed once.
#
# A mutant leaked into the real working tree once. The isolation was already
# here — worktree, relative paths, cd into the arena — and something still got
# past it, which is the point: an invariant that is merely arranged for is not
# an invariant. This asserts it at the moment of writing, where being wrong is
# cheap to detect and expensive to miss.
for file in $(find "$TARGET" -name "*.swift" | sort); do
  resolved="$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"
  case "$resolved" in
    "$ARENA"/*) ;;
    *) echo "refusing to mutate $resolved — outside $ARENA" >&2; exit 1 ;;
  esac
  cp "$file" "$WORK/backup.swift"

  while IFS=$'\t' read -r line column width replacement label; do
    [[ -z "${line:-}" ]] && continue
    total=$((total + 1))

    # Splice the replacement in at the exact column. awk throughout: the
    # replacement is data, so no delimiter in the line can be mistaken for
    # syntax — which is what blanked `var out = """` the first time round.
    awk -v n="$line" -v c="$column" -v w="$width" -v r="$replacement" \
      'NR == n { print substr($0, 1, c - 1) r substr($0, c + w); next } { print }' \
      "$WORK/backup.swift" > "$file"

    # Build and test are separated deliberately. Grepping the combined output
    # for "error:" counted a *failing test* whose message contained the word as
    # an uncompilable mutant — inflating the one number that means "learned
    # nothing" and deflating the one that means "a test caught it".
    if ! swift build --build-tests >/dev/null 2>&1; then
      uncompilable=$((uncompilable + 1))
    else
      run_suite_bounded
      outcome=$?
      if [[ $outcome -eq 0 ]]; then
        survived=$((survived + 1))
        original=$(awk -v n="$line" 'NR == n { print; exit }' "$WORK/backup.swift")
        printf 'SURVIVED %s:%s  [%s]\n    %s\n' \
          "$file" "$line" "$label" "$(echo "$original" | sed 's/^ *//')" >> "$REPORT"
        printf '  \033[31mSURVIVED\033[0m %s:%s [%s]\n' "$file" "$line" "$label"
      else
        killed=$((killed + 1))
        if [[ $outcome -eq 124 ]]; then
          hung=$((hung + 1))
          printf 'HUNG %s:%s  [%s]\n    %s\n' \
            "$file" "$line" "$label" \
            "$(awk -v n="$line" 'NR == n { print; exit }' "$WORK/backup.swift" | sed 's/^ *//')" \
            >> "$REPORT"
        fi
      fi
    fi

    cp "$WORK/backup.swift" "$file"
  done < <(awk -f "$SITES" "$WORK/backup.swift")

  cp "$WORK/backup.swift" "$file"
done

echo
echo "  mutants:      $total"
echo "  killed:       $killed"
echo "  survived:     $survived"
echo "  uncompilable: $uncompilable"
[[ $hung -gt 0 ]] && echo "  (of the killed, $hung hung rather than failed)"
if [[ $((killed + survived)) -gt 0 ]]; then
  echo "  score:        $(awk -v k="$killed" -v s="$survived" 'BEGIN{printf "%.1f%%", 100*k/(k+s)}')"
fi
echo
[[ $survived -gt 0 ]] && echo "Survivors listed in $REPORT"
exit 0

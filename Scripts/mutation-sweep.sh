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
SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${TMPDIR:-/tmp}/swizzle-mutation"
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
cleanup() {
  cd "$SOURCE_ROOT" || return
  git -C "$SOURCE_ROOT" worktree remove --force "$ARENA" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
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

total=0; survived=0; killed=0; uncompilable=0

echo "Mutation sweep over $TARGET"
[[ -n "$FILTER" ]] && echo "  test filter: $FILTER"
echo

run_suite() {
  if [[ -n "$FILTER" ]]; then swift test --filter "$FILTER" 2>&1
  else swift test 2>&1; fi
}

echo "Checking the suite is green before mutating…"
run_suite >/dev/null 2>&1 || { echo "baseline is RED — fix that first" >&2; exit 1; }
echo "  green."
echo

for file in $(find "$TARGET" -name "*.swift" | sort); do
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
    elif run_suite >/dev/null 2>&1; then
      survived=$((survived + 1))
      original=$(awk -v n="$line" 'NR == n { print; exit }' "$WORK/backup.swift")
      printf 'SURVIVED %s:%s  [%s]\n    %s\n' \
        "$file" "$line" "$label" "$(echo "$original" | sed 's/^ *//')" >> "$REPORT"
      printf '  \033[31mSURVIVED\033[0m %s:%s [%s]\n' "$file" "$line" "$label"
    else
      killed=$((killed + 1))
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
if [[ $((killed + survived)) -gt 0 ]]; then
  echo "  score:        $(awk -v k="$killed" -v s="$survived" 'BEGIN{printf "%.1f%%", 100*k/(k+s)}')"
fi
echo
[[ $survived -gt 0 ]] && echo "Survivors listed in $REPORT"
exit 0

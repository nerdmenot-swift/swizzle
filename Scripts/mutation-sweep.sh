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

git -C "$SOURCE_ROOT" worktree add --detach "$ARENA" HEAD >/dev/null 2>&1 || {
  echo "could not create a scratch worktree at $ARENA" >&2; exit 1
}
cleanup() {
  cd "$SOURCE_ROOT" || return
  git -C "$SOURCE_ROOT" worktree remove --force "$ARENA" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
cd "$ARENA" || exit 1

REPORT="$WORK/survivors.txt"
: > "$REPORT"

# The mutations. Each is `sed-expression|description`.
#
# Chosen to stay *compilable* — a mutant that does not build teaches nothing and
# costs a full build to discover. Boundary and comparison flips are where real
# off-by-one and wrong-operator bugs live, and they always type-check.
MUTATIONS=(
  's/ >= / > /|>= becomes >'
  's/ <= / < /|<= becomes <'
  's/ > / >= /|> becomes >='
  's/ < / <= /|< becomes <='
  's/ == / != /|== becomes !='
  's/ != / == /|!= becomes =='
  's/ && / || /|&& becomes ||'
  's/ || / \&\& /|log-or becomes and'
)

files=$(find "$TARGET" -name "*.swift" | sort)
total=0
survived=0
killed=0
uncompilable=0

echo "Mutation sweep over $TARGET"
[[ -n "$FILTER" ]] && echo "  test filter: $FILTER"
echo

# A baseline run, because a suite that is already red makes every mutant look
# killed and the whole exercise reports a comforting lie.
echo "Checking the suite is green before mutating…"
if [[ -n "$FILTER" ]]; then
  swift test --filter "$FILTER" >/dev/null 2>&1 || { echo "baseline is RED — fix that first" >&2; exit 1; }
else
  swift test >/dev/null 2>&1 || { echo "baseline is RED — fix that first" >&2; exit 1; }
fi
echo "  green."
echo

for file in $files; do
  # Line numbers holding code rather than comments. Mutating a comment is a
  # guaranteed survivor and pure noise.
  candidates=$(grep -n "" "$file" | grep -vE ":\s*(//|///|\*)" | cut -d: -f1)

  for mutation in "${MUTATIONS[@]}"; do
    expression="${mutation%%|*}"
    description="${mutation##*|}"

    for line in $candidates; do
      original=$(sed -n "${line}p" "$file")
      mutated=$(printf '%s' "$original" | sed "$expression")
      [[ "$mutated" == "$original" ]] && continue

      total=$((total + 1))
      cp "$file" "$WORK/backup.swift"

      # Rewritten with awk rather than `sed -i`, because the substitution has to
      # survive whatever the line contains — and Swift lines contain `|`, `&`,
      # `/`, `\` and `"""`. A `sed` s-command treats several of those as syntax,
      # which is how the first version blanked `var out = """` instead of
      # mutating an operator. awk takes the replacement as *data*: no delimiter,
      # no escape rules, nothing in the line to get wrong.
      awk -v n="$line" -v replacement="$mutated" \
        'NR == n { print replacement; next } { print }' \
        "$WORK/backup.swift" > "$file"

      if [[ -n "$FILTER" ]]; then
        output=$(swift test --filter "$FILTER" 2>&1)
      else
        output=$(swift test 2>&1)
      fi
      status=$?

      if echo "$output" | grep -q "error:"; then
        uncompilable=$((uncompilable + 1))
      elif [[ $status -eq 0 ]]; then
        survived=$((survived + 1))
        printf 'SURVIVED %s:%s  [%s]\n    %s\n' \
          "$file" "$line" "$description" "$(echo "$original" | sed 's/^ *//')" >> "$REPORT"
        printf '  \033[31mSURVIVED\033[0m %s:%s [%s]\n' "$file" "$line" "$description"
      else
        killed=$((killed + 1))
      fi

      cp "$WORK/backup.swift" "$file"
    done
  done
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

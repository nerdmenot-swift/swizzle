#!/usr/bin/env bash
# Properties of the *test suite* that nothing else checks.
#
# Both of these exist because a real defect got through, and neither is
# expressible as a test: they are statements about the test files themselves.

set -uo pipefail
cd "$(dirname "$0")/.."

pass=0
fail=0

report_pass() { echo "  ✓ $1"; ((pass++)); }
report_fail() { echo "  ✗ $1"; ((fail++)); }

echo ""
echo "═══ Every suite that needs a server must skip without one"
echo ""
# A suite that connects to a fixture and carries no `.enabled(if:)` does not
# skip on a machine with no servers — it opens a connection per test and waits
# out the acquisition timeout. The first Linux run produced 172 failures in 124
# seconds this way, none of which said anything about Linux, and a contributor
# who had not run `./Scripts/test-servers.sh up` saw exactly the same.
#
# The scan tracks paren depth from `@Suite(` to its matching close, because the
# declaration spans lines and the gate is usually on a later one. A plain grep
# for `enabled(if:` also misses the wrapped form, where `enabled(` and `if:`
# land on separate lines — which is how the first attempt at this produced a
# page of false positives.
ungated=""
for file in Tests/SwizzlePostgresTests/*.swift Tests/SwizzleMySQLIntegrationTests/*.swift; do
  [[ -f "$file" ]] || continue
  # Only files that actually reach a server.
  grep -qE "swizzlepass|TestServers\.(host|mysql|all|latest)|PostgresTestServer" "$file" || continue

  # The scan is per *suite*, but "does this reach a server" is judged per
  # *file* — which is too coarse: a file can hold both an integration suite and
  # a pure-parsing one. Rather than guess at a suite's body, the author says so
  # with `// test-hygiene: no server` immediately above the declaration. An
  # explicit claim in the source beats an allowlist in this script, and it is
  # visible to whoever next edits the suite.
  found=$(awk -v file="$file" '
    /test-hygiene: no server/ { exempt = 1; next }
    /^@Suite\(/ {
      in_suite = 1; depth = 0; gated = exempt; start = FNR; first = $0; exempt = 0
    }
    in_suite {
      opens = gsub(/\(/, "(");  depth += opens
      closes = gsub(/\)/, ")"); depth -= closes
      if ($0 ~ /enabled\(/) gated = 1
      if (depth <= 0) {
        if (!gated) printf "%s:%d  %s\n", file, start, first
        in_suite = 0
      }
    }
    # A blank line or code between the marker and the declaration clears it, so
    # the exemption cannot drift onto a suite it was not written for.
    !/^@Suite\(/ && !/^\/\// && NF { if (!in_suite) exempt = 0 }
  ' "$file")
  [[ -n "$found" ]] && ungated+="$found"$'\n'
done

if [[ -z "${ungated//[$'\n' ]/}" ]]; then
  report_pass "every server-touching suite carries an availability gate"
else
  report_fail "these suites reach a server with no .enabled(if:) — they fail rather than skip:"
  echo "$ungated" | sed '/^$/d; s/^/      /'
fi

echo ""
echo "═══ No Python in project scripts"
echo ""
# Shell or Swift. `TIMEFORMAT='%R'` covers the sub-second clock python was
# reached for; awk covers the float arithmetic the shell cannot do.
python_uses=$(
  grep -rn "python3" Scripts/*.sh \
    | grep -v "^Scripts/test-hygiene.sh:" \
    | grep -vE ":[0-9]+:\s*#" || true
)
if [[ -z "$python_uses" ]]; then
  report_pass "no script shells out to python"
else
  report_fail "python found in project scripts:"
  echo "$python_uses" | sed 's/^/      /'
fi

echo ""
echo "  $pass passed, $fail failed"
echo ""
[[ $fail -eq 0 ]]

#!/usr/bin/env bash
#
# Times the `mariadb` command-line client on the same query the Swift benchmark
# runs, so the two numbers can be compared honestly.
#
# The comparison is easy to get wrong. The CLI's wall clock includes fork/exec,
# connecting, authenticating and formatting every row back into text; a library
# call does none of the first three and does something different with the last.
# So this measures the fixed overhead separately and subtracts it, and reports
# the CLI's fastest mode (-B --quick) alongside the default one a person types.
#
# Usage:
#   ./Scripts/test-servers.sh up
#   ./Scripts/cli-comparison.sh
#   SWIZZLE_BENCH=1 swift test -c release --filter CLIComparison
#
set -euo pipefail

ROOT="$PWD/.testservers"
CLI="$ROOT/dist/mariadb-12.2.2/bin/mariadb"
ROWS=50000
ITERATIONS=20

[[ -x "$CLI" ]] || { echo "client not found at $CLI — run ./Scripts/test-servers.sh up" >&2; exit 1; }

mysql() { "$CLI" -h 127.0.0.1 -P 3308 -u native -pnativepass swizzle_test --skip-ssl "$@" 2>/dev/null; }

# `time -p` reports hundredths, which is far too coarse for a ~30 ms query. Timing
# a batch of ITERATIONS and dividing gets the resolution down to ~0.5 ms without
# needing a sub-second clock the shell does not have.
timed() {
  local label="$1"; shift
  local real
  real=$( { /usr/bin/time -p bash -c '
    for _ in $(seq 1 '"$ITERATIONS"'); do "$@" >/dev/null 2>&1; done
  ' _ "$@" ; } 2>&1 | awk '/^real/{print $2}' )
  awk -v r="$real" -v n="$ITERATIONS" -v l="$label" \
    'BEGIN { printf "  %-46s %8.4f s\n", l, r / n }'
}

echo "Seeding $ROWS rows..."
# Generated server-side. MariaDB's `seq_` engine makes this one statement rather
# than a client-side loop.
mysql -e "
  DROP TABLE IF EXISTS clibench;
  CREATE TABLE clibench (
      id INT PRIMARY KEY, name VARCHAR(64), score BIGINT,
      ratio DOUBLE, note VARCHAR(128)
  );
  INSERT INTO clibench
  SELECT seq, CONCAT('name-', seq), seq * 7, seq * 1.5, CONCAT('note-', seq)
  FROM seq_0_to_$((ROWS - 1));
"
echo "  $(mysql -B --skip-column-names -e 'SELECT COUNT(*) FROM clibench') rows"
echo

# Reported as a mean over the batch, not a minimum: `time -p` cannot resolve a
# single ~30 ms run. A mean includes scheduling noise, so these read a few
# milliseconds higher than the best-of-N minimums in docs/performance.md — that
# is the measurement method differing, not the machine.
echo "mariadb client ($("$CLI" --version | sed 's/.*Distrib //; s/,.*//')), mean of $ITERATIONS runs:"
timed "fixed overhead (fork/exec + connect + auth)" \
  "$CLI" -h 127.0.0.1 -P 3308 -u native -pnativepass swizzle_test --skip-ssl -B -e "SELECT 1"
timed "default (boxed table)" \
  "$CLI" -h 127.0.0.1 -P 3308 -u native -pnativepass swizzle_test --skip-ssl -e "SELECT * FROM clibench"
timed "-B --quick (fastest mode)" \
  "$CLI" -h 127.0.0.1 -P 3308 -u native -pnativepass swizzle_test --skip-ssl -B --quick -e "SELECT * FROM clibench"

echo
echo "Subtract the fixed overhead from the two query rows before comparing."
echo "Now run:  SWIZZLE_BENCH=1 swift test -c release --filter CLIComparison"

#!/usr/bin/env bash
#
# Catch pool tests that assert on a request outcome without ever producing one.
#
# ## The mistake this exists for
#
# `PoolStateMachine` decides what happens to a request and returns it as an
# action. It never resumes the caller — that is `ConnectionPool`'s job. So a
# test that drives the machine directly and then reads `MockRequest.result`,
# `.failure` or `.leasedConnectionID` is reading `nil` forever, whatever the
# pool did.
#
# That is not a test that fails; it is a test that cannot fail. Every `== nil`
# assertion passes vacuously and every other one fails for reasons that look
# like bugs in the pool. Four such assertions sat in the tree passing, and the
# same mistake was made three more times while writing one suite.
#
# The fix is `run(_:)` in PoolTestDoubles, which performs a request action
# exactly as the pool does. This script checks nobody forgets it again.
#
# ## What it flags
#
# A test function that calls the state machine directly, reads a request
# outcome, and never runs an action. Tests that go through the `lease(_:from:)`
# helper, call `run(_:)` themselves, or delegate setup to a `Self.` helper that
# does, are fine.
#
# Exit 1 on any finding, so CI fails.

set -euo pipefail

DIR="${1:-Tests/SwizzleConnectionPoolTests}"

if [ ! -d "$DIR" ]; then
    echo "no such directory: $DIR" >&2
    exit 2
fi

findings=0

for file in "$DIR"/*.swift; do
    [ -e "$file" ] || continue
    # Walk each file one test function at a time. A test begins at `@Test(` and
    # ends at the next one (or end of file); that is coarser than brace
    # matching but cannot mis-pair, which matters more here.
    awk -v FILE="$file" '
        function flush() {
            if (name != "" && reads && drives && !runs) {
                printf "%s:%d: %s asserts on a request outcome but never runs the action\n", FILE, start, name
                found++
            }
            name = ""; reads = 0; drives = 0; runs = 0
        }
        /@Test\(/ { flush(); start = NR; capture = 1; next }
        capture && /func [a-zA-Z_]+\(/ {
            line = $0
            sub(/^.*func /, "", line); sub(/\(.*$/, "", line)
            name = line; capture = 0
        }
        # Reading an outcome the machine never produces.
        /\.result[^a-zA-Z]|\.failure[^a-zA-Z]|\.leasedConnectionID/ { reads = 1 }
        # Driving the machine directly rather than through the helper.
        /machine\.[a-zA-Z]+\(|\.leaseConnection\(|\.releaseConnection\(/ { drives = 1 }
        # Running the action, by any of the sanctioned routes.
        /(^|[^a-zA-Z])run\(|(^|[^a-zA-Z])lease\(|Self\.[a-zA-Z]+\(/ { runs = 1 }
        END { flush(); exit (found > 0 ? 1 : 0) }
    ' "$file" || findings=1
done

if [ "$findings" -ne 0 ]; then
    cat >&2 <<'EOF'

Each finding above reads MockRequest.result, .failure or .leasedConnectionID
after driving the state machine directly. Those are nil unless the request
action is run, so the assertion cannot fail.

Use lease(_:from:) instead of machine.leaseConnection(_:), or pass the returned
action to run(_:). Both are in PoolTestDoubles.swift.
EOF
    exit 1
fi

echo "pool test lint: clean ($(ls "$DIR"/*.swift | wc -l | tr -d ' ') files)"

#!/usr/bin/env bash
# Build and test on Linux glibc, in a container.
#
# ## Why this is a script and not a line in a doc
#
# It was a line in a doc, and the doc's claim ("359 tests pass") went four times
# out of date without anyone noticing — the suite grew to 1375 while nothing had
# run on Linux in months. What it was hiding: `stderr` is a global `var` in
# glibc, so Swift 6 strict concurrency refuses to let a `@Sendable` closure
# reference it. Darwin and musl import the same symbol in a form that does not
# trip the check, so the package compiled on macOS *and* on both static-musl
# cross-builds and failed only here. A build-breaking failure on the platform
# most deployments use, sitting undetected.
#
# A command people run is worth more than a command people could run.
#
# ## What it covers
#
# Everything that does not need a database server: the protocol state machines,
# the codecs, the query builder, the whole SQLite suite. The MySQL and Postgres
# integration suites **skip**, because the fixtures bind to the host's loopback
# and a container cannot reach them — roughly 590 of the 1375. Covering those on
# Linux means running the servers in the same network namespace, which is a CI
# shape rather than a laptop one.
#
# The image is pinned to the same toolchain as the host, so a failure here is
# the platform rather than the compiler version.

set -uo pipefail
cd "$(dirname "$0")/.."

IMAGE="${SWIZZLE_LINUX_IMAGE:-swift:6.3.3}"
# A separate scratch path: sharing `.build` with the host means each run
# invalidates the other's, and a macOS `swift test` afterwards fails with
# "not registered" until it is rebuilt.
SCRATCH=".build-linux"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is not installed — this is the one check that needs it"
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "docker is installed but not running"
  exit 1
fi

echo ""
echo "═══ Linux glibc ($IMAGE)"
echo ""

docker run --rm -v "$PWD":/src -w /src "$IMAGE" \
  swift test --scratch-path "$SCRATCH" 2>&1 | tail -40
status=${PIPESTATUS[0]}

echo ""
if [[ $status -eq 0 ]]; then
  echo "  ✓ Linux build and test suite clean"
else
  echo "  ✗ Linux run failed (exit $status)"
fi
echo ""
exit $status

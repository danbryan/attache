#!/usr/bin/env bash
# Watchdog wrapper for `swift test`: a hung suite fails loudly instead of
# silently eating the session (2026-07-17: a run deadlocked for ~50 minutes
# against a stale concurrent xctest). Rules it enforces:
#
#   1. Single-flight: refuses to start while another AttachePackageTests
#      xctest is running (a concurrent suite contends on shared fixtures and
#      can deadlock both). Kill the stale one or pass KILL_STALE=1.
#   2. Wall clock cap: the whole run (build + tests) is killed after
#      ATTACHE_TEST_TIMEOUT seconds (default 900; a warm run is ~60s, and a
#      cold rebuild after AppModel-chain edits measured ~9 minutes on
#      2026-07-18, which is why the default is 900 and not lower). If the cap
#      fires, INVESTIGATE the hang; raising the cap without understanding it
#      just reintroduces the waste.
#
# Usage: scripts/test.sh [swift test args...]
set -u

TIMEOUT="${ATTACHE_TEST_TIMEOUT:-900}"

stale=$(pgrep -f "AttachePackageTests.xctest" || true)
if [[ -n "$stale" ]]; then
  if [[ "${KILL_STALE:-0}" == "1" ]]; then
    echo "test.sh: killing stale xctest process(es): $stale"
    kill $stale 2>/dev/null; sleep 2; kill -9 $stale 2>/dev/null
  else
    echo "test.sh: another AttachePackageTests run is already active (pid(s): $stale)." >&2
    echo "test.sh: suites are single-flight; rerun with KILL_STALE=1 to take over." >&2
    exit 75
  fi
fi

swift test "$@" &
test_pid=$!

elapsed=0
while kill -0 "$test_pid" 2>/dev/null; do
  if (( elapsed >= TIMEOUT )); then
    echo "test.sh: TIMED OUT after ${TIMEOUT}s (normal warm run is ~60s)." >&2
    echo "test.sh: killing the run. Investigate the hang (stuck test, fixture" >&2
    echo "test.sh: contention, unbounded wait) before raising ATTACHE_TEST_TIMEOUT." >&2
    pkill -P "$test_pid" 2>/dev/null
    kill "$test_pid" 2>/dev/null
    sleep 2
    pgrep -f "AttachePackageTests.xctest" | xargs kill -9 2>/dev/null
    kill -9 "$test_pid" 2>/dev/null
    exit 124
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done

wait "$test_pid"
exit $?

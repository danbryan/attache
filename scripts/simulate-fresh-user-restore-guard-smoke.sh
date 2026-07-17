#!/usr/bin/env bash
set -euo pipefail

# Self-check for scripts/simulate-fresh-user.sh's restore() guard and lock
# (2026-07-17 profile-wipe incident). Proves two things against a throwaway
# directory, never the real profile, Keychain, or UserDefaults:
#
#   1. restore() against a backup with no Attache folder exits nonzero and
#      leaves a seeded live profile completely untouched.
#   2. restore() refuses to run while another invocation's lock is held.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/simulate-fresh-user.sh"

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

export ATTACHE_FRESH_USER_TEST_MODE=1
export ATTACHE_FRESH_USER_SUPPORT_DIR="$WORKDIR/Attache"
export ATTACHE_FRESH_USER_BACKUP_ROOT="$WORKDIR/Attache Backups"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# --- Test 1: missing-Attache backup must hard-fail before touching the live profile. ---
mkdir -p "$ATTACHE_FRESH_USER_SUPPORT_DIR"
echo "seed-marker" > "$ATTACHE_FRESH_USER_SUPPORT_DIR/marker.txt"

empty_backup="$ATTACHE_FRESH_USER_BACKUP_ROOT/fresh-user-empty"
mkdir -p "$empty_backup"

set +e
restore_output="$("$TARGET" restore "$empty_backup" 2>&1)"
restore_status=$?
set -e

[[ "$restore_status" -ne 0 ]] || fail "restore() exited 0 against a backup with no Attache folder (expected nonzero)"
[[ -f "$ATTACHE_FRESH_USER_SUPPORT_DIR/marker.txt" ]] || fail "live profile marker was removed even though restore() should have hard-failed before touching it"
grep -q "no Attache directory" <<<"$restore_output" || fail "restore() did not print the expected guard error (got: $restore_output)"
echo "PASS: restore() hard-fails and leaves the live profile untouched when the backup has no Attache folder"

# --- Test 2: lockfile rejects a concurrent invocation. ---
lock_dir="$ATTACHE_FRESH_USER_BACKUP_ROOT/.simulate-fresh-user.lock"
mkdir -p "$lock_dir"
echo "99999999" > "$lock_dir/pid"

good_backup="$ATTACHE_FRESH_USER_BACKUP_ROOT/fresh-user-good"
mkdir -p "$good_backup/Attache"
echo "backup-marker" > "$good_backup/Attache/marker.txt"

set +e
lock_output="$("$TARGET" restore "$good_backup" 2>&1)"
lock_status=$?
set -e

[[ "$lock_status" -ne 0 ]] || fail "restore() exited 0 while a lock was held (expected nonzero)"
grep -qi "already in progress" <<<"$lock_output" || fail "restore() did not print the expected lock-contention error (got: $lock_output)"
rm -rf "$lock_dir"
echo "PASS: restore() refuses to run while another invocation's lock is held"

# --- Test 3: a real restore (valid backup, no contention) still works end to end. ---
set +e
happy_output="$("$TARGET" restore "$good_backup" 2>&1)"
happy_status=$?
set -e

[[ "$happy_status" -eq 0 ]] || fail "restore() failed against a valid, uncontended backup (output: $happy_output)"
[[ -f "$ATTACHE_FRESH_USER_SUPPORT_DIR/marker.txt" ]] || fail "restore() did not restore the backup's marker file into the live profile"
grep -q "backup-marker" "$ATTACHE_FRESH_USER_SUPPORT_DIR/marker.txt" || fail "restored live profile does not contain the backup's content"
[[ ! -d "$lock_dir" ]] || fail "lock directory was not released after a successful restore"
echo "PASS: restore() succeeds end to end against a valid, uncontended backup and releases its lock"

echo "All simulate-fresh-user.sh restore guard self-checks passed."

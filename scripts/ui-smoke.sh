#!/usr/bin/env bash
set -euo pipefail

# UI smoke harness entry point (INF-156). Builds the app and the AX driver,
# packages an unsigned test app, switches to fresh-user state, drives the five
# core flows headed, and restores the user's state afterward.
#
# Usage:
#   scripts/ui-smoke.sh                 run all flows
#   SMOKE_ONLY=f1,f4 scripts/ui-smoke.sh    run a subset while iterating
#   SMOKE_KEEP_STATE=1 scripts/ui-smoke.sh  skip fresh/restore (developer loop)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> Building driver and app"
swift build >/dev/null
SIGN_APP=0 scripts/package-app.sh >/dev/null

DRIVER="$ROOT/.build/debug/AttacheUISmoke"
if [[ ! -x "$DRIVER" ]]; then
  echo "error: driver binary not found at $DRIVER" >&2
  exit 1
fi

BACKUP_DIR=""
restore_state() {
  pkill -f "$ROOT/dist/Attache.app/Contents/MacOS/Attache" 2>/dev/null || true
  if [[ -n "$BACKUP_DIR" ]]; then
    echo "==> Restoring user state from $BACKUP_DIR"
    scripts/simulate-fresh-user.sh restore "$BACKUP_DIR" || {
      echo "error: state restore failed; restore manually with:" >&2
      echo "  scripts/simulate-fresh-user.sh restore \"$BACKUP_DIR\"" >&2
    }
    BACKUP_DIR=""
  fi
}

if [[ "${SMOKE_KEEP_STATE:-0}" != "1" ]]; then
  echo "==> Switching to fresh-user state"
  FRESH_OUTPUT="$(scripts/simulate-fresh-user.sh fresh)"
  echo "$FRESH_OUTPUT"
  BACKUP_DIR="$(printf '%s\n' "$FRESH_OUTPUT" | sed -n 's/^Backup: //p' | tail -1)"
  if [[ -z "$BACKUP_DIR" ]]; then
    echo "error: could not determine backup dir from fresh output" >&2
    exit 1
  fi
  trap restore_state EXIT
fi

echo "==> Running UI smoke flows"
# Any running Attaché owns the event-server port and would shadow the app
# under test, so clear all instances, not just prior dist builds.
pkill -f "Attache.app/Contents/MacOS/Attache" 2>/dev/null || true
set +e
"$DRIVER" "$ROOT/dist/Attache.app" "$ROOT"
STATUS=$?
set -e

exit "$STATUS"

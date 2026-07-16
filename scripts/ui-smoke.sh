#!/usr/bin/env bash
set -euo pipefail

# UI smoke harness entry point (INF-156). Builds the app and the AX driver,
# packages an unsigned test app, switches to fresh-user state, drives the six
# core flows headed, and restores the user's state afterward.
#
# Usage:
#   scripts/ui-smoke.sh                      run the default free/local flows
#   SMOKE_ONLY=f1,f4 scripts/ui-smoke.sh     run a subset while iterating
#   SMOKE_KEEP_STATE=1 scripts/ui-smoke.sh   skip fresh/restore (developer loop)
#
# Opt-in release/network/load flows are intentionally excluded from the default
# suite:
#   scripts/release-readiness-smoke.sh       eleven pre-release gates
#   scripts/agent-destination-smoke.sh       explicit Tell Agent staging
#   scripts/conversation-feedback-smoke.sh   live Ask Attaché send feedback
#   scripts/conversation-recovery-smoke.sh   usage-limit model recovery
#   scripts/codex-two-way-smoke.sh           real Codex send/watch round trip
#   scripts/codex-personality-two-way-smoke.sh
#                                             fake local personality + real Codex
#   scripts/claude-two-way-smoke.sh          real Claude Code send/watch round trip
#   scripts/provider-canaries.sh             provider tool-calling contracts

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "${ATTACHE_UI_SMOKE_SKIP_BUILD_PACKAGE:-0}" == "1" ]]; then
  echo "==> Reusing prebuilt driver and packaged app"
  [[ -x "$ROOT/.build/debug/AttacheUISmoke" ]] || {
    echo "error: ATTACHE_UI_SMOKE_SKIP_BUILD_PACKAGE=1 but the driver is missing" >&2
    exit 1
  }
  [[ -x "$ROOT/dist/Attache.app/Contents/MacOS/Attache" ]] || {
    echo "error: ATTACHE_UI_SMOKE_SKIP_BUILD_PACKAGE=1 but the packaged app is missing" >&2
    exit 1
  }
else
  echo "==> Building driver and app"
  swift build >/dev/null
  SIGN_APP=0 scripts/package-app.sh >/dev/null
fi

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

  # The standard suite exercises Command-K against real local Codex session
  # metadata. A truly fresh profile has every agent source disabled until the
  # user chooses one in onboarding, while flow 1 deliberately tests the Skip
  # path. Enable only the source that flow 4 explicitly intends to exercise in
  # this disposable profile. The dedicated no-key first-run flow remains fully
  # disconnected.
  if [[ -z "${SMOKE_ONLY:-}" || ",${SMOKE_ONLY}," == *",f4,"* ]]; then
    defaults write com.bryanlabs.attache attache.codexSourceEnabled -bool true
  fi
fi

echo "==> Running UI smoke flows"
export ATTACHE_UI_TEST_IMPORT_PERSONALITY_PATH="$ROOT/Tests/Fixtures/personality-import.json"
# Any running Attaché owns the event-server port and would shadow the app
# under test, so clear all instances, not just prior dist builds.
pkill -f "Attache.app/Contents/MacOS/Attache" 2>/dev/null || true
set +e
"$DRIVER" "$ROOT/dist/Attache.app" "$ROOT"
STATUS=$?
set -e

exit "$STATUS"

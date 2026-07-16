#!/usr/bin/env bash
set -euo pipefail

# INF-344: packaged, accessibility-driven context-management release surface.
# Uses only a disposable Codex home and ATTACHE_UI_TEST fixtures. No provider
# network request or paid inference is possible.

umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUNDLE_ID="com.bryanlabs.attache"
TEMP_ROOT=""
BACKUP_DIR=""

fail() {
  echo "error: $*" >&2
  exit 1
}

cleanup() {
  pkill -f "$ROOT/dist/Attache.app/Contents/MacOS/Attache" 2>/dev/null || true
  if [[ -n "$BACKUP_DIR" ]]; then
    scripts/simulate-fresh-user.sh restore "$BACKUP_DIR" >/dev/null || {
      echo "error: state restore failed; restore manually with:" >&2
      echo "  scripts/simulate-fresh-user.sh restore \"$BACKUP_DIR\"" >&2
      return
    }
    BACKUP_DIR=""
  fi
  if [[ -n "$TEMP_ROOT" ]]; then
    rm -rf "$TEMP_ROOT"
  fi
}
trap cleanup EXIT

TEMP_ROOT="$(mktemp -d /tmp/attache-context-ui.XXXXXX)"
CODEX_TEST_HOME="$TEMP_ROOT/codex-home"
META_FILE="$TEMP_ROOT/fake-codex.json"
MUTATION_LOG="$TEMP_ROOT/mutation.log"
NONCE="CONTEXT_$(uuidgen | tr '[:lower:]' '[:upper:]' | tr -d '-' | cut -c1-10)"

python3 scripts/create-fake-codex-home.py \
  --home "$CODEX_TEST_HOME" \
  --nonce "$NONCE" \
  --count 1 \
  --target-title "Context discovery smoke $NONCE" \
  --needle "ATTACHE_CONTEXT_DISCOVERY_$NONCE" \
  > "$META_FILE"

SESSION_ID="$(python3 - "$META_FILE" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["target_session_id"])
PY
)"
[[ -n "$SESSION_ID" ]] || fail "fake context discovery session was not created"

echo "==> Switching to a disposable context UI profile"
FRESH_OUTPUT="$(scripts/simulate-fresh-user.sh fresh)"
echo "$FRESH_OUTPUT"
BACKUP_DIR="$(printf '%s\n' "$FRESH_OUTPUT" | sed -n 's/^Backup: //p' | tail -1)"
[[ -n "$BACKUP_DIR" ]] || fail "could not determine Attaché backup dir"

defaults write "$BUNDLE_ID" attache.onboardingCompleted -bool true
defaults write "$BUNDLE_ID" attache.codexSourceEnabled -bool true
defaults write "$BUNDLE_ID" attache.claudeCodeSourceEnabled -bool false
defaults write "$BUNDLE_ID" attache.presentationLLMEnabled -bool false
defaults write "$BUNDLE_ID" attache.voicemailMode -bool true
defaults write "$BUNDLE_ID" attache.showActivityInsights -bool false
defaults write "$BUNDLE_ID" attache.showTips -bool false

echo "==> Running packaged context accessibility flow"
SMOKE_ONLY=context \
SMOKE_KEEP_STATE=1 \
CODEX_HOME="$CODEX_TEST_HOME" \
ATTACHE_DISABLE_TOPIC_TAGGING=1 \
ATTACHE_CONTEXT_SMOKE_FIXTURES=1 \
ATTACHE_CONTEXT_SMOKE_NONCE="$NONCE" \
ATTACHE_CONTEXT_SMOKE_SESSION_ID="$SESSION_ID" \
  scripts/ui-smoke.sh

echo "==> Proving the UI gate detects a missing major surface"
pkill -f "$ROOT/dist/Attache.app/Contents/MacOS/Attache" 2>/dev/null || true
set +e
SMOKE_ONLY=context \
CODEX_HOME="$CODEX_TEST_HOME" \
ATTACHE_DISABLE_TOPIC_TAGGING=1 \
ATTACHE_CONTEXT_SMOKE_FIXTURES=1 \
ATTACHE_CONTEXT_SMOKE_OMIT=review \
ATTACHE_CONTEXT_SMOKE_NONCE="$NONCE" \
ATTACHE_CONTEXT_SMOKE_SESSION_ID="$SESSION_ID" \
  "$ROOT/.build/debug/AttacheUISmoke" "$ROOT/dist/Attache.app" "$ROOT" \
  > "$MUTATION_LOG" 2>&1
MUTATION_STATUS=$?
set -e
if [[ "$MUTATION_STATUS" == "0" ]]; then
  fail "deliberately removing the exhaustive-review fixture did not fail the AX gate"
fi
grep -q "FAILED: context-ui / exhaustive review preview, cancel, and resume controls are reachable" "$MUTATION_LOG" || {
  echo "unexpected mutation-run output:" >&2
  tail -80 "$MUTATION_LOG" >&2
  fail "AX mutation failed for an unrelated reason"
}
echo "UI invariant mutation: PASS (missing exhaustive review was detected)"
echo "==> Context UI smoke passed"

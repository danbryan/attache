#!/usr/bin/env bash
set -euo pipefail

umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUNDLE_ID="com.bryanlabs.attache"
TEMP_ROOT=""
BACKUP_DIR=""

usage() {
  cat <<EOF
Usage:
  scripts/codex-two-way-safety-smoke.sh

Creates a disposable fake Codex session, opens Attaché's send-to-agent UI, and
proves an approval-like instruction is refused before any final send
confirmation or transcript write.
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

json_field() {
  python3 - "$1" "$2" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1], encoding="utf-8"))[sys.argv[2]])
PY
}

cleanup() {
  pkill -f "$ROOT/dist/Attache.app/Contents/MacOS/Attache" 2>/dev/null || true
  if [[ -n "$BACKUP_DIR" ]]; then
    scripts/simulate-fresh-user.sh restore "$BACKUP_DIR" >/dev/null || {
      echo "warning: state restore failed; restore manually with:" >&2
      echo "  scripts/simulate-fresh-user.sh restore \"$BACKUP_DIR\"" >&2
    }
    BACKUP_DIR=""
  fi
  if [[ -n "$TEMP_ROOT" ]]; then
    rm -rf "$TEMP_ROOT"
  fi
  rm -rf "$ROOT/dist/Attache.app" "$ROOT/dist/_dmgwork"
}
trap cleanup EXIT

case "${1:-}" in
  "" )
    ;;
  -h|--help|help )
    usage
    exit 0
    ;;
  * )
    usage >&2
    exit 1
    ;;
esac

command -v python3 >/dev/null 2>&1 || fail "python3 was not found on PATH"

TEMP_ROOT="$(mktemp -d /tmp/attache-two-way-safety.XXXXXX)"
CODEX_TEST_HOME="$TEMP_ROOT/codex-home"
META_FILE="$TEMP_ROOT/fake-codex.json"
NONCE="$(date +%Y%m%d%H%M%S)_$(uuidgen | tr '[:lower:]' '[:upper:]' | tr -d '-' | cut -c1-8)"

python3 scripts/create-fake-codex-home.py \
  --home "$CODEX_TEST_HOME" \
  --nonce "$NONCE" \
  --count 1 \
  --target-title "Two-way safety smoke $NONCE" \
  --needle "ATTACHE_SAFETY_$NONCE" \
  > "$META_FILE"

SESSION_ID="$(json_field "$META_FILE" target_session_id)"
SESSION_FILE="$(json_field "$META_FILE" target_session_file)"
[[ -n "$SESSION_ID" && -f "$SESSION_FILE" ]] || fail "fake Codex session was not created"

echo "==> Disposable safety session: $SESSION_ID"
echo "==> Switching Attaché to a fresh test profile"
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

echo "==> Running Attaché two-way safety UI smoke"
SMOKE_ONLY=f9 \
SMOKE_KEEP_STATE=1 \
CODEX_HOME="$CODEX_TEST_HOME" \
ATTACHE_DISABLE_TOPIC_TAGGING=1 \
ATTACHE_TWO_WAY_SAFETY_NONCE="$NONCE" \
ATTACHE_TWO_WAY_SAFETY_SESSION_ID="$SESSION_ID" \
ATTACHE_TWO_WAY_SAFETY_SESSION_FILE="$SESSION_FILE" \
  scripts/ui-smoke.sh

echo "==> Two-way safety smoke passed for session $SESSION_ID"

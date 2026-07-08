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
  scripts/load-smoke.sh

Creates a disposable Codex home with many sessions and a large target
transcript, files many local voicemail cards through Attaché's local event
server, then proves inbox search and Command-K session search stay responsive.

Environment:
  ATTACHE_LOAD_SMOKE_SESSION_COUNT   default 180
  ATTACHE_LOAD_SMOKE_CARD_COUNT      default 80
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

SESSION_COUNT="${ATTACHE_LOAD_SMOKE_SESSION_COUNT:-180}"
CARD_COUNT="${ATTACHE_LOAD_SMOKE_CARD_COUNT:-80}"
TEMP_ROOT="$(mktemp -d /tmp/attache-load-smoke.XXXXXX)"
CODEX_TEST_HOME="$TEMP_ROOT/codex-home"
META_FILE="$TEMP_ROOT/fake-codex.json"
NONCE="$(date +%Y%m%d%H%M%S)_$(uuidgen | tr '[:lower:]' '[:upper:]' | tr -d '-' | cut -c1-8)"
NEEDLE="ATTACHE_LOAD_NEEDLE_$NONCE"

python3 scripts/create-fake-codex-home.py \
  --home "$CODEX_TEST_HOME" \
  --nonce "$NONCE" \
  --count "$SESSION_COUNT" \
  --target-title "Load smoke target $NONCE" \
  --needle "$NEEDLE" \
  --large-target \
  > "$META_FILE"

SESSION_ID="$(json_field "$META_FILE" target_session_id)"
[[ -n "$SESSION_ID" ]] || fail "fake Codex load target was not created"

echo "==> Load target session: $SESSION_ID ($SESSION_COUNT fake sessions, $CARD_COUNT cards)"
echo "==> Switching Attaché to a fresh load profile"
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

echo "==> Running Attaché load UI smoke"
SMOKE_ONLY=f12 \
SMOKE_KEEP_STATE=1 \
CODEX_HOME="$CODEX_TEST_HOME" \
ATTACHE_DISABLE_TOPIC_TAGGING=1 \
ATTACHE_LOAD_SMOKE_NONCE="$NONCE" \
ATTACHE_LOAD_SMOKE_NEEDLE="$NEEDLE" \
ATTACHE_LOAD_SMOKE_TARGET_SESSION_ID="$SESSION_ID" \
ATTACHE_LOAD_SMOKE_CARD_COUNT="$CARD_COUNT" \
  scripts/ui-smoke.sh

echo "==> Load smoke passed"

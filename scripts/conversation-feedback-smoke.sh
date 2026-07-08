#!/usr/bin/env bash
set -euo pipefail

umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUNDLE_ID="com.bryanlabs.attache"
TEMP_ROOT=""
BACKUP_DIR=""
SERVER_PID=""

usage() {
  cat <<EOF
Usage:
  scripts/conversation-feedback-smoke.sh

Starts a deterministic local personality provider, opens the live Ask Attaché
text input, presses the visible send button, and proves the UI clears the field,
shows a thinking indicator while the provider is delayed, then displays the
provider's reply.
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

cleanup() {
  pkill -f "$ROOT/dist/Attache.app/Contents/MacOS/Attache" 2>/dev/null || true
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
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

TEMP_ROOT="$(mktemp -d /tmp/attache-conversation-feedback.XXXXXX)"
PROVIDER_LOG="$TEMP_ROOT/personality-provider.jsonl"
PROVIDER_STDOUT="$TEMP_ROOT/personality-provider.log"
: > "$PROVIDER_LOG"
chmod 600 "$PROVIDER_LOG"

NONCE="$(date +%Y%m%d%H%M%S)_$(uuidgen | tr '[:lower:]' '[:upper:]' | tr -d '-' | cut -c1-8)"
MODEL="attache-feedback-smoke"
PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"

echo "==> Starting deterministic personality provider on 127.0.0.1:$PORT"
ATTACHE_PERSONALITY_TWO_WAY_NONCE="$NONCE" \
ATTACHE_PERSONALITY_TWO_WAY_PONG_TOKEN="ATTACHE_UNUSED_${NONCE}" \
ATTACHE_PERSONALITY_TWO_WAY_PROVIDER_LOG="$PROVIDER_LOG" \
ATTACHE_PERSONALITY_TWO_WAY_MODEL="$MODEL" \
ATTACHE_PERSONALITY_TWO_WAY_PORT="$PORT" \
ATTACHE_SMOKE_PROVIDER_DELAY_MS=6000 \
  python3 scripts/personality-two-way-smoke-server.py >"$PROVIDER_STDOUT" 2>&1 &
SERVER_PID=$!

for _ in {1..50}; do
  if grep -q '"event": "ready"' "$PROVIDER_LOG"; then
    break
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    cat "$PROVIDER_STDOUT" >&2 || true
    fail "personality provider exited before becoming ready"
  fi
  sleep 0.1
done
grep -q '"event": "ready"' "$PROVIDER_LOG" || fail "personality provider did not become ready"

echo "==> Switching Attaché to a fresh test profile"
FRESH_OUTPUT="$(scripts/simulate-fresh-user.sh fresh)"
echo "$FRESH_OUTPUT"
BACKUP_DIR="$(printf '%s\n' "$FRESH_OUTPUT" | sed -n 's/^Backup: //p' | tail -1)"
[[ -n "$BACKUP_DIR" ]] || fail "could not determine Attaché backup dir"

defaults write "$BUNDLE_ID" attache.onboardingCompleted -bool true
defaults write "$BUNDLE_ID" attache.codexSourceEnabled -bool false
defaults write "$BUNDLE_ID" attache.claudeCodeSourceEnabled -bool false
defaults write "$BUNDLE_ID" attache.presentationLLMEnabled -bool true
defaults write "$BUNDLE_ID" attache.voicemailMode -bool true
defaults write "$BUNDLE_ID" attache.showActivityInsights -bool false
defaults write "$BUNDLE_ID" attache.showTips -bool false

echo "==> Running Attaché conversation feedback UI smoke"
SMOKE_ONLY=f15 \
SMOKE_KEEP_STATE=1 \
ATTACHE_DISABLE_TOPIC_TAGGING=1 \
ATTACHE_LLM_PROVIDER=ollama \
ATTACHE_LLM_BASE_URL="http://127.0.0.1:${PORT}/v1" \
ATTACHE_LLM_MODEL="$MODEL" \
ATTACHE_CONVERSATION_FEEDBACK_NONCE="$NONCE" \
ATTACHE_CONVERSATION_FEEDBACK_PROVIDER_LOG="$PROVIDER_LOG" \
ATTACHE_CONVERSATION_FEEDBACK_PROMPT="ATTACHE_CONVERSATION_FEEDBACK $NONCE" \
ATTACHE_CONVERSATION_FEEDBACK_REPLY="ATTACHE_CONVERSATION_FEEDBACK_REPLY_$NONCE" \
  scripts/ui-smoke.sh

echo "==> Conversation feedback smoke passed"

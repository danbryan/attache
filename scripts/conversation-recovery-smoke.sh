#!/usr/bin/env bash
set -euo pipefail

umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUNDLE_ID="com.bryanlabs.attache"
TEMP_ROOT=""
BACKUP_DIR=""
SERVER_PID=""

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

command -v python3 >/dev/null 2>&1 || fail "python3 was not found on PATH"

TEMP_ROOT="$(mktemp -d /tmp/attache-conversation-recovery.XXXXXX)"
PROVIDER_LOG="$TEMP_ROOT/personality-provider.jsonl"
PROVIDER_STDOUT="$TEMP_ROOT/personality-provider.log"
: > "$PROVIDER_LOG"
chmod 600 "$PROVIDER_LOG"

NONCE="$(date +%Y%m%d%H%M%S)_$(uuidgen | tr '[:lower:]' '[:upper:]' | tr -d '-' | cut -c1-8)"
MODEL="attache-recovery-smoke"
PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"

echo "==> Starting deterministic usage-limit provider on 127.0.0.1:$PORT"
ATTACHE_PERSONALITY_TWO_WAY_NONCE="$NONCE" \
ATTACHE_PERSONALITY_TWO_WAY_PONG_TOKEN="ATTACHE_UNUSED_${NONCE}" \
ATTACHE_PERSONALITY_TWO_WAY_PROVIDER_LOG="$PROVIDER_LOG" \
ATTACHE_PERSONALITY_TWO_WAY_MODEL="$MODEL" \
ATTACHE_PERSONALITY_TWO_WAY_PORT="$PORT" \
ATTACHE_SMOKE_PROVIDER_ERROR=usage_limit \
  python3 scripts/personality-two-way-smoke-server.py >"$PROVIDER_STDOUT" 2>&1 &
SERVER_PID=$!

for _ in {1..50}; do
  if grep -q '"event": "ready"' "$PROVIDER_LOG"; then
    break
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    cat "$PROVIDER_STDOUT" >&2 || true
    fail "usage-limit provider exited before becoming ready"
  fi
  sleep 0.1
done
grep -q '"event": "ready"' "$PROVIDER_LOG" || fail "usage-limit provider did not become ready"

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

echo "==> Running Attaché conversation recovery UI smoke"
SMOKE_ONLY=f16 \
SMOKE_KEEP_STATE=1 \
ATTACHE_DISABLE_TOPIC_TAGGING=1 \
ATTACHE_LLM_PROVIDER=ollama \
ATTACHE_LLM_BASE_URL="http://127.0.0.1:${PORT}/v1" \
ATTACHE_CONVERSATION_RECOVERY_PROMPT="ATTACHE_CONVERSATION_RECOVERY $NONCE" \
ATTACHE_CONVERSATION_RECOVERY_PROVIDER_LOG="$PROVIDER_LOG" \
  scripts/ui-smoke.sh

echo "==> Conversation recovery smoke passed"

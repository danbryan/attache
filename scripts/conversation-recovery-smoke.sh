#!/usr/bin/env bash
set -euo pipefail

umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUNDLE_ID="com.bryanlabs.attache"
TEMP_ROOT=""
BACKUP_DIR=""
SERVER_PID=""
# A second concurrent mock provider, used only by the auto-fallback scenario
# (INF-258/D5) below, which needs a primary AND a fallback server running at
# the same time rather than one at a time like the f16/f17 scenarios above.
SERVER_PID_B=""

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
  if [[ -n "$SERVER_PID_B" ]]; then
    kill "$SERVER_PID_B" 2>/dev/null || true
    wait "$SERVER_PID_B" 2>/dev/null || true
    SERVER_PID_B=""
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

free_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

wait_for_ready() {
  local log="$1" pid="$2" label="$3"
  for _ in {1..50}; do
    if grep -q '"event": "ready"' "$log"; then
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    sleep 0.1
  done
  return 1
}

TEMP_ROOT="$(mktemp -d /tmp/attache-conversation-recovery.XXXXXX)"
PROVIDER_LOG="$TEMP_ROOT/personality-provider.jsonl"
PROVIDER_STDOUT="$TEMP_ROOT/personality-provider.log"
: > "$PROVIDER_LOG"
chmod 600 "$PROVIDER_LOG"

NONCE="$(date +%Y%m%d%H%M%S)_$(uuidgen | tr '[:lower:]' '[:upper:]' | tr -d '-' | cut -c1-8)"
MODEL="attache-recovery-smoke"
PORT="$(free_port)"

echo "==> Starting deterministic usage-limit provider on 127.0.0.1:$PORT"
ATTACHE_PERSONALITY_TWO_WAY_NONCE="$NONCE" \
ATTACHE_PERSONALITY_TWO_WAY_PONG_TOKEN="ATTACHE_UNUSED_${NONCE}" \
ATTACHE_PERSONALITY_TWO_WAY_PROVIDER_LOG="$PROVIDER_LOG" \
ATTACHE_PERSONALITY_TWO_WAY_MODEL="$MODEL" \
ATTACHE_PERSONALITY_TWO_WAY_PORT="$PORT" \
ATTACHE_SMOKE_PROVIDER_ERROR=usage_limit \
  python3 scripts/personality-two-way-smoke-server.py >"$PROVIDER_STDOUT" 2>&1 &
SERVER_PID=$!

wait_for_ready "$PROVIDER_LOG" "$SERVER_PID" "usage-limit provider" || {
  cat "$PROVIDER_STDOUT" >&2 || true
  fail "usage-limit provider did not become ready"
}

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

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
scripts/simulate-fresh-user.sh restore "$BACKUP_DIR" >/dev/null || {
  echo "warning: state restore failed; restore manually with:" >&2
  echo "  scripts/simulate-fresh-user.sh restore \"$BACKUP_DIR\"" >&2
}
BACKUP_DIR=""

# INF-254 (D4): recap failure offers the same Switch model / Retry affordance
# as the live call, and retrying after switching models actually succeeds
# (unlike f16 above, whose mock keeps failing every model on purpose - this
# scenario needs one that starts failing and then answers once the request
# names the recovered model, so it reuses the exact same deterministic mock
# server with its new ATTACHE_SMOKE_PROVIDER_RECOVERY_MODEL knob instead of a
# second mock). The same run also exercises the plain-readback badge (spec
# item 2): the two demo cards' own per-event presentation hits the identical
# failing mock and falls back to plain readback with a classified category.
RECAP_NONCE="$(date +%Y%m%d%H%M%S)_$(uuidgen | tr '[:lower:]' '[:upper:]' | tr -d '-' | cut -c1-8)"
RECAP_MODEL="attache-recap-recovery-smoke"
RECAP_PORT="$(free_port)"
RECAP_PROVIDER_LOG="$TEMP_ROOT/recap-personality-provider.jsonl"
RECAP_PROVIDER_STDOUT="$TEMP_ROOT/recap-personality-provider.log"
: > "$RECAP_PROVIDER_LOG"
chmod 600 "$RECAP_PROVIDER_LOG"

echo "==> Starting deterministic recap recovery provider on 127.0.0.1:$RECAP_PORT"
ATTACHE_PERSONALITY_TWO_WAY_NONCE="$RECAP_NONCE" \
ATTACHE_PERSONALITY_TWO_WAY_PONG_TOKEN="ATTACHE_UNUSED_${RECAP_NONCE}" \
ATTACHE_PERSONALITY_TWO_WAY_PROVIDER_LOG="$RECAP_PROVIDER_LOG" \
ATTACHE_PERSONALITY_TWO_WAY_MODEL="$RECAP_MODEL" \
ATTACHE_PERSONALITY_TWO_WAY_PORT="$RECAP_PORT" \
ATTACHE_SMOKE_PROVIDER_ERROR=usage_limit \
ATTACHE_SMOKE_PROVIDER_RECOVERY_MODEL="$RECAP_MODEL" \
  python3 scripts/personality-two-way-smoke-server.py >"$RECAP_PROVIDER_STDOUT" 2>&1 &
SERVER_PID=$!

wait_for_ready "$RECAP_PROVIDER_LOG" "$SERVER_PID" "recap recovery provider" || {
  cat "$RECAP_PROVIDER_STDOUT" >&2 || true
  fail "recap recovery provider did not become ready"
}

echo "==> Switching Attaché to a fresh test profile for the recap scenario"
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

echo "==> Running Attaché recap recovery UI smoke"
SMOKE_ONLY=f17 \
SMOKE_KEEP_STATE=1 \
ATTACHE_DISABLE_TOPIC_TAGGING=1 \
ATTACHE_LLM_PROVIDER=ollama \
ATTACHE_LLM_BASE_URL="http://127.0.0.1:${RECAP_PORT}/v1" \
ATTACHE_RECAP_RECOVERY_PROVIDER_LOG="$RECAP_PROVIDER_LOG" \
ATTACHE_RECAP_RECOVERY_MODEL="$RECAP_MODEL" \
  scripts/ui-smoke.sh

echo "==> Recap recovery smoke passed"

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
scripts/simulate-fresh-user.sh restore "$BACKUP_DIR" >/dev/null || {
  echo "warning: state restore failed; restore manually with:" >&2
  echo "  scripts/simulate-fresh-user.sh restore \"$BACKUP_DIR\"" >&2
}
BACKUP_DIR=""

# INF-258 (D5): opt-in auto-fallback chain, conversation role only. Two
# deterministic mock providers run at once (unlike the scenarios above, which
# only ever need one): a primary that always returns HTTP 429 usage-limit
# (the same ATTACHE_SMOKE_PROVIDER_ERROR=usage_limit mechanism f16 uses
# above) and a fallback that always succeeds. With the toggle on and the
# chain naming the fallback, the live call must transparently retry on it,
# with no manual Switch model click, and announce the hop once.
FALLBACK_NONCE="$(date +%Y%m%d%H%M%S)_$(uuidgen | tr '[:lower:]' '[:upper:]' | tr -d '-' | cut -c1-8)"
FALLBACK_PRIMARY_MODEL="attache-fallback-primary-smoke"
FALLBACK_MODEL="attache-fallback-smoke"
FALLBACK_PRIMARY_PORT="$(free_port)"
FALLBACK_PORT="$(free_port)"
FALLBACK_PRIMARY_LOG="$TEMP_ROOT/fallback-primary-provider.jsonl"
FALLBACK_LOG="$TEMP_ROOT/fallback-provider.jsonl"
FALLBACK_PRIMARY_STDOUT="$TEMP_ROOT/fallback-primary.log"
FALLBACK_STDOUT="$TEMP_ROOT/fallback.log"
: > "$FALLBACK_PRIMARY_LOG"
: > "$FALLBACK_LOG"
chmod 600 "$FALLBACK_PRIMARY_LOG" "$FALLBACK_LOG"

echo "==> Starting deterministic always-failing primary provider on 127.0.0.1:$FALLBACK_PRIMARY_PORT"
ATTACHE_PERSONALITY_TWO_WAY_NONCE="${FALLBACK_NONCE}_primary" \
ATTACHE_PERSONALITY_TWO_WAY_PONG_TOKEN="ATTACHE_UNUSED_${FALLBACK_NONCE}_primary" \
ATTACHE_PERSONALITY_TWO_WAY_PROVIDER_LOG="$FALLBACK_PRIMARY_LOG" \
ATTACHE_PERSONALITY_TWO_WAY_MODEL="$FALLBACK_PRIMARY_MODEL" \
ATTACHE_PERSONALITY_TWO_WAY_PORT="$FALLBACK_PRIMARY_PORT" \
ATTACHE_SMOKE_PROVIDER_ERROR=usage_limit \
  python3 scripts/personality-two-way-smoke-server.py >"$FALLBACK_PRIMARY_STDOUT" 2>&1 &
SERVER_PID=$!

wait_for_ready "$FALLBACK_PRIMARY_LOG" "$SERVER_PID" "always-failing primary provider" || {
  cat "$FALLBACK_PRIMARY_STDOUT" >&2 || true
  fail "always-failing primary provider did not become ready"
}

echo "==> Starting deterministic always-succeeding fallback provider on 127.0.0.1:$FALLBACK_PORT"
ATTACHE_PERSONALITY_TWO_WAY_NONCE="${FALLBACK_NONCE}_fallback" \
ATTACHE_PERSONALITY_TWO_WAY_PONG_TOKEN="ATTACHE_UNUSED_${FALLBACK_NONCE}_fallback" \
ATTACHE_PERSONALITY_TWO_WAY_PROVIDER_LOG="$FALLBACK_LOG" \
ATTACHE_PERSONALITY_TWO_WAY_MODEL="$FALLBACK_MODEL" \
ATTACHE_PERSONALITY_TWO_WAY_PORT="$FALLBACK_PORT" \
  python3 scripts/personality-two-way-smoke-server.py >"$FALLBACK_STDOUT" 2>&1 &
SERVER_PID_B=$!

wait_for_ready "$FALLBACK_LOG" "$SERVER_PID_B" "always-succeeding fallback provider" || {
  cat "$FALLBACK_STDOUT" >&2 || true
  fail "always-succeeding fallback provider did not become ready"
}

echo "==> Switching Attaché to a fresh test profile for the auto-fallback scenario"
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
# The auto-fallback chain itself (INF-258/D5): on, naming lmStudio as the one
# fallback entry. Both ollama (primary) and lmStudio (fallback) are always
# "configured" with no API key and never trip cloud consent (their endpoints
# are loopback), so this scenario needs no Integrations key and no
# consent-sheet setup, unlike a cloud provider chain would.
defaults write "$BUNDLE_ID" attache.conversationFallbackChainEnabled -bool true
defaults write "$BUNDLE_ID" attache.conversationFallbackChainProviders -array "lmStudio"
defaults write "$BUNDLE_ID" attache.lmStudioBaseURL -string "http://127.0.0.1:${FALLBACK_PORT}/v1"

echo "==> Running Attaché conversation auto-fallback UI smoke"
SMOKE_ONLY=f21 \
SMOKE_KEEP_STATE=1 \
ATTACHE_DISABLE_TOPIC_TAGGING=1 \
ATTACHE_LLM_PROVIDER=ollama \
ATTACHE_LLM_BASE_URL="http://127.0.0.1:${FALLBACK_PRIMARY_PORT}/v1" \
ATTACHE_CONVERSATION_FALLBACK_PROMPT="ATTACHE_CONVERSATION_FALLBACK $FALLBACK_NONCE" \
ATTACHE_CONVERSATION_FALLBACK_PRIMARY_LOG="$FALLBACK_PRIMARY_LOG" \
ATTACHE_CONVERSATION_FALLBACK_FALLBACK_LOG="$FALLBACK_LOG" \
  scripts/ui-smoke.sh

echo "==> Conversation auto-fallback smoke passed"

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
kill "$SERVER_PID_B" 2>/dev/null || true
wait "$SERVER_PID_B" 2>/dev/null || true
SERVER_PID_B=""
scripts/simulate-fresh-user.sh restore "$BACKUP_DIR" >/dev/null || {
  echo "warning: state restore failed; restore manually with:" >&2
  echo "  scripts/simulate-fresh-user.sh restore \"$BACKUP_DIR\"" >&2
}
BACKUP_DIR=""

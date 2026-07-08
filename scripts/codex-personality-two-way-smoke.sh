#!/usr/bin/env bash
set -euo pipefail

umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUNDLE_ID="com.bryanlabs.attache"
REAL_CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
TEMP_ROOT=""
BACKUP_DIR=""
SERVER_PID=""

usage() {
  cat <<EOF
Usage:
  scripts/codex-personality-two-way-smoke.sh

Creates a disposable Codex session, starts a deterministic local personality
provider, asks the personality to stage an instruction for Codex, confirms the
send, then asks the personality to read Codex's reply from the watched session.
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

command -v codex >/dev/null 2>&1 || fail "codex CLI was not found on PATH"
command -v python3 >/dev/null 2>&1 || fail "python3 was not found on PATH"
[[ -f "$REAL_CODEX_HOME/auth.json" ]] || fail "Codex auth file not found at $REAL_CODEX_HOME/auth.json"

TEMP_ROOT="$(mktemp -d /tmp/attache-codex-personality-two-way.XXXXXX)"
CODEX_TEST_HOME="$TEMP_ROOT/codex-home"
WORKDIR="$TEMP_ROOT/work"
PROVIDER_LOG="$TEMP_ROOT/personality-provider.jsonl"
PROVIDER_STDOUT="$TEMP_ROOT/personality-provider.log"
mkdir -p "$CODEX_TEST_HOME/sessions" "$CODEX_TEST_HOME/archived_sessions" "$CODEX_TEST_HOME/automations" "$WORKDIR"
: > "$CODEX_TEST_HOME/session_index.jsonl"
: > "$PROVIDER_LOG"
cp "$REAL_CODEX_HOME/auth.json" "$CODEX_TEST_HOME/auth.json"
chmod 600 "$CODEX_TEST_HOME/auth.json" "$CODEX_TEST_HOME/session_index.jsonl" "$PROVIDER_LOG"

cat > "$CODEX_TEST_HOME/config.toml" <<'EOF'
sandbox_mode = "read-only"
approval_policy = "never"
model_reasoning_effort = "low"
EOF
chmod 600 "$CODEX_TEST_HOME/config.toml"

NONCE="$(date +%Y%m%d%H%M%S)_$(uuidgen | tr '[:lower:]' '[:upper:]' | tr -d '-' | cut -c1-8)"
READY_TOKEN="ATTACHE_READY_${NONCE}"
PONG_TOKEN="ATTACHE_SUM_${NONCE}_4"
READY_LOG="$TEMP_ROOT/codex-ready.log"
READY_OUT="$TEMP_ROOT/codex-ready.txt"
MODEL="attache-smoke-personality"
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
ATTACHE_PERSONALITY_TWO_WAY_PONG_TOKEN="$PONG_TOKEN" \
ATTACHE_PERSONALITY_TWO_WAY_PROVIDER_LOG="$PROVIDER_LOG" \
ATTACHE_PERSONALITY_TWO_WAY_MODEL="$MODEL" \
ATTACHE_PERSONALITY_TWO_WAY_PORT="$PORT" \
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

echo "==> Creating disposable Codex session"
if ! CODEX_HOME="$CODEX_TEST_HOME" codex exec \
    -C "$WORKDIR" \
    --skip-git-repo-check \
    --ignore-rules \
    -o "$READY_OUT" \
    "Your entire final answer must be exactly: ${READY_TOKEN}. Do not use tools." \
    >"$READY_LOG" 2>&1; then
  cat "$READY_LOG" >&2
  fail "initial Codex session creation failed"
fi

if ! grep -q "$READY_TOKEN" "$READY_OUT"; then
  cat "$READY_LOG" >&2
  cat "$READY_OUT" >&2
  fail "initial Codex response did not contain $READY_TOKEN"
fi

SESSION_FILES=($(find "$CODEX_TEST_HOME/sessions" -type f -name '*.jsonl' | sort))
if [[ "${#SESSION_FILES[@]}" -ne 1 ]]; then
  find "$CODEX_TEST_HOME/sessions" -type f -name '*.jsonl' >&2 || true
  fail "expected exactly one disposable Codex session file, found ${#SESSION_FILES[@]}"
fi
SESSION_FILE="${SESSION_FILES[0]}"
SESSION_ID="$(basename "$SESSION_FILE" | sed -E 's/.*([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}).*/\1/' | tr '[:upper:]' '[:lower:]')"
[[ "$SESSION_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || fail "could not extract session id from $SESSION_FILE"

echo "==> Disposable Codex session: $SESSION_ID"

echo "==> Switching Attaché to a fresh test profile"
FRESH_OUTPUT="$(scripts/simulate-fresh-user.sh fresh)"
echo "$FRESH_OUTPUT"
BACKUP_DIR="$(printf '%s\n' "$FRESH_OUTPUT" | sed -n 's/^Backup: //p' | tail -1)"
[[ -n "$BACKUP_DIR" ]] || fail "could not determine Attaché backup dir"

defaults write "$BUNDLE_ID" attache.onboardingCompleted -bool true
defaults write "$BUNDLE_ID" attache.codexSourceEnabled -bool true
defaults write "$BUNDLE_ID" attache.claudeCodeSourceEnabled -bool false
defaults write "$BUNDLE_ID" attache.presentationLLMEnabled -bool true
defaults write "$BUNDLE_ID" attache.voicemailMode -bool true
defaults write "$BUNDLE_ID" attache.showActivityInsights -bool false
defaults write "$BUNDLE_ID" attache.showTips -bool false

echo "==> Running Attaché personality-to-Codex UI smoke"
SMOKE_ONLY=f8 \
SMOKE_KEEP_STATE=1 \
CODEX_HOME="$CODEX_TEST_HOME" \
ATTACHE_DISABLE_TOPIC_TAGGING=1 \
ATTACHE_FORCE_PLAIN_READBACK=1 \
ATTACHE_LLM_PROVIDER=ollama \
ATTACHE_LLM_BASE_URL="http://127.0.0.1:${PORT}/v1" \
ATTACHE_LLM_MODEL="$MODEL" \
ATTACHE_PERSONALITY_TWO_WAY_NONCE="$NONCE" \
ATTACHE_PERSONALITY_TWO_WAY_SESSION_ID="$SESSION_ID" \
ATTACHE_PERSONALITY_TWO_WAY_SESSION_FILE="$SESSION_FILE" \
ATTACHE_PERSONALITY_TWO_WAY_PROVIDER_LOG="$PROVIDER_LOG" \
ATTACHE_PERSONALITY_TWO_WAY_PONG_TOKEN="$PONG_TOKEN" \
  scripts/ui-smoke.sh

echo "==> Personality-to-Codex two-way smoke passed for session $SESSION_ID"

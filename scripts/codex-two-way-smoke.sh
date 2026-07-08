#!/usr/bin/env bash
set -euo pipefail

umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUNDLE_ID="com.bryanlabs.attache"
REAL_CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
TEMP_ROOT=""
BACKUP_DIR=""

usage() {
  cat <<EOF
Usage:
  scripts/codex-two-way-smoke.sh

Creates a disposable Codex session, runs the opt-in Attaché f7 UI smoke flow
against it, then restores Attaché state and removes the temporary Codex home.
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
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

command -v codex >/dev/null 2>&1 || fail "codex CLI was not found on PATH"
[[ -f "$REAL_CODEX_HOME/auth.json" ]] || fail "Codex auth file not found at $REAL_CODEX_HOME/auth.json"

TEMP_ROOT="$(mktemp -d /tmp/attache-codex-two-way.XXXXXX)"
CODEX_TEST_HOME="$TEMP_ROOT/codex-home"
WORKDIR="$TEMP_ROOT/work"
mkdir -p "$CODEX_TEST_HOME/sessions" "$CODEX_TEST_HOME/archived_sessions" "$CODEX_TEST_HOME/automations" "$WORKDIR"
: > "$CODEX_TEST_HOME/session_index.jsonl"
cp "$REAL_CODEX_HOME/auth.json" "$CODEX_TEST_HOME/auth.json"
chmod 600 "$CODEX_TEST_HOME/auth.json" "$CODEX_TEST_HOME/session_index.jsonl"

cat > "$CODEX_TEST_HOME/config.toml" <<'EOF'
sandbox_mode = "read-only"
approval_policy = "never"
model_reasoning_effort = "low"
EOF
chmod 600 "$CODEX_TEST_HOME/config.toml"

NONCE="$(date +%Y%m%d%H%M%S)_$(uuidgen | tr '[:lower:]' '[:upper:]' | tr -d '-' | cut -c1-8)"
READY_TOKEN="ATTACHE_READY_${NONCE}"
PONG_TOKEN="ATTACHE_PONG_${NONCE}"
READY_LOG="$TEMP_ROOT/codex-ready.log"
READY_OUT="$TEMP_ROOT/codex-ready.txt"

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
defaults write "$BUNDLE_ID" attache.presentationLLMEnabled -bool false
defaults write "$BUNDLE_ID" attache.voicemailMode -bool true
defaults write "$BUNDLE_ID" attache.showActivityInsights -bool false
defaults write "$BUNDLE_ID" attache.showTips -bool false

echo "==> Running Attaché Codex two-way UI smoke"
SMOKE_ONLY=f7 \
SMOKE_KEEP_STATE=1 \
CODEX_HOME="$CODEX_TEST_HOME" \
ATTACHE_CODEX_TWO_WAY_NONCE="$NONCE" \
ATTACHE_CODEX_TWO_WAY_SESSION_ID="$SESSION_ID" \
ATTACHE_CODEX_TWO_WAY_SESSION_FILE="$SESSION_FILE" \
ATTACHE_CODEX_TWO_WAY_PONG_TOKEN="$PONG_TOKEN" \
ATTACHE_CODEX_TWO_WAY_INSTRUCTION="reply exactly ${PONG_TOKEN} and do not use tools." \
  scripts/ui-smoke.sh

echo "==> Codex two-way smoke passed for session $SESSION_ID"

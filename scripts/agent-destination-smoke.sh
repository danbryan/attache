#!/usr/bin/env bash
set -euo pipefail

umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUNDLE_ID="com.bryanlabs.attache"
TEMP_ROOT=""
BACKUP_DIR=""
# INF-250: CLILanguageModel.candidatePath() checks "~/.local/bin/<name>" before
# any other location, and AgentResumeDeliveryAdapter's default locateExecutable
# resolves through it, not a caller-supplied PATH override. Installing the fake
# `codex` there (backed up and restored below) makes the packaged app's own
# delivery adapter spawn the fake CLI instead of any real one on this machine,
# so the second Tell Agent turn delivers for real with no live credentials.
LOCAL_BIN_DIR="$HOME/.local/bin"
LOCAL_BIN_CODEX="$LOCAL_BIN_DIR/codex"
FAKE_CODEX_BACKUP=""
FAKE_CODEX_INSTALLED=0

usage() {
  cat <<EOF
Usage:
  scripts/agent-destination-smoke.sh

Creates a disposable fake Codex session, configures Attaché with a text-only
CLI personality provider, switches the live conversation to Tell Agent, and
proves Attaché both (a) stages a raw instruction through the normal
confirmation UI and cancels it, and (b) stages, confirms, and delivers a
second instruction end to end against a fake `codex` CLI (INF-250).
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
  if [[ "$FAKE_CODEX_INSTALLED" == "1" ]]; then
    if [[ -n "$FAKE_CODEX_BACKUP" ]]; then
      cp -a "$FAKE_CODEX_BACKUP" "$LOCAL_BIN_CODEX" || {
        echo "warning: could not restore the real $LOCAL_BIN_CODEX; restore manually from $FAKE_CODEX_BACKUP" >&2
      }
    else
      rm -f "$LOCAL_BIN_CODEX"
    fi
    FAKE_CODEX_INSTALLED=0
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

TEMP_ROOT="$(mktemp -d /tmp/attache-agent-destination.XXXXXX)"
CODEX_TEST_HOME="$TEMP_ROOT/codex-home"
META_FILE="$TEMP_ROOT/fake-codex.json"
NONCE="$(date +%Y%m%d%H%M%S)_$(uuidgen | tr '[:lower:]' '[:upper:]' | tr -d '-' | cut -c1-8)"
TOKEN="ATTACHE_AGENT_MODE_$NONCE"
DELIVER_TOKEN="ATTACHE_AGENT_MODE_DELIVER_$NONCE"

python3 scripts/create-fake-codex-home.py \
  --home "$CODEX_TEST_HOME" \
  --nonce "$NONCE" \
  --count 1 \
  --target-title "Agent destination smoke $NONCE" \
  --needle "ATTACHE_AGENT_MODE_SEARCH_$NONCE" \
  > "$META_FILE"

SESSION_ID="$(json_field "$META_FILE" target_session_id)"
SESSION_FILE="$(json_field "$META_FILE" target_session_file)"
FAKE_CODEX_EXECUTABLE="$(json_field "$META_FILE" fake_codex_executable)"
[[ -n "$SESSION_ID" && -f "$SESSION_FILE" ]] || fail "fake Codex session was not created"
[[ -n "$FAKE_CODEX_EXECUTABLE" && -x "$FAKE_CODEX_EXECUTABLE" ]] || fail "fake codex executable was not created"

echo "==> Disposable agent-destination session: $SESSION_ID"
echo "==> Installing the fake codex CLI ahead of any real one on this machine"
mkdir -p "$LOCAL_BIN_DIR"
if [[ -e "$LOCAL_BIN_CODEX" || -L "$LOCAL_BIN_CODEX" ]]; then
  FAKE_CODEX_BACKUP="$TEMP_ROOT/codex.real-backup"
  cp -a "$LOCAL_BIN_CODEX" "$FAKE_CODEX_BACKUP"
fi
cp "$FAKE_CODEX_EXECUTABLE" "$LOCAL_BIN_CODEX"
chmod 700 "$LOCAL_BIN_CODEX"
FAKE_CODEX_INSTALLED=1

echo "==> Switching Attaché to a fresh text-only personality profile"
FRESH_OUTPUT="$(scripts/simulate-fresh-user.sh fresh)"
echo "$FRESH_OUTPUT"
BACKUP_DIR="$(printf '%s\n' "$FRESH_OUTPUT" | sed -n 's/^Backup: //p' | tail -1)"
[[ -n "$BACKUP_DIR" ]] || fail "could not determine Attaché backup dir"

defaults write "$BUNDLE_ID" attache.onboardingCompleted -bool true
defaults write "$BUNDLE_ID" attache.codexSourceEnabled -bool true
defaults write "$BUNDLE_ID" attache.claudeCodeSourceEnabled -bool false
defaults write "$BUNDLE_ID" attache.presentationLLMEnabled -bool true
defaults write "$BUNDLE_ID" attache.presentationLLMProvider -string "claude_cli"
defaults write "$BUNDLE_ID" attache.presentationLLMModel -string "sonnet"
defaults write "$BUNDLE_ID" attache.presentationLLMBaseURL -string "http://127.0.0.1:11434/v1"
defaults write "$BUNDLE_ID" attache.voicemailMode -bool true
defaults write "$BUNDLE_ID" attache.showActivityInsights -bool false
defaults write "$BUNDLE_ID" attache.showTips -bool false

echo "==> Running Attaché explicit agent destination UI smoke"
SMOKE_ONLY=f14 \
SMOKE_KEEP_STATE=1 \
CODEX_HOME="$CODEX_TEST_HOME" \
ATTACHE_DISABLE_TOPIC_TAGGING=1 \
ATTACHE_AGENT_MODE_NONCE="$NONCE" \
ATTACHE_AGENT_MODE_SESSION_ID="$SESSION_ID" \
ATTACHE_AGENT_MODE_SESSION_FILE="$SESSION_FILE" \
ATTACHE_AGENT_MODE_TOKEN="$TOKEN" \
ATTACHE_AGENT_MODE_PROMPT="reply exactly $TOKEN and do not use tools" \
ATTACHE_AGENT_MODE_DELIVER_TOKEN="$DELIVER_TOKEN" \
ATTACHE_AGENT_MODE_DELIVER_PROMPT="reply exactly $DELIVER_TOKEN and do not use tools" \
  scripts/ui-smoke.sh

echo "==> Agent destination smoke passed for session $SESSION_ID"

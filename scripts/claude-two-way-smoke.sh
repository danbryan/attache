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
  scripts/claude-two-way-smoke.sh

The Claude Code analog of scripts/codex-two-way-smoke.sh (f7/INF-257/E2).
Creates a disposable Claude Code session with the real 'claude' CLI, runs the
opt-in Attaché f21 UI smoke flow against it, then restores Attaché state and
removes the temporary Claude config dir.

Opt-in: does nothing unless ATTACHE_RELEASE_READINESS_WITH_CLAUDE=1 is set, so
it never breaks a machine (or a CI-style caller) without real Claude Code
credentials.
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

if [[ "${ATTACHE_RELEASE_READINESS_WITH_CLAUDE:-0}" != "1" ]]; then
  echo "SKIP: scripts/claude-two-way-smoke.sh requires ATTACHE_RELEASE_READINESS_WITH_CLAUDE=1 (opt-in real Claude Code round trip). Not set; skipping cleanly."
  exit 0
fi

trap cleanup EXIT

command -v claude >/dev/null 2>&1 || fail "claude CLI was not found on PATH"

# Unlike Codex (a plaintext ~/.codex/auth.json), the real Claude CLI's OAuth
# session on this machine lives in the macOS Keychain (service "Claude
# Code-credentials"). Some setups may instead have a plaintext
# ~/.claude/.credentials.json (the real CLI honors that first when present);
# support both, but either way, isolation copies ONLY the `claudeAiOauth`
# portion into the disposable config dir. The same Keychain/credentials blob
# can also carry unrelated MCP OAuth tokens (Slack, Notion, Linear, Google
# Workspace, etc.) that a headless `claude -p --resume` call never needs, so
# they are deliberately left out to shrink what the disposable directory ever
# holds.
TEMP_ROOT="$(mktemp -d /tmp/attache-claude-two-way.XXXXXX)"
CLAUDE_TEST_HOME="$TEMP_ROOT/claude-home"
WORKDIR="$TEMP_ROOT/work"
mkdir -p "$CLAUDE_TEST_HOME" "$WORKDIR"
chmod 700 "$CLAUDE_TEST_HOME"

REAL_CLAUDE_CREDENTIALS="$HOME/.claude/.credentials.json"
if [[ -f "$REAL_CLAUDE_CREDENTIALS" ]]; then
  python3 -c "
import json
with open('$REAL_CLAUDE_CREDENTIALS') as f:
    d = json.load(f)
if 'claudeAiOauth' not in d:
    raise SystemExit('real ~/.claude/.credentials.json has no claudeAiOauth key')
with open('$CLAUDE_TEST_HOME/.credentials.json', 'w') as out:
    json.dump({'claudeAiOauth': d['claudeAiOauth']}, out)
" || fail "could not read claudeAiOauth from $REAL_CLAUDE_CREDENTIALS"
else
  security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
if 'claudeAiOauth' not in d:
    raise SystemExit('Keychain \"Claude Code-credentials\" item has no claudeAiOauth key')
with open('$CLAUDE_TEST_HOME/.credentials.json', 'w') as out:
    json.dump({'claudeAiOauth': d['claudeAiOauth']}, out)
" || fail "no real Claude Code credentials found (checked $REAL_CLAUDE_CREDENTIALS and the macOS Keychain \"Claude Code-credentials\" item; run 'claude /login' once on this machine first)"
fi
[[ -s "$CLAUDE_TEST_HOME/.credentials.json" ]] || fail "failed to materialize disposable Claude Code credentials"
chmod 600 "$CLAUDE_TEST_HOME/.credentials.json"

NONCE="$(date +%Y%m%d%H%M%S)_$(uuidgen | tr '[:lower:]' '[:upper:]' | tr -d '-' | cut -c1-8)"
READY_TOKEN="ATTACHE_READY_${NONCE}"
PONG_TOKEN="ATTACHE_PONG_${NONCE}"
READY_OUT="$TEMP_ROOT/claude-ready.json"
READY_LOG="$TEMP_ROOT/claude-ready.log"

echo "==> Creating disposable Claude Code session"
if ! ( cd "$WORKDIR" && CLAUDE_CONFIG_DIR="$CLAUDE_TEST_HOME" claude -p \
    --output-format json \
    "Your entire final answer must be exactly: ${READY_TOKEN}. Do not use tools." \
    >"$READY_OUT" 2>"$READY_LOG" ); then
  cat "$READY_LOG" >&2
  cat "$READY_OUT" >&2
  fail "initial Claude Code session creation failed"
fi

# Same evidence contract AgentResumeDeliveryAdapter.claudeEvidence requires
# (INF-238/B1): type=="result", subtype=="success", is_error==false, and a
# non-empty result containing the ready token. Exit 0 alone is not proof.
SESSION_ID="$(python3 -c "
import json, sys
with open('$READY_OUT') as f:
    obj = json.load(f)
ok = (obj.get('type') == 'result' and obj.get('subtype') == 'success'
      and obj.get('is_error') is False and '$READY_TOKEN' in (obj.get('result') or ''))
if not ok:
    sys.exit(1)
print(obj.get('session_id') or '')
" 2>/dev/null || true)"
if [[ -z "$SESSION_ID" ]]; then
  cat "$READY_LOG" >&2
  cat "$READY_OUT" >&2
  fail "initial Claude response did not carry evidence of a completed turn containing $READY_TOKEN"
fi
[[ "$SESSION_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || fail "Claude response session_id was not a UUID: $SESSION_ID"
SESSION_ID="$(printf '%s' "$SESSION_ID" | tr '[:upper:]' '[:lower:]')"

SESSION_FILES=($(find "$CLAUDE_TEST_HOME/projects" -type f -iname "${SESSION_ID}.jsonl" | sort))
if [[ "${#SESSION_FILES[@]}" -ne 1 ]]; then
  find "$CLAUDE_TEST_HOME/projects" -type f -name '*.jsonl' >&2 || true
  fail "expected exactly one disposable Claude session file for $SESSION_ID, found ${#SESSION_FILES[@]}"
fi
SESSION_FILE="${SESSION_FILES[0]}"

echo "==> Disposable Claude Code session: $SESSION_ID"

echo "==> Switching Attaché to a fresh test profile"
FRESH_OUTPUT="$(scripts/simulate-fresh-user.sh fresh)"
echo "$FRESH_OUTPUT"
BACKUP_DIR="$(printf '%s\n' "$FRESH_OUTPUT" | sed -n 's/^Backup: //p' | tail -1)"
[[ -n "$BACKUP_DIR" ]] || fail "could not determine Attaché backup dir"

defaults write "$BUNDLE_ID" attache.onboardingCompleted -bool true
defaults write "$BUNDLE_ID" attache.claudeCodeSourceEnabled -bool true
defaults write "$BUNDLE_ID" attache.codexSourceEnabled -bool false
# Presentation is left enabled (the default) rather than forced off, mirroring
# codex-two-way-smoke.sh: reply correlation is positional now (INF-245/B2), so
# this gate is the proof that a personality paraphrase of the real Claude
# Code reply does not break linking the card back to the delivered
# instruction. A profile with no configured presentation provider still
# degrades to plain readback on its own; a real paraphrase run additionally
# needs a presentation provider configured on the machine running this gate.
defaults write "$BUNDLE_ID" attache.voicemailMode -bool true
defaults write "$BUNDLE_ID" attache.showActivityInsights -bool false
defaults write "$BUNDLE_ID" attache.showTips -bool false

echo "==> Running Attaché Claude Code two-way UI smoke"
SMOKE_ONLY=f21 \
SMOKE_KEEP_STATE=1 \
CLAUDE_CONFIG_DIR="$CLAUDE_TEST_HOME" \
ATTACHE_CLAUDE_TWO_WAY_NONCE="$NONCE" \
ATTACHE_CLAUDE_TWO_WAY_SESSION_ID="$SESSION_ID" \
ATTACHE_CLAUDE_TWO_WAY_SESSION_FILE="$SESSION_FILE" \
ATTACHE_CLAUDE_TWO_WAY_PONG_TOKEN="$PONG_TOKEN" \
ATTACHE_CLAUDE_TWO_WAY_INSTRUCTION="reply exactly ${PONG_TOKEN} and do not use tools." \
  scripts/ui-smoke.sh

echo "==> Claude Code two-way smoke passed for session $SESSION_ID"

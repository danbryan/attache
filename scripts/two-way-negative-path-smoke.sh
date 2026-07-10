#!/usr/bin/env bash
set -euo pipefail

umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUNDLE_ID="com.bryanlabs.attache"
TEMP_ROOT=""
BACKUP_DIR=""
KEEPALIVE_PID=""
# Mirrors scripts/agent-destination-smoke.sh: CLILanguageModel.candidatePath()
# checks "~/.local/bin/<name>" before any other location, and
# AgentResumeDeliveryAdapter's default locateExecutable resolves through it,
# not a caller-supplied PATH override, so shadowing the real `codex` means
# placing the fake one at this exact path for the duration of each phase.
LOCAL_BIN_DIR="$HOME/.local/bin"
LOCAL_BIN_CODEX="$LOCAL_BIN_DIR/codex"
FAKE_CODEX_BACKUP=""
FAKE_CODEX_INSTALLED=0

usage() {
  cat <<EOF
Usage:
  scripts/two-way-negative-path-smoke.sh

Runs the three two-way negative-path gates (INF-256/E4) against disposable
fake Codex sessions; no live Codex/Claude credentials required.

  Phase 1/3  delivery failure    fake codex exits nonzero; the failed status
                                  shows the stderr tail and the instruction is
                                  logged failed.
  Phase 2/3  expiry              a queued send against a session that never
                                  goes quiet visibly expires per a (test-
                                  shortened) ATTACHE_TWO_WAY_EXPIRY_SECONDS.
  Phase 3/3  restart fails closed the app is killed mid-send; on relaunch the
                                  startup recovery message shows and the
                                  instruction is logged failed.
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

stop_keepalive() {
  if [[ -n "$KEEPALIVE_PID" ]]; then
    kill "$KEEPALIVE_PID" 2>/dev/null || true
    wait "$KEEPALIVE_PID" 2>/dev/null || true
    KEEPALIVE_PID=""
  fi
}

restore_fake_codex() {
  if [[ "$FAKE_CODEX_INSTALLED" == "1" ]]; then
    if [[ -n "$FAKE_CODEX_BACKUP" ]]; then
      cp -a "$FAKE_CODEX_BACKUP" "$LOCAL_BIN_CODEX" || {
        echo "warning: could not restore the real $LOCAL_BIN_CODEX; restore manually from $FAKE_CODEX_BACKUP" >&2
      }
    else
      rm -f "$LOCAL_BIN_CODEX"
    fi
    FAKE_CODEX_INSTALLED=0
    FAKE_CODEX_BACKUP=""
  fi
}

restore_state() {
  if [[ -n "$BACKUP_DIR" ]]; then
    scripts/simulate-fresh-user.sh restore "$BACKUP_DIR" >/dev/null || {
      echo "warning: state restore failed; restore manually with:" >&2
      echo "  scripts/simulate-fresh-user.sh restore \"$BACKUP_DIR\"" >&2
    }
    BACKUP_DIR=""
  fi
}

cleanup() {
  pkill -f "$ROOT/dist/Attache.app/Contents/MacOS/Attache" 2>/dev/null || true
  # A restart-fails-closed phase can leave an orphaned hung fake `codex`
  # behind (its parent Attache process was killed out from under it); it
  # self-terminates once ATTACHE_FAKE_CODEX_HANG_SECONDS elapses regardless,
  # but there is no reason to wait for that.
  pkill -f "$LOCAL_BIN_CODEX exec resume" 2>/dev/null || true
  stop_keepalive
  restore_fake_codex
  restore_state
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
command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 was not found on PATH"

TEMP_ROOT="$(mktemp -d /tmp/attache-two-way-negative.XXXXXX)"
mkdir -p "$LOCAL_BIN_DIR"

install_fake_codex() {
  local executable="$1"
  if [[ -e "$LOCAL_BIN_CODEX" || -L "$LOCAL_BIN_CODEX" ]]; then
    FAKE_CODEX_BACKUP="$TEMP_ROOT/codex.real-backup"
    cp -a "$LOCAL_BIN_CODEX" "$FAKE_CODEX_BACKUP"
  fi
  cp "$executable" "$LOCAL_BIN_CODEX"
  chmod 700 "$LOCAL_BIN_CODEX"
  FAKE_CODEX_INSTALLED=1
}

fresh_profile() {
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
}

# Appends a harmless, valid Codex response_item line to $1 once a second so
# the transcript never satisfies TwoWayCoordinator's "no growth across the
# quiet window" readiness check: the send can never look idle, so expiry (not
# a race with delivery) is the only way the queued instruction resolves.
start_keepalive() {
  local file="$1"
  local nonce="$2"
  ( while true; do
      printf '{"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"keepalive %s %s"}]}}\n' "$nonce" "$(date +%s)" >> "$file"
      sleep 1
    done ) &
  KEEPALIVE_PID=$!
}

################################################################################
# Phase 1/3: delivery failure
################################################################################

echo ""
echo "==> Phase 1/3: delivery failure"

PHASE1_HOME="$TEMP_ROOT/codex-home-failure"
PHASE1_META="$TEMP_ROOT/fake-codex-failure.json"
NONCE1="$(date +%Y%m%d%H%M%S)_$(uuidgen | tr '[:lower:]' '[:upper:]' | tr -d '-' | cut -c1-8)"
TOKEN1="ATTACHE_TWO_WAY_FAILURE_$NONCE1"
STDERR1="fake codex delivery failure $NONCE1"

python3 scripts/create-fake-codex-home.py \
  --home "$PHASE1_HOME" \
  --nonce "$NONCE1" \
  --count 1 \
  --target-title "Two-way failure smoke $NONCE1" \
  --needle "ATTACHE_TWO_WAY_FAILURE_SEARCH_$NONCE1" \
  > "$PHASE1_META"

SESSION_ID1="$(json_field "$PHASE1_META" target_session_id)"
SESSION_FILE1="$(json_field "$PHASE1_META" target_session_file)"
FAKE_CODEX1="$(json_field "$PHASE1_META" fake_codex_executable)"
[[ -n "$SESSION_ID1" && -f "$SESSION_FILE1" ]] || fail "fake Codex session was not created (phase 1)"

install_fake_codex "$FAKE_CODEX1"
fresh_profile

echo "==> Running delivery-failure UI smoke for session $SESSION_ID1"
SMOKE_ONLY=f18 \
SMOKE_KEEP_STATE=1 \
CODEX_HOME="$PHASE1_HOME" \
ATTACHE_DISABLE_TOPIC_TAGGING=1 \
ATTACHE_FAKE_CODEX_MODE=exit_code \
ATTACHE_FAKE_CODEX_EXIT_CODE=7 \
ATTACHE_FAKE_CODEX_STDERR="$STDERR1" \
ATTACHE_TWO_WAY_FAILURE_NONCE="$NONCE1" \
ATTACHE_TWO_WAY_FAILURE_SESSION_ID="$SESSION_ID1" \
ATTACHE_TWO_WAY_FAILURE_SESSION_FILE="$SESSION_FILE1" \
ATTACHE_TWO_WAY_FAILURE_TOKEN="$TOKEN1" \
ATTACHE_TWO_WAY_FAILURE_PROMPT="reply exactly $TOKEN1 and do not use tools" \
ATTACHE_TWO_WAY_FAILURE_STDERR="$STDERR1" \
  scripts/ui-smoke.sh

restore_fake_codex
restore_state
echo "==> Phase 1/3 passed for session $SESSION_ID1"

################################################################################
# Phase 2/3: expiry
################################################################################

echo ""
echo "==> Phase 2/3: expiry"

PHASE2_HOME="$TEMP_ROOT/codex-home-expiry"
PHASE2_META="$TEMP_ROOT/fake-codex-expiry.json"
NONCE2="$(date +%Y%m%d%H%M%S)_$(uuidgen | tr '[:lower:]' '[:upper:]' | tr -d '-' | cut -c1-8)"
TOKEN2="ATTACHE_TWO_WAY_EXPIRY_$NONCE2"

python3 scripts/create-fake-codex-home.py \
  --home "$PHASE2_HOME" \
  --nonce "$NONCE2" \
  --count 1 \
  --target-title "Two-way expiry smoke $NONCE2" \
  --needle "ATTACHE_TWO_WAY_EXPIRY_SEARCH_$NONCE2" \
  > "$PHASE2_META"

SESSION_ID2="$(json_field "$PHASE2_META" target_session_id)"
SESSION_FILE2="$(json_field "$PHASE2_META" target_session_file)"
FAKE_CODEX2="$(json_field "$PHASE2_META" fake_codex_executable)"
[[ -n "$SESSION_ID2" && -f "$SESSION_FILE2" ]] || fail "fake Codex session was not created (phase 2)"

# A codex CLI must still resolve (default/success mode is fine, it is never
# actually invoked): capability(forSessionID:) fails closed immediately with
# "CLI not found" if none is installed, which would make this an accidental
# missing-CLI test instead of an expiry test.
install_fake_codex "$FAKE_CODEX2"
fresh_profile
start_keepalive "$SESSION_FILE2" "$NONCE2"

echo "==> Running expiry UI smoke for session $SESSION_ID2"
SMOKE_ONLY=f19 \
SMOKE_KEEP_STATE=1 \
CODEX_HOME="$PHASE2_HOME" \
ATTACHE_DISABLE_TOPIC_TAGGING=1 \
ATTACHE_TWO_WAY_EXPIRY_SECONDS=3 \
ATTACHE_TWO_WAY_EXPIRY_NONCE="$NONCE2" \
ATTACHE_TWO_WAY_EXPIRY_SESSION_ID="$SESSION_ID2" \
ATTACHE_TWO_WAY_EXPIRY_SESSION_FILE="$SESSION_FILE2" \
ATTACHE_TWO_WAY_EXPIRY_TOKEN="$TOKEN2" \
ATTACHE_TWO_WAY_EXPIRY_PROMPT="reply exactly $TOKEN2 and do not use tools" \
  scripts/ui-smoke.sh

stop_keepalive
restore_fake_codex
restore_state
echo "==> Phase 2/3 passed for session $SESSION_ID2"

################################################################################
# Phase 3/3: restart fails closed
################################################################################

echo ""
echo "==> Phase 3/3: restart fails closed"

PHASE3_HOME="$TEMP_ROOT/codex-home-restart"
PHASE3_META="$TEMP_ROOT/fake-codex-restart.json"
NONCE3="$(date +%Y%m%d%H%M%S)_$(uuidgen | tr '[:lower:]' '[:upper:]' | tr -d '-' | cut -c1-8)"
TOKEN3="ATTACHE_TWO_WAY_RESTART_$NONCE3"

python3 scripts/create-fake-codex-home.py \
  --home "$PHASE3_HOME" \
  --nonce "$NONCE3" \
  --count 1 \
  --target-title "Two-way restart smoke $NONCE3" \
  --needle "ATTACHE_TWO_WAY_RESTART_SEARCH_$NONCE3" \
  > "$PHASE3_META"

SESSION_ID3="$(json_field "$PHASE3_META" target_session_id)"
SESSION_FILE3="$(json_field "$PHASE3_META" target_session_file)"
FAKE_CODEX3="$(json_field "$PHASE3_META" fake_codex_executable)"
[[ -n "$SESSION_ID3" && -f "$SESSION_FILE3" ]] || fail "fake Codex session was not created (phase 3)"

install_fake_codex "$FAKE_CODEX3"
fresh_profile

echo "==> Running restart-fails-closed UI smoke for session $SESSION_ID3"
SMOKE_ONLY=f20 \
SMOKE_KEEP_STATE=1 \
CODEX_HOME="$PHASE3_HOME" \
ATTACHE_DISABLE_TOPIC_TAGGING=1 \
ATTACHE_FAKE_CODEX_MODE=hang \
ATTACHE_FAKE_CODEX_HANG_SECONDS=90 \
ATTACHE_TWO_WAY_RESTART_NONCE="$NONCE3" \
ATTACHE_TWO_WAY_RESTART_SESSION_ID="$SESSION_ID3" \
ATTACHE_TWO_WAY_RESTART_SESSION_FILE="$SESSION_FILE3" \
ATTACHE_TWO_WAY_RESTART_TOKEN="$TOKEN3" \
ATTACHE_TWO_WAY_RESTART_PROMPT="reply exactly $TOKEN3 and do not use tools" \
  scripts/ui-smoke.sh

restore_fake_codex
restore_state
echo "==> Phase 3/3 passed for session $SESSION_ID3"

echo ""
echo "==> Two-way negative-path smoke passed (delivery failure, expiry, restart fails closed)"

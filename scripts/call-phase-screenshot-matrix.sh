#!/usr/bin/env bash
set -euo pipefail

umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Screenshot matrix for the on-call composer's seven CallPhase states
# (INF-244's outstanding success criterion: "Attach a screenshot matrix to
# this ticket: thinking / preparing audio / speaking / send queued /
# delivered / failed / listening"). Every state is driven through a
# deterministic local fixture (a mock OpenAI-compatible personality
# provider, a fake `codex` CLI shadow, or the ATTACHE_UI_TEST_FORCE_LISTENING
# test-only mic override) so this never depends on real network access, a
# hosted provider, or live Codex/Claude credentials.
#
# Usage:
#   scripts/call-phase-screenshot-matrix.sh
#
# Produces (or reports which are missing and why):
#   dist/screenshots/call-phase-thinking.png
#   dist/screenshots/call-phase-preparingaudio.png
#   dist/screenshots/call-phase-speaking.png
#   dist/screenshots/call-phase-sendqueued.png
#   dist/screenshots/call-phase-senddelivered.png
#   dist/screenshots/call-phase-failed.png
#   dist/screenshots/call-phase-listening.png

BUNDLE_ID="com.bryanlabs.attache"
TEMP_ROOT=""
BACKUP_DIR=""
SERVER_PID=""
KEEPALIVE_PID=""
# Mirrors scripts/two-way-negative-path-smoke.sh: CLILanguageModel.candidatePath()
# checks "~/.local/bin/<name>" before any other location, so shadowing the
# real `codex` means placing the fake one at this exact path for the
# duration of the sendQueued/sendDelivered phases only.
LOCAL_BIN_DIR="$HOME/.local/bin"
LOCAL_BIN_CODEX="$LOCAL_BIN_DIR/codex"
FAKE_CODEX_BACKUP=""
FAKE_CODEX_INSTALLED=0

SCREENSHOT_DIR="$ROOT/dist/screenshots"
FAILED_PHASES=()
CAPTURED_PHASES=()

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
    if grep -q '"event": "ready"' "$log" 2>/dev/null; then
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    sleep 0.1
  done
  return 1
}

stop_server() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
}

stop_keepalive() {
  if [[ -n "$KEEPALIVE_PID" ]]; then
    kill "$KEEPALIVE_PID" 2>/dev/null || true
    wait "$KEEPALIVE_PID" 2>/dev/null || true
    KEEPALIVE_PID=""
  fi
}

# Appends a harmless, valid Codex response_item line to $1 once a second so
# the transcript never satisfies TwoWayCoordinator's "no growth across the
# quiet window" readiness check: the confirmed instruction can never look
# idle enough to dispatch, so it stays queued for the whole hold instead of
# racing to delivery. Exact mechanism as scripts/two-way-negative-path-smoke.sh
# phase 2 (expiry).
start_keepalive() {
  local file="$1"
  local nonce="$2"
  ( while true; do
      printf '{"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"keepalive %s %s"}]}}\n' "$nonce" "$(date +%s)" >> "$file"
      sleep 1
    done ) &
  KEEPALIVE_PID=$!
}

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
  stop_server
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
    echo "Usage: scripts/call-phase-screenshot-matrix.sh"
    exit 0
    ;;
  * )
    echo "Usage: scripts/call-phase-screenshot-matrix.sh" >&2
    exit 1
    ;;
esac

command -v python3 >/dev/null 2>&1 || fail "python3 was not found on PATH"
command -v uuidgen >/dev/null 2>&1 || fail "uuidgen was not found on PATH"
command -v screencapture >/dev/null 2>&1 || fail "screencapture was not found on PATH"

TEMP_ROOT="$(mktemp -d /tmp/attache-call-phase-matrix.XXXXXX)"
mkdir -p "$LOCAL_BIN_DIR" "$SCREENSHOT_DIR"

# Base profile every phase starts from; each phase overrides
# POSE_CODEX_ENABLED / POSE_PRESENTATION_ENABLED before calling this.
fresh_profile() {
  echo "==> Switching Attaché to a fresh test profile"
  FRESH_OUTPUT="$(scripts/simulate-fresh-user.sh fresh)"
  echo "$FRESH_OUTPUT"
  BACKUP_DIR="$(printf '%s\n' "$FRESH_OUTPUT" | sed -n 's/^Backup: //p' | tail -1)"
  [[ -n "$BACKUP_DIR" ]] || fail "could not determine Attaché backup dir"

  defaults write "$BUNDLE_ID" attache.onboardingCompleted -bool true
  defaults write "$BUNDLE_ID" attache.codexSourceEnabled -bool "${POSE_CODEX_ENABLED:-false}"
  defaults write "$BUNDLE_ID" attache.claudeCodeSourceEnabled -bool false
  defaults write "$BUNDLE_ID" attache.presentationLLMEnabled -bool "${POSE_PRESENTATION_ENABLED:-false}"
  defaults write "$BUNDLE_ID" attache.voicemailMode -bool true
  defaults write "$BUNDLE_ID" attache.showActivityInsights -bool false
  defaults write "$BUNDLE_ID" attache.showTips -bool false
}

# Launches the packaged app in the given SMOKE_POSE and screenshots it the
# moment the pose case's own AX wait succeeds (or fails). main.swift's pose
# block prints "posing <name> for <n>s" right after driving to the target
# state and right before the shared hold-sleep, or "pose failed: <error>"
# immediately if a step throws (no hold in that case) - polling the log for
# either string is a tight, low-race signal for exactly when to screenshot,
# rather than guessing a fixed delay.
run_pose_and_screenshot() {
  local phase_label="$1" smoke_pose="$2" hold_seconds="$3"
  local out_png="$SCREENSHOT_DIR/call-phase-${phase_label}.png"
  local log="$TEMP_ROOT/pose-${phase_label}.log"
  : > "$log"
  rm -f "$out_png"

  # The pose block in main.swift captures its own screenshot by CGWindowID
  # (ATTACHE_POSE_SCREENSHOT_PATH, see captureAppWindowScreenshot) the instant
  # it confirms the target state on screen, before the hold-sleep even
  # starts. This is strictly better than driving a screenshot from out here:
  # no separate osascript/System Events round trip that can hang (one did,
  # for long enough that a later manual kill landed mid fresh/restore cycle
  # and wiped the real Attaché profile with no backup of what was there), and
  # no full-screen capture that can grab whatever Space a human happens to be
  # looking at instead of Attaché's own window.
  echo "==> Posing ${smoke_pose} (hold ${hold_seconds}s) -> $log"
  ATTACHE_POSE_SCREENSHOT_PATH="$out_png" \
  SMOKE_POSE="$smoke_pose" SMOKE_POSE_SECONDS="$hold_seconds" SMOKE_KEEP_STATE=1 \
    scripts/ui-smoke.sh >"$log" 2>&1 &
  local pose_pid=$!

  local deadline=$((SECONDS + 150))
  local outcome="timeout"
  while (( SECONDS < deadline )); do
    if grep -q '^posing ' "$log" 2>/dev/null; then
      outcome="posed"
      break
    fi
    if grep -q '^pose failed:' "$log" 2>/dev/null; then
      outcome="failed"
      break
    fi
    if ! kill -0 "$pose_pid" 2>/dev/null; then
      outcome="exited"
      break
    fi
    sleep 0.2
  done

  # The screenshot file itself is the authoritative signal, not the log-poll
  # outcome: main.swift writes it synchronously (screencapture's
  # waitUntilExit finishes) before ever printing "posing", but reading a
  # background job's redirected log back through a separate `grep` can lag
  # that write by a beat. An "exited"/"timeout" outcome with the file already
  # on disk is a real capture, not a failure; give it one short grace check
  # before believing the outcome over the file.
  if [[ "$outcome" != "posed" && ! -s "$out_png" ]]; then
    sleep 0.5
  fi
  if [[ -s "$out_png" ]]; then
    echo "==> Captured $out_png"
    CAPTURED_PHASES+=("$phase_label")
  else
    echo "warning: pose '${smoke_pose}' did not produce a screenshot (outcome=${outcome}); see $log" >&2
    tail -n 20 "$log" >&2 || true
    FAILED_PHASES+=("$phase_label ($outcome)")
  fi

  wait "$pose_pid" 2>/dev/null || true
}

################################################################################
# Phase: listening
################################################################################
echo ""
echo "==> Phase: listening"
POSE_CODEX_ENABLED=false POSE_PRESENTATION_ENABLED=false fresh_profile
ATTACHE_DISABLE_TOPIC_TAGGING=1 \
ATTACHE_UI_TEST_FORCE_LISTENING=1 \
  run_pose_and_screenshot "listening" "call-listening" 8
restore_state

################################################################################
# Phase: thinking
################################################################################
echo ""
echo "==> Phase: thinking"
NONCE_TH="$(date +%Y%m%d%H%M%S)_$(uuidgen | tr '[:lower:]' '[:upper:]' | tr -d '-' | cut -c1-8)"
PORT_TH="$(free_port)"
LOG_TH="$TEMP_ROOT/provider-thinking.jsonl"
: > "$LOG_TH"; chmod 600 "$LOG_TH"

ATTACHE_PERSONALITY_TWO_WAY_NONCE="$NONCE_TH" \
ATTACHE_PERSONALITY_TWO_WAY_PONG_TOKEN="ATTACHE_UNUSED_${NONCE_TH}" \
ATTACHE_PERSONALITY_TWO_WAY_PROVIDER_LOG="$LOG_TH" \
ATTACHE_PERSONALITY_TWO_WAY_MODEL="attache-pose-thinking" \
ATTACHE_PERSONALITY_TWO_WAY_PORT="$PORT_TH" \
ATTACHE_SMOKE_PROVIDER_DELAY_MS=60000 \
  python3 scripts/personality-two-way-smoke-server.py >"$TEMP_ROOT/provider-thinking.log" 2>&1 &
SERVER_PID=$!
wait_for_ready "$LOG_TH" "$SERVER_PID" "thinking provider" || {
  cat "$TEMP_ROOT/provider-thinking.log" >&2 || true
  fail "thinking provider did not become ready"
}

POSE_CODEX_ENABLED=false POSE_PRESENTATION_ENABLED=true fresh_profile

ATTACHE_DISABLE_TOPIC_TAGGING=1 \
ATTACHE_LLM_PROVIDER=ollama \
ATTACHE_LLM_BASE_URL="http://127.0.0.1:${PORT_TH}/v1" \
ATTACHE_POSE_PROMPT="Attache pose thinking check ${NONCE_TH}" \
  run_pose_and_screenshot "thinking" "call-thinking" 10

stop_server
restore_state

################################################################################
# Phase: preparingAudio
################################################################################
echo ""
echo "==> Phase: preparingAudio"
NONCE_PA="$(date +%Y%m%d%H%M%S)_$(uuidgen | tr '[:lower:]' '[:upper:]' | tr -d '-' | cut -c1-8)"
PORT_PA="$(free_port)"
LOG_PA="$TEMP_ROOT/provider-preparingaudio.jsonl"
: > "$LOG_PA"; chmod 600 "$LOG_PA"

ATTACHE_PERSONALITY_TWO_WAY_NONCE="$NONCE_PA" \
ATTACHE_PERSONALITY_TWO_WAY_PONG_TOKEN="ATTACHE_UNUSED_${NONCE_PA}" \
ATTACHE_PERSONALITY_TWO_WAY_PROVIDER_LOG="$LOG_PA" \
ATTACHE_PERSONALITY_TWO_WAY_MODEL="attache-pose-preparingaudio" \
ATTACHE_PERSONALITY_TWO_WAY_PORT="$PORT_PA" \
  python3 scripts/personality-two-way-smoke-server.py >"$TEMP_ROOT/provider-preparingaudio.log" 2>&1 &
SERVER_PID=$!
wait_for_ready "$LOG_PA" "$SERVER_PID" "preparingAudio provider" || {
  cat "$TEMP_ROOT/provider-preparingaudio.log" >&2 || true
  fail "preparingAudio provider did not become ready"
}

POSE_CODEX_ENABLED=false POSE_PRESENTATION_ENABLED=true fresh_profile

# ATTACHE_UI_TEST_AUDIO_PREP_DELAY_MS (SpeechPlaybackController, gated on
# ATTACHE_UI_TEST=1 which the driver always sets) holds isBusy/preparingAudio
# for a fixed, deterministic window instead of racing real TTS wall-clock
# time.
ATTACHE_DISABLE_TOPIC_TAGGING=1 \
ATTACHE_LLM_PROVIDER=ollama \
ATTACHE_LLM_BASE_URL="http://127.0.0.1:${PORT_PA}/v1" \
ATTACHE_UI_TEST_AUDIO_PREP_DELAY_MS=6000 \
ATTACHE_POSE_PROMPT="ATTACHE_CONVERSATION_FEEDBACK pose preparing audio ${NONCE_PA}" \
  run_pose_and_screenshot "preparingaudio" "call-preparingaudio" 10

stop_server
restore_state

################################################################################
# Phase: speaking
################################################################################
echo ""
echo "==> Phase: speaking"
NONCE_SP="$(date +%Y%m%d%H%M%S)_$(uuidgen | tr '[:lower:]' '[:upper:]' | tr -d '-' | cut -c1-8)"
PORT_SP="$(free_port)"
LOG_SP="$TEMP_ROOT/provider-speaking.jsonl"
: > "$LOG_SP"; chmod 600 "$LOG_SP"

ATTACHE_PERSONALITY_TWO_WAY_NONCE="$NONCE_SP" \
ATTACHE_PERSONALITY_TWO_WAY_PONG_TOKEN="ATTACHE_UNUSED_${NONCE_SP}" \
ATTACHE_PERSONALITY_TWO_WAY_PROVIDER_LOG="$LOG_SP" \
ATTACHE_PERSONALITY_TWO_WAY_MODEL="attache-pose-speaking" \
ATTACHE_PERSONALITY_TWO_WAY_PORT="$PORT_SP" \
  python3 scripts/personality-two-way-smoke-server.py >"$TEMP_ROOT/provider-speaking.log" 2>&1 &
SERVER_PID=$!
wait_for_ready "$LOG_SP" "$SERVER_PID" "speaking provider" || {
  cat "$TEMP_ROOT/provider-speaking.log" >&2 || true
  fail "speaking provider did not become ready"
}

POSE_CODEX_ENABLED=false POSE_PRESENTATION_ENABLED=true fresh_profile

ATTACHE_DISABLE_TOPIC_TAGGING=1 \
ATTACHE_LLM_PROVIDER=ollama \
ATTACHE_LLM_BASE_URL="http://127.0.0.1:${PORT_SP}/v1" \
ATTACHE_POSE_PROMPT="ATTACHE_CONVERSATION_FEEDBACK pose speaking ${NONCE_SP}" \
  run_pose_and_screenshot "speaking" "call-speaking" 10

stop_server
restore_state

################################################################################
# Phase: failed
################################################################################
echo ""
echo "==> Phase: failed"
NONCE_F="$(date +%Y%m%d%H%M%S)_$(uuidgen | tr '[:lower:]' '[:upper:]' | tr -d '-' | cut -c1-8)"
PORT_F="$(free_port)"
LOG_F="$TEMP_ROOT/provider-failed.jsonl"
: > "$LOG_F"; chmod 600 "$LOG_F"

ATTACHE_PERSONALITY_TWO_WAY_NONCE="$NONCE_F" \
ATTACHE_PERSONALITY_TWO_WAY_PONG_TOKEN="ATTACHE_UNUSED_${NONCE_F}" \
ATTACHE_PERSONALITY_TWO_WAY_PROVIDER_LOG="$LOG_F" \
ATTACHE_PERSONALITY_TWO_WAY_MODEL="attache-pose-failed" \
ATTACHE_PERSONALITY_TWO_WAY_PORT="$PORT_F" \
ATTACHE_SMOKE_PROVIDER_ERROR=usage_limit \
  python3 scripts/personality-two-way-smoke-server.py >"$TEMP_ROOT/provider-failed.log" 2>&1 &
SERVER_PID=$!
wait_for_ready "$LOG_F" "$SERVER_PID" "failed provider" || {
  cat "$TEMP_ROOT/provider-failed.log" >&2 || true
  fail "failed provider did not become ready"
}

POSE_CODEX_ENABLED=false POSE_PRESENTATION_ENABLED=true fresh_profile

ATTACHE_DISABLE_TOPIC_TAGGING=1 \
ATTACHE_LLM_PROVIDER=ollama \
ATTACHE_LLM_BASE_URL="http://127.0.0.1:${PORT_F}/v1" \
ATTACHE_POSE_PROMPT="Attache pose failure check ${NONCE_F}" \
  run_pose_and_screenshot "failed" "call-failed" 10

stop_server
restore_state

################################################################################
# Phase: sendQueued
################################################################################
echo ""
echo "==> Phase: sendQueued"
NONCE_SQ="$(date +%Y%m%d%H%M%S)_$(uuidgen | tr '[:lower:]' '[:upper:]' | tr -d '-' | cut -c1-8)"
TOKEN_SQ="ATTACHE_POSE_SENDQUEUED_${NONCE_SQ}"
HOME_SQ="$TEMP_ROOT/codex-home-sendqueued"
META_SQ="$TEMP_ROOT/fake-codex-sendqueued.json"

python3 scripts/create-fake-codex-home.py \
  --home "$HOME_SQ" \
  --nonce "$NONCE_SQ" \
  --count 1 \
  --target-title "Pose sendQueued $NONCE_SQ" \
  --needle "ATTACHE_POSE_SENDQUEUED_SEARCH_$NONCE_SQ" \
  > "$META_SQ"

SESSION_ID_SQ="$(json_field "$META_SQ" target_session_id)"
SESSION_FILE_SQ="$(json_field "$META_SQ" target_session_file)"
FAKE_CODEX_SQ="$(json_field "$META_SQ" fake_codex_executable)"
[[ -n "$SESSION_ID_SQ" && -f "$SESSION_FILE_SQ" ]] || fail "fake Codex session was not created (sendQueued)"

install_fake_codex "$FAKE_CODEX_SQ"
POSE_CODEX_ENABLED=true POSE_PRESENTATION_ENABLED=false fresh_profile
# Keep the target session's transcript growing so the confirmed instruction
# never looks idle enough to dispatch (see start_keepalive above): this is
# what keeps the state at sendQueued instead of racing straight to delivered.
start_keepalive "$SESSION_FILE_SQ" "$NONCE_SQ"

ATTACHE_DISABLE_TOPIC_TAGGING=1 \
CODEX_HOME="$HOME_SQ" \
ATTACHE_POSE_AGENT_NONCE="$NONCE_SQ" \
ATTACHE_POSE_AGENT_SESSION_ID="$SESSION_ID_SQ" \
ATTACHE_POSE_AGENT_TOKEN="$TOKEN_SQ" \
  run_pose_and_screenshot "sendqueued" "call-sendqueued" 10

stop_keepalive
restore_fake_codex
restore_state

################################################################################
# Phase: sendDelivered
################################################################################
echo ""
echo "==> Phase: sendDelivered"
NONCE_SD="$(date +%Y%m%d%H%M%S)_$(uuidgen | tr '[:lower:]' '[:upper:]' | tr -d '-' | cut -c1-8)"
TOKEN_SD="ATTACHE_POSE_SENDDELIVERED_${NONCE_SD}"
HOME_SD="$TEMP_ROOT/codex-home-senddelivered"
META_SD="$TEMP_ROOT/fake-codex-senddelivered.json"

python3 scripts/create-fake-codex-home.py \
  --home "$HOME_SD" \
  --nonce "$NONCE_SD" \
  --count 1 \
  --target-title "Pose sendDelivered $NONCE_SD" \
  --needle "ATTACHE_POSE_SENDDELIVERED_SEARCH_$NONCE_SD" \
  > "$META_SD"

SESSION_ID_SD="$(json_field "$META_SD" target_session_id)"
SESSION_FILE_SD="$(json_field "$META_SD" target_session_file)"
FAKE_CODEX_SD="$(json_field "$META_SD" fake_codex_executable)"
[[ -n "$SESSION_ID_SD" && -f "$SESSION_FILE_SD" ]] || fail "fake Codex session was not created (sendDelivered)"

install_fake_codex "$FAKE_CODEX_SD"
POSE_CODEX_ENABLED=true POSE_PRESENTATION_ENABLED=false fresh_profile
# No keepalive here: the default fake codex resolves the resume call quickly
# once invoked, delivering for real.

ATTACHE_DISABLE_TOPIC_TAGGING=1 \
CODEX_HOME="$HOME_SD" \
ATTACHE_POSE_AGENT_NONCE="$NONCE_SD" \
ATTACHE_POSE_AGENT_SESSION_ID="$SESSION_ID_SD" \
ATTACHE_POSE_AGENT_TOKEN="$TOKEN_SD" \
  run_pose_and_screenshot "senddelivered" "call-senddelivered" 8

restore_fake_codex
restore_state

################################################################################
# Summary
################################################################################
echo ""
echo "==> Screenshot matrix summary"
if (( ${#CAPTURED_PHASES[@]} > 0 )); then
  echo "Captured: ${CAPTURED_PHASES[*]}"
fi
if (( ${#FAILED_PHASES[@]} > 0 )); then
  echo "Did not reach target state: ${FAILED_PHASES[*]}" >&2
  exit 1
fi
echo "All seven call-phase screenshots captured under $SCREENSHOT_DIR"

#!/usr/bin/env bash
set -euo pipefail

umask 077

# Pet choreography demo (INF-271): drives REAL Codex and Claude Code sessions
# while Attaché watches them in pet mode, and records the window so every
# choreography beat is captured end to end: thinking, tool burst, response,
# narration with lip-sync, celebrate, blocked, and (after a relaunch with
# nothing pinned) sleep. Both agents run from disposable homes carrying only
# the credentials a headless turn needs, mirroring codex-two-way-smoke.sh and
# claude-two-way-smoke.sh. All captures are window-scoped by CGWindowID.
#
# Usage:
#   scripts/pet-choreography-demo.sh /path/to/output-dir
#
# Produces <output-dir>/pet-choreography-demo.mov plus the raw frames.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUNDLE_ID="com.bryanlabs.attache"
REAL_CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
OUT_DIR="${1:-}"
TEMP_ROOT=""
BACKUP_DIR=""
DRIVER_PID=""
RECORDER_FLAG=""

fail() { echo "error: $*" >&2; exit 1; }

LOG_STREAM_PID=""

cleanup() {
  [[ -n "$RECORDER_FLAG" ]] && rm -f "$RECORDER_FLAG"
  [[ -n "$LOG_STREAM_PID" ]] && kill "$LOG_STREAM_PID" 2>/dev/null || true
  [[ -n "$DRIVER_PID" ]] && kill "$DRIVER_PID" 2>/dev/null || true
  pkill -f "$ROOT/dist/Attache.app/Contents/MacOS/Attache" 2>/dev/null || true
  if [[ -n "$BACKUP_DIR" ]]; then
    scripts/simulate-fresh-user.sh restore "$BACKUP_DIR" >/dev/null || {
      echo "warning: state restore failed; restore manually with:" >&2
      echo "  scripts/simulate-fresh-user.sh restore \"$BACKUP_DIR\"" >&2
    }
    BACKUP_DIR=""
  fi
  [[ -n "$TEMP_ROOT" ]] && rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

[[ -n "$OUT_DIR" ]] || fail "usage: scripts/pet-choreography-demo.sh /path/to/output-dir"
rm -rf "$OUT_DIR/frames"
mkdir -p "$OUT_DIR/frames"
command -v codex >/dev/null 2>&1 || fail "codex CLI was not found on PATH"
command -v claude >/dev/null 2>&1 || fail "claude CLI was not found on PATH"
command -v ffmpeg >/dev/null 2>&1 || fail "ffmpeg was not found on PATH"
[[ -f "$REAL_CODEX_HOME/auth.json" ]] || fail "Codex auth file not found at $REAL_CODEX_HOME/auth.json"

echo "==> Building driver and app"
swift build >/dev/null
SIGN_APP=0 scripts/package-app.sh >/dev/null

TEMP_ROOT="$(mktemp -d /tmp/attache-pet-demo.XXXXXX)"
CODEX_TEST_HOME="$TEMP_ROOT/codex-home"
CLAUDE_TEST_HOME="$TEMP_ROOT/claude-home"
WORKDIR="$TEMP_ROOT/work"
mkdir -p "$CODEX_TEST_HOME/sessions" "$CODEX_TEST_HOME/archived_sessions" "$CODEX_TEST_HOME/automations" \
         "$CLAUDE_TEST_HOME" "$WORKDIR"
chmod 700 "$CLAUDE_TEST_HOME"
: > "$CODEX_TEST_HOME/session_index.jsonl"
cp "$REAL_CODEX_HOME/auth.json" "$CODEX_TEST_HOME/auth.json"
chmod 600 "$CODEX_TEST_HOME/auth.json" "$CODEX_TEST_HOME/session_index.jsonl"
cat > "$CODEX_TEST_HOME/config.toml" <<'EOF'
sandbox_mode = "read-only"
approval_policy = "never"
model_reasoning_effort = "low"
EOF
chmod 600 "$CODEX_TEST_HOME/config.toml"

REAL_CLAUDE_CREDENTIALS="$HOME/.claude/.credentials.json"
if [[ -f "$REAL_CLAUDE_CREDENTIALS" ]]; then
  python3 -c "
import json
with open('$REAL_CLAUDE_CREDENTIALS') as f: d = json.load(f)
with open('$CLAUDE_TEST_HOME/.credentials.json', 'w') as out:
    json.dump({'claudeAiOauth': d['claudeAiOauth']}, out)
" || fail "could not extract claudeAiOauth from $REAL_CLAUDE_CREDENTIALS"
else
  security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
with open('$CLAUDE_TEST_HOME/.credentials.json', 'w') as out:
    json.dump({'claudeAiOauth': d['claudeAiOauth']}, out)
" || fail "no Claude Code credentials found (run 'claude /login' once first)"
fi
chmod 600 "$CLAUDE_TEST_HOME/.credentials.json"

cat > "$WORKDIR/demo.txt" <<'EOF'
Attaché gives coding agents a voice. This demo file exists so the Claude
turn has something real to read before it asks its question.
EOF

NONCE="$(date +%H%M%S)"

echo "==> Creating disposable Codex session"
CODEX_HOME="$CODEX_TEST_HOME" codex exec -C "$WORKDIR" --skip-git-repo-check --ignore-rules \
  "Reply exactly: READY_${NONCE}. Do not use tools." >"$TEMP_ROOT/codex-ready.log" 2>&1 \
  || { cat "$TEMP_ROOT/codex-ready.log" >&2; fail "codex session creation failed"; }
CODEX_SESSION_FILE="$(find "$CODEX_TEST_HOME/sessions" -type f -name '*.jsonl' | head -1)"
[[ -n "$CODEX_SESSION_FILE" ]] || fail "no codex session file created"
CODEX_SESSION_ID="$(basename "$CODEX_SESSION_FILE" | sed -E 's/.*([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}).*/\1/' | tr '[:upper:]' '[:lower:]')"
echo "    codex session: $CODEX_SESSION_ID"

echo "==> Creating disposable Claude Code session"
( cd "$WORKDIR" && CLAUDE_CONFIG_DIR="$CLAUDE_TEST_HOME" claude -p --output-format json \
  "Reply exactly: READY_${NONCE}. Do not use tools." >"$TEMP_ROOT/claude-ready.json" 2>"$TEMP_ROOT/claude-ready.log" ) \
  || { cat "$TEMP_ROOT/claude-ready.log" >&2; fail "claude session creation failed"; }
CLAUDE_SESSION_ID="$(python3 -c "import json; print(json.load(open('$TEMP_ROOT/claude-ready.json'))['session_id'])" | tr '[:upper:]' '[:lower:]')"
echo "    claude session: $CLAUDE_SESSION_ID"

echo "==> Switching Attaché to a fresh test profile"
FRESH_OUTPUT="$(scripts/simulate-fresh-user.sh fresh)"
echo "$FRESH_OUTPUT"
BACKUP_DIR="$(printf '%s\n' "$FRESH_OUTPUT" | sed -n 's/^Backup: //p' | tail -1)"
[[ -n "$BACKUP_DIR" ]] || fail "could not determine Attaché backup dir"

defaults write "$BUNDLE_ID" attache.onboardingCompleted -bool true
defaults write "$BUNDLE_ID" attache.visualMode pet
defaults write "$BUNDLE_ID" attache.codexSourceEnabled -bool true
defaults write "$BUNDLE_ID" attache.claudeCodeSourceEnabled -bool true
defaults write "$BUNDLE_ID" attache.narrationDetail playByPlay
defaults write "$BUNDLE_ID" attache.showActivityInsights -bool false
defaults write "$BUNDLE_ID" attache.showTips -bool false

WATCHED_HEX="$(python3 -c "
import json, time
now = time.time() - 978307200
sessions = [
    {'id': '$CODEX_SESSION_ID', 'title': 'Demo Codex', 'updatedAt': now,
     'category': 'activeSession', 'sourceKind': 'codex'},
    {'id': '$CLAUDE_SESSION_ID', 'title': 'Demo Claude', 'updatedAt': now,
     'category': 'activeSession', 'sourceKind': 'claude_code'},
]
print(json.dumps(sessions, separators=(',', ':')).encode().hex())
")"
defaults write "$BUNDLE_ID" attache.watchedSessions -data "$WATCHED_HEX"

# Ground truth for the choreography beats: info-level breadcrumbs are not
# persisted by the unified log, so stream them live for the run's artifact.
LOG_PRED='subsystem == "com.bryanlabs.attache" AND category == "watcher"'
/usr/bin/log stream --level info --predicate "$LOG_PRED" > "$OUT_DIR/moments.log" 2>&1 &
LOG_STREAM_PID=$!

echo "==> Launching Attaché (pet mode, watching both sessions)"
CODEX_HOME="$CODEX_TEST_HOME" \
CLAUDE_CONFIG_DIR="$CLAUDE_TEST_HOME" \
ATTACHE_DISABLE_TOPIC_TAGGING=1 \
ATTACHE_FORCE_PLAIN_READBACK=1 \
SMOKE_POSE=play-selected-when-ready SMOKE_POSE_SECONDS=130 \
  .build/debug/AttacheUISmoke dist/Attache.app "$ROOT" >"$TEMP_ROOT/driver.log" 2>&1 &
DRIVER_PID=$!

cat > "$TEMP_ROOT/find-window.swift" <<'EOF'
import CoreGraphics
import Foundation
guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) else { exit(2) }
guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { exit(1) }
let wins = info.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
func area(_ e: [String: Any]) -> Double {
    let b = e[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (b["Width"] ?? 0) * (b["Height"] ?? 0)
}
if let best = wins.max(by: { area($0) < area($1) }), let n = best[kCGWindowNumber as String] as? Int { print(n) }
EOF
swiftc -O "$TEMP_ROOT/find-window.swift" -o "$TEMP_ROOT/find-window" 2>/dev/null || fail "could not build window helper"

APP_PID=""
for _ in $(seq 30); do APP_PID="$(pgrep -x Attache | head -1 || true)"; [[ -n "$APP_PID" ]] && break; sleep 1; done
[[ -n "$APP_PID" ]] || fail "app did not launch"
sleep 4
WINDOW_ID="$("$TEMP_ROOT/find-window" "$APP_PID" || true)"
[[ -n "$WINDOW_ID" ]] || fail "could not resolve the app window id"
echo "    app $APP_PID window $WINDOW_ID"

echo "==> Recording (window-scoped stills)"
RECORDER_FLAG="$TEMP_ROOT/recording"
touch "$RECORDER_FLAG"
(
  index=0
  while [[ -f "$RECORDER_FLAG" ]]; do
    index=$((index + 1))
    screencapture -x -o -l"$WINDOW_ID" "$(printf "$OUT_DIR/frames/f%04d.png" "$index")" 2>/dev/null || true
    sleep 0.15
  done
) &
RECORDER_JOB=$!
RECORD_STARTED_AT=$(date +%s)

sleep 4
echo "==> Codex turn: tool burst then answer (thinking, toolRunning, respond, narrate, celebrate)"
CODEX_HOME="$CODEX_TEST_HOME" codex exec resume --skip-git-repo-check --json "$CODEX_SESSION_ID" \
  "Run ls with your shell tool, then reply DONE in one sentence." \
  >"$TEMP_ROOT/codex-turn.log" 2>&1 || { tail -5 "$TEMP_ROOT/codex-turn.log" >&2; fail "codex demo turn failed"; }
echo "    codex turn complete"
find "$CODEX_TEST_HOME/sessions" -name '*.jsonl' -exec wc -l {} + | sed 's/^/    codex transcript: /'

# The turn-complete celebration fires when the session's attention settles
# (about 30 s after the last transcript record). Hold the stage open for it:
# starting the Claude turn immediately would end in blockedOnUser, a signal
# phase that queues the celebration past its shelf life.
echo "==> Waiting for the codex celebration window"
sleep 34

echo "==> Claude turn: read then a blocking question (thinking, toolRunning read, blocked)"
( cd "$WORKDIR" && CLAUDE_CONFIG_DIR="$CLAUDE_TEST_HOME" claude -p --resume "$CLAUDE_SESSION_ID" \
  --output-format json --allowedTools=Read \
  "Read demo.txt with your Read tool, then ask me exactly one short clarifying question about what tone the narration should take. End with the question." \
  >"$TEMP_ROOT/claude-turn.json" 2>"$TEMP_ROOT/claude-turn.log" ) \
  || { tail -5 "$TEMP_ROOT/claude-turn.log" >&2; fail "claude demo turn failed"; }
echo "    claude turn complete"

echo "==> Letting narration, celebrate, and blocked play out"
while kill -0 "$DRIVER_PID" 2>/dev/null; do sleep 2; done
DRIVER_PID=""

echo "==> Sleep segment: relaunch with nothing pinned"
pkill -f "$ROOT/dist/Attache.app/Contents/MacOS/Attache" 2>/dev/null || true
sleep 2
defaults delete "$BUNDLE_ID" attache.watchedSessions 2>/dev/null || true
ATTACHE_UI_TEST=1 ATTACHE_UI_TEST_MUTE_AUDIO=1 ATTACHE_DISABLE_TOPIC_TAGGING=1 \
  dist/Attache.app/Contents/MacOS/Attache >/dev/null 2>&1 &
SLEEP_APP=$!
sleep 6
SLEEP_WINDOW_ID="$("$TEMP_ROOT/find-window" "$SLEEP_APP" || true)"
if [[ -n "$SLEEP_WINDOW_ID" ]]; then
  for i in $(seq 30); do
    screencapture -x -o -l"$SLEEP_WINDOW_ID" "$(printf "$OUT_DIR/frames/sleep%03d.png" "$i")" 2>/dev/null || true
    sleep 0.3
  done
fi
kill "$SLEEP_APP" 2>/dev/null || true
rm -f "$RECORDER_FLAG"
wait "$RECORDER_JOB" 2>/dev/null || true
RECORD_SECONDS=$(( $(date +%s) - RECORD_STARTED_AT ))

echo "==> Assembling ${RECORD_SECONDS}s of frames"
FRAME_COUNT=$(ls "$OUT_DIR/frames" | wc -l | tr -d ' ')
FPS=$(python3 -c "print(max(1.5, round($FRAME_COUNT / max(1, $RECORD_SECONDS), 2)))")
( cd "$OUT_DIR/frames" && ls f*.png sleep*.png 2>/dev/null | sort > list.txt \
  && python3 -c "
lines = open('list.txt').read().split()
with open('concat.txt', 'w') as out:
    for name in lines:
        out.write(f\"file '{name}'\nduration {1/$FPS}\n\")
" )
ffmpeg -y -loglevel error -f concat -safe 0 -i "$OUT_DIR/frames/concat.txt" \
  -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2,fps=12" -c:v libx264 -pix_fmt yuv420p -crf 23 \
  -movflags +faststart "$OUT_DIR/pet-choreography-demo.mov"
rm -f "$OUT_DIR/frames/list.txt" "$OUT_DIR/frames/concat.txt"
kill "$LOG_STREAM_PID" 2>/dev/null || true
LOG_STREAM_PID=""
echo "==> Attention transitions and moments observed:"
grep -E "attention |companion moment" "$OUT_DIR/moments.log" | sed 's/.*Attache: //' || echo "    none captured"
echo "==> Demo recorded: $OUT_DIR/pet-choreography-demo.mov ($FRAME_COUNT frames over ${RECORD_SECONDS}s)"

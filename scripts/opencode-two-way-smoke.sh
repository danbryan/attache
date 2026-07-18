#!/usr/bin/env bash
set -euo pipefail

umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUNDLE_ID="com.bryanlabs.attache"
REAL_OPENCODE_DATA="$HOME/.local/share/opencode"
TEMP_ROOT=""
BACKUP_DIR=""

usage() {
  cat <<EOF
Usage:
  scripts/opencode-two-way-smoke.sh

The opencode analog of scripts/codex-two-way-smoke.sh (f7),
scripts/claude-two-way-smoke.sh (f21), and scripts/grok-two-way-smoke.sh (f23),
INF-395. Creates ONE disposable opencode session with the real 'opencode' CLI,
runs the opt-in Attaché f24 UI smoke flow against it
(opencode run --session <id> --format json), then restores Attaché state and
removes the throwaway session it created.

Isolation note: unlike Codex/Claude/Grok, the real 'opencode' CLI DOES honor a
home override. It reads its session database from \$XDG_DATA_HOME/opencode
(verified: 'opencode debug paths'). So this gate points XDG_DATA_HOME at a
UNIQUE temp directory for BOTH the CLI (session creation) AND the app (session
discovery, delivery, and its own spawned 'opencode run'), and copies only the
real auth.json into that temp data home so the model call authenticates. It
therefore NEVER reads, writes, resumes, or deletes the real
~/.local/share/opencode/opencode.db or any real session.

Opt-in: does nothing unless ATTACHE_RELEASE_READINESS_WITH_OPENCODE=1 is set.
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
  # Remove ONLY the disposable temp data home this run created. Guarded: must be
  # non-empty and under /tmp, never the real opencode data home.
  if [[ -n "$TEMP_ROOT" && "$TEMP_ROOT" == /tmp/attache-opencode-two-way.* && -d "$TEMP_ROOT" ]]; then
    rm -rf "$TEMP_ROOT"
  fi
  rm -rf "$ROOT/dist/Attache.app" "$ROOT/dist/_dmgwork"
}

case "${1:-}" in
  "" ) ;;
  -h|--help|help ) usage; exit 0 ;;
  * ) usage >&2; exit 1 ;;
esac

if [[ "${ATTACHE_RELEASE_READINESS_WITH_OPENCODE:-0}" != "1" ]]; then
  echo "SKIP: scripts/opencode-two-way-smoke.sh requires ATTACHE_RELEASE_READINESS_WITH_OPENCODE=1 (opt-in real opencode round trip). Not set; skipping cleanly."
  exit 0
fi

trap cleanup EXIT

command -v opencode >/dev/null 2>&1 || fail "opencode CLI was not found on PATH"
command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 CLI is required for this gate"
[[ -f "$REAL_OPENCODE_DATA/auth.json" ]] || fail "opencode auth not found at $REAL_OPENCODE_DATA/auth.json (run 'opencode auth login' once first)"

TEMP_ROOT="$(mktemp -d /tmp/attache-opencode-two-way.XXXXXX)"
# Isolated XDG_DATA_HOME: opencode's real data path becomes
# $DATA_HOME/opencode. Copy only auth.json in so the model call authenticates;
# config (providers/models) stays at ~/.config/opencode, untouched.
DATA_HOME="$TEMP_ROOT/xdg"
OPENCODE_DATA_DIR="$DATA_HOME/opencode"
mkdir -p "$OPENCODE_DATA_DIR"
cp "$REAL_OPENCODE_DATA/auth.json" "$OPENCODE_DATA_DIR/auth.json"
OPENCODE_DB="$OPENCODE_DATA_DIR/opencode.db"

mkdir -p "$TEMP_ROOT/work"
WORKDIR="$(cd "$TEMP_ROOT/work" && pwd -P)"

NONCE="$(date +%Y%m%d%H%M%S)_$(uuidgen | tr '[:lower:]' '[:upper:]' | tr -d '-' | cut -c1-8)"
READY_TOKEN="ATTACHE_READY_${NONCE}"
PONG_TOKEN="ATTACHE_PONG_${NONCE}"
READY_OUT="$TEMP_ROOT/opencode-ready.json"
READY_LOG="$TEMP_ROOT/opencode-ready.log"

echo "==> Creating disposable opencode session (Attaché smoke test) in isolated data home"
if ! ( cd "$WORKDIR" && XDG_DATA_HOME="$DATA_HOME" opencode run --format json \
    "Attaché two-way smoke ${NONCE}. Your entire final answer must be exactly: ${READY_TOKEN}. Do not use tools." \
    >"$READY_OUT" 2>"$READY_LOG" ); then
  cat "$READY_LOG" >&2
  cat "$READY_OUT" >&2
  fail "initial opencode session creation failed"
fi

[[ -f "$OPENCODE_DB" ]] || fail "expected opencode.db in the isolated data home at $OPENCODE_DB"

# The isolated DB holds exactly the one session we just created.
SESSION_ID="$(sqlite3 "$OPENCODE_DB" "SELECT id FROM session ORDER BY time_updated DESC LIMIT 1;" 2>/dev/null || true)"
[[ -n "$SESSION_ID" ]] || fail "could not locate the disposable opencode session id in $OPENCODE_DB"

READY_HITS="$(sqlite3 "$OPENCODE_DB" "SELECT COUNT(*) FROM part WHERE session_id='${SESSION_ID}' AND data LIKE '%${READY_TOKEN}%';" 2>/dev/null || echo 0)"
if [[ "${READY_HITS:-0}" -lt 1 ]] && ! grep -q "$READY_TOKEN" "$READY_OUT" 2>/dev/null; then
  cat "$READY_LOG" >&2
  cat "$READY_OUT" >&2
  fail "initial opencode response did not contain $READY_TOKEN"
fi

echo "==> Disposable opencode session: $SESSION_ID"

echo "==> Switching Attaché to a fresh test profile"
FRESH_OUTPUT="$(scripts/simulate-fresh-user.sh fresh)"
echo "$FRESH_OUTPUT"
BACKUP_DIR="$(printf '%s\n' "$FRESH_OUTPUT" | sed -n 's/^Backup: //p' | tail -1)"
[[ -n "$BACKUP_DIR" ]] || fail "could not determine Attaché backup dir"

defaults write "$BUNDLE_ID" attache.onboardingCompleted -bool true
defaults write "$BUNDLE_ID" attache.opencodeSourceEnabled -bool true
defaults write "$BUNDLE_ID" attache.codexSourceEnabled -bool false
defaults write "$BUNDLE_ID" attache.claudeCodeSourceEnabled -bool false
defaults write "$BUNDLE_ID" attache.grokBuildSourceEnabled -bool false
# Presentation is left enabled (the default), mirroring the Codex/Claude/Grok
# gates: reply correlation is positional (INF-245/B2), so this gate proves that
# a personality paraphrase of the real opencode reply still links the card back
# to the delivered instruction.
defaults write "$BUNDLE_ID" attache.voicemailMode -bool true
defaults write "$BUNDLE_ID" attache.showActivityInsights -bool false
defaults write "$BUNDLE_ID" attache.showTips -bool false

echo "==> Running Attaché opencode two-way UI smoke"
SMOKE_ONLY=f24 \
SMOKE_KEEP_STATE=1 \
XDG_DATA_HOME="$DATA_HOME" \
ATTACHE_OPENCODE_TWO_WAY_NONCE="$NONCE" \
ATTACHE_OPENCODE_TWO_WAY_SESSION_ID="$SESSION_ID" \
ATTACHE_OPENCODE_TWO_WAY_DB="$OPENCODE_DB" \
ATTACHE_OPENCODE_TWO_WAY_PONG_TOKEN="$PONG_TOKEN" \
ATTACHE_OPENCODE_TWO_WAY_INSTRUCTION="reply exactly ${PONG_TOKEN} and do not use tools." \
  scripts/ui-smoke.sh

echo "==> opencode two-way smoke passed for session $SESSION_ID"

#!/usr/bin/env bash
set -euo pipefail

umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUNDLE_ID="com.bryanlabs.attache"
REAL_GROK_HOME="$HOME/.grok"
GROK_SESSIONS="$REAL_GROK_HOME/sessions"
TEMP_ROOT=""
BACKUP_DIR=""
# Set only after we positively locate the throwaway session THIS run created,
# so cleanup can never delete a pre-existing (real) Grok session.
SESSION_DIR=""

usage() {
  cat <<EOF
Usage:
  scripts/grok-two-way-smoke.sh

The Grok Build analog of scripts/codex-two-way-smoke.sh (f7) and
scripts/claude-two-way-smoke.sh (f21), INF-394. Creates ONE disposable Grok
Build session with the real 'grok' CLI, runs the opt-in Attaché f23 UI smoke
flow against it (grok --resume <id> --output-format json -p), then restores
Attaché state and removes the throwaway session it created.

Isolation note: unlike CODEX_HOME / CLAUDE_CONFIG_DIR, the real 'grok' CLI has
no home override (verified: grok 0.1.219 documents only GROK_SANDBOX), so it
writes to the real ~/.grok. This gate therefore creates its session under a
UNIQUE temporary working directory, which makes its ~/.grok/sessions project
directory unambiguous to find and to clean up. It NEVER resumes, messages, or
deletes any pre-existing session.

Opt-in: does nothing unless ATTACHE_RELEASE_READINESS_WITH_GROK=1 is set, so it
never touches ~/.grok on a machine (or CI-style caller) that did not ask for the
real Grok Build round trip.
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
  # Remove ONLY the throwaway Grok session this run created. Guarded three ways:
  # SESSION_DIR must be non-empty, must live under ~/.grok/sessions, and its
  # basename must be a UUID. Never a blanket ~/.grok wipe.
  if [[ -n "$SESSION_DIR" && "$SESSION_DIR" == "$GROK_SESSIONS/"*/* \
        && "$(basename "$SESSION_DIR")" =~ ^[0-9a-fA-F-]{36}$ ]]; then
    local project_dir
    project_dir="$(dirname "$SESSION_DIR")"
    rm -rf "$SESSION_DIR"
    # Remove the project directory too, but only if it is now empty (i.e. we
    # created it and it held no other sessions).
    rmdir "$project_dir" 2>/dev/null || true
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

if [[ "${ATTACHE_RELEASE_READINESS_WITH_GROK:-0}" != "1" ]]; then
  echo "SKIP: scripts/grok-two-way-smoke.sh requires ATTACHE_RELEASE_READINESS_WITH_GROK=1 (opt-in real Grok Build round trip). Not set; skipping cleanly."
  exit 0
fi

trap cleanup EXIT

command -v grok >/dev/null 2>&1 || fail "grok CLI was not found on PATH"
[[ -f "$REAL_GROK_HOME/auth.json" ]] || fail "Grok auth file not found at $REAL_GROK_HOME/auth.json (run 'grok login' once on this machine first)"

TEMP_ROOT="$(mktemp -d /tmp/attache-grok-two-way.XXXXXX)"
mkdir -p "$TEMP_ROOT/work"
# Physical path (symlink-resolved) so it matches the cwd Grok records under
# ~/.grok/sessions/<percent-encoded-project>/.
WORKDIR="$(cd "$TEMP_ROOT/work" && pwd -P)"

NONCE="$(date +%Y%m%d%H%M%S)_$(uuidgen | tr '[:lower:]' '[:upper:]' | tr -d '-' | cut -c1-8)"
READY_TOKEN="ATTACHE_READY_${NONCE}"
PONG_TOKEN="ATTACHE_PONG_${NONCE}"
READY_OUT="$TEMP_ROOT/grok-ready.json"
READY_LOG="$TEMP_ROOT/grok-ready.log"

echo "==> Creating disposable Grok Build session (Attaché smoke test)"
if ! ( cd "$WORKDIR" && grok --output-format json -p \
    "Attaché two-way smoke test. Your entire final answer must be exactly: ${READY_TOKEN}. Do not use tools." \
    >"$READY_OUT" 2>"$READY_LOG" ); then
  cat "$READY_LOG" >&2
  cat "$READY_OUT" >&2
  fail "initial Grok session creation failed"
fi

# Locate OUR session: the project directory whose percent-decoded name equals
# this run's unique WORKDIR. That directory can only hold the single session we
# just created, so this never matches any of the user's real sessions.
if [[ -d "$GROK_SESSIONS" ]]; then
  while IFS= read -r proj; do
    decoded="$(python3 -c 'import urllib.parse,sys;print(urllib.parse.unquote(sys.argv[1]))' "$(basename "$proj")" 2>/dev/null || true)"
    if [[ "$decoded" == "$WORKDIR" ]]; then
      for cand in "$proj"/*/; do
        if [[ -f "${cand}chat_history.jsonl" ]]; then
          SESSION_DIR="${cand%/}"
          break
        fi
      done
    fi
  done < <(find "$GROK_SESSIONS" -mindepth 1 -maxdepth 1 -type d)
fi

[[ -n "$SESSION_DIR" ]] || fail "could not locate the disposable Grok session directory for $WORKDIR"
SESSION_FILE="$SESSION_DIR/chat_history.jsonl"
SESSION_ID="$(basename "$SESSION_DIR" | tr '[:upper:]' '[:lower:]')"
[[ "$SESSION_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || fail "Grok session directory name was not a UUID: $SESSION_ID"

if ! grep -q "$READY_TOKEN" "$SESSION_FILE" 2>/dev/null && ! grep -q "$READY_TOKEN" "$READY_OUT" 2>/dev/null; then
  cat "$READY_LOG" >&2
  cat "$READY_OUT" >&2
  fail "initial Grok response did not contain $READY_TOKEN"
fi

echo "==> Disposable Grok Build session: $SESSION_ID"

echo "==> Switching Attaché to a fresh test profile"
FRESH_OUTPUT="$(scripts/simulate-fresh-user.sh fresh)"
echo "$FRESH_OUTPUT"
BACKUP_DIR="$(printf '%s\n' "$FRESH_OUTPUT" | sed -n 's/^Backup: //p' | tail -1)"
[[ -n "$BACKUP_DIR" ]] || fail "could not determine Attaché backup dir"

defaults write "$BUNDLE_ID" attache.onboardingCompleted -bool true
defaults write "$BUNDLE_ID" attache.grokBuildSourceEnabled -bool true
defaults write "$BUNDLE_ID" attache.codexSourceEnabled -bool false
defaults write "$BUNDLE_ID" attache.claudeCodeSourceEnabled -bool false
# Presentation is left enabled (the default), mirroring the Codex/Claude gates:
# reply correlation is positional now (INF-245/B2), so this gate is the proof
# that a personality paraphrase of the real Grok Build reply does not break
# linking the card back to the delivered instruction.
defaults write "$BUNDLE_ID" attache.voicemailMode -bool true
defaults write "$BUNDLE_ID" attache.showActivityInsights -bool false
defaults write "$BUNDLE_ID" attache.showTips -bool false

echo "==> Running Attaché Grok Build two-way UI smoke"
SMOKE_ONLY=f23 \
SMOKE_KEEP_STATE=1 \
GROK_HOME="$REAL_GROK_HOME" \
ATTACHE_GROK_TWO_WAY_NONCE="$NONCE" \
ATTACHE_GROK_TWO_WAY_SESSION_ID="$SESSION_ID" \
ATTACHE_GROK_TWO_WAY_SESSION_FILE="$SESSION_FILE" \
ATTACHE_GROK_TWO_WAY_PONG_TOKEN="$PONG_TOKEN" \
ATTACHE_GROK_TWO_WAY_INSTRUCTION="reply exactly ${PONG_TOKEN} and do not use tools." \
  scripts/ui-smoke.sh

echo "==> Grok Build two-way smoke passed for session $SESSION_ID"

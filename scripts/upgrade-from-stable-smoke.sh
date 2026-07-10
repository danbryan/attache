#!/usr/bin/env bash
set -euo pipefail

umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Attache"
BUNDLE_ID="com.bryanlabs.attache"
TEMP_ROOT=""
BACKUP_DIR=""
STABLE_PID=""

usage() {
  cat <<EOF
Usage:
  scripts/upgrade-from-stable-smoke.sh

Builds a prior stable app from ATTACHE_STABLE_REF (default: origin/main) in an
isolated worktree, installs it into a temp Applications directory, seeds user
state through the stable app's real event server, installs the current candidate
over it, then proves the candidate still sees the pre-upgrade card and settings.
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

wait_for_token() {
  local token_file="$HOME/Library/Application Support/Attache/event-token"
  for _ in {1..80}; do
    [[ -s "$token_file" ]] && return 0
    sleep 0.25
  done
  return 1
}

stop_stable() {
  if [[ -n "$STABLE_PID" ]]; then
    kill "$STABLE_PID" 2>/dev/null || true
    wait "$STABLE_PID" 2>/dev/null || true
    STABLE_PID=""
  fi
}

cleanup() {
  stop_stable
  pkill -f "$ROOT/dist/Attache.app/Contents/MacOS/Attache" 2>/dev/null || true
  if [[ -n "$BACKUP_DIR" ]]; then
    scripts/simulate-fresh-user.sh restore "$BACKUP_DIR" >/dev/null || {
      echo "warning: state restore failed; restore manually with:" >&2
      echo "  scripts/simulate-fresh-user.sh restore \"$BACKUP_DIR\"" >&2
    }
    BACKUP_DIR=""
  fi
  if [[ -n "$TEMP_ROOT" ]]; then
    if [[ -d "$TEMP_ROOT/stable-worktree/.git" || -f "$TEMP_ROOT/stable-worktree/.git" ]]; then
      git worktree remove --force "$TEMP_ROOT/stable-worktree" >/dev/null 2>&1 || true
    fi
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

command -v git >/dev/null 2>&1 || fail "git was not found on PATH"
command -v python3 >/dev/null 2>&1 || fail "python3 was not found on PATH"

STABLE_REF="${ATTACHE_STABLE_REF:-origin/main}"
TEMP_ROOT="$(mktemp -d /tmp/attache-upgrade-smoke.XXXXXX)"
INSTALL_DIR="$TEMP_ROOT/Applications"
INSTALL_APP="$INSTALL_DIR/$APP_NAME.app"
STABLE_TREE="$TEMP_ROOT/stable-worktree"
mkdir -p "$INSTALL_DIR"

NONCE="$(date +%Y%m%d%H%M%S)_$(uuidgen | tr '[:lower:]' '[:upper:]' | tr -d '-' | cut -c1-8)"
SEEDED_TITLE="Upgrade smoke card $NONCE"

echo "==> Building current UI smoke driver"
swift build >/dev/null
DRIVER="$ROOT/.build/debug/AttacheUISmoke"
[[ -x "$DRIVER" ]] || fail "driver binary not found at $DRIVER"

echo "==> Switching Attaché to a fresh upgrade profile"
FRESH_OUTPUT="$(scripts/simulate-fresh-user.sh fresh)"
echo "$FRESH_OUTPUT"
BACKUP_DIR="$(printf '%s\n' "$FRESH_OUTPUT" | sed -n 's/^Backup: //p' | tail -1)"
[[ -n "$BACKUP_DIR" ]] || fail "could not determine Attaché backup dir"

defaults write "$BUNDLE_ID" attache.onboardingCompleted -bool true
defaults write "$BUNDLE_ID" attache.presentationLLMEnabled -bool false
defaults write "$BUNDLE_ID" attache.voicemailMode -bool true
defaults write "$BUNDLE_ID" attache.showActivityInsights -bool false
defaults write "$BUNDLE_ID" attache.showTips -bool false
defaults write "$BUNDLE_ID" attache.uiTextScale -float 1.2

echo "==> Building stable baseline from $STABLE_REF"
git worktree add --detach "$STABLE_TREE" "$STABLE_REF" >/dev/null
(
  cd "$STABLE_TREE"
  VERSION="${VERSION:-0.1.3}" BUILD_NUMBER=1000000001 SIGN_APP=0 NOTARIZE_APP=0 scripts/package-app.sh >/dev/null
)
STABLE_APP="$STABLE_TREE/dist/$APP_NAME.app"
[[ -d "$STABLE_APP" ]] || fail "stable app missing at $STABLE_APP"
cp -R "$STABLE_APP" "$INSTALL_APP"

echo "==> Launching stable baseline and seeding state"
ATTACHE_UI_TEST=1 ATTACHE_DISABLE_TOPIC_TAGGING=1 "$INSTALL_APP/Contents/MacOS/Attache" &
STABLE_PID="$!"
wait_for_token || fail "stable app did not write an event token"
EVENT_TITLE="$SEEDED_TITLE" \
EVENT_TEXT="This card was filed by the stable app before the upgrade." \
EXTERNAL_SESSION_ID="upgrade-smoke-$NONCE" \
  scripts/send-event.sh >/dev/null

# AppModel.receive(_:) processes an accepted event on an async Task and
# returns before it lands in SQLite (it posts 200 as soon as the event is
# queued, not once persisted), so poll instead of checking once immediately
# after send-event.sh returns, mirroring wait_for_token's own retry style.
wait_for_seeded_card() {
  for _ in {1..40}; do
    if python3 - "$HOME/Library/Application Support/Attache/Attache.sqlite" "$SEEDED_TITLE" <<'PY'
import sqlite3
import sys

db, title = sys.argv[1], sys.argv[2]
con = sqlite3.connect(db)
count = con.execute(
    "select count(*) from sessions where title = ?",
    (title,),
).fetchone()[0]
sys.exit(0 if count >= 1 else 1)
PY
    then
      return 0
    fi
    sleep 0.25
  done
  return 1
}
wait_for_seeded_card || fail "seeded card was not persisted by the stable app"

stop_stable
rm -rf "$INSTALL_APP"

echo "==> Building and installing current candidate over stable location"
VERSION="${VERSION:-0.1.3}" BUILD_NUMBER=2000000002 SIGN_APP=0 NOTARIZE_APP=0 INSTALL_TO_APPLICATIONS=1 INSTALL_DIR="$INSTALL_DIR" scripts/package-app.sh >/dev/null
[[ -d "$INSTALL_APP" ]] || fail "candidate install missing at $INSTALL_APP"

STABLE_BUILD="$(defaults read "$STABLE_APP/Contents/Info" CFBundleVersion)"
CANDIDATE_BUILD="$(defaults read "$INSTALL_APP/Contents/Info" CFBundleVersion)"
[[ "$CANDIDATE_BUILD" -gt "$STABLE_BUILD" ]] || fail "candidate build $CANDIDATE_BUILD is not greater than stable $STABLE_BUILD"

echo "==> Launching candidate and verifying pre-upgrade state"
SMOKE_ONLY=f13 \
ATTACHE_DISABLE_TOPIC_TAGGING=1 \
ATTACHE_UPGRADE_SEEDED_TITLE="$SEEDED_TITLE" \
  "$DRIVER" "$INSTALL_APP" "$ROOT"

echo "==> Upgrade-from-stable smoke passed: $STABLE_REF -> build $CANDIDATE_BUILD"

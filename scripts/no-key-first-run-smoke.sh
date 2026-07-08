#!/usr/bin/env bash
set -euo pipefail

umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BACKUP_DIR=""

usage() {
  cat <<EOF
Usage:
  scripts/no-key-first-run-smoke.sh

Runs a headed fresh-user smoke with no Attaché cloud API keys. It proves the
first-run path stays local by default, does not seed provider credentials, and
still files a normal voicemail card through the local event server.
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

echo "==> Switching Attaché to a fresh no-key profile"
FRESH_OUTPUT="$(scripts/simulate-fresh-user.sh fresh)"
echo "$FRESH_OUTPUT"
BACKUP_DIR="$(printf '%s\n' "$FRESH_OUTPUT" | sed -n 's/^Backup: //p' | tail -1)"
[[ -n "$BACKUP_DIR" ]] || fail "could not determine Attaché backup dir"

echo "==> Running Attaché no-key first-run UI smoke"
SMOKE_ONLY=f10 \
SMOKE_KEEP_STATE=1 \
ATTACHE_DISABLE_TOPIC_TAGGING=1 \
  scripts/ui-smoke.sh

echo "==> No-key first-run smoke passed"

#!/usr/bin/env bash
set -euo pipefail

ENDPOINT="${1:-http://127.0.0.1:7531/events}"
PROJECT_PATH="${PROJECT_PATH:-$(pwd)}"
# Overridable so hooks can post other event kinds, e.g. a Claude Code
# Notification hook sending EVENT_TYPE=needs_attention for exact
# waiting-on-you interrupts.
EVENT_TYPE="${EVENT_TYPE:-assistant.completed}"
EVENT_TITLE="${EVENT_TITLE:-Shell smoke update}"
EVENT_TEXT="${EVENT_TEXT:-Attaché accepted a local Codex-style event from the helper script. It should create an unread voicemail card with captions and replay.}"
EXTERNAL_SESSION_ID="${EXTERNAL_SESSION_ID:-shell-smoke}"
TOKEN_FILE="$HOME/Library/Application Support/Attache/event-token"

if [[ ! -f "$TOKEN_FILE" ]]; then
  echo "error: token file not found at $TOKEN_FILE" >&2
  echo "Launch Attaché once so it writes a per-launch token, then retry." >&2
  exit 1
fi
TOKEN="$(cat "$TOKEN_FILE")"

curl -sS -X POST "$ENDPOINT" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  --data-binary @- <<JSON
{
  "source": "codex",
  "event_type": "$EVENT_TYPE",
  "external_session_id": "$EXTERNAL_SESSION_ID",
  "project_path": "$PROJECT_PATH",
  "title": "$EVENT_TITLE",
  "text": "$EVENT_TEXT",
  "metadata": {
    "adapter": "shell",
    "cwd": "$PROJECT_PATH"
  }
}
JSON

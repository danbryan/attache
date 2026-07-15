#!/usr/bin/env bash
# Claude Code Notification hook -> Attaché needs-you interrupt.
#
# Claude Code fires the Notification hook exactly when it is waiting on you
# (a permission prompt or idle input). This forwards that moment to Attaché
# as an exact needs_attention event for the same session, so the Attaché
# can say "Claude is waiting on you" the second it happens. The notice
# clears automatically once the session's transcript moves again.
#
# Install (in ~/.claude/settings.json):
#   "hooks": {
#     "Notification": [
#       { "hooks": [ { "type": "command",
#           "command": "/path/to/attache/scripts/claude-notification-hook.sh" } ] }
#     ]
#   }
set -euo pipefail

HOOK_INPUT="$(cat)"

session_id="$(printf '%s' "$HOOK_INPUT" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("session_id",""))' 2>/dev/null || true)"
message="$(printf '%s' "$HOOK_INPUT" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("message",""))' 2>/dev/null || true)"

[[ -z "$session_id" ]] && exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

EVENT_TYPE=needs_attention \
EXTERNAL_SESSION_ID="$session_id" \
EVENT_TITLE="Claude Code" \
EVENT_TEXT="${message:-Claude Code is waiting on your input.}" \
"$SCRIPT_DIR/send-event.sh" >/dev/null 2>&1 || true

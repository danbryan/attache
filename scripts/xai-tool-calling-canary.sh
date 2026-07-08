#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() {
  cat <<EOF
Usage:
  scripts/xai-tool-calling-canary.sh

Checks the live xAI Chat Completions endpoint with Attaché's OpenAI-compatible
function-calling shape. This proves the xAI personality provider can request
Attaché's stage_agent_instruction tool and then produce a final reply after the
tool result.

Inputs:
  XAI_API_KEY or ATTACHE_LLM_API_KEY   xAI API key
  XAI_MODEL or ATTACHE_LLM_MODEL       optional model override (default: grok-4.3)
  XAI_BASE_URL or ATTACHE_LLM_BASE_URL optional endpoint (default: https://api.x.ai/v1)

If no key is in the environment, the script tries the local Attaché keychain
account com.bryanlabs.attache.secrets / xai-api-key. The key is never printed.
EOF
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

command -v python3 >/dev/null 2>&1 || {
  echo "error: python3 was not found on PATH" >&2
  exit 1
}

python3 - <<'PY'
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid


def first_nonempty(*values):
    for value in values:
        if value and value.strip():
            return value.strip()
    return ""


def read_keychain_key():
    if sys.platform != "darwin":
        return ""
    try:
        result = subprocess.run(
            [
                "security",
                "find-generic-password",
                "-w",
                "-s",
                "com.bryanlabs.attache.secrets",
                "-a",
                "xai-api-key",
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except Exception:
        return ""
    return result.stdout.strip()


api_key = first_nonempty(
    os.environ.get("XAI_API_KEY"),
    os.environ.get("ATTACHE_LLM_API_KEY"),
    os.environ.get("COMPANION_LLM_API_KEY"),
    read_keychain_key(),
)
if not api_key:
    print(
        "error: no xAI API key found in XAI_API_KEY, ATTACHE_LLM_API_KEY, or the local Attaché keychain account",
        file=sys.stderr,
    )
    sys.exit(2)

base_url = first_nonempty(
    os.environ.get("XAI_BASE_URL"),
    os.environ.get("ATTACHE_LLM_BASE_URL"),
    "https://api.x.ai/v1",
).rstrip("/")
model = first_nonempty(
    os.environ.get("XAI_MODEL"),
    os.environ.get("ATTACHE_LLM_MODEL"),
    "grok-4.3",
)

nonce = time.strftime("%Y%m%d%H%M%S") + "_" + uuid.uuid4().hex[:8].upper()
token = f"ATTACHE_XAI_TOOL_OK_{nonce}"
instruction = f"Reply exactly {token}. Do not use tools."

tools = [
    {
        "type": "function",
        "function": {
            "name": "stage_agent_instruction",
            "description": "Stage an instruction for the attached work agent. This opens Attaché's confirmation UI and does not send by itself.",
            "parameters": {
                "type": "object",
                "properties": {
                    "instruction": {
                        "type": "string",
                        "description": "The concise instruction to send to the work agent after the user confirms.",
                    }
                },
                "required": ["instruction"],
            },
        },
    }
]


def post_chat(messages, tools_payload=tools):
    payload = {
        "model": model,
        "temperature": 0,
        "messages": messages,
    }
    if tools_payload:
        payload["tools"] = tools_payload
    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        f"{base_url}/chat/completions",
        data=data,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        print(f"error: xAI HTTP {error.code}: {body[:500]}", file=sys.stderr)
        sys.exit(1)


messages = [
    {
        "role": "system",
        "content": "You are an Attaché smoke canary. Use stage_agent_instruction when the user asks you to ask Codex to do something.",
    },
    {
        "role": "user",
        "content": f"Ask Codex to reply with exactly {token}.",
    },
]

first = post_chat(messages)
message = (first.get("choices") or [{}])[0].get("message") or {}
tool_calls = message.get("tool_calls") or []
matching_call = None
for call in tool_calls:
    function = call.get("function") or {}
    if function.get("name") == "stage_agent_instruction":
        matching_call = call
        break

if not matching_call:
    print(
        f"error: xAI did not call stage_agent_instruction; response={json.dumps(message, sort_keys=True)[:1000]}",
        file=sys.stderr,
    )
    sys.exit(1)

arguments_text = (matching_call.get("function") or {}).get("arguments") or "{}"
try:
    arguments = json.loads(arguments_text)
except json.JSONDecodeError:
    print(f"error: tool arguments were not JSON: {arguments_text[:500]}", file=sys.stderr)
    sys.exit(1)

if token not in str(arguments.get("instruction", "")):
    print(
        f"error: stage_agent_instruction did not preserve nonce; arguments={json.dumps(arguments, sort_keys=True)}",
        file=sys.stderr,
    )
    sys.exit(1)

messages.append(message)
messages.append(
    {
        "role": "tool",
        "tool_call_id": matching_call["id"],
        "content": "Attaché opened the per-message confirmation sheet. The user must confirm before anything is sent to Codex.",
    }
)
final = post_chat(messages, tools_payload=None)
final_message = (final.get("choices") or [{}])[0].get("message") or {}
final_text = str(final_message.get("content") or "").strip()
if not final_text:
    print(f"error: xAI final reply was empty; response={json.dumps(final_message, sort_keys=True)[:1000]}", file=sys.stderr)
    sys.exit(1)

print(f"PASS xAI tool-calling canary: model={model} tool=stage_agent_instruction nonce={token}")
PY

#!/usr/bin/env python3
import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid


SKIP_EXIT = 77


def first_nonempty(*values):
    for value in values:
        if value and value.strip():
            return value.strip()
    return ""


def split_env(name):
    return [part.strip() for part in os.environ.get(name, "").split(",") if part.strip()]


def read_keychain_key(accounts):
    if sys.platform != "darwin":
        return ""
    for account in accounts:
        try:
            result = subprocess.run(
                [
                    "security",
                    "find-generic-password",
                    "-w",
                    "-s",
                    "com.bryanlabs.attache.secrets",
                    "-a",
                    account,
                ],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
            )
        except Exception:
            continue
        value = result.stdout.strip()
        if value:
            return value
    return ""


def skip(message):
    print(f"SKIP {message}")
    sys.exit(SKIP_EXIT)


provider = os.environ.get("CANARY_PROVIDER_NAME", "OpenAI-compatible")
allow_skip = os.environ.get("CANARY_ALLOW_SKIP", "0") == "1"
requires_key = os.environ.get("CANARY_REQUIRES_API_KEY", "1") == "1"
key_env_names = split_env("CANARY_KEY_ENV_NAMES")
keychain_accounts = split_env("CANARY_KEYCHAIN_ACCOUNTS")
key = first_nonempty(*(os.environ.get(name) for name in key_env_names), read_keychain_key(keychain_accounts))

if requires_key and not key:
    message = f"{provider} canary has no API key"
    if allow_skip:
        skip(message)
    print(f"error: {message}", file=sys.stderr)
    sys.exit(2)

base_url = first_nonempty(os.environ.get("CANARY_BASE_URL"), "http://127.0.0.1:11434/v1").rstrip("/")
model = first_nonempty(os.environ.get("CANARY_MODEL"), "qwen3:7b")
nonce = first_nonempty(os.environ.get("CANARY_NONCE"), time.strftime("%Y%m%d%H%M%S") + "_" + uuid.uuid4().hex[:8].upper())
token = first_nonempty(os.environ.get("CANARY_EXPECTED_TOKEN"), f"ATTACHE_TOOL_OK_{nonce}")
instruction = f"Reply exactly {token}. Do not use tools."
user_prompt = first_nonempty(os.environ.get("CANARY_USER_PROMPT"), f"Ask Codex to reply with exactly {token}.")
system_prompt = first_nonempty(
    os.environ.get("CANARY_SYSTEM_PROMPT"),
    "You are an Attaché smoke canary. Use stage_agent_instruction when the user asks you to ask Codex to do something.",
)

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


def request_headers():
    headers = {"Content-Type": "application/json"}
    if key:
        headers["Authorization"] = f"Bearer {key}"
    return headers


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
        headers=request_headers(),
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        if allow_skip and requires_key and error.code in (401, 403, 429):
            skip(f"{provider} canary credential/account unavailable: HTTP {error.code}")
        if allow_skip and error.code in (400, 404) and not requires_key:
            skip(f"{provider} canary endpoint/model unavailable: HTTP {error.code}")
        print(f"error: {provider} HTTP {error.code}: {body[:700]}", file=sys.stderr)
        sys.exit(1)
    except (urllib.error.URLError, TimeoutError, socket.timeout) as error:
        if allow_skip and not requires_key:
            skip(f"{provider} canary endpoint unavailable: {error}")
        print(f"error: {provider} request failed: {error}", file=sys.stderr)
        sys.exit(1)


messages = [
    {"role": "system", "content": system_prompt},
    {"role": "user", "content": user_prompt},
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
        f"error: {provider} did not call stage_agent_instruction; response={json.dumps(message, sort_keys=True)[:1200]}",
        file=sys.stderr,
    )
    sys.exit(1)

arguments_text = (matching_call.get("function") or {}).get("arguments") or "{}"
try:
    arguments = json.loads(arguments_text)
except json.JSONDecodeError:
    print(f"error: {provider} tool arguments were not JSON: {arguments_text[:700]}", file=sys.stderr)
    sys.exit(1)

if token not in str(arguments.get("instruction", "")):
    print(
        f"error: {provider} stage_agent_instruction did not preserve nonce; arguments={json.dumps(arguments, sort_keys=True)}",
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
    print(f"error: {provider} final reply was empty; response={json.dumps(final_message, sort_keys=True)[:1200]}", file=sys.stderr)
    sys.exit(1)

print(f"PASS {provider} tool-calling canary: model={model} tool=stage_agent_instruction nonce={token}")

#!/usr/bin/env python3
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


NONCE = os.environ["ATTACHE_PERSONALITY_TWO_WAY_NONCE"]
PONG_TOKEN = os.environ["ATTACHE_PERSONALITY_TWO_WAY_PONG_TOKEN"]
LOG_PATH = os.environ["ATTACHE_PERSONALITY_TWO_WAY_PROVIDER_LOG"]
MODEL = os.environ.get("ATTACHE_PERSONALITY_TWO_WAY_MODEL", "attache-smoke-personality")
RESPONSE_DELAY_MS = int(os.environ.get("ATTACHE_SMOKE_PROVIDER_DELAY_MS", "0") or "0")


def log(event):
    with open(LOG_PATH, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, sort_keys=True) + "\n")


def response(message):
    body = {
        "id": f"chatcmpl-attache-{NONCE}",
        "object": "chat.completion",
        "model": MODEL,
        "choices": [{"index": 0, "message": message, "finish_reason": "stop"}],
    }
    return json.dumps(body).encode("utf-8")


def tool_call(name, arguments):
    return {
        "role": "assistant",
        "content": "",
        "tool_calls": [{
            "id": f"call_{name}_{NONCE}",
            "type": "function",
            "function": {
                "name": name,
                "arguments": json.dumps(arguments),
            },
        }],
    }


def latest_user(messages):
    for message in reversed(messages):
        if message.get("role") == "user":
            return str(message.get("content", ""))
    return ""


def tool_contents(messages):
    return [str(message.get("content", "")) for message in messages if message.get("role") == "tool"]


def maybe_delay():
    if RESPONSE_DELAY_MS > 0:
        time.sleep(RESPONSE_DELAY_MS / 1000)


class Handler(BaseHTTPRequestHandler):
    server_version = "AttacheSmokePersonality/1.0"

    def log_message(self, format, *args):
        return

    def do_GET(self):
        if self.path.endswith("/models"):
            self.send_json({"object": "list", "data": [{"id": MODEL, "object": "model"}]})
            return
        self.send_error(404)

    def do_POST(self):
        if not self.path.endswith("/chat/completions"):
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        payload = json.loads(self.rfile.read(length).decode("utf-8") or "{}")
        messages = payload.get("messages", [])
        user = latest_user(messages)
        tools = tool_contents(messages)
        log({
            "event": "request",
            "last_user": user,
            "tool_results": tools,
            "tool_names": [
                call.get("function", {}).get("name", "")
                for message in messages
                for call in message.get("tool_calls", []) or []
            ],
        })

        if "Tell Codex" in user and not tools:
            instruction = f"Reply exactly {PONG_TOKEN}. Do not use tools."
            log({"event": "tool_call", "name": "stage_agent_instruction", "instruction": instruction})
            maybe_delay()
            self.send_bytes(response(tool_call("stage_agent_instruction", {"instruction": instruction})))
            return

        if any("opened" in content or "staged" in content for content in tools):
            maybe_delay()
            self.send_bytes(response({
                "role": "assistant",
                "content": "I staged that for Codex. Review the confirmation and press Send to agent.",
            }))
            return

        if "What did Codex say" in user and not tools:
            log({"event": "tool_call", "name": "read_session_transcript"})
            maybe_delay()
            self.send_bytes(response(tool_call("read_session_transcript", {})))
            return

        if any(PONG_TOKEN in content for content in tools):
            maybe_delay()
            self.send_bytes(response({"role": "assistant", "content": "Codex said 4."}))
            return

        if "ATTACHE_CONVERSATION_FEEDBACK" in user:
            maybe_delay()
            self.send_bytes(response({
                "role": "assistant",
                "content": f"ATTACHE_CONVERSATION_FEEDBACK_REPLY_{NONCE}",
            }))
            return

        maybe_delay()
        self.send_bytes(response({
            "role": "assistant",
            "content": "I need the attached session context before I can answer.",
        }))

    def send_json(self, value):
        self.send_bytes(json.dumps(value).encode("utf-8"))

    def send_bytes(self, data):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main():
    port = int(os.environ["ATTACHE_PERSONALITY_TWO_WAY_PORT"])
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    log({"event": "ready", "port": port, "model": MODEL})
    server.serve_forever()


if __name__ == "__main__":
    main()

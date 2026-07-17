#!/usr/bin/env python3
"""Minimal stdio MCP server for Attaché's client tests (INF-373).

Speaks newline-delimited JSON-RPC 2.0 over stdin/stdout: initialize,
notifications/initialized, tools/list, tools/call. Two tools:
  - echo (readOnlyHint true): returns the text it was given.
  - write_note (no annotations, so effectful): appends to the file named by
    the MOCK_MCP_NOTE_FILE environment variable.
Standard library only.
"""
import json
import os
import sys

TOOLS = [
    {
        "name": "echo",
        "description": "Echo the provided text back.",
        "inputSchema": {
            "type": "object",
            "properties": {"text": {"type": "string"}},
            "required": ["text"],
        },
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "write_note",
        "description": "Append a line to the note file.",
        "inputSchema": {
            "type": "object",
            "properties": {"text": {"type": "string"}},
            "required": ["text"],
        },
    },
]


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def handle(request):
    method = request.get("method")
    request_id = request.get("id")

    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "protocolVersion": request.get("params", {}).get("protocolVersion", "2025-06-18"),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "mock-mcp", "version": "0.0.1"},
            },
        }
    if method == "notifications/initialized":
        return None
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": request_id, "result": {"tools": TOOLS}}
    if method == "tools/call":
        params = request.get("params", {})
        name = params.get("name")
        arguments = params.get("arguments", {})
        text = arguments.get("text", "")
        if name == "echo":
            content = [{"type": "text", "text": text}]
            return {"jsonrpc": "2.0", "id": request_id, "result": {"content": content}}
        if name == "write_note":
            note_file = os.environ.get("MOCK_MCP_NOTE_FILE")
            if note_file:
                with open(note_file, "a", encoding="utf-8") as handle_file:
                    handle_file.write(text + "\n")
            content = [{"type": "text", "text": "noted"}]
            return {"jsonrpc": "2.0", "id": request_id, "result": {"content": content}}
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "error": {"code": -32601, "message": f"unknown tool {name}"},
        }
    if request_id is not None:
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "error": {"code": -32601, "message": f"unknown method {method}"},
        }
    return None


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            continue
        response = handle(request)
        if response is not None:
            send(response)


if __name__ == "__main__":
    main()

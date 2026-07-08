#!/usr/bin/env bash
set -euo pipefail

umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TEMP_ROOT=""
SERVER_PID=""

usage() {
  cat <<EOF
Usage:
  scripts/local-provider-tool-calling-canary.sh

Starts Attaché's deterministic local OpenAI-compatible smoke provider and runs
the same stage_agent_instruction tool-calling contract against it. This is the
free positive control for provider tooling and requires no hosted LLM account.
EOF
}

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
  if [[ -n "$TEMP_ROOT" ]]; then
    rm -rf "$TEMP_ROOT"
  fi
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

command -v python3 >/dev/null 2>&1 || {
  echo "error: python3 was not found on PATH" >&2
  exit 1
}

TEMP_ROOT="$(mktemp -d /tmp/attache-local-provider-canary.XXXXXX)"
PROVIDER_LOG="$TEMP_ROOT/provider.jsonl"
PROVIDER_STDOUT="$TEMP_ROOT/provider.log"
NONCE="$(date +%Y%m%d%H%M%S)_$(uuidgen | tr '[:lower:]' '[:upper:]' | tr -d '-' | cut -c1-8)"
PONG_TOKEN="ATTACHE_LOCAL_PROVIDER_${NONCE}_4"
MODEL="attache-local-canary"
PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
: > "$PROVIDER_LOG"
chmod 600 "$PROVIDER_LOG"

ATTACHE_PERSONALITY_TWO_WAY_NONCE="$NONCE" \
ATTACHE_PERSONALITY_TWO_WAY_PONG_TOKEN="$PONG_TOKEN" \
ATTACHE_PERSONALITY_TWO_WAY_PROVIDER_LOG="$PROVIDER_LOG" \
ATTACHE_PERSONALITY_TWO_WAY_MODEL="$MODEL" \
ATTACHE_PERSONALITY_TWO_WAY_PORT="$PORT" \
  python3 scripts/personality-two-way-smoke-server.py >"$PROVIDER_STDOUT" 2>&1 &
SERVER_PID=$!

for _ in {1..50}; do
  if grep -q '"event": "ready"' "$PROVIDER_LOG"; then
    break
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    cat "$PROVIDER_STDOUT" >&2 || true
    echo "error: local provider exited before becoming ready" >&2
    exit 1
  fi
  sleep 0.1
done
grep -q '"event": "ready"' "$PROVIDER_LOG" || {
  echo "error: local provider did not become ready" >&2
  exit 1
}

CANARY_PROVIDER_NAME="Local deterministic provider" \
CANARY_BASE_URL="http://127.0.0.1:${PORT}/v1" \
CANARY_MODEL="$MODEL" \
CANARY_ALLOW_SKIP=0 \
CANARY_REQUIRES_API_KEY=0 \
CANARY_EXPECTED_TOKEN="$PONG_TOKEN" \
CANARY_USER_PROMPT="Tell Codex to tell me the sum of 2+2." \
  python3 scripts/openai-compatible-tool-calling-canary.py

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() {
  cat <<EOF
Usage:
  scripts/ollama-tool-calling-canary.sh

Checks a local Ollama OpenAI-compatible endpoint with Attaché's
stage_agent_instruction tool shape.

Inputs:
  OLLAMA_BASE_URL or ATTACHE_LLM_BASE_URL optional endpoint (default: http://127.0.0.1:11434/v1)
  OLLAMA_MODEL or ATTACHE_LLM_MODEL       optional model override (default: qwen3:7b)

By default, an unavailable local endpoint/model is reported as SKIP. Set
OLLAMA_CANARY_REQUIRE=1 to make it a failure.
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

if [[ "${OLLAMA_CANARY_REQUIRE:-0}" == "1" ]]; then
  ALLOW_SKIP=0
else
  ALLOW_SKIP=1
fi

CANARY_PROVIDER_NAME="Ollama" \
CANARY_BASE_URL="${OLLAMA_BASE_URL:-${ATTACHE_LLM_BASE_URL:-http://127.0.0.1:11434/v1}}" \
CANARY_MODEL="${OLLAMA_MODEL:-${ATTACHE_LLM_MODEL:-qwen3:7b}}" \
CANARY_ALLOW_SKIP="$ALLOW_SKIP" \
CANARY_REQUIRES_API_KEY=0 \
  python3 scripts/openai-compatible-tool-calling-canary.py

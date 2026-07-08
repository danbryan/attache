#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() {
  cat <<EOF
Usage:
  scripts/groq-tool-calling-canary.sh

Checks Groq's OpenAI-compatible endpoint with Attaché's stage_agent_instruction
tool shape.

Inputs:
  GROQ_API_KEY or ATTACHE_GROQ_API_KEY or ATTACHE_LLM_API_KEY
  GROQ_MODEL or ATTACHE_LLM_MODEL       optional model override (default: llama-3.3-70b-versatile)
  GROQ_BASE_URL or ATTACHE_LLM_BASE_URL optional endpoint (default: https://api.groq.com/openai/v1)

Set ATTACHE_CANARY_ALLOW_SKIP=1 to report missing credentials as SKIP.
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

CANARY_PROVIDER_NAME="Groq" \
CANARY_KEY_ENV_NAMES="GROQ_API_KEY,ATTACHE_GROQ_API_KEY,ATTACHE_LLM_API_KEY,COMPANION_LLM_API_KEY" \
CANARY_KEYCHAIN_ACCOUNTS="groq-api-key" \
CANARY_BASE_URL="${GROQ_BASE_URL:-${ATTACHE_LLM_BASE_URL:-https://api.groq.com/openai/v1}}" \
CANARY_MODEL="${GROQ_MODEL:-${ATTACHE_LLM_MODEL:-llama-3.3-70b-versatile}}" \
CANARY_ALLOW_SKIP="${ATTACHE_CANARY_ALLOW_SKIP:-0}" \
CANARY_REQUIRES_API_KEY=1 \
  python3 scripts/openai-compatible-tool-calling-canary.py

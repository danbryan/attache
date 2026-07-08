#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() {
  cat <<EOF
Usage:
  scripts/openai-tool-calling-canary.sh

Checks an OpenAI-compatible endpoint using OpenAI defaults with the same
stage_agent_instruction tool shape Attaché uses for personality-to-agent turns.

Inputs:
  OPENAI_API_KEY or ATTACHE_OPENAI_API_KEY or ATTACHE_LLM_API_KEY
  OPENAI_MODEL or ATTACHE_LLM_MODEL       optional model override (default: gpt-4o-mini)
  OPENAI_BASE_URL or ATTACHE_LLM_BASE_URL optional endpoint (default: https://api.openai.com/v1)

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

CANARY_PROVIDER_NAME="OpenAI-compatible" \
CANARY_KEY_ENV_NAMES="OPENAI_API_KEY,ATTACHE_OPENAI_API_KEY,ATTACHE_LLM_API_KEY,COMPANION_LLM_API_KEY" \
CANARY_KEYCHAIN_ACCOUNTS="custom-api-key,openai-api-key" \
CANARY_BASE_URL="${OPENAI_BASE_URL:-${ATTACHE_LLM_BASE_URL:-https://api.openai.com/v1}}" \
CANARY_MODEL="${OPENAI_MODEL:-${ATTACHE_LLM_MODEL:-gpt-4o-mini}}" \
CANARY_ALLOW_SKIP="${ATTACHE_CANARY_ALLOW_SKIP:-0}" \
CANARY_REQUIRES_API_KEY=1 \
  python3 scripts/openai-compatible-tool-calling-canary.py

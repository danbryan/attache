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

CANARY_PROVIDER_NAME="xAI" \
CANARY_KEY_ENV_NAMES="XAI_API_KEY,ATTACHE_LLM_API_KEY,COMPANION_LLM_API_KEY" \
CANARY_KEYCHAIN_ACCOUNTS="xai-api-key" \
CANARY_BASE_URL="${XAI_BASE_URL:-${ATTACHE_LLM_BASE_URL:-https://api.x.ai/v1}}" \
CANARY_MODEL="${XAI_MODEL:-${ATTACHE_LLM_MODEL:-grok-4.3}}" \
CANARY_ALLOW_SKIP="${ATTACHE_CANARY_ALLOW_SKIP:-0}" \
CANARY_REQUIRES_API_KEY=1 \
  python3 scripts/openai-compatible-tool-calling-canary.py

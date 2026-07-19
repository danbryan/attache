#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() {
  cat <<EOF
Usage:
  scripts/provider-canaries.sh

Runs provider contract canaries for Attaché's personality tool-calling shape.
The deterministic local provider is mandatory. Hosted providers are tested when
credentials are available and reported as SKIP when they are not, so the suite
does not require paid subscriptions to pass.

Set ATTACHE_PROVIDER_CANARIES_REQUIRE_HOSTED=1 to make xAI and
OpenAI-compatible credentials mandatory.
Set OLLAMA_CANARY_REQUIRE=1 to require a live local Ollama model.
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

passes=0
skips=0
failures=0

run_canary() {
  local name="$1"
  shift
  echo "==> $name"
  set +e
  "$@"
  local status=$?
  set -e
  if [[ "$status" == "0" ]]; then
    passes=$((passes + 1))
  elif [[ "$status" == "77" ]]; then
    skips=$((skips + 1))
  else
    failures=$((failures + 1))
    echo "error: $name failed with exit $status" >&2
  fi
}

run_canary "Local deterministic provider" scripts/local-provider-tool-calling-canary.sh

if [[ "${ATTACHE_PROVIDER_CANARIES_REQUIRE_HOSTED:-0}" == "1" ]]; then
  HOSTED_SKIP=0
else
  HOSTED_SKIP=1
fi

run_canary "xAI" env ATTACHE_CANARY_ALLOW_SKIP="$HOSTED_SKIP" scripts/xai-tool-calling-canary.sh
run_canary "OpenAI-compatible" env ATTACHE_CANARY_ALLOW_SKIP="$HOSTED_SKIP" scripts/openai-tool-calling-canary.sh
run_canary "Ollama" scripts/ollama-tool-calling-canary.sh

echo "Provider canaries: $passes passed, $skips skipped, $failures failed"
[[ "$failures" == "0" ]]

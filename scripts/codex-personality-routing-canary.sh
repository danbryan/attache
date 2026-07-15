#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

cat <<EOF
==> Running the real Codex personality routing canary
    This uses Attaché's production prompt and CLI tool bridge with the exact
    explicit artifact-delegation wording from the July 10 routing incident.
EOF

ATTACHE_LIVE_CODEX_ROUTING_TEST=1 \
ATTACHE_LIVE_CODEX_MODEL="${ATTACHE_LIVE_CODEX_MODEL:-default}" \
  swift test --filter AttachePresentationCLIToolBridgeTests.testLiveCodexRoutesExplicitArtifactDelegationToAgentTool

echo "==> Real Codex personality routing canary passed"

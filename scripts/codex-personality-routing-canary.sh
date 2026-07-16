#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

cat <<EOF
==> Running the Codex personality isolation canary
    This proves legacy Codex personality settings fail before compilation,
    subprocess launch, or app-tool execution.
EOF

swift test --filter AttachePresentationCLIToolBridgeTests.testCodexPersonalityInferenceFailsClosedBeforeToolExecution

echo "==> Codex personality isolation canary passed"

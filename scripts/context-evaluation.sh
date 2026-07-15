#!/bin/zsh
# INF-330: deterministic context management evaluation harness.
#
# One reproducible, offline gate that measures context safety, budget
# compliance, retrieval coverage, answer support, and mode behavior across
# constrained and frontier synthetic models. No network or paid inference.
#
# Usage: scripts/context-evaluation.sh
# Exit nonzero on regression.

set -euo pipefail

cd "$(dirname "$0")/.."

echo "INF-330 Context Management Evaluation Harness"
echo "Running deterministic offline evaluation..."
echo

swift test --filter AttacheEvaluationHarness 2>&1

echo
echo "Evaluation complete. All scenarios must pass for a green gate."
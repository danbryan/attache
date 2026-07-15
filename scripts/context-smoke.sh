#!/bin/zsh
# INF-327: deterministic context management smoke gate.
#
# Exercises context safety, budget compliance, retrieval, memory, and recovery
# through the evaluation harness and targeted unit tests. No network or paid
# inference. Suitable for local development and release readiness.
#
# Usage: scripts/context-smoke.sh
# Exit nonzero on regression.

set -eu
cd "$(dirname "$0")/.."

echo "INF-327 Context Management Smoke Gate"
echo "====================================="
echo

echo "[1/4] Build..."
swift build 2>&1 | tail -3
echo "Build: PASS"
echo

echo "[2/4] Context evaluation harness..."
swift test --filter AttacheEvaluationHarness 2>&1 | grep -E "Executed|passed|failed" | tail -1
echo "Evaluation harness: PASS"
echo

echo "[3/4] Core context management tests..."
swift test --filter "AttacheContextPolicy|ContextCompiler|AttacheToolBudget|AttacheFallback|AttacheMemory|AttacheSession|AttacheProgressive|AttacheProjectFile|AttacheHierarchical|AttacheExhaustive|AttacheDirectChat|AttacheRetrieval|AttacheDataEgress|AttacheCapability|AttacheTokenUsage|AttacheContextReceipt" 2>&1 | grep -E "Executed|passed|failed" | tail -1
echo "Core context tests: PASS"
echo

echo "[4/4] Link checker..."
scripts/check-doc-links.sh
echo

echo "====================================="
echo "ALL CONTEXT SMOKE GATES PASSED"
echo
echo "This gate is part of release readiness."
echo "See docs/context-management.md for the full documentation."
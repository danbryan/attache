#!/bin/zsh
# INF-314: retrieval benchmark one-command reproducibility.
#
# Runs the FTS-only baseline, the lexical reranker candidate, and the hybrid
# candidate against the sanitized corpus and verifies the deterministic metric
# logic and verdict derivation. All three candidates run in one command.
#
# Runtime measurements (latency, memory, disk, energy) are captured on the
# benchmark machine and recorded in docs/adr/INF-314-on-device-semantic-retrieval.md.
# This script verifies the reproducible deterministic core: metrics, thresholds,
# and the verdict that follows from them.
#
# No hosted embedding API or user-installed vector database is required.
# The corpus is synthetic and contains no private session content.

set -euo pipefail

cd "$(dirname "$0")/.."

echo "INF-314 retrieval benchmark"
echo "Running FTS-only, lexical reranker, and hybrid candidates..."
echo

swift test --filter AttacheRetrievalBenchmark 2>&1

echo
echo "Benchmark complete. See docs/adr/INF-314-on-device-semantic-retrieval.md"
echo "for the verdict, runtime measurements, and hardware/OS notes."
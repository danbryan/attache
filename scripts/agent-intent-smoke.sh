#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "warning: scripts/agent-intent-smoke.sh was renamed to scripts/agent-destination-smoke.sh" >&2
exec scripts/agent-destination-smoke.sh "$@"

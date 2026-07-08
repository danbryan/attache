#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() {
  cat <<EOF
Usage:
  scripts/release-readiness-smoke.sh

Runs the eight release-readiness gates that sit on top of the default unit/UI
suite:

  1. release install smoke
  2. upgrade-from-stable smoke
  3. provider canaries
  4. negative two-way safety smoke
  5. explicit agent destination smoke
  6. no-key first-run smoke
  7. macOS lifecycle smoke
  8. long-session/load smoke

Environment:
  ATTACHE_RELEASE_READINESS_WITH_CODEX=1 also runs the real Codex f7/f8
  round-trip smokes after the eight gates.
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

echo "==> Gate 1/8: release install"
scripts/release-install-smoke.sh

echo "==> Gate 2/8: upgrade from stable"
scripts/upgrade-from-stable-smoke.sh

echo "==> Gate 3/8: provider canaries"
scripts/provider-canaries.sh

echo "==> Gate 4/8: two-way safety"
scripts/codex-two-way-safety-smoke.sh

echo "==> Gate 5/8: explicit agent destination"
scripts/agent-destination-smoke.sh

echo "==> Gate 6/8: no-key first run"
scripts/no-key-first-run-smoke.sh

echo "==> Gate 7/8: macOS lifecycle"
scripts/macos-lifecycle-smoke.sh

echo "==> Gate 8/8: load"
scripts/load-smoke.sh

if [[ "${ATTACHE_RELEASE_READINESS_WITH_CODEX:-0}" == "1" ]]; then
  echo "==> Extra: real Codex direct two-way"
  scripts/codex-two-way-smoke.sh
  echo "==> Extra: real Codex personality two-way"
  scripts/codex-personality-two-way-smoke.sh
fi

echo "==> Release-readiness smoke gates passed"

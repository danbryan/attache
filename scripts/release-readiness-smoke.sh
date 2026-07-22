#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Propagate background mode (never take the user's focus) to every gate that
# drives the packaged app, so a single SMOKE_BACKGROUND=1 covers the whole
# readiness run. Default stays headed (0).
export SMOKE_BACKGROUND="${SMOKE_BACKGROUND:-1}"

usage() {
  cat <<EOF
Usage:
  scripts/release-readiness-smoke.sh

Runs the eleven release-readiness gates that sit on top of the default unit/UI
suite:

  1. context-management production gate
  2. release install smoke
  3. upgrade-from-stable smoke
  4. provider canaries
  5. negative two-way safety smoke
  6. explicit agent destination smoke
  7. live conversation feedback smoke
  8. no-key first-run smoke
  9. macOS lifecycle smoke
  10. long-session/load smoke
  11. two-way negative-path smoke (delivery failure, expiry, restart fails closed)

Environment:
  SMOKE_BACKGROUND=1 runs every app-driving gate without taking system focus
  from the user's frontmost app (default 0, headed). Propagated to all gates.
  ATTACHE_RELEASE_READINESS_WITH_CODEX=1 also runs the real Codex f7/f8
  round-trip smokes after the eleven gates.
  ATTACHE_RELEASE_READINESS_WITH_CLAUDE=1 also runs the real Claude Code f21
  round-trip smoke (the claude -p --resume delivery branch, opt-in and
  separate from the Codex extras above).
  ATTACHE_RELEASE_READINESS_WITH_GROK=1 also runs the real Grok Build f23
  round-trip smoke (the grok --resume delivery branch, opt-in and separate
  from the Codex/Claude extras above).
  ATTACHE_RELEASE_READINESS_WITH_OPENCODE=1 also runs the real opencode f24
  round-trip smoke (the opencode run --session SQLite delivery branch, opt-in
  and separate from the Codex/Claude/Grok extras above).
  ATTACHE_RELEASE_READINESS_WITH_PREMIUM_VOICE=1 also runs the real Attaché
  Premium voice synthesis gate (scripts/premium-voice-smoke.sh, opt-in and
  separate from the Codex/Claude/Grok/opencode extras above).
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

echo "==> Gate 1/11: context management"
scripts/context-smoke.sh

echo "==> Gate 2/11: release install"
scripts/release-install-smoke.sh

echo "==> Gate 3/11: upgrade from stable"
scripts/upgrade-from-stable-smoke.sh

echo "==> Gate 4/11: provider canaries"
scripts/provider-canaries.sh

echo "==> Gate 5/11: two-way safety"
scripts/codex-two-way-safety-smoke.sh

echo "==> Gate 6/11: explicit agent destination"
scripts/agent-destination-smoke.sh

echo "==> Gate 7/11: live conversation feedback"
scripts/conversation-feedback-smoke.sh

echo "==> Gate 8/11: no-key first run"
scripts/no-key-first-run-smoke.sh

echo "==> Gate 9/11: macOS lifecycle"
scripts/macos-lifecycle-smoke.sh

echo "==> Gate 10/11: load"
scripts/load-smoke.sh

echo "==> Gate 11/11: two-way negative paths (delivery failure, expiry, restart fails closed)"
scripts/two-way-negative-path-smoke.sh

if [[ "${ATTACHE_RELEASE_READINESS_WITH_CODEX:-0}" == "1" ]]; then
  echo "==> Extra: Codex personality isolation"
  scripts/codex-personality-routing-canary.sh
  echo "==> Extra: real Codex direct two-way"
  scripts/codex-two-way-smoke.sh
  echo "==> Extra: real Codex personality two-way"
  scripts/codex-personality-two-way-smoke.sh
fi

if [[ "${ATTACHE_RELEASE_READINESS_WITH_CLAUDE:-0}" == "1" ]]; then
  echo "==> Extra: real Claude Code direct two-way"
  scripts/claude-two-way-smoke.sh
fi

if [[ "${ATTACHE_RELEASE_READINESS_WITH_GROK:-0}" == "1" ]]; then
  echo "==> Extra: real Grok Build direct two-way"
  scripts/grok-two-way-smoke.sh
fi

if [[ "${ATTACHE_RELEASE_READINESS_WITH_OPENCODE:-0}" == "1" ]]; then
  echo "==> Extra: real opencode direct two-way"
  scripts/opencode-two-way-smoke.sh
fi

if [[ "${ATTACHE_RELEASE_READINESS_WITH_PREMIUM_VOICE:-0}" == "1" ]]; then
  echo "==> Extra: real Attaché Premium voice synthesis"
  scripts/premium-voice-smoke.sh
fi

echo "==> Release-readiness smoke gates passed"

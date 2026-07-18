#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() {
  cat <<EOF
Usage:
  scripts/premium-voice-smoke.sh

Real-engine gate for the Attaché Premium voice (INF-385/E5). Stages the native
runtime (building it if absent), resolves the licensed weights, and synthesizes
the app's preview phrase through the REAL engine, asserting the output exceeds
five seconds with nonzero energy. The synthesis + assertions run in the guarded
integration test AttachePremiumVoiceIntegrationTests
/testRealRuntimeSynthesizesPreviewPhraseOverFiveSeconds, driven here via
scripts/test.sh --filter so it inherits the suite's bounded wall-clock cap
(ATTACHE_TEST_TIMEOUT, default 600s) instead of hanging.

Weights:
  ATTACHE_PREMIUM_VOICE_TEST_WEIGHTS  directory holding models/ and voices/
                                      (defaults to the E1 integration test's
                                      convention: \$ATTACHE_E0_SPIKE_DIR/PocketTTS.cpp
                                      or the E0 spike scratchpad path).

Opt-in: does nothing unless ATTACHE_RELEASE_READINESS_WITH_PREMIUM_VOICE=1 is
set, so it never fails a machine without the licensed weights. Run standalone
with that flag set.
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
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

if [[ "${ATTACHE_RELEASE_READINESS_WITH_PREMIUM_VOICE:-0}" != "1" ]]; then
  echo "SKIP: scripts/premium-voice-smoke.sh requires ATTACHE_RELEASE_READINESS_WITH_PREMIUM_VOICE=1 (opt-in real premium voice synthesis). Not set; skipping cleanly."
  exit 0
fi

DYLIB="$ROOT/.build/premium-voice/libpocket_tts.dylib"
if [[ ! -f "$DYLIB" ]]; then
  echo "==> Staging premium voice runtime (scripts/build-premium-voice-runtime.sh)"
  scripts/build-premium-voice-runtime.sh
fi
[[ -f "$DYLIB" ]] || fail "premium voice runtime dylib still absent after build at $DYLIB"

DEFAULT_WEIGHTS="/private/tmp/claude-501/-Users-danb-code-github-com-danbryan-attache/b4fb4128-9707-4522-a640-76ef90ca9a82/scratchpad/e0-spike/PocketTTS.cpp"
WEIGHTS_BASE="${ATTACHE_PREMIUM_VOICE_TEST_WEIGHTS:-}"
if [[ -z "$WEIGHTS_BASE" ]]; then
  if [[ -n "${ATTACHE_E0_SPIKE_DIR:-}" ]]; then
    WEIGHTS_BASE="$ATTACHE_E0_SPIKE_DIR/PocketTTS.cpp"
  else
    WEIGHTS_BASE="$DEFAULT_WEIGHTS"
  fi
fi
[[ -f "$WEIGHTS_BASE/models/tokenizer.model" && -f "$WEIGHTS_BASE/voices/azelma.wav" ]] \
  || fail "premium voice weights not found under $WEIGHTS_BASE (need models/tokenizer.model and voices/azelma.wav). Set ATTACHE_PREMIUM_VOICE_TEST_WEIGHTS."

export ATTACHE_PREMIUM_VOICE_DYLIB="$DYLIB"
export ATTACHE_PREMIUM_VOICE_TEST_WEIGHTS="$WEIGHTS_BASE"

echo "==> Synthesizing preview phrase through the real premium voice engine"
echo "    dylib:   $DYLIB"
echo "    weights: $WEIGHTS_BASE"
START=$SECONDS
scripts/test.sh --filter AttachePremiumVoiceIntegrationTests/testRealRuntimeSynthesizesPreviewPhraseOverFiveSeconds
echo "==> Premium voice real-engine gate passed in $((SECONDS - START))s"

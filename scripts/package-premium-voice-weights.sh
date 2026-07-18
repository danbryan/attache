#!/usr/bin/env bash
# Build the Attaché Premium voice weights tarball and print its sha256.
#
# The tarball is the release asset the app downloads on explicit user consent
# (PremiumVoiceWeightsManager). It is NOT in git. Producing it is one command:
# this script assembles the INT8 ONNX set, tokenizer, config yaml, and the
# precomputed azelma voice state into premium-voice-int8.tar.gz and prints the
# sha256 to paste into PremiumVoiceRelease (Core) before uploading the asset.
#
# Embedding decision (see AttachePremiumVoiceRuntime): the C runtime takes a
# voice as a wav path and, as a side effect, writes a precomputed embedding
# (.emb) and conditioned KV state (.kv) into voices/.cache. The C API exposes no
# explicit "export embedding" call, so we SHIP BOTH: the azelma prompt wav AND
# its precomputed .emb/.kv. At runtime the cache hits, giving exact built-in
# azelma parity with zero first-use encode cost, and the wav remains as a
# regeneration fallback if the cache is ever absent.
#
# Inputs (override via env; defaults point at the E0 spike output):
#   PREMIUM_VOICE_MODELS_DIR  dir with the exported *.onnx + tokenizer.model
#   PREMIUM_VOICE_VOICES_DIR  dir with azelma.wav and .cache/azelma.{emb,kv}
#   PREMIUM_VOICE_CONFIG      the reconstructed b6369a24.yaml
#   PREMIUM_VOICE_VERSION     tarball version tag (default v1)
#   OUT_DIR                   where to write the tarball (default dist/)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPIKE_DEFAULT="/private/tmp/claude-501/-Users-danb-code-github-com-danbryan-attache/b4fb4128-9707-4522-a640-76ef90ca9a82/scratchpad/e0-spike"

MODELS_DIR="${PREMIUM_VOICE_MODELS_DIR:-$SPIKE_DEFAULT/PocketTTS.cpp/models}"
VOICES_DIR="${PREMIUM_VOICE_VOICES_DIR:-$SPIKE_DEFAULT/PocketTTS.cpp/voices}"
CONFIG_YAML="${PREMIUM_VOICE_CONFIG:-$ROOT/vendor/pocket-tts-runtime/b6369a24.yaml}"
VERSION="${PREMIUM_VOICE_VERSION:-v1}"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"

die() { printf 'package-premium-voice-weights: error: %s\n' "$*" >&2; exit 1; }
log() { printf 'package-premium-voice-weights: %s\n' "$*"; }

# The INT8 runtime set: quantized LM + decoder, plus the fp32 encoder and text
# conditioner that are not quantized (matches the E0 spike's shipped set).
INT8_MODELS=(
  flow_lm_main_int8.onnx
  flow_lm_flow_int8.onnx
  mimi_decoder_int8.onnx
  mimi_encoder.onnx
  text_conditioner.onnx
  tokenizer.model
)

[[ -d "$MODELS_DIR" ]] || die "models dir not found: $MODELS_DIR"
[[ -f "$VOICES_DIR/azelma.wav" ]] || die "azelma.wav not found under $VOICES_DIR"
[[ -f "$CONFIG_YAML" ]] || die "config yaml not found: $CONFIG_YAML"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/premium-voice-int8"
mkdir -p "$PKG/models" "$PKG/voices/.cache" "$PKG/config"

for m in "${INT8_MODELS[@]}"; do
  [[ -f "$MODELS_DIR/$m" ]] || die "missing model file: $MODELS_DIR/$m"
  cp "$MODELS_DIR/$m" "$PKG/models/"
done

cp "$VOICES_DIR/azelma.wav" "$PKG/voices/"
# Precomputed azelma embedding + conditioned KV state (see header). Optional:
# if absent the runtime re-encodes from the wav on first use.
for c in azelma.emb azelma.kv; do
  if [[ -f "$VOICES_DIR/.cache/$c" ]]; then
    cp "$VOICES_DIR/.cache/$c" "$PKG/voices/.cache/"
  else
    log "note: $c not present; runtime will encode azelma from the wav on first use."
  fi
done

cp "$CONFIG_YAML" "$PKG/config/b6369a24.yaml"

# /usr/bin/stat explicitly: a GNU coreutils stat earlier in PATH breaks -f '%z'.
UNPACKED_BYTES="$(find "$PKG" -type f -exec /usr/bin/stat -f '%z' {} + | awk '{s+=$1} END {print s}')"

cat > "$PKG/MANIFEST.txt" <<EOF
Attaché Premium voice weights ($VERSION)
INT8 runtime model set for libpocket_tts.dylib.
models/    quantized LM + mimi decoder, fp32 mimi encoder + text conditioner, tokenizer
voices/    azelma.wav prompt + precomputed .cache/azelma.{emb,kv}
config/    b6369a24.yaml (reconstructed export config, provenance)
unpacked_bytes = $UNPACKED_BYTES
EOF

mkdir -p "$OUT_DIR"
TARBALL="$OUT_DIR/premium-voice-int8.tar.gz"
tar -czf "$TARBALL" -C "$STAGE" premium-voice-int8

SHA="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
SIZE="$(/usr/bin/stat -f '%z' "$TARBALL")"

log "wrote $TARBALL"
log "  download size (bytes) : $SIZE"
log "  unpacked size (bytes) : $UNPACKED_BYTES"
log "  sha256                : $SHA"
echo
echo "Paste into Sources/AttacheCore/PremiumVoiceRelease.swift:"
echo "  sha256:      \"$SHA\""
echo "  unpackedSize: $UNPACKED_BYTES"
echo "  version:     \"$VERSION\""

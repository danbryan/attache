#!/usr/bin/env bash
# Build the Attaché Premium voice runtime (dev use).
#
# Compiles the vendored C++ runtime in vendor/pocket-tts-runtime/ into
# libpocket_tts.dylib and stages it next to the ONNX Runtime dylib in
# .build/premium-voice/. The app dlopen's these at runtime; package-app.sh
# embeds and signs them into the shipped bundle (see EMBED_PREMIUM_VOICE).
#
# ONNX Runtime is NOT vendored to git: it is downloaded here by pinned URL and
# verified against the sha256 in vendor/pocket-tts-runtime/PINNED, then reused
# by CMake FetchContent so the C++ build never re-downloads it. SentencePiece and
# dr_libs are git-cloned by CMake on the first build and cached under the CMake
# build tree; after one successful run everything is local and re-runs are a
# no-op, so the script is idempotent and offline-friendly.
#
# Usage:
#   scripts/build-premium-voice-runtime.sh          # build if not already staged
#   PTT_FORCE=1 scripts/build-premium-voice-runtime.sh   # rebuild from scratch
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT/vendor/pocket-tts-runtime"
STAGE_DIR="$ROOT/.build/premium-voice"
CACHE_DIR="$STAGE_DIR/cache"
CMAKE_BUILD_DIR="$STAGE_DIR/cmake"

ORT_VERSION="1.23.2"
ORT_ARCHIVE="onnxruntime-osx-universal2-${ORT_VERSION}.tgz"
ORT_URL="https://github.com/microsoft/onnxruntime/releases/download/v${ORT_VERSION}/${ORT_ARCHIVE}"
ORT_SHA256="49ae8e3a66ccb18d98ad3fe7f5906b6d7887df8a5edd40f49eb2b14e20885809"
ORT_LIB_NAME="libonnxruntime.${ORT_VERSION}.dylib"

STAGED_LIB="$STAGE_DIR/libpocket_tts.dylib"
STAGED_ORT="$STAGE_DIR/$ORT_LIB_NAME"

log() { printf 'build-premium-voice-runtime: %s\n' "$*"; }
die() { printf 'build-premium-voice-runtime: error: %s\n' "$*" >&2; exit 1; }

if [[ "${PTT_FORCE:-0}" != "1" && -f "$STAGED_LIB" && -f "$STAGED_ORT" ]]; then
  log "already staged in $STAGE_DIR (PTT_FORCE=1 to rebuild); nothing to do."
  exit 0
fi

command -v cmake >/dev/null 2>&1 || die "cmake not found. Install it (brew install cmake)."
[[ -f "$VENDOR_DIR/pocket_tts.cpp" ]] || die "vendored runtime source missing at $VENDOR_DIR."

mkdir -p "$CACHE_DIR"

verify_sha() {
  local file="$1" expected="$2"
  local actual
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]]
}

# 1. Fetch + verify ONNX Runtime (offline-friendly: reuse a verified cached copy).
ORT_TGZ="$CACHE_DIR/$ORT_ARCHIVE"
if [[ -f "$ORT_TGZ" ]] && verify_sha "$ORT_TGZ" "$ORT_SHA256"; then
  log "using cached $ORT_ARCHIVE (checksum ok)."
else
  command -v curl >/dev/null 2>&1 || die "curl not found and no verified cached archive present."
  log "downloading $ORT_URL"
  curl -fL --retry 3 -o "$ORT_TGZ.partial" "$ORT_URL" || die "download failed."
  mv "$ORT_TGZ.partial" "$ORT_TGZ"
  verify_sha "$ORT_TGZ" "$ORT_SHA256" \
    || die "checksum mismatch for $ORT_ARCHIVE (expected $ORT_SHA256). Refusing to build."
  log "downloaded and verified $ORT_ARCHIVE."
fi

# 2. Extract ONNX Runtime for CMake FetchContent to reuse (no network on rebuild).
ORT_SRC_DIR="$CACHE_DIR/onnxruntime-osx-universal2-${ORT_VERSION}"
if [[ ! -d "$ORT_SRC_DIR/lib" ]]; then
  log "extracting $ORT_ARCHIVE"
  tar -xzf "$ORT_TGZ" -C "$CACHE_DIR"
fi
[[ -d "$ORT_SRC_DIR/lib" ]] || die "extracted ONNX Runtime layout unexpected under $ORT_SRC_DIR."

# 3. Configure + build the shared library from the vendored source.
log "configuring CMake build in $CMAKE_BUILD_DIR"
cmake -S "$VENDOR_DIR" -B "$CMAKE_BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIB=ON \
  -DFETCHCONTENT_SOURCE_DIR_ONNXRUNTIME="$ORT_SRC_DIR" \
  >/dev/null

log "building libpocket_tts.dylib"
cmake --build "$CMAKE_BUILD_DIR" --target pocket-tts-lib -j"$(sysctl -n hw.ncpu)" >/dev/null

# CMake writes outputs next to the source (CMAKE_LIBRARY_OUTPUT_DIRECTORY = source dir).
BUILT_LIB="$VENDOR_DIR/libpocket_tts.dylib"
[[ -f "$BUILT_LIB" ]] || BUILT_LIB="$(find "$CMAKE_BUILD_DIR" "$VENDOR_DIR" -name libpocket_tts.dylib 2>/dev/null | head -1)"
[[ -n "$BUILT_LIB" && -f "$BUILT_LIB" ]] || die "build produced no libpocket_tts.dylib."

BUILT_ORT="$ORT_SRC_DIR/lib/$ORT_LIB_NAME"
[[ -f "$BUILT_ORT" ]] || die "ONNX Runtime dylib $ORT_LIB_NAME not found under $ORT_SRC_DIR/lib."

# 4. Stage both dylibs and fix the runtime's rpath so it finds its sibling ORT.
# Upstream CMake sets LC_RPATH to `$ORIGIN` (Linux syntax dyld ignores on macOS);
# @loader_path is the macOS equivalent for "the dylib's own directory".
cp "$BUILT_LIB" "$STAGED_LIB"
cp "$BUILT_ORT" "$STAGED_ORT"
chmod u+w "$STAGED_LIB" "$STAGED_ORT"
install_name_tool -rpath '$ORIGIN' '@loader_path' "$STAGED_LIB" 2>/dev/null \
  || install_name_tool -add_rpath '@loader_path' "$STAGED_LIB" 2>/dev/null || true
# Clean vendored build artifacts out of the source tree so git stays clean.
rm -f "$VENDOR_DIR/libpocket_tts.dylib" "$VENDOR_DIR/libonnxruntime.dylib" \
      "$VENDOR_DIR/libonnxruntime.${ORT_VERSION}.dylib" "$VENDOR_DIR/pocket-tts" 2>/dev/null || true

log "staged:"
log "  $STAGED_LIB"
log "  $STAGED_ORT"
log "done."

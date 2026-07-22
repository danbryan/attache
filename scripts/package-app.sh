#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="Attache"
LEGACY_APP_NAME="Codex Attache"
PRODUCT_NAME="Attache"
EXECUTABLE_NAME="Attache"
ICON_NAME="Attache"
APP_VERSION="${VERSION:-0.6.5}"
# Monotonic build number for Sparkle's version comparison (CFBundleShortVersionString
# is the marketing version users see). A timestamp always increases across releases.
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%s)}"
DIST_DIR="$ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
INSTALL_TO_APPLICATIONS="${INSTALL_TO_APPLICATIONS:-0}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
SIGN_APP="${SIGN_APP:-1}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
CODE_SIGN_CERTIFICATE_TYPE="${CODE_SIGN_CERTIFICATE_TYPE:-Developer ID Application}"
CODE_SIGN_TIMESTAMP="${CODE_SIGN_TIMESTAMP:-1}"
# Embed the Attaché Premium voice native runtime (libpocket_tts.dylib + ORT).
# Default off so plain `SIGN_APP=0 scripts/package-app.sh` works on a machine
# that never built the runtime; release builds set EMBED_PREMIUM_VOICE=1, which
# fails clearly if the staged dylibs are missing.
EMBED_PREMIUM_VOICE="${EMBED_PREMIUM_VOICE:-0}"
PREMIUM_VOICE_STAGE="$ROOT/.build/premium-voice"
NOTARIZE_APP="${NOTARIZE_APP:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARY_KEYCHAIN="${NOTARY_KEYCHAIN:-}"
NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-30m}"
NOTARY_ZIP_PATH="$DIST_DIR/$APP_NAME-notary-submit.zip"
RELEASE_ZIP_PATH="$DIST_DIR/$APP_NAME.zip"
RELEASE_CHECKSUM_PATH="$DIST_DIR/SHA256SUMS"

find_codesigning_identity() {
  local certificate_type="$1"

  security find-identity -v -p codesigning \
    | sed -n 's/^ *[0-9]*) [A-F0-9]* "\([^"]*\)".*$/\1/p' \
    | grep -m 1 -F "$certificate_type:" || true
}

require_developer_id_identity() {
  if [[ "$CODE_SIGN_IDENTITY" != Developer\ ID\ Application:* ]]; then
    echo "error: NOTARIZE_APP=1 requires a Developer ID Application signing identity." >&2
    echo "       Found: ${CODE_SIGN_IDENTITY:-none}" >&2
    exit 1
  fi
}

if [[ "$NOTARIZE_APP" == "1" ]]; then
  SIGN_APP="1"
fi

cd "$ROOT"
swift build -c "$CONFIGURATION" --product "$PRODUCT_NAME"

rm -rf "$APP_DIR" "$DIST_DIR/$LEGACY_APP_NAME.app"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp ".build/$CONFIGURATION/$PRODUCT_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"
chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"

# Embed Sparkle so the in-app updater is available at runtime. The framework
# comes from the resolved SwiftPM artifact; the executable gets an rpath into
# Contents/Frameworks so dyld can find it.
SPARKLE_FRAMEWORK="$(find "$ROOT/.build/artifacts" -type d -name "Sparkle.framework" -path "*macos-arm64*" 2>/dev/null | head -1)"
if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
  echo "error: Sparkle.framework not found under .build/artifacts (run 'swift build' first)." >&2
  exit 1
fi
mkdir -p "$CONTENTS_DIR/Frameworks"
cp -R "$SPARKLE_FRAMEWORK" "$CONTENTS_DIR/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/$EXECUTABLE_NAME" 2>/dev/null || true
# SwiftPM target resources (source logos etc.); Bundle.module finds this
# bundle inside Contents/Resources.
if [[ -d ".build/$CONFIGURATION/Attache_AttacheApp.bundle" ]]; then
  cp -R ".build/$CONFIGURATION/Attache_AttacheApp.bundle" "$RESOURCES_DIR/"
  # Promote compiled localizations to the app's Resources so SwiftUI's
  # Bundle.main lookups (Text literals, NSLocalizedString) resolve them.
  find "$RESOURCES_DIR/Attache_AttacheApp.bundle" -maxdepth 3 -name "*.lproj" -print0 \
    | while IFS= read -r -d '' lproj; do
        cp -R "$lproj" "$RESOURCES_DIR/"
      done
fi
# Embed the Attaché Premium voice runtime dylibs into Frameworks, mirroring how
# Sparkle is handled. Guarded: when requested but not built, fail with a clear
# pointer to the build script rather than shipping a half-app.
PREMIUM_VOICE_LIB="$PREMIUM_VOICE_STAGE/libpocket_tts.dylib"
PREMIUM_VOICE_ORT="$(ls "$PREMIUM_VOICE_STAGE"/libonnxruntime.*.dylib 2>/dev/null | head -1 || true)"
if [[ "$EMBED_PREMIUM_VOICE" == "1" ]]; then
  if [[ ! -f "$PREMIUM_VOICE_LIB" || -z "$PREMIUM_VOICE_ORT" ]]; then
    echo "error: EMBED_PREMIUM_VOICE=1 but the runtime is not built." >&2
    echo "       Expected $PREMIUM_VOICE_LIB and libonnxruntime.*.dylib in $PREMIUM_VOICE_STAGE." >&2
    echo "       Build it first: scripts/build-premium-voice-runtime.sh" >&2
    exit 1
  fi
  mkdir -p "$CONTENTS_DIR/Frameworks"
  cp "$PREMIUM_VOICE_LIB" "$CONTENTS_DIR/Frameworks/"
  cp "$PREMIUM_VOICE_ORT" "$CONTENTS_DIR/Frameworks/"
  # The runtime loads its sibling ORT dylib via @rpath; @loader_path resolves it
  # from the same Frameworks dir. Idempotent if already present.
  install_name_tool -add_rpath "@loader_path" \
    "$CONTENTS_DIR/Frameworks/$(basename "$PREMIUM_VOICE_LIB")" 2>/dev/null || true
  echo "Embedded Attaché Premium voice runtime ($(basename "$PREMIUM_VOICE_ORT"))."
fi

swift scripts/generate-app-icon.swift "$RESOURCES_DIR/$ICON_NAME.icns"

# Bundle the third-party license acknowledgements so the About pane can load
# them via Bundle.main (never Bundle.module). Fail clearly if it was not
# generated: scripts/generate-third-party-licenses.sh produces it.
THIRD_PARTY_LICENSES="$ROOT/THIRD-PARTY-LICENSES"
if [[ ! -f "$THIRD_PARTY_LICENSES" ]]; then
  echo "error: THIRD-PARTY-LICENSES missing at $THIRD_PARTY_LICENSES." >&2
  echo "       Generate it first: scripts/generate-third-party-licenses.sh" >&2
  exit 1
fi
cp "$THIRD_PARTY_LICENSES" "$RESOURCES_DIR/THIRD-PARTY-LICENSES"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>Attaché</string>
  <key>CFBundleIconFile</key>
  <string>$ICON_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>com.bryanlabs.attache</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Attaché uses the microphone to show live user speech captions.</string>
  <key>NSUserNotificationAlertStyle</key>
  <string>alert</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Attaché uses speech recognition to show live user transcripts during voice input.</string>
  <key>SUFeedURL</key>
  <string>https://attache.fm/appcast.xml</string>
  <key>SUPublicEDKey</key>
  <string>4GS+Ug0iPkAeiQUOrSJZ3aUNMKcgRfknAzV1eZosKE4=</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUScheduledCheckInterval</key>
  <integer>3600</integer>
</dict>
</plist>
PLIST

if [[ "$SIGN_APP" == "1" ]]; then
  if [[ -z "$CODE_SIGN_IDENTITY" ]]; then
    CODE_SIGN_IDENTITY="$(find_codesigning_identity "$CODE_SIGN_CERTIFICATE_TYPE")"
  fi

  if [[ -z "$CODE_SIGN_IDENTITY" ]]; then
    echo "error: no '$CODE_SIGN_CERTIFICATE_TYPE' code-signing identity found." >&2
    echo "       Set CODE_SIGN_IDENTITY, or create the certificate in Xcode or Apple Developer." >&2
    exit 1
  fi

  # Hardened runtime blocks the microphone unless the app carries the audio-input
  # entitlement, so the live-transcription / hold-to-talk paths need it.
  ENTITLEMENTS_FILE="${TMPDIR:-/tmp}/attache-entitlements-$$.plist"
  cat > "$ENTITLEMENTS_FILE" <<'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key>
  <true/>
</dict>
</plist>
ENTITLEMENTS

  sign_args=(--force --sign "$CODE_SIGN_IDENTITY" --options runtime --entitlements "$ENTITLEMENTS_FILE")
  if [[ "$CODE_SIGN_TIMESTAMP" == "1" ]]; then
    sign_args+=(--timestamp)
  fi

  # Re-sign Sparkle's nested code inside-out with the Developer ID and hardened
  # runtime so the whole bundle notarizes. Preserve the XPC services' sandbox
  # entitlements. The app signature below then seals over Frameworks.
  SPARKLE_FW="$CONTENTS_DIR/Frameworks/Sparkle.framework"
  if [[ -d "$SPARKLE_FW" ]]; then
    ts_flag=(); [[ "$CODE_SIGN_TIMESTAMP" == "1" ]] && ts_flag=(--timestamp)
    codesign --force --options runtime "${ts_flag[@]}" --preserve-metadata=entitlements --sign "$CODE_SIGN_IDENTITY" "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"
    codesign --force --options runtime "${ts_flag[@]}" --preserve-metadata=entitlements --sign "$CODE_SIGN_IDENTITY" "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"
    codesign --force --options runtime "${ts_flag[@]}" --sign "$CODE_SIGN_IDENTITY" "$SPARKLE_FW/Versions/B/Autoupdate"
    codesign --force --options runtime "${ts_flag[@]}" --sign "$CODE_SIGN_IDENTITY" "$SPARKLE_FW/Versions/B/Updater.app"
    codesign --force --options runtime "${ts_flag[@]}" --sign "$CODE_SIGN_IDENTITY" "$SPARKLE_FW"
  fi

  # Sign the embedded premium-voice dylibs with the hardened runtime before the
  # app signature seals over Frameworks (same inside-out order as Sparkle).
  if [[ "$EMBED_PREMIUM_VOICE" == "1" ]]; then
    ts_flag=(); [[ "$CODE_SIGN_TIMESTAMP" == "1" ]] && ts_flag=(--timestamp)
    for dylib in "$CONTENTS_DIR/Frameworks/libpocket_tts.dylib" "$CONTENTS_DIR/Frameworks"/libonnxruntime.*.dylib; do
      [[ -f "$dylib" ]] || continue
      codesign --force --options runtime "${ts_flag[@]}" --sign "$CODE_SIGN_IDENTITY" "$dylib"
    done
  fi

  codesign "${sign_args[@]}" "$APP_DIR"
  codesign --verify --strict --verbose=2 "$APP_DIR"
fi

if [[ "$NOTARIZE_APP" == "1" ]]; then
  require_developer_id_identity

  if [[ -z "$NOTARY_PROFILE" ]]; then
    echo "error: NOTARIZE_APP=1 requires NOTARY_PROFILE." >&2
    echo "       Create one with: xcrun notarytool store-credentials <profile> --apple-id <apple-id> --team-id <team-id>" >&2
    exit 1
  fi

  rm -f "$NOTARY_ZIP_PATH" "$RELEASE_ZIP_PATH"
  ditto -c -k --norsrc --keepParent "$APP_DIR" "$NOTARY_ZIP_PATH"
  notary_args=(submit "$NOTARY_ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait --timeout "$NOTARY_TIMEOUT")
  if [[ -n "$NOTARY_KEYCHAIN" ]]; then
    notary_args+=(--keychain "$NOTARY_KEYCHAIN")
  fi
  xcrun notarytool "${notary_args[@]}"
  xcrun stapler staple "$APP_DIR"
  xcrun stapler validate "$APP_DIR"
  spctl --assess --type execute --verbose=4 "$APP_DIR"
fi

rm -f "$RELEASE_ZIP_PATH"
ditto -c -k --norsrc --keepParent "$APP_DIR" "$RELEASE_ZIP_PATH"
(
  cd "$DIST_DIR"
  shasum -a 256 "$(basename "$RELEASE_ZIP_PATH")" > "$RELEASE_CHECKSUM_PATH"
)

echo "$APP_DIR"
echo "$RELEASE_ZIP_PATH"
echo "$RELEASE_CHECKSUM_PATH"

if [[ "$INSTALL_TO_APPLICATIONS" == "1" ]]; then
  rm -rf "$INSTALL_DIR/$APP_NAME.app" "$INSTALL_DIR/$LEGACY_APP_NAME.app"
  cp -R "$APP_DIR" "$INSTALL_DIR/$APP_NAME.app"
  echo "$INSTALL_DIR/$APP_NAME.app"
fi

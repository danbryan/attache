#!/usr/bin/env bash
# Wraps an already signed+notarized+stapled Attache.app in a drag-to-install
# DMG, then signs, notarizes, and staples the DMG itself. The app inside keeps
# its own notarization; this adds a notarized DMG wrapper users can double-click.
#
#   NOTARY_PROFILE=bryanlabs-notary SRC_APP=dist/Attache.app scripts/make-dmg.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT/dist"
SRC_APP="${SRC_APP:-$DIST_DIR/Attache.app}"
DMG_PATH="$DIST_DIR/Attache.dmg"
VOL_NAME="${VOL_NAME:-Attaché}"
NOTARY_PROFILE="${NOTARY_PROFILE:-bryanlabs-notary}"
NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-30m}"
CODE_SIGN_CERTIFICATE_TYPE="Developer ID Application"

[[ -d "$SRC_APP" ]] || { echo "error: missing app bundle: $SRC_APP" >&2; exit 1; }

IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning \
    | sed -n 's/^ *[0-9]*) [A-F0-9]* "\([^"]*\)".*$/\1/p' \
    | grep -m 1 -F "$CODE_SIGN_CERTIFICATE_TYPE:" || true)"
fi
[[ -n "$IDENTITY" ]] || { echo "error: no Developer ID Application identity found." >&2; exit 1; }
echo "signing identity: $IDENTITY"

# The app must already be validly signed + stapled before we wrap it.
codesign --verify --strict --verbose=2 "$SRC_APP"
xcrun stapler validate "$SRC_APP"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$SRC_APP" "$STAGE/Attache.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG_PATH"
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE" -fs HFS+ -ov -format UDZO "$DMG_PATH"

codesign --force --sign "$IDENTITY" --timestamp "$DMG_PATH"
codesign --verify --strict --verbose=2 "$DMG_PATH"

echo "submitting DMG to notary service..."
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait --timeout "$NOTARY_TIMEOUT"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH" || true

( cd "$DIST_DIR" && shasum -a 256 "$(basename "$DMG_PATH")" )
echo "$DMG_PATH"

#!/usr/bin/env bash
set -euo pipefail

umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Attache"
TEMP_ROOT=""
BACKUP_DIR=""
MOUNT_POINT=""

usage() {
  cat <<EOF
Usage:
  scripts/release-install-smoke.sh

Builds a signed local candidate, wraps it in a temporary DMG, mounts the DMG at
a known mountpoint, installs Attaché into a temp Applications directory, verifies
the installed bundle, then launches that installed app with the UI smoke driver.

This does not replace /Applications/Attache.app. Set
ATTACHE_RELEASE_INSTALL_REQUIRE_NOTARIZATION=1 to require a notarized/stapled
app and DMG using the normal notary profile.
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

cleanup() {
  pkill -f "$ROOT/dist/Attache.app/Contents/MacOS/Attache" 2>/dev/null || true
  if [[ -n "$MOUNT_POINT" ]] && mount | grep -q " on $MOUNT_POINT "; then
    hdiutil detach "$MOUNT_POINT" -quiet || true
  fi
  if [[ -n "$BACKUP_DIR" ]]; then
    scripts/simulate-fresh-user.sh restore "$BACKUP_DIR" >/dev/null || {
      echo "warning: state restore failed; restore manually with:" >&2
      echo "  scripts/simulate-fresh-user.sh restore \"$BACKUP_DIR\"" >&2
    }
    BACKUP_DIR=""
  fi
  if [[ -n "$TEMP_ROOT" ]]; then
    rm -rf "$TEMP_ROOT"
  fi
  rm -rf "$ROOT/dist/Attache.app" "$ROOT/dist/_dmgwork"
}
trap cleanup EXIT

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

command -v hdiutil >/dev/null 2>&1 || fail "hdiutil was not found on PATH"
command -v codesign >/dev/null 2>&1 || fail "codesign was not found on PATH"

TEMP_ROOT="$(mktemp -d /tmp/attache-release-install.XXXXXX)"
INSTALL_DIR="$TEMP_ROOT/Applications"
INSTALL_APP="$INSTALL_DIR/$APP_NAME.app"
LOCAL_DMG="$TEMP_ROOT/Attache-install-smoke.dmg"
MOUNT_POINT="$TEMP_ROOT/mnt"
mkdir -p "$INSTALL_DIR" "$MOUNT_POINT"

echo "==> Building UI smoke driver"
swift build >/dev/null
DRIVER="$ROOT/.build/debug/AttacheUISmoke"
[[ -x "$DRIVER" ]] || fail "driver binary not found at $DRIVER"

echo "==> Building packaged app candidate"
BUILD_NUMBER="${ATTACHE_RELEASE_INSTALL_BUILD_NUMBER:-$(date +%s)}"
if [[ "${ATTACHE_RELEASE_INSTALL_REQUIRE_NOTARIZATION:-0}" == "1" ]]; then
  VERSION="${VERSION:-0.1.3}" BUILD_NUMBER="$BUILD_NUMBER" NOTARIZE_APP=1 NOTARY_PROFILE="${NOTARY_PROFILE:-bryanlabs-notary}" scripts/package-app.sh >/dev/null
  SRC_APP="$ROOT/dist/$APP_NAME.app"
  SRC_APP="$SRC_APP" NOTARY_PROFILE="${NOTARY_PROFILE:-bryanlabs-notary}" scripts/make-dmg.sh >/dev/null
  DMG_PATH="$ROOT/dist/Attache.dmg"
else
  VERSION="${VERSION:-0.1.3}" BUILD_NUMBER="$BUILD_NUMBER" SIGN_APP=1 NOTARIZE_APP=0 scripts/package-app.sh >/dev/null
  SRC_APP="$ROOT/dist/$APP_NAME.app"
  STAGE="$TEMP_ROOT/dmg-stage"
  mkdir -p "$STAGE"
  cp -R "$SRC_APP" "$STAGE/$APP_NAME.app"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Attaché Smoke" -srcfolder "$STAGE" -fs HFS+ -ov -format UDZO "$LOCAL_DMG" >/dev/null
  DMG_PATH="$LOCAL_DMG"
fi

[[ -d "$SRC_APP" ]] || fail "packaged app missing at $SRC_APP"
[[ -f "$DMG_PATH" ]] || fail "DMG missing at $DMG_PATH"
codesign --verify --strict --verbose=2 "$SRC_APP"

echo "==> Mounting DMG and installing to temp Applications"
hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MOUNT_POINT" >/dev/null
[[ -d "$MOUNT_POINT/$APP_NAME.app" ]] || fail "mounted DMG does not contain $APP_NAME.app"
rm -rf "$INSTALL_APP"
ditto "$MOUNT_POINT/$APP_NAME.app" "$INSTALL_APP"
hdiutil detach "$MOUNT_POINT" -quiet
MOUNT_POINT=""

codesign --verify --strict --verbose=2 "$INSTALL_APP"
INSTALLED_BUILD="$(defaults read "$INSTALL_APP/Contents/Info" CFBundleVersion)"
[[ "$INSTALLED_BUILD" == "$BUILD_NUMBER" ]] || fail "installed build $INSTALLED_BUILD did not match $BUILD_NUMBER"
defaults read "$INSTALL_APP/Contents/Info" SUFeedURL >/dev/null
defaults read "$INSTALL_APP/Contents/Info" SUPublicEDKey >/dev/null

echo "==> Switching Attaché to a fresh install-smoke profile"
FRESH_OUTPUT="$(scripts/simulate-fresh-user.sh fresh)"
echo "$FRESH_OUTPUT"
BACKUP_DIR="$(printf '%s\n' "$FRESH_OUTPUT" | sed -n 's/^Backup: //p' | tail -1)"
[[ -n "$BACKUP_DIR" ]] || fail "could not determine Attaché backup dir"

echo "==> Launching installed temp app through UI smoke"
SMOKE_ONLY=f1 ATTACHE_DISABLE_TOPIC_TAGGING=1 "$DRIVER" "$INSTALL_APP" "$ROOT"

echo "==> Release install smoke passed: $INSTALL_APP build $BUILD_NUMBER"

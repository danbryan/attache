#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-0.6.1}"
TAG="${TAG:-v$VERSION}"
TITLE="${TITLE:-Attaché $VERSION}"
ASSET="$ROOT/dist/Attache.zip"
CHECKSUMS="$ROOT/dist/SHA256SUMS"
APP="$ROOT/dist/Attache.app"
NOTES_FILE="${NOTES_FILE:-$ROOT/docs/releases/$TAG.md}"

cd "$ROOT"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree has uncommitted changes." >&2
  echo "       Commit the release scripts and app changes before creating a GitHub release." >&2
  exit 1
fi

if [[ ! -d "$APP" ]]; then
  echo "error: missing app bundle: $APP" >&2
  echo "       Run NOTARIZE_APP=1 NOTARY_PROFILE=bryanlabs-notary scripts/package-app.sh first." >&2
  exit 1
fi

if [[ ! -f "$ASSET" ]]; then
  echo "error: missing release asset: $ASSET" >&2
  echo "       Run NOTARIZE_APP=1 NOTARY_PROFILE=bryanlabs-notary scripts/package-app.sh first." >&2
  exit 1
fi

if [[ ! -f "$CHECKSUMS" ]]; then
  echo "error: missing checksum file: $CHECKSUMS" >&2
  echo "       Run NOTARIZE_APP=1 NOTARY_PROFILE=bryanlabs-notary scripts/package-app.sh first." >&2
  exit 1
fi

codesign --verify --strict --verbose=2 "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"

if gh repo view --json isPrivate --jq .isPrivate | grep -qx true; then
  if [[ "${ALLOW_PRIVATE_RELEASE:-0}" != "1" ]]; then
    echo "error: repository is private; random users cannot download private release assets." >&2
    echo "       Make the repository public, or rerun with ALLOW_PRIVATE_RELEASE=1 for an access-limited release." >&2
    exit 1
  fi
fi

if ! git rev-parse "$TAG" >/dev/null 2>&1; then
  git tag -a "$TAG" -m "$TITLE"
fi

git push origin "$TAG"

release_args=(release create "$TAG" "$ASSET" "$CHECKSUMS" --title "$TITLE")
if [[ -f "$NOTES_FILE" ]]; then
  release_args+=(--notes-file "$NOTES_FILE")
else
  release_args+=(--notes "Prebuilt, Developer ID signed, notarized, and stapled macOS app bundle.")
fi

gh "${release_args[@]}"

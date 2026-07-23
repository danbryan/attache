#!/usr/bin/env bash
# Generate the Sparkle appcast for a release WITH user-facing release notes.
#
# Sparkle shows an item's notes in the update prompt before the user clicks
# Install, so every release ships notes. This script signs the appcast with
# generate_appcast, then embeds the current version's notes inline as the item
# <description> and adds a <sparkle:fullReleaseNotesLink> to the public GitHub
# releases page (the cumulative changelog for a user several versions behind,
# since Sparkle shows only the offered version's notes, not skipped ones).
#
# Writes dist/appcast.xml. Publish that file via the ConfigMap step in
# AGENTS.md (Landing Page).
#
# Usage: VERSION=X.Y.Z scripts/generate-appcast.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:?set VERSION=X.Y.Z}"
DMG="$ROOT/dist/Attache.dmg"
NOTES_MD="$ROOT/docs/releases/v$VERSION.md"
GEN="$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
FULL_NOTES_LINK="${FULL_NOTES_LINK:-https://github.com/danbryan/attache/releases}"
DL_PREFIX="https://github.com/danbryan/attache/releases/download/v$VERSION/"
OUT="$ROOT/dist/appcast.xml"

[ -f "$DMG" ] || { echo "error: $DMG missing (build the release first)." >&2; exit 1; }
[ -f "$NOTES_MD" ] || { echo "error: release notes $NOTES_MD missing. Write concise, high-level, public-safe notes before cutting the release." >&2; exit 1; }
[ -x "$GEN" ] || { echo "error: generate_appcast not found under .build/artifacts (run swift build)." >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$DMG" "$WORK/"
"$GEN" --download-url-prefix "$DL_PREFIX" --link "https://attache.fm" "$WORK/" >/dev/null

python3 "$ROOT/scripts/release-notes-appcast.py" "$WORK/appcast.xml" "$NOTES_MD" "$FULL_NOTES_LINK" "$OUT"
echo "Wrote $OUT with inline release notes and a full-changelog link."

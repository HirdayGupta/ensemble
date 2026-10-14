#!/bin/bash
# Adds a DMG to the Sparkle appcast: scripts/appcast.sh build/Clutch-0.1.0.dmg [appcast-dir]
# appcast-dir (default build/appcast) holds the published appcast.xml, if any; it is updated in place.
#
# Environment:
#   CLUTCH_DOWNLOAD_PREFIX   required: URL the DMG is downloaded from, ending in "/",
#                            e.g. https://github.com/OWNER/REPO/releases/download/v0.1.0/
#   SPARKLE_ED_PRIVATE_KEY   the EdDSA private key text (from generate_keys -x). Without it, generate_appcast reads the
#                            key from this Mac's login keychain (where generate_keys stored it).
#   CLUTCH_RELEASE_NOTES     optional path to a .md/.html/.txt file embedded as the release notes of this version.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DMG="${1:?usage: scripts/appcast.sh <dmg> [appcast-dir]}"
OUT_DIR="${2:-build/appcast}"
GEN=".build/artifacts/sparkle/Sparkle/bin/generate_appcast"
PREFIX="${CLUTCH_DOWNLOAD_PREFIX:?set CLUTCH_DOWNLOAD_PREFIX to the release download URL, ending in /}"
[ -x "$GEN" ] || { echo "error: $GEN not found (run swift package resolve)" >&2; exit 1; }
[ -f "$DMG" ] || { echo "error: $DMG not found" >&2; exit 1; }

# generate_appcast works on a folder and applies the prefix to every archive in it, so the folder holds only the
# new DMG plus the existing appcast, which it extends.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT_DIR"
[ ! -f "$OUT_DIR/appcast.xml" ] || cp "$OUT_DIR/appcast.xml" "$WORK/appcast.xml"
cp "$DMG" "$WORK/"
if [ -n "${CLUTCH_RELEASE_NOTES:-}" ]; then
  cp "$CLUTCH_RELEASE_NOTES" "$WORK/$(basename "${DMG%.dmg}").${CLUTCH_RELEASE_NOTES##*.}"
fi

echo "[$(date -u +%FT%TZ)] generate_appcast for $(basename "$DMG")"
if [ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
  printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$GEN" --ed-key-file - --download-url-prefix "$PREFIX" --embed-release-notes "$WORK"
else
  "$GEN" --download-url-prefix "$PREFIX" --embed-release-notes "$WORK"
fi

# An unsigned item is rejected by every installed copy, so never publish one (usually: SUPublicEDKey in Info.plist
# is still the placeholder, or the private key does not match it).
ITEMS="$(grep -c '<enclosure ' "$WORK/appcast.xml" || true)"
SIGNED="$(grep -c 'sparkle:edSignature=' "$WORK/appcast.xml" || true)"
if [ "$ITEMS" != "$SIGNED" ]; then
  echo "error: $((ITEMS - SIGNED)) of $ITEMS appcast items have no EdDSA signature; not writing the appcast." >&2
  exit 1
fi
cp "$WORK/appcast.xml" "$OUT_DIR/appcast.xml"
echo "[$(date -u +%FT%TZ)] wrote $OUT_DIR/appcast.xml"

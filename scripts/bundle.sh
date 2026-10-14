#!/bin/bash
# Builds build/Clutch.app from the SwiftPM release build. Safe to run repeatedly.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="build/Clutch.app"
LOG="/tmp/clutch-bundle.log"

echo "[$(date -u +%FT%TZ)] swift build -c release" | tee "$LOG"
swift build -c release 2>&1 | tee -a "$LOG"
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "[$(date -u +%FT%TZ)] assembling $APP" | tee -a "$LOG"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/Clutch" "$APP/Contents/MacOS/Clutch"
cp Sources/Clutch/Info.plist "$APP/Contents/Info.plist"

if [ -f Assets/AppIcon.icns ]; then
  cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
  echo "warning: Assets/AppIcon.icns missing; run: swift scripts/make-icon.swift" | tee -a "$LOG"
fi

# SwiftPM's generated Bundle.module looks for Clutch_Clutch.bundle in the app's top level, which the signature
# rejects ("unsealed contents present in the bundle root"), and then in the absolute build directory, which
# only exists on the build machine. The bundle therefore ships in Contents/Resources (sealed), and code must
# resolve it with ClutchResources.bundle (Sources/Clutch/App/ClutchResources.swift), not Bundle.module.
RESOURCE_BUNDLE="$BIN_DIR/Clutch_Clutch.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
  cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
else
  echo "error: $RESOURCE_BUNDLE not found" | tee -a "$LOG"
  exit 1
fi

# Signing uses one pinned identity so the designated requirement (what Camera and Accessibility grants are tied
# to) is the same on every build. Set CLUTCH_SIGN_IDENTITY to use another identity name; there is no ad-hoc
# fallback, because an ad-hoc signature is a new identity on every build and silently invalidates the grants.
IDENTITY_NAME="${CLUTCH_SIGN_IDENTITY:-Clutch Local Signing}"
HASHES="$(security find-identity -p codesigning 2>/dev/null | grep -F "\"$IDENTITY_NAME\"" | awk '{print $2}' | sort -u || true)"
COUNT="$(printf '%s' "$HASHES" | grep -c . || true)"
if [ "$COUNT" -eq 0 ]; then
  echo "error: no code-signing identity named \"$IDENTITY_NAME\" in the keychain." | tee -a "$LOG" >&2
  echo "       Create it (Keychain Access > Certificate Assistant > Create a Certificate, type Code Signing) or set CLUTCH_SIGN_IDENTITY." | tee -a "$LOG" >&2
  exit 1
elif [ "$COUNT" -gt 1 ]; then
  echo "error: $COUNT identities are named \"$IDENTITY_NAME\"; delete the extras so the choice is unambiguous:" | tee -a "$LOG" >&2
  echo "$HASHES" | tee -a "$LOG" >&2
  exit 1
fi
IDENTITY="$HASHES"
echo "[$(date -u +%FT%TZ)] signing with \"$IDENTITY_NAME\" ($IDENTITY)" | tee -a "$LOG"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP" 2>&1 | tee -a "$LOG"

codesign --verify --strict "$APP" 2>&1 | tee -a "$LOG"

REQ_FILE="build/designated-requirement.txt"
REQ="$(codesign -dr - "$APP" 2>&1 | sed -n 's/^designated => //p')"
if [ -z "$REQ" ]; then
  echo "error: could not read the designated requirement" | tee -a "$LOG" >&2
  exit 1
fi
if [ -f "$REQ_FILE" ] && [ "$(cat "$REQ_FILE")" != "$REQ" ]; then
  echo "WARNING: the designated requirement changed since the last build; macOS will ask for Camera and Accessibility again." | tee -a "$LOG" >&2
  echo "  was: $(cat "$REQ_FILE")" | tee -a "$LOG" >&2
  echo "  now: $REQ" | tee -a "$LOG" >&2
fi
printf '%s\n' "$REQ" > "$REQ_FILE"
echo "[$(date -u +%FT%TZ)] designated requirement: $REQ" | tee -a "$LOG"
echo "$ROOT/$APP"

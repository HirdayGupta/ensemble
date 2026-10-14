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

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Apple Development' | head -1 | awk '{print $2}' || true)"
if [ -n "$IDENTITY" ]; then
  echo "[$(date -u +%FT%TZ)] signing with Apple Development identity $IDENTITY" | tee -a "$LOG"
  codesign --force --sign "$IDENTITY" --timestamp=none "$APP" 2>&1 | tee -a "$LOG"
else
  echo "[$(date -u +%FT%TZ)] no Apple Development identity; signing ad-hoc" | tee -a "$LOG"
  codesign --force --sign - "$APP" 2>&1 | tee -a "$LOG"
fi

codesign --verify --strict "$APP" 2>&1 | tee -a "$LOG"
echo "$ROOT/$APP"

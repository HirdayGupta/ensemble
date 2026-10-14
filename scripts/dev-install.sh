#!/bin/bash
# Installs Ensemble on a development Mac and keeps it on the latest main.
#   gh repo clone oficiallyAkshay/ensemble ~/ensemble && ~/ensemble/scripts/dev-install.sh
# What it does: creates a self-signed "Ensemble Local Signing" identity once (a stable signature keeps the Camera and
# Accessibility grants across rebuilds), builds and installs ~/Applications/Ensemble.app, and loads the
# dev.ensemble.updater agent, which checks main every 2 minutes and rebuilds when it moved (scripts/dev-update.sh).
# Undo: launchctl bootout "gui/$(id -u)/dev.ensemble.updater"; rm ~/Library/LaunchAgents/dev.ensemble.updater.plist
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="Ensemble Local Signing"
LABEL="dev.ensemble.updater"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
say() { echo "[$(date -u +%FT%TZ)] $*"; }

command -v swift >/dev/null || { echo "Swift is missing. Run: xcode-select --install, then run this again." >&2; exit 1; }
command -v git >/dev/null || { echo "git is missing (xcode-select --install)." >&2; exit 1; }

if ! security find-identity -p codesigning | grep -qF "\"$IDENTITY\""; then
  say "creating the \"$IDENTITY\" code-signing identity in the login keychain"
  TMP="$(mktemp -d)"
  cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:ensemble
  security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P ensemble -T /usr/bin/codesign >/dev/null
  rm -rf "$TMP"
fi

say "building and installing (first build takes a few minutes; macOS may ask once to let codesign use the key: choose Always Allow)"
"$ROOT/scripts/dev-update.sh" --force
LOG="$HOME/Library/Logs/Ensemble/updater.log"
tail -n 1 "$LOG"
if tail -n 1 "$LOG" | grep -q "build failed"; then
  echo "--- this Mac's compiler: $(swift --version 2>&1 | head -1)"
  echo "--- build errors (paste everything from here to the end into your Claude session):"
  sed -n "/swift build -c release/,\$p" /tmp/clutch-bundle.log | grep -E -A3 "error:" | head -60
fi

mkdir -p "$(dirname "$AGENT")"
cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>/bin/bash</string><string>$ROOT/scripts/dev-update.sh</string></array>
    <key>StartInterval</key><integer>120</integer>
    <key>RunAtLoad</key><true/>
    <key>ProcessType</key><string>Background</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"
say "done. Ensemble is in ~/Applications and updates itself from main every 2 minutes."
say "log: ~/Library/Logs/Ensemble/updater.log"

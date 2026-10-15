#!/bin/bash
# Installs Ensemble on a development Mac and keeps it on the latest main.
#   gh repo clone oficiallyAkshay/ensemble ~/ensemble && ~/ensemble/scripts/dev-install.sh
# What it does: creates a self-signed "Ensemble Local Signing" identity once (a stable signature keeps the Camera and
# Accessibility grants across rebuilds), builds and installs Ensemble.app (over /Applications/Ensemble.app when that
# exists, else in ~/Applications), and loads the dev.ensemble.updater agent, which checks main every 2 minutes and
# rebuilds when it moved (scripts/dev-update.sh).
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

# Without this, every rebuild makes codesign ask to use the key until someone clicks Always Allow (macOS keeps a
# per-key list of programs allowed to use it). Adding Apple's signing tools to that list needs the login password
# once, typed into Terminal here and never stored. Safe to run again. If it fails or is cancelled, the prompts stay.
say "macOS will ask for your login password once, so builds can use the signing key without a prompt every time"
if security set-key-partition-list -S apple-tool:,apple:,codesign: -s -l "$IDENTITY" "$HOME/Library/Keychains/login.keychain-db" >/dev/null; then
  say "signing key set up for builds"
else
  say "skipped; builds will ask to use the key until you choose Always Allow"
fi

# macOS refuses background agents access to Desktop, Documents and Downloads (the agent exits 126 and never builds),
# so a clone kept there gets a separate build-only clone for the agent. The updater resets that clone to main, so
# nobody develops in it.
case "$ROOT/" in
  "$HOME/Desktop/"*|"$HOME/Documents/"*|"$HOME/Downloads/"*)
    BUILD_ROOT="$HOME/Library/Application Support/Ensemble/checkout"
    if [ ! -d "$BUILD_ROOT/.git" ]; then
      say "this clone is in a folder macOS hides from background agents; cloning a build-only copy to $BUILD_ROOT"
      mkdir -p "$(dirname "$BUILD_ROOT")"
      git clone --quiet "$(git -C "$ROOT" remote get-url origin)" "$BUILD_ROOT"
    fi
    ROOT="$BUILD_ROOT"
    ;;
esac

say "building and installing (first build takes a few minutes; macOS may ask once to let codesign use the key: choose Always Allow)"
"$ROOT/scripts/dev-update.sh" --force
LOG="$HOME/Library/Logs/Ensemble/updater.log"
tail -n 1 "$LOG"
if tail -n 1 "$LOG" | grep -q "build skipped"; then
  exit 1
elif tail -n 1 "$LOG" | grep -q "build failed"; then
  echo "--- this Mac's compiler: $(swift --version 2>&1 | head -1)"
  echo "--- build errors (paste everything from here to the end into your Claude session):"
  sed -n "/swift build -c release/,\$p" "$ROOT/build/bundle.log" | grep -E -A3 "error:" | head -60
fi

mkdir -p "$(dirname "$AGENT")"
# Written with PlistBuddy, which escapes for us: a clone path holding & or < would break a hand-written XML file.
write_agent() {
  local out="$1" root="$2" pb=/usr/libexec/PlistBuddy
  rm -f "$out"
  "$pb" -c "Add :Label string $LABEL" "$out" >/dev/null
  "$pb" -c "Add :ProgramArguments array" "$out"
  "$pb" -c "Add :ProgramArguments:0 string /bin/bash" "$out"
  "$pb" -c "Add :ProgramArguments:1 string $root/scripts/dev-update.sh" "$out"
  "$pb" -c "Add :StartInterval integer 120" "$out"
  "$pb" -c "Add :RunAtLoad bool true" "$out"
  "$pb" -c "Add :ProcessType string Background" "$out"
  plutil -lint "$out" >/dev/null
}
write_agent "$AGENT" "$ROOT"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"
say "done. Ensemble updates itself from main every 2 minutes, built from $ROOT."
say "log: ~/Library/Logs/Ensemble/updater.log"

#!/bin/bash
# Keeps a development Mac on the latest main: fetch, and when main moved, rebuild, swap the app, relaunch.
# Run every 2 minutes by the dev.ensemble.updater launchd agent that scripts/dev-install.sh writes.
# Off switch: launchctl bootout "gui/$(id -u)/dev.ensemble.updater"
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$HOME/Library/Logs/Ensemble"
LOG="$LOG_DIR/updater.log"
# Replace the copy the owner already has where it is; a second copy in ~/Applications would sit beside the one
# that holds the Camera and Accessibility grants and get rebuilt on every run.
if [ -n "${ENSEMBLE_APP_DEST:-}" ]; then APP_DEST="$ENSEMBLE_APP_DEST"
elif [ -d /Applications/Ensemble.app ]; then APP_DEST="/Applications/Ensemble.app"
else APP_DEST="$HOME/Applications/Ensemble.app"; fi
BUNDLE_ID="dev.ensemble.app"
LOCK="$ROOT/.build/dev-update.lock"
PENDING="$ROOT/.build/dev-update.pending"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

mkdir -p "$LOG_DIR" "$ROOT/.build"
log() { echo "[$(date -u +%FT%TZ)] $*" >> "$LOG"; }

# One run at a time: a build can outlast the 2-minute interval.
if ! mkdir "$LOCK" 2>/dev/null; then
  # A lock older than 30 minutes belongs to a run that died; take it over.
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
    log "stale lock removed"; rm -rf "$LOCK"; mkdir "$LOCK" || exit 0
  else
    exit 0
  fi
fi
trap 'rm -rf "$LOCK"' EXIT

cd "$ROOT" || exit 1
FORCE="${1:-}"
if ! git fetch --quiet origin main 2>>"$LOG"; then log "fetch failed; retrying next run"; exit 0; fi
HERE="$(git rev-parse HEAD)"
THERE="$(git rev-parse origin/main)"
# A copy carrying the update key is a published release (Sparkle or a download put it there), not this checkout's
# build: replace it even though main has not moved.
release_installed() { /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP_DEST/Contents/Info.plist" >/dev/null 2>&1; }
if [ "$HERE" = "$THERE" ] && [ "$FORCE" != "--force" ] && [ -d "$APP_DEST" ] && [ ! -f "$PENDING" ] && ! release_installed; then exit 0; fi

# Never swap the app while Claude is listening: the safety record exists only during dictation.
# A build from before the rename keeps its record in the old folder until it quits, so both are checked.
# Checked here to skip a pointless build, and again right before quitting the app, because the build takes minutes.
dictating() { [ -f "$HOME/Library/Application Support/Ensemble/episode.json" ] || [ -f "$HOME/Library/Application Support/Clutch/episode.json" ]; }
if dictating && [ "$FORCE" != "--force" ]; then
  log "dictation in progress; update deferred"; exit 0
fi

if [ "$HERE" != "$THERE" ]; then
  # Never discard work: uncommitted edits, or a HEAD other than the one this script last moved to, mean someone
  # is developing in this checkout. (After a rewritten main, HEAD still equals the recorded commit, so reset is safe.)
  LAST="$(cat "$ROOT/.build/dev-update.head" 2>/dev/null || echo "$HERE")"
  if [ -n "$(git status --porcelain --untracked-files=no)" ] || [ "$HERE" != "$LAST" ]; then
    log "this checkout has local edits or commits; not updating. Develop in another clone, or push and run: git reset --hard origin/main"; exit 0
  fi
  # This checkout only builds main; it follows main exactly, including a rewritten history.
  if ! git reset --hard --quiet origin/main 2>>"$LOG"; then log "could not move to origin/main; retrying next run"; exit 0; fi
  log "main moved ${HERE:0:7} -> ${THERE:0:7}: $(git log -1 --format=%s)"
fi
git rev-parse HEAD > "$ROOT/.build/dev-update.head"

# The app uses macOS 26 APIs (Liquid Glass, renamed AVFoundation notifications): Swift 6.2 or newer is required.
SWIFT_VER="$(swift --version 2>&1 | sed -nE 's/.*Swift version ([0-9]+)\.([0-9]+).*/\1 \2/p' | head -1)"
read -r SV_MAJOR SV_MINOR <<< "${SWIFT_VER:-0 0}"
if [ "$SV_MAJOR" -lt 6 ] || { [ "$SV_MAJOR" -eq 6 ] && [ "$SV_MINOR" -lt 2 ]; }; then
  log "build skipped: Swift ${SV_MAJOR}.${SV_MINOR} is too old, 6.2 or newer is needed. Fix: sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install"
  exit 0
fi

if ! ENSEMBLE_DEV_BUILD=1 scripts/bundle.sh >> "$LOG" 2>&1; then log "build failed at $(git rev-parse --short HEAD); the installed app is unchanged"; exit 0; fi

# Dictation may have started during the build, which takes minutes. A record now defers the install; the pending
# mark makes the next run retry even though main has not moved.
if dictating; then
  touch "$PENDING"; log "dictation started during the build; install deferred"; exit 0
fi
# Quit the running copy cleanly (quitting stops dictation first), swap it, relaunch.
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
for _ in $(seq 1 20); do pgrep -f "$APP_DEST/Contents/MacOS/" >/dev/null || break; sleep 0.5; done
# Force-kill only a copy that did not quit, and never while a record says Claude may still be listening.
if pgrep -f "$APP_DEST/Contents/MacOS/" >/dev/null; then
  if dictating; then touch "$PENDING"; log "dictation in progress and the app did not quit; install deferred"; exit 0; fi
  pkill -f "$APP_DEST/Contents/MacOS/" 2>/dev/null || true
fi
mkdir -p "$(dirname "$APP_DEST")"
rm -rf "$APP_DEST.new" && ditto build/Ensemble.app "$APP_DEST.new" && rm -rf "$APP_DEST" && mv "$APP_DEST.new" "$APP_DEST"
rm -f "$PENDING"
open "$APP_DEST"
log "installed $(git rev-parse --short HEAD) at $APP_DEST and relaunched"

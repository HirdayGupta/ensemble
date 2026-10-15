#!/bin/bash
# Turns the current main into a release that installed copies pick up through Check for Updates:
#   scripts/ship-release.sh 0.2.0
# Tags main, builds and signs the DMG with this Mac's identity (scripts/release.sh), publishes the GitHub Release,
# adds the DMG to the appcast (scripts/appcast.sh, signed with the update key in this Mac's login keychain) and
# pushes the appcast to the gh-pages branch that GitHub Pages serves. Run it right after a merge to main.
# Everything that can refuse (the DMG, the signed appcast) happens before the tag and the release exist, so a refusal
# leaves nothing public to take back.
# Log: build/ship.log
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${1:?usage: scripts/ship-release.sh <version, e.g. 0.2.0>}"
TAG="v$VERSION"
mkdir -p build
LOG=build/ship.log
log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }

# Only a clean main that matches GitHub ships: the release must be exactly what was merged.
# Explicit refspecs: a clone made for one branch (the production Mac's job service clone) has no fetch refspec, so a
# plain fetch would leave origin/gh-pages and the remote tags missing.
git fetch --quiet --tags origin +refs/heads/main:refs/remotes/origin/main +refs/heads/gh-pages:refs/remotes/origin/gh-pages
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { log "error: HEAD is not origin/main; check out main and pull first"; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { log "error: uncommitted changes; this must be a clean main"; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { log "error: $TAG already exists; versions are never reused"; exit 1; }

REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
PREV="$(git describe --tags --abbrev=0 2>/dev/null || true)"
log "shipping $TAG from $(git rev-parse --short HEAD) of $REPO (previous: ${PREV:-none})"

ENSEMBLE_VERSION="$VERSION" scripts/release.sh 2>&1 | tee -a "$LOG"
DMG="build/Ensemble-$VERSION.dmg"
[ -f "$DMG" ] || { log "error: $DMG was not built"; exit 1; }

NOTES="$(mktemp)"
PAGES="$(mktemp -d)"
# The gh-pages checkout is a git worktree: remove it on every exit, or a failed run leaves it registered.
cleanup() { rm -f "$NOTES"; git worktree remove --force "$PAGES" 2>/dev/null || true; rm -rf "$PAGES"; }
trap cleanup EXIT
{ echo "Changes since ${PREV:-the first commit}:"; echo; git log --merges --format='- %b' "${PREV:+$PREV..}HEAD" | grep -v '^- $' || true; } > "$NOTES"

# The appcast lives on gh-pages; extend the published one so older items stay listed. It is built and checked now
# (scripts/appcast.sh refuses an unsigned item), before anything public exists; the download address is known
# from the tag alone.
git worktree add --quiet "$PAGES" origin/gh-pages --detach
rm -rf build/appcast
mkdir -p build/appcast
[ ! -f "$PAGES/appcast.xml" ] || cp "$PAGES/appcast.xml" build/appcast/appcast.xml
ENSEMBLE_DOWNLOAD_PREFIX="https://github.com/$REPO/releases/download/$TAG/" scripts/appcast.sh "$DMG" build/appcast 2>&1 | tee -a "$LOG"
[ -s build/appcast/appcast.xml ] || { log "error: no appcast was produced; nothing was tagged or published"; exit 1; }
cp build/appcast/appcast.xml "$PAGES/appcast.xml"
git -C "$PAGES" add appcast.xml
git -C "$PAGES" commit --quiet -m "Appcast: Ensemble $VERSION"

git tag -a "$TAG" -m "Ensemble $VERSION"
git push --quiet origin "$TAG"
# Ensemble.dmg, the same file under a fixed name, is what the website's Download buttons fetch directly:
# https://github.com/<repo>/releases/latest/download/Ensemble.dmg always resolves to the newest release.
cp "$DMG" build/Ensemble.dmg
gh release create "$TAG" "$DMG" "$DMG.sha256" build/Ensemble.dmg --title "Ensemble $VERSION" --notes-file "$NOTES" | tee -a "$LOG"

git -C "$PAGES" push --quiet origin HEAD:gh-pages
log "done: $TAG released; installed copies see it within their next update check"

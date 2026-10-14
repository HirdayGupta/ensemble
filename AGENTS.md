# Ensemble: instructions for coding agents

Ensemble is a macOS menu bar app (Swift, SwiftPM, macOS 14.2+, Apple Silicon) that drives Claude desktop sessions hands-free with a webcam. This is the one agent-instructions file; `CLAUDE.md` only points here. Human contributors read `CONTRIBUTING.md`; the user-facing description is `README.md`.

## Commands

Build and test before every commit. All tests must pass.

```
swift build                 # debug build
swift build -c release      # what ci.yml builds
swift test                  # with full Xcode installed
scripts/bundle.sh           # build/Ensemble.app, signed; needs a signing identity (gotcha 1)
```

With only the Command Line Tools installed, `swift test` needs the Swift Testing framework paths:

```
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
swift test --enable-swift-testing -Xswiftc -F -Xswiftc $F -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $L
```

Repository checks, run before pushing a change to `.github/`, `.pre-commit-config.yaml` or anything that could hold a secret:

```
env -u GH_TOKEN -u GITHUB_TOKEN pre-commit run --all-files   # gitleaks and zizmor
scripts/check-network.sh && scripts/check-size.sh            # when present
```

Unset the token variables: zizmor forwards whatever it finds to github.com, and a placeholder token fails with a 401 instead of a clean finding.

## Where things live

| Path | Owns | Rules |
|---|---|---|
| `Sources/EnsembleCore` | Pure logic: gesture state machine, nose pointer, detectors, safety records, log file, frame-rate planner, hand classifier adapter | No UI, no camera, no AppKit. Every change comes with a test. |
| `Sources/EnsembleCore/Vendor` | Sleight hand-pose rules and licence | Vendored; keep the licence files, do not reformat. |
| `Sources/Ensemble/Engine` | Camera capture, Vision hand pose, MediaPipe face tracker in a hidden web view | Frame scheduling lives here, not in the coordinator. |
| `Sources/Ensemble/Claude` | Accessibility bridge to Claude desktop, dictation safety, input muting | Every Claude label is an English string of one Claude version. |
| `Sources/Ensemble/Coordinator` | Turns gesture intents into actions after every safety guard agrees | The only place that decides to press Claude's controls. |
| `Sources/Ensemble/App` | Menu bar, settings, calibration, overlay, hotkey, notifications, updater | |
| `Sources/Ensemble/Resources/web` | Bundled MediaPipe runtime, WebAssembly, model, page | Served through `ensemble-asset://`; nothing is fetched at run time. |
| `Tests/EnsembleCoreTests` | Unit tests; gesture timing is replayed from recorded fixtures in `Fixtures/` | Do not edit a fixture to make a test pass. |
| `Tools/PerfBench` | Separate package of camera-free benchmarks | Not part of the app package. |
| `scripts/` | Bundle, release, appcast, dev install and update, icon | `bundle.sh` signing rules: gotcha 1. |
| `.github/`, `.pre-commit-config.yaml` | CI and repository hygiene | Pins and permissions: gotcha 8. |
| `docs/RELEASING.md` | How a release is built, signed, notarized and delivered | |

## Trust rules (do not weaken)

- The app makes no network connection except the Sparkle update feed, and that is off until the user turns on automatic checks or presses Check for Updates. The face tracker page, its WebAssembly and the model ship in the bundle. No telemetry, no analytics, no crash upload, no remote logging. A change that adds a network call needs the owner's explicit approval first.
- Video frames are analysed in memory and never written to disk. Logs hold events and numbers, never images or transcripts.
- Nothing personal in the tree or in history: no personal email, no machine paths, no tokens, no names of private repositories. Commit under the repository's GitHub no-reply identity (`<id>+<user>@users.noreply.github.com`); never change `user.email`. A push whose newest commit carries any other address is refused by GitHub, and older commits are not checked, so check `git log --format=%ae` yourself.
- Dictation safety: Claude's microphone is never left recording because of Ensemble. A change to dictation or send keeps the written-before-pressed record, the dead-man check, the standing check and the narrow send rules (README, "Safety design"), and the pull request says how.
- Acting only on Claude: with another app in front, gestures do nothing.

## Gotchas that have cost incidents

1. **Signing identity and TCC.** Camera and Accessibility grants are tied to the app's designated requirement. An ad-hoc signature is a new identity on every build, so grants silently stop working after each install. `scripts/bundle.sh` never signs ad hoc; it signs with one stable identity (`Ensemble Local Signing`, or `ENSEMBLE_SIGN_IDENTITY`). Changing the bundle id (`dev.ensemble.app`) or the signing identity drops every grant, and the owner must turn Accessibility on again by hand. A grant that shows on but does not work is cleared with `tccutil reset Accessibility dev.ensemble.app`. The settings domain follows the bundle id. Never run `tccutil`, `defaults` or anything that touches the keychain or the installed app from an agent session.
2. **Claude desktop's controls exist only in its accessibility tree, and only after a flag.** Claude is an Electron app: set `AXManualAccessibility` to true on the app element, then retry discovery for about 3 seconds while Chromium builds the tree. A session pane is found by its dictation checkbox, labelled "Press and hold to record" (idle) or "Stop dictation" (recording); the session name is the header button whose description reads "<name>, rename session"; Send is a button labelled "Send". All are English labels of one Claude version. After a Claude update, check them first. Microphone state needs two sources, the checkbox value and CoreAudio's per-process capture flag, because either alone has lagged.
3. **Scrolling goes through the session event tap.** `CGEvent.postToPid` scroll events never reach Claude's web content. Post with `CGEvent.post(tap: .cgSessionEventTap)` with the pointer over the session, then `CGWarpMouseCursorPosition` puts the pointer back. A positive pixel delta scrolls the transcript down. Because the pointer is warped, any guard that counts mouse movement as the user's activity fires on Ensemble's own scrolling: guards count only key presses and clicks.
4. **Double-pinch timing comes from measured frames, never from intuition.** Check every change to the tap rules against the per-frame trace (hidden setting `detailedTrace`). Pinches within 0.7 s of a thumbs-up do not count (lowering a thumbs-up brushes thumb and index together). The window between the two pinches is 1.2 s; 0.6 s reset deliberate pairs. A hand in front of the face reads as a second face, so second-face detection is off.
5. **Overlay windows.** SwiftUI `.glassEffect` renders as a dark disc inside a transparent borderless panel; the nose dot is a separate small `NSPanel` holding `NSGlassEffectView`. SwiftUI insertions and removals animate only inside an animated change, so the view-level `.animation(value:)` on the shown session stays. An overlay panel waits 0.8 s before `orderOut` or every fade-out is cut off. `@Published` sinks fire before the stored value changes: read the value passed in, or dispatch to the next run-loop turn.
6. **Pausing other audio after macOS 15.4.** MediaRemote is closed to third-party apps. Use CoreAudio's `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default output to see whether anything plays, skip headphones, read and set the volume through `kAudioHardwareServiceDeviceProperty_VirtualMainVolume`, and send a synthetic play/pause key. The key can reach the wrong app, so the volume fade is the real protection. Save the volume before touching it so a crash is put right on the next launch.
7. **Resources in the bundle.** SwiftPM's `Bundle.module` fails inside the signed app. Resolve resources with `EnsembleResources.bundle`.
8. **Workflows.** Every `uses:` is a full commit SHA with a version comment; resolve a SHA with `gh api repos/<owner>/<repo>/commits/<tag> --jq .sha`. Top-level `permissions: {}`, each job declares its own, every checkout sets `persist-credentials: false`, no `${{ }}` inside a `run:` step (pass it through `env:`), and a `run:` step that pipes into `tee` needs `shell: bash` so the pipe fails the step. `release.yml` stays disabled on the repository until Developer ID signing exists.
9. **Values the owner set by hand.** Do not revert them without asking: focus follows the nose after 0.075 s with a 28 pt margin; hold-to-send defaults to 0.75 s; the highlight is a blue outline only, never red and never filled; the menu bar icon is three small dots (hollow off, filled on); every motion uses one smooth spring curve and fades are never instant.
10. **History.** The repository history was rewritten once to the no-reply address before it went public. Never merge a branch created before that rewrite; it carries the old address.

## Working rules

- Branch before editing; open a pull request; `ci` and `hygiene` must pass. No force-push to `main`, no `git add -A`, no amended commits, no skipped hooks.
- Commit messages state the outcome. No emojis in commits, code, comments or docs.
- Comments match the density of the surrounding code and explain why, not what. Delete dead code instead of hiding it.
- If a README or doc describes something you change (counts, commands, file names), update it in the same change.
- When a file is renamed, grep the repository for the old name (imports, workflows, scripts, docs) and fix every reference in the same change.

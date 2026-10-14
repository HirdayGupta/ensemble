# Contributing to Ensemble

Thank you for helping. Ensemble drives Claude desktop with a webcam and a user's hands, and it is installed on people's
own Macs, so the bar is trust first, features second. Read the trust rules below before you write code.

Coding agents read `AGENTS.md`; it holds the same commands and rules in a denser form. This file is for people.

## What you need

- A Mac with Apple Silicon, macOS 14.2 or later (developed on macOS 26), and a webcam.
- Swift 6.2 or newer. Apple's Command Line Tools are enough to build and test (`xcode-select --install`); Xcode is not
  required. Older tools lack the macOS 26 interfaces the app uses (Liquid Glass).
- [Claude desktop](https://claude.com/download) with Code sessions, to try the app end to end.
- `gh` for pull requests, and optionally [pre-commit](https://pre-commit.com) for the repository checks.

## Build, test, bundle, run

```
swift build                 # debug build
swift test                  # unit tests
scripts/bundle.sh           # release build -> build/Ensemble.app, code-signed
open build/Ensemble.app
```

With only the Command Line Tools installed, the tests need the Swift Testing framework paths:

```
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
swift test --enable-swift-testing -Xswiftc -F -Xswiftc $F -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $L
```

All tests must pass before you open a pull request. The tests live in `Tests/EnsembleCoreTests`; gesture timing is
replayed from recorded fixtures in `Tests/EnsembleCoreTests/Fixtures`, so a timing change is checked against real hands,
not against a guess.

### Signing

`scripts/bundle.sh` signs with a local code-signing certificate named `Ensemble Local Signing` and stops with an error if
it is missing. It never signs ad hoc, on purpose: macOS ties the Camera and Accessibility permissions to the app's
signature, and an ad-hoc signature is a new identity on every build, so the permissions would silently stop working after
each install. Create the certificate once in Keychain Access, Certificate Assistant, Create a Certificate (type: Code
Signing), or point `ENSEMBLE_SIGN_IDENTITY` at another identity. Keep using the same one; changing it makes macOS ask for
Camera and Accessibility again, and a permission that shows on but does not work is cleared with
`tccutil reset Accessibility dev.ensemble.app`.

### Running your build

Quit any installed Ensemble first. Open `build/Ensemble.app`, grant Camera and Accessibility, and choose Calibrate in the
menu bar panel. Claude desktop must be running with at least one Code session. The log is
`~/Library/Logs/Ensemble/ensemble.log`; the hidden setting `detailedTrace` (numbers and states only) adds a per-frame
trace for tuning gestures:

```
defaults write dev.ensemble.app detailedTrace -bool true    # then restart the app
```

For a Mac you develop on, `scripts/dev-install.sh` builds from source, installs the app and keeps it on the latest `main`
(see the README).

## Repository checks

CI runs the same checks you can run locally.

```
env -u GH_TOKEN -u GITHUB_TOKEN pre-commit run --all-files   # gitleaks (secrets) and zizmor (workflow security)
```

Unset the two variables: zizmor forwards any token it finds to github.com, and a placeholder token fails with a 401
instead of a clean finding. If you change a workflow, also run `actionlint` and `pinact run --check`. The pre-commit hooks
pin their tools to commit SHAs; do not loosen a pin to make a hook pass.

## The trust rules

These are not style preferences. A pull request that breaks one will not be merged, however useful it is.

1. **No network except the update feed.** The app makes no connection of its own. Sparkle may fetch the update feed, and
   only after the user turns on automatic checks or presses Check for Updates. The face tracker page, its WebAssembly and
   its model ship inside the app bundle and are served through the `ensemble-asset://` scheme. Do not add a network call,
   a remote script, a font or image fetched from the web, or a dependency that talks to the network. If you think the app
   needs one, open an issue first.
2. **No telemetry.** No analytics, no crash upload, no usage counts, no remote logging, not even opt-in.
3. **Camera frames stay in memory.** Frames are analysed and discarded. They are never written to disk and never sent
   anywhere. Logs hold events and numbers, never images and never the text of a draft.
4. **Nothing personal in the tree or in history.** No personal email addresses, machine paths, tokens, keys, names of
   private repositories, screenshots of private windows, or recordings of other people. The secrets scan covers the whole
   history, but it is not a substitute for looking at your own diff.
5. **Commit under a no-reply identity.** Use your GitHub no-reply address (GitHub, Settings, Emails, "Keep my email
   addresses private"): `git config user.email "<id>+<username>@users.noreply.github.com"` in this clone. GitHub refuses
   a push whose newest commit carries a private address, and it does not check older commits in the same push, so check
   `git log --format=%ae origin/main..HEAD` before you push. A wrong address in public history stays there.
6. **Dictation is never left recording because of Ensemble.** Anything that touches dictation or sending must keep the
   safety design in the README intact (written before pressed, dead-man check, standing check, narrow send rules, stop on
   typing or clicking). Say in the pull request how your change preserves it.
7. **Ensemble acts only on Claude.** With another app in front, gestures do nothing.
8. **Pin everything the build runs.** Every GitHub Action is a full commit SHA with the version in a trailing comment;
   workflows start from `permissions: {}`; no `${{ }}` expression inside a `run:` step (pass it through `env:`).
   Dependabot proposes bumps weekly.

## How a change flows

1. Open an issue for anything bigger than a bug fix, so the direction is agreed before you spend time.
2. Branch from current `main`; one change per branch. Do not work on `main`, and do not merge an old branch that predates the
   repository going public: its history was replaced and merging it brings the old commits back.
3. Make the change with a test when it touches `Sources/EnsembleCore`. If it changes behaviour a README, a doc or a count
   describes, update that in the same change.
4. Run `swift build`, the tests and the repository checks above.
5. Commit with a message that states the outcome ("Hold-to-send stops counting after a keystroke"), not the mechanism.
   No emojis in commits, code, comments or docs. Do not amend or force-push a branch someone has reviewed.
6. Open a pull request against `main`. `ci` (build, tests and the repository's own checks on a macOS runner) and `hygiene`
   (zizmor, pinact, secrets scan) must pass. A pull request that changes dictation, sending or the Accessibility bridge
   gets a manual check on a real Mac with Claude desktop; say what you ran.
7. The maintainer merges once the checks pass.

## Code structure

SwiftPM package with two targets plus a separate benchmark package.

| Path | What it is |
|---|---|
| `Sources/EnsembleCore` | The `EnsembleCore` target. Pure logic with no UI and no camera: gesture state machine, nose pointer (calibration fit plus a One Euro filter), covered-camera and multi-face detectors, the size-capped log file, dictation safety records, the frame-rate planner, and the hand-pose classifier adapted from Sleight (`Vendor/`). Unit-tested. |
| `Sources/Ensemble` | The `Ensemble` executable target, the menu bar app. |
| `Sources/Ensemble/Engine` | Camera capture, Apple Vision hand pose, MediaPipe Face Landmarker in a hidden `WKWebView`, and frame scheduling. |
| `Sources/Ensemble/Claude` | The Accessibility bridge: finds Claude's session panes, reads and presses its dictation and Send controls, runs the dictation safety checks, mutes the input device as a last resort. |
| `Sources/Ensemble/Coordinator` | Joins the engine and the bridge: turns gesture intents into actions on the session being looked at, after every safety guard has agreed. |
| `Sources/Ensemble/App` | The shell: menu bar, settings, calibration, status capsule and overlay, hotkey, notifications, Sparkle updater. |
| `Sources/Ensemble/Resources/web` | The bundled MediaPipe runtime, WebAssembly, model and tracker page. |
| `Tests/EnsembleCoreTests` | Swift Testing tests and the recorded gesture fixtures. |
| `Tools/PerfBench` | Separate package of camera-free micro-benchmarks (synthetic frames). |
| `scripts/` | `bundle.sh`, `release.sh`, `appcast.sh`, `dev-install.sh`, `dev-update.sh`, `make-icon.swift`. |
| `docs/RELEASING.md` | How a release is signed, notarized, published and delivered. |
| `.github/workflows` | `ci.yml` (build and test), `hygiene.yml` (workflow and secrets checks), `release.yml` (tag-triggered release, disabled until Developer ID signing exists). |

Rules of thumb: logic that can be tested without a camera belongs in `EnsembleCore`; only `Coordinator` decides to press
Claude's controls; frame scheduling stays in `Engine`.

## Lessons that were paid for

Ensemble has been broken in specific, repeatable ways, and the fixes are not obvious from the code. They are written down
in `AGENTS.md`, section "Gotchas that have cost incidents". Read it before you touch any of these:

- the signing identity and the Camera and Accessibility permissions;
- Claude desktop's accessibility labels, which are English strings of one Claude version;
- scrolling Claude, which works only through the session event tap;
- the double-pinch timing, which comes from measured frames;
- overlay windows and Liquid Glass animation;
- pausing other audio on macOS 15.4 and later;
- loading resources from the signed bundle;
- workflow pinning and permissions.

Values the owner chose by hand (focus delay, hold-to-send time, the blue outline, the menu bar icon, the motion curve) are
listed there too; do not change them without asking in an issue.

## Reporting problems

A bug: open an issue with your macOS version, Claude desktop version and the lines from the log around the problem (remove
anything you do not want shared). A security problem: do not open an issue; see `SECURITY.md`.

## Licence

By contributing you agree your work is released under the repository's MIT licence (`LICENSE`). Vendored code keeps its
own licence; see `THIRD_PARTY_NOTICES.md`.

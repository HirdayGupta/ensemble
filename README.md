# Clutch

Control Claude desktop's Code-tab sessions hands-free with a webcam. Clutch is a macOS menu-bar app (macOS 14+, Apple Silicon) that:

- highlights the Claude session you face, driven by your nose (head pose from MediaPipe Face Landmarker, smoothed with a One Euro filter);
- starts Claude's own dictation while you hold a fist, and stops when you let go;
- sends the dictated draft with a thumbs-up after a countdown you can cancel;
- scrolls the session while you point your index finger up or down, faster the longer you hold.

Status: MVP. The app shell (menu bar, settings, overlay, calibration, hotkey, notifications, icon, packaging) is in place; the camera pipeline and the Claude bridge are wired by the coordinator.

## Gestures

| Action | Default gesture | Notes |
|---|---|---|
| Talk | Fist (hold) | Release to stop. The microphone is never left recording. |
| Send | Thumbs up | Starts a countdown (1-5 s, default 2 s). Not available in unsafe modes. |
| Scroll up | Index finger pointing up (hold) | Starts after a quarter second, then scrolls continuously, ramping from about 300 to 1200 points per second over 1.5 s. Stops the moment you change pose. Can be turned off. |
| Scroll down | Index finger pointing down (hold) | Same as scroll up, the other way. Can be turned off. |
| Cancel | Open palm | Stops a pending send. Takes the leftover gesture if you remap the others. |

Gestures are remapped in Settings > Gestures. A gesture can only do one thing: picking one that is already in use swaps the two actions.

## Using it

1. Open the menu-bar icon, then Calibrate... A dot visits five spots on each screen; point your nose at it and keep your head still.
2. Turn Clutch on from the panel. Face a Claude session and it lights up.
3. `Option-Command-K` shows the same panel anywhere, as a floating glass panel. Esc closes it.

The menu-bar icon shows the state: raised hand (watching), slashed hand (off), a red dot (listening), slashed camera (camera covered).

"Clear and disarm" drops any pending send and stops listening immediately.

## Privacy

Video is analysed on this Mac and is never stored or sent. The camera is used for head direction and hand pose only. Clutch only acts on Claude.

## Build and run

```
swift build            # debug build
swift test             # core logic tests
scripts/bundle.sh      # release build -> build/Clutch.app (signed with the "Clutch Local Signing" identity)
open build/Clutch.app
```

`scripts/bundle.sh` signs with the identity named `Clutch Local Signing` (override with `CLUTCH_SIGN_IDENTITY`) and stops with an error if it is missing; it never signs ad-hoc, because an ad-hoc signature is a new identity on every build and macOS then asks for Camera and Accessibility again. Each build writes the signature's designated requirement to `build/designated-requirement.txt` and warns when it changes.

`swift scripts/make-icon.swift` redraws the app icon (`Assets/AppIcon.iconset`, `Assets/AppIcon.icns`, `Assets/logo.png`) from code.

### Resources in the packaged app

SwiftPM's generated `Bundle.module` looks in the app's top level, which code signing rejects, so the resource bundle ships in `Contents/Resources`. Use `ClutchResources.bundle` (not `Bundle.module`) to load the web assets. `Clutch --print-resource-path` prints where it resolved.

## Layout

- `Sources/ClutchCore` - gesture rules, state machine, nose pointer (no UI, unit-tested).
- `Sources/Clutch/App` - the shell: entry point, menu bar, settings, overlay, calibration, hotkey, notifications.
- `Sources/Clutch/Coordinator` - the coordinator contract (`AppCoordinating`, `makeCoordinator`).
- `Sources/Clutch/Resources/web` - MediaPipe runtime and face model.
- `scripts` - packaging and icon generation. `Assets` - icon sources.

## Credits

- MediaPipe - Apache-2.0, Google.
- Sleight - MIT, Florian Riquelme. Hand-pose classifier, vendored in `Sources/ClutchCore/Vendor/Sleight`.
- claude-dictation-hotkey - MIT. Dictation approach, license in `Sources/ClutchCore/Vendor`.

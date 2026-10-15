# Changelog

Each release and what changed. Back to the [README](../README.md).

## Unreleased

- Pointing follows your nose when you slide along the desk: Ensemble reads where your head is as well as which way it points, so the screen you aim at stays the one you aim at without recalibrating. It is on by default and can be switched off in Settings, Display, "Correct for where I sit". Calibrations saved before this version keep pointing by angle until you recalibrate.
- A five-step tour opens on first launch (look, calibrate, four gestures practised on a 3D hand, permissions), can be skipped at any step, and replays from the menu bar panel, the Option-Command-K panel or Settings. While its gesture step is open, gestures only drive the tour and nothing reaches Claude.

## 0.1.1

- The app is 6.9 MB instead of 19 MB, and the download 5.4 MB instead of 10 MB.
- The face tracker page is blocked from the internet, and every build checks that no network code or build-machine detail is inside the app.
- Other audio on your speakers fades out and pauses while you dictate; Claude's own start and stop sounds play normally.
- The island names the session and what Claude is doing: "Claude dictation on", "Sending in", "Sent in", "Activating".
- The double pinch follows a natural rhythm and ignores fingertips brushing as a thumbs-up is lowered.
- Focus follows your nose after 0.075 s; highlight fades use one smooth curve.
- The menu bar icon is three dots: hollow when off, filled when on.
- Turning Ensemble off stops any Claude dictation and confirms the microphone is off.

## 0.1.0

First release. Face a session to pick it, double pinch to dictate, hold a thumbs-up to send, pinch and drag to scroll.

- Requires an Apple Silicon Mac, macOS 14.2 or later, and a webcam.
- Video is analysed on your Mac and never stored or sent.
- A draft sends only in the moment you spoke it, to the session you spoke it to.
- No automatic updates yet: download each new version from the releases page.
- Tested against one Claude desktop version, in English.
- macOS shows the unidentified-developer warning until the app is signed and notarized.

# Changelog

Each release and what changed. Back to the [README](../README.md).

## Unreleased

- A thumbs-up send feels like one step: the island goes from "Sending" straight to "Sent" (or "Not sent" with the reason) instead of flicking back to the dictation and folding away first, and only the send sound plays. The fixed 0.6 s wait for Claude's transcript is replaced by waiting until the draft stops changing for 0.3 s, and Send's result is checked every 30 ms instead of every 100 ms.
- When macOS cannot read whether Claude is recording for 3 seconds while a dictation record is open, the alarm sounds and the input is muted, instead of waiting for a reading that may never come.
- A new dictation is refused while an earlier one's stop is unconfirmed, its alarm sounds or its safety mute is on, so that dictation's stop is never abandoned. The alarm now also ends when the microphone is confirmed off without a mute having been needed.
- Quitting while a dictation is starting waits for the start press before reading the microphone, so the safety record is not deleted moments before Claude's microphone opens.
- A dictation interrupted by sleep, a lock or the safety check while it was starting or stopping can no longer be sent by a later thumbs-up.
- The safety mute counts only when macOS accepts it and reads back silent, lands on the device of every Claude process the recording check counts (helpers included), and is undone when an unplugged device comes back.
- Starting a dictation, sending and switching off no longer read the audio system or wait on the safety check on the main thread, so a stalled audio device cannot freeze the app.
- Music paused for a dictation no longer resumes in the middle of the next one started within 0.7 s.
- The camera turns off while the Mac or display sleeps, the screen is locked or the screen saver runs, and Ensemble moves no focus meanwhile; it comes back on when you return.
- Moving or resizing the Claude window you are dictating into keeps the highlight and edge warnings on it.
- An automatic update no longer installs while a send is pending or a gesture is being held.

- The "Claude's microphone may still be on" alarm now always shows as a banner on the island and stays until the safety check confirms the microphone is off and the mute is undone, even when notifications are refused or a Focus mode hides them; the system notification is sent as well when allowed.
- On first launch the tour's Welcome step is no longer covered by the Accessibility prompt and the Camera request: the camera starts when the tour moves on to calibration, and the Accessibility prompt waits for the tour's permissions step or for the tour to close.
- The tour's Camera card now has three states: Allow (not asked yet), Open Settings with a plain explanation (denied), and Granted. The Accessibility Grant button also opens the Accessibility list in System Settings, because macOS shows its own prompt only once.
- Opened from the disk image or Downloads, Ensemble offers to move itself to Applications and reopens from there. Until then it refuses to turn on open at login and says why, instead of recording a path that goes away.
- The website and README now quote the current macOS 15 and later install wording (Apple could not verify the app; Done; Open Anyway asks for your Mac password). The live demo's no-JavaScript message is readable.
- The release workflow also uploads Ensemble.dmg, the fixed name the Download button links to, and stands down when scripts/ship-release.sh has already published the release.
- Return stops a dictation Ensemble started: the text stays unsent and Claude never sees that key, and the next Return sends as usual. Two quick Returns while you talk stop and then send, under the same rules as the thumbs-up; if the stop cannot be confirmed, the island says "Not sent". Only with Claude in front and only plain Return: Shift-Return and every other key are left alone. Starting a dictation also puts the keyboard in that session's message box while Claude is in front.
- Settings, Calibration can recalibrate one screen: pick it under Screens and press Calibrate this screen; every other screen keeps its calibration. Add position calibrates again from another place, such as standing or leaning back, and keeps it beside the ones you have; Ensemble uses, screen by screen, the saved position nearest where your head is (switching only once another is clearly nearer), Calibrate redoes the position in use, and Remove forgets one. Calibrations saved before this version become Position 1, nothing lost.
- Turning Ensemble off while a dictation is starting no longer leaves Claude's microphone recording: the start is waited for and, if it turns the microphone on, stopped at once, and the safety record is kept until the microphone is confirmed off.
- When macOS cannot say whether Claude is recording (the audio system restarting, say), Ensemble treats the microphone as possibly on: the safety record and any safety mute stay until a definite "off". On quit, a stop that finds no Claude session is no longer counted as confirmed.
- A thumbs-up sends nothing while another app is in front, even right after dictating; the island says "Not sent". This is checked when the gesture arrives and again right before Send is pressed.
- Next to every Check for Updates button (menu bar panel, Option-Command-K panel, Settings) Ensemble shows the version you have installed, and after a check it says "Ensemble 0.5.0 is available" or "Up to date". The latest version is learned only from a check you start or the automatic checks you turned on; nothing is fetched otherwise.
- With one chat session open in Claude, the highlight, focus and edge warnings cover just that session, not the whole window with its top bar and left navigation. Two or more sessions side by side are unchanged.
- Calibrate puts its full-screen window up at once, even when Ensemble was off or the camera is still starting; it says what it is waiting for ("Starting the camera...", "Looking for your face...") and shows the first dot only after a face reading arrives. The log records the time from click to window and from click to first face reading.
- A calibration dot is captured only when your head has turned toward it and holds still for 0.4 s; the ring does not fill before that. The text reads "Turn your nose to the dot", then "Move your head, not just your eyes" after 4 s, and after 12 s offers Skip this point or Retry (a skipped point leaves that screen uncalibrated).
- Calibration opens with "Found 2 screens", listing each screen's name, size, orientation and place in the display arrangement and the order they will be calibrated in, on every screen at once; each step names its screen ("Screen 2 of 2 - DELL U2723QE - turn to face it"). The menu bar panel says "Calibrated for 2 screens".
- A five-step tour opens on first launch (look, calibrate, four gestures shown in 3D scenes, permissions), can be skipped at any step, and replays from the menu bar panel, the Option-Command-K panel or Settings. While its gesture step is open, gestures only drive the tour and nothing reaches Claude, and the gestures step is one 3D scene (Claude's screen reacting to the hand) with a small overlay in its bottom-right corner that draws your hand's 21 joints as the camera reads them, with the gesture it recognises and a check mark when the open tab's gesture is done. The overlay holds coordinates only: no frame is stored or sent.
- Pointing follows your nose when you slide along the desk: Ensemble reads where your head is as well as which way it points, so the screen you aim at stays the one you aim at without recalibrating. It is on by default and can be switched off in Settings, Display, "Correct for where I sit". Calibrations saved before this version keep pointing by angle until you recalibrate.

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

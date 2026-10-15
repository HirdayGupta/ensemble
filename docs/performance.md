# Performance

How the app stays light, and how to measure it. Back to the [README](../README.md).

## Frame scheduling

The camera is locked to 30 frames a second at 640 by 480 where it offers that (`CameraFormatChoice`): the format with the fewest pixels from 640 by 480 to 1280 by 720 that reaches 30, uncompressed first, with both the minimum and maximum frame duration set to 1/30 s so a dim room cannot lengthen the exposure and halve the rate. AVFoundation on macOS has no control for a USB webcam's own "auto exposure priority"; a camera whose firmware still drops frames in low light (the log line "locked at 30 fps" is there, the panel's camera rate still shows fewer) needs more light. Center Stage is turned off for Ensemble's capture, because its cropping moves the head in the frame and breaks the calibration. The panel names both rates, "camera 30 fps · dot 75 Hz": the Logitech C920 offers no format above 30 fps, and the dot is redrawn on every refresh of the screen it is on regardless. A 60 fps camera (an iPhone through Continuity Camera offers one) is still locked to 30: the face tracker, the frame planner and the gesture timings are measured at 30 readings a second (gotchas, 4), and moving them is its own change.

Analyses are scheduled per frame. Hand pose runs on every frame only while a hand is in view and for 1 second after, while dictating, while a send is pending, while calibrating, or while a gesture is held. Otherwise it probes about 8 times a second. The face tracker gets a 320 by 240 frame on every frame, up to 30 a second; only one frame is in flight, so a slow machine skips frames rather than queueing them. Hand pose runs on its own queue, one frame at a time, and a frame that arrives while it is busy skips hand pose only. It used to run on the camera queue, which holds no frames back (late frames are discarded), so every frame that arrived during hand pose was lost to the face tracker as well: 721 to 886 head readings in 30 s from a 30 fps camera instead of about 900. After 3 seconds with no face, both drop to about 2 a second until a face returns, never while dictating. A camera restart (wake, a replugged camera) keeps the face tracker page loaded.

CPU: the face tracker running every frame instead of every second frame roughly doubles the work of the web content and GPU processes (one landmark pass per frame); hand pose, brightness and the idle slowdown are unchanged.

## Face frames

The face tracker page gets raw pixels, not an image file. The camera queue scales the frame to 320 pixels wide with vImage and swaps it to RGBA (`FrameAnalyzer.facePixels`), leaves it in a one-frame slot (`FaceFrameSlot`) under a number, and asks the page for that number; the page fetches `ensemble-asset://local/frame/<number>` from the app's own scheme handler, which hands the bytes out of memory once and empties the slot, and wraps them as ImageData for MediaPipe. It replaced a JPEG (quality 0.6) sent as base64 text inside `evaluateJavaScript` and decoded in the page. A frame is 307,200 bytes instead of about 8,900 bytes of base64, but nothing is encoded or decoded: on the bench below, 12.5 to 12.7 CPU ms per frame instead of 14.4 to 14.6 (about 13% less across the app, web content and GPU processes), half-way latency 14.6 to 16.5 ms instead of 18.7, and the web content process holds level (about 110 MB, no growth over 60 s). The frame never touches disk. Measured and not taken: BGRA wrapped as a VideoFrame (13.8 ms, no better than RGBA), raw bytes as a `callAsyncJavaScript` argument (WebKit refuses binary arguments), the CPU delegate (14.6 ms), and cropping the frame to the last face box (12.6 ms, but the landmarker's head matrix assumes the whole camera view, so head angles and position move with the crop, and its tracking lost the face on 58% of frames).

The landmarker computes only what the nose direction needs: one face, no blendshapes (that part is also cut from the bundled model), and the transformation matrix, which carries the head angles and the head position the pointer's sitting correction uses (gotchas, 12). MediaPipe's face detector alone (6 keypoints, already inside the landmarker bundle) costs about 9.0 CPU ms per frame instead of 12.5, but it gives no head position and only a flat 2D estimate of the turn, so it stays unused.

## Claude's accessibility tree

Reading Claude's tree costs Claude's own main thread a round trip per node. The session list refreshes every second while a face is in view, but a full walk (thousands of nodes per window) runs only when Claude's window list or frames change, a cached checkbox or pane stops answering, or every 10 seconds; otherwise the refresh reads each cached dictation checkbox and pane frame, three reads per session. A walk stops after 2 seconds, so a hung Claude cannot hold the bridge queue (`SessionScan`).

## The nose dot

Each head reading goes through a One Euro filter (`NosePointer`, strong smoothing when still and light when moving; the Settings slider picks how strong), then the rest rule (`NoseDot`: a resting dot ignores the nose until it is 32 pt away for 3 readings in a row, then follows it exactly and rests again where it stops), then a critically damped spring (`DotSpring`) that moves the dot's window on every screen refresh, so it glides between the 30 readings a second at 50 to 120 Hz. Focus decisions use the filtered reading, not the drawn dot.

The filter is restarted only when the calibration it maps through actually changes (a new calibration, another camera, a screen added, removed or moved). The camera engine repeats the camera in use with every frame-rate reading, about once a second, and each repeat used to re-decide the desk setup and refit the pointer, which restarted the filter: the next reading went through unsmoothed and the dot hitched about once a second. A repeated report is now ignored, a refit with the same samples keeps the filter (`SetupChangeFilter`, `NosePointer.fit`), and at launch the pointer is fitted from the saved profile of the camera used last instead of waiting for the camera's first report.

The dot's position and the highlighted pane are not published to SwiftUI: they change on every reading, and publishing them re-rendered Settings and the menu 30 times a second. Claude's process id is looked up at most once a second and the connected screens' ids once per screen change, not on every reading.

With `detailedTrace` on, the trace records how long each face frame held the gate and how many frames it turned away, how long hand pose took on each frame, and each frame whose hand pose was skipped.

`perfbench pointer [noise=0.004]` replays synthetic head paths through that pipeline at a 60 Hz display and reports jitter while still, the time to cover 90% of a 300 pt step, how far the dot rests from the aim, and judder while panning; `sweep` adds a grid of filter settings.

## Benchmarks

`Tools/PerfBench` is a separate Swift package of camera-free micro-benchmarks on synthetic frames and head paths. It never touches the camera or the installed app.

| Command | What it measures |
|---|---|
| `swift build -c release && .build/release/perfbench native` | Frame preparation and Apple Vision. |
| `perfbench web [transfer=pull, b64 or bgra] [sec=15] [hz=30] [delegate=GPU or CPU] [model=landmarker or detector] [max-cpu-ms=N] [max-growth-mb=N]` | The face pipeline on synthetic frames: frames answered per second, bytes per frame, latency, CPU ms per frame and CPU per second of the harness (frame preparation, as the app's camera queue), the web content process and the GPU process, and memory at start, peak and end. `pull` loads the app's own `head.html`; `b64` is the old JPEG protocol, for before and after. The limits make it exit 1, for a local check before a change to the face pipeline. |
| `perfbench pointer [noise=0.004] [sweep]` | How the nose dot moves: jitter, step lag, rest error and judder, before and after. |

Run them from inside `Tools/PerfBench`. The web bench needs a logged-in Mac with a GPU and is too noisy for a CI threshold (the same run moved from 30 to 25 frames a second under other load), so it is a local check: run `perfbench web sec=15 max-cpu-ms=15 max-growth-mb=20` before and after a change to the face pipeline and put both lines in the pull request.

## Size

CI fails if the built app passes the byte budget set in `scripts/check-size.sh`.

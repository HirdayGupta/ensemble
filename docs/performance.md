# Performance

How the app stays light, and how to measure it. Back to the [README](../README.md).

## Frame scheduling

The camera is locked to 30 frames a second at 640 by 480 where it offers that (`CameraFormatChoice`): the format with the fewest pixels from 640 by 480 to 1280 by 720 that reaches 30, uncompressed first, with both the minimum and maximum frame duration set to 1/30 s so a dim room cannot lengthen the exposure and halve the rate. AVFoundation on macOS has no control for a USB webcam's own "auto exposure priority"; a camera whose firmware still drops frames in low light (the log line "locked at 30 fps" is there, the panel's camera rate still shows fewer) needs more light. Center Stage is turned off for Ensemble's capture, because its cropping moves the head in the frame and breaks the calibration. The panel names both rates, "camera 30 fps · dot 75 Hz": the Logitech C920 offers no format above 30 fps, and the dot is redrawn on every refresh of the screen it is on regardless. A 60 fps camera (an iPhone through Continuity Camera offers one) is still locked to 30: the face tracker, the frame planner and the gesture timings are measured at 30 readings a second (gotchas, 4), and moving them is its own change.

Analyses are scheduled per frame. Hand pose runs on every frame only while a hand is in view and for 1 second after, while dictating, while a send is pending, while calibrating, or while a gesture is held. Otherwise it probes about 8 times a second. The face tracker gets a 320 by 240 frame on every frame, up to 30 a second; only one frame is in flight, so a slow machine skips frames rather than queueing them. Hand pose runs on its own queue, one frame at a time, and a frame that arrives while it is busy skips hand pose only. It used to run on the camera queue, which holds no frames back (late frames are discarded), so every frame that arrived during hand pose was lost to the face tracker as well: 721 to 886 head readings in 30 s from a 30 fps camera instead of about 900. After 3 seconds with no face, both drop to about 2 a second until a face returns, never while dictating. A camera restart (wake, a replugged camera) keeps the face tracker page loaded.

CPU: the face tracker running every frame instead of every second frame roughly doubles the work of the web content and GPU processes (JPEG encode, decode and one landmark pass per frame); hand pose, brightness and the idle slowdown are unchanged.

## Claude's accessibility tree

Reading Claude's tree costs Claude's own main thread a round trip per node. Claude tells Ensemble when its windows and panes change (`ClaudeWatcher`: accessibility notifications for window moves, resizes and new windows, divider and dictation-checkbox values, and destroyed windows, panes and checkboxes; NSWorkspace for Claude launching, quitting and coming to the front, and for Space changes). The session check still runs every second while a face is in view (every 5 seconds otherwise), but it reads only each cached dictation checkbox, one read per session, so a dictation Claude runs on its own is seen exactly as soon as before. The pane frames are read, one read per pane, only when a notification or the window server's list (which costs Claude nothing) says something moved; a burst of notifications (a window dragged, a divider moved) is folded into one read 100 ms after the first. A full walk runs when a window opens, closes or leaves the screen, a cached element is destroyed or stops answering, a pane changes size inside a window that did not (a pane opened or closed, or a divider moved), and otherwise every 15 seconds, the net for a notification Chromium did not post. Before, every check read the checkbox and the pane frame (three reads per session), any window move or resize walked the tree on every check while it lasted, and the walk ran every 10 seconds. Without the notifications (the observer could not be created), and during Ensemble's own width steps, the check works the old way (`SessionScan.plan`). A walk stops after 2 seconds, so a hung Claude cannot hold the bridge queue.

Measured on 2026-10-15 with a read-only harness that makes the same reads as the old and the new check, one to four sessions open (the owner was using Claude), two interleaved 126 s runs each: the time Claude spent answering fell from 12.9 and 5.4 ms a second to 4.8 and 3.1 (about half), and the harness's own CPU from 0.14 and 0.06% to 0.06 and 0.04%. Claude's whole-process CPU in `top` (2 s samples) moved more with what the owner was doing than with the check (7.8 to 8.2% with no check at all), so it cannot show a difference this small. The saving is modest because the walk skips the transcripts and costs a few hundred reads; the larger win is during a window drag or resize, which used to walk the tree every second until it stopped.

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
| `perfbench web transfer=b64 w=320 h=240 hz=30 sec=10 [delegate=GPU or CPU] [face=0 or 1]` | CPU of the harness, the web content process and the GPU process while the bundled face tracker runs. |
| `perfbench pointer [noise=0.004] [sweep]` | How the nose dot moves: jitter, step lag, rest error and judder, before and after. |

Run them from inside `Tools/PerfBench`.

## Size

CI fails if the built app passes the byte budget set in `scripts/check-size.sh`.

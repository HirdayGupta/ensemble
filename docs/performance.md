# Performance

How the app stays light, and how to measure it. Back to the [README](../README.md).

## Frame scheduling

The camera runs at its own rate and analyses are scheduled. Hand pose runs on every frame only while a hand is in view and for 1 second after, while dictating, while a send is pending, while calibrating, or while a gesture is held. Otherwise it probes about 8 times a second. The face tracker gets a 320 by 240 frame about 15 times a second. After 3 seconds with no face, both drop to about 2 a second until a face returns, never while dictating.

## Benchmarks

`Tools/PerfBench` is a separate Swift package of camera-free micro-benchmarks on synthetic frames. It never touches the camera or the installed app.

| Command | What it measures |
|---|---|
| `swift build -c release && .build/release/perfbench native` | Frame preparation and Apple Vision. |
| `perfbench web transfer=b64 w=320 h=240 hz=15 sec=10 [delegate=GPU or CPU] [face=0 or 1]` | CPU of the harness, the web content process and the GPU process while the bundled face tracker runs. |

Run both from inside `Tools/PerfBench`.

## Size

CI fails if the built app passes 7.4 MB, through `scripts/check-size.sh`.

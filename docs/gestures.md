# Gestures and settings

What each gesture does and what Settings can change. The overview is in the [README](../README.md).

## Gestures

| Do this | What happens |
|---|---|
| Look at a Claude session | That session is the target of every gesture. Looking at a different session while listening pauses dictation after 2 seconds. |
| Pinch thumb and index twice, quickly | Starts listening through Claude's own dictation. Do it again to stop. Your hand can leave the frame in between. |
| Hold a thumbs-up | Sends the dictated draft. The default hold is 0.75 seconds, adjustable from 0.5 to 3 seconds in Settings. It works only within 30 seconds of dictation ending. |
| Press the headphone stem once (Bluetooth output) | Same as the double pinch, in the session you are looking at: starts dictation, or stops it. Refused with the usual message when no session is targeted, Claude is not in front or the calibration is missing. |
| Press the headphone stem twice | Same as the thumbs-up: sends the dictated draft under the same rules. |
| Pinch and drag up or down | Scrolls the session, at your system's scroll direction and speed. A fast release carries on with momentum, a slow release stops dead. |

Ensemble does no speech recognition of its own. The status capsule at the top of the screen, a floating one on screens without a notch, names the state and the session. Option-Command-K opens the control panel from anywhere.

## Settings

| Group | What you can change |
|---|---|
| General | Turn Ensemble on or off, open at login (restarts after a crash), play sounds, fade out and pause other audio while dictating. |
| Gestures | Remap gestures, including turning the thumbs-up send off, and the hold time. Headphone presses on or off (on by default). |
| Display | Show the nose dot, highlight the session you face, pointer smoothing, live sound bars (asks for microphone access), reverse the pinch-and-drag direction, the send countdown. |
| Calibration | Recalibrate the nose pointer after you move your seat or change monitors. |
| About | Check for updates automatically, once a day. Off until the updater is configured. |

## Audio pause

While you dictate, other audio on speakers fades out in 0.25 seconds and pauses, then resumes and fades back in over 0.4 seconds. Headphones are left alone. The volume is saved before it is touched, so a crash puts it right on the next launch. The setting is on by default.

## Headphone presses

macOS delivers a stem press only to the app it treats as Now Playing: a single press arrives as play/pause, a double press as next track (older AirPods' double-tap, if set to those). Ensemble claims Now Playing without playing any sound, only while the setting is on, the output is Bluetooth, Claude is running and no other app is playing audio. If music starts, Ensemble lets go at once and presses control the music. The press-and-hold mute goes to the app using the microphone, which is Claude, so Ensemble cannot use it. A play/pause key that Ensemble sends itself for the audio pause is ignored for 1.5 seconds so it can never count as a press.

## Hidden setting

`detailedTrace` writes a per-frame trace of numbers and states for tuning gestures, never images. It is off by default and rolls over at 20 MB. The command to turn it on is in the [contributing guide](../.github/CONTRIBUTING.md).

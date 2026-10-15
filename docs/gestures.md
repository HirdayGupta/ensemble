# Gestures and settings

What each gesture does and what Settings can change. The overview is in the [README](../README.md).

## Gestures

| Do this | What happens |
|---|---|
| Look at a Claude session | That session is the target of every gesture. Looking at a different session while listening pauses dictation after 2 seconds, once your nose is at least 15 percent of that session's width (or height) inside it. |
| Pinch thumb and index twice, quickly | Starts listening through Claude's own dictation. Do it again to stop. Your hand can leave the frame in between. |
| Hold a thumbs-up | Sends the dictated draft. The default hold is 0.75 seconds, adjustable from 0.5 to 3 seconds in Settings. It works only within 30 seconds of dictation ending. |
| Pinch and drag up or down | Scrolls the session, at your system's scroll direction and speed. A fast release carries on with momentum, a slow release stops dead. |

Ensemble does no speech recognition of its own. The status capsule at the top of the screen, a floating one on screens without a notch, names the state and the session. Option-Command-K opens the control panel from anywhere.

## Warnings while you dictate

Only while dictating, and only when your look is heading out of the session you dictate into. The outer 15 percent of that session is the warning band.

| What lies beyond that edge | What you see |
|---|---|
| Another Claude session | The edge you share with it lights up blue, brighter as your nose nears it, with its name beside it. That session gets a dashed blue outline and a name chip, a thin dashed line runs from your session to your nose, and the island's session columns lean toward its column. Once your nose is across, the line turns amber and the shared edge fills amber as the 2-second switch wait runs. Looking back before it fills changes nothing. |
| Anything that is not Claude | The whole edge glows amber, brighter as your nose nears it. Turn it off with Settings, Gestures, Warn when my look leaves Claude. |

Two guards apply only while dictating. The switch wait does not advance while you are speaking and resumes after about 0.6 seconds of quiet; it reads the input level, which exists only when live sound bars are on and the microphone is allowed, so without that the speaking guard is inactive. And a look counts as resting on another session only once your nose is 15 percent of its width (height for a session above or below) inside it.

## Settings

| Group | What you can change |
|---|---|
| General | Turn Ensemble on or off, open at login (restarts after a crash), play sounds, fade out and pause other audio while dictating. |
| Gestures | Remap gestures, including turning the thumbs-up send off, and the hold time. Warn when my look leaves Claude (on by default). |
| Display | Show the nose dot, highlight the session you face, pointer smoothing, live sound bars (asks for microphone access), reverse the pinch-and-drag direction, the send countdown. |
| Calibration | Recalibrate the nose pointer after you move your seat or change monitors. |
| About | Check for updates automatically, once a day. Off until the updater is configured. |

## Audio pause

While you dictate, other audio on speakers fades out in 0.25 seconds and pauses, then resumes and fades back in over 0.4 seconds. Headphones are left alone. The volume is saved before it is touched, so a crash puts it right on the next launch. The setting is on by default.

## Hidden setting

`detailedTrace` writes a per-frame trace of numbers and states for tuning gestures, never images. It is off by default and rolls over at 20 MB. The command to turn it on is in the [contributing guide](../.github/CONTRIBUTING.md).

# Safety, permissions and privacy

The rule: Claude's microphone is never left recording because of Ensemble. The summary a reader needs is in the [README](../README.md).

## Safety design

| Check | What it does |
|---|---|
| Written before pressed | A record of "dictation started" is saved and flushed to disk before the microphone button is pressed. If the app crashes mid-recording, the next launch finds the record and stops it. |
| Dead-man check | While listening, the app must keep confirming it is alive roughly every second, or dictation is stopped. |
| Standing check | A timer verifies, even when nothing seems wrong, that Claude's microphone state matches what Ensemble believes. |
| Fallback | If a stop cannot be confirmed, Ensemble sounds an alarm and mutes the input device Claude is using, recording the change so it can be undone later. |
| Only a definite "off" counts | The record is deleted, and the safety mute undone, only when macOS says plainly that Claude is not recording. An unreadable reading (the audio system restarting, say) counts as possibly recording, and a stop that finds no Claude session to press is not counted as a stop. |
| Switching off | Turning Ensemble off (or the automatic switch-off after a Claude update) stops any dictation and confirms the microphone is off before the record is cleared. A start press still in flight is waited for, up to 8 seconds; if it turns the microphone on, it is stopped at once. If it is still in flight after 8 seconds, the record stays, the dictation is stopped the moment the press lands, and the standing check clears the record once the microphone is off. |
| Quitting | Quitting stops dictation before the process exits. A stop that cannot be confirmed with a definite "off" leaves the record and mutes the input, and the next launch puts it right. |
| Refusals | Dictation stops and gestures are refused when you type or click, when more than one face is in view, when no face has been seen for 10 seconds, when the camera is covered, when another app starts using a microphone, when the input device changes, when the Mac sleeps, the screen locks or the screen saver starts, or when Claude quits. |
| Narrow send | Send needs Claude to be the app in front, a non-empty draft, dictation that ended in the last 30 seconds, and no keyboard or mouse use since. Claude being in front is checked when the thumbs-up arrives and again right before Send is pressed; otherwise the island says "Not sent". A draft you walked away from can never go out later from a stray gesture. |

Sending by gesture is not restricted by Claude's permission mode. Turn gesture send off in Settings to press Send yourself.

## Permissions

| Permission | Why |
|---|---|
| Camera | Reads your head direction and hand pose. Frames are analysed in memory and discarded. |
| Accessibility | Finds Claude's session panes and presses its dictation, Send and scroll controls. |
| Microphone, optional | Loudness only, for the live sound bars while Claude is listening. Never recorded. |
| Notifications, optional | Alerts and sound cues when a safety check refuses or stops something. |

Ensemble asks for the Microphone permission only for the live sound bars, and only when that setting is on, while Claude is listening. It reduces the input to one loudness number to animate the bars; the audio is never recorded, stored or sent. With the setting off, Ensemble never touches the microphone: Claude records, and Ensemble only watches which apps are recording. A Microphone permission request would appear the first time the bars are turned on.

## Privacy

- Video is analysed on your Mac. Frames are never written to disk and never sent anywhere.
- The face tracker is a web page served from inside the app through a custom address scheme, its model ships in the app, and every web address it could load is blocked.
- The only files written are settings, a small log rolled over at 1 MB with one backup, and the two safety records above.

The full table of what the app touches is in [SECURITY.md](../SECURITY.md).

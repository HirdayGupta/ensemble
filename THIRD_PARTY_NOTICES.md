# Third-party notices

Clutch bundles the following third-party code and models. Each keeps its own license.

| Component | Where it lives | Author | License |
|---|---|---|---|
| MediaPipe Tasks Vision (JavaScript runtime and WebAssembly) | `Sources/Clutch/Resources/web/vision_bundle.mjs`, `Sources/Clutch/Resources/web/wasm/` | Google | Apache-2.0 |
| MediaPipe Face Landmarker model (`face_landmarker.task`) | `Sources/Clutch/Resources/web/face_landmarker.task` | Google | See the note below |
| Sleight (hand-pose classifier rules, adapted) | `Sources/ClutchCore/Vendor/Sleight/` | Florian Riquelme | MIT |
| claude-dictation-hotkey (approach to driving Claude's dictation) | `Sources/ClutchCore/Vendor/LICENSE-claude-dictation-hotkey` | Rene Banuelos | MIT |

Apple's Vision, AVFoundation, WebKit and ApplicationServices frameworks are system frameworks and are not redistributed.

## MediaPipe (Apache-2.0)

The runtime in `vision_bundle.mjs` and `wasm/` is built from the MediaPipe project, <https://github.com/google-ai-edge/mediapipe>, which is licensed under the Apache License, Version 2.0. The license text is at <https://www.apache.org/licenses/LICENSE-2.0>. The files were vendored from a MediaPipe release.

## MediaPipe Face Landmarker model

`face_landmarker.task` is the model package that Google publishes for the MediaPipe Face Landmarker task. It combines three models, each with a published model card:

- BlazeFace (short range): <https://storage.googleapis.com/mediapipe-assets/MediaPipe%20BlazeFace%20Model%20Card%20(Short%20Range).pdf>
- Face Mesh V2: <https://storage.googleapis.com/mediapipe-assets/Model%20Card%20MediaPipe%20Face%20Mesh%20V2.pdf>
- Blendshape V2: <https://storage.googleapis.com/mediapipe-assets/Model%20Card%20Blendshape%20V2.pdf>

The Face Landmarker documentation page does not state a license for the model file itself, only for the page and its code samples. TODO(owner): read the three model cards, confirm the license that applies to the model file, and replace this paragraph with the confirmed license name and text before the first public release.

## Sleight (MIT)

Source: Florian Riquelme's Sleight, the hand-pose rules adapted in `Sources/ClutchCore/Vendor/Sleight/`. Clutch adds the gather, point-up and point-down poses. The original license is kept in `Sources/ClutchCore/Vendor/Sleight/LICENSE-sleight`:

```
MIT License

Copyright (c) 2026 Florian Riquelme

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## claude-dictation-hotkey (MIT)

Clutch's way of starting and stopping Claude's own dictation follows the approach of claude-dictation-hotkey. The original license is kept in `Sources/ClutchCore/Vendor/LICENSE-claude-dictation-hotkey`:

```
MIT License

Copyright (c) 2026 Rene Banuelos

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

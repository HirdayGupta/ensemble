import Foundation

// `transfer=pull` (the default) loads the app's own head.html and head.js, so its numbers are the app's. This page
// carries the alternatives measured against it: the old JPEG-as-base64 protocol (`b64`), raw BGRA wrapped as a
// VideoFrame (`bgra`), and MediaPipe's face detector, 6 keypoints, as a yaw and pitch source (`model=detector`).
let benchPage = #"""
<!doctype html><html><head><meta charset="utf-8"></head><body>
<script type="module">
import { FilesetResolver, FaceLandmarker, FaceDetector } from './vision_bundle.mjs';
const post = (m) => window.webkit.messageHandlers.head.postMessage(m);
const BASE = 'ensemble-asset://local';
const q = new URLSearchParams(location.search);
const delegate = q.get('delegate') || 'GPU';
const model = q.get('model') || 'landmarker';
let tracker = null, lastTs = 0;
async function init() {
  try {
    const fileset = await FilesetResolver.forVisionTasks(BASE + '/wasm');
    if (model === 'detector') {
      tracker = await FaceDetector.createFromOptions(fileset, {
        baseOptions: { modelAssetPath: BASE + '/face_detector.tflite', delegate }, runningMode: 'VIDEO' });
    } else {
      tracker = await FaceLandmarker.createFromOptions(fileset, {
        baseOptions: { modelAssetPath: BASE + '/face_landmarker.task', delegate }, runningMode: 'VIDEO', numFaces: 1,
        outputFaceBlendshapes: false, outputFacialTransformationMatrixes: true });
    }
    post({ ready: true, delegate });
  } catch (e) { post({ error: String(e && e.message ? e.message : e) }); }
}
function decode(b64) {
  const bin = atob(b64); const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return createImageBitmap(new Blob([bytes], { type: 'image/jpeg' }));
}
function run(src, t, w, h) {
  lastTs = Math.max(lastTs + 1, Math.round(t * 1000));
  const result = tracker.detectForVideo(src, lastTs);
  if (model === 'detector') {
    const d = (result.detections || [])[0];
    if (!d || !d.keypoints || d.keypoints.length < 6) return { t, faces: 0 };
    // Keypoints: right eye, left eye, nose tip, mouth, right ear, left ear (normalised; scaled to pixels here).
    const k = d.keypoints.map(p => ({ x: p.x * w, y: p.y * h }));
    const earMid = { x: (k[4].x + k[5].x) / 2, y: (k[4].y + k[5].y) / 2 }, eyeMid = { x: (k[0].x + k[1].x) / 2, y: (k[0].y + k[1].y) / 2 };
    const span = Math.hypot(k[5].x - k[4].x, k[5].y - k[4].y) || 1, drop = Math.hypot(k[3].x - eyeMid.x, k[3].y - eyeMid.y) || 1;
    return { t, faces: result.detections.length, yaw: (k[2].x - earMid.x) / span, pitch: (eyeMid.y - k[2].y) / drop + 0.5 };
  }
  const mats = result.facialTransformationMatrixes, lms = result.faceLandmarks || [];
  if (!lms.length || !mats || !mats.length) return { t, faces: 0 };
  const m = mats[0].data;
  return { t, faces: lms.length, yaw: Math.atan2(m[8], m[10]), pitch: Math.asin(Math.max(-1, Math.min(1, m[9]))), x: m[12], y: m[13], z: m[14] };
}
async function guarded(t, body) {
  try { post(await body()); } catch (e) { post({ t, frameError: String(e && e.message ? e.message : e) }); }
}
// b64: the old protocol (JPEG as base64 in an evaluateJavaScript string).
window.frameB64 = (b64, t, w, h) => guarded(t, async () => { const bmp = await decode(b64); try { return run(bmp, t, w, h); } finally { bmp.close(); } });
// Raw pixels fetched from the scheme handler, as the app does: RGBA as ImageData, or BGRA wrapped as a VideoFrame.
window.frameRaw = (n, t, w, h, bgra) => guarded(t, async () => {
  const buf = await (await fetch(BASE + '/frame/' + n)).arrayBuffer();
  if (!bgra) return run(new ImageData(new Uint8ClampedArray(buf), w, h), t, w, h);
  const vf = new VideoFrame(new Uint8Array(buf), { format: 'BGRA', codedWidth: w, codedHeight: h, timestamp: Math.round(t * 1e6) });
  try { return run(vf, t, w, h); } finally { vf.close(); }
});
init();
</script></body></html>
"""#

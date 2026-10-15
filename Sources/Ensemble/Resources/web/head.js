import { FilesetResolver, FaceLandmarker } from './vision_bundle.mjs';

const post = (m) => window.webkit.messageHandlers.head.postMessage(m);
const BASE = 'ensemble-asset://local';

let landmarker = null;
let delegate = null;
let lastTs = 0;

window.addEventListener('error', (e) => post({ log: 'window error: ' + e.message }));
window.addEventListener('unhandledrejection', (e) => post({ log: 'unhandled rejection: ' + e.reason }));

async function create(which) {
  const fileset = await FilesetResolver.forVisionTasks(BASE + '/wasm');
  const lm = await FaceLandmarker.createFromOptions(fileset, {
    baseOptions: { modelAssetPath: BASE + '/face_landmarker.task', delegate: which },
    runningMode: 'VIDEO',
    // Only the nose direction is needed: one face (a raised hand was misread as a second face), no blendshapes, and
    // the transformation matrix, which carries both the head angles and the head position.
    numFaces: 1,
    outputFaceBlendshapes: false,
    outputFacialTransformationMatrixes: true,
  });
  landmarker = lm;
  delegate = which;
}

async function init() {
  try {
    try {
      await create('GPU');
    } catch (gpuError) {
      post({ log: 'GPU delegate failed, using CPU: ' + gpuError });
      await create('CPU');
    }
    post({ ready: true, delegate });
  } catch (e) {
    post({ error: String(e && e.message ? e.message : e) });
  }
}

// The engine leaves raw RGBA pixels at /frame/<number> and asks for them; no image encoding on either side.
async function fetchFrame(number, width, height) {
  const response = await fetch(BASE + '/frame/' + number);
  if (!response.ok) throw new Error('frame ' + number + ' unavailable');
  return new ImageData(new Uint8ClampedArray(await response.arrayBuffer()), width, height);
}

function detect(image, t) {
  lastTs = Math.max(lastTs + 1, Math.round(t * 1000));
  return landmarker.detectForVideo(image, lastTs);
}

// Column-major 4x4 head transform: yaw from the forward axis, pitch from the up axis' z component.
// The same matrix carries the head position in m[12], m[13], m[14] (centimetres, camera space).
function angles(m) {
  const yaw = Math.atan2(m[8], m[10]);
  const pitch = Math.asin(Math.max(-1, Math.min(1, m[9])));
  return { yaw, pitch };
}

async function processFrame(number, width, height, t) {
  try {
    if (!landmarker) throw new Error('face tracker not ready');
    const image = await fetchFrame(number, width, height);
    let result;
    try {
      result = detect(image, t);
    } catch (e) {
      if (delegate !== 'GPU') throw e;
      post({ log: 'GPU detection failed, switching to CPU: ' + e });
      landmarker.close();
      lastTs = 0;
      await create('CPU');
      result = detect(image, t);
    }
    const faces = (result.faceLandmarks || []).length;
    const mats = result.facialTransformationMatrixes;
    if (faces > 0 && mats && mats.length > 0) {
      const m = mats[0].data;
      const { yaw, pitch } = angles(m);
      // Translation is the head position in centimetres; the pointer uses it to correct for where you sit.
      post({ t, yaw, pitch, faces, x: m[12], y: m[13], z: m[14] });
    } else {
      post({ t, faces });
    }
  } catch (e) {
    post({ t, frameError: String(e && e.message ? e.message : e) });
  }
}

// Returns nothing: evaluateJavaScript cannot carry a Promise back. The answer arrives via postMessage.
window.ensembleFrame = (number, width, height, t) => { processFrame(number, width, height, t); };

init();

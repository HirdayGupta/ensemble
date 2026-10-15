// Loads the MediaPipe runtime and the two models on demand, and runs them. Everything is same-origin: the runtime and
// the models ship gzipped (GitHub Pages does not compress .wasm or .task) and are inflated here with DecompressionStream.

import { anglesFromMatrix, noseOffset } from './logic.js';

const here = (p) => new URL(p, import.meta.url).href;

// Compressed sizes on the wire; the progress bar sums these. The loader script is fetched by the runtime itself.
export const ASSETS = {
  bundle: { url: 'vendor/vision_bundle.js', bytes: 136870 },
  loader: { url: 'vendor/wasm/vision_wasm_internal.js', bytes: 209826 },
  wasm: { url: 'vendor/wasm/vision_wasm_internal.wasm.gz', bytes: 2857519 },
  face: { url: 'models/face_landmarker.task.gz', bytes: 2496541 },
  hand: { url: 'models/gesture_recognizer.task.gz', bytes: 6320973 },
};
export const TOTAL_BYTES = Object.values(ASSETS).reduce((a, x) => a + x.bytes, 0);

const SIMD = new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 96, 0, 1, 123, 3, 2, 1, 0, 10, 10, 1, 8, 0, 65, 0, 253, 15, 253, 98, 11]);

/** A plain-words reason this browser cannot run the trackers, or null. */
export function unsupportedReason() {
  if (typeof WebAssembly !== 'object') return 'This browser has no WebAssembly, which the trackers need.';
  let simd = false;
  try { simd = WebAssembly.validate(SIMD); } catch { simd = false; }
  if (!simd) return 'This browser is too old for the trackers (WebAssembly SIMD is missing).';
  if (typeof DecompressionStream !== 'function') return 'This browser is too old to unpack the trackers (DecompressionStream is missing).';
  if (!window.isSecureContext) return 'Camera access needs a secure page (https).';
  if (!navigator.mediaDevices?.getUserMedia) return 'This browser cannot reach a camera.';
  return null;
}

async function fetchBytes(url, { gz, signal, onBytes }) {
  const res = await fetch(url, { signal });
  if (!res.ok) throw new Error(`${url}: ${res.status}`);
  const reader = res.body.getReader();
  const chunks = [];
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value); onBytes?.(value.length);
  }
  const blob = new Blob(chunks);
  if (!gz) return blob.arrayBuffer();
  return new Response(blob.stream().pipeThrough(new DecompressionStream('gzip'))).arrayBuffer();
}

export class Trackers {
  constructor() {
    this.delegate = null;
    this.face = null; this.hand = null; this.lastFaceTs = 0; this.lastHandTs = 0;
    this.blobUrl = null; this.mp = null; this.buffers = null; this.fileset = null;
    this.stats = { face: { n: 0, sum: 0, last: 0, max: 0 }, hand: { n: 0, sum: 0, last: 0, max: 0 } };
  }

  /** Downloads and starts both trackers. `onProgress(fraction, label)`; `signal` aborts the downloads. */
  async load({ onProgress, signal, log = () => {} }) {
    let got = 0;
    const count = (n) => { got += n; onProgress?.(Math.min(got / TOTAL_BYTES, 1)); };
    const fetchAll = (a, gz) => fetchBytes(here(a.url), { gz, signal, onBytes: count });
    const [mp, wasm, face, hand] = await Promise.all([
      import(here(ASSETS.bundle.url)).then((m) => { count(ASSETS.bundle.bytes); return m; }),
      fetchAll(ASSETS.wasm, true), fetchAll(ASSETS.face, true), fetchAll(ASSETS.hand, true),
    ]);
    this.mp = mp; this.buffers = { face, hand };
    this.blobUrl = URL.createObjectURL(new Blob([wasm], { type: 'application/wasm' }));
    this.fileset = { wasmLoaderPath: here(ASSETS.loader.url), wasmBinaryPath: this.blobUrl };
    onProgress?.(0.97, 'Starting the trackers');
    try {
      await this.create('GPU');
      log('GPU delegate ready');
    } catch (gpuError) {
      log('GPU delegate failed, using CPU: ' + (gpuError?.message || gpuError));
      await this.create('CPU');
    }
    count(ASSETS.loader.bytes);   // fetched by the runtime itself while the trackers started
    onProgress?.(1);
    return this.delegate;
  }

  async create(delegate) {
    this.closeTasks();
    const { FaceLandmarker, GestureRecognizer } = this.mp;
    const copy = (b) => new Uint8Array(b.slice(0));
    this.face = await FaceLandmarker.createFromOptions(this.fileset, {
      baseOptions: { modelAssetBuffer: copy(this.buffers.face), delegate },
      runningMode: 'VIDEO', numFaces: 1, outputFacialTransformationMatrixes: true,
    });
    this.hand = await GestureRecognizer.createFromOptions(this.fileset, {
      baseOptions: { modelAssetBuffer: copy(this.buffers.hand), delegate },
      runningMode: 'VIDEO', numHands: 1,
    });
    this.lastFaceTs = 0; this.lastHandTs = 0;
    this.delegate = delegate;
  }

  closeTasks() {
    try { this.face?.close(); } catch { /* already closed */ }
    try { this.hand?.close(); } catch { /* already closed */ }
    this.face = null; this.hand = null;
  }

  /** Runs `fn`; if the GPU path throws, rebuilds both trackers on the CPU and runs it once more. */
  async guarded(fn) {
    try { return fn(); } catch (e) {
      if (this.delegate !== 'GPU') throw e;
      await this.create('CPU');
      return fn();
    }
  }

  record(kind, ms) {
    const s = this.stats[kind];
    s.n += 1; s.sum += ms; s.last = ms; s.max = Math.max(s.max, ms);
  }

  /** Head reading for a video frame: yaw, pitch, nose offset and the landmarks, or null when no face. */
  detectFace(video, nowMs) {
    if (!this.face) return null;
    this.lastFaceTs = Math.max(this.lastFaceTs + 1, Math.round(nowMs));
    const t0 = performance.now();
    const r = this.face.detectForVideo(video, this.lastFaceTs);
    this.record('face', performance.now() - t0);
    const lm = r.faceLandmarks?.[0], m = r.facialTransformationMatrixes?.[0];
    if (!lm || !m) return null;
    return { landmarks: lm, offset: noseOffset(lm), ...anglesFromMatrix(m.data) };
  }

  /** Hand reading for a video frame, or null when no hand. */
  detectHand(video, nowMs) {
    if (!this.hand) return null;
    this.lastHandTs = Math.max(this.lastHandTs + 1, Math.round(nowMs));
    const t0 = performance.now();
    const r = this.hand.recognizeForVideo(video, this.lastHandTs);
    this.record('hand', performance.now() - t0);
    const lm = r.landmarks?.[0];
    if (!lm) return null;
    const g = r.gestures?.[0]?.[0];
    return { landmarks: lm, gesture: g?.categoryName ?? null, score: g?.score ?? 0 };
  }

  close() {
    this.closeTasks();
    if (this.blobUrl) { URL.revokeObjectURL(this.blobUrl); this.blobUrl = null; }
    this.buffers = null; this.fileset = null;
  }
}

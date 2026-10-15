// End-to-end check in headless Chrome against a local server: node docs/live/test/e2e.mjs [camera|denied|nodevice|mouse|phone|cpu|nowebgl|modelfail|all]
// Needs: python3 -m http.server 8791 run from docs/, and Chrome at the usual macOS path. Fake camera: a test pattern with no face or hand.
import { launch, Page, say, sleep } from './cdp.mjs';

const ORIGIN = 'http://127.0.0.1:8791';
const URL_ = `${ORIGIN}/live/index.html`;
const FAKE = ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'];
const results = [];
const check = (name, ok, detail = '') => { results.push({ name, ok }); say(`${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ' :: ' + detail : ''}`); };

// MediaPipe reports its own INFO lines (the TensorFlow Lite delegate notice) through console.error; those are not errors.
const real = (w) => w.errors.filter((e) => !/INFO:/.test(e));
function offOrigin(w) { return w.requests.filter((r) => !/^(http:\/\/127\.0\.0\.1:8791|blob:|data:|about:)/.test(r.url)).map((r) => r.url); }

async function camera() {
  say('scenario camera: launching Chrome with a fake camera');
  const c = await launch({ port: 9333, flags: FAKE });
  const p = await Page.open(c.port); const w = await p.watch();
  try {
    await p.send('Page.navigate', { url: URL_ });
    await p.waitFor("document.readyState === 'complete'", 15000, 'page load');
    say('page loaded; checking nothing heavy loaded before consent');
    const pre = w.requests.map((r) => r.url.replace(ORIGIN, ''));
    check('no wasm, model or runtime request before the button', !pre.some((u) => /vendor|models|\.wasm|\.task/.test(u)), pre.join(' '));
    check('gate is showing', await p.eval("document.getElementById('app').dataset.state === 'gate' && !document.getElementById('gate').hidden"));
    check('no video element is visible', await p.eval("[...document.querySelectorAll('video')].every(v => v.closest('#sink') && v.getBoundingClientRect().right < 0)"));
    const mark = w.requests.length;
    say('pressing Turn on camera');
    await p.eval("document.getElementById('go-camera').click()");
    const ms = await p.waitFor("document.getElementById('app').dataset.state === 'running' || !document.getElementById('gate').hidden && !document.getElementById('gate-message').hidden", 180000, 'camera running');
    const state = await p.eval("document.getElementById('app').dataset.state");
    say(`state after ${ms} ms: ${state}`);
    check('camera mode reached', state === 'running', await p.eval("document.getElementById('gate-message').textContent"));
    if (state === 'running') {
      say('letting the trackers run for 12 s');
      await sleep(12000);
      const s = await p.eval('window.__live.stats()');
      say('stats ' + JSON.stringify(s));
      const secs = (s.frames.processed ? 12 : 1);
      check('delegate chosen', ['GPU', 'CPU'].includes(s.delegate), s.delegate);
      check('face frames processed', s.face.n > 20, `${s.face.n} frames, median ${s.face.p50.toFixed(1)} ms, p95 ${s.face.p95.toFixed(1)} ms, max ${s.face.max.toFixed(1)} ms`);
      check('hand frames processed', s.hand.n > 50, `${s.hand.n} frames, median ${s.hand.p50.toFixed(1)} ms, p95 ${s.hand.p95.toFixed(1)} ms, max ${s.hand.max.toFixed(1)} ms`);
      say(`video frames seen ${s.frames.seen}, processed ${s.frames.processed}, tracking about ${(s.frames.processed / secs).toFixed(1)} Hz overall; hand ${(s.hand.n / secs).toFixed(1)} Hz, face ${(s.face.n / secs).toFixed(1)} Hz`);
      const fps = await p.eval(`new Promise(r => { let n = 0; const t0 = performance.now(); (function f(){ n++; if (performance.now() - t0 < 2000) requestAnimationFrame(f); else r(n / 2); })(); })`);
      say(`UI frame rate while tracking: ${fps.toFixed(0)} fps (headless Chrome)`);
      check('UI stays smooth while tracking (>= 30 fps)', fps >= 30, fps.toFixed(0));
      check('sees panel readouts are live', (await p.eval("document.getElementById('r-speed').textContent")) !== '-');
      check('coach shows a first suggestion', (await p.eval("document.getElementById('prompt').textContent")).includes('Look at one'));

      say('camera stays on; now bytes downloaded after the button');
      const after = w.requests.slice(mark).filter((r) => r.bytes);
      let total = 0; for (const r of after) total += r.bytes;
      for (const r of after) say(`  ${(r.bytes / 1e6).toFixed(2)} MB  ${r.status} ${r.enc || '-'}  ${r.url.replace(ORIGIN, '')}`);
      say(`downloaded after the button: ${(total / 1e6).toFixed(2)} MB over ${after.length} requests`);

      say('pressing Stop camera');
      await p.eval("document.getElementById('stop').click()");
      await sleep(300);
      check('stop shows the gate', await p.eval("!document.getElementById('gate').hidden"));
      check('camera track stopped after Stop', await p.eval("[...document.querySelectorAll('video')].every(v => !v.srcObject)"));
      await p.eval("document.getElementById('go-camera').click()");
      await p.waitFor("document.getElementById('app').dataset.state === 'running'", 30000, 'restart camera');
      check('camera restarts without downloading again', w.requests.slice(mark).filter((r) => /models|\.gz/.test(r.url)).length <= 3);

      say('hiding the tab');
      const other = await Page.open(c.port, 'about:blank');
      await p.send('Target.activateTarget', { targetId: other.targetId }).catch(() => {});
      await fetch(`http://127.0.0.1:${c.port}/json/activate/${other.targetId}`);
      await sleep(800);
      const hidden = await p.eval('document.hidden');
      say('document.hidden = ' + hidden);
      if (hidden) check('camera released while the tab is hidden', await p.eval("[...document.querySelectorAll('video')].every(v => !v.srcObject)"));
      else say('NOTE could not hide the tab in headless Chrome; the hidden-tab path is not verified here');
      other.close();
    }
    check('no request left localhost', offOrigin(w).length === 0, offOrigin(w).join(' '));
    check('no console errors', real(w).length === 0, real(w).join(' | '));
  } finally { p.close(); await c.close(); }
}

async function denied() {
  say('scenario denied: camera permission refused');
  const c = await launch({ port: 9334, flags: ['--use-fake-device-for-media-stream'] });
  const p = await Page.open(c.port); const w = await p.watch();
  try {
    await p.send('Browser.setPermission', { permission: { name: 'camera' }, setting: 'denied', origin: ORIGIN });
    await p.send('Page.navigate', { url: URL_ });
    await p.waitFor("document.readyState === 'complete'", 15000);
    await p.eval("document.getElementById('go-camera').click()");
    await p.waitFor("!document.getElementById('gate-message').hidden", 30000, 'refusal message');
    const msg = await p.eval("document.getElementById('gate-message').textContent");
    say('message: ' + msg);
    check('refusal explained in plain words', /refused|blocked/i.test(msg), msg);
    check('mouse option offered', await p.eval("!document.getElementById('go-mouse').hidden"));
    const big = w.requests.filter((r) => /\.gz$/.test(r.url));
    say(`downloads started before refusal: ${big.length} (aborted on refusal)`);
    await p.eval("document.getElementById('go-mouse').click()");
    await sleep(300);
    check('mouse mode starts after refusal', (await p.eval('window.__live.mode')) === 'mouse');
    check('no request left localhost', offOrigin(w).length === 0, offOrigin(w).join(' '));
    check('no console errors', real(w).length === 0, real(w).join(' | '));
  } finally { p.close(); await c.close(); }
}

async function nodevice() {
  say('scenario nodevice: no camera at all');
  const c = await launch({ port: 9335, flags: ['--use-fake-ui-for-media-stream'] });
  const p = await Page.open(c.port); const w = await p.watch();
  try {
    await p.send('Page.navigate', { url: URL_ });
    await p.waitFor("document.readyState === 'complete'", 15000);
    await p.eval("document.getElementById('go-camera').click()");
    await p.waitFor("!document.getElementById('gate-message').hidden", 40000, 'message');
    const msg = await p.eval("document.getElementById('gate-message').textContent");
    say('message: ' + msg);
    check('dead or missing camera explained', /No camera|could not start|no picture/i.test(msg), msg);
    check('mouse option still offered', await p.eval("!document.getElementById('go-mouse').hidden"));
    check('no console errors', real(w).length === 0, real(w).join(' | '));
  } finally { p.close(); await c.close(); }
}

async function mouse() {
  say('scenario mouse: every gesture with the mouse, in a free order');
  const c = await launch({ port: 9336, flags: [], size: '1400,860' });
  const p = await Page.open(c.port); const w = await p.watch();
  try {
    await p.send('Page.navigate', { url: URL_ });
    await p.waitFor("document.readyState === 'complete'", 15000);
    await p.eval("document.getElementById('go-mouse').click()");
    await sleep(300);
    check('mouse mode on', (await p.eval('window.__live.mode')) === 'mouse');
    check('four panes, a rail, traffic lights', await p.eval("document.querySelectorAll('.ls-pane').length === 4 && document.querySelectorAll('.ls-rail-item').length === 4 && document.querySelectorAll('.ls-lights i').length === 3"));
    const centre = (id) => p.eval(`(() => { const r = document.querySelector('[data-id=${id}]').getBoundingClientRect(); return {x: r.left + r.width / 2, y: r.top + r.height / 2}; })()`);
    const api = await centre('api'), land = await centre('landing');
    await p.mouse('mouseMoved', api.x, api.y);
    await sleep(1000);
    check('hover focuses a pane', (await p.eval('window.__live.focus()')) === 'api');
    check('blue outline on the focused pane', await p.eval("document.querySelector('[data-id=api]').classList.contains('focused')"));
    check('looked is ticked', (await p.eval('window.__live.done()')).looked);
    const click = async (pt) => { await p.mouse('mousePressed', pt.x, pt.y); await sleep(110); await p.mouse('mouseReleased', pt.x, pt.y); };
    await click(api); await sleep(250); await click(api);
    await sleep(500);
    check('click-click starts dictation', await p.eval('window.__live.talking()'));
    check('island says dictation on in the session', (await p.eval("document.querySelector('#island .l1').textContent + ' ' + document.querySelector('#island .l2').textContent")) === 'Claude dictation on in api-refactor');
    await sleep(2200);
    const draft = await p.eval("window.__live.draft('api')");
    say('draft: ' + draft);
    check('dictation types that session\'s own sentence word by word', draft.startsWith('Add retry') && draft.split(' ').length >= 4, draft);
    say('looking at another pane while dictating');
    await p.mouse('mouseMoved', land.x, land.y);
    await sleep(700);
    check('island shows Activating with the edge filling', (await p.eval("document.getElementById('island').dataset.mode")) === 'switching' && Number(await p.eval("document.getElementById('island').style.getPropertyValue('--fill')")) > 0.1);
    check('island names the other session', (await p.eval("document.querySelector('#island .l1').textContent")) === 'Activating landing-page');
    await sleep(1900);
    check('dictation stopped after 2 s', !(await p.eval('window.__live.talking()')));
    const kept = await p.eval("window.__live.draft('api')");
    check('draft kept, unsent', kept.length > 0 && (await p.eval("[...document.querySelectorAll('[data-id=api] .ls-line.you')].every(e => e.textContent !== window.__live.draft('api'))")), kept);
    check('focus moved to the other session', (await p.eval('window.__live.focus()')) === 'landing');
    await p.mouse('mouseMoved', api.x, api.y);
    await sleep(900);
    const lines0 = await p.eval("document.querySelectorAll('[data-id=api] .ls-line').length");
    await p.mouse('mousePressed', api.x, api.y);
    await sleep(500);
    await sleep(900);
    await p.mouse('mouseReleased', api.x, api.y);
    await sleep(300);
    check('hold sends: draft cleared and in the transcript', (await p.eval("window.__live.draft('api')")) === '' && (await p.eval("[...document.querySelectorAll('[data-id=api] .ls-line.you')].pop().textContent")).startsWith('Add retry'));
    await sleep(4500);
    const lines1 = await p.eval("document.querySelectorAll('[data-id=api] .ls-line').length");
    check('a Claude reply streams in', lines1 >= lines0 + 3, `${lines0} -> ${lines1}`);
    check('sent is ticked', (await p.eval('window.__live.done()')).sent);
    const before = await p.eval("document.querySelector('[data-id=api] .ls-transcript').scrollTop");
    await p.mouse('mousePressed', api.x, api.y - 60);
    for (let i = 0; i < 25; i++) { await p.mouse('mouseMoved', api.x, api.y - 60 + i * 6, { buttons: 1 }); await sleep(16); }
    await p.mouse('mouseReleased', api.x, api.y + 90);
    await sleep(300);
    const after = await p.eval("document.querySelector('[data-id=api] .ls-transcript').scrollTop");
    say(`scrollTop ${before} -> ${after}`);
    check('press and drag scrolls that pane', after !== before);
    check('all four ticked, offer shown', (await p.eval('Object.values(window.__live.done()).every(Boolean)')) && await p.eval("!document.getElementById('done').hidden"));
    check('finish screen not forced', await p.eval("document.getElementById('finish').hidden"));
    await p.eval("document.getElementById('done').click()");
    await sleep(200);
    check('ends on the download screen', await p.eval("!document.getElementById('finish').hidden"));
    check('download links point at the release', await p.eval("document.getElementById('download').href === 'https://github.com/oficiallyAkshay/ensemble/releases/latest' && document.querySelector('.ls-download-corner').href === 'https://github.com/oficiallyAkshay/ensemble/releases/latest'"));
    check('back to the letter link', await p.eval("[...document.querySelectorAll('#finish a')].some(a => a.getAttribute('href') === '../index.html')"));
    check('no request left localhost', offOrigin(w).length === 0, offOrigin(w).join(' '));
    check('mouse mode downloaded no models', !w.requests.some((r) => /models|vendor/.test(r.url)));
    check('no console errors', real(w).length === 0, real(w).join(' | '));
  } finally { p.close(); await c.close(); }
}

async function cpu() {
  say('scenario cpu: the GPU path skipped, the CPU delegate must take over');
  const c = await launch({ port: 9338, flags: FAKE });
  const p = await Page.open(c.port); const w = await p.watch();
  try {
    await p.send('Page.navigate', { url: URL_ + '?delegate=cpu' });
    await p.waitFor("document.readyState === 'complete'", 15000);
    await p.eval("document.getElementById('go-camera').click()");
    await p.waitFor("document.getElementById('app').dataset.state === 'running' || !document.getElementById('gate-message').hidden", 120000, 'running');
    const state = await p.eval("document.getElementById('app').dataset.state");
    check('camera mode reached on the CPU delegate', state === 'running', await p.eval("document.getElementById('gate-message').textContent"));
    if (state === 'running') {
      await sleep(8000);
      const s = await p.eval('window.__live.stats()');
      say('stats ' + JSON.stringify(s));
      check('CPU delegate in use', s.delegate === 'CPU', s.delegate);
      check('frames processed on CPU', s.hand.n > 30 && s.face.n > 15, `hand ${s.hand.n} median ${s.hand.p50.toFixed(1)} ms; face ${s.face.n} median ${s.face.p50.toFixed(1)} ms`);
      const fps = await p.eval(`new Promise(r => { let n = 0; const t0 = performance.now(); (function f(){ n++; if (performance.now() - t0 < 2000) requestAnimationFrame(f); else r(n / 2); })(); })`);
      check('UI stays smooth on CPU (>= 30 fps)', fps >= 30, fps.toFixed(0));
    }
    check('no console errors', real(w).length === 0, real(w).join(' | '));
  } finally { p.close(); await c.close(); }
}

async function nowebgl() {
  say('scenario nowebgl: WebGL disabled, a clear message and the mouse instead');
  const c = await launch({ port: 9341, flags: [...FAKE, '--disable-gpu', '--disable-webgl', '--disable-3d-apis'] });
  const p = await Page.open(c.port); const w = await p.watch();
  try {
    await p.send('Page.navigate', { url: URL_ });
    await p.waitFor("document.readyState === 'complete'", 15000);
    await p.eval("document.getElementById('go-camera').click()");
    await p.waitFor("!document.getElementById('gate-message').hidden", 30000, 'message');
    const msg = await p.eval("document.getElementById('gate-message').textContent");
    say('message: ' + msg);
    check('no-WebGL message', /WebGL/.test(msg), msg);
    check('nothing downloaded for an unsupported browser', !w.requests.some((r) => /models|\.gz/.test(r.url)));
    await p.eval("document.getElementById('go-mouse').click()");
    await sleep(300);
    check('mouse mode available', (await p.eval('window.__live.mode')) === 'mouse');
    check('no console errors', real(w).length === 0, real(w).join(' | '));
  } finally { p.close(); await c.close(); }
}

async function modelfail() {
  say('scenario modelfail: the model download fails');
  const c = await launch({ port: 9339, flags: FAKE });
  const p = await Page.open(c.port); const w = await p.watch();
  try {
    await p.send('Fetch.enable', { patterns: [{ urlPattern: '*face_landmarker*' }] });
    p.on('Fetch.requestPaused', (e) => p.send('Fetch.failRequest', { requestId: e.requestId, errorReason: 'Failed' }));
    await p.send('Page.navigate', { url: URL_ });
    await p.waitFor("document.readyState === 'complete'", 15000);
    await p.eval("document.getElementById('go-camera').click()");
    await p.waitFor("!document.getElementById('gate-message').hidden", 60000, 'message');
    const msg = await p.eval("document.getElementById('gate-message').textContent");
    say('message: ' + msg);
    check('model failure explained, mouse offered', /trackers could not load/.test(msg) && await p.eval("!document.getElementById('go-mouse').hidden"), msg);
    check('camera released after the failure', await p.eval("[...document.querySelectorAll('video')].every(v => !v.srcObject)"));
  } finally { p.close(); await c.close(); }
}

async function phone() {
  say('scenario phone: touch emulation');
  const c = await launch({ port: 9337, flags: [], size: '390,844' });
  const p = await Page.open(c.port); const w = await p.watch();
  try {
    await p.send('Emulation.setUserAgentOverride', { userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1' });
    await p.send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 3, mobile: true });
    await p.send('Emulation.setTouchEmulationEnabled', { enabled: true });
    await p.send('Page.navigate', { url: URL_ });
    await p.waitFor("document.readyState === 'complete'", 15000);
    check('phone: no camera button', await p.eval("document.getElementById('go-camera').hidden"));
    check('phone: touch option', (await p.eval("document.getElementById('go-mouse').textContent")).includes('touch'));
    check('phone: no horizontal overflow', await p.eval('document.documentElement.scrollWidth <= innerWidth + 1'));
    await p.eval("document.getElementById('go-mouse').click()");
    await sleep(300);
    check('phone: touch mode on', (await p.eval('window.__live.mode')) === 'mouse');
    check('phone: nothing heavy loaded', !w.requests.some((r) => /models|vendor/.test(r.url)));
    check('no console errors', real(w).length === 0, real(w).join(' | '));
  } finally { p.close(); await c.close(); }
}

const which = process.argv[2] || 'all';
const all = { camera, denied, nodevice, mouse, phone, cpu, nowebgl, modelfail };
for (const [name, fn] of Object.entries(all)) {
  if (which !== 'all' && which !== name) continue;
  try { await fn(); } catch (e) { check(`${name} scenario ran`, false, e.stack || e.message); }
}
const failed = results.filter((r) => !r.ok);
say(`${results.length - failed.length} passed, ${failed.length} failed`);
process.exit(failed.length ? 1 : 0);

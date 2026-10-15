// End-to-end check in headless Chrome against a local server: node docs/live/test/e2e.mjs [camera|denied|nodevice|mouse|phone|all]
// Needs: python3 -m http.server 8791 run from docs/, and Chrome at the usual macOS path. Fake camera: a test pattern with no face or hand.
import { launch, Page, say, sleep } from './cdp.mjs';

const ORIGIN = 'http://127.0.0.1:8791';
const URL_ = `${ORIGIN}/live/index.html`;
const FAKE = ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'];
const results = [];
const check = (name, ok, detail = '') => { results.push({ name, ok }); say(`${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ' :: ' + detail : ''}`); };

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
      check('face frames processed', s.face.n > 20, `${s.face.n} frames, avg ${(s.face.sum / s.face.n).toFixed(1)} ms, max ${s.face.max.toFixed(1)} ms`);
      check('hand frames processed', s.hand.n > 50, `${s.hand.n} frames, avg ${(s.hand.sum / s.hand.n).toFixed(1)} ms, max ${s.hand.max.toFixed(1)} ms`);
      say(`video frames seen ${s.frames.seen}, processed ${s.frames.processed}, tracking about ${(s.frames.processed / secs).toFixed(1)} Hz overall; hand ${(s.hand.n / secs).toFixed(1)} Hz, face ${(s.face.n / secs).toFixed(1)} Hz`);
      const fps = await p.eval(`new Promise(r => { let n = 0; const t0 = performance.now(); (function f(){ n++; if (performance.now() - t0 < 2000) requestAnimationFrame(f); else r(n / 2); })(); })`);
      say(`UI frame rate while tracking: ${fps.toFixed(0)} fps (headless Chrome)`);
      check('UI stays smooth while tracking (>= 30 fps)', fps >= 30, fps.toFixed(0));
      check('sees panel readouts are live', (await p.eval("document.getElementById('r-speed').textContent")) !== '-');
      check('coach shows first prompt', (await p.eval("document.getElementById('prompt').textContent")).includes('Look at one'));

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
    check('no console errors', w.errors.length === 0, w.errors.join(' | '));
  } finally { p.close(); await c.close(); }
}

async function denied() {
  say('scenario denied: camera permission refused');
  const c = await launch({ port: 9334, flags: FAKE });
  const p = await Page.open(c.port); const w = await p.watch();
  try {
    await p.send('Browser.setPermission', { permission: { name: 'videoCapture' }, setting: 'denied', origin: ORIGIN });
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
    check('no console errors', w.errors.length === 0, w.errors.join(' | '));
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
    await p.waitFor("!document.getElementById('gate-message').hidden", 30000, 'message');
    const msg = await p.eval("document.getElementById('gate-message').textContent");
    say('message: ' + msg);
    check('no-camera message', /No camera|could not start/i.test(msg), msg);
    check('mouse option still offered', await p.eval("!document.getElementById('go-mouse').hidden"));
    check('no console errors', w.errors.length === 0, w.errors.join(' | '));
  } finally { p.close(); await c.close(); }
}

async function mouse() {
  say('scenario mouse: whole tutorial with the mouse');
  const c = await launch({ port: 9336, flags: [] });
  const p = await Page.open(c.port); const w = await p.watch();
  try {
    await p.send('Page.navigate', { url: URL_ });
    await p.waitFor("document.readyState === 'complete'", 15000);
    await p.eval("document.getElementById('go-mouse').click()");
    await sleep(300);
    check('mouse mode on', (await p.eval('window.__live.mode')) === 'mouse');
    const rect = await p.eval("(() => { const r = document.querySelector('[data-id=api]').getBoundingClientRect(); return {x: r.left + r.width / 2, y: r.top + r.height / 2}; })()");
    await p.mouse('mouseMoved', rect.x, rect.y);
    await sleep(500);
    check('hover focuses a pane', (await p.eval('window.__live.focus()')) === 'api');
    await sleep(1200);
    check('step 2 reached (look)', (await p.eval('window.__live.step')) === 1, String(await p.eval('window.__live.step')));
    const click = async () => { await p.mouse('mousePressed', rect.x, rect.y); await sleep(110); await p.mouse('mouseReleased', rect.x, rect.y); };
    await click(); await sleep(250); await click();
    await sleep(500);
    check('click-click starts dictation', await p.eval('window.__live.talking()'));
    check('island says dictation on', (await p.eval("document.querySelector('#island .l1').textContent")) === 'Claude dictation on');
    await sleep(2600);
    const draft = await p.eval("window.__live.draft('api')");
    say('draft: ' + draft);
    check('dictation types words', draft.split(' ').length >= 4, draft);
    check('step 4 reached', (await p.eval('window.__live.step')) === 3, String(await p.eval('window.__live.step')));
    await p.mouse('mousePressed', rect.x, rect.y);
    await sleep(500);
    const mode = await p.eval("document.getElementById('island').dataset.mode");
    say('island while holding: ' + mode);
    await sleep(1200);
    await p.mouse('mouseReleased', rect.x, rect.y);
    await sleep(300);
    check('hold sends: draft empty and moved into the transcript', (await p.eval("window.__live.draft('api')")) === '' && (await p.eval("document.querySelector('[data-id=api] .ls-transcript').lastElementChild.textContent")).length > 0);
    check('step 5 reached', (await p.eval('window.__live.step')) === 4, String(await p.eval('window.__live.step')));
    const before = await p.eval("document.querySelector('[data-id=api] .ls-transcript').scrollTop");
    await p.mouse('mousePressed', rect.x, rect.y - 60);
    for (let i = 0; i < 25; i++) { await p.mouse('mouseMoved', rect.x, rect.y - 60 + i * 6, { buttons: 1 }); await sleep(16); }
    await p.mouse('mouseReleased', rect.x, rect.y + 90);
    await sleep(300);
    const after = await p.eval("document.querySelector('[data-id=api] .ls-transcript').scrollTop");
    say(`scrollTop ${before} -> ${after}`);
    check('press and drag scrolls the pane', after !== before);
    await sleep(300);
    const fin = await p.eval("!document.getElementById('finish').hidden");
    check('ends on the download screen', fin);
    check('download links point at the release', await p.eval("document.getElementById('download').href === 'https://github.com/oficiallyAkshay/ensemble/releases/latest' && document.querySelector('.ls-download-corner').href === 'https://github.com/oficiallyAkshay/ensemble/releases/latest'"));
    check('back to the letter link', await p.eval("[...document.querySelectorAll('#finish a')].some(a => a.getAttribute('href') === '../index.html')"));
    check('no request left localhost', offOrigin(w).length === 0, offOrigin(w).join(' '));
    check('mouse mode downloaded no models', !w.requests.some((r) => /models|vendor/.test(r.url)));
    check('no console errors', w.errors.length === 0, w.errors.join(' | '));
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
    check('no console errors', w.errors.length === 0, w.errors.join(' | '));
  } finally { p.close(); await c.close(); }
}

const which = process.argv[2] || 'all';
const all = { camera, denied, nodevice, mouse, phone };
for (const [name, fn] of Object.entries(all)) {
  if (which !== 'all' && which !== name) continue;
  try { await fn(); } catch (e) { check(`${name} scenario ran`, false, e.stack || e.message); }
}
const failed = results.filter((r) => !r.ok);
say(`${results.length - failed.length} passed, ${failed.length} failed`);
process.exit(failed.length ? 1 : 0);

/* Glue between the tour window and scene3d.js. Everything here talks to the app through one script message
 * handler named "tour"; nothing leaves the process. Messages out: {ready}, {failed: reason}, {frame: {...}}.
 * The page takes ?scene=<name>&rm=1 (reduce motion) &frames=1 (report scene state for the session mock). */
(function () {
  'use strict';
  var q = new URLSearchParams(window.location.search);
  var wantsFrames = q.get('frames') === '1';
  var reduced = q.get('rm') === '1';
  var HAND_SCENES = { dictate: 1, send: 1, scroll: 1 };
  var instance = null, current = q.get('scene') || 'welcome', watch = null, lastPost = 0;

  function post(message) {
    try { window.webkit.messageHandlers.tour.postMessage(message); } catch (e) { /* opened outside the app */ }
  }

  function onFrame(state) {
    if (!wantsFrames) return;
    var now = performance.now();
    // 30 Hz is plenty for a text mock; the single frame of a reduced-motion still always goes through.
    if (!reduced && now - lastPost < 33) return;
    lastPost = now;
    post({ frame: {
      scene: state.scene, listening: !!state.listening, draft: state.draft || 0,
      hold: state.hold || 0, sent: !!state.sent, scroll: state.scroll || 0
    } });
  }

  // scene3d.js keeps drawing an empty stage if the hand model cannot load; report it so the app shows its still.
  function watchHand() {
    if (watch) { clearInterval(watch); watch = null; }
    if (!instance || !HAND_SCENES[current]) return;
    var waited = 0;
    watch = setInterval(function () {
      waited += 250;
      if (instance._hand && instance._hand()) { clearInterval(watch); watch = null; return; }
      if ((instance._ready && instance._ready()) || waited > 6000) {
        clearInterval(watch); watch = null; post({ failed: 'hand' });
      }
    }, 250);
  }

  function start() {
    if (!window.THREE || !window.EnsembleScene || !THREE.GLTFLoader) { post({ failed: 'scripts' }); return; }
    var stage = document.getElementById('stage');
    try {
      instance = window.EnsembleScene.mount(stage, { scene: current, reducedMotion: reduced, onFrame: onFrame, handUrl: 'hand.glb' });
    } catch (e) { post({ failed: 'mount' }); return; }
    var canvas = stage.querySelector('canvas');
    if (!canvas) { post({ failed: 'webgl' }); return; }
    canvas.addEventListener('webglcontextlost', function (e) { e.preventDefault(); post({ failed: 'webgl' }); });
    post({ ready: true });
    watchHand();
  }

  window.EnsembleTour = {
    setScene: function (name) {
      if (!instance) return;
      current = name;
      instance.setScene(name);
      watchHand();
    },
    destroy: function () {
      if (watch) clearInterval(watch);
      if (instance) instance.destroy();
      instance = null;
    }
  };

  start();
})();

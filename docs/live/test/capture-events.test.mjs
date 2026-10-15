// node --test docs/live/test : the replay timeline's event finder, on built frames.
import test from 'node:test';
import assert from 'node:assert/strict';
import { detectEvents, judge } from '../capture3d/events.js';

// A hand with palm length 0.1 m; gap is the thumb-to-index distance in metres.
function frame(t, gap, gesture = 'None') {
  const world = Array.from({ length: 21 }, () => [0, 0, 0]);
  world[9] = [0, 0.1, 0]; world[8] = [gap, 0, 0];
  const image = world.map((p) => [0.5 + p[0], 0.5 - p[1], 0]);
  return { t, hand: 'Right', world, image, gesture, score: 0.9 };
}
const take = (fn, ms = 6000) => Array.from({ length: ms / 33 }, (_, i) => fn(i * 33));

test('four short pinches with a pause read as a double pinch twice', () => {
  const on = (t) => [[500, 650], [800, 950], [2200, 2350], [2500, 2650]].some(([a, b]) => t >= a && t <= b);
  const ev = detectEvents(take((t) => frame(t, on(t) ? 0.005 : 0.08)));
  assert.equal(ev.pinches.length, 4);
  assert.ok(judge('dictate', ev).every((c) => c.ok));
});

test('a thumbs-up shorter than expected is flagged', () => {
  const ev = detectEvents(take((t) => frame(t, 0.08, t > 1000 && t < 1600 ? 'Thumb_Up' : 'None'), 4000));
  assert.equal(ev.holds.length, 1);
  assert.equal(judge('send', ev)[0].ok, false);
});

test('a still hand has no events', () => {
  const ev = detectEvents(take(() => frame(0, 0.08), 3000));
  assert.deepEqual([ev.pinches.length, ev.holds.length, ev.scroll], [0, 0, null]);
});

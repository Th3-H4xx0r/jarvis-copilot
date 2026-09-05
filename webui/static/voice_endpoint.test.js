'use strict';
// node --test webui/static/voice_endpoint.test.js
//
// Pure-logic tests for the adaptive endpointer (plan 1.1). No DOM/browser
// APIs involved - voice_endpoint.js must stay dependency-free so it can be
// exercised here with plain `node --test` (no npm install required).
const test = require('node:test');
const assert = require('node:assert/strict');
const { createEndpointer, DEFAULTS } = require('./voice_endpoint.js');

// Feed a run of frames of a fixed amplitude for a duration, at a fixed frame
// interval, returning the last feed() result (or the first one that fired).
function feedRun(ep, amp, durationMs, frameMs) {
  frameMs = frameMs || 20;
  let elapsed = 0;
  let last = { fired: false, reason: null };
  while (elapsed < durationMs) {
    last = ep.feed(amp, frameMs);
    elapsed += frameMs;
    if (last.fired) return last;
  }
  return last;
}

test('short blip (< minUtteranceMs of speech) is ignored, never fires', () => {
  const ep = createEndpointer();
  // 100ms of speech - under MIN_UTTERANCE_MS (250ms) - then a long silence.
  feedRun(ep, 0.5, 100, 20);
  const r = feedRun(ep, 0.0, 2000, 20);
  assert.equal(r.fired, false, 'a blip shorter than minUtteranceMs must not fire end_turn');
});

test('pause mid-sentence (short utterance) extends the silence window', () => {
  const ep = createEndpointer();
  // 300ms of speech - real (>= minUtteranceMs) but short (< shortUtteranceMs=1200),
  // so the following pause should be treated as "still talking" and need the
  // extended window, not the base one.
  feedRun(ep, 0.5, 300, 20);

  // Just under the extended window: must not have fired yet.
  let fired = false;
  let elapsed = 0;
  while (elapsed < DEFAULTS.extendedSilenceMs - 40) {
    const r = ep.feed(0.0, 20);
    elapsed += 20;
    if (r.fired) fired = true;
  }
  assert.equal(fired, false, 'must not fire before the extended window elapses');

  // Push past the extended window - now it should fire.
  let r2 = { fired: false };
  for (let i = 0; i < 5 && !r2.fired; i++) r2 = ep.feed(0.0, 20);
  assert.equal(r2.fired, true, 'must fire once the extended silence window elapses');
  assert.equal(r2.reason, 'silence');
});

test('clean stop (longer, flat utterance) fires at ~ the base silence window', () => {
  const ep = createEndpointer();
  // 1600ms of steady (non-rising) speech - well over shortUtteranceMs (1200),
  // so the base window applies once the user stops.
  feedRun(ep, 0.5, 1600, 20);

  let elapsed = 0;
  let fired = false;
  while (elapsed < DEFAULTS.baseSilenceMs - 40) {
    const r = ep.feed(0.0, 20);
    elapsed += 20;
    if (r.fired) fired = true;
  }
  assert.equal(fired, false, 'must not fire before the base window elapses');

  let r2 = { fired: false };
  let extra = 0;
  while (!r2.fired && extra < 200) { r2 = ep.feed(0.0, 20); extra += 20; }
  assert.equal(r2.fired, true, 'must fire once the base silence window elapses');
  assert.equal(r2.reason, 'silence');
  // Should fire close to the base window, not the extended one.
  assert.ok(elapsed + extra < DEFAULTS.extendedSilenceMs, 'fired well before the extended window would have');
});

test('rising energy right before the pause extends the window even for a long utterance', () => {
  const ep = createEndpointer();
  // 1000ms of speech that gets louder toward the end (rising energy) -
  // should extend even though the utterance is long.
  feedRun(ep, 0.3, 200, 20);
  feedRun(ep, 0.5, 400, 20);
  feedRun(ep, 0.9, 400, 20);

  let elapsed = 0;
  let fired = false;
  while (elapsed < DEFAULTS.baseSilenceMs + 40) {
    const r = ep.feed(0.0, 20);
    elapsed += 20;
    if (r.fired) fired = true;
  }
  assert.equal(fired, false, 'rising energy must extend past the base window');
});

test('30s cap forces end_turn even with continuous speech and no silence', () => {
  const ep = createEndpointer();
  const r = feedRun(ep, 0.5, DEFAULTS.maxUtteranceMs + 500, 50);
  assert.equal(r.fired, true, 'must force end_turn once maxUtteranceMs is exceeded');
  assert.equal(r.reason, 'max_utterance');
});

test('never-spoken silence does not fire (phase 1: waiting for real speech)', () => {
  const ep = createEndpointer();
  const r = feedRun(ep, 0.0, 5000, 20);
  assert.equal(r.fired, false);
});

test('reset() clears state for the next utterance', () => {
  const ep = createEndpointer();
  feedRun(ep, 0.5, 1000, 20);
  ep.reset();
  assert.equal(ep.hasSpoken, false);
  // Silence right after reset should not fire immediately.
  const r = feedRun(ep, 0.0, 300, 20);
  assert.equal(r.fired, false);
});

test('an explicit override config is honored (debug hook use case)', () => {
  const ep = createEndpointer({ baseSilenceMs: 100, extendedSilenceMs: 100, shortUtteranceMs: 0 });
  feedRun(ep, 0.5, 1000, 20);
  const r = feedRun(ep, 0.0, 200, 20);
  assert.equal(r.fired, true);
});

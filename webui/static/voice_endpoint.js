// webui/static/voice_endpoint.js
//
// Pure adaptive endpointer for realtime voice (plan 1.1). Replaces the old
// fixed END_TURN_SILENCE_MS = 1500 in voice.js with an energy-VAD state
// machine that ends a turn after a short, context-sensitive silence window
// instead of always waiting 1.5s. No DOM/timer/browser APIs are used here so
// this module can be driven with plain `node --test` and reused as-is from
// voice.js (loaded as a plain <script>, see _loadEndpointModule() there).
//
// Usage:
//   const ep = createEndpointer();       // or createEndpointer({...overrides})
//   const { fired, reason } = ep.feed(amplitude0to1, dtMs);
//   if (fired) { /* send end_turn; reason is 'silence' or 'max_utterance' */ }
//
// The caller supplies one (amplitude, dt) sample per mic frame; feed() is a
// pure state transition - identical inputs always produce identical outputs,
// which is what makes this unit-testable without a browser.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) {
    module.exports = factory();
  } else {
    root.JCVoiceEndpoint = factory();
  }
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  // ---- Constants (plan 1.1) — tune here, nowhere else. ----
  // Hysteresis pair: separate on/off thresholds stop the state machine from
  // chattering when amplitude hovers right at one fixed threshold.
  const SPEECH_ON_THRESHOLD = 0.08;    // plan 1.1: amp >= this = speech begins
  const SPEECH_OFF_THRESHOLD = 0.04;   // plan 1.1: amp < this = counts as silence
  const BASE_SILENCE_MS = 400;         // plan 1.1: default end-of-turn silence window (was a fixed 1500ms wait)
  const EXTENDED_SILENCE_MS = 700;     // plan 1.1: window used when the pause looks mid-sentence, not a real stop
  const RISING_WINDOW_MS = 800;        // plan 1.1: trailing energy window used to detect a rising (vs falling) utterance
  const SHORT_UTTERANCE_MS = 600;      // plan 1.1: utterances shorter than this when the pause starts are assumed mid-sentence (still talking)
  const MIN_UTTERANCE_MS = 250;        // plan 1.1: below this the "utterance" is actually a blip/cough - drop it, don't end_turn
  const MAX_UTTERANCE_MS = 30000;      // plan 1.1: hard cap - force end_turn even if the user never stops talking

  const DEFAULTS = {
    speechOnThreshold: SPEECH_ON_THRESHOLD,
    speechOffThreshold: SPEECH_OFF_THRESHOLD,
    baseSilenceMs: BASE_SILENCE_MS,
    extendedSilenceMs: EXTENDED_SILENCE_MS,
    risingWindowMs: RISING_WINDOW_MS,
    shortUtteranceMs: SHORT_UTTERANCE_MS,
    minUtteranceMs: MIN_UTTERANCE_MS,
    maxUtteranceMs: MAX_UTTERANCE_MS,
  };

  function createEndpointer(opts) {
    const cfg = Object.assign({}, DEFAULTS, opts || null);

    let hasSpoken = false;   // PHASE 1 gate - ignore everything until real speech is seen
    let elapsedMs = 0;       // total ms fed since the last reset()
    let speechStartMs = 0;   // elapsedMs value when speech was first detected this utterance
    let silenceMs = 0;       // consecutive silence accumulated since the last speech frame
    let silenceLimitMs = cfg.baseSilenceMs; // decided once, when silence starts
    let history = [];        // trailing {t, amp} samples while in speech, pruned to risingWindowMs

    function reset() {
      hasSpoken = false;
      elapsedMs = 0;
      speechStartMs = 0;
      silenceMs = 0;
      silenceLimitMs = cfg.baseSilenceMs;
      history = [];
    }

    function pruneHistory() {
      const cutoff = elapsedMs - cfg.risingWindowMs;
      while (history.length && history[0].t < cutoff) history.shift();
    }

    // "Rising" = the back half of the trailing window is louder than the
    // front half, i.e. energy is building rather than trailing off - a sign
    // the speaker is mid-thought (emphasis coming), not finishing up.
    function isRising() {
      if (history.length < 4) return false;
      const first = history[0].t;
      const mid = first + (elapsedMs - first) / 2;
      let aSum = 0, aN = 0, bSum = 0, bN = 0;
      for (let i = 0; i < history.length; i++) {
        const s = history[i];
        if (s.t < mid) { aSum += s.amp; aN++; } else { bSum += s.amp; bN++; }
      }
      if (!aN || !bN) return false;
      const aAvg = aSum / aN, bAvg = bSum / bN;
      return bAvg > aAvg * 1.1;
    }

    function feed(amp, dtMs) {
      const dt = Math.max(0, Number(dtMs) || 0);
      elapsedMs += dt;

      if (!hasSpoken) {
        // PHASE 1: wait for actual speech so a quiet room never fires end_turn.
        if (amp >= cfg.speechOnThreshold) {
          hasSpoken = true;
          speechStartMs = elapsedMs;
          silenceMs = 0;
          history = [{ t: elapsedMs, amp: amp }];
        }
        return { fired: false, reason: null };
      }

      // Hard cap: never let one utterance hold the turn open forever.
      if (elapsedMs - speechStartMs >= cfg.maxUtteranceMs) {
        reset();
        return { fired: true, reason: 'max_utterance' };
      }

      if (amp >= cfg.speechOffThreshold) {
        // Still speaking - clear the silence clock, keep the energy trail.
        silenceMs = 0;
        history.push({ t: elapsedMs, amp: amp });
        pruneHistory();
        return { fired: false, reason: null };
      }

      // PHASE 2: this frame counts toward silence.
      if (silenceMs === 0) {
        // Silence just started - pick the window length from how the speech
        // that just ended looked (short and/or building energy = probably
        // still mid-sentence, so wait longer).
        const utteranceMsSoFar = elapsedMs - speechStartMs;
        const extend = utteranceMsSoFar < cfg.shortUtteranceMs || isRising();
        silenceLimitMs = extend ? cfg.extendedSilenceMs : cfg.baseSilenceMs;
      }
      silenceMs += dt;

      if (silenceMs < silenceLimitMs) return { fired: false, reason: null };

      const spokenMs = elapsedMs - speechStartMs - silenceMs;
      if (spokenMs < cfg.minUtteranceMs) {
        // Too short to be a real utterance (a blip/cough) - drop it and go
        // back to waiting for real speech rather than ending the turn.
        reset();
        return { fired: false, reason: null };
      }

      reset();
      return { fired: true, reason: 'silence' };
    }

    return {
      feed: feed,
      reset: reset,
      get hasSpoken() { return hasSpoken; },
    };
  }

  return { createEndpointer: createEndpointer, DEFAULTS: DEFAULTS };
});

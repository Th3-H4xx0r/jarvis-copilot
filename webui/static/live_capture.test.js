'use strict';
// node --test webui/static/live_capture.test.js
//
// The parts of browser Live capture a screenshot cannot check: the bytes of an
// audio frame (the server decodes them with struct ">IQ"), the 16 kHz PCM the
// speech engine is told it gets, and what the page says when nobody transcribes.
const test = require('node:test');
const assert = require('node:assert/strict');
const {
  encodeAudioFrame, Resampler, Chunker, helloFrame, readyNote, rms,
} = require('./live_capture.js');

test('an audio frame is seq, then epoch ms, big-endian, then little-endian PCM', () => {
  const buf = encodeAudioFrame(7, 1700000000123, Int16Array.from([1, -2, 32767]));
  const view = new DataView(buf);
  assert.equal(buf.byteLength, 12 + 6);
  assert.equal(view.getUint32(0), 7);
  assert.equal(view.getBigUint64(4), 1700000000123n);
  assert.deepEqual([view.getInt16(12, true), view.getInt16(14, true), view.getInt16(16, true)],
                   [1, -2, 32767]);
});

test('48 kHz becomes 16 kHz, one third the samples, across chunk borders', () => {
  const r = new Resampler(48000, 16000);
  const half = new Float32Array(4800).fill(0.5);
  const out = [...r.push(half.subarray(0, 1000)), ...r.push(half.subarray(1000))];
  assert.ok(Math.abs(out.length - 1600) <= 1, `got ${out.length}`);
  for (const s of out) assert.ok(Math.abs(s - 16384) <= 1, `sample ${s}`);
});

test('16 kHz passes through and loud input clips instead of wrapping', () => {
  const r = new Resampler(16000, 16000);
  const out = r.push(Float32Array.from([2, -2, 0]));
  assert.deepEqual(Array.from(out), [32767, -32768, 0]);
});

test('audio goes out in 100 ms chunks and the rest waits for more', () => {
  const c = new Chunker(1600);
  assert.equal(c.push(new Int16Array(1000)).length, 0);
  const full = c.push(new Int16Array(1000));
  assert.equal(full.length, 1);
  assert.equal(full[0].length, 1600);
  assert.equal(c.push(new Int16Array(1200)).length, 1);
});

test('hello says a browser sends 16 kHz PCM and cannot transcribe', () => {
  const hello = helloFrame({ deviceId: 'web-abc', sourceLabel: 'MacBook Pro Microphone',
                             resumeSid: 'ls1', afterSeq: 4 });
  assert.equal(hello.t, 'hello');
  assert.equal(hello.device_kind, 'web');
  assert.deepEqual(
    { codec: hello.caps.codec, rate: hello.caps.rate, stt: hello.caps.stt, speak: hello.caps.speak },
    { codec: 'pcm16', rate: 16000, stt: 'none', speak: false });
  assert.deepEqual(hello.resume, { live_session_id: 'ls1', after_seq: 4 });
  assert.equal(hello.source_label, 'MacBook Pro Microphone');
  assert.equal(helloFrame({ deviceId: 'web-abc' }).resume, undefined);
});

test('the page says so when the server has no engine to transcribe with', () => {
  assert.match(readyNote({ lane: 'server' }), /Soniox/);
  assert.equal(readyNote({ lane: 'server', engine: 'Soniox' }), '');
});

test('the level meter reads loudness from 0 to 1', () => {
  assert.equal(rms(new Int16Array(160)), 0);
  assert.ok(rms(new Int16Array(160).fill(32767)) > 0.99);
});

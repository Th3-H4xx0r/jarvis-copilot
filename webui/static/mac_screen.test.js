'use strict';
// node --test webui/static/mac_screen.test.js
//
// The mac_screen card finds its share in a computer_do result however it was
// stored (the JSON result, the live repr of an image result, the stored text
// part), and a finished task with no share keeps the plain tool card.
const test = require('node:test');
const assert = require('node:assert/strict');
const M = require('./mac_screen.js');

test('the share id is found in every shape of computer_do result', () => {
  const id = 'scr_0123456789abcdef';
  assert.equal(M.shareIn({ snippet: JSON.stringify({ ok: true, card: { kind: 'mac_screen', share: id } }) }), id);
  assert.equal(M.shareIn({ snippet: `{'card': {'kind': 'mac_screen', 'share': '${id}'}, '_multimodal': True` }), id);
  assert.equal(M.shareIn({ snippet: `[{'type': 'text', 'text': '{"card": {"kind": "mac_screen", "share": "${id}"}}\\nDone'}]` }), id);
  assert.equal(M.shareIn({ snippet: 'Done on the Mac.' }), null);
  assert.equal(M.shareIn({ snippet: 'scr_123' }), null);
  assert.equal(M.shareIn(null), null);
});

test('a finished computer task without a share keeps the plain card', () => {
  assert.equal(M.toolRow({ name: 'computer_do', done: true, snippet: 'Done on the Mac.' }, null), null);
});

test('keys carry the physical code; a PC Del key is ForwardDelete, Backspace stays Backspace', () => {
  const ev = (o) => Object.assign({ metaKey: false, shiftKey: false, altKey: false, ctrlKey: false }, o);
  assert.deepEqual(M.keyMessage(ev({ key: 'ƒ', code: 'KeyF', altKey: true })),
    { t: 'key', key: 'ƒ', code: 'KeyF', mods: ['alt'] });
  assert.equal(M.keyMessage(ev({ key: 'Delete', code: 'Delete' })).key, 'ForwardDelete');
  assert.equal(M.keyMessage(ev({ key: 'Backspace', code: 'Backspace' })).key, 'Backspace');
  assert.equal('code' in M.keyMessage(ev({ key: 'a' })), false);
});

test('⌘V / Ctrl+V are left to the paste event', () => {
  assert.equal(M.isPasteKey({ metaKey: true, key: 'v', code: 'KeyV' }), true);
  assert.equal(M.isPasteKey({ ctrlKey: true, key: 'V', code: 'KeyV' }), true);
  assert.equal(M.isPasteKey({ metaKey: true, key: 'c', code: 'KeyC' }), false);
  assert.equal(M.isPasteKey({ key: 'v', code: 'KeyV' }), false);
});

test('a replay may still be uploading only for a recently ended task share', () => {
  const now = Date.parse('2026-11-03T12:00:00Z');
  const ended = (min) => new Date(now - min * 60000).toISOString();
  assert.equal(M.replayMayCome({ reason: 'task', ended_at: ended(1) }, now), true);
  assert.equal(M.replayMayCome({ reason: 'task', ended_at: ended(60) }, now), false);
  assert.equal(M.replayMayCome({ reason: 'anytime', ended_at: ended(1) }, now), false);
  assert.equal(M.replayMayCome({ reason: 'task', ended_at: null }, now), false);
  assert.equal(M.replayMayCome({ reason: 'task', ended_at: ended(1), replay_url: '/x.mp4' }, now), false);
});

test('the note says to open Jarvis when the Mac is offline, and a real failure when it fails', () => {
  assert.match(M.liveNote({ mac_online: false }, { state: 'connecting' }), /Open Jarvis on your Mac/);
  assert.equal(M.liveNote({ mac_online: true }, { state: 'live' }), null);
  assert.match(M.liveNote({ mac_online: true }, { state: 'failed', error: 'Couldn’t connect to your Mac — retrying.' }),
    /Couldn’t connect/);
  assert.ok(M.backoff(1) < M.backoff(3) && M.backoff(20) === 30000);
});

test('the Mac\'s candidates wait for its answer', async () => {
  const added = [];
  const pc = {
    signalingState: 'have-local-offer', remoteDescription: null,
    async setRemoteDescription(d) { this.remoteDescription = d; this.signalingState = 'stable'; },
    async addIceCandidate(c) { if (!this.remoteDescription) throw new Error('too early'); added.push(c.candidate); },
    close() {},
  };
  const v = new M._Viewer('scr_0123456789abcdef');
  v.pc = pc;
  await v.handle({ type: 'candidate', candidate: { candidate: 'c1', sdpMid: '0', sdpMLineIndex: 0 } });
  assert.deepEqual(added, []);
  await v.handle({ type: 'answer', sdp: 'v=0' });
  await v.handle({ type: 'candidate', candidate: { candidate: 'c2', sdpMid: '0', sdpMLineIndex: 0 } });
  assert.deepEqual(added, ['c1', 'c2']);
  v.end();
});

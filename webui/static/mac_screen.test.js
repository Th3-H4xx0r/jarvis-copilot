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

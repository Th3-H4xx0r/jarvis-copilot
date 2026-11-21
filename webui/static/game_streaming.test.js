// node --test webui/static/game_streaming.test.js — the card's pure helpers.
'use strict';
const test = require('node:test');
const assert = require('node:assert');
const G = require('./game_streaming.js');

test('status line reads the live app, else reachability', () => {
  assert.strictEqual(G.statusLine({ live: { active: true, app: 'Hades' } }), 'Streaming Hades');
  assert.strictEqual(G.statusLine({ live: { active: true } }), 'Streaming a game');
  assert.strictEqual(G.statusLine({ reachable: true, apps: [{ name: 'A' }, { name: 'B' }] }), 'Idle · 2 games');
  assert.strictEqual(G.statusLine({ reachable: true, apps: [{ name: 'A' }] }), 'Idle · 1 game');
  assert.strictEqual(G.statusLine({ reachable: true, apps: [] }), 'Idle');
  assert.strictEqual(G.statusLine({ reachable: false }), 'Host unreachable');
  assert.strictEqual(G.statusLine(undefined), 'Host unreachable');
});

test('primary is the first game and target, or null without a target', () => {
  assert.deepStrictEqual(
    G.primary({ apps: [{ name: 'Hades' }], targets: [{ name: 'Mac', kind: 'mac' }] }),
    { game: 'Hades', target: 'Mac' });
  assert.strictEqual(G.primary({ apps: [{ name: 'Hades' }], targets: [] }), null);
  assert.deepStrictEqual(
    G.primary({ targets: [{ name: 'TV' }] }), { game: 'a game', target: 'TV' });
});

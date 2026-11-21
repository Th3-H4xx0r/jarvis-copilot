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

test('typeGuess maps names to Mac / Android TV / iPhone, else Mac', () => {
  assert.strictEqual(G.typeGuess('MacBook Pro'), 'mac');
  assert.strictEqual(G.typeGuess('SHIELD Android TV'), 'androidtv');
  assert.strictEqual(G.typeGuess('Fire TV Stick'), 'androidtv');
  assert.strictEqual(G.typeGuess('Google TV'), 'androidtv');
  assert.strictEqual(G.typeGuess('Living Room TV'), 'androidtv');
  assert.strictEqual(G.typeGuess('iPhone 17 Pro'), 'ios');
  assert.strictEqual(G.typeGuess('Pranav\'s iPad'), 'ios');
  assert.strictEqual(G.typeGuess('Steam Deck'), 'mac');
});

test('detectHeadline distinguishes offline / running / needs-login / found', () => {
  assert.strictEqual(G.detectHeadline({ online: true, running: true, needs_login: false }),
    'Found Sunshine on your gaming PC');
  assert.strictEqual(G.detectHeadline({ online: true, running: true, needs_login: true }),
    'Sunshine is running — add your Sunshine login below');
  assert.strictEqual(G.detectHeadline({ online: true, running: false }),
    "Sunshine isn't running on your PC yet");
  assert.strictEqual(G.detectHeadline({ online: false }),
    'Your PC is offline — turn it on to finish setup');
});

test('drafts guess unknown types and keep saved type + address', () => {
  var paired = [{ name: 'MacBook' }, { name: 'Shield' }, { name: 'Spare Phone' }];
  var targets = [{ name: 'Shield', kind: 'androidtv', tv_addr: '10.0.0.5:5555' },
                 { name: 'Old TV', kind: 'androidtv', tv_addr: '10.0.0.9:5555' }];
  var d = G.drafts(paired, targets);
  assert.deepStrictEqual(d.map(function (x) { return x.name; }), ['MacBook', 'Shield', 'Spare Phone', 'Old TV']);
  assert.strictEqual(d[0].kind, 'mac');
  assert.strictEqual(d[1].kind, 'androidtv');
  assert.strictEqual(d[1].tv_addr, '10.0.0.5:5555');
  assert.strictEqual(d[2].kind, 'mac');
  assert.strictEqual(d[3].name, 'Old TV');
});


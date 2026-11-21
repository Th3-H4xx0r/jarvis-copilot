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


test('statusLine says needs-sign-in when the login is wrong, not unreachable', () => {
  assert.strictEqual(G.statusLine({ reachable: false, needs_login: true }),
    'Sunshine needs sign-in — check your password');
  assert.strictEqual(G.statusLine({ reachable: false, needs_login: false }), 'Host unreachable');
});

test('pairSelection keeps the pick, auto-picks the only waiting device, else none', () => {
  var a = { id: 'a'.repeat(32), name: 'roth', address: '192.168.1.69' };
  var b = { id: 'b'.repeat(32), name: 'Shield' };
  assert.strictEqual(G.pairSelection(null, [a]), a.id);
  assert.strictEqual(G.pairSelection(null, [a, b]), null);
  assert.strictEqual(G.pairSelection(b.id, [a, b]), b.id);
  assert.strictEqual(G.pairSelection(a.id, []), null);
  assert.strictEqual(G.pairSelection(null, undefined), null);
});

test('pairWaitingLine says what the pair panel is waiting for', () => {
  var a = { id: 'a'.repeat(32), name: 'roth', address: '192.168.1.69' };
  assert.strictEqual(G.pairWaitingLine(null), 'Looking for devices…');
  assert.strictEqual(G.pairWaitingLine({ ok: true, reachable: true, pairings: [] }),
    'Waiting for a device… On the device, open Moonlight and tap your PC');
  assert.strictEqual(G.pairWaitingLine({ ok: true, reachable: true, pairings: [a] }),
    'Enter the PIN shown on roth');
  assert.strictEqual(G.pairWaitingLine({ ok: true, reachable: true, pairings: [a, { id: 'b' }] }),
    "Pick the device that's showing a PIN");
  assert.strictEqual(G.pairWaitingLine({ ok: false, offline: true, pairings: [] }),
    'Your PC is asleep or offline — wake it to pair');
  assert.strictEqual(G.pairWaitingLine({ ok: true, needs_login: true, pairings: [] }),
    'Sunshine needs sign-in — check your password above');
  assert.strictEqual(G.pairWaitingLine({ ok: true, reachable: false, pairings: [] }),
    "Sunshine isn't running on your PC");
  assert.strictEqual(G.pairLabel({ address: '10.0.0.2' }), '10.0.0.2');
});

test('detectHeadline shows a rejection only when a password is already set', () => {
  assert.strictEqual(G.detectHeadline({ online: true, running: true, needs_login: true }, true),
    'That login was rejected — check your Sunshine password');
  assert.strictEqual(G.detectHeadline({ online: true, running: true, needs_login: true }, false),
    'Sunshine is running — add your Sunshine login below');
  assert.strictEqual(G.detectHeadline({ online: true, running: true, needs_login: false }, true),
    'Found Sunshine on your gaming PC');
});

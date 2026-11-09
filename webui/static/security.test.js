'use strict';
// node --test webui/static/security.test.js
//
// The Security page's pure helpers: the status line and the event-feed
// filters. No DOM; fixtures use documentation IPs only (the repo is public).
const test = require('node:test');
const assert = require('node:assert/strict');
const S = require('./security.js');

const EVENTS = [
  { id: 1, ts: '2026-11-08T03:04:05Z', source: 'device', kind: 'auth.failed', actor: '203.0.113.7', detail: {}, outcome: 'block' },
  { id: 2, ts: '2026-11-08T03:05:00Z', source: 'host', kind: 'ssh.login', actor: 'root@198.51.100.4', detail: {}, outcome: 'alert' },
  { id: 3, ts: '2026-11-08T03:06:00Z', source: 'host', kind: 'file.changed', actor: 'webui/app.py', detail: {}, outcome: 'digest' },
  { id: 4, ts: '2026-11-08T03:07:00Z', source: 'agent', kind: 'tool.risky', actor: 'session-1', detail: {}, outcome: 'alert' },
  { id: 5, ts: '2026-11-08T03:08:00Z', source: 'device', kind: 'pair.claimed', actor: '203.0.113.9', detail: {}, outcome: 'ignore' },
];
const ids = list => list.map(e => e.id);

test('status line: all quiet with no open alerts', () => {
  assert.equal(S.securityStatusLine({ state: 'quiet', open_alerts: 0 }), 'All quiet');
});

test('status line: one open alert is singular', () => {
  assert.equal(S.securityStatusLine({ state: 'alerts', open_alerts: 1 }), '1 open alert');
});

test('status line: two open alerts are plural', () => {
  assert.equal(S.securityStatusLine({ state: 'alerts', open_alerts: 2 }), '2 open alerts');
});

test('status line: nothing loaded yet says nothing', () => {
  assert.equal(S.securityStatusLine(null), '');
});

test('filter: all/all keeps every event in order', () => {
  assert.deepEqual(ids(S.filterEvents(EVENTS, { source: 'all', level: 'all' })), [1, 2, 3, 4, 5]);
  assert.deepEqual(ids(S.filterEvents(EVENTS, {})), [1, 2, 3, 4, 5]);
});

test('filter: by source', () => {
  assert.deepEqual(ids(S.filterEvents(EVENTS, { source: 'device', level: 'all' })), [1, 5]);
  assert.deepEqual(ids(S.filterEvents(EVENTS, { source: 'host', level: 'all' })), [2, 3]);
  assert.deepEqual(ids(S.filterEvents(EVENTS, { source: 'agent', level: 'all' })), [4]);
});

test('filter: by level matches the outcome', () => {
  assert.deepEqual(ids(S.filterEvents(EVENTS, { source: 'all', level: 'alert' })), [2, 4]);
  assert.deepEqual(ids(S.filterEvents(EVENTS, { source: 'all', level: 'block' })), [1]);
  assert.deepEqual(ids(S.filterEvents(EVENTS, { source: 'all', level: 'digest' })), [3]);
});

test('filter: source and level together', () => {
  assert.deepEqual(ids(S.filterEvents(EVENTS, { source: 'host', level: 'alert' })), [2]);
  assert.deepEqual(ids(S.filterEvents(EVENTS, { source: 'agent', level: 'block' })), []);
});

test('filter: a missing list is an empty feed', () => {
  assert.deepEqual(S.filterEvents(null, { source: 'all', level: 'all' }), []);
});

test('event title: the readable title wins over the raw kind', () => {
  assert.equal(S.eventTitle({ kind: 'auth.failed', title: 'Failed sign-in' }), 'Failed sign-in');
});

test('event title: a missing or empty title falls back to the kind', () => {
  assert.equal(S.eventTitle({ kind: 'ssh.accepted' }), 'ssh.accepted');
  assert.equal(S.eventTitle({ kind: 'ssh.accepted', title: '' }), 'ssh.accepted');
  assert.equal(S.eventTitle({ kind: 'ssh.accepted', title: '   ' }), 'ssh.accepted');
  assert.equal(S.eventTitle({ kind: 'ssh.accepted', title: null }), 'ssh.accepted');
});

test('event title: neither title nor kind says "event"', () => {
  assert.equal(S.eventTitle({}), 'event');
  assert.equal(S.eventTitle({ title: '', kind: '' }), 'event');
  assert.equal(S.eventTitle(null), 'event');
});

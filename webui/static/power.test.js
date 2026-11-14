// node --test webui/static/power.test.js — JCPower's state and gating logic.
'use strict';
const test = require('node:test');
const assert = require('node:assert');
const JCPower = require('./power.js');

function fakeDoc(ids) {
  const els = ids.map(id => {
    const classes = new Set();
    return { id, getAttribute: () => id, classList: { toggle(c, on) { on ? classes.add(c) : classes.delete(c); } }, classes };
  });
  return { els, querySelectorAll: () => els };
}

test('unknown id is on', () => {
  JCPower.apply({ integrations: [] }, fakeDoc([]));
  assert.strictEqual(JCPower.isOn('anything'), true);
});

test('data-power elements toggle with the switch', () => {
  const doc = fakeDoc(['kanban', 'security-advisor']);
  JCPower.apply({ integrations: [{ id: 'kanban', enabled: false }, { id: 'security-advisor', enabled: true }] }, doc);
  assert.ok(doc.els[0].classes.has('power-off'));
  assert.ok(!doc.els[1].classes.has('power-off'));
  JCPower.apply({ integrations: [{ id: 'kanban', enabled: true }] }, doc);
  assert.ok(!doc.els[0].classes.has('power-off'));
});

test('a pending switch-off says it waits for Face ID', () => {
  JCPower.pending.car = true;
  assert.strictEqual(JCPower.subtitle({ id: 'car', enabled: true, status_line: 'Locked' }),
    'Waiting for Face ID on your iPhone');
  JCPower.apply({ integrations: [{ id: 'car', enabled: false }] }, fakeDoc([]));
  assert.strictEqual(JCPower.subtitle({ id: 'car', enabled: false }), 'Off');
});

test('secrets render only as set / not set', () => {
  assert.strictEqual(JCPower.secretLabel({ set: true }), 'Set');
  assert.strictEqual(JCPower.secretLabel({ set: false }), 'Not set');
  assert.strictEqual(JCPower.secretLabel(undefined), 'Not set');
});

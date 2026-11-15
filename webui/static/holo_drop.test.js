'use strict';
// node --test webui/static/holo_drop.test.js
//
// Holo Drop on the web: what a pasted thing becomes, what an arrival may do without a click,
// which links ever open, and where a fling goes.
const test = require('node:test');
const assert = require('node:assert/strict');
const H = require('./holo_drop.js');

test('pasted links travel as links, anything else as text', () => {
  assert.deepEqual(H.fromText(' https://apple.com/x '), { kind: 'link', url: 'https://apple.com/x' });
  assert.deepEqual(H.fromText('buy milk'), { kind: 'text', text: 'buy milk' });
  assert.equal(H.fromText('   '), null);
  assert.deepEqual(H.fromText('javascript:alert(1)'), { kind: 'text', text: 'javascript:alert(1)' });
});

test('file kinds come from MIME', () => {
  assert.equal(H.kindOf('image/heic'), 'image');
  assert.equal(H.kindOf('video/mp4'), 'video');
  assert.equal(H.kindOf('application/pdf'), 'file');
  assert.equal(H.kindOf(''), 'file');
});

test('opening a link waits for his click; copying does not', () => {
  const link = H.plan({ kind: 'link', action: 'open' });
  assert.equal(link.needsClick, true);
  assert.equal(link.outcome, 'opened');
  const copy = H.plan({ kind: 'text', action: 'save_copy' });
  assert.equal(copy.needsClick, false);
  assert.equal(copy.auto.copy, true);
  assert.equal(copy.outcome, 'saved_copied');
  const file = H.plan({ kind: 'image', action: 'open' });
  assert.equal(file.auto.download, true);
  assert.equal(file.needsClick, false);
});

test('only web links ever open', () => {
  assert.equal(H.safeLink('https://a.b/c'), 'https://a.b/c');
  assert.equal(H.safeLink('javascript:alert(1)'), null);
  assert.equal(H.safeLink('file:///etc/passwd'), null);
  assert.equal(H.safeLink('not a url'), null);
});

test('upload path carries the file and target', () => {
  const p = H.uploadPath({ name: 'a b.pdf', type: 'application/pdf' }, 'mac-1', 'save');
  assert.match(p, /^api\/holo-drop\/drops\/upload\?/);
  const q = new URLSearchParams(p.split('?')[1]);
  assert.equal(q.get('kind'), 'file');
  assert.equal(q.get('target'), 'mac-1');
  assert.equal(q.get('name'), 'a b.pdf');
  assert.equal(q.get('action'), 'save');
  assert.equal(new URLSearchParams(H.uploadPath({ name: 'x', type: '' }, 't', null).split('?')[1]).get('action'), null);
});

test('a fling goes to the bubble it points at', () => {
  const pos = H.ring([{ id: 'up' }, { id: 'right' }, { id: 'down' }, { id: 'left' }], 400, 400);
  const o = { x: 200, y: 184 };
  assert.equal(H.flingTarget(0, -900, o, pos), 'up');
  assert.equal(H.flingTarget(900, 0, o, pos), 'right');
  assert.equal(H.flingTarget(-900, 0, o, pos), 'left');
  assert.equal(H.flingTarget(30, -40, o, pos), null, 'a slow drag is not a fling');
});

test('outcomes in words', () => {
  assert.equal(H.words('saved_opened'), 'Saved + opened');
  assert.equal(H.outcome('save_copy'), 'saved_copied');
});

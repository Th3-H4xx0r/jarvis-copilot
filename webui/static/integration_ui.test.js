// node --test webui/static/integration_ui.test.js — the integration UI renderer.
'use strict';
const test = require('node:test');
const assert = require('node:assert');
const ui = require(process.env.JCI_PATH || './integration_ui.js');

// A small fake DOM: enough for the renderer.
function fakeDoc() {
  function El(tag) {
    this.tagName = tag.toUpperCase(); this.children = []; this.attrs = {}; this.listeners = {};
    this.style = {}; this.className = ''; this._text = '';
    const self = this;
    this.classList = { add(c) { self.className += ' ' + c; } };
  }
  El.prototype.appendChild = function (c) { this.children.push(c); return c; };
  El.prototype.setAttribute = function (k, v) { this.attrs[k] = String(v); };
  El.prototype.getAttribute = function (k) { return this.attrs[k]; };
  El.prototype.addEventListener = function (k, fn) { (this.listeners[k] = this.listeners[k] || []).push(fn); };
  El.prototype.fire = function (k, ev) { (this.listeners[k] || []).forEach(fn => fn(ev || {})); };
  Object.defineProperty(El.prototype, 'textContent', {
    get() { return this._text + this.children.map(c => c.textContent).join(''); },
    set(v) { this._text = String(v); },
  });
  return { createElement: (t) => new El(t) };
}
function all(el, out = []) { out.push(el); (el.children || []).forEach(c => all(c, out)); return out; }
function byNode(el, type) { return all(el).filter(e => e.attrs && e.attrs['data-node'] === type); }

const EVERY = {
  type: 'vstack', children: [
    { type: 'section', title: 'S', children: [{ type: 'text', value: 'hello' }] },
    { type: 'hstack', children: [{ type: 'symbol', name: 'star' }, { type: 'symbolValue', symbol: 'x', value: 1 }] },
    { type: 'zstack', children: [{ type: 'dot', color: '#fff' }] },
    { type: 'hscroll', children: [{ type: 'badge', text: 'b' }] },
    { type: 'grid', columns: 2, children: [{ type: 'stat', value: 3, caption: 'c' }, { type: 'spacer' }] },
    { type: 'list', data: { $: 'items' }, row: { type: 'row', title: { $row: 'name' } } },
    { type: 'titleSubtitle', title: 't', subtitle: 's' },
    { type: 'image', source: 'https://x/y.png' }, { type: 'progress', value: 0.5 },
    { type: 'segbar', segments: [{}, {}] }, { type: 'gauge', value: 0.3 }, { type: 'timer', to: 1 },
    { type: 'timeProgress', from: 0, to: 1 }, { type: 'keyValue', pairs: [{ label: 'a', value: 'b' }] },
    { type: 'sparkline', points: [1, 2, 3] }, { type: 'iconStrip', items: [{}, {}] },
    { type: 'waveform' }, { type: 'divider' }, { type: 'accent' }, { type: 'chart', series: [{ points: [1, 3] }] },
    { type: 'model', device: 'ring' }, { type: 'button', label: 'Go', action: 'go' },
    { type: 'toggle', label: 'T', value: true, action: 'flip' }, { type: 'textField', placeholder: 'p' },
    { type: 'picker', options: [{ label: 'A', value: 'a' }] }, { type: 'slider', min: 0, max: 1 },
    { type: 'stepper' }, { type: 'date' },
  ],
};
const TYPES = ['vstack', 'hstack', 'zstack', 'grid', 'section', 'hscroll', 'list', 'spacer', 'text',
  'titleSubtitle', 'stat', 'symbol', 'symbolValue', 'image', 'dot', 'badge', 'progress', 'segbar', 'gauge',
  'timer', 'timeProgress', 'keyValue', 'sparkline', 'iconStrip', 'waveform', 'divider', 'accent', 'chart',
  'model', 'row', 'button', 'toggle', 'textField', 'picker', 'slider', 'stepper', 'date'];

test('every node type the validator accepts renders', () => {
  const out = ui.render(EVERY, { items: [{ name: 'Milk' }] }, { doc: fakeDoc() });
  for (const t of TYPES) assert.ok(byNode(out, t).length >= 1, 'missing ' + t);
});

test('bindings read state, rows and defaults', () => {
  assert.strictEqual(ui.resolve({ $: 'a.b' }, { a: { b: 7 } }), 7);
  assert.strictEqual(ui.resolve({ $: 'x', default: '—' }, {}), '—');
  assert.strictEqual(ui.resolve({ $row: 'n' }, {}, { n: 'r' }), 'r');
  const out = ui.render({ type: 'list', data: { $: 'items' }, row: { type: 'row', title: { $row: 'name' } } },
    { items: [{ name: 'Milk' }, { name: 'Eggs' }] }, { doc: fakeDoc() });
  assert.deepStrictEqual(byNode(out, 'row').map(r => r.textContent), ['Milk', 'Eggs']);
});

test('when hides a node', () => {
  const tree = { type: 'vstack', children: [{ type: 'text', value: 'shown', when: { $: 'on' } },
    { type: 'text', value: 'hidden', when: { not: { $: 'on' } } }] };
  const out = ui.render(tree, { on: true }, { doc: fakeDoc() });
  assert.deepStrictEqual(byNode(out, 'text').map(t => t.textContent), ['shown']);
});

test('a button runs its action with the control', () => {
  const calls = [];
  const out = ui.render({ type: 'button', id: 'b1', label: 'Go', action: 'go' }, {},
    { doc: fakeDoc(), onAction: (name, ev) => { calls.push([name, ev.control]); return Promise.resolve({}); } });
  byNode(out, 'button')[0].fire('click');
  assert.deepStrictEqual(calls, [['go', 'b1']]);
});

test('an action with confirm text asks first', () => {
  const calls = []; let asked = null;
  const out = ui.render({ type: 'button', label: 'Clear', action: 'clear' }, {}, {
    doc: fakeDoc(), confirms: { clear: 'Clear all?' },
    confirmSheet: (msg, go) => { asked = msg; },
    onAction: (name) => { calls.push(name); return Promise.resolve({}); },
  });
  byNode(out, 'button')[0].fire('click');
  assert.strictEqual(asked, 'Clear all?');
  assert.deepStrictEqual(calls, []);
});

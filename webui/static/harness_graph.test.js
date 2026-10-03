'use strict';
// node --test webui/static/harness_graph.test.js
//
// Pure document edits behind the harness canvas editor (harness_editor.js):
// add/remove/wire nodes, duplicate a built-in, what a new wire's condition
// is, and the exact design the editor posts to the server.
const test = require('node:test');
const assert = require('node:assert/strict');
const G = require('./harness_graph.js');

test('new harness has a message node', () => {
  assert.equal(G.newHarness('mine', 'Mine').nodes.filter(n => n.type === 'message').length, 1);
});

test('add + connect + disconnect', () => {
  const d = G.newHarness('m', 'M');
  const a = G.addNode(d, 'answer', 10, 20);
  assert.ok(G.connect(d, 'in', a, 'always'));
  assert.ok(!G.connect(d, 'in', a, 'always'));
  assert.ok(!G.connect(d, a, a, 'always'));
  assert.ok(!G.connect(d, 'in', 'nope', 'always'));
  G.disconnect(d, 0);
  assert.equal(d.edges.length, 0);
});

test('node ids are unique per type', () => {
  const d = G.newHarness('m', 'M');
  assert.equal(G.addNode(d, 'answer', 0, 0), 'answer-1');
  assert.equal(G.addNode(d, 'answer', 0, 0), 'answer-2');
  assert.equal(G.addNode(d, 'route', 0, 0), 'route-1');
});

test('removing a node removes its wires', () => {
  const d = G.newHarness('m', 'M');
  const a = G.addNode(d, 'answer', 0, 0);
  G.connect(d, 'in', a, 'always');
  G.removeNode(d, a);
  assert.equal(d.edges.length, 0);
  assert.ok(!d.nodes.find(n => n.id === a));
});

test('message node cannot be removed', () => {
  const d = G.newHarness('m', 'M');
  assert.equal(G.removeNode(d, 'in'), false);
  assert.ok(d.nodes.find(n => n.id === 'in'));
});

test('moveNode rounds to whole pixels', () => {
  const d = G.newHarness('m', 'M');
  G.moveNode(d, 'in', 10.6, 20.2);
  assert.deepEqual([d.nodes[0].x, d.nodes[0].y], [11, 20]);
});

test('duplicate drops builtin, version, problems', () => {
  const d = Object.assign(G.newHarness('single', 'Single'), { builtin: true, version: 3, problems: [] });
  const c = G.duplicate(d, 'single-copy', 'Single copy');
  assert.equal(c.id, 'single-copy');
  assert.equal(c.name, 'Single copy');
  assert.ok(!('builtin' in c) && !('version' in c) && !('problems' in c));
  assert.notStrictEqual(c.nodes, d.nodes);
});

test('defaults per type', () => {
  assert.equal(G.defaultsFor('background').deliver, 'speak_or_notify');
  assert.equal(G.defaultsFor('review').deliver, 'post_if_changed');
  assert.equal(G.defaultsFor('answer').tools, 'lean');
  assert.equal(G.defaultsFor('route').by, 'rules');
  assert.notStrictEqual(G.defaultsFor('route').rules, G.defaultsFor('route').rules);
});

test('nextWhen: first Route wire is default, later ones take unused labels', () => {
  const d = G.newHarness('m', 'M');
  const r = G.addNode(d, 'route', 0, 0);
  const a = G.addNode(d, 'answer', 0, 0);
  const b = G.addNode(d, 'answer', 0, 0);
  const c = G.addNode(d, 'answer', 0, 0);
  d.nodes.find(n => n.id === r).labels = ['deep'];
  assert.equal(G.nextWhen(d, 'in'), 'always');
  assert.equal(G.nextWhen(d, r), 'default');
  G.connect(d, r, a, 'default');
  assert.equal(G.nextWhen(d, r), 'label:deep');
  G.connect(d, r, b, 'label:deep');
  // Out of labels: a fresh one is made and remembered on the node.
  assert.equal(G.nextWhen(d, r), 'label:path-2');
  assert.deepEqual(d.nodes.find(n => n.id === r).labels, ['deep', 'path-2']);
  G.connect(d, r, c, 'label:path-2');
});

test('nextWhen: Answer to Background defaults to a hand-off', () => {
  const d = G.newHarness('m', 'M');
  const a = G.addNode(d, 'answer', 0, 0);
  const bg = G.addNode(d, 'background', 0, 0);
  assert.equal(G.nextWhen(d, a, bg), 'handoff');
  const rv = G.addNode(d, 'review', 0, 0);
  assert.equal(G.nextWhen(d, a, rv), 'always');
});

test('edgeLabel names every condition but always', () => {
  assert.equal(G.edgeLabel('always'), '');
  assert.equal(G.edgeLabel(undefined), '');
  assert.equal(G.edgeLabel('handoff'), 'hand-off');
  assert.equal(G.edgeLabel('default'), 'default');
  assert.equal(G.edgeLabel('label:deep'), 'deep');
  assert.equal(G.edgeLabel('slow:8'), 'slower than 8 s');
  assert.equal(G.edgeLabel('tools:3'), '3+ tools');
});

test('toDesign strips server-only fields and is a copy', () => {
  const d = Object.assign(G.newHarness('m', 'M'), { builtin: false, version: 4, problems: [{ node: 'in' }], updated_at: 1 });
  const out = G.toDesign(d);
  assert.deepEqual(Object.keys(out).sort(), ['edges', 'icon', 'id', 'name', 'nodes']);
  out.nodes.push({});
  assert.equal(d.nodes.length, 1);
});

test('problemsFor splits node, edge and harness problems', () => {
  const d = Object.assign(G.newHarness('m', 'M'), {
    problems: [{ node: 'in', edge: null, message: 'a' }, { node: null, edge: 0, message: 'b' },
               { node: null, edge: null, message: 'c' }],
  });
  assert.deepEqual(G.problemsFor(d, { node: 'in' }), ['a']);
  assert.deepEqual(G.problemsFor(d, { edge: 0 }), ['b']);
  assert.deepEqual(G.problemsFor(d, {}), ['c']);
});

test('uniqueId and slug make safe new ids', () => {
  assert.equal(G.slug('Fast + Claude!'), 'fast-claude');
  assert.equal(G.slug('   '), 'harness');
  assert.equal(G.uniqueId('single-copy', ['single-copy']), 'single-copy-2');
  assert.equal(G.uniqueId('x', ['x', 'x-2']), 'x-3');
  assert.equal(G.uniqueId('y', []), 'y');
});

test('modelOptions turns api/models groups into @provider:model refs', () => {
  const groups = [
    { provider: 'Ollama Cloud', provider_id: 'ollama-cloud', models: [{ id: 'gemma4:31b', label: 'Gemma 4 31B' }] },
    { provider: 'Claude Code', provider_id: 'claude-code', models: [{ id: '@claude-code:claude-sonnet-5-5', label: 'Sonnet' }] },
    { provider: 'OpenRouter', provider_id: 'openrouter', models: [{ id: 'openai/gpt-4o', label: 'GPT-4o' }] },
  ];
  const out = G.modelOptions(groups);
  assert.deepEqual(out.map(g => g.label), ['Ollama Cloud', 'Claude Code', 'OpenRouter']);
  assert.deepEqual(out[0].options[0], { value: '@ollama-cloud:gemma4:31b', label: 'Gemma 4 31B' });
  assert.equal(out[1].options[0].value, '@claude-code:claude-sonnet-5-5');
  assert.equal(out[2].options[0].value, '@openrouter:openai/gpt-4o');
  assert.deepEqual(G.modelOptions(null), []);
});

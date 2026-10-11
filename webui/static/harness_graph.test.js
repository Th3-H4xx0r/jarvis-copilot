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

test('decisionOptions lists decision models in their own group', () => {
  const g = G.decisionOptions([{ id: '@celeris:celeris-1-decision', label: 'Celeris 1 Decision',
    provider: 'Celeris', provider_id: 'celeris' }]);
  assert.deepEqual(g, [{ label: 'Decision models',
    options: [{ value: '@celeris:celeris-1-decision', label: 'Celeris 1 Decision · Celeris' }] }]);
  assert.deepEqual(G.decisionOptions(undefined), []);
});

function routeDoc() {
  return {
    id: 'h', name: 'H', nodes: [
      { id: 'in', type: 'message' },
      { id: 'r', type: 'route', by: 'rules', labels: ['deep', 'quick'],
        label_descriptions: { deep: 'needs research' },
        rules: [{ match: 'keywords', value: 'code', label: 'deep' }, { match: 'regex', value: 'x', label: 'other' }] },
      { id: 'a', type: 'answer' }, { id: 'b', type: 'answer' }, { id: 'r2', type: 'route', labels: ['deep'] }],
    edges: [{ from: 'in', to: 'r', when: 'always' }, { from: 'r', to: 'a', when: 'label:deep' },
      { from: 'r', to: 'b', when: 'default' }, { from: 'r2', to: 'a', when: 'label:deep' }],
  };
}

test('renameLabel carries the description, the wires and the rules of that Route only', () => {
  const d = routeDoc();
  assert.equal(G.renameLabel(d, 'r', 'deep', ' research '), true);
  const r = d.nodes[1];
  assert.deepEqual(r.labels, ['research', 'quick']);
  assert.deepEqual(r.label_descriptions, { research: 'needs research' });
  assert.equal(r.rules[0].label, 'research');
  assert.equal(r.rules[1].label, 'other');
  assert.equal(d.edges[1].when, 'label:research');
  assert.equal(d.edges[3].when, 'label:deep');  // another Route's wire is untouched
  assert.deepEqual(d.nodes[4].labels, ['deep']);
});

test('renameLabel refuses blank and taken names (rule labels count as taken)', () => {
  const d = routeDoc();
  assert.equal(G.renameLabel(d, 'r', 'deep', '  '), false);
  assert.equal(G.renameLabel(d, 'r', 'deep', 'quick'), false);
  assert.equal(G.renameLabel(d, 'r', 'deep', 'other'), false);
  assert.equal(G.renameLabel(d, 'r', 'deep', 'deep'), true);
  assert.deepEqual(d.nodes[1].labels, ['deep', 'quick']);
});

test('addLabel skips names used by labels, rules and wires', () => {
  const d = routeDoc();
  d.nodes[1].labels = ['path-2'];
  d.edges.push({ from: 'r', to: 'b', when: 'label:path-3' });
  assert.equal(G.addLabel(d, 'r'), 'path-4');
  assert.deepEqual(d.nodes[1].labels, ['path-2', 'path-4']);
});

test('removeLabel drops the label and its description', () => {
  const d = routeDoc();
  G.removeLabel(d, 'r', 0);
  assert.deepEqual(d.nodes[1].labels, ['quick']);
  assert.equal(d.nodes[1].label_descriptions, undefined);
});

test('removeLabel takes its wires with it (a stray wire could never be picked)', () => {
  const d = routeDoc();
  G.removeLabel(d, 'r', 0);
  assert.ok(!d.edges.some(e => e.from === 'r' && e.when === 'label:deep'));
  assert.ok(d.edges.some(e => e.from === 'r2' && e.when === 'label:deep'));  // another Route's wire stays
});

test('describeLabel and labelNote use own keys only', () => {
  const d = routeDoc();
  const r = d.nodes[1];
  assert.equal(G.labelNote(r, 'constructor'), '');
  assert.equal(G.labelNote(r, 'deep'), 'needs research');
  G.describeLabel(d, 'r', 'quick', 'small talk');
  assert.deepEqual(r.label_descriptions, { deep: 'needs research', quick: 'small talk' });
  G.describeLabel(d, 'r', 'deep', '  ');
  G.describeLabel(d, 'r', 'quick', '');
  assert.equal(r.label_descriptions, undefined);
});

// ── A Route's labels and its wires stay in step ────────────────────────────
// The bug seen live: a third wire got `path-2`, its label was retyped to
// `long-running` on the wire (the Route kept `path-2`), and renaming `path-2`
// in the Route panel was then refused — so a model router could never pick it.
function modelRouteDoc() {
  return {
    id: 'h', name: 'H', nodes: [
      { id: 'in', type: 'message' },
      { id: 'r', type: 'route', by: 'model', labels: ['deep'] },
      { id: 'a', type: 'answer' }, { id: 'b', type: 'answer' }, { id: 'c', type: 'answer' }],
    edges: [{ from: 'in', to: 'r', when: 'always' }, { from: 'r', to: 'a', when: 'default' },
      { from: 'r', to: 'b', when: 'label:deep' }],
  };
}

test('retyping a Route wire\'s label renames the label it had (description included)', () => {
  const d = modelRouteDoc();
  const when = G.nextWhen(d, 'r', 'c');
  assert.equal(when, 'label:path-2');
  G.connect(d, 'r', 'c', when);
  G.describeLabel(d, 'r', 'path-2', 'long jobs');
  assert.equal(G.relabelWire(d, 3, ' long-running '), true);
  const r = d.nodes[1];
  assert.deepEqual(r.labels, ['deep', 'long-running']);
  assert.deepEqual(r.label_descriptions, { 'long-running': 'long jobs' });
  assert.equal(d.edges[3].when, 'label:long-running');
});

test('relabelWire carries the rules of a rules Route', () => {
  const d = routeDoc();
  assert.equal(G.relabelWire(d, 1, 'research'), true);
  assert.deepEqual(d.nodes[1].labels, ['research', 'quick']);
  assert.equal(d.nodes[1].rules[0].label, 'research');
  assert.equal(d.edges[1].when, 'label:research');
  assert.equal(d.edges[3].when, 'label:deep');  // another Route's wire is untouched
});

test('relabelWire points the wire at a label no other wire has', () => {
  const d = routeDoc();
  assert.equal(G.relabelWire(d, 1, 'quick'), true);
  assert.equal(d.edges[1].when, 'label:quick');
  assert.deepEqual(d.nodes[1].labels, ['deep', 'quick']);
  // A rules Route also picks its rules' labels.
  assert.equal(G.relabelWire(d, 1, 'other'), true);
  assert.equal(d.edges[1].when, 'label:other');
});

test('relabelWire refuses blank names and labels another wire already has', () => {
  const d = modelRouteDoc();
  G.connect(d, 'r', 'c', G.nextWhen(d, 'r', 'c'));  // label:path-2
  const before = JSON.stringify(d);
  assert.equal(G.relabelWire(d, 3, '   '), false);
  assert.equal(G.relabelWire(d, 3, 'deep'), false);
  assert.equal(JSON.stringify(d), before);
  assert.equal(G.relabelWire(d, 3, 'path-2'), true);  // unchanged is fine
});

test('relabelWire on a stray wire adds the new name to the labels', () => {
  const d = modelRouteDoc();
  d.edges.push({ from: 'r', to: 'c', when: 'label:ghost' });
  assert.equal(G.relabelWire(d, 3, 'long-running'), true);
  assert.deepEqual(d.nodes[1].labels, ['deep', 'long-running']);
  assert.equal(d.edges[3].when, 'label:long-running');
});

test('renameLabel adopts the stray wire that carries the new name (the live bug)', () => {
  const d = modelRouteDoc();
  const r = d.nodes[1];
  r.labels = ['deep', 'path-2'];
  r.label_descriptions = { 'path-2': 'long jobs' };
  d.edges.push({ from: 'r', to: 'c', when: 'label:long-running' });
  assert.equal(G.renameLabel(d, 'r', 'path-2', 'long-running'), true);
  assert.deepEqual(r.labels, ['deep', 'long-running']);
  assert.deepEqual(r.label_descriptions, { 'long-running': 'long jobs' });
  assert.equal(d.edges[3].when, 'label:long-running');
});

test('renameLabel won\'t adopt a stray wire when the label has a wire of its own', () => {
  const d = modelRouteDoc();
  d.edges.push({ from: 'r', to: 'c', when: 'label:ghost' });
  assert.equal(G.renameLabel(d, 'r', 'deep', 'ghost'), false);
  assert.deepEqual(d.nodes[1].labels, ['deep']);
  assert.equal(d.edges[2].when, 'label:deep');
});

test('freeLabel picks a label no wire has, else makes one', () => {
  const d = modelRouteDoc();
  assert.equal(G.freeLabel(d, 'r'), 'path-2');
  assert.deepEqual(d.nodes[1].labels, ['deep', 'path-2']);
  assert.equal(G.freeLabel(d, 'r'), 'path-2');  // still unwired
});

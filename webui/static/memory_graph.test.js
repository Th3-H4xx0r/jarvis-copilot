'use strict';
// node --test webui/static/memory_graph.test.js
//
// Pure helpers behind the Long-term Memory map (memory_map.js) and the
// "memories used" chat chip (jarvis_memory.js): query building, graph
// load/expand/merge/cap, the force step + settle check, the view transform,
// and matching a chat's user messages to recall traces.
const test = require('node:test');
const assert = require('node:assert/strict');
const G = require('./memory_graph.js');

const DAY = 86400;

function payload(centerId, nodes, edges) {
  return {
    center: { id: centerId, label: centerId === 'me' ? 'You' : centerId, type: centerId === 'me' ? 'me' : 'person' },
    nodes: nodes.map(([id, type, weight]) => ({ id, label: id.toUpperCase(), type, weight, pinned: false, event_start: null })),
    edges: edges.map(([a, b, weight]) => ({ a, b, weight })),
  };
}

// ── query building ──

test('graph query: defaults are center=me, limit 40, no filters', () => {
  const url = G.graphUrl({ center: 'me' }, 1000);
  assert.equal(url, 'api/jarvis-memory/graph?center=me&limit=40');
});

test('graph query: all types on omits types; a subset is a comma list', () => {
  const all = G.graphUrl({ center: 'me', types: G.TYPES.slice() }, 0);
  assert.ok(!all.includes('types='));
  const some = G.graphUrl({ center: 'me', types: ['person', 'place'] }, 0);
  assert.ok(some.includes('types=person%2Cplace'));
});

test('graph query: time range becomes since, source passes through, center is encoded', () => {
  const now = 1_000_000;
  const url = G.graphUrl({ center: 'e 1/2', time: 'week', source: 'imessage', limit: 40 }, now);
  const q = new URLSearchParams(url.split('?')[1]);
  assert.equal(q.get('center'), 'e 1/2');
  assert.equal(Number(q.get('since')), now - 7 * DAY);
  assert.equal(q.get('source'), 'imessage');
  assert.ok(!G.graphUrl({ center: 'me', time: 'all', source: '' }, now).includes('since='));
  assert.ok(!G.graphUrl({ center: 'me', time: 'all', source: '' }, now).includes('source='));
});

test('sinceFor maps week/month/year and leaves all open', () => {
  assert.equal(G.sinceFor('week', 100 * DAY), 93 * DAY);
  assert.equal(G.sinceFor('month', 100 * DAY), 70 * DAY);
  assert.equal(G.sinceFor('year', 400 * DAY), 35 * DAY);
  assert.equal(G.sinceFor('all', 100 * DAY), null);
  assert.equal(G.sinceFor(undefined, 100 * DAY), null);
});

test('source options cover the spec families with Chats=fact, Integrations=cron, Saved=tool', () => {
  const byLabel = Object.fromEntries(G.SOURCES.map(s => [s.label, s.value]));
  assert.equal(byLabel.All, '');
  assert.equal(byLabel.Chats, 'fact');
  assert.equal(byLabel.Integrations, 'cron');
  assert.equal(byLabel.Saved, 'tool');
  for (const v of ['imessage', 'live', 'calendar', 'email', 'health', 'location', 'dashcam']) {
    assert.ok(G.SOURCES.some(s => s.value === v), v);
  }
});

// ── load / expand / cap ──

test('load puts You fixed at the origin and every node around it', () => {
  const g = G.createGraph();
  G.loadGraph(g, payload('me', [['a', 'person', 10], ['b', 'place', 4]], [['me', 'a', 10], ['me', 'b', 4], ['a', 'b', 2]]));
  const me = G.node(g, 'me');
  assert.equal(me.type, 'me');
  assert.equal(me.label, 'You');
  assert.ok(me.fixed);
  assert.equal(me.x, 0);
  assert.equal(me.y, 0);
  assert.equal(g.nodes.length, 3);
  assert.equal(g.edges.length, 3);
  for (const n of g.nodes) assert.ok(Number.isFinite(n.x) && Number.isFinite(n.y));
  const a = G.node(g, 'a');
  assert.ok(Math.hypot(a.x, a.y) > 20, 'not stacked on You');
});

test('load replaces the previous graph', () => {
  const g = G.createGraph();
  G.loadGraph(g, payload('me', [['a', 'person', 1]], [['me', 'a', 1]]));
  G.loadGraph(g, payload('me', [['b', 'topic', 1]], [['me', 'b', 1]]));
  assert.deepEqual(g.nodes.map(n => n.id).sort(), ['b', 'me']);
});

test('load drops edges whose ends are missing and de-duplicates undirected edges', () => {
  const g = G.createGraph();
  G.loadGraph(g, payload('me', [['a', 'person', 1], ['b', 'person', 1]],
    [['me', 'a', 1], ['a', 'b', 2], ['b', 'a', 3], ['a', 'ghost', 1]]));
  assert.equal(g.edges.length, 2);
  const ab = g.edges.find(e => G.edgeKey(e.a, e.b) === G.edgeKey('a', 'b'));
  assert.equal(ab.weight, 3);
});

test('expand merges in place: existing nodes keep their positions, new ones land near the anchor', () => {
  const g = G.createGraph();
  G.loadGraph(g, payload('me', [['a', 'person', 10], ['b', 'place', 4]], [['me', 'a', 10], ['me', 'b', 4]]));
  const a = G.node(g, 'a');
  a.x = 300; a.y = -200;
  const b = G.node(g, 'b');
  const bPos = [b.x, b.y];
  const added = G.mergeGraph(g, payload('a', [['b', 'place', 2], ['c', 'topic', 3], ['d', 'org', 1]],
    [['a', 'b', 2], ['a', 'c', 3], ['a', 'd', 1], ['c', 'd', 1]]), { anchor: 'a' });
  assert.deepEqual(added.sort(), ['c', 'd']);
  assert.deepEqual([b.x, b.y], bPos);
  assert.equal(a.x, 300);
  const c = G.node(g, 'c');
  assert.ok(Math.hypot(c.x - 300, c.y + 200) < 150, 'new node near the anchor');
  assert.ok(g.edges.some(e => G.edgeKey(e.a, e.b) === G.edgeKey('a', 'c')));
  assert.equal(g.nodes.length, 5);
});

test('merge keeps the larger weight and refreshes label/pinned', () => {
  const g = G.createGraph();
  G.loadGraph(g, payload('me', [['a', 'person', 10]], [['me', 'a', 10]]));
  const p = payload('x', [['a', 'person', 3]], []);
  p.nodes[0].label = 'Alice';
  p.nodes[0].pinned = true;
  G.mergeGraph(g, p, { anchor: 'a' });
  const a = G.node(g, 'a');
  assert.equal(a.weight, 10);
  assert.equal(a.label, 'Alice');
  assert.equal(a.pinned, true);
});

test('expanding an unknown center adds the center too', () => {
  const g = G.createGraph();
  G.loadGraph(g, payload('me', [], []));
  G.mergeGraph(g, payload('z', [['y', 'person', 1]], [['z', 'y', 1]]), { anchor: 'z' });
  assert.ok(G.node(g, 'z'));
  assert.ok(G.node(g, 'y'));
});

test('cap evicts the lightest unprotected nodes and their edges', () => {
  const g = G.createGraph();
  const nodes = [];
  const edges = [];
  for (let i = 0; i < 10; i++) { nodes.push(['n' + i, 'topic', i + 1]); edges.push(['me', 'n' + i, i + 1]); }
  G.loadGraph(g, payload('me', nodes, edges));
  G.node(g, 'n0').pinned = true;
  const removed = G.capGraph(g, 6, ['n1']);
  assert.equal(g.nodes.length, 6);
  assert.ok(G.node(g, 'me'), 'You is never evicted');
  assert.ok(G.node(g, 'n0'), 'pinned survives');
  assert.ok(G.node(g, 'n1'), 'protected survives');
  assert.ok(G.node(g, 'n9'));
  assert.ok(!G.node(g, 'n2'));
  assert.deepEqual(removed.sort(), ['n2', 'n3', 'n4', 'n5', 'n6']);
  for (const e of g.edges) assert.ok(G.node(g, e.a) && G.node(g, e.b));
});

test('mergeGraph applies the cap and protects the anchor + new nodes', () => {
  const g = G.createGraph();
  const nodes = [];
  for (let i = 0; i < 8; i++) nodes.push(['n' + i, 'topic', 100 + i]);
  G.loadGraph(g, payload('me', nodes, nodes.map(n => ['me', n[0], n[2]])));
  G.mergeGraph(g, payload('n0', [['x1', 'person', 1], ['x2', 'person', 1]], [['n0', 'x1', 1], ['n0', 'x2', 1]]),
    { anchor: 'n0', cap: 6 });
  assert.equal(g.nodes.length, 6);
  assert.ok(G.node(g, 'n0') && G.node(g, 'x1') && G.node(g, 'x2'));
});

test('MAX_NODES is 150 and BASE_LIMIT is 40', () => {
  assert.equal(G.MAX_NODES, 150);
  assert.equal(G.BASE_LIMIT, 40);
});

// ── fix tools on the canvas ──

test('mergeNodes rewires edges onto the survivor, sums duplicates and drops self loops', () => {
  const g = G.createGraph();
  G.loadGraph(g, payload('me', [['a', 'person', 5], ['b', 'person', 3], ['c', 'place', 2]],
    [['me', 'a', 5], ['me', 'b', 3], ['a', 'b', 1], ['b', 'c', 2], ['a', 'c', 1]]));
  G.mergeNodes(g, 'b', 'a', { label: 'Alice', aliases: ['B'] });
  assert.ok(!G.node(g, 'b'));
  const a = G.node(g, 'a');
  assert.equal(a.label, 'Alice');
  assert.equal(a.weight, 8);
  const keys = g.edges.map(e => G.edgeKey(e.a, e.b));
  assert.equal(new Set(keys).size, keys.length, 'no duplicate edges');
  assert.ok(!g.edges.some(e => e.a === e.b), 'no self loops');
  assert.equal(g.edges.find(e => G.edgeKey(e.a, e.b) === G.edgeKey('me', 'a')).weight, 8);
  assert.equal(g.edges.find(e => G.edgeKey(e.a, e.b) === G.edgeKey('a', 'c')).weight, 3);
});

test('removeNode drops the node and its edges; You cannot be removed', () => {
  const g = G.createGraph();
  G.loadGraph(g, payload('me', [['a', 'person', 5]], [['me', 'a', 5]]));
  assert.equal(G.removeNode(g, 'me'), false);
  assert.equal(G.removeNode(g, 'a'), true);
  assert.equal(g.edges.length, 0);
});

test('merge candidates: same type, not itself, filtered by label or alias, sorted', () => {
  const g = G.createGraph();
  G.loadGraph(g, payload('me', [['a', 'person', 5], ['b', 'person', 3], ['c', 'place', 2], ['d', 'person', 1]], []));
  G.node(g, 'b').label = 'Bob';
  G.node(g, 'd').label = 'Dana';
  G.node(g, 'd').aliases = ['Robbie'];
  assert.deepEqual(G.mergeCandidates(g, 'a', '').map(n => n.id), ['b', 'd']);
  assert.deepEqual(G.mergeCandidates(g, 'a', 'rob').map(n => n.id), ['d']);
  assert.deepEqual(G.mergeCandidates(g, 'a', 'BO').map(n => n.id), ['b']);
  assert.deepEqual(G.mergeCandidates(g, 'c', ''), []);
});

// ── physics ──

test('step keeps You fixed, separates nodes and eventually settles', () => {
  const g = G.createGraph();
  const nodes = [];
  const edges = [];
  for (let i = 0; i < 20; i++) { nodes.push(['n' + i, 'topic', i + 1]); edges.push(['me', 'n' + i, i + 1]); }
  edges.push(['n1', 'n2', 3]);
  G.loadGraph(g, payload('me', nodes, edges));
  let ticks = 0;
  let energy = Infinity;
  while (ticks < 2000) {
    energy = G.step(g);
    ticks++;
    if (G.isSettled(energy, g.nodes.length)) break;
  }
  assert.ok(ticks < 2000, 'settles');
  assert.equal(G.node(g, 'me').x, 0);
  assert.equal(G.node(g, 'me').y, 0);
  for (const n of g.nodes) assert.ok(Number.isFinite(n.x) && Number.isFinite(n.y));
  // No two nodes sit on top of each other.
  for (let i = 0; i < g.nodes.length; i++) {
    for (let j = i + 1; j < g.nodes.length; j++) {
      const a = g.nodes[i], b = g.nodes[j];
      assert.ok(Math.hypot(a.x - b.x, a.y - b.y) > 5, `${a.id}/${b.id}`);
    }
  }
});

test('step leaves a fixed (dragged) node where it is', () => {
  const g = G.createGraph();
  G.loadGraph(g, payload('me', [['a', 'person', 5], ['b', 'person', 5]], [['me', 'a', 5], ['a', 'b', 1]]));
  const a = G.node(g, 'a');
  a.x = 500; a.y = 500; a.fixed = true;
  for (let i = 0; i < 50; i++) G.step(g);
  assert.equal(a.x, 500);
  assert.equal(a.y, 500);
});

test('step survives coincident nodes', () => {
  const g = G.createGraph();
  G.loadGraph(g, payload('me', [['a', 'person', 1], ['b', 'person', 1]], []));
  G.node(g, 'a').x = 10; G.node(g, 'a').y = 10;
  G.node(g, 'b').x = 10; G.node(g, 'b').y = 10;
  G.step(g);
  assert.ok(Number.isFinite(G.node(g, 'a').x));
  assert.notEqual(G.node(g, 'a').x === G.node(g, 'b').x && G.node(g, 'a').y === G.node(g, 'b').y, true);
});

test('isSettled thresholds energy per node', () => {
  assert.equal(G.isSettled(0, 10), true);
  assert.equal(G.isSettled(1e6, 10), false);
  assert.equal(G.isSettled(0, 0), true);
});

// ── look ──

test('radius grows with sqrt(weight) and is clamped; You is the largest base', () => {
  assert.ok(G.radiusFor({ type: 'person', weight: 100 }) > G.radiusFor({ type: 'person', weight: 4 }));
  const r4 = G.radiusFor({ type: 'person', weight: 4 }) - G.radiusFor({ type: 'person', weight: 0 });
  const r16 = G.radiusFor({ type: 'person', weight: 16 }) - G.radiusFor({ type: 'person', weight: 0 });
  assert.ok(Math.abs(r16 / r4 - 2) < 0.01, 'sqrt scaling');
  assert.ok(G.radiusFor({ type: 'person', weight: 1e9 }) <= G.MAX_RADIUS);
  assert.ok(G.radiusFor({ type: 'me', weight: 0 }) >= G.radiusFor({ type: 'person', weight: 0 }));
});

test('colours: one per type, accent for You, a fallback for unknown types', () => {
  const seen = new Set();
  for (const t of G.TYPES) { const c = G.colorFor(t, '#abc'); assert.ok(c); seen.add(c); }
  assert.equal(seen.size, G.TYPES.length);
  assert.equal(G.colorFor('me', '#abc'), '#abc');
  assert.ok(G.colorFor('weird', '#abc'));
});

test('labels show for big nodes, when zoomed, and for selected/highlighted', () => {
  const small = { id: 's', type: 'topic', weight: 1 };
  const big = { id: 'b', type: 'person', weight: 400 };
  assert.equal(G.showLabel(big, 1, {}), true);
  assert.equal(G.showLabel(small, 1, {}), false);
  assert.equal(G.showLabel(small, 2.5, {}), true);
  assert.equal(G.showLabel(small, 1, { selected: 's' }), true);
  assert.equal(G.showLabel(small, 1, { highlight: new Set(['s']) }), true);
  assert.equal(G.showLabel({ id: 'me', type: 'me', weight: 0 }, 0.5, {}), true);
});

test('dimming: only when highlighting, and never for highlighted ids or You', () => {
  assert.equal(G.isDimmed('a', null), false);
  assert.equal(G.isDimmed('a', new Set()), false);
  const hl = new Set(['a']);
  assert.equal(G.isDimmed('a', hl), false);
  assert.equal(G.isDimmed('b', hl), true);
  assert.equal(G.isDimmed('me', hl), false);
});

// ── view transform + hit test ──

test('zoomAt keeps the world point under the cursor still, and clamps scale', () => {
  const v = { x: 200, y: 100, k: 1 };
  const before = G.toWorld(v, 260, 140);
  const v2 = G.zoomAt(v, 2, 260, 140);
  const after = G.toWorld(v2, 260, 140);
  assert.ok(Math.abs(before.x - after.x) < 1e-9 && Math.abs(before.y - after.y) < 1e-9);
  assert.equal(v2.k, 2);
  assert.ok(G.zoomAt(v, 1e6, 0, 0).k <= G.MAX_ZOOM);
  assert.ok(G.zoomAt(v, 1e-6, 0, 0).k >= G.MIN_ZOOM);
  const s = G.toScreen(v2, after.x, after.y);
  assert.ok(Math.abs(s.x - 260) < 1e-9 && Math.abs(s.y - 140) < 1e-9);
});

test('hitTest finds the top-most node under the point, else null', () => {
  const g = G.createGraph();
  G.loadGraph(g, payload('me', [['a', 'person', 1]], []));
  const a = G.node(g, 'a');
  a.x = 100; a.y = 0;
  const v = { x: 0, y: 0, k: 1 };
  assert.equal(G.hitTest(g, v, 101, 1).id, 'a');
  assert.equal(G.hitTest(g, v, 0, 0).id, 'me');
  assert.equal(G.hitTest(g, v, 50, 300), null);
});

// ── chat chip: recall matching ──

test('normalizeQuery strips leading injected [...] blocks, the workspace prefix and whitespace', () => {
  const rules = '[Voice mode — keep answers short, no markdown, speak naturally please ok]\n\n';
  assert.equal(G.normalizeQuery(rules + '  where is mom?  '), 'where is mom?');
  assert.equal(G.normalizeQuery(rules + rules + 'hi'), 'hi');
  assert.equal(G.normalizeQuery('[Workspace::v1: /Users/p/x]\nwhat did I eat'), 'what did I eat');
  assert.equal(G.normalizeQuery('[Workspace: /tmp]\nhello'), 'hello');
  assert.equal(G.normalizeQuery('[short] tag stays'), '[short] tag stays');
  assert.equal(G.normalizeQuery('two   spaces\n\nand lines'), 'two spaces and lines');
  assert.equal(G.normalizeQuery(null), '');
});

test('messageText reads strings and content-part arrays', () => {
  assert.equal(G.messageText('hi'), 'hi');
  assert.equal(G.messageText([{ type: 'text', text: 'a' }, { type: 'image_url' }, { type: 'text', text: 'b' }]), 'a\nb');
  assert.equal(G.messageText(null), '');
});

test('matchRecalls pairs user messages with recalls of the same query, nearest in time, each used once', () => {
  const recalls = [
    { id: 3, ts: 2005, query: 'hi' },
    { id: 2, ts: 1003, query: 'where is mom?' },
    { id: 1, ts: 1001, query: 'hi' },
  ];
  const users = [
    { key: 'u0', text: 'hi', ts: 1000 },
    { key: 'u1', text: '[Voice mode — keep answers short, no markdown, speak naturally please ok]\n\nwhere is mom?', ts: 1002 },
    { key: 'u2', text: 'hi', ts: 2000 },
    { key: 'u3', text: 'hi', ts: 3000 },
    { key: 'u4', text: 'nothing recalled', ts: 3100 },
  ];
  const m = G.matchRecalls(users, recalls);
  assert.equal(m.u0.id, 1);
  assert.equal(m.u1.id, 2);
  assert.equal(m.u2.id, 3);
  assert.equal(m.u3, undefined, 'no recall left for a repeat');
  assert.equal(m.u4, undefined);
});

test('matchRecalls without timestamps pairs in order', () => {
  const recalls = [{ id: 'b', ts: 20, query: 'x' }, { id: 'a', ts: 10, query: 'x' }];
  const m = G.matchRecalls([{ key: 1, text: 'x' }, { key: 2, text: 'x' }], recalls);
  assert.equal(m[1].id, 'a');
  assert.equal(m[2].id, 'b');
});

test('matchRecalls ignores a same-text recall far away in time', () => {
  const m = G.matchRecalls([{ key: 'u', text: 'hi', ts: 100000 }], [{ id: 1, ts: 10, query: 'hi' }]);
  assert.equal(m.u, undefined);
});

test('matchRecalls tolerates junk', () => {
  assert.deepEqual(G.matchRecalls(null, null), {});
  assert.deepEqual(G.matchRecalls([{ key: 'u', text: '' }], [{ id: 1, query: '' }]), {});
});

test('recallsUrl: per-session chip request and the Recent recalls list', () => {
  assert.equal(G.recallsUrl({ sessionId: 'a b', limit: 100 }), 'api/jarvis-memory/recalls?limit=100&session_id=a%20b');
  assert.equal(G.recallsUrl({ limit: 30 }), 'api/jarvis-memory/recalls?limit=30');
});

// ── review fixes ──

test('matchRecalls prefers the latest recall in the window (Regenerate re-ran the recall)', () => {
  const recalls = [
    { id: 'old', ts: 1001, query: 'where is mom?' },
    { id: 'regen', ts: 1500, query: 'where is mom?' },
  ];
  const m = G.matchRecalls([{ key: 'u', text: 'where is mom?', ts: 1000 }], recalls);
  assert.equal(m.u.id, 'regen');
});

test('matchRecalls latest-in-window still keeps each turn to its own window', () => {
  const recalls = [
    { id: 'a', ts: 1001, query: 'hi' }, { id: 'a2', ts: 1050, query: 'hi' },
    { id: 'b', ts: 2001, query: 'hi' },
  ];
  const m = G.matchRecalls([{ key: 0, text: 'hi', ts: 1000 }, { key: 1, text: 'hi', ts: 2000 }], recalls);
  assert.equal(m[0].id, 'a2');
  assert.equal(m[1].id, 'b');
});

test('matchRecalls without timestamps gives the last turns the latest recalls', () => {
  const recalls = [{ id: 'a', ts: 10, query: 'x' }, { id: 'b', ts: 20, query: 'x' }, { id: 'c', ts: 30, query: 'x' }];
  const m = G.matchRecalls([{ key: 1, text: 'x' }, { key: 2, text: 'x' }], recalls);
  assert.equal(m[1].id, 'b');
  assert.equal(m[2].id, 'c');
});

test('chatSignature changes with the message count and with the last assistant reply', () => {
  const base = [{ role: 'user', content: 'hi' }, { role: 'assistant', content: 'hello' }];
  const s0 = G.chatSignature(base);
  assert.equal(G.chatSignature(base.map(m => Object.assign({}, m))), s0, 'stable for equal chats');
  assert.notEqual(G.chatSignature(base.concat([{ role: 'user', content: 'x' }])), s0);
  const regen = [{ role: 'user', content: 'hi' }, { role: 'assistant', content: 'hey there' }];
  assert.notEqual(G.chatSignature(regen), s0, 'regenerated reply');
  const sameLen = [{ role: 'user', content: 'hi' }, { role: 'assistant', content: 'hellp' }];
  assert.notEqual(G.chatSignature(sameLen), s0, 'same length, different text');
  assert.equal(typeof G.chatSignature(null), 'string');
});

test('isStale: reload the base graph when it is older than two minutes', () => {
  assert.equal(G.isStale(0, 1000), true);
  assert.equal(G.isStale(1000, 1000 + 60e3), false);
  assert.equal(G.isStale(1000, 1000 + G.BASE_MAX_AGE_MS + 1), true);
  assert.equal(G.BASE_MAX_AGE_MS, 120000);
});

test('loadGraph keepPositions: nodes already on the map stay put, new ones still get a spot', () => {
  const g = G.createGraph();
  G.loadGraph(g, payload('me', [['a', 'person', 5], ['b', 'place', 2]], [['me', 'a', 5], ['me', 'b', 2]]));
  G.node(g, 'a').x = 321; G.node(g, 'a').y = -45;
  G.loadGraph(g, payload('me', [['a', 'person', 9], ['c', 'topic', 1]], [['me', 'a', 9], ['me', 'c', 1]]), { keepPositions: true });
  assert.equal(G.node(g, 'a').x, 321);
  assert.equal(G.node(g, 'a').y, -45);
  assert.equal(G.node(g, 'a').weight, 9);
  assert.ok(!G.node(g, 'b'));
  const c = G.node(g, 'c');
  assert.ok(Number.isFinite(c.x) && Math.hypot(c.x, c.y) > 20);
  // Without the option a load still lays everything out fresh.
  G.loadGraph(g, payload('me', [['a', 'person', 9]], [['me', 'a', 9]]));
  assert.notEqual(G.node(g, 'a').x, 321);
});

test('pointer filtering: only the primary mouse button drags; touch gets a bigger tap slop', () => {
  assert.equal(G.acceptsPointer({ pointerType: 'mouse', button: 0 }), true);
  assert.equal(G.acceptsPointer({ pointerType: 'mouse', button: 2 }), false);
  assert.equal(G.acceptsPointer({ pointerType: 'mouse', button: 1 }), false);
  assert.equal(G.acceptsPointer({ pointerType: 'touch', button: 0 }), true);
  assert.equal(G.acceptsPointer({ pointerType: 'pen', button: 0 }), true);
  assert.equal(G.tapSlop('touch'), 10);
  assert.equal(G.tapSlop('pen'), 10);
  assert.equal(G.tapSlop('mouse'), 4);
});

test('memoriesHeading: "50 of N" when the node weight says there are more', () => {
  assert.equal(G.memoriesHeading(50, 611), 'Memories (50 of 611)');
  assert.equal(G.memoriesHeading(3, 3), 'Memories (3)');
  assert.equal(G.memoriesHeading(3, 1), 'Memories (3)');
  assert.equal(G.memoriesHeading(3, null), 'Memories (3)');
  assert.equal(G.memoriesHeading(0, 0), 'Memories');
});

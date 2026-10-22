// Pure helpers for the Long-term Memory map (memory_map.js) and the
// "memories used" chat chip (jarvis_memory.js). No DOM, no fetch.
//
// A graph is {nodes: [{id,label,type,weight,pinned,aliases,event_start,x,y,vx,vy,fixed}],
// edges: [{a,b,weight}]}; "me" (You) is a virtual node fixed at the origin.
// Server contract: docs/superpowers/specs/2026-10-22-memory-graph-and-sources-design.md.
// UMD: window.MemoryGraph in the page, require() under `node --test`.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.MemoryGraph = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  const TYPES = ['person', 'place', 'event', 'topic', 'org'];
  const TYPE_LABELS = { person: 'People', place: 'Places', event: 'Events', topic: 'Topics', org: 'Orgs' };
  const TIME_RANGES = [
    { value: 'week', label: 'Week', seconds: 7 * 86400 },
    { value: 'month', label: 'Month', seconds: 30 * 86400 },
    { value: 'year', label: 'Year', seconds: 365 * 86400 },
    { value: 'all', label: 'All', seconds: 0 },
  ];
  const SOURCES = [
    { value: '', label: 'All' },
    { value: 'imessage', label: 'iMessage' },
    { value: 'live', label: 'Live' },
    { value: 'fact', label: 'Chats' },
    { value: 'calendar', label: 'Calendar' },
    { value: 'email', label: 'Email' },
    { value: 'health', label: 'Health' },
    { value: 'location', label: 'Location' },
    { value: 'cron', label: 'Integrations' },
    { value: 'dashcam', label: 'Dashcam' },
    { value: 'tool', label: 'Saved' },
  ];
  const COLORS = {
    person: '#5B8DEF', place: '#3FB27F', org: '#A97BE0', event: '#E8A33D', topic: '#E06C8B',
  };
  const FALLBACK_COLOR = '#8A8F98';

  const BASE_LIMIT = 40;
  const MAX_NODES = 150;
  const MIN_ZOOM = 0.2;
  const MAX_ZOOM = 5;
  const MAX_RADIUS = 34;
  const ME = 'me';
  const BASE_MAX_AGE_MS = 2 * 60 * 1000;   // the base graph is reloaded on show() after this

  // Physics (world units ≈ CSS px at zoom 1).
  const REPULSION = 2200;
  const SPRING = 0.02;
  const REST = 70;
  const CENTERING = 0.003;
  const DAMPING = 0.8;
  const MAX_SPEED = 40;
  const SETTLE_PER_NODE = 0.02;

  // ── URLs ──
  const enc = encodeURIComponent;

  function sinceFor(range, nowSec) {
    const r = TIME_RANGES.find(t => t.value === range);
    if (!r || !r.seconds) return null;
    return Math.floor(nowSec - r.seconds);
  }

  function filterParams(f, nowSec) {
    let s = '';
    const types = (f.types || []).filter(t => TYPES.includes(t));
    if (types.length && types.length < TYPES.length) s += '&types=' + enc(types.join(','));
    const since = sinceFor(f.time, nowSec);
    if (since != null) s += '&since=' + since;
    if (f.source) s += '&source=' + enc(f.source);
    return s;
  }

  function graphUrl(f, nowSec) {
    f = f || {};
    return 'api/jarvis-memory/graph?center=' + enc(f.center || ME) +
      '&limit=' + (f.limit || BASE_LIMIT) + filterParams(f, nowSec);
  }

  function recallsUrl(o) {
    o = o || {};
    let s = 'api/jarvis-memory/recalls?limit=' + (o.limit || 30);
    if (o.sessionId) s += '&session_id=' + enc(o.sessionId);
    return s;
  }

  // ── graph state ──
  function createGraph() { return { nodes: [], edges: [] }; }

  function node(g, id) {
    for (const n of g.nodes) if (n.id === id) return n;
    return null;
  }

  function edgeKey(a, b) { return a < b ? a + '\u0000' + b : b + '\u0000' + a; }

  function meNode() {
    return { id: ME, label: 'You', type: 'me', weight: 0, pinned: false, aliases: [], event_start: null,
      x: 0, y: 0, vx: 0, vy: 0, fixed: true };
  }

  function makeNode(raw, x, y) {
    return {
      id: String(raw.id), label: raw.label != null ? String(raw.label) : String(raw.id),
      type: raw.type || 'topic', weight: Number(raw.weight) || 0, pinned: !!raw.pinned,
      aliases: Array.isArray(raw.aliases) ? raw.aliases.slice() : [],
      event_start: raw.event_start != null ? raw.event_start : null,
      x, y, vx: 0, vy: 0, fixed: false,
    };
  }

  const GOLDEN = Math.PI * (3 - Math.sqrt(5));

  function ringPos(cx, cy, i, base, step) {
    const r = base + step * Math.sqrt(i + 1);
    const a = i * GOLDEN;
    return [cx + r * Math.cos(a), cy + r * Math.sin(a)];
  }

  function addEdge(g, idx, a, b, w) {
    a = String(a); b = String(b);
    if (a === b) return;
    const k = edgeKey(a, b);
    const e = idx.get(k);
    w = Number(w) || 0;
    if (e) { e.weight = Math.max(e.weight, w); return; }
    const ne = { a, b, weight: w };
    idx.set(k, ne);
    g.edges.push(ne);
  }

  function edgeIndex(g) {
    const m = new Map();
    for (const e of g.edges) m.set(edgeKey(e.a, e.b), e);
    return m;
  }

  function pruneEdges(g) {
    const ids = new Set(g.nodes.map(n => n.id));
    g.edges = g.edges.filter(e => ids.has(e.a) && ids.has(e.b) && e.a !== e.b);
  }

  // Fresh "You at the center" load (also the highlight payload).
  // opts.keepPositions: nodes already on the map keep their place (a refresh).
  function loadGraph(g, payload, opts) {
    const old = new Map();
    if (opts && opts.keepPositions) for (const n of g.nodes) old.set(n.id, n);
    g.nodes = [meNode()];
    g.edges = [];
    const nodes = (payload && payload.nodes) || [];
    const center = payload && payload.center;
    if (center && center.id && center.id !== ME) {
      g.nodes.push(makeNode(center, 0, 0));
    }
    nodes.forEach((raw, i) => {
      if (!raw || raw.id == null || raw.id === ME || node(g, String(raw.id))) return;
      const prev = old.get(String(raw.id));
      const [x, y] = prev ? [prev.x, prev.y] : ringPos(0, 0, i, 90, 24);
      g.nodes.push(makeNode(raw, x, y));
    });
    const idx = new Map();
    for (const e of (payload && payload.edges) || []) {
      if (e) addEdge(g, idx, e.a, e.b, e.weight);
    }
    pruneEdges(g);
    return g;
  }

  // Expand in place: existing nodes keep their positions; new ones are
  // placed around the anchor. Returns the ids that were added.
  function mergeGraph(g, payload, opts) {
    opts = opts || {};
    if (!g.nodes.length) g.nodes.push(meNode());
    const center = payload && payload.center;
    const anchorId = String(opts.anchor || (center && center.id) || ME);
    const added = [];
    if (center && center.id && center.id !== ME && !node(g, String(center.id))) {
      const [x, y] = ringPos(0, 0, g.nodes.length, 90, 24);
      g.nodes.push(makeNode(center, x, y));
      added.push(String(center.id));
    }
    const anchor = node(g, anchorId) || node(g, ME);
    let i = 0;
    for (const raw of (payload && payload.nodes) || []) {
      if (!raw || raw.id == null || raw.id === ME) continue;
      const id = String(raw.id);
      const have = node(g, id);
      if (have) {
        have.weight = Math.max(have.weight, Number(raw.weight) || 0);
        if (raw.label != null) have.label = String(raw.label);
        if (raw.pinned != null) have.pinned = !!raw.pinned;
        if (Array.isArray(raw.aliases)) have.aliases = raw.aliases.slice();
        continue;
      }
      const [x, y] = ringPos(anchor.x, anchor.y, i++, 45, 14);
      g.nodes.push(makeNode(raw, x, y));
      added.push(id);
    }
    const idx = edgeIndex(g);
    for (const e of (payload && payload.edges) || []) {
      if (e) addEdge(g, idx, e.a, e.b, e.weight);
    }
    pruneEdges(g);
    const protect = (opts.protect || []).concat([anchorId], added);
    capGraph(g, opts.cap || MAX_NODES, protect);
    return added.filter(id => node(g, id));
  }

  // Keep at most `cap` nodes: evict the lightest ones that are not You,
  // pinned or protected. Returns the evicted ids.
  function capGraph(g, cap, protectIds) {
    const over = g.nodes.length - cap;
    if (over <= 0) return [];
    const keep = new Set((protectIds || []).map(String));
    keep.add(ME);
    const victims = g.nodes
      .filter(n => !keep.has(n.id) && !n.pinned)
      .sort((a, b) => a.weight - b.weight)
      .slice(0, over)
      .map(n => n.id);
    const gone = new Set(victims);
    g.nodes = g.nodes.filter(n => !gone.has(n.id));
    pruneEdges(g);
    return victims;
  }

  function removeNode(g, id) {
    if (id === ME || !node(g, id)) return false;
    g.nodes = g.nodes.filter(n => n.id !== id);
    pruneEdges(g);
    return true;
  }

  // After a server merge (or a rename that merged): fold `fromId` into `intoId`.
  function mergeNodes(g, fromId, intoId, entity) {
    const from = node(g, fromId);
    let into = node(g, intoId);
    if (!into && from) {
      // The survivor isn't on the canvas yet: the merged node becomes it.
      from.id = String(intoId);
      into = from;
    } else if (from && into && from !== into) {
      into.weight += from.weight;
      into.pinned = into.pinned || from.pinned;
      g.nodes = g.nodes.filter(n => n !== from);
    }
    if (into && entity) {
      if (entity.label != null) into.label = String(entity.label);
      if (Array.isArray(entity.aliases)) into.aliases = entity.aliases.slice();
      if (entity.pinned != null) into.pinned = !!entity.pinned;
    }
    const merged = new Map();
    for (const e of g.edges) {
      const a = e.a === fromId ? String(intoId) : e.a;
      const b = e.b === fromId ? String(intoId) : e.b;
      if (a === b) continue;
      const k = edgeKey(a, b);
      const have = merged.get(k);
      if (have) have.weight += e.weight;
      else merged.set(k, { a, b, weight: e.weight });
    }
    g.edges = Array.from(merged.values());
    pruneEdges(g);
    return into;
  }

  function mergeCandidates(g, id, q) {
    const self = node(g, id);
    if (!self) return [];
    const needle = String(q || '').trim().toLowerCase();
    return g.nodes
      .filter(n => n.id !== id && n.type === self.type)
      .filter(n => !needle || [n.label].concat(n.aliases || []).some(s => String(s).toLowerCase().includes(needle)))
      .sort((a, b) => a.label.localeCompare(b.label));
  }

  // ── physics ──
  function radiusFor(n) {
    const base = n.type === 'me' ? 16 : 5;
    return Math.min(MAX_RADIUS, base + 1.6 * Math.sqrt(Math.max(0, Number(n.weight) || 0)));
  }

  // One tick of the force simulation. Returns the kinetic energy.
  function step(g) {
    const ns = g.nodes;
    const n = ns.length;
    const fx = new Float64Array(n);
    const fy = new Float64Array(n);
    const pos = new Map();
    ns.forEach((nd, i) => pos.set(nd.id, i));
    for (let i = 0; i < n; i++) {
      const a = ns[i];
      for (let j = i + 1; j < n; j++) {
        const b = ns[j];
        let dx = a.x - b.x;
        let dy = a.y - b.y;
        let d2 = dx * dx + dy * dy;
        if (d2 < 1e-6) {
          // Coincident: push apart along a deterministic direction.
          const ang = (i * 7 + j * 13) * GOLDEN;
          dx = Math.cos(ang); dy = Math.sin(ang); d2 = 1;
        }
        const d = Math.sqrt(d2);
        const f = REPULSION / Math.max(d2, 36);
        const ux = dx / d, uy = dy / d;
        fx[i] += ux * f; fy[i] += uy * f;
        fx[j] -= ux * f; fy[j] -= uy * f;
      }
    }
    for (const e of g.edges) {
      const i = pos.get(e.a), j = pos.get(e.b);
      if (i == null || j == null) continue;
      const a = ns[i], b = ns[j];
      const dx = b.x - a.x, dy = b.y - a.y;
      const d = Math.sqrt(dx * dx + dy * dy) || 1;
      const rest = REST + radiusFor(a) + radiusFor(b);
      const k = SPRING * (1 + Math.log1p(Math.max(0, e.weight)) / 6);
      const f = k * (d - rest);
      const ux = dx / d, uy = dy / d;
      fx[i] += ux * f; fy[i] += uy * f;
      fx[j] -= ux * f; fy[j] -= uy * f;
    }
    let energy = 0;
    for (let i = 0; i < n; i++) {
      const nd = ns[i];
      if (nd.fixed || nd.id === ME) {
        nd.vx = 0; nd.vy = 0;
        if (nd.id === ME) { nd.x = 0; nd.y = 0; }
        continue;
      }
      fx[i] -= CENTERING * nd.x;
      fy[i] -= CENTERING * nd.y;
      nd.vx = (nd.vx + fx[i]) * DAMPING;
      nd.vy = (nd.vy + fy[i]) * DAMPING;
      const sp = Math.hypot(nd.vx, nd.vy);
      if (sp > MAX_SPEED) { nd.vx *= MAX_SPEED / sp; nd.vy *= MAX_SPEED / sp; }
      nd.x += nd.vx;
      nd.y += nd.vy;
      energy += nd.vx * nd.vx + nd.vy * nd.vy;
    }
    return energy;
  }

  function isSettled(energy, count) {
    if (!count) return true;
    return energy / count < SETTLE_PER_NODE;
  }

  // ── look ──
  function colorFor(type, accent) {
    if (type === 'me') return accent || '#B8860B';
    return COLORS[type] || FALLBACK_COLOR;
  }

  function showLabel(n, k, ctx) {
    ctx = ctx || {};
    if (n.type === 'me' || n.id === ME) return true;
    if (ctx.selected === n.id || ctx.hover === n.id) return true;
    if (ctx.highlight && ctx.highlight.size && ctx.highlight.has(n.id)) return true;
    if (k >= 2) return true;
    return radiusFor(n) * k >= 14;
  }

  function isDimmed(id, highlight) {
    if (!highlight || !highlight.size) return false;
    return id !== ME && !highlight.has(id);
  }

  // ── view transform: screen = world * k + (x, y) ──
  function toWorld(v, sx, sy) { return { x: (sx - v.x) / v.k, y: (sy - v.y) / v.k }; }
  function toScreen(v, wx, wy) { return { x: wx * v.k + v.x, y: wy * v.k + v.y }; }

  function zoomAt(v, factor, sx, sy) {
    const w = toWorld(v, sx, sy);
    const k = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, v.k * factor));
    return { x: sx - w.x * k, y: sy - w.y * k, k };
  }

  function hitTest(g, v, sx, sy) {
    const w = toWorld(v, sx, sy);
    const slop = 4 / v.k;
    for (let i = g.nodes.length - 1; i >= 0; i--) {
      const n = g.nodes[i];
      const r = radiusFor(n) + slop;
      if ((n.x - w.x) * (n.x - w.x) + (n.y - w.y) * (n.y - w.y) <= r * r) return n;
    }
    return null;
  }

  // ── chat chip: which recall belongs to which user message ──
  const INJECTED = /^\s*\[[\s\S]{40,}?\]\s*\n\s*\n/;
  const WORKSPACE_V1 = /^\s*\[Workspace::v1:\s*(?:\\.|[^\]\\])+\]\s*/;
  const WORKSPACE = /^\s*\[Workspace:[^\]]+\]\s*/;

  function normalizeQuery(text) {
    let s = String(text == null ? '' : text);
    for (let guard = 0; guard < 20; guard++) {
      const before = s;
      s = s.replace(WORKSPACE_V1, '').replace(WORKSPACE, '');
      const m = INJECTED.exec(s);
      if (m) s = s.slice(m[0].length);
      if (s === before) break;
    }
    return s.replace(/\s+/g, ' ').trim();
  }

  function messageText(content) {
    if (content == null) return '';
    if (typeof content === 'string') return content;
    if (Array.isArray(content)) {
      return content
        .map(p => (typeof p === 'string' ? p : (p && p.type === 'text' && typeof p.text === 'string' ? p.text : null)))
        .filter(p => p != null)
        .join('\n');
    }
    if (typeof content === 'object' && typeof content.text === 'string') return content.text;
    return '';
  }

  const SKEW = 120;          // client/server clock skew allowance (s)
  const MAX_GAP = 3600;      // a recall runs right after the message it answers

  // users: [{key, text, ts?}] in chat order; recalls: [{id, ts, query, ...}].
  // Returns {key: recall}. Each recall is used once; with timestamps, a recall
  // must fall between its message and the next user message.
  function matchRecalls(users, recalls) {
    const out = {};
    if (!Array.isArray(users) || !Array.isArray(recalls)) return out;
    const byQuery = new Map();
    for (const r of recalls) {
      if (!r) continue;
      const q = normalizeQuery(r.query);
      if (!q) continue;
      if (!byQuery.has(q)) byQuery.set(q, []);
      byQuery.get(q).push(r);
    }
    for (const list of byQuery.values()) list.sort((a, b) => (Number(a.ts) || 0) - (Number(b.ts) || 0));
    const used = new Set();
    // For each user turn: how many LATER turns ask the same thing.
    const laterSame = new Map();
    const seen = new Map();
    for (let i = users.length - 1; i >= 0; i--) {
      const q = users[i] ? normalizeQuery(users[i].text) : '';
      if (!q) continue;
      laterSame.set(i, seen.get(q) || 0);
      seen.set(q, (seen.get(q) || 0) + 1);
    }
    users.forEach((u, i) => {
      if (!u) return;
      const q = normalizeQuery(u.text);
      const list = q && byQuery.get(q);
      if (!list) return;
      const uts = Number(u.ts);
      let pick = null;
      if (Number.isFinite(uts) && uts > 0) {
        let hi = uts + MAX_GAP;
        for (let j = i + 1; j < users.length; j++) {
          const nts = users[j] && Number(users[j].ts);
          if (Number.isFinite(nts) && nts > 0) { hi = Math.min(hi, Math.max(nts, uts)); break; }
        }
        // The latest recall in this turn's window: a Regenerate re-runs the
        // recall for the same question, and the newest one fed the reply shown.
        let best = -Infinity;
        for (const r of list) {
          if (used.has(r)) continue;
          const rts = Number(r.ts);
          if (!Number.isFinite(rts)) continue;
          if (rts < uts - SKEW || rts > hi) continue;
          if (rts > best) { best = rts; pick = r; }
        }
      } else {
        // No clock: align from the end — the last turns asking this got the
        // latest recalls.
        const later = laterSame.get(i) || 0;
        const free = list.filter(r => !used.has(r));
        pick = free.length > later ? free[free.length - 1 - later] : null;
      }
      if (pick) { used.add(pick); out[u.key] = pick; }
    });
    return out;
  }

  // A cheap fingerprint of a chat: message count + the last assistant reply
  // (so a Regenerate, which keeps the count, still refreshes the chip).
  function chatSignature(messages) {
    if (!Array.isArray(messages)) return '0';
    let last = '';
    let lastIdx = -1;
    for (let i = messages.length - 1; i >= 0; i--) {
      const m = messages[i];
      if (m && m.role === 'assistant') { last = messageText(m.content); lastIdx = i; break; }
    }
    let h = 2166136261;
    for (let i = 0; i < last.length; i++) { h ^= last.charCodeAt(i); h = Math.imul(h, 16777619); }
    return messages.length + ':' + lastIdx + ':' + last.length + ':' + (h >>> 0).toString(36);
  }

  function isStale(loadedAtMs, nowMs) {
    return !loadedAtMs || nowMs - loadedAtMs > BASE_MAX_AGE_MS;
  }

  // Mouse drags only with the primary button; touch / pen always.
  function acceptsPointer(e) {
    if (!e) return false;
    if (e.pointerType === 'mouse' || !e.pointerType) return e.button === 0;
    return true;
  }

  // How far a pointer may move before a tap becomes a drag (CSS px).
  function tapSlop(pointerType) {
    return pointerType === 'touch' || pointerType === 'pen' ? 10 : 4;
  }

  function memoriesHeading(shown, weight) {
    shown = Number(shown) || 0;
    const w = Number(weight) || 0;
    if (!shown && !w) return 'Memories';
    if (w > shown) return 'Memories (' + shown + ' of ' + w + ')';
    return 'Memories (' + shown + ')';
  }

  return {
    BASE_MAX_AGE_MS, chatSignature, isStale, acceptsPointer, tapSlop, memoriesHeading,
    TYPES, TYPE_LABELS, TIME_RANGES, SOURCES, COLORS, BASE_LIMIT, MAX_NODES, MIN_ZOOM, MAX_ZOOM, MAX_RADIUS, ME,
    sinceFor, graphUrl, recallsUrl,
    createGraph, node, edgeKey, loadGraph, mergeGraph, capGraph, removeNode, mergeNodes, mergeCandidates,
    radiusFor, step, isSettled, colorFor, showLabel, isDimmed,
    toWorld, toScreen, zoomAt, hitTest,
    normalizeQuery, messageText, matchRecalls,
  };
});

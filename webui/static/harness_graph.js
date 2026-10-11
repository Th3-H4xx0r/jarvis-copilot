// Pure edits on a harness document {id, name, icon, nodes:[…], edges:[…]}
// for the canvas editor (harness_editor.js). No DOM. The server is the only
// validator (api/harness_schema.py); these helpers just keep an edit sane and
// produce the design the editor posts.
// UMD: window.HarnessGraph in the page, require() under `node --test`.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.HarnessGraph = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  const DEFAULTS = {
    answer: { tools: 'lean', model: '' },
    route: { by: 'rules', rules: [], labels: [] },
    background: { tools: 'all', model: '', deliver: 'speak_or_notify' },
    review: { model: '', deliver: 'post_if_changed' },
    message: {},
  };
  const SERVER_ONLY = ['builtin', 'version', 'problems', 'updated_at'];
  const clone = o => JSON.parse(JSON.stringify(o));
  const nodeById = (doc, id) => doc.nodes.find(n => n.id === id) || null;

  function defaultsFor(type) { return clone(DEFAULTS[type] || {}); }

  function newHarness(id, name) {
    return { id, name, icon: '', nodes: [{ id: 'in', type: 'message', x: 40, y: 40 }], edges: [] };
  }

  function addNode(doc, type, x, y) {
    let n = 1;
    while (doc.nodes.some(nd => nd.id === `${type}-${n}`)) n++;
    const id = `${type}-${n}`;
    doc.nodes.push(Object.assign({ id, type, x: Math.round(x), y: Math.round(y) }, defaultsFor(type)));
    return id;
  }

  function removeNode(doc, id) {
    const node = nodeById(doc, id);
    if (!node || node.type === 'message') return false;
    doc.nodes = doc.nodes.filter(n => n.id !== id);
    doc.edges = doc.edges.filter(e => e.from !== id && e.to !== id);
    return true;
  }

  function connect(doc, from, to, when) {
    if (from === to) return false;
    if (!nodeById(doc, from) || !nodeById(doc, to)) return false;
    if (doc.edges.some(e => e.from === from && e.to === to)) return false;
    doc.edges.push({ from, to, when: when || 'always' });
    return true;
  }

  function disconnect(doc, index) { doc.edges.splice(index, 1); }

  function moveNode(doc, id, x, y) {
    const n = nodeById(doc, id);
    if (n) { n.x = Math.round(x); n.y = Math.round(y); }
  }

  function duplicate(doc, id, name) {
    const c = clone(doc);
    SERVER_ONLY.forEach(k => { delete c[k]; });
    c.id = id; c.name = name;
    return c;
  }

  // The condition a freshly drawn wire gets. A Route's first wire is its
  // default, later ones take the next label nobody uses yet (a new label is
  // made and remembered on the node when they are all taken).
  function nextWhen(doc, from, to) {
    const src = nodeById(doc, from);
    if (!src) return 'always';
    if (src.type === 'route') {
      const out = doc.edges.filter(e => e.from === from).map(e => e.when || 'always');
      if (!out.includes('default')) return 'default';
      return `label:${freeLabel(doc, from)}`;
    }
    const dst = to ? nodeById(doc, to) : null;
    if (src.type === 'answer' && dst && dst.type === 'background') return 'handoff';
    return 'always';
  }

  // Short text drawn on a wire; '' for the plain "always" wire.
  function edgeLabel(when) {
    const w = String(when || 'always');
    if (w === 'always') return '';
    if (w === 'handoff') return 'hand-off';
    if (w === 'default') return 'default';
    const i = w.indexOf(':');
    const kind = i < 0 ? w : w.slice(0, i);
    const value = i < 0 ? '' : w.slice(i + 1);
    if (kind === 'label') return value;
    if (kind === 'slow') return `slower than ${value} s`;
    if (kind === 'tools') return `${value}+ tools`;
    return w;
  }

  // What the editor posts: the graph, never the fields the server owns.
  function toDesign(doc) {
    const out = clone(doc);
    SERVER_ONLY.forEach(k => { delete out[k]; });
    Object.keys(out).forEach(k => { if (!['id', 'name', 'icon', 'nodes', 'edges'].includes(k)) delete out[k]; });
    if (!('icon' in out)) out.icon = '';
    return out;
  }

  // Server problems ({node, edge, message}) for one node ({node: id}), one
  // wire ({edge: index}) or the harness as a whole ({}).
  function problemsFor(doc, where) {
    const list = (doc && doc.problems) || [];
    return list.filter(p => {
      if (where && where.node != null) return p.node === where.node;
      if (where && where.edge != null) return p.edge === where.edge;
      return p.node == null && p.edge == null;
    }).map(p => String(p.message || ''));
  }

  function slug(name) {
    const s = String(name || '').toLowerCase().replace(/[^a-z0-9_-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 48);
    return s || 'harness';
  }

  function uniqueId(base, taken) {
    const set = new Set(taken || []);
    if (!set.has(base)) return base;
    let n = 2;
    while (set.has(`${base}-${n}`)) n++;
    return `${base}-${n}`;
  }

  // api/models groups -> [{label, options:[{value: '@provider:model', label}]}].
  function modelOptions(groups) {
    return (Array.isArray(groups) ? groups : []).map(g => {
      const pid = String(g.provider_id || g.provider || '').trim();
      const options = (Array.isArray(g.models) ? g.models : []).filter(m => m && m.id).map(m => {
        const id = String(m.id);
        return { value: id.startsWith('@') ? id : `@${pid}:${id}`, label: String(m.label || id) };
      });
      return { label: String(g.provider || pid || 'Models'), options };
    }).filter(g => g.options.length);
  }

  // ── Route labels ──────────────────────────────────────────────────────────
  const own = (o, k) => !!o && Object.prototype.hasOwnProperty.call(o, k);

  // What a label means ('' when unset; never an inherited key like "constructor").
  function labelNote(node, label) {
    const notes = node && node.label_descriptions;
    return own(notes, label) ? String(notes[label] || '') : '';
  }

  // Every name a Route already uses: its labels, its rules' labels, its wires.
  function takenLabels(doc, node) {
    const wired = doc.edges.filter(e => e.from === node.id && String(e.when || '').startsWith('label:'))
      .map(e => e.when.slice(6));
    return new Set([...(node.labels || []), ...(node.rules || []).map(r => r.label), ...wired]);
  }

  const wireLabel = e => (String(e.when || '').startsWith('label:') ? e.when.slice(6) : null);

  // The names a Route's wire can be picked by: its labels, plus its rules'
  // labels when rules pick (a model router only ever picks from `labels`).
  function pickable(node) {
    const labels = node.labels || [];
    return node.by === 'model' ? labels.slice() : [...labels, ...(node.rules || []).map(r => r.label)];
  }

  // old -> v everywhere on this Route: the label, its description, its rules, its wires.
  function carry(doc, node, old, v) {
    const i = (node.labels || []).indexOf(old);
    if (i >= 0) node.labels[i] = v;
    if (own(node.label_descriptions, old)) {
      node.label_descriptions[v] = node.label_descriptions[old];
      delete node.label_descriptions[old];
    }
    (node.rules || []).forEach(r => { if (r.label === old) r.label = v; });
    doc.edges.forEach(e => { if (e.from === node.id && e.when === `label:${old}`) e.when = `label:${v}`; });
  }

  // Rename a Route's label, carrying its description, its rules and this
  // Route's `label:` wires. A blank name, or one another label or rule has, is
  // refused (false). A name only a stray wire carries (its label is on no list,
  // so nothing could pick it) is fine when this label has no wire of its own:
  // the label adopts that wire.
  function renameLabel(doc, id, old, name) {
    const node = nodeById(doc, id);
    const labels = (node && node.labels) || [];
    const v = String(name || '').trim();
    if (labels.indexOf(old) < 0) return false;
    if (v === old) return true;
    if (!v || labels.includes(v) || (node.rules || []).some(r => r.label === v)) return false;
    const wired = doc.edges.filter(e => e.from === id).map(wireLabel);
    if (wired.includes(v) && wired.includes(old)) return false;
    carry(doc, node, old, v);
    return true;
  }

  // Retype a Route wire's label without the Route's labels and wires drifting
  // apart: a free name renames the label the wire had (description, rules and
  // all), a label no other wire has just takes the wire, and a stray wire's new
  // name joins the labels. Blank, or a name another wire has, is refused (false).
  function relabelWire(doc, index, name) {
    const e = doc.edges[index];
    const node = e && nodeById(doc, e.from);
    const old = e && wireLabel(e);
    if (!node || node.type !== 'route' || old == null) return false;
    const v = String(name || '').trim();
    if (!v) return false;
    if (v === old) return true;
    node.labels = Array.isArray(node.labels) ? node.labels : [];
    const others = doc.edges.filter((x, j) => j !== index && x.from === node.id).map(wireLabel);
    const free = !takenLabels(doc, node).has(v);
    if (free && pickable(node).includes(old) && !others.includes(old)) { carry(doc, node, old, v); return true; }
    if (others.includes(v)) return false;
    if (pickable(node).includes(v)) { e.when = `label:${v}`; return true; }
    if (!free) return false;
    node.labels.push(v);
    e.when = `label:${v}`;
    return true;
  }

  // A label of this Route no wire has yet; when every label has one, the next
  // free `path-N`, remembered on the node so a model router can pick it.
  function freeLabel(doc, id) {
    const node = nodeById(doc, id);
    if (!node) return null;
    node.labels = Array.isArray(node.labels) ? node.labels : [];
    const used = new Set(doc.edges.filter(e => e.from === id).map(wireLabel).filter(l => l != null));
    let label = node.labels.find(l => !used.has(l));
    if (!label) {
      let n = node.labels.length + 1;
      while (node.labels.includes(`path-${n}`) || used.has(`path-${n}`)) n++;
      label = `path-${n}`;
      node.labels.push(label);
    }
    return label;
  }

  // Add the next free `path-N` label (the name a new wire's label gets too).
  function addLabel(doc, id) {
    const node = nodeById(doc, id);
    if (!node) return null;
    node.labels = node.labels || [];
    const taken = takenLabels(doc, node);
    let k = node.labels.length + 1;
    while (taken.has(`path-${k}`)) k++;
    node.labels.push(`path-${k}`);
    return `path-${k}`;
  }

  function removeLabel(doc, id, index) {
    const node = nodeById(doc, id);
    if (!node || !node.labels) return;
    const [gone] = node.labels.splice(index, 1);
    if (own(node.label_descriptions, gone)) delete node.label_descriptions[gone];
    if (node.label_descriptions && !Object.keys(node.label_descriptions).length) delete node.label_descriptions;
    // Its wires go too: left behind, the router could never pick them.
    if (!node.labels.includes(gone)) doc.edges = doc.edges.filter(e => !(e.from === id && e.when === `label:${gone}`));
  }

  // Set what a label means; blank text clears it (an empty map is dropped).
  function describeLabel(doc, id, label, text) {
    const node = nodeById(doc, id);
    if (!node) return;
    const notes = Object.assign({}, node.label_descriptions || {});
    if (String(text || '').trim()) notes[label] = text; else delete notes[label];
    if (Object.keys(notes).length) node.label_descriptions = notes; else delete node.label_descriptions;
  }

  // api/models decision_models -> one "Decision models" group for a Route's router picker.
  function decisionOptions(list) {
    const options = (Array.isArray(list) ? list : []).filter(m => m && m.id).map(m => ({
      value: String(m.id), label: `${m.label || m.id}${m.provider ? ' · ' + m.provider : ''}`,
    }));
    return options.length ? [{ label: 'Decision models', options }] : [];
  }

  return {
    newHarness, addNode, removeNode, connect, disconnect, moveNode, duplicate, defaultsFor,
    nextWhen, edgeLabel, toDesign, problemsFor, slug, uniqueId, modelOptions, decisionOptions,
    labelNote, renameLabel, relabelWire, freeLabel, addLabel, removeLabel, describeLabel,
  };
});

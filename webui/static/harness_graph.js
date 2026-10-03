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
      src.labels = Array.isArray(src.labels) ? src.labels : [];
      const used = new Set(out.filter(w => w.startsWith('label:')).map(w => w.slice(6)));
      let label = src.labels.find(l => !used.has(l));
      if (!label) {
        let n = src.labels.length + 1;
        while (src.labels.includes(`path-${n}`) || used.has(`path-${n}`)) n++;
        label = `path-${n}`;
        src.labels.push(label);
      }
      return `label:${label}`;
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

  return {
    newHarness, addNode, removeNode, connect, disconnect, moveNode, duplicate, defaultsFor,
    nextWhen, edgeLabel, toDesign, problemsFor, slug, uniqueId, modelOptions,
  };
});

// Harnesses panel (#mainHarnesses): the list of harnesses with the Voice/Chat
// defaults, and an SVG canvas editor for one harness. Reached from Settings →
// Harnesses and from the harness chip's "Edit harnesses…".
//
// The canvas: drag a node to move it, drag a node's right dot onto another
// node to wire them, drag empty space to pan, scroll (or −/+) to zoom. The
// side panel edits the selected node or wire. Graph edits go through
// HarnessGraph (pure, tested); the server validates on save and its problems
// are drawn on the nodes and wires they name.
(function () {
  const NODE_W = 160, NODE_H = 58;
  const TYPES = { message: 'Message', answer: 'Answer', route: 'Route', background: 'Background', review: 'Review' };
  const E = {
    harnesses: [], assignments: { voice: 'fast-claude', chat: 'single' }, models: null,
    view: 'list', doc: null, readOnly: false, dirty: false, isNew: false,
    sel: null, tx: 40, ty: 40, k: 1, gesture: null, saving: false,
  };

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }
  const $id = id => document.getElementById(id);
  const toast = (msg, kind) => { if (typeof showToast === 'function') showToast(msg, 3500, kind); };
  const shortModel = ref => (window.HarnessFormat ? HarnessFormat.shortModel(ref) : String(ref || ''));
  const clip = (s, n) => { s = String(s || ''); return s.length > n ? s.slice(0, n - 1) + '…' : s; };
  const nodeById = id => (E.doc ? E.doc.nodes.find(n => n.id === id) : null);

  // ── Data ────────────────────────────────────────────────────────────────
  async function fetchData() {
    try {
      const data = await api('api/harnesses');
      if (data && Array.isArray(data.harnesses)) {
        E.harnesses = data.harnesses;
        E.assignments = Object.assign({ voice: 'fast-claude', chat: 'single' }, data.assignments || {});
      }
    } catch (e) { console.warn('[harness-editor] load failed', e); }
  }

  async function fetchModels() {
    if (E.models) return;
    try {
      const data = await api('api/models');
      E.models = HarnessGraph.modelOptions(data && data.groups);
    } catch (e) { console.warn('[harness-editor] models failed', e); E.models = []; }
  }

  function refreshChip() { if (window.Harness) window.Harness.load(); }

  // ── Entry points ────────────────────────────────────────────────────────
  // Settings → Harnesses and the chip's "Edit harnesses…".
  async function open(id) {
    if (typeof switchPanel === 'function') await switchPanel('harnesses');
    if (typeof closeMobileSidebar === 'function') closeMobileSidebar();
    if (id) editHarness(id);
  }

  // switchPanel('harnesses') lazy-loads this: refresh, then draw the current view.
  async function load() {
    document.querySelectorAll('#settingsMenu .side-menu-item').forEach(it =>
      it.classList.toggle('active', it.id === 'settingsMenuHarnesses'));
    await fetchData();
    if (E.view === 'edit' && E.doc) renderEditor(); else renderList();
  }

  // ── List view ───────────────────────────────────────────────────────────
  function miniSvg(h) {
    const nodes = h.nodes || [];
    if (!nodes.length) return '';
    const xs = nodes.map(n => Number(n.x) || 0), ys = nodes.map(n => Number(n.y) || 0);
    const minX = Math.min(...xs), minY = Math.min(...ys);
    const w = Math.max(...xs) - minX + NODE_W, hgt = Math.max(...ys) - minY + NODE_H;
    const pos = {};
    nodes.forEach(n => { pos[n.id] = { x: (Number(n.x) || 0) - minX, y: (Number(n.y) || 0) - minY, type: n.type }; });
    const lines = (h.edges || []).filter(e => pos[e.from] && pos[e.to]).map(e => {
      const a = pos[e.from], b = pos[e.to];
      return `<line x1="${a.x + NODE_W}" y1="${a.y + NODE_H / 2}" x2="${b.x}" y2="${b.y + NODE_H / 2}"${e.when === 'handoff' ? ' class="dash"' : ''}/>`;
    }).join('');
    const boxes = nodes.map(n => {
      const p = pos[n.id];
      return `<rect class="t-${esc(n.type)}" x="${p.x}" y="${p.y}" width="${NODE_W}" height="${NODE_H}" rx="14"/>`;
    }).join('');
    return `<svg class="harness-card-mini" viewBox="-20 -20 ${w + 40} ${hgt + 40}" preserveAspectRatio="xMidYMid meet" aria-hidden="true">${lines}${boxes}</svg>`;
  }

  function assignSelect(surface) {
    const cur = E.assignments[surface];
    return `<select data-assign="${surface}">` + E.harnesses.map(h =>
      `<option value="${esc(h.id)}"${h.id === cur ? ' selected' : ''}>${esc(((h.icon || '') + ' ' + (h.name || h.id)).trim())}</option>`).join('') + '</select>';
  }

  function renderList() {
    E.view = 'list';
    $id('harnessViewTitle').textContent = 'Harnesses';
    $id('harnessViewActions').innerHTML = '<button type="button" class="harness-btn accent" data-act="new">+ New harness</button>';
    const body = $id('harnessViewBody');
    body.classList.remove('harness-body--edit');
    const cards = E.harnesses.map(h => {
      const badges = [];
      if (h.builtin) badges.push('<span class="harness-badge">Built-in</span>');
      if (E.assignments.voice === h.id) badges.push('<span class="harness-badge on">Voice default</span>');
      if (E.assignments.chat === h.id) badges.push('<span class="harness-badge on">Chat default</span>');
      const probs = (h.problems || []).length;
      if (probs) badges.push(`<span class="harness-badge warn" title="${esc((h.problems[0] || {}).message || '')}">${probs} problem${probs > 1 ? 's' : ''}</span>`);
      return `<div class="harness-card" data-id="${esc(h.id)}">
          <div class="harness-card-head"><span class="harness-card-icon" aria-hidden="true">${esc(h.icon || '●')}</span>
            <span class="harness-card-name">${esc(h.name || h.id)}</span></div>
          <div class="harness-card-badges">${badges.join('')}</div>
          ${miniSvg(h)}
          <div class="harness-card-actions">
            <button type="button" class="harness-btn" data-act="edit">${h.builtin ? 'View' : 'Edit'}</button>
            <button type="button" class="harness-btn" data-act="dup">Duplicate</button>
            ${h.builtin ? '' : '<button type="button" class="harness-btn danger" data-act="del">Delete</button>'}
          </div></div>`;
    }).join('');
    body.innerHTML = `<div class="harness-list">
        <div class="harness-defaults">
          <label class="harness-field"><span>Voice default</span>${assignSelect('voice')}</label>
          <label class="harness-field"><span>Chat default</span>${assignSelect('chat')}</label>
          <div class="harness-hint">A chat can pick its own harness from the chip in the composer; new chats start on the Chat default.</div>
        </div>
        <div class="harness-cards">${cards || '<div class="harness-hint">Loading harnesses…</div>'}</div>
      </div>`;
  }

  async function onListClick(ev) {
    const btn = ev.target.closest('[data-act]');
    if (!btn || E.view !== 'list') return;
    const card = btn.closest('.harness-card');
    const h = card ? E.harnesses.find(x => x.id === card.dataset.id) : null;
    const act = btn.dataset.act;
    if (act === 'new') return createHarness();
    if (!h) return;
    if (act === 'edit') return editHarness(h.id);
    if (act === 'dup') return startDuplicate(h);
    if (act === 'del') return deleteHarness(h);
  }

  async function onAssignChange(ev) {
    const sel = ev.target.closest('select[data-assign]');
    if (!sel) return;
    try {
      const r = await api('api/harnesses/assign', { method: 'POST', body: JSON.stringify({ surface: sel.dataset.assign, harness_id: sel.value }) });
      if (r && r.assignments) E.assignments = Object.assign(E.assignments, r.assignments);
      refreshChip();
      renderList();
    } catch (e) { toast('Could not set the default: ' + (e.message || e), 'error'); }
  }

  async function createHarness() {
    const name = typeof showPromptDialog === 'function'
      ? await showPromptDialog({ title: 'New harness', message: 'Name it after what it is for.', placeholder: 'Deep research', confirmLabel: 'Create' })
      : window.prompt('Name the new harness');
    if (!name || !String(name).trim()) return;
    const id = HarnessGraph.uniqueId(HarnessGraph.slug(name), E.harnesses.map(h => h.id));
    const doc = HarnessGraph.newHarness(id, String(name).trim());
    const a = HarnessGraph.addNode(doc, 'answer', 40, 180);
    HarnessGraph.connect(doc, 'in', a, 'always');
    startEditing(doc, { isNew: true, readOnly: false, sel: { node: a } });
  }

  function startDuplicate(h) {
    const ids = E.harnesses.map(x => x.id);
    const doc = HarnessGraph.duplicate(h, HarnessGraph.uniqueId(h.id + '-copy', ids), (h.name || h.id) + ' copy');
    startEditing(doc, { isNew: true, readOnly: false });
    toast('Copy made. Save to keep it.');
  }

  async function deleteHarness(h) {
    const ok = typeof showConfirmDialog === 'function'
      ? await showConfirmDialog({ title: 'Delete harness?', message: `“${h.name || h.id}” will be removed. Chats using it fall back to the Chat default.`, confirmLabel: 'Delete', danger: true })
      : window.confirm('Delete this harness?');
    if (!ok) return;
    try {
      await api(`api/harnesses/designs/${encodeURIComponent(h.id)}/delete`, { method: 'POST', body: '{}' });
      await fetchData();
      refreshChip();
      renderList();
    } catch (e) { toast('Delete failed: ' + (e.message || e), 'error'); }
  }

  // ── Editor view ─────────────────────────────────────────────────────────
  function editHarness(id) {
    const h = E.harnesses.find(x => x.id === id);
    if (!h) { toast('That harness is gone.', 'error'); renderList(); return; }
    startEditing(JSON.parse(JSON.stringify(h)), { isNew: false, readOnly: !!h.builtin });
  }

  async function startEditing(doc, opts) {
    E.doc = doc; E.view = 'edit'; E.readOnly = !!opts.readOnly; E.isNew = !!opts.isNew;
    E.dirty = !!opts.isNew; E.sel = opts.sel || null;
    renderEditor();
    fitView();
    await fetchModels();
    if (E.view === 'edit' && E.doc === doc) renderPanel();
  }

  function renderHeader() {
    const d = E.doc;
    $id('harnessViewTitle').textContent = `${d.icon ? d.icon + ' ' : ''}${d.name || d.id}${E.readOnly ? ' · built-in' : ''}${E.dirty ? ' •' : ''}`;
    $id('harnessViewActions').innerHTML = '<button type="button" class="harness-btn" data-act="back">Back</button>' +
      (E.readOnly
        ? '<button type="button" class="harness-btn accent" data-act="dup-edit">Duplicate to edit</button>'
        : `<button type="button" class="harness-btn accent" data-act="save"${E.saving ? ' disabled' : ''}>${E.saving ? 'Saving…' : 'Save'}</button>`);
  }

  function renderEditor() {
    E.view = 'edit';
    renderHeader();
    const d = E.doc, ro = E.readOnly ? ' disabled' : '';
    const body = $id('harnessViewBody');
    body.classList.add('harness-body--edit');
    const adders = E.readOnly ? '' : ['answer', 'route', 'background', 'review'].map(t =>
      `<button type="button" class="harness-btn" data-add="${t}">+ ${TYPES[t]}</button>`).join('');
    body.innerHTML = `<div class="harness-editor">
        <div class="harness-editor-main">
          <div class="harness-toolbar">
            <input class="harness-input harness-icon-input" data-doc="icon" maxlength="4" value="${esc(d.icon || '')}" placeholder="⚡" aria-label="Icon"${ro}>
            <input class="harness-input harness-name-input" data-doc="name" maxlength="60" value="${esc(d.name || '')}" placeholder="Name" aria-label="Name"${ro}>
            <span class="harness-toolbar-adders">${adders}</span>
            <span class="harness-toolbar-zoom">
              <button type="button" class="harness-btn icon" data-zoom="out" aria-label="Zoom out">−</button>
              <button type="button" class="harness-btn icon" data-zoom="fit" aria-label="Fit">Fit</button>
              <button type="button" class="harness-btn icon" data-zoom="in" aria-label="Zoom in">+</button>
            </span>
          </div>
          <div class="harness-canvas-wrap">
            <svg id="harnessCanvas" class="harness-canvas" tabindex="0" aria-label="Harness graph">
              <defs><marker id="harnessArrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z"/></marker></defs>
              <g id="harnessRoot"><g class="h-edges"></g><g class="h-nodes"></g><path class="h-temp-wire" d=""/></g>
            </svg>
          </div>
        </div>
        <aside class="harness-side-panel" id="harnessSidePanel"></aside>
      </div>`;
    wireCanvas($id('harnessCanvas'));
    drawCanvas();
    renderPanel();
  }

  function nodeSubtitle(n) {
    if (n.type === 'message') return 'start';
    if (n.type === 'route') return n.by === 'model' ? `by model · ${shortModel(n.model) || 'pick a model'}` : `by rules · ${(n.rules || []).length} rule${(n.rules || []).length === 1 ? '' : 's'}`;
    if (n.model === '@session') return "the chat's model";
    return n.model ? shortModel(n.model) : 'pick a model';
  }

  // Output dot (right middle) to just short of the input dot, so the arrow
  // tip meets the dot instead of covering it.
  function edgePath(a, b) {
    const x1 = a.x + NODE_W, y1 = a.y + NODE_H / 2, x2 = b.x - 6, y2 = b.y + NODE_H / 2;
    const dx = Math.max(40, Math.abs(x2 - x1) / 2);
    return { d: `M${x1},${y1} C${x1 + dx},${y1} ${x2 - dx},${y2} ${x2},${y2}`, mx: (x1 + x2) / 2, my: (y1 + y2) / 2 };
  }

  function drawCanvas() {
    const root = $id('harnessRoot');
    if (!root || !E.doc) return;
    const d = E.doc;
    root.setAttribute('transform', `translate(${E.tx},${E.ty}) scale(${E.k})`);
    root.querySelector('.h-edges').innerHTML = d.edges.map((e, i) => {
      const a = nodeById(e.from), b = nodeById(e.to);
      if (!a || !b) return '';
      const p = edgePath(a, b);
      const label = HarnessGraph.edgeLabel(e.when);
      const probs = HarnessGraph.problemsFor(d, { edge: i });
      const cls = ['h-edge', 'when-' + esc(String(e.when || 'always').split(':')[0]),
        E.sel && E.sel.edge === i ? 'sel' : '', probs.length ? 'err' : ''].filter(Boolean).join(' ');
      return `<g class="${cls}" data-edge="${i}"><path class="h-edge-hit" d="${p.d}"/>` +
        `<path class="h-edge-line" d="${p.d}" marker-end="url(#harnessArrow)"/>` +
        (label ? `<text class="h-edge-label" x="${p.mx}" y="${p.my - 6}" text-anchor="middle">${esc(clip(label, 22))}</text>` : '') +
        (probs.length ? `<title>${esc(probs.join('\n'))}</title>` : '') + '</g>';
    }).join('');
    root.querySelector('.h-nodes').innerHTML = d.nodes.map(n => {
      const probs = HarnessGraph.problemsFor(d, { node: n.id });
      const cls = ['h-node', 't-' + esc(n.type), E.sel && E.sel.node === n.id ? 'sel' : '', probs.length ? 'err' : ''].filter(Boolean).join(' ');
      return `<g class="${cls}" data-node="${esc(n.id)}" transform="translate(${Number(n.x) || 0},${Number(n.y) || 0})">` +
        `<rect class="h-node-box" width="${NODE_W}" height="${NODE_H}" rx="10"/>` +
        `<text class="h-node-cap" x="12" y="17">${esc((TYPES[n.type] || n.type).toUpperCase())}</text>` +
        `<text class="h-node-title" x="12" y="34">${esc(clip(n.label || n.id, 20))}</text>` +
        `<text class="h-node-sub" x="12" y="49">${esc(clip(nodeSubtitle(n), 24))}</text>` +
        (n.type !== 'message' ? `<circle class="h-port h-port-in" cx="0" cy="${NODE_H / 2}" r="5"/>` : '') +
        `<circle class="h-port h-port-out" data-port-out="${esc(n.id)}" cx="${NODE_W}" cy="${NODE_H / 2}" r="7"/>` +
        (probs.length ? `<g class="h-node-badge"><circle cx="${NODE_W - 10}" cy="10" r="8"/><text x="${NODE_W - 10}" y="14" text-anchor="middle">!</text></g>` : '') +
        `<title>${esc([n.id].concat(probs).join('\n'))}</title></g>`;
    }).join('');
  }

  function applyTransform() {
    const root = $id('harnessRoot');
    if (root) root.setAttribute('transform', `translate(${E.tx},${E.ty}) scale(${E.k})`);
  }

  function fitView() {
    const svg = $id('harnessCanvas');
    if (!svg || !E.doc || !E.doc.nodes.length) return;
    const r = svg.getBoundingClientRect();
    if (!r.width || !r.height) return;
    const xs = E.doc.nodes.map(n => Number(n.x) || 0), ys = E.doc.nodes.map(n => Number(n.y) || 0);
    const minX = Math.min(...xs), minY = Math.min(...ys);
    const w = Math.max(...xs) - minX + NODE_W, h = Math.max(...ys) - minY + NODE_H;
    const pad = 32;
    E.k = Math.max(0.4, Math.min(1.25, (r.width - pad * 2) / w, (r.height - pad * 2) / h));
    E.tx = (r.width - w * E.k) / 2 - minX * E.k;
    E.ty = (r.height - h * E.k) / 2 - minY * E.k;
    applyTransform();
  }

  function zoomAt(factor, cx, cy) {
    const k2 = Math.max(0.4, Math.min(2.5, E.k * factor));
    E.tx = cx - (cx - E.tx) * (k2 / E.k);
    E.ty = cy - (cy - E.ty) * (k2 / E.k);
    E.k = k2;
    applyTransform();
  }

  function markDirty() {
    if (!E.dirty) { E.dirty = true; renderHeader(); }
  }

  // ── Canvas gestures (pointer events: mouse, pen and touch) ──────────────
  function wireCanvas(svg) {
    const toCanvas = ev => {
      const r = svg.getBoundingClientRect();
      return { x: (ev.clientX - r.left - E.tx) / E.k, y: (ev.clientY - r.top - E.ty) / E.k };
    };
    svg.addEventListener('pointerdown', ev => {
      if (ev.pointerType === 'mouse' && ev.button !== 0) return;
      const p = toCanvas(ev);
      const port = ev.target.closest('[data-port-out]');
      const nodeEl = ev.target.closest('[data-node]');
      const edgeEl = ev.target.closest('[data-edge]');
      if (port && !E.readOnly) {
        E.gesture = { kind: 'wire', from: port.dataset.portOut, id: ev.pointerId };
      } else if (nodeEl) {
        const n = nodeById(nodeEl.dataset.node);
        E.sel = { node: nodeEl.dataset.node };
        E.gesture = (n && !E.readOnly) ? { kind: 'drag', node: n.id, dx: p.x - n.x, dy: p.y - n.y, moved: false, id: ev.pointerId } : null;
        drawCanvas(); renderPanel();
      } else if (edgeEl) {
        E.sel = { edge: Number(edgeEl.dataset.edge) };
        E.gesture = null;
        drawCanvas(); renderPanel();
      } else {
        E.gesture = { kind: 'pan', sx: ev.clientX, sy: ev.clientY, tx0: E.tx, ty0: E.ty, moved: false, id: ev.pointerId };
      }
      if (E.gesture) { try { svg.setPointerCapture(ev.pointerId); } catch (_) { /* old browsers */ } }
      svg.focus({ preventScroll: true });
      ev.preventDefault();
    });
    svg.addEventListener('pointermove', ev => {
      const g = E.gesture;
      if (!g || g.id !== ev.pointerId) return;
      if (g.kind === 'pan') {
        if (Math.abs(ev.clientX - g.sx) + Math.abs(ev.clientY - g.sy) > 3) g.moved = true;
        E.tx = g.tx0 + (ev.clientX - g.sx); E.ty = g.ty0 + (ev.clientY - g.sy);
        applyTransform();
      } else if (g.kind === 'drag') {
        const p = toCanvas(ev);
        HarnessGraph.moveNode(E.doc, g.node, p.x - g.dx, p.y - g.dy);
        g.moved = true;
        drawCanvas();
      } else if (g.kind === 'wire') {
        const a = nodeById(g.from);
        if (!a) return;
        const p = toCanvas(ev);
        const path = edgePath(a, { x: p.x, y: p.y - NODE_H / 2 });
        svg.querySelector('.h-temp-wire').setAttribute('d', path.d);
      }
    });
    const end = ev => {
      const g = E.gesture;
      if (!g || g.id !== ev.pointerId) return;
      E.gesture = null;
      try { svg.releasePointerCapture(ev.pointerId); } catch (_) { /* already released */ }
      if (g.kind === 'pan' && !g.moved && E.sel) { E.sel = null; drawCanvas(); renderPanel(); }
      if (g.kind === 'drag' && g.moved) markDirty();
      if (g.kind === 'wire') {
        svg.querySelector('.h-temp-wire').setAttribute('d', '');
        const hit = ev.type === 'pointerup' ? document.elementFromPoint(ev.clientX, ev.clientY) : null;
        const target = hit && hit.closest ? hit.closest('[data-node]') : null;
        const to = target && target.dataset.node;
        if (to && to !== g.from && !E.doc.edges.some(e => e.from === g.from && e.to === to)) {
          if (HarnessGraph.connect(E.doc, g.from, to, HarnessGraph.nextWhen(E.doc, g.from, to))) {
            E.sel = { edge: E.doc.edges.length - 1 };
            markDirty();
            drawCanvas(); renderPanel();
          }
        }
      }
    };
    svg.addEventListener('pointerup', end);
    svg.addEventListener('pointercancel', end);
    svg.addEventListener('wheel', ev => {
      ev.preventDefault();
      const r = svg.getBoundingClientRect();
      zoomAt(Math.exp(-ev.deltaY * 0.0015), ev.clientX - r.left, ev.clientY - r.top);
    }, { passive: false });
    svg.addEventListener('keydown', ev => {
      if ((ev.key === 'Delete' || ev.key === 'Backspace') && E.sel && !E.readOnly) {
        ev.preventDefault();
        deleteSelection();
      }
    });
  }

  function deleteSelection() {
    if (!E.sel || E.readOnly) return;
    if (E.sel.node != null) {
      if (!HarnessGraph.removeNode(E.doc, E.sel.node)) { toast('The Message node is the start; it stays.'); return; }
    } else if (E.sel.edge != null) {
      HarnessGraph.disconnect(E.doc, E.sel.edge);
    }
    // Indexes moved: stale server problems would point at the wrong wires.
    E.doc.problems = [];
    E.sel = null;
    markDirty();
    drawCanvas(); renderPanel();
  }

  // ── Side panel ──────────────────────────────────────────────────────────
  function opt(value, label, cur) {
    return `<option value="${esc(value)}"${String(value) === String(cur) ? ' selected' : ''}>${esc(label)}</option>`;
  }

  function modelField(field, value, allowNone) {
    const groups = E.models || [];
    if (!groups.length) {
      return `<input class="harness-input" data-field="${field}" value="${esc(value || '')}" placeholder="@provider:model">`;
    }
    const known = new Set();
    let html = groups.map(g => `<optgroup label="${esc(g.label)}">` + g.options.map(o => {
      known.add(o.value);
      return opt(o.value, o.label, value);
    }).join('') + '</optgroup>').join('');
    if (value && !known.has(value)) {
      html = opt(value, (value === '@session' ? "The chat's model" : shortModel(value)) + ' (current)', value) + html;
    }
    html = (allowNone ? opt('', 'None', value) : (value ? '' : opt('', 'Pick a model…', value))) + html;
    return `<select class="harness-input" data-field="${field}">${html}</select>`;
  }

  function fieldRow(label, control) {
    return `<label class="harness-field"><span>${esc(label)}</span>${control}</label>`;
  }

  function problemsHtml(list) {
    return list.length ? `<ul class="harness-problems">${list.map(m => `<li>${esc(m)}</li>`).join('')}</ul>` : '';
  }

  function nodePanel(n) {
    const rows = [];
    rows.push(`<div class="harness-panel-title">${esc(TYPES[n.type] || n.type)} <span class="harness-panel-id">${esc(n.id)}</span></div>`);
    rows.push(problemsHtml(HarnessGraph.problemsFor(E.doc, { node: n.id })));
    if (n.type === 'message') {
      rows.push('<div class="harness-hint">Every turn starts here. Wire it to an Answer (or a Route).</div>');
      return rows.join('');
    }
    rows.push(fieldRow('Title', `<input class="harness-input" data-field="label" maxlength="60" value="${esc(n.label || '')}" placeholder="${esc(n.id)}">`));
    if (n.type === 'answer' || n.type === 'background' || n.type === 'review') {
      rows.push(fieldRow('Model', modelField('model', n.model, false)));
    }
    if (n.type === 'answer' || n.type === 'background') {
      const custom = Array.isArray(n.tools);
      rows.push(fieldRow('Tools', `<select class="harness-input" data-field="tools">` +
        opt('lean', 'Lean (fast)', n.tools) + opt('all', 'All', n.tools) + opt('none', 'None', n.tools) +
        (custom ? opt('__keep', 'Toolsets: ' + n.tools.join(', '), '__keep') : '') + '</select>'));
    }
    if (n.type === 'answer') {
      rows.push(fieldRow('Fallback model', modelField('fallback_model', n.fallback_model || '', true)));
      rows.push(fieldRow('Max tool steps', `<input class="harness-input" type="number" min="1" data-field="max_steps" value="${esc(n.max_steps || '')}" placeholder="no limit">`));
    }
    if (n.type === 'background') {
      rows.push(fieldRow('Deliver', `<select class="harness-input" data-field="deliver">` +
        opt('speak_or_notify', 'Speak if Voice is open, else notify', n.deliver) + opt('post', 'Post in the chat', n.deliver) +
        opt('notify', 'Notify', n.deliver) + '</select>'));
    }
    if (n.type === 'review') {
      rows.push(fieldRow('Deliver', `<select class="harness-input" data-field="deliver">` +
        opt('post_if_changed', 'Post only a correction', n.deliver) + opt('post', 'Always post', n.deliver) + '</select>'));
    }
    if (n.type === 'route') {
      rows.push(fieldRow('Pick by', `<select class="harness-input" data-field="by">` +
        opt('rules', 'Rules', n.by) + opt('model', 'A model', n.by) + '</select>'));
      if (n.by === 'model') rows.push(fieldRow('Router model', modelField('model', n.model, false)));
      rows.push(fieldRow('Labels', `<input class="harness-input" data-field="labels" value="${esc((n.labels || []).join(', '))}" placeholder="deep, quick">`));
      const rules = (n.rules || []).map((r, i) => `<div class="harness-rule" data-rule="${i}">
          <select class="harness-input" data-rule-field="match">${opt('keywords', 'Keywords', r.match)}${opt('regex', 'Regex', r.match)}${opt('surface', 'Surface', r.match)}${opt('has_attachment', 'Has attachment', r.match)}</select>
          ${r.match === 'has_attachment' ? '<span class="harness-rule-value">attached file</span>'
            : `<input class="harness-input" data-rule-field="value" value="${esc(r.value == null ? '' : r.value)}" placeholder="${r.match === 'surface' ? 'voice' : 'code, bug'}">`}
          <input class="harness-input" data-rule-field="label" value="${esc(r.label || '')}" placeholder="label">
          ${E.readOnly ? '' : '<button type="button" class="harness-btn icon" data-rule-del aria-label="Remove rule">×</button>'}
        </div>`).join('');
      rows.push(`<div class="harness-field"><span>Rules (first match wins; nothing matches → default wire)</span>${rules || '<div class="harness-hint">No rules yet.</div>'}` +
        (E.readOnly ? '' : '<button type="button" class="harness-btn" data-rule-add>+ Rule</button>') + '</div>');
    }
    rows.push(fieldRow('Instructions', `<textarea class="harness-input" rows="3" data-field="instructions" placeholder="Extra instructions for this step">${esc(n.instructions || '')}</textarea>`));
    if (!E.readOnly) rows.push('<button type="button" class="harness-btn danger" data-del-sel>Delete node</button>');
    return rows.join('');
  }

  function edgePanel(i) {
    const e = E.doc.edges[i];
    if (!e) return '';
    const from = nodeById(e.from), to = nodeById(e.to);
    const when = String(e.when || 'always');
    const kind = when.includes(':') ? when.slice(0, when.indexOf(':')) : when;
    const value = when.includes(':') ? when.slice(when.indexOf(':') + 1) : '';
    const fromRoute = from && from.type === 'route';
    const kinds = fromRoute ? [['default', 'Default (nothing matched)'], ['label', 'Label']]
      : [['always', 'Always'], ['handoff', 'Hand-off'], ['slow', 'When the answer is slow'], ['tools', 'When it used many tools']];
    if (!kinds.some(k => k[0] === kind)) kinds.push([kind, kind]);
    let valueCtl = '';
    if (kind === 'label') {
      const labels = (from && from.labels) || [];
      valueCtl = fieldRow('Label', `<input class="harness-input" data-when-value list="harnessLabelList" value="${esc(value)}">` +
        `<datalist id="harnessLabelList">${labels.map(l => `<option value="${esc(l)}">`).join('')}</datalist>`);
    } else if (kind === 'slow') {
      valueCtl = fieldRow('Seconds', `<input class="harness-input" type="number" min="1" data-when-value value="${esc(value || 10)}">`);
    } else if (kind === 'tools') {
      valueCtl = fieldRow('Tool calls', `<input class="harness-input" type="number" min="1" data-when-value value="${esc(value || 3)}">`);
    }
    return `<div class="harness-panel-title">Wire <span class="harness-panel-id">${esc((from && (from.label || from.id)) || e.from)} → ${esc((to && (to.label || to.id)) || e.to)}</span></div>` +
      problemsHtml(HarnessGraph.problemsFor(E.doc, { edge: i })) +
      fieldRow('Runs', `<select class="harness-input" data-when-kind>${kinds.map(k => opt(k[0], k[1], kind)).join('')}</select>`) + valueCtl +
      (E.readOnly ? '' : '<button type="button" class="harness-btn danger" data-del-sel>Delete wire</button>');
  }

  function generalPanel() {
    const d = E.doc;
    const nodeProblems = (d.problems || []).filter(p => p.node != null || p.edge != null).length;
    return `<div class="harness-panel-title">${esc(d.name || d.id)} <span class="harness-panel-id">${esc(d.id)}</span></div>` +
      problemsHtml(HarnessGraph.problemsFor(d, {})) +
      (nodeProblems ? `<div class="harness-hint warn">${nodeProblems} problem${nodeProblems > 1 ? 's' : ''} marked on the graph.</div>` : '') +
      (E.readOnly
        ? '<div class="harness-hint">Built-in harnesses are read-only. Duplicate one to start from it.</div>'
        : '<div class="harness-hint">Drag a node to move it. Drag a node’s right dot onto another node to wire them. Drag empty space to pan; scroll or use − / + to zoom. Select a node or wire to edit it.</div>');
  }

  function renderPanel() {
    const panel = $id('harnessSidePanel');
    if (!panel || !E.doc) return;
    let html;
    if (E.sel && E.sel.node != null && nodeById(E.sel.node)) html = nodePanel(nodeById(E.sel.node));
    else if (E.sel && E.sel.edge != null && E.doc.edges[E.sel.edge]) html = edgePanel(E.sel.edge);
    else { E.sel = null; html = generalPanel(); }
    panel.innerHTML = html;
    if (E.readOnly) panel.querySelectorAll('input,select,textarea').forEach(el => { el.disabled = true; });
  }

  function onPanelField(ev) {
    if (E.readOnly || !E.doc) return;
    const el = ev.target;
    if (el.dataset.doc) {  // name / icon in the toolbar
      E.doc[el.dataset.doc] = el.value;
      markDirty(); renderHeader();
      return;
    }
    if (!E.sel) return;
    const n = E.sel.node != null ? nodeById(E.sel.node) : null;
    const e = E.sel.edge != null ? E.doc.edges[E.sel.edge] : null;
    let rerenderPanel = false;
    if (n && el.dataset.field) {
      const f = el.dataset.field, v = el.value;
      if (f === 'tools') { if (v !== '__keep') n.tools = v; }
      else if (f === 'max_steps') { if (v) n.max_steps = Math.max(1, parseInt(v, 10) || 1); else delete n.max_steps; }
      else if (f === 'labels') { n.labels = Array.from(new Set(v.split(',').map(s => s.trim()).filter(Boolean))); }
      else if (f === 'by') { n.by = v; rerenderPanel = true; }
      else if (['label', 'instructions', 'fallback_model'].includes(f)) { if (v.trim()) n[f] = v; else delete n[f]; }
      else n[f] = v;
    } else if (n && el.dataset.ruleField) {
      const row = el.closest('[data-rule]');
      const r = row && (n.rules || [])[Number(row.dataset.rule)];
      if (!r) return;
      const f = el.dataset.ruleField;
      if (f === 'match') { r.match = el.value; r.value = el.value === 'has_attachment' ? true : ''; rerenderPanel = true; }
      else r[f] = el.value;
    } else if (e && (el.hasAttribute('data-when-kind') || el.hasAttribute('data-when-value'))) {
      const panel = $id('harnessSidePanel');
      const kind = panel.querySelector('[data-when-kind]').value;
      const valEl = panel.querySelector('[data-when-value]');
      if (el.hasAttribute('data-when-kind')) {
        const from = nodeById(e.from);
        const defaults = { label: ((from && from.labels) || [])[0] || 'path', slow: '10', tools: '3' };
        e.when = defaults[kind] ? `${kind}:${defaults[kind]}` : kind;
        rerenderPanel = true;
      } else {
        const v = String(valEl.value || '').trim();
        if (!v) return;
        e.when = `${kind}:${v}`;
      }
    } else {
      return;
    }
    markDirty();
    drawCanvas();
    if (rerenderPanel) renderPanel();
  }

  function onPanelClick(ev) {
    if (E.readOnly) return;
    const n = E.sel && E.sel.node != null ? nodeById(E.sel.node) : null;
    if (ev.target.closest('[data-del-sel]')) return deleteSelection();
    if (n && ev.target.closest('[data-rule-add]')) {
      n.rules = n.rules || [];
      n.rules.push({ match: 'keywords', value: '', label: (n.labels || [])[0] || '' });
      markDirty(); drawCanvas(); renderPanel();
      return;
    }
    const del = ev.target.closest('[data-rule-del]');
    if (n && del) {
      const row = del.closest('[data-rule]');
      n.rules.splice(Number(row.dataset.rule), 1);
      markDirty(); drawCanvas(); renderPanel();
    }
  }

  async function onEditorClick(ev) {
    if (E.view !== 'edit') return;
    const add = ev.target.closest('[data-add]');
    if (add && !E.readOnly) {
      const svg = $id('harnessCanvas');
      const r = svg.getBoundingClientRect();
      const cx = (r.width / 2 - E.tx) / E.k - NODE_W / 2, cy = (r.height / 2 - E.ty) / E.k - NODE_H / 2;
      const offset = (E.doc.nodes.length % 5) * 18;
      const id = HarnessGraph.addNode(E.doc, add.dataset.add, cx + offset, cy + offset);
      E.sel = { node: id };
      markDirty(); drawCanvas(); renderPanel();
      return;
    }
    const z = ev.target.closest('[data-zoom]');
    if (z) {
      const r = $id('harnessCanvas').getBoundingClientRect();
      if (z.dataset.zoom === 'fit') fitView();
      else zoomAt(z.dataset.zoom === 'in' ? 1.2 : 1 / 1.2, r.width / 2, r.height / 2);
      return;
    }
    const act = ev.target.closest('[data-act]');
    if (!act) return;
    if (act.dataset.act === 'back') return leaveEditor();
    if (act.dataset.act === 'save') return save();
    if (act.dataset.act === 'dup-edit') return startDuplicate(E.doc);
  }

  async function leaveEditor() {
    if (E.dirty && !E.readOnly) {
      const ok = typeof showConfirmDialog === 'function'
        ? await showConfirmDialog({ title: 'Discard changes?', message: 'This harness has unsaved changes.', confirmLabel: 'Discard', danger: true })
        : window.confirm('Discard unsaved changes?');
      if (!ok) return;
    }
    E.doc = null; E.sel = null; E.dirty = false;
    await fetchData();
    renderList();
  }

  async function save() {
    if (E.readOnly || E.saving || !E.doc) return;
    E.saving = true;
    renderHeader();
    try {
      const r = await api('api/harnesses/designs', { method: 'POST', body: JSON.stringify({ design: HarnessGraph.toDesign(E.doc) }) });
      if (r && r.design) {
        const keepSel = E.sel;
        E.doc = Object.assign(r.design, { problems: [] });
        E.sel = keepSel;
        E.dirty = false; E.isNew = false;
        toast('Harness saved.');
        await fetchData();
        refreshChip();
      }
    } catch (e) {
      let errors = null;
      try { errors = JSON.parse(e.body || '{}').errors; } catch (_) { errors = null; }
      if (Array.isArray(errors) && errors.length) {
        E.doc.problems = errors;
        toast(`Not saved: ${errors.length} problem${errors.length > 1 ? 's' : ''} marked on the graph.`, 'error');
      } else {
        toast('Save failed: ' + (e.message || e), 'error');
      }
    } finally {
      E.saving = false;
      if (E.view === 'edit' && E.doc) { renderHeader(); drawCanvas(); renderPanel(); }
    }
  }

  // ── Wiring (delegated; the panel's DOM is rebuilt freely) ───────────────
  function init() {
    const main = $id('mainHarnesses');
    if (!main || main.dataset.wired) return;
    main.dataset.wired = '1';
    main.addEventListener('click', ev => {
      if (E.view === 'list') onListClick(ev);
      else if (ev.target.closest('#harnessSidePanel')) onPanelClick(ev);
      else onEditorClick(ev);
    });
    main.addEventListener('change', ev => {
      if (E.view === 'list') onAssignChange(ev);
      else onPanelField(ev);
    });
    main.addEventListener('input', ev => {
      if (E.view !== 'edit') return;
      // Text fields apply as you type; selects/numbers settle on change.
      const el = ev.target;
      if (el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT' && el.type !== 'number')) onPanelField(ev);
    });
    window.addEventListener('resize', () => { if (E.view === 'edit' && E.gesture == null) applyTransform(); });
    // Harnesses is a Settings entry with its own main view: clicking any other
    // Settings section from here goes back to the Settings view first. Capture
    // phase, so it runs before the item's own switchSettingsSection() onclick.
    const menu = $id('settingsMenu');
    if (menu) menu.addEventListener('click', ev => {
      const item = ev.target.closest('.side-menu-item[data-settings-section]');
      if (item && typeof _currentPanel !== 'undefined' && _currentPanel === 'harnesses' && typeof switchPanel === 'function') {
        switchPanel('settings');
      }
    }, true);
  }

  window.HarnessEditor = { open, load };
  document.addEventListener('DOMContentLoaded', init);
})();

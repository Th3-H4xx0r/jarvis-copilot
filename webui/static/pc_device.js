// The PC's card in the web Devices panel: a still picture of its 3D model, the same controls as the
// Agents tab's PC card (agents.js JCMacControls — not a copy), PC Lighting (part by part, colours,
// effects, looks) and the specs the Jarvis app on the PC reads. Calibration needs the 3D model, so it
// stays on the iPhone. Spec: docs/superpowers/specs/2026-11-20-pc-lighting-model-specs-design.md
(function (root) {
  const PARTS = [['top', 'Top fans'], ['rear', 'Rear fans'], ['bottom', 'Bottom fans'], ['cooler', 'Cooler'], ['strip', 'Strip']];
  const EFFECTS = [['static', 'Static'], ['breathing', 'Breathing'], ['rainbow', 'Rainbow'], ['spectrum', 'Spectrum'], ['comet', 'Comet']];
  const SWATCHES = ['#ffffff', '#ff3b30', '#ff9f0a', '#ffd60a', '#30d158', '#22d3ee', '#0a84ff', '#bf5af2'];
  const st = { pc: null, lighting: null, specs: null, part: null, error: '', card: null, loadedAt: 0 };
  const RELOAD_MS = 30000;

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }
  function label(list, id) { const hit = list.find((x) => x[0] === id); return hit ? hit[1] : id; }

  function lightsLabel(l) {
    if (!l || !l.state) return '';
    if (!((l.map || {}).segments || []).length) return 'Set up';
    if (!l.state.on) return 'Off';
    const effects = new Set(PARTS.map(([p]) => ((l.state.parts || {})[p] || {}).effect));
    return effects.size === 1 ? label(EFFECTS, [...effects][0]) : 'Mixed';
  }

  function specsHtml(specs) {
    if (!specs) return '<p class="pcd-muted">No specs yet. Update Jarvis on the PC.</p>';
    const rows = [];
    const add = (k, v) => { if (v) rows.push('<span>' + esc(k) + '</span><span>' + esc(v) + '</span>'); };
    const c = specs.cpu || {};
    add('Processor', [c.name, c.cores && c.cores + ' cores', c.threads && c.threads + ' threads'].filter(Boolean).join(' · '));
    (specs.gpus || []).forEach((g) => add('Graphics', [g.name, g.vram_mb && Math.round(g.vram_mb / 1024) + ' GB'].filter(Boolean).join(' · ')));
    const b = specs.board || {};
    add('Motherboard', [[b.maker, b.product].filter(Boolean).join(' '), b.bios && 'BIOS ' + b.bios].filter(Boolean).join(' · '));
    const m = specs.memory || {};
    add('Memory', m.total_mb && (m.total_mb / 1024) + ' GB');
    (m.modules || []).forEach((x, i) => add('Stick ' + (i + 1), [x.maker, x.part, x.size_mb && x.size_mb / 1024 + ' GB', x.mhz && x.mhz + ' MT/s'].filter(Boolean).join(' · ')));
    (specs.storage || []).forEach((d) => add('Storage', [d.model, d.size_gb && d.size_gb + ' GB', d.kind].filter(Boolean).join(' · ')));
    (specs.displays || []).forEach((d) => add('Display', [d.name, d.width && d.height && d.width + '×' + d.height, d.hz && d.hz + ' Hz'].filter(Boolean).join(' · ')));
    const o = specs.os || {};
    add('System', [o.name, (specs.system || {}).maker, (specs.system || {}).model].filter(Boolean).join(' · '));
    add('From your photos', 'Glass dual-chamber case · 240 mm liquid cooler · 7 × 120 mm RGB fans · CyberPower PSU');
    return '<div class="dev-facts pcd-specs">' + rows.join('') + '</div>';
  }

  function lightingHtml(l, part) {
    if (!l) return '';
    let body;
    if (!l.online) {
      body = '<p class="pcd-muted">Unavailable — the PC is asleep or offline.</p>';
    } else if (!((l.map || {}).segments || []).length) {
      body = '<p class="pcd-muted">Finish setting up lighting on your iPhone (PC page → Lighting): Jarvis installs OpenRGB, then you tap each part as it lights up.</p>';
    } else {
      const s = l.state || {};
      const cur = (s.parts || {})[part || 'top'] || {};
      const host = part && l.coverage && l.coverage[part] && l.coverage[part] !== 'missing' ? l.coverage[part] : '';
      const chip = (id, text, on, dim) => '<button type="button" class="agents-pill-btn pcd-chip' + (on ? ' is-on' : '') + (dim ? ' is-dim' : '') +
        '" data-pcd="part" data-part="' + esc(id) + '"' + (dim ? ' disabled title="No lights mapped"' : '') + '>' + esc(text) + '</button>';
      body =
        '<div class="pcd-row"><label class="pcd-toggle"><input type="checkbox" data-pcd="on"' + (s.on ? ' checked' : '') + '> Lights</label>' +
        '<input type="range" min="0" max="100" value="' + esc(s.brightness) + '" data-pcd="brightness" aria-label="Brightness">' +
        '<span class="pcd-muted">' + esc(s.brightness) + '%</span></div>' +
        '<div class="pcd-row">' + chip('', 'All', !part) + PARTS.map(([id, t]) => chip(id, t, part === id, l.coverage && l.coverage[id] === 'missing')).join('') + '</div>' +
        (host ? '<p class="pcd-muted">' + esc(label(PARTS, part)) + ' share lights with ' + esc(label(PARTS, host).toLowerCase()) + ' — changing one changes both.</p>' : '') +
        '<div class="pcd-row">' + SWATCHES.map((c) => '<button type="button" class="pcd-swatch' + (cur.color === c ? ' is-on' : '') +
          '" style="background:' + c + '" data-pcd="color" data-color="' + c + '" aria-label="Colour ' + c + '"></button>').join('') +
        '<input type="color" value="' + esc(cur.color || '#ffffff') + '" data-pcd="pick" aria-label="Pick a colour"></div>' +
        '<div class="pcd-row">' + EFFECTS.map(([id, t]) => '<button type="button" class="agents-pill-btn' + (cur.effect === id ? ' is-on' : '') +
          '" data-pcd="effect" data-effect="' + id + '">' + t + '</button>').join('') + '</div>' +
        (cur.effect && cur.effect !== 'static' ? '<div class="pcd-row"><span class="pcd-muted">Speed</span><input type="range" min="1" max="10" value="' +
          esc(cur.speed || 5) + '" data-pcd="speed" aria-label="Speed"></div>' : '') +
        '<div class="pcd-row">' + (l.looks || []).map((k) => '<button type="button" class="agents-pill-btn" data-pcd="look" data-name="' + esc(k.name) + '">' +
          esc(k.name) + '</button>').join('') + '<button type="button" class="agents-pill-btn" data-pcd="save-look">Save this look…</button></div>' +
        '<div class="pcd-row pcd-dots">' + PARTS.map(([id, t]) => '<span title="' + esc(t) + '"><i style="background:' +
          esc(((s.parts || {})[id] || {}).color || '#000') + '"></i>' + esc(t) + '</span>').join('') + '</div>' +
        ((l.live || {}).paused_for_game ? '<p class="pcd-muted">Effects are paused while you play.</p>' : '') +
        ((l.live || {}).error ? '<p class="pcd-err">' + esc(l.live.error) + '</p>' : '');
    }
    return '<div class="pcd-lighting" data-power="pc-lighting"><div class="dev-sec"><span>Lighting</span><span class="dev-sec-count">' +
      esc(lightsLabel(l)) + '</span></div>' + body + '</div>';
  }

  function cardHtml(o) {
    if (!o || !o.pc) return '';
    return '<div class="device-card dev-card pcd-card">' +
      '<div class="pcd-hero"><img src="static/img/pc/pc-model.png" alt="Your PC" loading="lazy"></div>' +
      (o.controlsHtml || '') +
      (o.powerOn ? lightingHtml(o.lighting, o.part) : '') +
      '<details class="dev-skills pcd-specs-wrap"><summary class="dev-foot"><span>Specs</span></summary>' + specsHtml(o.specs) + '</details>' +
      (o.error ? '<p class="pcd-err">' + esc(o.error) + '</p>' : '') + '</div>';
  }

  // ── live (browser only) ───────────────────────────────────────────────────
  async function req(method, path, body) {
    const r = await fetch(path, { method, credentials: 'same-origin',
      headers: Object.assign({ 'X-Requested-With': 'fetch' }, body ? { 'Content-Type': 'application/json' } : {}),
      body: body ? JSON.stringify(body) : undefined });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(j.error || 'Request failed (' + r.status + ')');
    return j;
  }
  function powerOn() { return !root.JCPower || root.JCPower.isOn('pc-lighting'); }
  function render() {
    if (!st.card) return;
    const q = (sel) => (st.card.querySelector ? st.card.querySelector(sel) : null);
    const specsOpen = !!(q('details.pcd-specs-wrap') || {}).open;
    const controls = st.pc && root.JCMacControls ? root.JCMacControls.html(st.pc) : '';
    st.card.innerHTML = cardHtml({ pc: st.pc, lighting: st.lighting, specs: st.specs, powerOn: powerOn(), part: st.part,
      controlsHtml: controls, error: st.error });
    const details = q('details.pcd-specs-wrap');
    if (details && specsOpen) details.open = true;
  }
  async function load() {
    st.loadedAt = Date.now();
    try {
      const list = await req('GET', '/api/coding/agents/list');
      st.pc = ((list && list.mac) || []).find((m) => m.os === 'windows') || null;
      if (!st.pc) { render(); return; }
      const [l, s] = await Promise.all([powerOn() ? req('GET', '/api/pc-lighting').catch(() => null) : null,
                                        req('GET', '/api/pc-specs').catch(() => ({}))]);
      st.lighting = l; st.specs = (s && s.specs) || null; st.error = '';
    } catch (e) { st.error = e.message; }
    render();
  }
  async function change(body) {
    try { const r = await req('POST', '/api/pc-lighting/state', Object.assign({ part: st.part || 'all' }, body));
      if (st.lighting && r.state) st.lighting.state = r.state; st.error = ''; }
    catch (e) { st.error = e.message; }
    render();
  }
  function onClick(e) {
    const t = e.target.closest('[data-pcd],[data-act]');
    if (!t || t.disabled) return;
    if (t.dataset.act && root.JCMacControls) { root.JCMacControls.act(t); setTimeout(load, 1500); return; }
    switch (t.dataset.pcd) {
      case 'part': st.part = t.dataset.part || null; render(); break;
      case 'color': change({ color: t.dataset.color }); break;
      case 'effect': change({ effect: t.dataset.effect }); break;
      case 'look': req('POST', '/api/pc-lighting/looks/apply', { name: t.dataset.name }).then(load, (err) => { st.error = err.message; render(); }); break;
      case 'save-look': {
        const name = (root.prompt && root.prompt('Name this look')) || '';
        if (name.trim()) req('POST', '/api/pc-lighting/looks', { name }).then(load, (err) => { st.error = err.message; render(); });
        break;
      }
      default: break;
    }
  }
  function onChange(e) {
    const t = e.target;
    if (!t.dataset || !t.dataset.pcd) return;
    if (t.dataset.pcd === 'on') change({ on: t.checked });
    if (t.dataset.pcd === 'brightness') change({ brightness: Number(t.value) });
    if (t.dataset.pcd === 'speed') change({ speed: Number(t.value) });
    if (t.dataset.pcd === 'pick') change({ color: t.value });
  }
  // devices.js rebuilds its page every 10 s: the card is one element of ours, moved into the new
  // container, so an open Specs panel or colour picker survives, and it reloads at most every 30 s.
  function mount(el) {
    if (!el) return;
    if (!st.card) {
      st.card = document.createElement('div');
      st.card.addEventListener('click', onClick);
      st.card.addEventListener('change', onChange);
      render();
    }
    el.appendChild(st.card);
    if (Date.now() - st.loadedAt > RELOAD_MS) load();
  }

  const api = { mount, cardHtml, lightsLabel };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.JCPcDevice = api;
})(typeof window !== 'undefined' ? window : globalThis);

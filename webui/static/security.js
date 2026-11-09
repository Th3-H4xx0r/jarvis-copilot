// The Security page (Security Advisor, webui/api/security_routes.py): a status
// line, open alerts, the event feed with Source / Level filters, active blocks
// with Undo, recent digests and the advisor's settings.
//
// Block and Allow on an alert need a Face ID signature (domain "jarvis-security"),
// and Face ID lives on the iPhone — so here they only point there. Dismiss, Undo
// and Settings are plain session calls.
//
// UMD: the pure helpers are require()d by security.test.js under `node --test`;
// in the page the same factory also exposes loadSecurity() for panels.js.
(function (root, factory) {
  const S = factory();
  if (typeof module === 'object' && module.exports) module.exports = S;
  else {
    root.SecurityPage = S;
    root.loadSecurity = S.load;
  }
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // ── pure helpers (tested) ──────────────────────────────────────────────────

  // "All quiet" / "1 open alert" / "2 open alerts"; '' before anything loaded.
  function securityStatusLine(status) {
    if (!status) return '';
    const n = Number(status.open_alerts) || 0;
    if (n === 0) return 'All quiet';
    return n === 1 ? '1 open alert' : `${n} open alerts`;
  }

  // source: "device" | "host" | "agent" | "all"; level: "alert" | "block" | "digest" | "all"
  // (matched against the event's outcome).
  function filterEvents(events, filters) {
    const f = filters || {};
    const source = f.source || 'all';
    const level = f.level || 'all';
    return (Array.isArray(events) ? events : []).filter(e => e &&
      (source === 'all' || e.source === source) &&
      (level === 'all' || e.outcome === level));
  }

  // ── page state ─────────────────────────────────────────────────────────────

  const BASE = '/api/security';
  const SOURCES = [['all', 'All'], ['device', 'Devices'], ['host', 'Server'], ['agent', 'Agent']];
  const LEVELS = [['all', 'All'], ['alert', 'Alerts'], ['block', 'Blocks'], ['digest', 'Digest']];
  const FILTER_KEY = 'jarviscopilot-security-filters';
  const SEC = {
    status: null, alerts: [], events: [], blocks: [], digests: [], settings: null,
    errors: {}, filters: { source: 'all', level: 'all' }, saving: false, loaded: false,
  };

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }
  // A value inside an inline handler: JSON-quoted, then HTML-escaped.
  function jsArg(v) { return esc(JSON.stringify(String(v == null ? '' : v))); }
  function el(id) { return document.getElementById(id); }
  function toast(msg) { if (typeof showToast === 'function') showToast(msg); }

  // A list answer may be a bare array or wrapped ({events: [...]}, {items: [...]}).
  function rows(v, key) {
    if (Array.isArray(v)) return v;
    if (v && Array.isArray(v[key])) return v[key];
    if (v && Array.isArray(v.items)) return v.items;
    return [];
  }

  // ISO string, or epoch seconds / ms → "Nov 8, 3:04 AM"; '' when unknown.
  function when(v) {
    if (v === null || v === undefined || v === '') return '';
    let d;
    if (typeof v === 'number') d = new Date(v < 1e12 ? v * 1000 : v);
    else d = new Date(v);
    if (isNaN(d)) return String(v);
    return d.toLocaleString(undefined, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
  }

  function loadFilters() {
    try {
      const f = JSON.parse(localStorage.getItem(FILTER_KEY) || '{}');
      if (SOURCES.some(s => s[0] === f.source)) SEC.filters.source = f.source;
      if (LEVELS.some(s => s[0] === f.level)) SEC.filters.level = f.level;
    } catch (_) { /* per-viewer convenience only */ }
  }
  function saveFilters() {
    try { localStorage.setItem(FILTER_KEY, JSON.stringify(SEC.filters)); } catch (_) {}
  }

  // ── loading ────────────────────────────────────────────────────────────────

  async function load(refresh) {
    const box = el('securityContent');
    if (!box) return;
    if (!SEC.loaded) { loadFilters(); box.innerHTML = '<div class="sec-empty">Loading…</div>'; }
    const btn = el('securityRefreshBtn');
    if (refresh && btn) btn.disabled = true;
    const calls = {
      status: api(`${BASE}/status`),
      alerts: api(`${BASE}/alerts?status=open`),
      events: api(`${BASE}/events?limit=200`),
      blocks: api(`${BASE}/blocks`),
      digests: api(`${BASE}/digests`),
      settings: api(`${BASE}/settings`),
    };
    const keys = Object.keys(calls);
    const settled = await Promise.allSettled(keys.map(k => calls[k]));
    SEC.errors = {};
    settled.forEach((r, i) => {
      const k = keys[i];
      if (r.status === 'rejected') { SEC.errors[k] = (r.reason && r.reason.message) || 'failed'; return; }
      const v = r.value;
      if (k === 'status') SEC.status = v || null;
      else if (k === 'settings') SEC.settings = v || null;
      else SEC[k] = rows(v, k);
    });
    SEC.loaded = true;
    if (refresh && btn) btn.disabled = false;
    render();
  }

  // ── rendering ──────────────────────────────────────────────────────────────

  function render() {
    const box = el('securityContent');
    if (!box) return;
    box.innerHTML = '<div class="sec-page">' + [
      statusSection(), alertsSection(), eventsSection(), blocksSection(), digestsSection(), settingsSection(),
    ].join('') + '</div>';
    const side = el('securitySideStatus');
    if (side) side.textContent = securityStatusLine(SEC.status) || (SEC.errors.status ? 'Unavailable' : '');
  }

  function label(text, extra) {
    return `<div class="sec-label"><span>${esc(text)}</span>${extra ? `<span class="sec-label-extra">${extra}</span>` : ''}</div>`;
  }

  function failed(key) {
    return SEC.errors[key] ? `<div class="sec-card"><div class="sec-error">Couldn't load: ${esc(SEC.errors[key])}</div></div>` : '';
  }

  function statusSection() {
    if (SEC.errors.status && !SEC.status) return label('Status') + failed('status');
    const s = SEC.status || {};
    const src = s.sources || {};
    const facts = [];
    if (src.ssh) facts.push(`SSH watch ${esc(src.ssh)}`);
    if (src.files) facts.push(`file watch ${esc(src.files)}`);
    if (s.chain_ok === false) facts.push('<span class="sec-warn">event log chain broken</span>');
    else if (s.chain_ok === true) facts.push('event log intact');
    const blocks = Number(s.blocks) || 0;
    if (blocks) facts.push(`${blocks} IP${blocks === 1 ? '' : 's'} blocked`);
    const last = s.last_event ? `Last event ${esc(when(s.last_event.ts || s.last_event))}` : '';
    return label('Status', '') + `<div class="sec-card sec-status">
      <div class="sec-status-line${Number(s.open_alerts) > 0 ? ' is-alert' : ''}">${esc(securityStatusLine(s) || '—')}</div>
      ${facts.length ? `<div class="sec-sub">${facts.join(' · ')}</div>` : ''}
      ${last ? `<div class="sec-sub">${last}</div>` : ''}
    </div>`;
  }

  function alertsSection() {
    const open = SEC.alerts.filter(a => !a.status || a.status === 'open');
    if (SEC.errors.alerts) return label('Open alerts') + failed('alerts');
    if (!open.length) return '';
    return label('Open alerts', String(open.length)) + open.map(a => {
      const sev = a.severity ? `<span class="sec-pill">${esc(a.severity)}</span>` : '';
      const count = Number(a.count) > 1 ? `<span class="sec-pill">×${esc(a.count)}</span>` : '';
      const text = a.explanation || a.summary || '';
      return `<div class="sec-card sec-alert">
        <div class="sec-alert-head"><div class="sec-title">${esc(a.title || a.rule || 'Alert')}</div><div class="sec-pills">${sev}${count}</div></div>
        ${a.summary && a.explanation ? `<div class="sec-sub">${esc(a.summary)}</div>` : ''}
        ${text ? `<div class="sec-text">${esc(text)}</div>` : ''}
        <div class="sec-sub">${esc(when(a.updated || a.created))}</div>
        <div class="sec-actions">
          <button type="button" class="sec-btn" onclick="SecurityPage.phoneOnly('Block')">Block</button>
          <button type="button" class="sec-btn" onclick="SecurityPage.phoneOnly('Allow')">Allow</button>
          <button type="button" class="sec-btn" onclick="SecurityPage.dismiss(${jsArg(a.id)})">Dismiss</button>
          <span class="sec-hint">Block and Allow: approve on your iPhone</span>
        </div>
      </div>`;
    }).join('');
  }

  function segmented(name, options, value) {
    return `<div class="sec-seg" role="tablist" aria-label="${esc(name)}">` + options.map(([v, text]) =>
      `<button type="button" role="tab" class="sec-seg-btn${v === value ? ' active' : ''}" aria-selected="${v === value}"
        onclick="SecurityPage.setFilter(${jsArg(name)}, ${jsArg(v)})">${esc(text)}</button>`).join('') + '</div>';
  }

  function eventsSection() {
    const list = filterEvents(SEC.events, SEC.filters);
    const head = label('Events', SEC.events.length ? `${list.length} of ${SEC.events.length}` : '');
    const filters = `<div class="sec-filters">${segmented('source', SOURCES, SEC.filters.source)}${segmented('level', LEVELS, SEC.filters.level)}</div>`;
    if (SEC.errors.events) return head + filters + failed('events');
    const body = list.length ? list.map(e => `<div class="sec-row">
        <div class="sec-row-main">
          <div class="sec-row-title">${esc(e.kind || 'event')}</div>
          <div class="sec-sub">${esc([e.actor, when(e.ts)].filter(Boolean).join(' · '))}</div>
        </div>
        ${e.outcome && e.outcome !== 'ignore' ? `<span class="sec-pill sec-out-${esc(e.outcome)}">${esc(e.outcome)}</span>` : ''}
      </div>`).join('') : '<div class="sec-empty">No events match.</div>';
    return head + filters + `<div class="sec-card sec-list">${body}</div>`;
  }

  function blocksSection() {
    if (SEC.errors.blocks) return label('Blocked') + failed('blocks');
    const body = SEC.blocks.length ? SEC.blocks.map(b => `<div class="sec-row">
        <div class="sec-row-main">
          <div class="sec-row-title sec-mono">${esc(b.ip)}</div>
          <div class="sec-sub">${esc([b.reason, b.until ? 'until ' + when(b.until) : ''].filter(Boolean).join(' · '))}</div>
        </div>
        <button type="button" class="sec-btn" onclick="SecurityPage.undoBlock(${jsArg(b.ip)})">Undo</button>
      </div>`).join('') : '<div class="sec-empty">Nothing is blocked.</div>';
    return label('Blocked') + `<div class="sec-card sec-list">${body}</div>`;
  }

  function digestsSection() {
    if (SEC.errors.digests) return label('Digests') + failed('digests');
    if (!SEC.digests.length) return '';
    return label('Digests') + `<div class="sec-card sec-list">` + SEC.digests.slice(0, 7).map(d => {
      const text = d.text || d.summary || d.body || '';
      const at = d.date || d.day || d.created || d.ts || '';
      return `<div class="sec-row sec-digest"><div class="sec-row-main">
        <div class="sec-row-title">${esc(typeof at === 'string' && at.length === 10 ? at : when(at))}</div>
        ${text ? `<div class="sec-text">${esc(text)}</div>` : ''}
      </div></div>`;
    }).join('') + '</div>';
  }

  // ── settings ───────────────────────────────────────────────────────────────

  // A model entry may be a string ("@provider:model" / "model") or an object.
  function modelOption(m) {
    if (typeof m === 'string') {
      const at = m.startsWith('@') ? m.slice(1) : '';
      const i = at.indexOf(':');
      return i > 0 ? { provider: at.slice(0, i), model: at.slice(i + 1), label: at.slice(i + 1) }
                   : { provider: '', model: m, label: m };
    }
    const model = m.model || m.id || m.name || '';
    return { provider: m.provider || '', model, label: m.label || m.title || m.name || model };
  }
  function modelKey(p, m) { return `${p || ''}|${m || ''}`; }

  function hourOptions(selected) {
    let out = '';
    for (let h = 0; h < 24; h++) {
      const text = new Date(2000, 0, 1, h).toLocaleTimeString(undefined, { hour: 'numeric' });
      out += `<option value="${h}"${Number(selected) === h ? ' selected' : ''}>${esc(text)}</option>`;
    }
    return out;
  }

  function pair(v, fallback) {
    return Array.isArray(v) && v.length === 2 ? v : fallback;
  }

  // Every rule the page can toggle: the server's list when it sends one, else the
  // ones it has disabled plus any an alert named.
  function ruleList(resp, s) {
    const out = new Map();
    rows(resp.rules || s.rules, 'rules').forEach(r => {
      const id = typeof r === 'string' ? r : (r.id || r.name);
      if (id) out.set(id, typeof r === 'string' ? r : (r.title || r.label || id));
    });
    (s.disabled_rules || []).forEach(id => { if (!out.has(id)) out.set(id, id); });
    SEC.alerts.forEach(a => { if (a.rule && !out.has(a.rule)) out.set(a.rule, a.rule); });
    return [...out.entries()];
  }

  function settingsSection() {
    if (SEC.errors.settings && !SEC.settings) return label('Settings') + failed('settings');
    const resp = SEC.settings || {};
    const s = resp.settings || {};
    const cur = resp.model || {};
    const models = (resp.models || []).map(modelOption).filter(m => m.model);
    if (cur.model && !models.some(m => modelKey(m.provider, m.model) === modelKey(cur.provider, cur.model))) {
      models.unshift({ provider: cur.provider || '', model: cur.model, label: cur.model });
    }
    const quiet = pair(s.quiet_hours, [22, 7]);
    const usual = pair(s.usual_hours, [7, 23]);
    const disabled = new Set(s.disabled_rules || []);
    const rules = ruleList(resp, s);
    const field = (title, sub, control) => `<div class="sec-row sec-field">
      <div class="sec-row-main"><div class="sec-row-title">${esc(title)}</div>${sub ? `<div class="sec-sub">${esc(sub)}</div>` : ''}</div>
      <div class="sec-control">${control}</div></div>`;
    const num = (id, v, min, max) => `<input class="sec-input" type="number" id="${id}" min="${min}" max="${max}" value="${esc(v)}">`;
    return label('Settings') + `<div class="sec-card sec-list" id="securitySettings">
      ${field('Model', 'Explains flagged events. Blocks never wait for it.',
        `<select class="sec-input" id="secModel">${models.map(m =>
          `<option value="${esc(modelKey(m.provider, m.model))}"${modelKey(m.provider, m.model) === modelKey(cur.provider, cur.model) ? ' selected' : ''}>${esc(m.label)}${m.provider ? ' · ' + esc(m.provider) : ''}</option>`).join('')}</select>`)}
      ${field('Phone alerts per hour', 'The rest wait here and in the digest.', num('secAlertCap', s.alert_cap_per_hour ?? 3, 0, 60))}
      ${field('Daily digest', '', `<select class="sec-input" id="secDigestHour">${hourOptions(s.digest_hour ?? 8)}</select>`)}
      ${field('Quiet hours', 'No phone alerts between these hours.',
        `<select class="sec-input" id="secQuietFrom">${hourOptions(quiet[0])}</select><span class="sec-to">to</span><select class="sec-input" id="secQuietTo">${hourOptions(quiet[1])}</select>`)}
      ${field('Usual car and door hours', 'Car or door use outside these is flagged.',
        `<select class="sec-input" id="secUsualFrom">${hourOptions(usual[0])}</select><span class="sec-to">to</span><select class="sec-input" id="secUsualTo">${hourOptions(usual[1])}</select>`)}
      ${field('Block an IP for', 'Hours.', num('secBlockTtl', s.block_ttl_hours ?? 24, 1, 720))}
      ${rules.length ? `<div class="sec-subhead">Rules</div>` + rules.map(([id, text]) => field(text, id !== text ? id : '',
        `<label class="sec-switch"><input type="checkbox" data-rule="${esc(id)}"${disabled.has(id) ? '' : ' checked'}><span></span></label>`)).join('') : ''}
      <div class="sec-save-row"><button type="button" class="sec-btn sec-btn-main" id="secSaveBtn" onclick="SecurityPage.saveSettings()"${SEC.saving ? ' disabled' : ''}>Save settings</button></div>
    </div>`;
  }

  function readSettingsForm() {
    const intOf = (id, fallback) => {
      const n = parseInt((el(id) || {}).value, 10);
      return isNaN(n) ? fallback : n;
    };
    const s = (SEC.settings && SEC.settings.settings) || {};
    const disabled = [];
    document.querySelectorAll('#securitySettings input[data-rule]').forEach(cb => {
      if (!cb.checked) disabled.push(cb.getAttribute('data-rule'));
    });
    const [provider, ...rest] = String((el('secModel') || {}).value || '|').split('|');
    return {
      settings: {
        alert_cap_per_hour: intOf('secAlertCap', s.alert_cap_per_hour ?? 3),
        digest_hour: intOf('secDigestHour', s.digest_hour ?? 8),
        quiet_hours: [intOf('secQuietFrom', 22), intOf('secQuietTo', 7)],
        usual_hours: [intOf('secUsualFrom', 7), intOf('secUsualTo', 23)],
        block_ttl_hours: intOf('secBlockTtl', s.block_ttl_hours ?? 24),
        disabled_rules: disabled,
      },
      model: { provider, model: rest.join('|') },
    };
  }

  // ── actions ────────────────────────────────────────────────────────────────

  function setFilter(name, value) {
    if (name !== 'source' && name !== 'level') return;
    SEC.filters[name] = value;
    saveFilters();
    render();
  }

  function phoneOnly(action) {
    toast(`${action} needs Face ID — approve it on your iPhone (More → Security).`);
  }

  async function dismiss(id) {
    try {
      await api(`${BASE}/alerts/${encodeURIComponent(id)}/resolve`, { method: 'POST', body: JSON.stringify({ action: 'dismiss' }) });
      toast('Alert dismissed');
    } catch (e) {
      toast(`Couldn't dismiss: ${e.message}`);
    }
    await load();
  }

  async function undoBlock(ip) {
    try {
      await api(`${BASE}/blocks/${encodeURIComponent(ip)}/undo`, { method: 'POST', body: '{}' });
      toast(`${ip} unblocked`);
    } catch (e) {
      toast(`Couldn't undo: ${e.message}`);
    }
    await load();
  }

  async function saveSettings() {
    const body = readSettingsForm();
    SEC.saving = true;
    const btn = el('secSaveBtn');
    if (btn) btn.disabled = true;
    try {
      await api(`${BASE}/settings`, { method: 'POST', body: JSON.stringify(body) });
      toast('Security settings saved');
    } catch (e) {
      toast(`Couldn't save: ${e.message}`);
    } finally {
      SEC.saving = false;
    }
    await load();
  }

  return { securityStatusLine, filterEvents, load, setFilter, phoneOnly, dismiss, undoBlock, saveSettings };
});

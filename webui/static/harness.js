// Agent harnesses: the header chip (Chat composer + Voice), its picker sheet
// and the per-turn harness id. The server validates and stores harnesses
// (api/harnesses); this file only reads them and records which one is in use.
//
//   chat current  = the open chat's own harness_id, else the Chat default
//   voice current = the Voice default
//
// Picking for Chat sets the open chat's harness (POST api/session/harness);
// picking for Voice changes the Voice default (POST api/harnesses/assign).
(function () {
  const DEFAULTS = { voice: 'fast-claude', chat: 'single' };
  // pendingChat: a pick made before any chat exists. It rides the first turn
  // (chat/start pins it on the new chat) instead of changing the Chat default.
  const H = { data: { harnesses: [], assignments: Object.assign({}, DEFAULTS) }, loaded: false, sheetSurface: null, pendingChat: null };

  // ui.js declares `const S` at top level: reachable by name, never on window.
  function session() {
    return (typeof S !== 'undefined' && S && S.session) ? S.session : null;
  }

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }

  async function load() {
    try {
      const data = await api('api/harnesses');
      if (data && Array.isArray(data.harnesses)) {
        H.data = { harnesses: data.harnesses, assignments: Object.assign({}, DEFAULTS, data.assignments || {}) };
        H.loaded = true;
      }
    } catch (e) { console.warn('[harness] load failed', e); }
    render();
    if (H.sheetSurface) renderSheet(H.sheetSurface);
    return H.data;
  }

  const list = () => H.data.harnesses || [];
  const byId = id => list().find(h => h.id === id) || null;

  // A chat nothing has been said in yet (or no chat at all).
  function isFreshChat(s) {
    return !s || !((s.messages && s.messages.length) || s.message_count);
  }

  // The pick made before a chat existed, if it belongs to the open chat. It
  // binds only to a fresh chat (the one its first send creates) — opening an
  // existing chat from the sidebar drops it instead of pinning it there.
  function pendingPick() {
    const p = H.pendingChat;
    if (!p) return null;
    const s = session();
    if (p.sid && s && p.sid === s.session_id) return p.id;
    if (!p.sid && isFreshChat(s)) {
      if (s && s.session_id) p.sid = s.session_id;  // bind to the chat it created
      return p.id;
    }
    if (!p.sid) H.pendingChat = null;
    return null;
  }

  function currentFor(surface) {
    if (surface === 'chat') {
      const s = session();
      if (s && s.harness_id) return s.harness_id;
      return pendingPick() || H.data.assignments.chat || DEFAULTS.chat;
    }
    return H.data.assignments.voice || DEFAULTS.voice;
  }

  async function select(surface, id) {
    const s = session();
    if (surface === 'chat') {
      if (s && s.session_id) {
        const r = await api('api/session/harness', { method: 'POST', body: JSON.stringify({ session_id: s.session_id, harness_id: id }) });
        s.harness_id = (r && r.harness_id) || id;
        H.pendingChat = null;
      } else {
        H.pendingChat = { id, sid: null };
      }
    } else {
      const r = await api('api/harnesses/assign', { method: 'POST', body: JSON.stringify({ surface, harness_id: id }) });
      if (r && r.assignments) H.data.assignments = Object.assign({}, DEFAULTS, r.assignments);
    }
    render();
  }

  function label(id) {
    const h = byId(id);
    return h ? `${h.icon || ''} ${h.name || h.id}`.trim() : String(id || '');
  }

  // Single model in Chat names the model itself: that is what will answer.
  function chipText(surface) {
    const id = currentFor(surface);
    if (surface === 'chat' && id === 'single') {
      const modelLabel = document.getElementById('composerModelLabel');
      const text = modelLabel && modelLabel.textContent.trim();
      if (text) { const h = byId('single'); return `${(h && h.icon) || '●'} ${text}`; }
    }
    return label(id);
  }

  function render() {
    [['chat', 'harnessChipChat', 'harnessMobileLabel'], ['voice', 'harnessChipVoice', null]].forEach(([surface, chipId, extraId]) => {
      const text = chipText(surface);
      const h = byId(currentFor(surface));
      const warn = !!(h && (h.problems || []).length);
      const el = document.getElementById(chipId);
      if (el) {
        const lab = el.querySelector('.harness-chip-label');
        if (lab) lab.textContent = text;
        el.title = (surface === 'chat' ? 'Chat harness: ' : 'Voice harness: ') + text + (warn ? ' (has problems)' : '');
        el.classList.toggle('warn', warn);
        el.setAttribute('aria-expanded', H.sheetSurface === surface ? 'true' : 'false');
      }
      const extra = extraId && document.getElementById(extraId);
      if (extra) extra.textContent = text;
    });
  }

  // A row of dots, one per step after the Message node, tinted by step type.
  function mini(h) {
    const nodes = (h.nodes || []).filter(n => n.type !== 'message');
    return '<span class="harness-mini" aria-hidden="true">' +
      nodes.map(n => `<i class="t-${esc(n.type)}"></i>`).join('<s></s>') + '</span>';
  }

  function renderSheet(surface) {
    const sheet = document.getElementById('harnessSheet');
    if (!sheet) return;
    const cur = currentFor(surface);
    const rows = list().map(h => {
      const problems = h.problems || [];
      const warn = problems.length
        ? `<span class="harness-row-warn" title="${esc(problems[0].message || 'Has problems')}">⚠︎</span>` : '';
      const on = h.id === cur;
      return `<button type="button" class="harness-row${on ? ' on' : ''}" role="menuitemradio" aria-checked="${on}" data-id="${esc(h.id)}">
          <span class="harness-row-icon" aria-hidden="true">${esc(h.icon || '●')}</span>
          <span class="harness-row-name">${esc(h.name || h.id)}${warn}</span>${mini(h)}
          <span class="harness-row-check" aria-hidden="true">${on ? '✓' : ''}</span></button>`;
    }).join('');
    const title = surface === 'chat' ? 'Harness for this chat' : 'Voice harness';
    sheet.innerHTML = `<div class="harness-sheet-card" role="dialog" aria-modal="true" aria-label="${esc(title)}">
        <div class="harness-sheet-title">${esc(title)}</div>
        <div class="harness-sheet-rows" role="menu">${rows || '<div class="harness-sheet-empty">Loading harnesses…</div>'}</div>
        <div class="harness-sheet-actions">
          ${surface === 'chat' ? '<button type="button" class="harness-row harness-row-action" data-action="single">Single model…</button>' : ''}
          <button type="button" class="harness-row harness-row-action accent" data-action="edit">Edit harnesses…</button>
        </div></div>`;
  }

  function closeSheet() {
    const sheet = document.getElementById('harnessSheet');
    if (sheet) sheet.hidden = true;
    H.sheetSurface = null;
    render();
  }

  function openSheet(surface) {
    const sheet = document.getElementById('harnessSheet');
    if (!sheet) return;
    if (typeof closeModelDropdown === 'function') closeModelDropdown();
    if (typeof closeMobileComposerConfig === 'function') closeMobileComposerConfig();
    H.sheetSurface = surface;
    renderSheet(surface);
    sheet.onclick = async ev => {
      if (ev.target === sheet) { closeSheet(); return; }
      const row = ev.target.closest('.harness-row');
      if (!row) return;
      closeSheet();
      try {
        if (row.dataset.action === 'edit') {
          if (window.HarnessEditor) window.HarnessEditor.open();
          return;
        }
        if (row.dataset.action === 'single') {
          await select('chat', 'single');
          // Phone width hides the footer chip; the model list then anchors to
          // the overflow panel's Model row, so open that panel first.
          const chip = document.getElementById('harnessChipChat');
          const panel = document.getElementById('composerMobileConfigPanel');
          if (!(chip && chip.offsetParent) && panel && !panel.classList.contains('open') &&
              typeof toggleMobileComposerConfig === 'function') toggleMobileComposerConfig();
          if (typeof toggleModelDropdown === 'function') await toggleModelDropdown();
          return;
        }
        await select(surface, row.dataset.id);
      } catch (e) {
        console.warn('[harness] select failed', e);
        if (typeof showToast === 'function') showToast('Could not switch harness: ' + (e && e.message || e), 4000, 'error');
      }
    };
    sheet.hidden = false;
    render();
    const first = sheet.querySelector('.harness-row.on') || sheet.querySelector('.harness-row');
    if (first) first.focus({ preventScroll: true });
    // Refresh in the background: another device may have edited or switched.
    load();
  }

  document.addEventListener('keydown', ev => {
    if (ev.key === 'Escape' && H.sheetSurface) closeSheet();
  });

  // What a chat turn sends as harness_id: the chat's own harness (or a pick made
  // before the chat existed), else '' = "follow the Chat default". Sending the
  // default itself would make the server save it onto the chat for good.
  function turnHarnessFor(surface) {
    // Voice: '' until the list has loaded, so the server's Voice default wins.
    if (surface !== 'chat') return H.loaded ? currentFor(surface) : '';
    // Chat: only a pick made before the chat existed. A pick on an existing
    // chat is already saved (api/session/harness); re-sending a possibly stale
    // copy every turn would overwrite a newer pick made on another device.
    return pendingPick() || '';
  }


  window.Harness = { load, list, currentFor, turnHarnessFor, select, openSheet, closeSheet, byId, label, render };
  document.addEventListener('DOMContentLoaded', load);
})();

/* ============================================================================
 * Agents panel — every Claude and Codex session on the Mac and the server in
 * one list (webui/api/agents_core.py), with the picked session's chat, its
 * approval and question cards, a message box and a terminal drawer.
 *
 * Replaces the old Coding panel. Left column, top to bottom: the plan-usage
 * strip, the Mac-asleep card (only while it applies), "Needs you" (a flat list
 * of whatever waits on an approval or a question) and the projects as
 * collapsible groups. Right column: the session. Below 760 px it shows the list
 * OR the session, with a back button.
 *
 * The web has no bridge socket, so it polls GET /api/coding/agents/list (and
 * the pending approval cards) every 5 s — only while this panel is on screen
 * and the browser tab is visible.
 *
 * Entry points (panels.js): loadAgents() when the panel opens,
 * onAgentsPanelLeave() when it closes.
 * ========================================================================== */
(function () {
  'use strict';

  const API = '/api/coding';
  const POLL_MS = 5000;
  const PAGE = 40;
  const FLASH_MS = 7000;
  const COLLAPSE_KEY = 'jc.agents.collapsedProjects';
  // Integration groups (an integration's background runs) start collapsed; these are the ones opened.
  const OPEN_INTEGRATIONS_KEY = 'jc.agents.openIntegrations';
  const TERM_H_KEY = 'jc.agents.termHeight';
  const TERM_H_DEFAULT = 300;
  const SETTLED_MS = 15000;   // a decided card stays hidden this long while the hooks catch up

  const AGENT_NAMES = {
    claude: 'Claude', 'claude-desktop': 'Claude', codex: 'Codex', gemini: 'Gemini',
    copilot: 'Copilot', cursor: 'Cursor', opencode: 'OpenCode', amp: 'Amp',
    antigravity: 'Antigravity', muse: 'Muse', jarvis: 'Jarvis',
  };
  const TERMINAL_APPS = {
    vscode: 'VS Code', 'iterm.app': 'iTerm', apple_terminal: 'Terminal', ghostty: 'Ghostty',
    wezterm: 'WezTerm', warpterminal: 'Warp', cursor: 'Cursor', zed: 'Zed', tmux: 'tmux',
  };
  const PERMISSION_MODES = [
    ['', 'Ask before risky actions'], ['acceptEdits', 'Accept edits'], ['plan', 'Plan first'],
    ['auto', 'Auto'], ['bypassPermissions', 'Skip all permission checks'],
  ];

  // ── state ──────────────────────────────────────────────────────────────
  const st = {
    active: false, timer: 0, soon: 0, inflight: false, flashTimer: 0,
    list: null, error: '', requests: [],
    lastConv: {},          // ckey -> last seen conv (a session that left the list stays readable)
    selected: null,        // ckey of the open session
    pane: 'empty',         // right column: 'empty' | 'session' | 'launch'
    view: 'list',          // narrow layout: 'list' | 'session'
    chats: {},             // ckey -> {messages, start, total, loading, fetching, olderLoading, error}
    details: {},           // ckey -> {i: full message | 'loading' | 'none'}
    openTools: new Set(),  // "<ckey>:<i>:<ti>" of expanded tool rows
    outgoing: {},          // ckey -> [{id, text, norm, state, reason, baseEnd, deliveryId}]
    delivered: {},         // ckey -> Set of transcript indices that arrived from here
    drafts: {},            // ckey -> unsent text
    picks: {},             // request_id -> {question: [labels]}
    denying: {},           // decision key -> true while the deny note is open
    denyNote: {},          // decision key -> note text
    decisionErr: {},       // decision key -> error line
    settled: {},           // request_id / fingerprint -> when it was decided here
    confirm: null,         // {ckeys, to, scope, name} offline-Mac continue awaiting a yes
    stopConfirm: false,
    menuOpen: false,
    flash: null,           // {scope: 'list'|'card'|'session', text, tone, until}
    busy: {},
    moving: new Set(),     // ckeys a Continue is on its way for (one move per session at a time)
    termOpen: false, termCkey: null,
    projSync: {}, projSyncLoading: false,
    devices: null,
    deepCkey: null,
    collapsed: _loadCollapsed(),
    openIntegrations: _loadSet(OPEN_INTEGRATIONS_KEY),
    seq: 0,
  };

  // ── small helpers ──────────────────────────────────────────────────────
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
  }
  function $(id) { return document.getElementById(id); }
  function storeGet(key) { try { return window.localStorage.getItem(key); } catch (_) { return null; } }
  function storeSet(key, val) { try { window.localStorage.setItem(key, val); } catch (_) { /* private mode */ } }
  function _loadCollapsed() {
    try { return new Set(JSON.parse(storeGet(COLLAPSE_KEY) || '[]')); } catch (_) { return new Set(); }
  }
  function _loadSet(key) {
    try { return new Set(JSON.parse(storeGet(key) || '[]')); } catch (_) { return new Set(); }
  }
  function firstLine(text, limit) {
    const max = limit || 140;
    const line = (String(text || '').split(/\r?\n/).find((l) => l.trim()) || '').trim();
    return line.length > max ? line.slice(0, max - 1) + '…' : line;
  }
  function basename(p) { return String(p || '').replace(/\/+$/, '').split('/').pop() || ''; }
  function norm(text) { return String(text || '').replace(/\s+/g, ' ').trim(); }
  function agentName(a) { return AGENT_NAMES[a] || (a ? a.charAt(0).toUpperCase() + a.slice(1) : 'Claude'); }
  function terminalApp(tp) { const k = String(tp || '').toLowerCase(); return TERMINAL_APPS[k] || ''; }
  function encQ(o) {
    return Object.keys(o).filter((k) => o[k] !== undefined && o[k] !== null)
      .map((k) => encodeURIComponent(k) + '=' + encodeURIComponent(o[k])).join('&');
  }
  function errText(e, fallback) {
    try {
      const j = JSON.parse((e && e.body) || '{}');
      if (j && (j.error || j.message)) return j.error || j.message;
    } catch (_) { /* not JSON */ }
    return (e && e.message) || fallback;
  }
  function post(path, body) {
    return api(API + path, { method: 'POST', body: JSON.stringify(body || {}) });
  }
  function toMs(ts) {
    const n = Number(ts);
    if (!n) return 0;
    return n > 1e12 ? n : n * 1000;
  }
  function ago(ts) {
    const ms = toMs(ts);
    if (!ms) return '';
    const s = Math.max(0, Math.floor((Date.now() - ms) / 1000));
    if (s < 60) return 'now';
    const m = Math.floor(s / 60);
    if (m < 60) return m + 'm';
    const h = Math.floor(m / 60);
    if (h < 24) return h + 'h';
    return Math.floor(h / 24) + 'd';
  }
  function clock(ts) {
    const ms = toMs(ts);
    if (!ms) return '';
    const d = new Date(ms);
    const sameDay = new Date().toDateString() === d.toDateString();
    const time = d.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
    return sameDay ? time : d.toLocaleDateString(undefined, { weekday: 'short' }) + ' ' + time;
  }
  // Replace an element's markup only when it changed; says whether it did.
  function setHtml(el, html) {
    if (!el || el._agentsHtml === html) return false;
    el.innerHTML = html;
    el._agentsHtml = html;
    return true;
  }
  function isQuestionKind(k) { return k === 'ask' || k === 'question'; }

  // ── how a tool reads ("Ran npm test", "Edited agents.js") ──────────────
  // [imperative, progressive, past, object kind, monospaced]
  const VERBS = {
    Bash: ['run', 'Running', 'Ran', 'line', true],
    BashOutput: ['run', 'Running', 'Ran', 'line', true],
    Read: ['read', 'Reading', 'Read', 'file'],
    NotebookRead: ['read', 'Reading', 'Read', 'file'],
    Edit: ['edit', 'Editing', 'Edited', 'file'],
    MultiEdit: ['edit', 'Editing', 'Edited', 'file'],
    NotebookEdit: ['edit', 'Editing', 'Edited', 'file'],
    Write: ['write', 'Writing', 'Wrote', 'file'],
    Grep: ['search for', 'Searching for', 'Searched for', 'line', true],
    Glob: ['find files', 'Finding files', 'Found files', 'line', true],
    WebSearch: ['search the web for', 'Searching the web for', 'Searched the web for', 'line'],
    WebFetch: ['fetch', 'Fetching', 'Fetched', 'host'],
    Task: ['start an agent:', 'Running an agent:', 'Ran an agent:', 'line'],
    Agent: ['start an agent:', 'Running an agent:', 'Ran an agent:', 'line'],
    TodoWrite: ['update the plan', 'Updating the plan', 'Updated the plan', 'none'],
    ExitPlanMode: ['propose a plan', 'Proposing a plan', 'Proposed a plan', 'none'],
    AskUserQuestion: ['ask', 'Asking', 'Asked', 'line'],
  };
  const TENSE = { imperative: 0, progressive: 1, past: 2 };

  function toolName(tool) {
    if (!String(tool).startsWith('mcp__')) return tool;
    return tool.slice(5).split('__').map((p) => p.replace(/_/g, ' ')).filter(Boolean).join(' ');
  }
  function toolDetail(tool, summary) {
    const s = String(summary || '').trim();
    for (const prefix of [tool + ':', tool + ' ']) {
      if (tool && s.startsWith(prefix)) return s.slice(prefix.length).trim();
    }
    return s;
  }
  function toolLine(tool, summary, tense) {
    const v = VERBS[tool] || ['use', 'Using', 'Used', 'raw'];
    const detail = toolDetail(tool, summary);
    let object = '';
    if (v[3] === 'file') object = basename(detail) || firstLine(detail);
    else if (v[3] === 'line') object = firstLine(detail, 120);
    else if (v[3] === 'host') {
      try { object = new URL(detail).host || firstLine(detail, 120); } catch (_) { object = firstLine(detail, 120); }
    } else if (v[3] === 'raw') object = [toolName(tool), firstLine(detail, 120)].filter(Boolean).join(' ');
    return { verb: v[TENSE[tense] || 0], object, mono: !!v[4] };
  }
  function lineText(l) { return l.object ? l.verb + ' ' + l.object : l.verb; }

  // "Bash: npm test" -> "Running npm test…" for the tools whose labels name them.
  function liveStep(step) {
    const line = firstLine(step);
    if (!line) return 'Thinking…';
    const tool = (line.match(/^[^: ]+/) || [''])[0];
    if (!['Bash', 'Read', 'Edit', 'MultiEdit', 'Write', 'NotebookEdit'].includes(tool)) return line;
    return lineText(toolLine(tool, line, 'progressive')) + '…';
  }

  // One line for what a session waits on.
  function askText(kind, questions, tool, what) {
    if (isQuestionKind(kind)) {
      const q = firstLine(((questions || [])[0] || {}).question || '');
      return q || 'Has a question';
    }
    if (!what && !tool) return 'Needs approval';
    return 'Wants to ' + lineText(toolLine(tool, what, 'imperative'));
  }
  function askOfRequest(r) { return askText(r.kind, r.questions, r.tool, r.command || r.summary); }
  function askOfPending(p) { return askText(p.kind, p.questions, p.tool, p.summary); }

  // ── the list's rules (ported from the iPhone's AgentsListLayout) ───────
  function allConvs() {
    const l = st.list || {};
    const out = (l.needs_you || []).slice();
    (l.projects || []).forEach((g) => (g.sessions || []).forEach((c) => out.push(c)));
    return out;
  }
  function conv(ckey) {
    if (!ckey) return null;
    return allConvs().find((c) => c.ckey === ckey) || null;
  }
  function currentConv() {
    const live = conv(st.selected);
    if (live) return live;
    const old = st.lastConv[st.selected];
    return old ? Object.assign({}, old, { gone: true, can_send: false, can_terminal: false,
      can_continue_server: false, can_continue_mac: false, can_resume: false }) : null;
  }
  function titleOf(c) { return c.title || c.project || basename(c.cwd) || 'Session'; }
  function onServer(c) { return c.owner === 'server'; }
  function macName(c) { return (!c.owner_name || onServer(c)) ? (c.moved_from_name || 'Mac') : c.owner_name; }
  function waitsOnYou(c) {
    return c.status === 'live' && (!!livePending(c) || c.state === 'approval' || c.state === 'question');
  }
  function whereLabel(c) {
    if (onServer(c)) return 'Server';
    const name = c.owner_name || 'Mac';
    if (c.status === 'asleep') return name + ' (asleep)';
    if (c.status === 'offline') return name + ' (offline)';
    return name;
  }
  function subtitle(c, showsProject) {
    const parts = [];
    if (showsProject && c.project && c.project !== titleOf(c)) parts.push(c.project);
    parts.push(agentName(c.agent));
    parts.push(whereLabel(c));
    return parts.join(' · ');
  }
  function isSettled(id) { return !!(id && st.settled[id] && Date.now() - st.settled[id] < SETTLED_MS); }
  function livePending(c) {
    const p = c && c.pending;
    if (!p || isSettled(p.fingerprint)) return null;
    return p;
  }
  function ckeyFromKey(key) {
    const parts = String(key || '').split('|');
    return parts.length >= 3 ? parts.slice(-2).join('|') : String(key || '');
  }
  function matches(r, c) {
    if (c.key && r.key && c.key === r.key) return true;
    if (r.key && ckeyFromKey(r.key) === c.ckey) return true;
    const fp = c.pending && c.pending.fingerprint;
    return !!(fp && fp === r.fingerprint);
  }
  function liveRequests() {
    return (st.requests || []).filter((r) => !isSettled(r.request_id) && !isSettled(r.fingerprint));
  }
  function requestFor(c) {
    if (!c || c.status !== 'live') return null;
    return liveRequests().find((r) => matches(r, c)) || null;
  }
  function orphans() {
    const all = allConvs();
    return liveRequests().filter((r) => !all.some((c) => matches(r, c)));
  }
  function rowStatus(c, req) {
    if (c.status === 'asleep' || c.status === 'offline') return 'paused';
    if (c.status === 'moving') return 'moving';
    if (c.status === 'ended') return 'ended';
    if (req || livePending(c) || c.state === 'approval' || c.state === 'question') return 'waiting';
    if (c.state === 'working' || c.state === 'thinking') return 'working';
    if (c.state === 'finished') return 'finished';
    if (c.state === 'error') return 'failed';
    if (c.state === 'ratelimit') return 'ratelimit';
    return 'idle';
  }
  function statusLabel(c, req) {
    switch (c.status) {
      case 'asleep': return 'Mac asleep';
      case 'offline': return 'Mac offline';
      case 'moving': return 'Moving';
      case 'ended': return 'Ended';
      default: break;
    }
    const p = req || livePending(c);
    if (p) return isQuestionKind(p.kind) ? 'Has a question' : 'Needs approval';
    return ({
      approval: 'Needs approval', question: 'Has a question', thinking: 'Thinking', working: 'Working',
      finished: 'Finished', error: 'Failed', ratelimit: 'Rate-limited',
    })[c.state] || 'Idle';
  }
  function rowDetail(c, req) {
    switch (c.status) {
      case 'asleep': case 'offline': return null;
      case 'moving': return { text: onServer(c) ? 'Moving to the Mac…' : 'Moving to the server…', tone: 'quiet' };
      case 'ended': return { text: 'Ended', tone: 'quiet' };
      default: break;
    }
    if (req) return { text: askOfRequest(req), tone: 'waiting' };
    const p = livePending(c);
    if (p) return { text: askOfPending(p), tone: 'waiting' };
    switch (c.state) {
      case 'approval': return { text: 'Needs approval', tone: 'waiting' };
      case 'question': return { text: 'Has a question', tone: 'waiting' };
      case 'working': case 'thinking': return { text: liveStep(c.step), tone: 'working' };
      case 'error': return { text: firstLine(c.step) || 'Stopped with an error', tone: 'failed' };
      case 'ratelimit': return { text: 'Paused until the plan limit resets', tone: 'quiet' };
      default: break;
    }
    if (onServer(c) && c.moved_from_name) return { text: 'Moved from ' + c.moved_from_name, tone: 'quiet' };
    return null;
  }
  function wasLine(state) {
    switch (state) {
      case 'working': case 'thinking': return 'was working';
      case 'approval': case 'question': return 'was waiting on you';
      case 'ratelimit': return 'was rate-limited';
      case 'error': return 'had stopped with an error';
      default: return 'idle';
    }
  }
  function offlineWarning(name, count) {
    const what = count === 1 ? 'this session' : 'these sessions';
    return name + ' went offline without going to sleep, so it may still be running ' + what +
      '. Continuing on the server could leave two copies running.';
  }
  function cantSendReason(c) {
    if (c.gone) return 'This session isn’t in the list any more.';
    // A message now would be typed into Claude's approval / question menu, and
    // the Return would pick its highlighted "Yes". The card answers it.
    if (c.status === 'live' && waitsOnYou(c)) {
      const p = livePending(c);
      return (p ? isQuestionKind(p.kind) : c.state === 'question')
        ? 'Answer the question above first.' : 'Allow or deny the request above first.';
    }
    if (c.can_send) return null;
    const name = (!c.owner_name || onServer(c)) ? 'This Mac' : c.owner_name;
    switch (c.status) {
      case 'asleep': return name + ' is asleep.';
      case 'offline': return name + ' is offline.';
      case 'moving': return onServer(c) ? 'It’s moving to the Mac…' : 'It’s moving to the server…';
      case 'ended': return 'This session has ended.';
      default: break;
    }
    const app = terminalApp(c.terminal_app);
    return 'Can’t send here: it’s idle in ' + (app || 'a terminal Jarvis can’t type into') +
      '. Reply there, or wait until it’s working.';
  }
  function sendFailure(reason) {
    switch (reason || '') {
      case 'owner_offline': return 'The Mac running it is asleep or offline.';
      case 'no_runtime': return 'Nothing is running it on the server.';
      case 'ended': return 'This session has ended.';
      case 'moving': return 'It’s moving between machines. Try again in a moment.';
      case 'no_session': return 'That session is gone.';
      case '': return 'It didn’t go through.';
      default: return reason;
    }
  }
  function continueFailure(r) {
    if (r && r.error) return r.error;
    switch ((r && r.reason) || '') {
      case 'not_synced': return 'Its project folder isn’t synced, so it can’t move to the server yet.';
      case 'mac_offline': case 'owner_offline': return 'The Mac is asleep or offline.';
      default: return 'It couldn’t move.';
    }
  }

  // ── flash lines ────────────────────────────────────────────────────────
  function setFlash(scope, text, tone) {
    st.flash = { scope: scope || 'list', text, tone: tone || 'ok', until: Date.now() + FLASH_MS };
    clearTimeout(st.flashTimer);
    st.flashTimer = setTimeout(() => { st.flash = null; renderAll(); }, FLASH_MS + 50);
  }
  function flashHtml(scope) {
    const f = st.flash;
    if (!f || f.scope !== scope || Date.now() > f.until) return '';
    return '<div class="agents-flash tone-' + esc(f.tone) + '" role="status">' + esc(f.text) + '</div>';
  }

  // ── the shell ──────────────────────────────────────────────────────────
  function ensureShell() {
    const root = $('mainAgents');
    if (!root) return null;
    if (root.querySelector('.agents-body')) return root;
    root.innerHTML =
      '<div class="agents-body" id="agentsBody" data-view="list">' +
        '<aside class="agents-list" aria-label="Agent sessions">' +
          '<div class="agents-list-head">' +
            '<h2 class="agents-title" data-i18n="tab_agents">Agents</h2>' +
            '<button type="button" class="agents-new-btn" data-act="new">+ New session</button>' +
          '</div>' +
          '<div class="agents-list-scroll" id="agentsListScroll"><div id="agentsListInner"></div></div>' +
        '</aside>' +
        '<section class="agents-pane" id="agentsPane"></section>' +
      '</div>';
    root.addEventListener('click', onClick);
    root.addEventListener('keydown', onKeydown);
    root.addEventListener('input', onInput);
    root.addEventListener('submit', onSubmit);
    root.addEventListener('toggle', onToggle, true);   // <details> toggle doesn't bubble
    root.addEventListener('pointerdown', onPointerDown);
    return root;
  }

  function renderAll() {
    if (!$('agentsBody')) return;
    const body = $('agentsBody');
    if (body.dataset.view !== st.view) body.dataset.view = st.view;
    // Keep keyboard focus on the same row/button across a list refresh.
    const inner = $('agentsListInner');
    const a = document.activeElement;
    const focus = a && inner && inner.contains(a) && a.dataset
      ? { act: a.dataset.act, ckey: a.dataset.ckey, gid: a.dataset.gid, ckeys: a.dataset.ckeys } : null;
    if (setHtml(inner, listHtml()) && focus && focus.act) {
      const sel = '[data-act="' + focus.act + '"]' +
        (focus.ckey ? '[data-ckey="' + CSS.escape(focus.ckey) + '"]' : '') +
        (focus.gid ? '[data-gid="' + CSS.escape(focus.gid) + '"]' : '') +
        (focus.ckeys ? '[data-ckeys="' + CSS.escape(focus.ckeys) + '"]' : '');
      const again = inner.querySelector(sel);
      if (again) again.focus();
    }
    renderPane();
  }

  // ── the list ───────────────────────────────────────────────────────────
  function listHtml() {
    const l = st.list;
    const parts = [];
    if (st.error) parts.push('<div class="agents-banner" role="status">' + esc(st.error) + '</div>');
    parts.push(flashHtml('list'));
    if (!l) {
      parts.push('<div class="agents-note">Loading…</div>');
      return parts.join('');
    }
    parts.push(usageHtml(l.usage, l.usage_codex));
    const card = cardHtml(l.card);
    parts.push(card);
    const needs = (l.needs_you || []).slice().sort((a, b) => toMs(b.last_event_at) - toMs(a.last_event_at));
    const orph = orphans();
    if (needs.length || orph.length) {
      parts.push('<div class="agents-sec">Needs you <span class="agents-sec-count">' +
        (needs.length + orph.length) + '</span></div>');
      parts.push('<div class="agents-sec-body">' +
        needs.map((c) => rowHtml(c, { showsProject: true, decision: true })).join('') +
        orph.map(orphanHtml).join('') + '</div>');
    }
    const all = (l.projects || []).filter((g) => (g.sessions || []).length);
    const groups = all.filter((g) => !g.integration);
    const integrations = all.filter((g) => g.integration);
    if (groups.length) {
      parts.push('<div class="agents-sec">Projects</div>');
      parts.push(groups.map((g) => groupHtml(g, needs)).join(''));
    }
    if (integrations.length) {
      parts.push('<div class="agents-sec">Integrations</div>');
      parts.push(integrations.map((g) => groupHtml(g, needs)).join(''));
    }
    if (!card && !needs.length && !orph.length && !groups.length) {
      parts.push('<div class="agents-empty"><div class="agents-empty-title">No sessions right now</div>' +
        'Run <code>claude</code> or <code>codex</code> in any terminal on a paired Mac and it shows up ' +
        'here, or start one with <b>+ New session</b>.</div>');
    }
    return parts.join('');
  }

  function usageWindow(w) {
    if (!w || typeof w.used_percentage !== 'number') return null;
    const resets = Number(w.resets_at) || 0;
    const pct = resets && toMs(resets) <= Date.now() ? 0
      : Math.round(Math.max(0, Math.min(100, w.used_percentage)));
    return { pct, resets };
  }
  function ringHtml(label, win) {
    const pct = win ? win.pct : null;
    const tone = pct == null ? '' : pct >= 90 ? ' is-hot' : pct >= 75 ? ' is-warm' : '';
    const name = label === '5h' ? '5-hour limit' : 'Weekly limit';
    const title = pct == null ? name + ': no data yet' : name + ': ' + pct + '% used' +
      (win.resets ? ', resets ' + clock(win.resets) : '');
    const val = pct ? '<circle class="agents-ring-val" cx="18" cy="18" r="15.5" pathLength="100" stroke-dasharray="' +
      pct + ' 100"/>' : '';
    return '<span class="agents-ring' + tone + '" title="' + esc(title) + '" role="img" aria-label="' + esc(title) + '">' +
      '<span class="agents-ring-dial"><svg viewBox="0 0 36 36" aria-hidden="true">' +
      '<circle class="agents-ring-track" cx="18" cy="18" r="15.5" pathLength="100"/>' + val + '</svg>' +
      '<span class="agents-ring-num">' + (pct == null ? '–' : pct) + '</span></span>' +
      '<span class="agents-ring-label">' + label + '</span></span>';
  }
  function usageItemHtml(name, u) {
    if (!u) return '';
    const f = usageWindow(u.five_hour);
    const w = usageWindow(u.seven_day);
    if (!f && !w) return '';
    let sub = '';
    if (f && f.resets && toMs(f.resets) > Date.now()) sub = '5-hour limit resets ' + clock(f.resets);
    else if (w && w.resets && toMs(w.resets) > Date.now()) sub = 'Weekly limit resets ' + clock(w.resets);
    return '<div class="agents-usage-item"><div class="agents-usage-text">' +
      '<span class="agents-usage-name">' + esc(name) + '</span>' +
      (sub ? '<span class="agents-usage-sub">' + esc(sub) + '</span>' : '') + '</div>' +
      '<div class="agents-rings">' + ringHtml('5h', f) + ringHtml('Wk', w) + '</div></div>';
  }
  function usageHtml(claude, codex) {
    const items = usageItemHtml('Claude', claude) + usageItemHtml('Codex', codex);
    return items ? '<div class="agents-usage">' + items + '</div>' : '';
  }

  function confirmHtml(scope) {
    const c = st.confirm;
    if (!c || c.scope !== scope) return '';
    const busy = st.busy['continue:' + c.ckeys.join(',')];
    return '<div class="agents-confirm" role="alert"><div>' + esc(offlineWarning(c.name || 'Your Mac', c.ckeys.length)) +
      '</div><div class="agents-confirm-actions">' +
      '<button type="button" class="agents-btn" data-act="confirm-cancel">Cancel</button>' +
      '<button type="button" class="agents-btn is-warn" data-act="confirm-continue"' + (busy ? ' disabled' : '') + '>' +
      (busy ? 'Continuing…' : 'Continue anyway') + '</button></div></div>';
  }

  function cardHtml(card) {
    const sessions = (card && card.sessions) || [];
    if (!card || !sessions.length) return '';
    const name = card.device_name || 'Your Mac';
    const sleep = card.kind !== 'offline';
    const title = sleep ? name + ' went to sleep' : name + ' went offline';
    const rows = sessions.map((s) => {
      const busy = st.moving.has(s.ckey);
      const was = wasLine(s.was);
      const line = s.project ? s.project + ' · ' + was : was.charAt(0).toUpperCase() + was.slice(1);
      return '<div class="agents-sleep-row"><div class="agents-sleep-main">' +
        '<span class="agents-sleep-title">' + esc(s.title || s.project || 'Session') + '</span>' +
        '<span class="agents-sleep-sub">' + esc(line) + '</span></div>' +
        '<button type="button" class="agents-pill-btn" data-act="continue" data-to="server" data-scope="card" ' +
        'data-name="' + esc(name) + '" data-ckeys="' + esc(s.ckey) + '"' + (busy ? ' disabled' : '') + '>' +
        (busy ? 'Continuing…' : 'Continue') + '</button></div>';
    }).join('');
    const all = sessions.map((s) => s.ckey);
    const allBusy = all.some((k) => st.moving.has(k));
    const allTitle = sessions.length === 2 ? 'Continue both on server' : 'Continue all on server';
    const allBtn = sessions.length < 2 ? '' :
      '<button type="button" class="agents-pill-btn is-all" data-act="continue" data-to="server" data-scope="card" ' +
      'data-name="' + esc(name) + '" data-ckeys="' + esc(all.join(',')) + '"' + (allBusy ? ' disabled' : '') + '>' +
      (allBusy ? 'Continuing…' : allTitle) + '</button>';
    return '<div class="agents-sleep" role="region" aria-label="' + esc(title) + '">' +
      '<div class="agents-sleep-head"><span class="agents-moon" aria-hidden="true">☾</span>' +
      '<b>' + esc(title) + '</b><small>' + esc(clock(card.since)) + '</small>' +
      '<button type="button" class="agents-x" data-act="dismiss" data-device="' + esc(card.device_id) + '" ' +
      'aria-label="Dismiss" title="Dismiss">✕</button></div>' +
      rows + confirmHtml('card') + flashHtml('card') + allBtn + '</div>';
  }

  const MARKS = {
    working: ['<span class="agents-spin"></span>', 'Working'],
    moving: ['<span class="agents-spin is-quiet"></span>', 'Moving'],
    waiting: ['<span class="agents-dot is-amber"></span>', 'Waiting on you'],
    finished: ['<svg class="agents-check" viewBox="0 0 16 16" aria-hidden="true"><path d="M3.5 8.5l3 3 6-7"/></svg>', 'Finished'],
    failed: ['<span class="agents-dot is-red"></span>', 'Stopped with an error'],
    paused: ['<span class="agents-moon">☾</span>', 'Mac asleep'],
    ratelimit: ['<span class="agents-hollow is-quiet"></span>', 'Rate-limited'],
    ended: ['<span class="agents-hollow is-ended"></span>', 'Ended'],
    idle: ['<span class="agents-dot is-open"></span>', 'Open, idle'],
  };
  function markHtml(status) {
    const m = MARKS[status] || MARKS.idle;
    return '<span class="agents-mark" title="' + esc(m[1]) + '">' + m[0] +
      '<span class="agents-sr">' + esc(m[1]) + '</span></span>';
  }

  function rowHtml(c, opts) {
    const req = requestFor(c);
    const status = rowStatus(c, req);
    const det = rowDetail(c, req);
    const sel = st.pane === 'session' && st.selected === c.ckey;
    let html = '<div class="agents-row-wrap">' +
      '<button type="button" class="agents-row' + (sel ? ' is-selected' : '') + '" data-act="open" data-ckey="' +
      esc(c.ckey) + '"' + (sel ? ' aria-current="true"' : '') + '>' + markHtml(status) +
      '<span class="agents-row-main"><span class="agents-row-top">' +
      '<span class="agents-row-title">' + esc(titleOf(c)) + '</span>' +
      '<span class="agents-row-time">' + esc(ago(c.last_event_at)) + '</span></span>' +
      '<span class="agents-row-sub">' + esc(subtitle(c, opts.showsProject)) + '</span>' +
      (det ? '<span class="agents-row-detail tone-' + det.tone + '">' + esc(det.text) + '</span>' : '') +
      '</span></button>';
    if (opts.decision && (req || livePending(c))) html += decisionHtml(c, req, true);
    return html + '</div>';
  }

  function orphanHtml(r) {
    return '<div class="agents-row-wrap"><div class="agents-row is-static">' + markHtml('waiting') +
      '<span class="agents-row-main"><span class="agents-row-top">' +
      '<span class="agents-row-title">' + esc(r.project || 'Session') + '</span>' +
      '<span class="agents-row-time">' + esc(ago(r.created)) + '</span></span>' +
      '<span class="agents-row-sub">' + esc(agentName(r.agent)) + '</span>' +
      '<span class="agents-row-detail tone-waiting">' + esc(askOfRequest(r)) + '</span></span></div>' +
      decisionHtml(null, r, true) + '</div>';
  }

  function groupId(g) {
    if (g.integration) return 'integration:' + g.integration;
    return g.id != null && g.id !== '' ? String(g.id) : 'name:' + (g.name || '');
  }
  function groupWaiting(g, needs) {
    const own = (g.sessions || []).filter(waitsOnYou).length;
    const inNeeds = needs.filter((c) => (g.id != null && g.id !== '')
      ? String(c.project_id) === String(g.id)
      : (!c.project_id && c.project === g.name)).length;
    return own + inNeeds;
  }
  function groupHtml(g, needs) {
    const gid = groupId(g);
    const waiting = groupWaiting(g, needs);
    const open = waiting > 0 || (g.integration ? st.openIntegrations.has(gid) : !st.collapsed.has(gid));
    const name = g.name || ((g.sessions || [])[0] || {}).project || 'Other';
    return '<div class="agents-group' + (open ? ' is-open' : '') + '">' +
      '<button type="button" class="agents-group-head" data-act="toggle-group" data-gid="' + esc(gid) + '" ' +
      'aria-expanded="' + open + '"><span class="agents-chev" aria-hidden="true">' + (open ? '▾' : '▸') + '</span>' +
      '<span class="agents-group-name">' + esc(name) + '</span>' +
      '<span class="agents-group-count">' + g.sessions.length + '</span>' +
      (waiting ? '<span class="agents-group-badge">● ' + waiting + ' needs you</span>' : '') + '</button>' +
      (open ? '<div class="agents-group-body">' +
        g.sessions.map((c) => rowHtml(c, { showsProject: false })).join('') + '</div>' : '') +
      '</div>';
  }

  // ── approval and question cards ────────────────────────────────────────
  function decisionKey(req, c) {
    return (req && req.request_id) || (req && req.fingerprint) || (c && c.pending && c.pending.fingerprint) || '';
  }
  function decisionHtml(c, req, compact) {
    const p = req || livePending(c);
    if (!p) return '';
    const key = decisionKey(req, c);
    const rid = (req && req.request_id) || '';
    const fp = (req && req.fingerprint) || (c && c.pending && c.pending.fingerprint) || '';
    const agent = agentName((req && req.agent) || (c && c.agent));
    const busy = !!st.busy['decide:' + key];
    const err = st.decisionErr[key];
    const attrs = ' data-key="' + esc(key) + '" data-rid="' + esc(rid) + '" data-fp="' + esc(fp) + '"';
    const cls = 'agents-decision' + (compact ? ' is-compact' : '');
    const errHtml = err ? '<div class="agents-decision-err" role="alert">' + esc(err) + '</div>' : '';
    if (isQuestionKind(p.kind)) return questionHtml(req, p, compact, cls, attrs, key, busy, agent, errHtml);

    const tool = p.tool || '';
    const what = (req && req.command) || p.summary || '';
    const title = tool === 'Bash' ? 'Allow ' + agent + ' to run this command?'
      : 'Allow ' + agent + ' to ' + lineText(toolLine(tool, what, 'imperative')) + '?';
    const canDecide = !!(rid || fp);
    const canAlways = !!(req && req.can_always);
    let actions;
    if (!canDecide) {
      actions = '<div class="agents-hint">Answer it in the terminal it runs in.</div>';
    } else if (!compact && st.denying[key]) {
      actions = '<div class="agents-deny-row">' +
        '<input type="text" class="agents-text agents-deny-note" data-key="' + esc(key) + '" ' +
        'aria-label="Note for ' + esc(agent) + '" placeholder="Tell ' + esc(agent) + ' what to do instead (optional)">' +
        '<div class="agents-decision-actions">' +
        '<button type="button" class="agents-btn" data-act="deny-back">Back</button>' +
        '<button type="button" class="agents-btn is-danger" data-act="deny-send"' + (busy ? ' disabled' : '') + '>Deny</button>' +
        '</div></div>';
    } else {
      actions = '<div class="agents-decision-actions">' +
        '<button type="button" class="agents-btn is-primary" data-act="decide" data-decision="allow"' + (busy ? ' disabled' : '') + '>Allow</button>' +
        (canAlways ? '<button type="button" class="agents-btn" data-act="decide" data-decision="always"' + (busy ? ' disabled' : '') + '>Always</button>' : '') +
        '<button type="button" class="agents-btn is-danger" data-act="' + (compact ? 'decide' : 'deny-open') + '" data-decision="deny"' + (busy ? ' disabled' : '') + '>Deny</button>' +
        (!compact && rid ? '<button type="button" class="agents-link" data-act="decide" data-decision="ask">Answer in the terminal</button>' : '') +
        '</div>';
    }
    return '<div class="' + cls + '"' + attrs + '>' +
      (compact ? '' : '<div class="agents-decision-title">' + esc(title) + '</div>' +
        ((req && req.project) ? '<div class="agents-decision-sub">' + esc(req.project) + '</div>' : '') +
        (what ? '<pre class="agents-decision-what">' + esc(what) + '</pre>' : '')) +
      actions + errHtml + '</div>';
  }

  function questionHtml(req, p, compact, cls, attrs, key, busy, agent, errHtml) {
    const qs = (req ? req.questions : p.questions) || [];
    const picks = st.picks[key] || {};
    const answerable = !!(req && req.request_id);
    const body = qs.map((q, qi) => {
      const multi = !!q.multiSelect;
      const chosen = picks[q.question] || [];
      const opts = (q.options || []).map((o, oi) => {
        const on = chosen.includes(o.label);
        return '<button type="button" class="agents-q-opt' + (on ? ' is-on' : '') + '" data-act="pick" ' +
          'data-qi="' + qi + '" data-oi="' + oi + '" role="' + (multi ? 'checkbox' : 'radio') + '" ' +
          'aria-checked="' + on + '"' + (answerable ? '' : ' disabled') + '>' +
          '<span class="agents-q-label">' + esc(o.label) + '</span>' +
          (o.description && !compact ? '<span class="agents-q-desc">' + esc(o.description) + '</span>' : '') +
          '</button>';
      }).join('');
      const showText = !compact || qs.length > 1;
      return '<div class="agents-q">' +
        (q.header && !compact ? '<span class="agents-q-chip">' + esc(q.header) + '</span>' : '') +
        (showText ? '<div class="agents-q-text">' + esc(q.question) + '</div>' : '') +
        (multi && !compact ? '<div class="agents-hint">Pick any that apply.</div>' : '') +
        '<div class="agents-q-opts" role="' + (multi ? 'group' : 'radiogroup') + '" aria-label="' + esc(q.question) + '">' +
        opts + '</div></div>';
    }).join('');
    const answered = qs.some((q) => (picks[q.question] || []).length);
    const actions = answerable
      ? '<div class="agents-decision-actions">' +
        '<button type="button" class="agents-btn is-primary" data-act="answer"' + (answered && !busy ? '' : ' disabled') + '>' +
        (busy ? 'Sending…' : 'Send answer') + '</button>' +
        (!compact ? '<button type="button" class="agents-link" data-act="decide" data-decision="ask">Answer in the terminal</button>' : '') +
        '</div>'
      : '<div class="agents-hint">Answer it in the terminal it runs in.</div>';
    return '<div class="' + cls + '"' + attrs + '>' +
      (compact ? '' : '<div class="agents-decision-title">' + esc(agent + ' has a question') + '</div>') +
      body + actions + errHtml + '</div>';
  }

  async function decide(el, decision, message) {
    const card = el.closest('.agents-decision');
    if (!card) return;
    const key = card.dataset.key;
    const rid = card.dataset.rid;
    const fp = card.dataset.fp;
    if (!key || st.busy['decide:' + key]) return;
    st.busy['decide:' + key] = true;
    delete st.decisionErr[key];
    renderAll();
    try {
      let res;
      if (rid) res = await post('/permission/verdict', { request_id: rid, decision, message: message || '' });
      else res = await post('/agents/decide', { fingerprint: fp, decision, message: message || '' });
      if (res && res.ok) {
        const now = Date.now();
        if (rid) st.settled[rid] = now;
        if (fp) st.settled[fp] = now;
        st.requests = (st.requests || []).filter((r) => r.request_id !== rid);
        delete st.denying[key]; delete st.denyNote[key]; delete st.picks[key];
      } else {
        st.decisionErr[key] = 'That request isn’t waiting any more.';
      }
    } catch (e) {
      st.decisionErr[key] = errText(e, 'Couldn’t send that.');
    } finally {
      delete st.busy['decide:' + key];
      renderAll();
      refreshSoon();
    }
  }

  function pick(el) {
    const card = el.closest('.agents-decision');
    if (!card) return;
    const key = card.dataset.key;
    const req = (st.requests || []).find((r) => r.request_id === card.dataset.rid);
    const q = req && (req.questions || [])[Number(el.dataset.qi)];
    const o = q && (q.options || [])[Number(el.dataset.oi)];
    if (!o) return;
    const picks = st.picks[key] || (st.picks[key] = {});
    const cur = picks[q.question] || [];
    if (q.multiSelect) picks[q.question] = cur.includes(o.label) ? cur.filter((l) => l !== o.label) : cur.concat([o.label]);
    else picks[q.question] = [o.label];
    renderAll();
  }

  async function answer(el) {
    const card = el.closest('.agents-decision');
    if (!card) return;
    const key = card.dataset.key;
    const rid = card.dataset.rid;
    const req = (st.requests || []).find((r) => r.request_id === rid);
    if (!req || st.busy['decide:' + key]) return;
    const picks = st.picks[key] || {};
    const answers = {};
    (req.questions || []).forEach((q) => {
      const chosen = picks[q.question] || [];
      if (chosen.length) answers[q.question] = q.multiSelect ? chosen : chosen[0];
    });
    if (!Object.keys(answers).length) return;
    st.busy['decide:' + key] = true;
    delete st.decisionErr[key];
    renderAll();
    try {
      const res = await post('/permission/verdict', { request_id: rid, decision: 'answer', answers });
      if (res && res.ok) {
        const now = Date.now();
        st.settled[rid] = now;
        if (req.fingerprint) st.settled[req.fingerprint] = now;
        st.requests = st.requests.filter((r) => r.request_id !== rid);
        delete st.picks[key];
      } else {
        st.decisionErr[key] = 'That question isn’t waiting any more.';
      }
    } catch (e) {
      st.decisionErr[key] = errText(e, 'Couldn’t send the answer.');
    } finally {
      delete st.busy['decide:' + key];
      renderAll();
      refreshSoon();
    }
  }

  // ── the right column ───────────────────────────────────────────────────
  function renderPane() {
    const pane = $('agentsPane');
    if (!pane) return;
    if (st.pane === 'launch') {
      if (!pane.querySelector('.agents-launch')) { pane.innerHTML = launchHtml(); pane._agentsHtml = null; wireLaunch(); }
      return;
    }
    if (st.pane === 'session' && st.selected && currentConv()) {
      const shell = pane.querySelector('.agents-sess');
      if (!shell || shell.dataset.ckey !== st.selected) {
        pane.innerHTML = sessionShellHtml(st.selected);
        pane._agentsHtml = null;
        const ta = $('agentsInput');
        if (ta) ta.value = st.drafts[st.selected] || '';
        const box = $('agentsTranscript');
        if (box) box.addEventListener('scroll', onTranscriptScroll, { passive: true });
        st.scrollToEnd = true;
      }
      updateSession();
      return;
    }
    setHtml(pane, '<div class="agents-pane-empty"><div class="agents-pane-empty-title">Pick a session</div>' +
      'Its chat, approvals and a message box open here.' +
      '<div><button type="button" class="agents-btn" data-act="new">+ New session</button></div></div>');
  }

  function sessionShellHtml(ckey) {
    return '<div class="agents-sess" data-ckey="' + esc(ckey) + '">' +
      '<header class="agents-sess-head" id="agentsSessHead"></header>' +
      '<div class="agents-sess-notes" id="agentsSessNotes"></div>' +
      '<div class="agents-transcript" id="agentsTranscript" aria-live="polite">' +
        '<div class="agents-older" id="agentsOlder"></div>' +
        '<div class="agents-msgs" id="agentsMsgs"></div>' +
        '<div class="agents-live" id="agentsLive"></div>' +
        '<div class="agents-outgoing" id="agentsOutgoing"></div>' +
      '</div>' +
      '<div class="agents-decision-slot" id="agentsDecisionSlot"></div>' +
      '<div class="agents-term-drawer" id="agentsTermDrawer" hidden>' +
        '<div class="agents-term-grip" data-drag="term" role="separator" aria-orientation="horizontal" ' +
        'aria-label="Drag to resize the terminal" tabindex="0"></div>' +
        '<div class="agents-term-bar"><span class="agents-term-title">Terminal</span>' +
        '<span class="agents-term-hint">For slash commands and Claude’s menus</span>' +
        '<button type="button" class="agents-btn is-small is-dark" data-act="term-close">Close</button></div>' +
        '<div class="agents-term-host" id="agentsTermHost"></div>' +
      '</div>' +
      '<div class="agents-composer" id="agentsComposer">' +
        '<div class="agents-blocked" id="agentsBlocked" hidden></div>' +
        '<form class="agents-form" id="agentsForm" autocomplete="off">' +
          '<textarea class="agents-input" id="agentsInput" rows="1" aria-label="Message"></textarea>' +
          '<button type="button" class="agents-send-now" id="agentsSendNow" data-act="send-now" hidden ' +
            'title="Send it in now instead of after this turn (Ctrl+Enter)">Send now</button>' +
          '<button type="submit" class="agents-send" id="agentsSend" aria-label="Send" title="Send (Enter)">' +
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 19V5M5 12l7-7 7 7"/></svg></button>' +
        '</form>' +
      '</div>' +
    '</div>';
  }

  function updateSession() {
    const c = currentConv();
    if (!c) return;
    const req = requestFor(c);
    setHtml($('agentsSessHead'), headHtml(c, req));
    setHtml($('agentsSessNotes'), notesHtml(c));
    updateTranscript(c.ckey);
    const slot = $('agentsDecisionSlot');
    const waiting = !c.gone && c.status === 'live' && (req || livePending(c));
    // The deny note's text lives in st.denyNote (not in the markup), so typing
    // never re-renders the card; a card that does re-render gets it back.
    if (setHtml(slot, waiting ? decisionHtml(c, req, false) : '')) {
      slot.querySelectorAll('.agents-deny-note').forEach((n) => { n.value = st.denyNote[n.dataset.key] || ''; });
    }
    updateComposer(c);
    const drawer = $('agentsTermDrawer');
    if (drawer) {
      drawer.hidden = !st.termOpen;
      if (st.termOpen) applyTermHeight();
    }
  }

  function headHtml(c, req) {
    const status = rowStatus(c, req);
    const sub = [c.project && c.project !== titleOf(c) ? c.project : '', agentName(c.agent), whereLabel(c),
      c.model || ''].filter(Boolean).join(' · ');
    return '<button type="button" class="agents-back" data-act="back" aria-label="Back to the list">‹ Agents</button>' +
      '<div class="agents-sess-titles"><div class="agents-sess-title">' + esc(titleOf(c)) + '</div>' +
      '<div class="agents-sess-sub">' + esc(sub) + '</div></div>' +
      '<span class="agents-pill tone-' + status + '">' + esc(statusLabel(c, req)) + '</span>' +
      (c.can_terminal ? '<button type="button" class="agents-btn is-small" data-act="terminal" aria-pressed="' +
        st.termOpen + '">' + (st.termOpen ? 'Hide terminal' : 'Terminal') + '</button>' : '') +
      '<div class="agents-menu-wrap"><button type="button" class="agents-icon-btn" data-act="menu" aria-haspopup="menu" ' +
      'aria-expanded="' + st.menuOpen + '" aria-label="Session actions" title="Session actions">⋯</button>' +
      (st.menuOpen ? menuHtml(c) : '') + '</div>';
  }

  function menuItem(act, label, extra) {
    const x = extra || {};
    return '<button type="button" class="agents-menu-item' + (x.cls ? ' ' + x.cls : '') + '" role="' +
      (x.role || 'menuitem') + '" data-act="' + act + '"' + (x.disabled ? ' disabled' : '') +
      (x.checked != null ? ' aria-checked="' + !!x.checked + '"' : '') + '><span>' + esc(label) + '</span>' +
      (x.state ? '<span class="agents-menu-state">' + esc(x.state) + '</span>' : '') + '</button>';
  }
  function menuHtml(c) {
    const safe = [];
    if (c.can_terminal) safe.push(menuItem('terminal', st.termOpen ? 'Hide terminal' : 'Open terminal'));
    if (c.can_continue_server) safe.push(menuItem('continue-server', 'Continue on server'));
    if (c.can_continue_mac) safe.push(menuItem('continue-mac', 'Continue on ' + macName(c)));
    if (c.can_resume) {
      safe.push(menuItem('resume-server', 'Resume on server'));
      if (!onServer(c) || c.moved_from) safe.push(menuItem('resume-mac', 'Resume on ' + macName(c)));
    }
    if (c.project_id != null && c.project_id !== '') {
      const on = st.projSync[String(c.project_id)];
      safe.push(menuItem('sync', 'Sync this project', {
        role: 'menuitemcheckbox', checked: on, disabled: on === undefined || st.busy.sync,
        state: on === undefined ? '…' : (on ? 'On' : 'Off'),
      }));
    }
    if (c.session_id) safe.push(menuItem('copy-id', 'Copy session id'));
    const danger = [];
    if (!c.gone && (c.status === 'live' || c.status === 'moving')) {
      danger.push(menuItem('stop-ask', 'Stop session…', { cls: 'is-danger' }));
    }
    if (!safe.length && !danger.length) safe.push(menuItem('noop', 'Nothing to do here', { disabled: true }));
    return '<div class="agents-menu" role="menu" aria-label="Session actions">' + safe.join('') +
      (danger.length ? '<div class="agents-menu-sep" role="separator"></div>' + danger.join('') : '') + '</div>';
  }

  function notesHtml(c) {
    const parts = [];
    if (c.gone) parts.push('<div class="agents-note-row">It’s no longer in the list (it ended over 12 hours ago, or it’s gone).</div>');
    if (st.stopConfirm) {
      const where = onServer(c) ? 'the server' : (c.owner_name || 'the Mac');
      parts.push('<div class="agents-note-row is-danger" role="alert"><span>Stop this session? This ends the ' +
        esc(agentName(c.agent)) + ' process on ' + esc(where) + '.</span><span class="agents-note-actions">' +
        '<button type="button" class="agents-btn" data-act="stop-cancel">Cancel</button>' +
        '<button type="button" class="agents-btn is-danger" data-act="stop"' + (st.busy.stop ? ' disabled' : '') + '>' +
        (st.busy.stop ? 'Stopping…' : 'Stop') + '</button></span></div>');
    }
    parts.push(confirmHtml('session'));
    parts.push(flashHtml('session'));
    return parts.join('');
  }

  // ── transcript ─────────────────────────────────────────────────────────
  function md(text) {
    if (typeof renderMd === 'function') {
      try { return renderMd(text); } catch (_) { /* fall back to plain text */ }
    }
    return '<p class="agents-plain">' + esc(text) + '</p>';
  }
  function isDelivered(ckey, i) { const s = st.delivered[ckey]; return !!(s && s.has(i)); }
  function detailTool(ckey, i, ti) {
    const d = (st.details[ckey] || {})[i];
    return d && typeof d === 'object' ? (d.tools || [])[ti] || null : null;
  }
  function msgSig(ckey, m) {
    let sig = JSON.stringify(m);
    if (isDelivered(ckey, m.i)) sig += '|d';
    (m.tools || []).forEach((_, ti) => {
      const k = ckey + ':' + m.i + ':' + ti;
      if (st.openTools.has(k)) {
        const d = (st.details[ckey] || {})[m.i];
        sig += '|o' + ti + (typeof d === 'string' ? d : (d ? 'f' : ''));
      }
    });
    return sig;
  }
  function msgHtml(ckey, m) {
    const text = String(m.text || '').trim();
    if (m.role === 'user') {
      return '<div class="agents-msg is-user" data-i="' + m.i + '"><div class="agents-bubble">' + esc(text) + '</div>' +
        (isDelivered(ckey, m.i) ? '<div class="agents-msg-meta">Delivered</div>' : '') + '</div>';
    }
    const tools = (m.tools || []).map((t, ti) => toolHtml(ckey, m, t, ti)).join('');
    return '<div class="agents-msg is-agent" data-i="' + m.i + '">' +
      (tools ? '<div class="agents-tools">' + tools + '</div>' : '') +
      (text ? '<div class="agents-md">' + md(text) + '</div>' : '') + '</div>';
  }
  function toolHtml(ckey, m, t, ti) {
    const full = detailTool(ckey, m.i, ti) || t;
    const l = toolLine(t.name, t.summary || '', 'past');
    const chip = (t.name === 'Task' || t.name === 'Agent') && t.subagent_type
      ? ' <span class="agents-chip">' + esc(t.subagent_type) + '</span>' : '';
    const counts = (t.added || t.removed)
      ? ' <span class="agents-diffcount"><span class="is-add">+' + (t.added || 0) + '</span> ' +
        '<span class="is-del">−' + (t.removed || 0) + '</span></span>' : '';
    const head = '<span class="agents-tool-verb">' + esc(l.verb) + '</span>' +
      (l.object ? ' <span class="agents-tool-obj' + (l.mono ? ' is-mono' : '') + '">' + esc(l.object) + '</span>' : '') +
      chip + counts;
    const cls = 'agents-tool' + (t.ok === false ? ' is-failed' : '');
    const expandable = full.output || (full.diff && full.diff.length) || t.more;
    if (!expandable) return '<div class="' + cls + '">' + head + '</div>';
    const k = ckey + ':' + m.i + ':' + ti;
    const open = st.openTools.has(k);
    return '<details class="' + cls + '" data-tool="' + esc(k) + '"' + (open ? ' open' : '') + '><summary>' + head +
      '</summary>' + (open ? toolBodyHtml(ckey, m.i, full) : '') + '</details>';
  }
  function toolBodyHtml(ckey, i, full) {
    const parts = [];
    if (full.diff && full.diff.length) {
      parts.push('<pre class="agents-diff">' + full.diff.map((ln) => {
        const s = String(ln);
        const c = s.startsWith('@@') ? 'is-hunk' : s.startsWith('+') ? 'is-add' : s.startsWith('-') ? 'is-del' : '';
        return '<span' + (c ? ' class="' + c + '"' : '') + '>' + (esc(s) || ' ') + '</span>';
      }).join('') + '</pre>');
    }
    if (full.output) parts.push('<pre class="agents-tool-out">' + esc(full.output) + '</pre>');
    if (!parts.length) {
      const d = (st.details[ckey] || {})[i];
      parts.push('<div class="agents-tool-note">' +
        (d === undefined || d === 'loading' ? 'Loading…' : 'The full output isn’t available here.') + '</div>');
    }
    return parts.join('');
  }
  function emptyTranscriptHtml(c, ch) {
    if (ch && ch.error === 'gone') return '<div class="agents-note">This session isn’t on the server any more.</div>';
    const t = c && c.turn_summary;
    if (t && (t.prompt || t.final)) {
      return '<div class="agents-note">The server doesn’t have this chat yet. Its last turn:</div>' +
        (t.prompt ? '<div class="agents-msg is-user"><div class="agents-bubble">' + esc(t.prompt) + '</div></div>' : '') +
        (t.final ? '<div class="agents-msg is-agent"><div class="agents-md">' + md(t.final) + '</div></div>' : '');
    }
    return '<div class="agents-note">No messages yet.</div>';
  }

  function updateTranscript(ckey) {
    const box = $('agentsTranscript');
    const el = $('agentsMsgs');
    if (!box || !el) return;
    const ch = st.chats[ckey];
    const c = currentConv();
    const nearBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 90;
    const prevHeight = box.scrollHeight;
    const prevTop = box.scrollTop;
    let prepended = false;
    if (!ch || (ch.loading && !ch.messages.length)) {
      setHtml(el, '<div class="agents-note">Loading the conversation…</div>');
      el._agentsDom = null;
    } else if (!ch.messages.length && ch.syncing) {
      const pct = Math.round(100 * Math.min(1, (Number(ch.syncing.have) || 0) / (Number(ch.syncing.of) || 1)));
      setHtml(el, '<div class="agents-note">Copying this chat from ' + esc((c && c.owner_name) || 'the Mac') +
        '… ' + pct + '%</div>');
      el._agentsDom = null;
    } else if (!ch.messages.length) {
      setHtml(el, emptyTranscriptHtml(c, ch));
      el._agentsDom = null;
    } else {
      let dom = el._agentsDom;
      const end = ch.start + ch.messages.length;
      if (!dom || dom.ckey !== ckey || ch.start > dom.start || end < dom.end) {
        el.innerHTML = ch.messages.map((m) => msgHtml(ckey, m)).join('');
        el._agentsHtml = null;
        dom = el._agentsDom = { ckey, start: ch.start, end, sigs: new Map() };
        ch.messages.forEach((m) => dom.sigs.set(m.i, msgSig(ckey, m)));
      } else {
        if (ch.start < dom.start) {
          const add = ch.messages.filter((m) => m.i < dom.start);
          el.insertAdjacentHTML('afterbegin', add.map((m) => msgHtml(ckey, m)).join(''));
          add.forEach((m) => dom.sigs.set(m.i, msgSig(ckey, m)));
          dom.start = ch.start;
          prepended = true;
        }
        ch.messages.forEach((m) => {
          const sig = msgSig(ckey, m);
          if (!dom.sigs.has(m.i)) {
            el.insertAdjacentHTML('beforeend', msgHtml(ckey, m));
            dom.sigs.set(m.i, sig);
          } else if (dom.sigs.get(m.i) !== sig) {
            const node = el.querySelector('[data-i="' + m.i + '"]');
            if (node) node.outerHTML = msgHtml(ckey, m);
            dom.sigs.set(m.i, sig);
          }
        });
        dom.end = end;
      }
    }
    const older = $('agentsOlder');
    if (older) {
      setHtml(older, ch && ch.start > 0
        ? '<button type="button" class="agents-link" data-act="older"' + (ch.olderLoading ? ' disabled' : '') + '>' +
          (ch.olderLoading ? 'Loading earlier messages…' : 'Earlier messages') + '</button>' : '');
    }
    setHtml($('agentsLive'), liveHtml(c));
    renderOutgoing(ckey);
    if (prepended) {
      box.scrollTop = prevTop + (box.scrollHeight - prevHeight);
    } else if (st.scrollToEnd && ch && ch.messages.length) {
      box.scrollTop = box.scrollHeight;
      st.scrollToEnd = false;
    } else if (nearBottom) {
      box.scrollTop = box.scrollHeight;
    }
  }

  function liveHtml(c) {
    if (!c || c.gone || c.status !== 'live') return '';
    if (c.state === 'working' || c.state === 'thinking') {
      return '<span class="agents-spin"></span><span>' + esc(liveStep(c.step)) + '</span>';
    }
    if (c.state === 'ratelimit') return '<span>Paused until the plan limit resets</span>';
    return '';
  }

  function outgoingMeta(o, c) {
    switch (o.state) {
      case 'sending': return ['Sending…', ''];
      case 'sent': return ['Sent', ''];
      case 'queued': return ['Queued · it goes in when this turn ends', ''];
      case 'delivered': return ['Delivered', ''];
      default: return ['Not sent · ' + sendFailure(o.reason), 'failed'];
    }
  }
  function renderOutgoing(ckey) {
    const el = $('agentsOutgoing');
    if (!el) return;
    const c = currentConv();
    const list = (st.outgoing[ckey] || []).filter((o) => !o.landed);
    setHtml(el, list.map((o) => {
      const meta = outgoingMeta(o, c);
      let actions = '';
      if (o.state === 'failed') {
        actions = '<div class="agents-out-actions">' +
          (o.reason === 'owner_offline' && c && c.can_continue_server
            ? '<button type="button" class="agents-btn is-small is-primary" data-act="continue-server">Continue on server</button>' : '') +
          '<button type="button" class="agents-btn is-small" data-act="retry-send" data-oid="' + o.id + '">Retry</button>' +
          '<button type="button" class="agents-link" data-act="drop-send" data-oid="' + o.id + '">Dismiss</button></div>';
      }
      return '<div class="agents-msg is-user is-outgoing' + (meta[1] ? ' is-failed' : '') + '">' +
        '<div class="agents-bubble">' + esc(o.text) + '</div>' +
        '<div class="agents-msg-meta' + (meta[1] ? ' tone-failed' : '') + '">' + esc(meta[0]) + '</div>' + actions + '</div>';
    }).join(''));
  }

  // A sent message has landed once a user turn with the same words shows up
  // past where the transcript ended when it was sent.
  function reconcileOutgoing(ckey) {
    const list = st.outgoing[ckey];
    const ch = st.chats[ckey];
    if (!list || !ch) return;
    const users = ch.messages.filter((m) => m.role === 'user');
    const used = new Set();
    list.forEach((o) => {
      if (o.landed || o.state === 'failed' || o.state === 'sending') return;
      const hit = users.find((m) => m.i >= o.baseEnd && !used.has(m.i) && norm(m.text) === o.norm);
      if (hit) {
        used.add(hit.i);
        o.landed = true;
        o.state = 'delivered';
        (st.delivered[ckey] || (st.delivered[ckey] = new Set())).add(hit.i);
      }
    });
    st.outgoing[ckey] = list.filter((o) => !o.landed || Date.now() - (o.at || 0) < 600000);
  }

  // The list may (later) carry each session's recent deliveries; fold their states in.
  function applyServerDeliveries() {
    allConvs().forEach((c) => {
      const ds = Array.isArray(c.deliveries) ? c.deliveries : null;
      const list = st.outgoing[c.ckey];
      if (!ds || !list) return;
      list.forEach((o) => {
        const d = o.deliveryId && ds.find((x) => x && x.id === o.deliveryId);
        if (d && d.state && !o.landed) { o.state = d.state; o.reason = d.reason || ''; }
      });
    });
  }

  async function loadChat(ckey) {
    let ch = st.chats[ckey];
    if (!ch) ch = st.chats[ckey] = { messages: [], start: 0, total: 0, loading: true, fetching: false, error: '' };
    if (ch.fetching) return;
    ch.fetching = true;
    try {
      const full = !ch.messages.length;
      const q = full ? { ckey, after: 0, limit: PAGE }
        : { ckey, after: Math.max(ch.start, ch.start + ch.messages.length - 1) };
      const page = await api(API + '/agents/messages?' + encQ(q));
      if (!applyPage(ch, page, full)) {
        const again = await api(API + '/agents/messages?' + encQ({ ckey, after: 0, limit: PAGE }));
        applyPage(ch, again, true);
      }
      ch.error = '';
    } catch (e) {
      if (e && e.status === 404) { ch.error = 'gone'; ch.messages = []; ch.start = 0; }
    } finally {
      ch.loading = false;
      ch.fetching = false;
    }
    reconcileOutgoing(ckey);
    if (st.selected === ckey && st.pane === 'session') updateSession();
  }

  // Fold a page in (the iPhone's CodingStreamReducer): the last message grows
  // in place as a turn goes on, so a refresh re-reads it and anything after.
  function applyPage(ch, page, full) {
    // A long Mac chat whose copy is still on its way: the server has only its
    // oldest part, so it says how far it is. Keep what's shown.
    ch.syncing = (page && page.syncing) || null;
    if (ch.syncing) return true;
    const msgs = (page && page.messages) || [];
    const total = Number(page && page.total) || 0;
    if (!full) {
      const end = ch.start + ch.messages.length;
      if (total < end) return false;                      // the transcript shrank: reload
      const fresh = msgs.filter((m) => m.i >= end).map((m) => m.i);
      if (fresh.length && Math.min.apply(null, fresh) > end) return false;   // a gap: reload rather than lose one
    }
    if (full) {
      ch.messages = msgs.slice();
      ch.start = Number(page && page.start) || (msgs[0] ? msgs[0].i : 0);
    } else {
      msgs.forEach((m) => {
        const end = ch.start + ch.messages.length;
        if (m.i >= ch.start && m.i < end) ch.messages[m.i - ch.start] = m;
        else if (m.i === end) ch.messages.push(m);
      });
    }
    ch.total = total;
    return true;
  }

  async function loadOlder(ckey) {
    const ch = st.chats[ckey];
    if (!ch || ch.start <= 0 || ch.olderLoading) return;
    ch.olderLoading = true;
    updateTranscript(ckey);
    try {
      const page = await api(API + '/agents/messages?' + encQ({ ckey, before: ch.start, limit: PAGE }));
      const older = ((page && page.messages) || []).filter((m) => m.i < ch.start);
      const last = older[older.length - 1];
      if (last && last.i === ch.start - 1 && older[0].i === page.start && older.length === ch.start - page.start) {
        ch.messages = older.concat(ch.messages);
        ch.start = page.start;
      }
    } catch (_) { /* a blip: the button stays */ }
    finally { ch.olderLoading = false; }
    if (st.selected === ckey) updateTranscript(ckey);
  }

  // A tool's output and diff aren't in the list page; fetch that one message in full.
  async function loadDetails(ckey, i) {
    const map = st.details[ckey] || (st.details[ckey] = {});
    if (map[i] !== undefined && map[i] !== 'error') return;
    map[i] = 'loading';
    try {
      const page = await api(API + '/agents/messages?' + encQ({ ckey, before: i + 1, limit: 1, lite: 0 }));
      const m = ((page && page.messages) || []).find((x) => x.i === i);
      const stillLite = !m || ((m.tools || []).length && (m.tools || []).every((t) =>
        !t.output && !(t.diff && t.diff.length)));
      map[i] = stillLite ? 'none' : m;
    } catch (_) {
      map[i] = 'error';
    }
    if (st.selected === ckey) updateTranscript(ckey);
  }

  function onTranscriptScroll(e) {
    const box = e.currentTarget;
    if (box.scrollTop < 40 && st.selected) {
      const ch = st.chats[st.selected];
      if (ch && ch.start > 0 && !ch.olderLoading) loadOlder(st.selected);
    }
  }

  // ── composer ───────────────────────────────────────────────────────────
  function updateComposer(c) {
    const ta = $('agentsInput');
    const btn = $('agentsSend');
    const blocked = $('agentsBlocked');
    if (!ta || !btn || !blocked) return;
    const reason = cantSendReason(c);
    const working = isWorking(c);
    ta.disabled = !!reason;
    ta.placeholder = reason ? 'Can’t send to this session right now'
      : working ? 'Message ' + agentName(c.agent) + '…  (Enter queues it for after this turn, Ctrl+Enter sends now)'
      : 'Message ' + agentName(c.agent) + '…  (Enter sends, Shift+Enter for a new line)';
    btn.disabled = !!reason || !ta.value.trim();
    btn.title = working ? 'Queue for after this turn (Enter)' : 'Send (Enter)';
    const now = $('agentsSendNow');
    if (now) { now.hidden = !working || !!reason; now.disabled = !!reason || !ta.value.trim(); }
    blocked.hidden = !reason;
    let actions = '';
    if (reason && c.can_continue_server) {
      actions += '<button type="button" class="agents-btn is-small is-primary" data-act="continue-server">Continue on server</button>';
    }
    if (reason && c.can_resume) {
      actions += '<button type="button" class="agents-btn is-small" data-act="resume-server">Resume on server</button>';
    }
    setHtml(blocked, reason ? '<span>' + esc(reason) + '</span>' + actions : '');
  }

  function isWorking(c) { return c.state === 'working' || c.state === 'thinking'; }

  // While the agent works a message joins its own queue (the terminal's
  // Enter); ``now`` sends it straight in (its Ctrl+Enter).
  async function send(retryText, now) {
    const c = currentConv();
    const ta = $('agentsInput');
    if (!c || !ta) return;
    const text = (retryText != null ? retryText : ta.value).trim();
    if (!text || cantSendReason(c)) return;
    const ch = st.chats[c.ckey];
    const o = { id: ++st.seq, text, norm: norm(text), state: 'sending', reason: '', at: Date.now(),
      now: !!now, baseEnd: ch ? ch.start + ch.messages.length : 0 };
    (st.outgoing[c.ckey] || (st.outgoing[c.ckey] = [])).push(o);
    if (retryText == null) { ta.value = ''; delete st.drafts[c.ckey]; }
    st.scrollToEnd = true;
    updateSession();
    try {
      const res = await post('/agents/send', now ? { ckey: c.ckey, text, now: true } : { ckey: c.ckey, text });
      takeDelivery(o, res && res.delivery);
    } catch (e) {
      let d = null;
      try { d = (JSON.parse((e && e.body) || '{}') || {}).delivery; } catch (_) { /* not JSON */ }
      if (d) takeDelivery(o, d);
      else { o.state = 'failed'; o.reason = errText(e, ''); }
    }
    if (st.selected === c.ckey) updateSession();
    refreshSoon(1200);
  }
  function takeDelivery(o, d) {
    if (!d) { o.state = 'sent'; return; }
    o.deliveryId = d.id || '';
    o.state = d.state || 'sent';
    o.reason = d.reason || '';
  }

  // ── actions ────────────────────────────────────────────────────────────
  async function doContinue(ckeys, to, opts) {
    const o = opts || {};
    const busyKey = 'continue:' + ckeys.join(',');
    // A session already on its way (a row's Continue during "Continue all")
    // isn't asked again: two moves at once could start it twice.
    const keys = ckeys.filter((k) => !st.moving.has(k));
    if (!keys.length || st.busy[busyKey]) return;
    st.busy[busyKey] = true;
    keys.forEach((k) => st.moving.add(k));
    renderAll();
    try {
      const res = await post('/agents/continue', { ckeys: keys, to, confirm_offline: !!o.confirmOffline });
      const results = (res && res.results) || {};
      const confirm = [];
      const errors = [];
      keys.forEach((k) => {
        const r = results[k] || {};
        if (r.ok) return;
        if (r.reason === 'confirm_offline' && !o.confirmOffline) confirm.push(k);
        else errors.push(continueFailure(r));
      });
      st.confirm = confirm.length ? { ckeys: confirm, to, scope: o.scope || 'session', name: o.name } : null;
      if (errors.length) setFlash(o.scope || 'session', errors[0], 'error');
      else if (!confirm.length) {
        setFlash(o.scope === 'card' ? 'list' : (o.scope || 'session'),
          to === 'server' ? 'Continuing on the server…' : 'Moving it back to the Mac…', 'ok');
      }
    } catch (e) {
      setFlash(o.scope || 'session', errText(e, 'It couldn’t move.'), 'error');
    } finally {
      delete st.busy[busyKey];
      keys.forEach((k) => st.moving.delete(k));
      renderAll();
      refreshSoon();
    }
  }

  async function resume(c, where) {
    if (!c || st.busy.resume) return;
    st.busy.resume = true;
    st.menuOpen = false;
    renderAll();
    try {
      await post('/agents/resume', { ckey: c.ckey, where });
      setFlash('session', where === 'server' ? 'Resuming it on the server…' : 'Resuming it on ' + macName(c) + '…', 'ok');
    } catch (e) {
      setFlash('session', errText(e, 'It couldn’t resume.'), 'error');
    } finally {
      delete st.busy.resume;
      renderAll();
      refreshSoon();
    }
  }

  async function stopSession(c) {
    if (!c || st.busy.stop) return;
    st.busy.stop = true;
    renderAll();
    try {
      const res = await post('/agents/stop', { ckey: c.ckey });
      setFlash('session', res && res.pending ? 'Asked ' + (c.owner_name || 'the Mac') + ' to stop it.' : 'Stopped.', 'ok');
      if (st.termCkey === c.ckey) closeTerminal();
    } catch (e) {
      setFlash('session', errText(e, 'It couldn’t be stopped.'), 'error');
    } finally {
      delete st.busy.stop;
      st.stopConfirm = false;
      renderAll();
      refreshSoon();
    }
  }

  async function dismissCard(deviceId) {
    if (!deviceId) return;
    if (st.list && st.list.card) st.list.card = null;   // it leaves at once
    st.confirm = st.confirm && st.confirm.scope === 'card' ? null : st.confirm;
    renderAll();
    try { await post('/agents/card/dismiss', { device_id: deviceId }); }
    catch (e) { setFlash('list', errText(e, 'Couldn’t dismiss it.'), 'error'); }
    refreshSoon();
  }

  async function loadProjectSync(force) {
    if (st.projSyncLoading) return;
    const c = currentConv();
    if (!c || c.project_id == null || (!force && st.projSync[String(c.project_id)] !== undefined)) return;
    st.projSyncLoading = true;
    try {
      const res = await api(API + '/projects');
      ((res && res.projects) || []).concat((res && res.ignored) || []).forEach((p) => {
        if (p && p.id != null) st.projSync[String(p.id)] = !!p.sync_enabled;
      });
    } catch (_) { /* leave it unknown */ }
    finally { st.projSyncLoading = false; }
    if (st.menuOpen) updateSession();
  }

  async function toggleSync(c) {
    const pid = c && c.project_id != null ? String(c.project_id) : '';
    const on = st.projSync[pid];
    if (!pid || on === undefined || st.busy.sync) return;
    st.busy.sync = true;
    try {
      await post('/agents/project/sync', { project_id: pid, on: !on });
      st.projSync[pid] = !on;
      setFlash('session', !on ? 'This project syncs with the server now.'
        : 'Sync is off for this project. It won’t turn back on by itself.', 'ok');
    } catch (e) {
      setFlash('session', errText(e, 'Couldn’t change sync.'), 'error');
    } finally {
      delete st.busy.sync;
      st.menuOpen = false;
      renderAll();
    }
  }

  function copyText(text) {
    try {
      if (typeof _copyText === 'function') return _copyText(text);
      if (navigator.clipboard) return navigator.clipboard.writeText(text);
    } catch (_) { /* fall through */ }
    return Promise.reject(new Error('no clipboard'));
  }

  // ── terminal drawer ────────────────────────────────────────────────────
  function termHeight() {
    const n = Number(storeGet(TERM_H_KEY));
    return n >= 140 && n <= 2000 ? n : TERM_H_DEFAULT;
  }
  function applyTermHeight(h) {
    const drawer = $('agentsTermDrawer');
    if (drawer) drawer.style.setProperty('--agents-term-h', (h || termHeight()) + 'px');
  }
  async function openTerminal() {
    const c = currentConv();
    if (!c || !c.can_terminal) return;
    const ckey = c.ckey;
    st.termOpen = true;
    st.termCkey = ckey;
    st.menuOpen = false;
    updateSession();
    const host = $('agentsTermHost');
    if (host) host.innerHTML = '<div class="agents-term-msg">Opening the terminal…</div>';
    try {
      const host2 = $('agentsTermHost');
      const r = host2 ? host2.getBoundingClientRect() : null;
      const cols = r && r.width ? Math.max(40, Math.floor(r.width / 7.8)) : 100;
      const rows = r && r.height ? Math.max(8, Math.floor(r.height / 17)) : 24;
      const res = await post('/agents/terminal/start', { ckey, rows, cols });
      if (!st.termOpen || st.termCkey !== ckey) return;
      if (!window.AgentsTerminal) throw new Error('The terminal module didn’t load.');
      if (!res || !res.terminal_id) throw new Error('The server didn’t open a terminal for this session.');
      const el = $('agentsTermHost');
      if (el) {
        window.AgentsTerminal.mount(el, res.terminal_id, { onClosed: () => { /* the note is written in the terminal */ } });
        window.AgentsTerminal.focus();
      }
    } catch (e) {
      const el = $('agentsTermHost');
      if (el && st.termCkey === ckey) el.innerHTML = '<div class="agents-term-msg">' + esc(errText(e, 'The terminal couldn’t open.')) + '</div>';
    }
  }
  function closeTerminal() {
    if (window.AgentsTerminal) window.AgentsTerminal.close();
    st.termOpen = false;
    st.termCkey = null;
    const host = $('agentsTermHost');
    if (host) host.innerHTML = '';
    const drawer = $('agentsTermDrawer');
    if (drawer) drawer.hidden = true;
    if (st.pane === 'session') updateSession();
  }

  function onPointerDown(e) {
    const grip = e.target.closest('[data-drag="term"]');
    if (!grip) return;
    const drawer = $('agentsTermDrawer');
    const sess = grip.closest('.agents-sess');
    if (!drawer || !sess) return;
    e.preventDefault();
    const startY = e.clientY;
    const startH = drawer.getBoundingClientRect().height;
    const maxH = Math.max(180, sess.getBoundingClientRect().height * 0.8);
    let h = startH;
    try { grip.setPointerCapture(e.pointerId); } catch (_) { /* old browser */ }
    const move = (ev) => {
      h = Math.round(Math.max(140, Math.min(maxH, startH + (startY - ev.clientY))));
      applyTermHeight(h);
    };
    const up = () => {
      grip.removeEventListener('pointermove', move);
      grip.removeEventListener('pointerup', up);
      grip.removeEventListener('pointercancel', up);
      storeSet(TERM_H_KEY, String(h));
      if (window.AgentsTerminal) window.AgentsTerminal.refit();
    };
    grip.addEventListener('pointermove', move);
    grip.addEventListener('pointerup', up);
    grip.addEventListener('pointercancel', up);
  }

  // ── launch form ────────────────────────────────────────────────────────
  function desktopDevices() {
    const MOBILE = ['mobile-ios', 'mobile'];
    return (st.devices || []).filter((d) => {
      const k = String(d.kind || '').toLowerCase();
      if (MOBILE.includes(k)) return false;
      if (typeof d.sync_capable === 'boolean') return d.sync_capable;
      return k === 'desktop' || d.bridge_connected;
    });
  }
  function whereOptionsHtml() {
    return '<option value="server">Server</option>' + desktopDevices().map((d) => {
      const id = String(d.id != null ? d.id : (d.device_id || ''));
      const name = d.name || d.device_name || 'Mac';
      return '<option value="' + esc(id) + '"' + (d.online === false ? ' disabled' : '') + '>' + esc(name) +
        (d.online === false ? ' (offline)' : '') + '</option>';
    }).join('');
  }
  function launchHtml() {
    return '<div class="agents-launch">' +
      '<div class="agents-launch-head"><button type="button" class="agents-back" data-act="back" aria-label="Back to the list">‹ Agents</button>' +
      '<h3 class="agents-launch-title">New session</h3></div>' +
      '<form class="agents-launch-form" id="agentsLaunchForm" autocomplete="off">' +
        '<div class="agents-field-row">' +
          '<label class="agents-field"><span class="agents-label">Agent</span>' +
          '<select class="agents-select" id="agentsLaunchAgent"><option value="claude">Claude Code</option><option value="codex">Codex</option></select></label>' +
          '<label class="agents-field"><span class="agents-label">Run on</span>' +
          '<select class="agents-select" id="agentsLaunchWhere">' + whereOptionsHtml() + '</select></label>' +
        '</div>' +
        '<label class="agents-field"><span class="agents-label">Folder</span>' +
          '<input class="agents-text" id="agentsLaunchCwd" list="agentsLaunchDirs" spellcheck="false" ' +
          'placeholder="~/codingprojects/my-app" required>' +
          '<datalist id="agentsLaunchDirs"></datalist>' +
          '<span class="agents-hint" id="agentsLaunchCwdHint">A folder on the server. A new one is created.</span></label>' +
        '<div class="agents-field-row" id="agentsLaunchClaudeOpts">' +
          '<label class="agents-field"><span class="agents-label">Model <i>optional</i></span>' +
          '<input class="agents-text" id="agentsLaunchModel" spellcheck="false" placeholder="Default"></label>' +
          '<label class="agents-field"><span class="agents-label">Permissions</span>' +
          '<select class="agents-select" id="agentsLaunchPerm">' +
          PERMISSION_MODES.map((m) => '<option value="' + m[0] + '">' + esc(m[1]) + '</option>').join('') +
          '</select></label>' +
        '</div>' +
        '<label class="agents-field"><span class="agents-label">First message <i>optional</i></span>' +
          '<textarea class="agents-text agents-textarea" id="agentsLaunchPrompt" rows="4" placeholder="What should it work on?"></textarea></label>' +
        '<div class="agents-form-err" id="agentsLaunchErr" role="alert" hidden></div>' +
        '<div class="agents-form-actions">' +
          '<button type="button" class="agents-btn" data-act="launch-cancel">Cancel</button>' +
          '<button type="submit" class="agents-btn is-primary" id="agentsLaunchBtn">Start session</button>' +
        '</div>' +
      '</form></div>';
  }

  // Folder autocomplete on the machine it runs on (GET /api/coding/dir-suggest).
  function wireLaunch() {
    const cwd = $('agentsLaunchCwd');
    const list = $('agentsLaunchDirs');
    const where = $('agentsLaunchWhere');
    const agent = $('agentsLaunchAgent');
    if (!cwd || !list || !where) return;
    const seq = { n: 0 };
    let t = 0;
    const fill = (dirs) => { list.innerHTML = (dirs || []).map((d) => '<option value="' + esc(d) + '"></option>').join(''); };
    const suggest = async () => {
      const my = ++seq.n;
      const w = where.value || 'server';
      const q = { path: cwd.value || '', host: w === 'server' ? 'server' : 'desktop' };
      if (w !== 'server') q.device_id = w;
      try {
        const res = await api(API + '/dir-suggest?' + encQ(q));
        if (my === seq.n) fill(res && res.dirs);
      } catch (_) { /* offline: keep what's there */ }
    };
    const run = () => { if (t) clearTimeout(t); t = setTimeout(suggest, 140); };
    cwd.addEventListener('input', run);
    cwd.addEventListener('focus', run);
    where.addEventListener('change', () => { fill([]); syncLaunchHints(); run(); });
    if (agent) agent.addEventListener('change', syncLaunchHints);
    syncLaunchHints();
    setTimeout(() => { try { cwd.focus(); } catch (_) { /* hidden */ } }, 30);
  }
  function syncLaunchHints() {
    const where = $('agentsLaunchWhere');
    const hint = $('agentsLaunchCwdHint');
    const agent = $('agentsLaunchAgent');
    const opts = $('agentsLaunchClaudeOpts');
    if (hint && where) {
      const opt = where.options[where.selectedIndex];
      hint.textContent = where.value === 'server' ? 'A folder on the server. A new one is created.'
        : 'A folder on ' + (opt ? opt.textContent : 'the Mac') + '.';
    }
    if (opts && agent) opts.hidden = agent.value !== 'claude';
  }
  async function openLaunch() {
    closeTerminal();
    st.pane = 'launch';
    st.view = 'session';
    st.menuOpen = false;
    renderAll();
    try {
      const res = await api('/api/devices');
      st.devices = (res && res.devices) || [];
    } catch (_) { st.devices = st.devices || []; }
    const where = $('agentsLaunchWhere');
    if (where && st.pane === 'launch') {
      const keep = where.value;
      where.innerHTML = whereOptionsHtml();
      if ([].some.call(where.options, (o) => o.value === keep)) where.value = keep;
      syncLaunchHints();
    }
  }
  async function launch() {
    const val = (id) => (($(id) || {}).value || '').trim();
    const err = $('agentsLaunchErr');
    const btn = $('agentsLaunchBtn');
    const showErr = (msg) => { if (err) { err.textContent = msg; err.hidden = false; } };
    if (err) err.hidden = true;
    const cwd = val('agentsLaunchCwd');
    if (!cwd) { showErr('Pick a folder.'); return; }
    const agent = val('agentsLaunchAgent') || 'claude';
    const where = val('agentsLaunchWhere') || 'server';
    const whereSel = $('agentsLaunchWhere');
    const whereName = where === 'server' ? 'the server'
      : ((whereSel && whereSel.options[whereSel.selectedIndex]) || {}).textContent || 'the Mac';
    const body = { cwd, where, agent };
    if (agent === 'claude') {
      if (val('agentsLaunchModel')) body.model = val('agentsLaunchModel');
      if (val('agentsLaunchPerm')) body.permission_mode = val('agentsLaunchPerm');
    }
    if (val('agentsLaunchPrompt')) body.prompt = val('agentsLaunchPrompt');
    if (btn) { btn.disabled = true; btn.textContent = 'Starting…'; }
    try {
      await post('/agents/launch', body);
      st.pane = 'empty';
      st.view = 'list';
      setFlash('list', 'Starting it on ' + whereName + '. It shows up here in a few seconds.', 'ok');
      renderAll();
      refreshSoon(1500);
    } catch (e) {
      showErr(errText(e, 'It didn’t start.'));
    } finally {
      const b = $('agentsLaunchBtn');
      if (b) { b.disabled = false; b.textContent = 'Start session'; }
    }
  }

  // ── navigation ─────────────────────────────────────────────────────────
  function selectSession(ckey) {
    if (!ckey) return;
    if (st.selected !== ckey || st.pane !== 'session') {
      if (st.termCkey && st.termCkey !== ckey) closeTerminal();
      st.menuOpen = false;
      st.stopConfirm = false;
      if (st.confirm && st.confirm.scope === 'session') st.confirm = null;
    }
    st.selected = ckey;
    st.pane = 'session';
    st.view = 'session';
    const c = conv(ckey);
    if (c) st.lastConv[ckey] = c;
    renderAll();
    loadChat(ckey);
  }
  function goBack() {
    st.view = 'list';
    if (st.pane === 'launch') st.pane = st.selected && currentConv() ? 'session' : 'empty';
    st.menuOpen = false;
    renderAll();
  }
  function splitKeys(s) { return String(s || '').split(',').map((k) => k.trim()).filter(Boolean); }

  // ── events ─────────────────────────────────────────────────────────────
  function onClick(e) {
    const t = e.target.closest('[data-act]');
    if (!t) {
      if (st.menuOpen && !e.target.closest('.agents-menu-wrap')) { st.menuOpen = false; updateSession(); }
      return;
    }
    if (t.disabled) return;
    const act = t.dataset.act;
    const c = currentConv();
    if (st.menuOpen && act !== 'menu' && act !== 'sync') st.menuOpen = false;
    switch (act) {
      case 'open': selectSession(t.dataset.ckey); break;
      case 'back': goBack(); break;
      case 'new': openLaunch(); break;
      case 'launch-cancel': goBack(); break;
      case 'toggle-group': {
        const gid = t.dataset.gid;
        const opening = t.getAttribute('aria-expanded') !== 'true';
        if (gid.startsWith('integration:')) {
          if (opening) st.openIntegrations.add(gid); else st.openIntegrations.delete(gid);
          storeSet(OPEN_INTEGRATIONS_KEY, JSON.stringify(Array.from(st.openIntegrations)));
        } else {
          if (opening) st.collapsed.delete(gid); else st.collapsed.add(gid);
          storeSet(COLLAPSE_KEY, JSON.stringify(Array.from(st.collapsed)));
        }
        renderAll();
        break;
      }
      case 'dismiss': dismissCard(t.dataset.device); break;
      case 'continue':
        doContinue(splitKeys(t.dataset.ckeys), t.dataset.to || 'server', { scope: t.dataset.scope, name: t.dataset.name });
        break;
      case 'confirm-continue':
        if (st.confirm) doContinue(st.confirm.ckeys, st.confirm.to, { scope: st.confirm.scope, name: st.confirm.name, confirmOffline: true });
        break;
      case 'confirm-cancel': st.confirm = null; renderAll(); break;
      case 'menu':
        st.menuOpen = !st.menuOpen;
        updateSession();
        if (st.menuOpen) {
          loadProjectSync(false);
          const first = document.querySelector('#agentsSessHead .agents-menu-item:not(:disabled)');
          if (first) first.focus();
        }
        break;
      case 'terminal': if (st.termOpen) closeTerminal(); else openTerminal(); break;
      case 'term-close': closeTerminal(); break;
      case 'continue-server':
        if (c) doContinue([c.ckey], 'server', { scope: 'session', name: c.owner_name || 'Your Mac' });
        break;
      case 'continue-mac': if (c) doContinue([c.ckey], 'mac', { scope: 'session' }); break;
      case 'resume-server': resume(c, 'server'); break;
      case 'resume-mac': resume(c, 'mac'); break;
      case 'sync': toggleSync(c); break;
      case 'copy-id':
        if (c && c.session_id) {
          Promise.resolve(copyText(c.session_id)).then(() => setFlash('session', 'Session id copied.', 'ok'))
            .catch(() => setFlash('session', c.session_id, 'ok')).then(renderAll);
        }
        updateSession();
        break;
      case 'stop-ask': st.stopConfirm = true; updateSession(); break;
      case 'stop-cancel': st.stopConfirm = false; updateSession(); break;
      case 'stop': stopSession(c); break;
      case 'decide': decide(t, t.dataset.decision); break;
      case 'deny-open': {
        const card = t.closest('.agents-decision');
        if (card) { st.denying[card.dataset.key] = true; updateSession(); }
        const note = document.querySelector('#agentsDecisionSlot .agents-deny-note');
        if (note) note.focus();
        break;
      }
      case 'deny-back': {
        const card = t.closest('.agents-decision');
        if (card) { delete st.denying[card.dataset.key]; updateSession(); }
        break;
      }
      case 'deny-send': {
        const card = t.closest('.agents-decision');
        if (card) decide(t, 'deny', st.denyNote[card.dataset.key] || '');
        break;
      }
      case 'pick': pick(t); break;
      case 'answer': answer(t); break;
      case 'older': if (st.selected) loadOlder(st.selected); break;
      case 'retry-send': {
        const list = st.outgoing[st.selected] || [];
        const o = list.find((x) => String(x.id) === t.dataset.oid);
        if (!o) break;
        // Nothing goes while it can't take a message: keep the bubble (and its
        // words) and say why, rather than dropping it unsent.
        const why = c ? cantSendReason(c) : 'This session isn’t in the list any more.';
        if (why) { setFlash('session', why, 'error'); updateSession(); break; }
        st.outgoing[st.selected] = list.filter((x) => x !== o);
        send(o.text, o.now);
        break;
      }
      case 'send-now': send(null, true); break;
      case 'drop-send':
        st.outgoing[st.selected] = (st.outgoing[st.selected] || []).filter((x) => String(x.id) !== t.dataset.oid);
        updateSession();
        break;
      default: break;
    }
  }

  function onKeydown(e) {
    if (e.target && e.target.id === 'agentsInput' && e.key === 'Enter' && !e.shiftKey && !e.isComposing &&
        !e.altKey) {
      e.preventDefault();
      send(null, e.ctrlKey || e.metaKey);
      return;
    }
    if (e.target && e.target.classList && e.target.classList.contains('agents-deny-note') && e.key === 'Enter') {
      e.preventDefault();
      decide(e.target, 'deny', e.target.value);
      return;
    }
    if (e.key === 'Escape') {
      if (st.menuOpen) { st.menuOpen = false; updateSession(); const b = document.querySelector('#agentsSessHead [data-act="menu"]'); if (b) b.focus(); return; }
      if (st.stopConfirm) { st.stopConfirm = false; updateSession(); return; }
      if (st.confirm) { st.confirm = null; renderAll(); return; }
    }
    if (st.menuOpen && (e.key === 'ArrowDown' || e.key === 'ArrowUp')) {
      const items = Array.from(document.querySelectorAll('#agentsSessHead .agents-menu-item:not(:disabled)'));
      if (items.length) {
        e.preventDefault();
        const i = items.indexOf(document.activeElement);
        const next = e.key === 'ArrowDown' ? (i + 1) % items.length : (i - 1 + items.length) % items.length;
        items[next].focus();
      }
      return;
    }
    const grip = e.target && e.target.closest && e.target.closest('[data-drag="term"]');
    if (grip && (e.key === 'ArrowUp' || e.key === 'ArrowDown')) {
      e.preventDefault();
      const h = Math.max(140, termHeight() + (e.key === 'ArrowUp' ? 30 : -30));
      storeSet(TERM_H_KEY, String(h));
      applyTermHeight(h);
    }
  }

  function onInput(e) {
    const t = e.target;
    if (t.id === 'agentsInput') {
      if (st.selected) st.drafts[st.selected] = t.value;
      const btn = $('agentsSend');
      if (btn) btn.disabled = t.disabled || !t.value.trim();
      const now = $('agentsSendNow');
      if (now) now.disabled = t.disabled || !t.value.trim();
    } else if (t.classList && t.classList.contains('agents-deny-note')) {
      st.denyNote[t.dataset.key] = t.value;
    }
  }
  function onSubmit(e) {
    if (e.target.id === 'agentsForm') { e.preventDefault(); send(); }
    else if (e.target.id === 'agentsLaunchForm') { e.preventDefault(); launch(); }
  }
  function onToggle(e) {
    const d = e.target;
    if (!d || d.tagName !== 'DETAILS' || !d.dataset.tool) return;
    const k = d.dataset.tool;
    const parts = k.split(':');
    const ti = Number(parts.pop());
    const i = Number(parts.pop());
    const ckey = parts.join(':');
    // A re-rendered <details open> fires toggle too; only a real change counts.
    if (st.openTools.has(k) === d.open) return;
    if (d.open) st.openTools.add(k); else st.openTools.delete(k);
    if (d.open) {
      const ch = st.chats[ckey];
      const m = ch && ch.messages[i - ch.start];
      const t = m && (m.tools || [])[ti];
      if (t && t.more && !t.output && !(t.diff && t.diff.length)) loadDetails(ckey, i);
    }
    if (st.selected === ckey) updateTranscript(ckey);
  }

  document.addEventListener('click', (e) => {
    if (!st.menuOpen) return;
    // The panel's own handler may have re-rendered the clicked button away
    // (opening the menu does): a detached target isn't a click outside.
    if (!e.target || !e.target.isConnected) return;
    const root = $('mainAgents');
    if (root && !root.contains(e.target)) { st.menuOpen = false; updateSession(); }
  });

  // ── polling ────────────────────────────────────────────────────────────
  function shouldTail(ckey) {
    const c = conv(ckey);
    const ch = st.chats[ckey];
    if (!ch) return true;
    if ((st.outgoing[ckey] || []).some((o) => !o.landed && o.state !== 'failed')) return true;
    return !!(c && (c.status === 'live' || c.status === 'moving'));
  }
  async function tick() {
    if (!st.active || st.inflight) return;
    st.inflight = true;
    try {
      const [list, pend] = await Promise.all([
        api(API + '/agents/list'),
        api(API + '/permission/pending').catch(() => null),
      ]);
      if (list && typeof list === 'object') {
        st.list = list;
        st.error = '';
        allConvs().forEach((c) => { if (c.ckey) st.lastConv[c.ckey] = c; });
      }
      if (pend && Array.isArray(pend.pending)) st.requests = pend.pending;
      // Forget decisions that are long settled.
      Object.keys(st.settled).forEach((k) => { if (Date.now() - st.settled[k] > SETTLED_MS * 4) delete st.settled[k]; });
    } catch (e) {
      st.error = st.list ? 'Can’t reach the server right now. This is what it last said.'
        : 'Can’t reach the server right now.';
    } finally {
      st.inflight = false;
    }
    if (!st.active) return;
    applyServerDeliveries();
    if (st.deepCkey && conv(st.deepCkey)) { const k = st.deepCkey; st.deepCkey = null; selectSession(k); return; }
    renderAll();
    if (st.pane === 'session' && st.selected && shouldTail(st.selected)) loadChat(st.selected);
  }
  function schedule() {
    clearTimeout(st.timer);
    if (!st.active || document.hidden) return;
    st.timer = setTimeout(async () => { await tick(); schedule(); }, POLL_MS);
  }
  function refreshSoon(ms) {
    clearTimeout(st.soon);
    st.soon = setTimeout(() => { if (st.active && !document.hidden) tick(); }, ms || 600);
  }

  document.addEventListener('visibilitychange', () => {
    if (!st.active) return;
    if (document.hidden) { clearTimeout(st.timer); clearTimeout(st.soon); return; }
    tick().then(schedule);
  });

  // ── entry points (panels.js) ───────────────────────────────────────────
  async function loadAgents() {
    if (!ensureShell()) return;
    if (!st.active) {
      try {
        const q = new URLSearchParams(location.search || '');
        if (q.get('ckey')) st.deepCkey = q.get('ckey');
      } catch (_) { /* no query */ }
    }
    st.active = true;
    renderAll();
    await tick();
    schedule();
  }
  function onAgentsPanelLeave() {
    st.active = false;
    clearTimeout(st.timer);
    clearTimeout(st.soon);
    st.menuOpen = false;
    closeTerminal();
  }

  window.loadAgents = loadAgents;
  window.onAgentsPanelLeave = onAgentsPanelLeave;
})();

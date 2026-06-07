/* ============================================================================
 * Coding tab — drive interactive `claude` coding sessions from the WebUI.
 *
 * Renders into #mainCoding: a projects+sessions list on the left and a detail
 * pane on the right (launch form + live status + subagent list + composer +
 * stop). Talks to the /api/coding/* JSON API (cookie auth, same as every other
 * panel — uses the shared global api() helper from workspace.js).
 *
 * Mirrors the Code Memory tab's structure/look (frosted cards, .cm-* style
 * tokens reused where practical, plus a small set of .cdg-* classes in
 * style.css). The whole thing is full-width (body.coding-fullwidth hides the
 * conversation sidebar, like codememory).
 *
 * MVP scope: NO live terminal yet. We poll the selected session's status +
 * subagent list every few seconds and render a textual snapshot. A live
 * tmux-attach terminal (xterm.js, already loaded in index.html) is a later
 * enhancement — see the TODO near _codingStartPoll().
 * ========================================================================== */

// Module state. Kept on window-adjacent locals (the file is loaded as a plain
// <script defer>, sharing global scope with the other panel scripts).
let _codingSessionsCache = [];      // [{id,title,status,cwd,...}]
let _codingProjectsCache = [];      // [{repo_path,name,...}]
let _codingSelectedId = null;       // currently-open session id (string) or null
let _codingPollTimer = null;        // setInterval handle for the detail poll
let _codingLoaded = false;          // idempotency guard for the one-time shell render
let _codingDetailShellId = null;    // session id the detail shell is built for
let _codingTerm = null;             // xterm instance for the live terminal
let _codingTermES = null;           // EventSource for terminal output
let _codingTermFit = null;          // xterm FitAddon
let _codingTermResize = null;       // bound window resize handler
let _codingTermMountedId = null;    // session id the terminal is attached to
const _CODING_POLL_MS = 4000;       // detail status/subagent refresh cadence

function _cdgEsc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}

function _cdgStatusClass(status) {
  const s = String(status || '').toLowerCase();
  if (s === 'running' || s === 'active' || s === 'busy') return 'running';
  if (s === 'done' || s === 'completed' || s === 'finished') return 'done';
  if (s === 'error' || s === 'failed') return 'error';
  if (s === 'stopped' || s === 'cancelled' || s === 'canceled') return 'stopped';
  return 'idle';
}

/**
 * Entry point — wired into panels.js switchPanel() lazy-load dispatch.
 * Idempotent: renders the static shell once, then (re)loads the list every
 * time the panel is shown.
 */
async function loadCoding() {
  const root = document.getElementById('mainCoding');
  if (!root) return;
  if (!_codingLoaded) {
    _codingRenderShell(root);
    _codingLoaded = true;
  }
  await _codingRefreshList();
}
window.loadCoding = loadCoding;

function _codingRenderShell(root) {
  // Body of #mainCoding lives below the .cm-header already present in index.html.
  // We render the two-column body here so the shell stays declarative-light.
  const body = root.querySelector('#codingBody');
  if (!body) return;
  body.innerHTML = `
    <aside class="cdg-side" id="codingSide">
      <div class="cdg-side-head">
        <span class="cdg-side-title">Sessions</span>
        <button type="button" class="cdg-new-btn" id="codingNewBtn" onclick="codingShowLaunch()" title="New coding session">+ New</button>
      </div>
      <div class="cdg-list" id="codingList"><div class="cm-projects-empty">Loading…</div></div>
    </aside>
    <section class="cdg-detail" id="codingDetail">
      <div class="cm-detail-body"><div class="cm-empty">Select a session, or start a new one.</div></div>
    </section>`;
}

async function _codingRefreshList() {
  const list = document.getElementById('codingList');
  if (!list) return;
  try {
    const [sessRes, projRes] = await Promise.all([
      api('/api/coding/sessions').catch(() => ({ sessions: [] })),
      api('/api/coding/projects').catch(() => ({ projects: [] })),
    ]);
    _codingSessionsCache = (sessRes && sessRes.sessions) || [];
    _codingProjectsCache = (projRes && projRes.projects) || [];
    _codingRenderList();
    // Re-open the previously selected session if it still exists; otherwise
    // show the launch form so the panel is never just an empty pane.
    if (_codingSelectedId && _codingSessionsCache.some(s => String(s.id) === String(_codingSelectedId))) {
      // keep current detail (poll refreshes it)
    } else if (!_codingSelectedId) {
      // leave the empty/launch hint as-is
    }
  } catch (e) {
    list.innerHTML = '<div class="cm-projects-empty">Couldn\'t load coding sessions (is JarvisCopilot reachable?)</div>';
  }
}

function _codingRenderList() {
  const list = document.getElementById('codingList');
  if (!list) return;
  const sessions = _codingSessionsCache.slice().sort((a, b) =>
    String((b && b.created_at) || '').localeCompare(String((a && a.created_at) || '')));
  if (!sessions.length) {
    list.innerHTML = '<div class="cm-projects-empty">No coding sessions yet.<br><br>Click <b>+ New</b> to launch a headless <code>claude</code> session against a repo.</div>';
    return;
  }
  list.innerHTML = sessions.map(s => {
    const id = String(s.id != null ? s.id : '');
    const title = s.title || s.cwd || s.repo_path || id;
    const sub = s.cwd || s.repo_path || '';
    const st = _cdgStatusClass(s.status);
    const active = String(_codingSelectedId) === id ? ' active' : '';
    return `<button class="cdg-item${active}" data-id="${_cdgEsc(id)}" onclick="codingOpenSession('${_cdgEsc(id)}')">
      <div class="cdg-item-top">
        <span class="cdg-item-name">${_cdgEsc(title)}</span>
        <span class="cdg-dot cdg-dot-${st}" title="${_cdgEsc(s.status || 'idle')}"></span>
      </div>
      <div class="cdg-item-sub">${_cdgEsc(sub)}</div>
    </button>`;
  }).join('');
}

/* ── Launch form ─────────────────────────────────────────────────────────── */

function codingShowLaunch() {
  _codingStopPoll();
  _codingSelectedId = null;
  document.querySelectorAll('.cdg-item').forEach(b => b.classList.remove('active'));
  const detail = document.getElementById('codingDetail');
  if (!detail) return;
  // Project <datalist> options from the known-projects list, so the cwd field
  // autocompletes repo paths the server already knows about.
  const projOpts = (_codingProjectsCache || []).map(p => {
    const path = p.repo_path || p.path || p.cwd || '';
    const name = p.name || path;
    return `<option value="${_cdgEsc(path)}">${_cdgEsc(name)}</option>`;
  }).join('');
  detail.innerHTML = `
    <div class="cm-detail-body">
      <div class="cdg-form-card">
        <div class="cdg-form-title">New coding session</div>
        <label class="cdg-label" for="codingCwd">Working directory</label>
        <input class="cdg-input" id="codingCwd" list="codingProjList" placeholder="~/code/your-project  (~ expands, new folders are created)" autocomplete="off">
        <datalist id="codingProjList">${projOpts}</datalist>
        <div class="cdg-hint"><code>~</code> and relative paths work; the folder is created if it doesn't exist.</div>

        <label class="cdg-label" for="codingTitle">Title (optional)</label>
        <input class="cdg-input" id="codingTitle" placeholder="What are we building?" autocomplete="off">

        <label class="cdg-label" for="codingModel">Model (optional)</label>
        <input class="cdg-input" id="codingModel" placeholder="e.g. claude-opus-4-8 (blank = server default)" autocomplete="off">

        <label class="cdg-label" for="codingHost">Run on</label>
        <select class="cdg-input" id="codingHost">
          <option value="server">This server (Jarvis host)</option>
          <option value="desktop">My computer (paired desktop)</option>
        </select>

        <label class="cdg-check"><input type="checkbox" id="codingWorktree"> <span>Run in an isolated git worktree</span></label>
        <label class="cdg-check"><input type="checkbox" id="codingSkipPerms"> <span>Dangerously skip permissions (autonomous — no approval prompts)</span></label>
        <label class="cdg-check"><input type="checkbox" id="codingSync" onchange="codingToggleSyncOpts()"> <span>Sync this project with another device</span></label>
        <div id="codingSyncOpts" style="display:none;margin:4px 0 2px 22px">
          <label class="cdg-label" for="codingSyncDevice">Device</label>
          <input class="cdg-input" id="codingSyncDevice" placeholder="paired device name (e.g. your Mac)" autocomplete="off">
          <label class="cdg-label" for="codingSyncPath">Folder path on that device</label>
          <input class="cdg-input" id="codingSyncPath" placeholder="~/code/your-project" autocomplete="off">
          <div class="cdg-hint">On launch: if that folder already has files they're pulled to the server; if it's empty, the server's folder is pushed to it. Two-way sync then keeps them in step. (Activates once that device's sync agent is connected.)</div>
        </div>

        <label class="cdg-label" for="codingPrompt">Initial prompt</label>
        <textarea class="cdg-textarea" id="codingPrompt" rows="5" placeholder="Describe the task for the coding agent…"></textarea>

        <div class="cdg-form-actions">
          <button type="button" class="cdg-btn-secondary" onclick="codingClearDetail()">Cancel</button>
          <button type="button" class="cdg-btn-primary" id="codingLaunchBtn" onclick="codingLaunch()">Launch session</button>
        </div>
        <div class="cdg-form-err" id="codingLaunchErr" style="display:none"></div>
      </div>
    </div>`;
}
window.codingShowLaunch = codingShowLaunch;

function codingClearDetail() {
  _codingStopPoll();
  _codingTeardownTerminal();
  _codingDetailShellId = null;
  _codingSelectedId = null;
  document.querySelectorAll('.cdg-item').forEach(b => b.classList.remove('active'));
  const detail = document.getElementById('codingDetail');
  if (detail) detail.innerHTML = '<div class="cm-detail-body"><div class="cm-empty">Select a session, or start a new one.</div></div>';
}
window.codingClearDetail = codingClearDetail;

function codingToggleSyncOpts() {
  const on = !!(document.getElementById('codingSync') || {}).checked;
  const opts = document.getElementById('codingSyncOpts');
  if (opts) opts.style.display = on ? '' : 'none';
}
window.codingToggleSyncOpts = codingToggleSyncOpts;

async function codingLaunch() {
  const cwd = (document.getElementById('codingCwd') || {}).value || '';
  const title = (document.getElementById('codingTitle') || {}).value || '';
  const model = (document.getElementById('codingModel') || {}).value || '';
  const prompt = (document.getElementById('codingPrompt') || {}).value || '';
  const worktree = !!(document.getElementById('codingWorktree') || {}).checked;
  const skipPerms = !!(document.getElementById('codingSkipPerms') || {}).checked;
  const syncOn = !!(document.getElementById('codingSync') || {}).checked;
  const syncDevice = ((document.getElementById('codingSyncDevice') || {}).value || '').trim();
  const syncPath = ((document.getElementById('codingSyncPath') || {}).value || '').trim();
  const host = (document.getElementById('codingHost') || {}).value || 'server';
  const errEl = document.getElementById('codingLaunchErr');
  const btn = document.getElementById('codingLaunchBtn');
  const showErr = (msg) => { if (errEl) { errEl.textContent = msg; errEl.style.display = ''; } };
  if (errEl) errEl.style.display = 'none';
  if (!cwd.trim()) { showErr('Working directory is required.'); return; }
  if (!prompt.trim()) { showErr('An initial prompt is required.'); return; }
  if (btn) { btn.disabled = true; btn.textContent = 'Launching…'; }
  try {
    // The API accepts cwd or repo_path for the directory; we send both keys set
    // to the same value so either server-side naming works.
    const payload = {
      cwd: cwd.trim(),
      repo_path: cwd.trim(),
      worktree,
      skip_permissions: skipPerms,
      host,
      title: title.trim(),
      prompt: prompt.trim(),
    };
    if (model.trim()) payload.model = model.trim();
    if (syncOn) payload.sync = { enabled: true, device: syncDevice, remote_path: syncPath };
    const res = await api('/api/coding/launch', { method: 'POST', body: JSON.stringify(payload) });
    if (!res || res.ok === false) { showErr((res && (res.error || res.message)) || 'Launch failed.'); return; }
    const sess = res.session || {};
    await _codingRefreshList();
    if (sess.id != null) codingOpenSession(String(sess.id));
  } catch (e) {
    showErr((e && e.message) || 'Launch failed.');
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = 'Launch session'; }
  }
}
window.codingLaunch = codingLaunch;

/* ── Session detail (status + subagents + composer + stop) ───────────────── */

async function codingOpenSession(id) {
  _codingSelectedId = String(id);
  document.querySelectorAll('.cdg-item').forEach(b => b.classList.toggle('active', b.dataset.id === String(id)));
  const detail = document.getElementById('codingDetail');
  if (detail) detail.innerHTML = '<div class="cm-detail-body"><div class="cm-empty">Loading…</div></div>';
  await _codingRefreshDetail();
  _codingStartPoll();
}
window.codingOpenSession = codingOpenSession;

async function _codingRefreshDetail() {
  if (!_codingSelectedId) return;
  const id = _codingSelectedId;
  let res;
  try {
    res = await api('/api/coding/session/' + encodeURIComponent(id));
  } catch (e) {
    // If the session 404s (gone), drop back to the list view.
    if (e && e.status === 404) { codingClearDetail(); _codingRefreshList(); return; }
    return; // transient — keep last render, poll again
  }
  // Ignore stale responses if the user switched sessions mid-flight.
  if (String(_codingSelectedId) !== String(id)) return;
  if (!res || res.ok === false) return;
  _codingRenderDetail(res.session || {}, res.subagents || []);
}

function _codingRenderDetail(session, subagents) {
  const detail = document.getElementById('codingDetail');
  if (!detail) return;
  const id = String(session.id != null ? session.id : _codingSelectedId || '');
  const subList = Array.isArray(subagents) ? subagents : [];

  // Build the detail SHELL once per session. Subsequent polls only update the
  // dynamic bits (status + subagents) so the live xterm terminal isn't
  // destroyed and recreated every 4s.
  if (_codingDetailShellId !== id) {
    _codingTeardownTerminal();
    _codingDetailShellId = id;
    const title = session.title || session.cwd || session.repo_path || id;
    const cwd = session.cwd || session.repo_path || '';
    const host = session.host || 'server';
    const hostLabel = host === 'desktop' ? 'desktop' : 'server';
    let _sc = {}; try { _sc = session.sync_config ? JSON.parse(session.sync_config) : {}; } catch (_) {}
    const _syncEnabled = !!_sc.enabled;
    const _syncDevice = _cdgEsc(_sc.device || '');
    const _syncPath = _cdgEsc(_sc.remote_path || '');
    const termSection = `<div class="cm-section">
           <div class="cm-section-head"><span class="cm-section-title">Live terminal</span><span class="cm-section-count" style="font-weight:400;opacity:.6">${hostLabel} · type here to talk to claude</span></div>
           <div class="cdg-term" id="codingTerm" style="height:460px;background:#0a0d13;border-radius:8px;padding:6px;overflow:hidden"></div>
         </div>`;
    detail.innerHTML = `
      <div class="cm-detail-head">
        <div class="cm-detail-titles">
          <div class="cm-detail-name">${_cdgEsc(title)}</div>
          <div class="cm-detail-slug">${_cdgEsc(cwd)}</div>
        </div>
        <div class="cdg-detail-status">
          <span class="cdg-dot cdg-dot-idle" id="codingStatusDot"></span>
          <span class="cdg-status-text" id="codingStatusText">…</span>
          <button type="button" class="cdg-btn-stop" id="codingStopBtn" onclick="codingStop()">Stop</button>
          <button type="button" class="cdg-btn-primary" id="codingRestartBtn" onclick="codingRestart()" style="display:none">Restart</button>
          <button type="button" class="cdg-btn-secondary" id="codingSettingsBtn" onclick="codingToggleSettings()">Settings</button>
          <button type="button" class="cdg-btn-secondary" id="codingDeleteBtn" onclick="codingDelete()">Delete</button>
        </div>
      </div>
      <div class="cm-detail-body">
        <div class="cm-section" id="codingSettingsPanel" style="display:none">
          <div class="cm-section-head"><span class="cm-section-title">Session settings</span><span class="cm-section-count" style="font-weight:400;opacity:.6">${hostLabel}</span></div>
          <div class="cdg-hint">Changes to the directory or skip-permissions apply on the next <b>Restart</b>.</div>
          <label class="cdg-label" for="codingSetCwd">Working directory</label>
          <input class="cdg-input" id="codingSetCwd" value="${_cdgEsc(cwd)}" autocomplete="off">
          <label class="cdg-check"><input type="checkbox" id="codingSetSkip" ${session.skip_permissions ? 'checked' : ''}> <span>Dangerously skip permissions</span></label>
          <label class="cdg-check"><input type="checkbox" id="codingSetSync" onchange="codingToggleSetSyncOpts()" ${_syncEnabled ? 'checked' : ''}> <span>Sync this project with another device</span></label>
          <div id="codingSetSyncOpts" style="display:${_syncEnabled ? '' : 'none'};margin-left:22px">
            <label class="cdg-label" for="codingSetSyncDevice">Device</label>
            <input class="cdg-input" id="codingSetSyncDevice" value="${_syncDevice}" placeholder="paired device name" autocomplete="off">
            <label class="cdg-label" for="codingSetSyncPath">Folder on that device</label>
            <input class="cdg-input" id="codingSetSyncPath" value="${_syncPath}" placeholder="~/code/your-project" autocomplete="off">
          </div>
          <div class="cdg-form-actions"><button type="button" class="cdg-btn-primary" id="codingSetSaveBtn" onclick="codingSaveSettings()">Save settings</button></div>
          <div class="cdg-form-err" id="codingSetErr" style="display:none"></div>
        </div>
        ${termSection}
      </div>`;
    _codingMountTerminal(id);   // server attaches local tmux; desktop streams over the bridge
  }
  _codingUpdateDetailStatus(session);
}

function _codingUpdateDetailStatus(session) {
  const st = _cdgStatusClass(session.status);
  const dot = document.getElementById('codingStatusDot');
  const txt = document.getElementById('codingStatusText');
  const stop = document.getElementById('codingStopBtn');
  const restart = document.getElementById('codingRestartBtn');
  if (dot) dot.className = 'cdg-dot cdg-dot-' + st;
  if (txt) txt.textContent = session.status || 'idle';
  const running = (st === 'running' || st === 'idle');
  if (stop) stop.style.display = running ? '' : 'none';
  if (restart) restart.style.display = running ? 'none' : '';
}

function _codingMountTerminal(id) {
  const host = document.getElementById('codingTerm');
  if (!host || !window.Terminal) return;
  // Attach a server-side PTY to the session's tmux, then stream it into xterm.
  api('/api/coding/session/' + encodeURIComponent(id) + '/terminal/start',
    { method: 'POST', body: JSON.stringify({ rows: 24, cols: 100 }) })
    .then(res => {
      if (_codingDetailShellId !== id) return;        // switched away during start
      if (res && res.ok === false) { host.textContent = (res.error || 'terminal unavailable'); return; }
      const term = new window.Terminal({
        cursorBlink: true, fontSize: 13,
        fontFamily: 'Menlo, Monaco, Consolas, "Liberation Mono", monospace',
        scrollback: 4000, convertEol: false,
      });
      let fit = null;
      if (window.FitAddon && typeof window.FitAddon.FitAddon === 'function') {
        fit = new window.FitAddon.FitAddon(); term.loadAddon(fit);
      }
      term.open(host);
      try { if (fit) fit.fit(); } catch (_) {}
      _codingTerm = term; _codingTermFit = fit; _codingTermMountedId = id;
      term.onData(d => api('/api/terminal/input',
        { method: 'POST', body: JSON.stringify({ session_id: id, data: d }) }).catch(() => {}));
      const sendResize = () => {
        try { if (fit) fit.fit(); } catch (_) {}
        api('/api/terminal/resize',
          { method: 'POST', body: JSON.stringify({ session_id: id, rows: term.rows, cols: term.cols }) }).catch(() => {});
      };
      _codingTermResize = sendResize;
      window.addEventListener('resize', sendResize);
      setTimeout(sendResize, 120);
      const es = new EventSource('/api/terminal/output?session_id=' + encodeURIComponent(id), { withCredentials: true });
      _codingTermES = es;
      es.addEventListener('output', ev => {
        let text = ''; try { text = (JSON.parse(ev.data) || {}).text || ''; } catch (_) {}
        if (text && _codingTerm) _codingTerm.write(text);
      });
      es.addEventListener('terminal_closed', () => { if (_codingTerm) _codingTerm.write('\r\n\x1b[90m[detached]\x1b[0m\r\n'); });
    }).catch(() => { host.textContent = 'terminal failed to start'; });
}

function _codingTeardownTerminal() {
  try { if (_codingTermES) _codingTermES.close(); } catch (_) {}
  try { if (_codingTermResize) window.removeEventListener('resize', _codingTermResize); } catch (_) {}
  // Detach the server-side PTY (does NOT kill the tmux session / claude).
  if (_codingTermMountedId) {
    api('/api/terminal/close', { method: 'POST', body: JSON.stringify({ session_id: _codingTermMountedId }) }).catch(() => {});
  }
  try { if (_codingTerm) _codingTerm.dispose(); } catch (_) {}
  _codingTerm = null; _codingTermES = null; _codingTermFit = null;
  _codingTermResize = null; _codingTermMountedId = null;
}

// Messages are now sent by typing directly into the live terminal (xterm ->
// /api/terminal/input). The separate composer was removed as redundant; the
// /api/coding/session/<id>/message endpoint stays for the chat skill + mobile.

async function codingStop() {
  if (!_codingSelectedId) return;
  const btn = document.getElementById('codingStopBtn');
  if (btn) { btn.disabled = true; btn.textContent = 'Stopping…'; }
  try {
    await api('/api/coding/session/' + encodeURIComponent(_codingSelectedId) + '/stop', { method: 'POST', body: JSON.stringify({}) });
    await _codingRefreshDetail();
    _codingRefreshList();
  } catch (e) {
    if (btn) { btn.disabled = false; btn.textContent = 'Stop'; }
  }
}
window.codingStop = codingStop;

async function codingRestart() {
  if (!_codingSelectedId) return;
  const id = _codingSelectedId;
  const btn = document.getElementById('codingRestartBtn');
  if (btn) { btn.disabled = true; btn.textContent = 'Restarting…'; }
  try {
    const res = await api('/api/coding/session/' + encodeURIComponent(id) + '/restart',
      { method: 'POST', body: JSON.stringify({}) });
    if (res && res.ok === false) { alert(res.error || 'Restart failed.'); return; }
    // Force a full re-render so the live terminal re-attaches to the NEW tmux.
    _codingTeardownTerminal();
    _codingDetailShellId = null;
    await _codingRefreshDetail();
    _codingRefreshList();
  } catch (e) {
    alert((e && e.message) || 'Restart failed.');
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = 'Restart'; }
  }
}
window.codingRestart = codingRestart;

async function codingDelete() {
  if (!_codingSelectedId) return;
  if (!window.confirm('Delete this coding session? This stops it and permanently removes it.')) return;
  const id = _codingSelectedId;
  try {
    await api('/api/coding/session/' + encodeURIComponent(id) + '/delete',
      { method: 'POST', body: JSON.stringify({}) });
    codingClearDetail();
    _codingRefreshList();
  } catch (e) {
    alert((e && e.message) || 'Delete failed.');
  }
}
window.codingDelete = codingDelete;

function codingToggleSettings() {
  const p = document.getElementById('codingSettingsPanel');
  if (p) p.style.display = (p.style.display === 'none' || !p.style.display) ? '' : 'none';
}
window.codingToggleSettings = codingToggleSettings;

function codingToggleSetSyncOpts() {
  const on = !!(document.getElementById('codingSetSync') || {}).checked;
  const o = document.getElementById('codingSetSyncOpts');
  if (o) o.style.display = on ? '' : 'none';
}
window.codingToggleSetSyncOpts = codingToggleSetSyncOpts;

async function codingSaveSettings() {
  if (!_codingSelectedId) return;
  const id = _codingSelectedId;
  const errEl = document.getElementById('codingSetErr');
  const btn = document.getElementById('codingSetSaveBtn');
  const cwd = ((document.getElementById('codingSetCwd') || {}).value || '').trim();
  const skip = !!(document.getElementById('codingSetSkip') || {}).checked;
  const syncOn = !!(document.getElementById('codingSetSync') || {}).checked;
  const dev = ((document.getElementById('codingSetSyncDevice') || {}).value || '').trim();
  const path = ((document.getElementById('codingSetSyncPath') || {}).value || '').trim();
  if (errEl) errEl.style.display = 'none';
  if (btn) { btn.disabled = true; btn.textContent = 'Saving…'; }
  try {
    const payload = { skip_permissions: skip, cwd,
      sync: { enabled: syncOn, device: dev, remote_path: path } };
    const res = await api('/api/coding/session/' + encodeURIComponent(id) + '/settings',
      { method: 'POST', body: JSON.stringify(payload) });
    if (res && res.ok === false) {
      if (errEl) { errEl.textContent = res.error || 'Save failed.'; errEl.style.display = ''; }
      return;
    }
    // re-render from the updated row (force shell rebuild)
    _codingTeardownTerminal();
    _codingDetailShellId = null;
    await _codingRefreshDetail();
  } catch (e) {
    if (errEl) { errEl.textContent = (e && e.message) || 'Save failed.'; errEl.style.display = ''; }
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = 'Save settings'; }
  }
}
window.codingSaveSettings = codingSaveSettings;

/* ── Polling lifecycle ───────────────────────────────────────────────────── */

function _codingStartPoll() {
  _codingStopPoll();
  // TODO(live-terminal): replace/augment this poll with a WebSocket-backed
  // tmux-attach terminal stream once the backend exposes it.
  _codingPollTimer = setInterval(() => {
    // Stop polling if we've navigated away from the Coding panel.
    if (typeof _currentPanel === 'string' && _currentPanel !== 'coding') { _codingStopPoll(); return; }
    _codingRefreshDetail();
  }, _CODING_POLL_MS);
}

function _codingStopPoll() {
  if (_codingPollTimer) { clearInterval(_codingPollTimer); _codingPollTimer = null; }
}

// Cleared from panels.js when the panel is switched away (mirrors how other
// panels stop their timers), but also self-guards inside the interval above.
function onCodingPanelLeave() { _codingStopPoll(); _codingTeardownTerminal(); _codingDetailShellId = null; }
window.onCodingPanelLeave = onCodingPanelLeave;

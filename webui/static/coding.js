/* ============================================================================
 * Coding tab — drive headless `claude` coding sessions from the WebUI.
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
        <label class="cdg-label" for="codingCwd">Working directory (cwd / repo_path)</label>
        <input class="cdg-input" id="codingCwd" list="codingProjList" placeholder="/Users/you/code/your-repo" autocomplete="off">
        <datalist id="codingProjList">${projOpts}</datalist>

        <label class="cdg-label" for="codingTitle">Title (optional)</label>
        <input class="cdg-input" id="codingTitle" placeholder="What are we building?" autocomplete="off">

        <label class="cdg-label" for="codingModel">Model (optional)</label>
        <input class="cdg-input" id="codingModel" placeholder="e.g. claude-opus-4-8 (blank = server default)" autocomplete="off">

        <label class="cdg-check"><input type="checkbox" id="codingWorktree"> <span>Run in an isolated git worktree</span></label>

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
  _codingSelectedId = null;
  document.querySelectorAll('.cdg-item').forEach(b => b.classList.remove('active'));
  const detail = document.getElementById('codingDetail');
  if (detail) detail.innerHTML = '<div class="cm-detail-body"><div class="cm-empty">Select a session, or start a new one.</div></div>';
}
window.codingClearDetail = codingClearDetail;

async function codingLaunch() {
  const cwd = (document.getElementById('codingCwd') || {}).value || '';
  const title = (document.getElementById('codingTitle') || {}).value || '';
  const model = (document.getElementById('codingModel') || {}).value || '';
  const prompt = (document.getElementById('codingPrompt') || {}).value || '';
  const worktree = !!(document.getElementById('codingWorktree') || {}).checked;
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
      title: title.trim(),
      prompt: prompt.trim(),
    };
    if (model.trim()) payload.model = model.trim();
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
  const title = session.title || session.cwd || session.repo_path || id;
  const cwd = session.cwd || session.repo_path || '';
  const st = _cdgStatusClass(session.status);
  const statusLabel = session.status || 'idle';
  const isRunning = st === 'running' || st === 'idle';
  const subList = Array.isArray(subagents) ? subagents : [];
  const subHtml = subList.length
    ? subList.map(sa => {
        const sast = _cdgStatusClass(sa.status);
        return `<div class="cdg-sub">
          <span class="cdg-dot cdg-dot-${sast}"></span>
          <span class="cdg-sub-name">${_cdgEsc(sa.name || sa.title || sa.id || 'subagent')}</span>
          <span class="cdg-sub-status">${_cdgEsc(sa.status || '')}</span>
          ${sa.detail ? `<span class="cdg-sub-detail">${_cdgEsc(sa.detail)}</span>` : ''}
        </div>`;
      }).join('')
    : '<div class="cdg-sub-empty">No subagents.</div>';

  detail.innerHTML = `
    <div class="cm-detail-head">
      <div class="cm-detail-titles">
        <div class="cm-detail-name">${_cdgEsc(title)}</div>
        <div class="cm-detail-slug">${_cdgEsc(cwd)}</div>
      </div>
      <div class="cdg-detail-status">
        <span class="cdg-dot cdg-dot-${st}"></span>
        <span class="cdg-status-text">${_cdgEsc(statusLabel)}</span>
        <button type="button" class="cdg-btn-stop" id="codingStopBtn" onclick="codingStop()" ${isRunning ? '' : 'disabled'}>Stop</button>
      </div>
    </div>
    <div class="cm-detail-body">
      <div class="cm-section">
        <div class="cm-section-head"><span class="cm-section-title">Subagents</span><span class="cm-section-count">${subList.length}</span></div>
        <div class="cdg-subs">${subHtml}</div>
      </div>
      <div class="cm-section">
        <div class="cm-section-head"><span class="cm-section-title">Send a message</span></div>
        <textarea class="cdg-textarea" id="codingMsg" rows="3" placeholder="Send a follow-up to the coding agent…"></textarea>
        <div class="cdg-form-actions">
          <button type="button" class="cdg-btn-primary" id="codingSendBtn" onclick="codingSendMessage()">Send</button>
        </div>
        <div class="cdg-form-err" id="codingMsgErr" style="display:none"></div>
      </div>
      <!-- TODO: live tmux-attach terminal (xterm.js is already loaded in index.html).
           MVP polls status/subagents only; a real PTY stream is a later enhancement. -->
    </div>`;
}

async function codingSendMessage() {
  if (!_codingSelectedId) return;
  const ta = document.getElementById('codingMsg');
  const errEl = document.getElementById('codingMsgErr');
  const btn = document.getElementById('codingSendBtn');
  const text = ta ? ta.value.trim() : '';
  if (errEl) errEl.style.display = 'none';
  if (!text) return;
  if (btn) { btn.disabled = true; btn.textContent = 'Sending…'; }
  try {
    const res = await api('/api/coding/session/' + encodeURIComponent(_codingSelectedId) + '/message',
      { method: 'POST', body: JSON.stringify({ text }) });
    if (!res || res.ok === false) {
      if (errEl) { errEl.textContent = (res && (res.error || res.message)) || 'Send failed.'; errEl.style.display = ''; }
      return;
    }
    if (ta) ta.value = '';
    _codingRefreshDetail();
  } catch (e) {
    if (errEl) { errEl.textContent = (e && e.message) || 'Send failed.'; errEl.style.display = ''; }
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = 'Send'; }
  }
}
window.codingSendMessage = codingSendMessage;

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
function onCodingPanelLeave() { _codingStopPoll(); }
window.onCodingPanelLeave = onCodingPanelLeave;

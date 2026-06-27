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
let _codingSessionsCache = [];      // [{id,title,status,cwd,...}] flat list (all)
let _codingProjectsCache = [];      // [{id,name,repo_path,sessions:[...],...}]
let _codingUngroupedCache = [];     // [<session rows with no project>]
let _codingIgnoredCache = [];       // [<ignored (soft-deleted) projects>]
let _codingDevicesCache = [];       // [{id,name,online,...}] paired devices
let _codingSelectedId = null;       // currently-open session id (string) or null
let _codingCurrentSession = null;   // last-rendered detail session (for the ended panel)
let _codingPollTimer = null;        // setInterval handle for the detail poll
let _codingLoaded = false;          // idempotency guard for the one-time shell render
let _codingDetailShellId = null;    // session id the detail shell is built for
let _codingTerm = null;             // xterm instance for the live terminal
let _codingTermES = null;           // EventSource for terminal output
let _codingEventsES = null;         // EventSource for instant state-change nudges
let _codingEventsDebounce = null;   // coalesces nudge bursts into one refresh
let _codingTermFit = null;          // xterm FitAddon
let _codingTermResize = null;       // immediate refit (fullscreen calls this)
let _codingTermWinResize = null;    // THROTTLED window-resize listener (for removal)
let _codingTermMountedId = null;    // session id the terminal is attached to
const _CODING_POLL_MS = 4000;       // detail status/subagent refresh cadence

// Per-project collapse state (in-memory, persisted best-effort to localStorage).
// Default: expanded. A project id present in this set is COLLAPSED.
const _codingCollapsed = (() => {
  try {
    const raw = window.localStorage && localStorage.getItem('cdgCollapsedProjects');
    return new Set(raw ? JSON.parse(raw) : []);
  } catch (_) { return new Set(); }
})();
function _codingPersistCollapsed() {
  try { localStorage.setItem('cdgCollapsedProjects', JSON.stringify(Array.from(_codingCollapsed))); } catch (_) {}
}

function _cdgEsc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}

// <option> list for the sync device dropdown, built from the paired-devices
// cache. `selected` matches a device by id OR name (settings panel stores the
// chosen value). Offline devices are shown but labelled.
function _codingDeviceOptionsHtml(selected) {
  const sel = String(selected == null ? '' : selected);
  let html = '<option value="">— choose a device —</option>';
  let matched = false;
  // Only DESKTOP jc-clients can run Mutagen sync. Mobile devices ALSO hold a
  // bridge WS (notifications/phone-control), so bridge_connected alone isn't
  // enough — exclude mobile kinds. But a desktop jc-client usually registers
  // with the DEFAULT kind 'browser' (only the mobile app flips its kind), so we
  // must NOT exclude 'browser'/'' by kind — actual web browsers are filtered by
  // sync_capable/bridge_connected (they never hold a bridge). Prefer the
  // server's sync_capable flag when present.
  const MOBILE_KINDS = ['mobile-ios', 'mobile-android', 'mobile'];
  const desktops = (_codingDevicesCache || []).filter(d => {
    const k = String(d.kind || '').toLowerCase();
    if (MOBILE_KINDS.includes(k)) return false;
    if (typeof d.sync_capable === 'boolean') return d.sync_capable;
    return k === 'desktop' || d.bridge_connected;
  });
  desktops.forEach(d => {
    const id = String(d.id != null ? d.id : (d.device_id || ''));
    const name = d.name || d.device_name || id || 'device';
    const off = d.online === false ? ' (offline)' : '';
    const isSel = sel && (sel === id || sel === name);
    if (isSel) matched = true;
    html += `<option value="${_cdgEsc(id)}"${isSel ? ' selected' : ''}>${_cdgEsc(name)}${off}</option>`;
  });
  // preserve a previously-saved value even if that device isn't in the list now
  if (sel && !matched) html += `<option value="${_cdgEsc(sel)}" selected>${_cdgEsc(sel)} (not connected)</option>`;
  return html;
}

// Format a last-activity value (epoch seconds OR ms OR an ISO string) into a
// readable local datetime + a relative suffix. Returns '' for empty input and
// echoes the raw value back if it can't be parsed.
function _cdgFmtTime(v) {
  if (v == null || v === '') return '';
  let ms;
  const str = String(v).trim();
  if (/^[0-9]+(\.[0-9]+)?$/.test(str)) {
    const n = Number(str);
    ms = n > 1e12 ? n : n * 1000;   // >1e12 ⇒ already milliseconds
  } else {
    ms = Date.parse(str);
    if (isNaN(ms)) return str;
  }
  const date = new Date(ms);
  if (isNaN(date.getTime())) return str;
  const abs = date.toLocaleString(undefined, {
    year: 'numeric', month: 'short', day: 'numeric',
    hour: '2-digit', minute: '2-digit',
  });
  const rel = _cdgRelTime(Date.now() - ms);
  return rel ? `${abs} · ${rel}` : abs;
}
function _cdgRelTime(diffMs) {
  if (diffMs < 0) return '';
  const s = Math.floor(diffMs / 1000);
  if (s < 60) return 'just now';
  const m = Math.floor(s / 60);
  if (m < 60) return m + 'm ago';
  const h = Math.floor(m / 60);
  if (h < 24) return h + 'h ago';
  const d = Math.floor(h / 24);
  if (d < 30) return d + 'd ago';
  const mo = Math.floor(d / 30);
  return mo < 12 ? mo + 'mo ago' : Math.floor(mo / 12) + 'y ago';
}

function _cdgStatusClass(status) {
  const s = String(status || '').toLowerCase();
  if (s === 'running' || s === 'active' || s === 'busy') return 'running';
  if (s === 'done' || s === 'completed' || s === 'finished') return 'done';
  if (s === 'error' || s === 'failed') return 'error';
  if (s === 'stopped' || s === 'cancelled' || s === 'canceled') return 'stopped';
  return 'idle';
}

// Display state for the dot/label. A live (running) session refines into
// working / waiting / idle via its server-detected activity_state (Scheme 4:
// green / purple / grey). Non-running statuses keep their lifecycle class.
function _cdgDisplayState(s) {
  if (_codingIsTranscriptIdle(s)) return 'history';
  const status = String((s && s.status) || '').toLowerCase();
  const cls = _cdgStatusClass(status);
  // Refine ANY live session (running/starting/idle lifecycle) — the server
  // detects activity_state for all of them, so a permission prompt on an
  // idle/starting session must still read as waiting, not grey.
  const live = status === 'running' || status === 'starting' || status === 'idle';
  if (live) {
    const act = String((s && s.activity_state) || '').toLowerCase();
    if (act === 'waiting') return 'waiting';
    if (act === 'working') return 'working';
    const st = (act === 'idle') ? 'idle' : (cls === 'running' ? 'working' : 'idle');
    // A forgotten (detached + idle) discovered tmux is de-emphasized (dimmed),
    // not hidden. Mirrors the server's `_is_dim` in agent/coding_la_push.py.
    if (st === 'idle' && _codingIsDim(s)) return 'dim';
    return st;
  }
  return cls;
}

// A discovered tmux with NO client attached, sitting idle. `attached` is 1/null =
// attached (default); only an explicit 0 = detached, so we never wrongly dim.
function _codingIsDim(s) {
  const src = String((s && s.source) || '');
  return src.indexOf('discovered-tmux') === 0 &&
    s && s.attached != null && Number(s.attached) === 0;
}

function _cdgStateLabel(state) {
  switch (state) {
    case 'working': return 'working';
    case 'waiting': return 'waiting for you';
    case 'idle': return 'idle';
    case 'dim': return 'idle · detached';
    case 'history': return 'past session (not running)';
    case 'done': return 'done';
    case 'error': return 'error';
    case 'stopped': return 'stopped';
    default: return state || 'idle';
  }
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
  _codingStartStatusPoll();    // sidebar status fallback (if SSE drops)
  _codingStartEventsStream();  // instant push updates (primary path)
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
        <span class="cdg-side-title">Projects</span>
        <div class="cdg-side-actions">
          <button type="button" class="cdg-rescan-btn" id="codingCmSettingsBtn" onclick="codingCodeMasterSettings()" title="Code Master settings (notifications + usage)">⚙</button>
          <button type="button" class="cdg-rescan-btn" id="codingRescanBtn" onclick="codingRescanDiscovered()" title="Rescan paired devices for tmux + transcript sessions">⟳</button>
          <button type="button" class="cdg-new-btn cdg-new-proj" id="codingNewProjBtn" onclick="codingNewProject()" title="New project">+ Project</button>
          <button type="button" class="cdg-new-btn" id="codingNewBtn" onclick="codingShowLaunch()" title="New coding session">+ Session</button>
        </div>
      </div>
      <div class="cdg-usage" id="codingUsage" style="display:none"></div>
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
    // Projects (with nested sessions) drive the sidebar tree; the flat sessions
    // list is still fetched as a fallback (older backends / safety) and used to
    // check whether the selected session still exists.
    const [projRes, sessRes, devRes] = await Promise.all([
      api('/api/coding/projects?expand=sessions').catch(() => ({ projects: [], ungrouped: [], ignored: [] })),
      api('/api/coding/sessions').catch(() => ({ sessions: [] })),
      api('/api/devices').catch(() => ({ devices: [] })),
    ]);
    _codingProjectsCache = (projRes && projRes.projects) || [];
    _codingUngroupedCache = (projRes && projRes.ungrouped) || [];
    _codingIgnoredCache = (projRes && projRes.ignored) || [];
    // Build a flat session cache from project+ungrouped (preferred), falling
    // back to the flat /sessions endpoint if the projects payload was empty.
    const flat = [];
    (_codingProjectsCache || []).forEach(p => (p && Array.isArray(p.sessions) ? p.sessions : []).forEach(s => flat.push(s)));
    (_codingUngroupedCache || []).forEach(s => flat.push(s));
    _codingSessionsCache = flat.length ? flat : ((sessRes && sessRes.sessions) || []);
    _codingDevicesCache = (devRes && devRes.devices) || [];
    _codingRenderList();
    _codingRenderUsage((sessRes && sessRes.usage) || null);
    if (_codingSettingsCache === null) {  // lazily learn the usage_display toggle
      api('/api/coding/settings').then(r => {
        _codingSettingsCache = (r && r.settings) || {};
        _codingRenderUsage((sessRes && sessRes.usage) || null);
      }).catch(() => { _codingSettingsCache = {}; });
    }
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

// Code Master settings (notification matrix + usage_display), fetched lazily.
let _codingSettingsCache = null;

// Render the 5-hour + weekly account-usage rings in the sidebar from the
// {five_hour_pct, weekly_pct, *_resets} block (or null → "—"). Hidden when the
// Code Master usage_display toggle is off.
function _codingRenderUsage(usage) {
  const el = document.getElementById('codingUsage');
  if (!el) return;
  if (_codingSettingsCache && _codingSettingsCache.usage_display === false) {
    el.style.display = 'none';
    return;
  }
  const bar = (label, pct, resets) => {
    const has = typeof pct === 'number' && pct >= 0;
    const val = has ? Math.max(0, Math.min(100, pct)) : 0;
    const txt = has ? (val + '%') : '—';
    const hue = val >= 90 ? 0 : (val >= 75 ? 35 : 145);  // red / amber / green
    const reset = (has && resets)
      ? `<span style="opacity:.5;font-size:10px;margin-left:4px">${_cdgEsc(resets)}</span>` : '';
    return `<div style="display:flex;align-items:center;gap:6px;font-size:11px;padding:1px 0" title="${_cdgEsc(label)} account usage">
        <span style="width:30px;opacity:.7">${_cdgEsc(label)}</span>
        <span style="flex:1;height:6px;border-radius:3px;background:rgba(127,127,127,.22);overflow:hidden">
          <span style="display:block;height:100%;width:${val}%;background:hsl(${hue},65%,46%)"></span>
        </span>
        <span style="width:30px;text-align:right;opacity:.85">${txt}</span>${reset}
      </div>`;
  };
  const u = usage || {};
  el.innerHTML = bar('5h', u.five_hour_pct, u.five_hour_resets)
    + bar('Wk', u.weekly_pct, u.weekly_resets);
  el.style.padding = '4px 12px 6px';
  el.style.display = '';
}

// Code Master settings panel: per-event × per-channel notification matrix +
// the usage-display toggle. Rendered in the detail pane.
async function codingCodeMasterSettings() {
  const detail = document.getElementById('codingDetail');
  if (!detail) return;
  // Deselect + stop the session poll/terminal (like codingProjectSettings):
  // with a session still selected, its detail poll repaints the session view
  // over this panel a few seconds after it opens. Remember the selection so
  // Save can return straight to it.
  _codingCmReturnTo = _codingSelectedId;
  _codingStopPoll();
  _codingTeardownTerminal();
  _codingDetailShellId = null;
  _codingSelectedId = null;
  document.querySelectorAll('.cdg-item').forEach(b => b.classList.remove('active'));
  detail.innerHTML = '<div class="cm-detail-body"><div class="cm-empty">Loading settings…</div></div>';
  let settings;
  try {
    const res = await api('/api/coding/settings');
    settings = (res && res.settings) || {};
  } catch (e) {
    detail.innerHTML = '<div class="cm-detail-body"><div class="cm-empty">Couldn\'t load settings.</div></div>';
    return;
  }
  _codingSettingsCache = settings;
  const events = [
    ['finished', 'Finished'],
    ['needs_input', 'Needs input'],
    ['error', 'Error'],
  ];
  const channels = [['telegram', 'Telegram'], ['mobile', 'Mobile push'], ['toast', 'WebUI toast'], ['photon', 'iMessage']];
  const ev = (settings.events) || {};
  const cell = (ekey, ch) => {
    const on = !!((ev[ekey] || {})[ch]);
    return `<td style="text-align:center;padding:6px 10px">
      <input type="checkbox" data-ev="${ekey}" data-ch="${ch}" ${on ? 'checked' : ''}></td>`;
  };
  const rows = events.map(([ekey, elabel]) => `
    <tr><td style="padding:6px 10px;opacity:.85">${elabel}</td>
      ${channels.map(([ch]) => cell(ekey, ch)).join('')}
    </tr>`).join('');
  const head = channels.map(([, lbl]) => `<th style="padding:6px 10px;font-weight:500;opacity:.7">${lbl}</th>`).join('');
  detail.innerHTML = `
    <div class="cm-detail-body">
      <div class="cm-detail-name">Code Master settings</div>
      <div class="cm-section">
        <div class="cm-section-head"><span class="cm-section-title">Notifications</span></div>
        <p style="opacity:.6;font-size:12px;margin:.2em 0 .6em">Which coding events notify you, and on which channels.</p>
        <table style="border-collapse:collapse;font-size:13px">
          <thead><tr><th style="padding:6px 10px"></th>${head}</tr></thead>
          <tbody id="cmNotifyMatrix">${rows}</tbody>
        </table>
      </div>
      <div class="cm-section">
        <div class="cm-section-head"><span class="cm-section-title">Usage rings</span></div>
        <label style="display:flex;align-items:center;gap:8px;font-size:13px;cursor:pointer">
          <input type="checkbox" id="cmUsageDisplay" ${settings.usage_display === false ? '' : 'checked'}>
          Show the 5-hour / weekly account-usage rings
        </label>
      </div>
      <div class="cm-section">
        <div class="cm-section-head"><span class="cm-section-title">Remote approvals</span></div>
        <label style="display:flex;align-items:center;gap:8px;font-size:13px;cursor:pointer">
          <input type="checkbox" id="cmRemoteApprovals" ${settings.remote_approvals ? 'checked' : ''}>
          Approve tool permissions from your phone (relays prompts to the mobile app)
        </label>
        <p style="opacity:.6;font-size:12px;margin:.3em 0 0">Turn on when you're away from the terminal. While off, sessions prompt locally as usual.</p>
      </div>
      <div class="cdg-form-actions">
        <button type="button" class="cdg-btn-primary" id="cmSaveBtn" onclick="codingSaveCodeMaster()">Save settings</button>
      </div>
    </div>`;
}
window.codingCodeMasterSettings = codingCodeMasterSettings;

async function codingSaveCodeMaster() {
  const btn = document.getElementById('cmSaveBtn');
  const events = {};
  document.querySelectorAll('#cmNotifyMatrix input[type=checkbox]').forEach(cb => {
    const e = cb.getAttribute('data-ev'), c = cb.getAttribute('data-ch');
    if (!e || !c) return;
    (events[e] = events[e] || {})[c] = cb.checked;
  });
  const usageEl = document.getElementById('cmUsageDisplay');
  const remoteEl = document.getElementById('cmRemoteApprovals');
  const payload = { events, usage_display: usageEl ? usageEl.checked : true,
                    remote_approvals: remoteEl ? remoteEl.checked : false };
  if (btn) { btn.disabled = true; btn.textContent = 'Saving…'; }
  try {
    const res = await api('/api/coding/settings', { method: 'POST', body: JSON.stringify(payload) });
    _codingSettingsCache = (res && res.settings) || payload;
    _codingFlash('Code Master settings saved');
    // Saved — the settings pane has done its job. Continue where the user
    // was: reopen the session they had selected, else the default hint.
    const back = _codingCmReturnTo;
    _codingCmReturnTo = null;
    if (back && _codingSessionsCache.some(s => String(s.id) === String(back))) {
      codingOpenSession(String(back));
    } else {
      const detail = document.getElementById('codingDetail');
      if (detail) {
        detail.innerHTML = '<div class="cm-detail-body"><div class="cm-empty">' +
          'Select a session, or start a new one.</div></div>';
      }
    }
    return;
  } catch (e) {
    _codingFlash('Couldn\'t save settings');
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = 'Save settings'; }
  }
}
window.codingSaveCodeMaster = codingSaveCodeMaster;

// Where the Code Master settings pane should return on Save (the session that
// was open when the gear was clicked).
let _codingCmReturnTo = null;

// Newest-first by last_activity_at (falls back to created_at). NUMERIC compare —
// these are epoch values (seconds, ms, or an ISO string), so a string compare
// mis-ordered them.
function _codingActivityTs(s) {
  const v = s && (s.last_activity_at != null && s.last_activity_at !== ''
    ? s.last_activity_at : s.created_at);
  if (v == null || v === '') return 0;
  const n = Number(v);
  if (!isNaN(n)) return n > 1e12 ? n / 1000 : n;   // normalise ms → s
  const p = Date.parse(String(v));
  return isNaN(p) ? 0 : p / 1000;
}
function _codingSortSessions(arr) {
  return (arr || []).slice().sort((a, b) => _codingActivityTs(b) - _codingActivityTs(a));
}

// Is this a transcript-only session that isn't currently running? Such sessions
// have no live tmux — they're a PAST conversation we can RESUME on the device.
function _codingIsTranscriptIdle(s) {
  return s && String(s.source || '') === 'discovered-transcript'
    && _cdgStatusClass(s.status) !== 'running';
}

// A live (tmux) session that has ENDED — the user quit claude / the tmux session
// is gone, so the server reconciled it to stopped (or error). It has no live
// terminal to attach; show the "session ended" panel (Resume / Relaunch) instead
// of dumping the user into a dead terminal — or, for a SERVER session, instead of
// re-attaching the dead tmux on a loop (the ctrl-C "infinite reload" bug).
function _codingIsEnded(s) {
  if (!s) return false;
  const src = String(s.source || '');
  if (src === 'discovered-transcript') return false;   // that's transcript-idle
  const cls = _cdgStatusClass(s.status);
  // A discovered Mac live session the user quit → stopped.
  if (src.startsWith('discovered') && cls === 'stopped') return true;
  // A server-LAUNCHED session whose tmux died (e.g. you ctrl-C'd claude) gets
  // reaped to stopped/error. Route it to the ended panel so the detail view
  // stops re-mounting a dead terminal attach (which looped forever).
  if ((s.host || 'server') === 'server' && (cls === 'stopped' || cls === 'error')) return true;
  return false;
}

// One session row (used inside both project groups and the ungrouped group).
function _codingSessionRowHtml(s) {
  const id = String(s.id != null ? s.id : '');
  const title = s.title || s.cwd || s.repo_path || id;
  const sub = s.cwd || s.repo_path || '';
  const source = String(s.source || '');
  const transcriptIdle = _codingIsTranscriptIdle(s);
  // Status dot: a transcript-only (idle/past) session gets a muted "history" dot;
  // a live session refines into working/waiting/idle via its activity_state.
  const st = _cdgDisplayState(s);
  const active = String(_codingSelectedId) === id ? ' active' : '';
  // host/source badge: history (idle transcript) > discovered/live (external) >
  // desktop > server.
  let badgeKind = 'server', badgeLabel = 'server';
  if (transcriptIdle) { badgeKind = 'history'; badgeLabel = 'history'; }
  else if (s.external) {
    // A live transcript or a discovered tmux session is currently drivable.
    badgeKind = 'discovered';
    badgeLabel = (source === 'discovered-transcript' && _cdgStatusClass(s.status) === 'running') ? 'live' : 'discovered';
  }
  else if (String(s.host || '').toLowerCase() === 'desktop') { badgeKind = 'desktop'; badgeLabel = 'desktop'; }
  const badge = `<span class="cdg-badge cdg-badge-${badgeKind}">${_cdgEsc(badgeLabel)}</span>`;
  // For a past (transcript-only) session, surface an inline Resume affordance so
  // the user can relaunch it on the device without opening the detail pane.
  const resumeBtn = transcriptIdle
    ? `<span class="cdg-resume-btn" role="button" tabindex="0" title="Resume this session on the device" onclick="event.stopPropagation();codingResumeSession('${_cdgEsc(id)}')">Resume</span>`
    : '';
  const dotTitle = _cdgStateLabel(st);
  // A small coloured word for the two actionable live states (the ones you care
  // about at a glance); other states stay dot-only to keep the row clean.
  const stateChip = (st === 'waiting' || st === 'working')
    ? `<span class="cdg-item-state cdg-state-${st}">${_cdgEsc(_cdgStateLabel(st))}</span>`
    : '';
  return `<button class="cdg-item cdg-item-nested${active}" data-id="${_cdgEsc(id)}" onclick="codingOpenSession('${_cdgEsc(id)}')">
      <div class="cdg-item-top">
        <span class="cdg-item-name">${_cdgEsc(title)}</span>
        ${stateChip}<span class="cdg-dot cdg-dot-${st}" title="${_cdgEsc(dotTitle)}"></span>
      </div>
      <div class="cdg-item-sub">${badge}<span class="cdg-item-path">${_cdgEsc(sub)}</span>${resumeBtn}</div>
    </button>`;
}

// One collapsible project group. `pid` may be '' for the synthetic ungrouped
// group (which has no header actions and is never persisted/collapsible-keyed
// against a real id — we use the literal '__ungrouped__').
function _codingProjectGroupHtml(opts) {
  const pid = String(opts.id == null ? '' : opts.id);
  const key = opts.key || pid;
  const name = opts.name || 'Project';
  const sessions = _codingSortSessions(opts.sessions);
  const collapsed = _codingCollapsed.has(key);
  const caret = collapsed ? '▸' : '▾';
  const count = sessions.length;
  const rows = sessions.length
    ? sessions.map(_codingSessionRowHtml).join('')
    : '<div class="cdg-group-empty">No sessions yet.</div>';
  const actions = opts.actionsHtml != null
    ? `<span class="cdg-group-actions">${opts.actionsHtml}</span>`
    : (opts.actions
      ? `<span class="cdg-group-actions">
         <button type="button" class="cdg-group-act" title="New session in this project" onclick="event.stopPropagation();codingProjectNewSession('${_cdgEsc(pid)}')">+</button>
         <button type="button" class="cdg-group-act" title="Project settings" onclick="event.stopPropagation();codingProjectSettings('${_cdgEsc(pid)}')">⚙</button>
       </span>`
      : '');
  return `<div class="cdg-group${collapsed ? ' collapsed' : ''}" data-key="${_cdgEsc(key)}">
      <div class="cdg-group-head" role="button" tabindex="0" onclick="codingToggleProject('${_cdgEsc(key)}')">
        <span class="cdg-caret">${caret}</span>
        <span class="cdg-group-name">${_cdgEsc(name)}</span>
        <span class="cdg-group-count">${count}</span>
        ${actions}
      </div>
      <div class="cdg-group-body"${collapsed ? ' style="display:none"' : ''}>${rows}</div>
    </div>`;
}

function _codingRenderList() {
  const list = document.getElementById('codingList');
  if (!list) return;
  const _savedScroll = list.scrollTop;  // preserve scroll across the rebuild
  const projects = _codingProjectsCache || [];
  const ungrouped = _codingUngroupedCache || [];
  // Nothing at all → friendly empty state.
  if (!projects.length && !ungrouped.length && !_codingSessionsCache.length) {
    list.innerHTML = '<div class="cm-projects-empty">No projects or sessions yet.<br><br>Click <b>+ Project</b> to create a project, or <b>+ Session</b> to launch a headless <code>claude</code> session against a repo.</div>';
    return;
  }
  let html = '';
  // Real project groups (with header actions).
  projects.forEach(p => {
    if (!p) return;
    html += _codingProjectGroupHtml({
      id: p.id,
      key: String(p.id == null ? (p.name || '') : p.id),
      name: p.name || p.repo_path || ('project ' + (p.id != null ? p.id : '')),
      sessions: Array.isArray(p.sessions) ? p.sessions : [],
      actions: true,
    });
  });
  // Ungrouped bucket — only when non-empty. If the projects payload was empty
  // but the flat sessions list isn't, fall those sessions into Ungrouped so the
  // panel still works against older backends.
  let loose = ungrouped;
  if (!projects.length && !ungrouped.length && _codingSessionsCache.length) loose = _codingSessionsCache;
  if (loose && loose.length) {
    html += _codingProjectGroupHtml({
      id: '', key: '__ungrouped__', name: 'Ungrouped', sessions: loose, actions: false,
    });
  }
  // Ignored (soft-deleted) projects — a collapsed section at the bottom. Each has
  // Restore (↩) + Delete-permanently (🗑) actions.
  const ignored = _codingIgnoredCache || [];
  if (ignored.length) {
    const caret = _codingIgnoredOpen ? '▾' : '▸';
    let body = '';
    if (_codingIgnoredOpen) {
      body = ignored.map(p => p ? _codingProjectGroupHtml({
        id: p.id, key: 'ign:' + String(p.id),
        name: p.name || p.repo_path || ('project ' + (p.id != null ? p.id : '')),
        sessions: Array.isArray(p.sessions) ? p.sessions : [],
        actionsHtml:
          `<button type="button" class="cdg-group-act" title="Restore project" onclick="event.stopPropagation();codingRestoreProject('${_cdgEsc(String(p.id))}')">↩</button>
           <button type="button" class="cdg-group-act cdg-btn-danger" title="Delete permanently" onclick="event.stopPropagation();codingDeleteProjectPermanent('${_cdgEsc(String(p.id))}')">🗑</button>`,
      }) : '').join('');
    }
    html += `<div class="cdg-group cdg-ignored${_codingIgnoredOpen ? '' : ' collapsed'}" data-key="__ignored__">
        <div class="cdg-group-head" role="button" tabindex="0" onclick="codingToggleIgnored()" style="opacity:.65">
          <span class="cdg-caret">${caret}</span>
          <span class="cdg-group-name">Ignored projects</span>
          <span class="cdg-group-count">${ignored.length}</span>
        </div>
        <div class="cdg-group-body"${_codingIgnoredOpen ? '' : ' style="display:none"'}>${body}</div>
      </div>`;
  }
  list.innerHTML = html || '<div class="cm-projects-empty">No projects or sessions yet.</div>';
  list.scrollTop = _savedScroll;
}

let _codingIgnoredOpen = false;  // the "Ignored projects" section is collapsed by default
function codingToggleIgnored() {
  _codingIgnoredOpen = !_codingIgnoredOpen;
  _codingRenderList();
}
window.codingToggleIgnored = codingToggleIgnored;

function codingToggleProject(key) {
  const k = String(key);
  if (_codingCollapsed.has(k)) _codingCollapsed.delete(k); else _codingCollapsed.add(k);
  _codingPersistCollapsed();
  // Toggle in place (avoids a full re-render / list flicker).
  const group = document.querySelector('.cdg-group[data-key="' + (window.CSS && CSS.escape ? CSS.escape(k) : k) + '"]');
  if (group) {
    const collapsed = _codingCollapsed.has(k);
    group.classList.toggle('collapsed', collapsed);
    const body = group.querySelector('.cdg-group-body');
    const caret = group.querySelector('.cdg-caret');
    if (body) body.style.display = collapsed ? 'none' : '';
    if (caret) caret.textContent = collapsed ? '▸' : '▾';
  } else {
    _codingRenderList();
  }
}
window.codingToggleProject = codingToggleProject;

/* ── Projects (create / new-session / settings) ──────────────────────────── */

function _codingFindProject(pid) {
  const key = String(pid == null ? '' : pid);
  return ((_codingProjectsCache || []).find(p => p && String(p.id) === key))
    || ((_codingIgnoredCache || []).find(p => p && String(p.id) === key))
    || null;
}

// Create a project. Renders a small styled form-card in the detail pane (Name +
// Repo path) — mirrors codingProjectSettings's card so it follows the chosen
// skin (no native dialogs).
function codingNewProject() {
  _codingStopPoll();
  _codingTeardownTerminal();
  _codingDetailShellId = null;
  _codingSelectedId = null;
  document.querySelectorAll('.cdg-item').forEach(b => b.classList.remove('active'));
  const detail = document.getElementById('codingDetail');
  if (!detail) return;
  detail.innerHTML = `
    <div class="cm-detail-body">
      <div class="cdg-form-card">
        <div class="cdg-form-title">New project</div>

        <label class="cdg-label" for="codingNewProjFormName">Name</label>
        <input class="cdg-input" id="codingNewProjFormName" placeholder="My project" autocomplete="off">

        <label class="cdg-label" for="codingNewProjFormPath">Repo path on the server</label>
        <input class="cdg-input" id="codingNewProjFormPath" placeholder="~/code/my-project" autocomplete="off">
        <div class="cdg-hint"><code>~</code> and relative paths work; the folder is created if it doesn't exist.</div>

        <div class="cdg-form-actions">
          <button type="button" class="cdg-btn-secondary" onclick="codingClearDetail()">Cancel</button>
          <button type="button" class="cdg-btn-primary" id="codingNewProjSaveBtn" onclick="codingCreateProject()">Create project</button>
        </div>
        <div class="cdg-form-err" id="codingNewProjErr" style="display:none"></div>
      </div>
    </div>`;
  const nameEl = document.getElementById('codingNewProjFormName');
  if (nameEl) try { nameEl.focus(); } catch (_) {}
}
window.codingNewProject = codingNewProject;

// Submit handler for the styled new-project form-card.
async function codingCreateProject() {
  const errEl = document.getElementById('codingNewProjErr');
  const btn = document.getElementById('codingNewProjSaveBtn');
  const name = ((document.getElementById('codingNewProjFormName') || {}).value || '').trim();
  const repoPath = ((document.getElementById('codingNewProjFormPath') || {}).value || '').trim();
  const showErr = (msg) => { if (errEl) { errEl.textContent = msg; errEl.style.display = ''; } };
  if (errEl) errEl.style.display = 'none';
  if (!name) { showErr('Name is required.'); return; }
  if (!repoPath) { showErr('Repo path is required.'); return; }
  if (btn) { btn.disabled = true; btn.textContent = 'Creating…'; }
  try {
    const res = await api('/api/coding/projects', {
      method: 'POST', body: JSON.stringify({ name, repo_path: repoPath }),
    });
    if (res && res.ok === false) { showErr((res.error || res.message) || 'Could not create project.'); return; }
    const newPid = res && (res.project_id != null ? res.project_id : (res.project && res.project.id));
    await _codingRefreshList();
    if (newPid != null) { _codingCollapsed.delete(String(newPid)); _codingPersistCollapsed(); }
    codingClearDetail();
  } catch (e) {
    showErr((e && e.message) || 'Could not create project.');
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = 'Create project'; }
  }
}
window.codingCreateProject = codingCreateProject;

// Launch a new session inside a project. Opens the unified styled launch form
// pre-selected to this project (the form's Project dropdown handles the actual
// POST to /api/coding/project/<id>/session) — no native prompt.
function codingProjectNewSession(pid) {
  codingShowLaunch(pid);
}
window.codingProjectNewSession = codingProjectNewSession;

// Open a project-settings panel in the DETAIL pane (rename + sync + ignore +
// delete). Stops any session poll so the pane isn't clobbered.
function codingProjectSettings(pid) {
  const proj = _codingFindProject(pid);
  if (!proj) { _codingFlash('Project not found.'); return; }
  _codingStopPoll();
  _codingTeardownTerminal();
  _codingDetailShellId = null;
  _codingSelectedId = null;
  document.querySelectorAll('.cdg-item').forEach(b => b.classList.remove('active'));
  const detail = document.getElementById('codingDetail');
  if (!detail) return;
  const id = String(proj.id);
  const name = _cdgEsc(proj.name || '');
  const repo = _cdgEsc(proj.repo_path || '');
  const branch = _cdgEsc(proj.default_branch || '');
  const syncOn = !!proj.sync_enabled;
  const syncPath = _cdgEsc(proj.sync_desktop_path || '');
  const syncDevice = proj.device_id || proj.sync_device || '';
  const ignore = _cdgEsc(proj.ignore_rules || '');
  detail.innerHTML = `
    <div class="cm-detail-head">
      <div class="cm-detail-titles">
        <div class="cm-detail-name">Project settings</div>
        <div class="cm-detail-slug">${repo}</div>
      </div>
      <div class="cdg-detail-status">
        <button type="button" class="cdg-btn-secondary" onclick="codingClearDetail()">Close</button>
      </div>
    </div>
    <div class="cm-detail-body">
      <div class="cdg-form-card" data-pid="${_cdgEsc(id)}">
        <div class="cdg-form-title">Edit project</div>

        <label class="cdg-label" for="codingProjName">Name</label>
        <input class="cdg-input" id="codingProjName" value="${name}" autocomplete="off">

        <label class="cdg-label" for="codingProjBranch">Default branch (optional)</label>
        <input class="cdg-input" id="codingProjBranch" value="${branch}" placeholder="main" autocomplete="off">

        <label class="cdg-check"><input type="checkbox" id="codingProjSync" onchange="codingToggleProjSyncOpts()" ${syncOn ? 'checked' : ''}> <span>Sync this project with a desktop device</span></label>
        <div id="codingProjSyncOpts" style="display:${syncOn ? '' : 'none'};margin-left:22px">
          <label class="cdg-label" for="codingProjSyncDevice">Device</label>
          <select class="cdg-input" id="codingProjSyncDevice">${_codingDeviceOptionsHtml(syncDevice)}</select>
          <label class="cdg-label" for="codingProjSyncPath">Folder path on that device</label>
          <input class="cdg-input" id="codingProjSyncPath" value="${syncPath}" placeholder="~/code/your-project" autocomplete="off">
        </div>

        <label class="cdg-label" for="codingProjIgnore">Ignore rules (optional, one per line)</label>
        <textarea class="cdg-textarea" id="codingProjIgnore" rows="4" placeholder="node_modules/&#10;.venv/&#10;*.log">${ignore}</textarea>

        <div class="cdg-form-actions">
          <button type="button" class="cdg-btn-secondary cdg-btn-danger" id="codingProjDeleteBtn" onclick="codingDeleteProject('${_cdgEsc(id)}')">Delete project</button>
          <button type="button" class="cdg-btn-primary" id="codingProjSaveBtn" onclick="codingSaveProject('${_cdgEsc(id)}')">Save</button>
        </div>
        <div class="cdg-form-err" id="codingProjErr" style="display:none"></div>
      </div>
    </div>`;
}
window.codingProjectSettings = codingProjectSettings;

function codingToggleProjSyncOpts() {
  const on = !!(document.getElementById('codingProjSync') || {}).checked;
  const o = document.getElementById('codingProjSyncOpts');
  if (o) o.style.display = on ? '' : 'none';
}
window.codingToggleProjSyncOpts = codingToggleProjSyncOpts;

async function codingSaveProject(pid) {
  const id = String(pid);
  const errEl = document.getElementById('codingProjErr');
  const btn = document.getElementById('codingProjSaveBtn');
  const name = ((document.getElementById('codingProjName') || {}).value || '').trim();
  const branch = ((document.getElementById('codingProjBranch') || {}).value || '').trim();
  const syncOn = !!(document.getElementById('codingProjSync') || {}).checked;
  const syncDevice = ((document.getElementById('codingProjSyncDevice') || {}).value || '').trim();
  const syncPath = ((document.getElementById('codingProjSyncPath') || {}).value || '').trim();
  const ignore = ((document.getElementById('codingProjIgnore') || {}).value || '');
  const showErr = (msg) => { if (errEl) { errEl.textContent = msg; errEl.style.display = ''; } };
  if (errEl) errEl.style.display = 'none';
  if (!name) { showErr('Name is required.'); return; }
  if (btn) { btn.disabled = true; btn.textContent = 'Saving…'; }
  try {
    const payload = {
      name,
      default_branch: branch,
      sync_enabled: syncOn,
      device_id: syncDevice,
      sync_desktop_path: syncPath,
      ignore_rules: ignore,
    };
    const res = await api('/api/coding/project/' + encodeURIComponent(id), {
      method: 'POST', body: JSON.stringify(payload),
    });
    if (res && res.ok === false) { showErr((res.error || res.message) || 'Save failed.'); return; }
    await _codingRefreshList();
    codingClearDetail();
  } catch (e) {
    showErr((e && e.message) || 'Save failed.');
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = 'Save'; }
  }
}
window.codingSaveProject = codingSaveProject;

// "Delete" a project = SOFT-ignore it: it leaves the tree, stops being
// re-discovered, and moves to the collapsed "Ignored projects" menu (Restore or
// Delete permanently from there). Reversible, so the confirm is light.
async function codingDeleteProject(pid) {
  const id = String(pid);
  const proj = _codingFindProject(id);
  const projName = proj ? proj.name : id;
  const ok = await showConfirmDialog({
    title: 'Ignore project',
    message: 'Move "' + projName + '" to Ignored projects?\n\n' +
      'It stops showing here and won’t be re-discovered. Its sessions are kept — ' +
      'you can Restore it anytime from the Ignored projects menu.',
    confirmLabel: 'Ignore', cancelLabel: 'Cancel',
  });
  if (!ok) return;
  try {
    const res = await api('/api/coding/project/' + encodeURIComponent(id), { method: 'DELETE' });
    if (res && res.ok === false) { _codingFlash((res.error || res.message) || 'Could not ignore project.'); return; }
    codingClearDetail();
    await _codingRefreshList();
    _codingFlash('Moved “' + projName + '” to Ignored projects.');
  } catch (e) {
    _codingFlash((e && e.message) || 'Could not ignore project.');
  }
}
window.codingDeleteProject = codingDeleteProject;

// Restore (un-ignore) a project: it returns to the main tree and is re-discovered.
async function codingRestoreProject(pid) {
  const id = String(pid);
  try {
    const res = await api('/api/coding/project/' + encodeURIComponent(id),
      { method: 'POST', body: JSON.stringify({ ignored: false }) });
    if (res && res.ok === false) { _codingFlash((res.error || res.message) || 'Restore failed.'); return; }
    await _codingRefreshList();
  } catch (e) {
    _codingFlash((e && e.message) || 'Restore failed.');
  }
}
window.codingRestoreProject = codingRestoreProject;

// Permanently delete an ignored project (the real cascade delete).
async function codingDeleteProjectPermanent(pid) {
  const id = String(pid);
  const proj = _codingFindProject(id);
  const projName = proj ? proj.name : id;
  const cnt = proj && Array.isArray(proj.sessions) ? proj.sessions.length : 0;
  const ok = await showConfirmDialog({
    title: 'Delete permanently',
    message: 'Permanently delete "' + projName + '"' +
      (cnt > 0 ? ' and its ' + cnt + ' session(s)' : '') + '? This cannot be undone.',
    confirmLabel: 'Delete permanently', cancelLabel: 'Cancel', danger: true,
  });
  if (!ok) return;
  try {
    const res = await api('/api/coding/project/' + encodeURIComponent(id) + '?permanent=1&delete_sessions=1',
      { method: 'DELETE' });
    if (res && res.ok === false) { _codingFlash((res.error || res.message) || 'Delete failed.'); return; }
    await _codingRefreshList();
  } catch (e) {
    _codingFlash((e && e.message) || 'Delete failed.');
  }
}
window.codingDeleteProjectPermanent = codingDeleteProjectPermanent;

/* ── Launch form ─────────────────────────────────────────────────────────── */

// preselectProjectId (optional): pre-select that project in the dropdown and
// prefill the cwd from its repo_path.
function codingShowLaunch(preselectProjectId) {
  _codingStopPoll();
  _codingSelectedId = null;
  document.querySelectorAll('.cdg-item').forEach(b => b.classList.remove('active'));
  const detail = document.getElementById('codingDetail');
  if (!detail) return;
  const preId = (preselectProjectId == null || preselectProjectId === '') ? '' : String(preselectProjectId);
  const preProj = preId ? _codingFindProject(preId) : null;
  // Project <select> options: auto (default) + one per known project + a "new"
  // entry. Pre-select `preId` when the caller passed a project to launch into.
  const projSelOpts = (_codingProjectsCache || []).map(p => {
    if (!p) return '';
    const pid = String(p.id == null ? '' : p.id);
    const name = p.name || p.repo_path || ('project ' + pid);
    const sel = (preId && pid === preId) ? ' selected' : '';
    return `<option value="${_cdgEsc(pid)}"${sel}>${_cdgEsc(name)}</option>`;
  }).join('');
  // Project <datalist> options from the known-projects list, so the cwd field
  // autocompletes repo paths the server already knows about.
  const projOpts = (_codingProjectsCache || []).map(p => {
    const path = p.repo_path || p.path || p.cwd || '';
    const name = p.name || path;
    return `<option value="${_cdgEsc(path)}">${_cdgEsc(name)}</option>`;
  }).join('');
  // Prefill the cwd from the preselected project's repo path.
  const cwdVal = preProj ? _cdgEsc(preProj.repo_path || preProj.path || preProj.cwd || '') : '';
  detail.innerHTML = `
    <div class="cm-detail-body">
      <div class="cdg-form-card">
        <div class="cdg-form-title">New coding session</div>

        <label class="cdg-label" for="codingLaunchProject">Project</label>
        <select class="cdg-input" id="codingLaunchProject" onchange="codingLaunchProjectChanged()">
          <option value=""${preId ? '' : ' selected'}>Auto — new project from the working directory</option>
          ${projSelOpts}
          <option value="__new__">+ New project…</option>
        </select>

        <div id="codingNewProjNameRow" style="display:none">
          <label class="cdg-label" for="codingNewProjName">New project name</label>
          <input class="cdg-input" id="codingNewProjName" placeholder="My project" autocomplete="off">
        </div>

        <label class="cdg-label" for="codingCwd">Working directory</label>
        <input class="cdg-input" id="codingCwd" list="codingProjList" value="${cwdVal}" placeholder="~/code/your-project  (~ expands, new folders are created)" autocomplete="off">
        <datalist id="codingProjList">${projOpts}</datalist>
        <div class="cdg-hint" id="codingCwdHint"><code>~</code> and relative paths work; the folder is created if it doesn't exist.</div>

        <label class="cdg-label" for="codingTitle">Title (optional)</label>
        <input class="cdg-input" id="codingTitle" placeholder="What are we building?" autocomplete="off">

        <label class="cdg-label" for="codingModel">Model (optional)</label>
        <input class="cdg-input" id="codingModel" placeholder="e.g. claude-opus-4-8 (blank = server default)" autocomplete="off">

        <label class="cdg-label" for="codingHost">Run on</label>
        <select class="cdg-input" id="codingHost">
          <option value="server">This server (Jarvis host)</option>
          <option value="desktop">My computer (paired desktop)</option>
        </select>

        <label class="cdg-check" id="codingWorktreeRow"><input type="checkbox" id="codingWorktree"> <span>Run in an isolated git worktree</span></label>
        <label class="cdg-check"><input type="checkbox" id="codingSkipPerms"> <span>Dangerously skip permissions (autonomous — no approval prompts)</span></label>
        <label class="cdg-check"><input type="checkbox" id="codingSync" onchange="codingToggleSyncOpts()"> <span>Sync this project with another device</span></label>
        <div id="codingSyncOpts" style="display:none;margin:4px 0 2px 22px">
          <label class="cdg-label" for="codingSyncDevice">Device</label>
          <select class="cdg-input" id="codingSyncDevice">${_codingDeviceOptionsHtml('')}</select>
          <label class="cdg-label" for="codingSyncPath">Folder path on that device</label>
          <input class="cdg-input" id="codingSyncPath" list="codingSyncPathList" placeholder="~/code/your-project" autocomplete="off">
          <datalist id="codingSyncPathList"></datalist>
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
  // Apply the initial project-selection state (e.g. hide worktree row / relabel
  // the cwd hint when a real project is preselected).
  codingLaunchProjectChanged();
  // Wire the host-aware directory autocomplete (Working Directory + sync path).
  _codingWireDirSuggest();
}
window.codingShowLaunch = codingShowLaunch;

// Live, host-aware directory autocomplete for the New-session form.
//   • Working Directory lists dirs on the host the session RUNS on — the SERVER
//     filesystem when RUN ON = "This server", or the paired DEVICE's filesystem
//     (over the bridge) when RUN ON = "My computer". Re-queries when RUN ON
//     changes, so it never shows Mac paths for a server session (the old bug).
//   • "Folder path on that device" lists the chosen sync DEVICE's dirs.
// Both hit GET /api/coding/dir-suggest and refresh a native <datalist> as you
// type (drill-down). Failures (offline / no device) leave existing options.
function _codingWireDirSuggest() {
  const cwd = document.getElementById('codingCwd');
  const cwdList = document.getElementById('codingProjList');
  const hostSel = document.getElementById('codingHost');
  const syncPath = document.getElementById('codingSyncPath');
  const syncList = document.getElementById('codingSyncPathList');
  const syncDev = document.getElementById('codingSyncDevice');

  const fillList = (listEl, dirs) => {
    if (!listEl) return;
    listEl.innerHTML = (dirs || []).map(
      d => `<option value="${_cdgEsc(d)}"></option>`).join('');
  };
  const debounce = (fn, ms) => {
    let t = 0;
    return (...a) => { if (t) clearTimeout(t); t = setTimeout(() => fn(...a), ms); };
  };
  // seqRef drops out-of-order responses (the bridge/device path is slow enough
  // that a stale reply could otherwise clobber a newer one).
  const suggest = async (path, host, deviceId, listEl, seqRef) => {
    const my = ++seqRef.n;
    try {
      const qs = new URLSearchParams({ path: path || '', host: host || 'server' });
      if (deviceId) qs.set('device_id', deviceId);
      const res = await api('/api/coding/dir-suggest?' + qs.toString());
      if (my !== seqRef.n) return;  // superseded by a newer request
      fillList(listEl, res && res.dirs);
    } catch (_) { /* offline / no device → keep whatever options are there */ }
  };

  if (cwd && cwdList) {
    const seq = { n: 0 };
    const run = debounce(
      () => suggest(cwd.value, (hostSel || {}).value || 'server', '', cwdList, seq), 140);
    cwd.addEventListener('input', run);
    cwd.addEventListener('focus', run);
    if (hostSel) hostSel.addEventListener('change', () => { fillList(cwdList, []); run(); });
    // No seed-on-open: keep the static known-project options until the user
    // focuses the field, then switch to live host-appropriate dirs (so a server
    // session never shows the discovered Mac project paths the user complained
    // about).
  }
  if (syncPath && syncList) {
    const seq = { n: 0 };
    const run = debounce(
      () => suggest(syncPath.value, 'desktop', (syncDev || {}).value || '', syncList, seq), 140);
    syncPath.addEventListener('input', run);
    syncPath.addEventListener('focus', run);
    if (syncDev) syncDev.addEventListener('change', () => { fillList(syncList, []); run(); });
  }
}
window._codingWireDirSuggest = _codingWireDirSuggest;

// React to the Project dropdown changing:
//   existing project id → prefill cwd with that project's repo_path, hide the
//     worktree row (sessions in a project share the repo), hide the new-name
//     input, restore the normal cwd hint.
//   "__new__" → reveal the "New project name" input; the working-directory field
//     IS the new project's repo path (relabel the hint to say so).
//   "" (auto) → normal: everything as the default new-from-cwd flow.
function codingLaunchProjectChanged() {
  const sel = document.getElementById('codingLaunchProject');
  const val = sel ? sel.value : '';
  const nameRow = document.getElementById('codingNewProjNameRow');
  const wtRow = document.getElementById('codingWorktreeRow');
  const cwd = document.getElementById('codingCwd');
  const hint = document.getElementById('codingCwdHint');
  const defaultHint = '<code>~</code> and relative paths work; the folder is created if it doesn\'t exist.';
  if (val === '__new__') {
    if (nameRow) nameRow.style.display = '';
    if (wtRow) wtRow.style.display = '';
    if (hint) hint.innerHTML = 'This is the new project\'s repo path. <code>~</code> and relative paths work; the folder is created if it doesn\'t exist.';
  } else if (val) {
    // Existing project: prefill cwd from its repo path, hide worktree + name.
    const proj = _codingFindProject(val);
    if (proj && cwd) cwd.value = proj.repo_path || proj.path || proj.cwd || '';
    if (nameRow) nameRow.style.display = 'none';
    if (wtRow) wtRow.style.display = 'none';
    if (hint) hint.innerHTML = 'Defaults to the project\'s folder. Change it only to run this session elsewhere.';
  } else {
    // Auto — new project from the working directory.
    if (nameRow) nameRow.style.display = 'none';
    if (wtRow) wtRow.style.display = '';
    if (hint) hint.innerHTML = defaultHint;
  }
}
window.codingLaunchProjectChanged = codingLaunchProjectChanged;

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
  const projectSel = ((document.getElementById('codingLaunchProject') || {}).value || '');
  const cwd = (document.getElementById('codingCwd') || {}).value || '';
  const title = (document.getElementById('codingTitle') || {}).value || '';
  const model = (document.getElementById('codingModel') || {}).value || '';
  const initialPrompt = (document.getElementById('codingPrompt') || {}).value || '';
  const newProjName = ((document.getElementById('codingNewProjName') || {}).value || '').trim();
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
  if (!initialPrompt.trim()) { showErr('An initial prompt is required.'); return; }
  if (btn) { btn.disabled = true; btn.textContent = 'Launching…'; }
  const sync = syncOn ? { enabled: true, device: syncDevice, remote_path: syncPath } : null;
  // Body for the project-scoped session endpoint (existing or freshly-created
  // project). cwd is included only when the user changed it from the project's
  // default repo_path (so the backend uses the project folder otherwise).
  const projectSessionBody = (pid) => {
    const proj = _codingFindProject(pid);
    const projPath = proj ? String(proj.repo_path || proj.path || proj.cwd || '') : '';
    const body = {
      title: title.trim(),
      prompt: initialPrompt.trim(),
      skip_permissions: skipPerms,
      host,
    };
    if (model.trim()) body.model = model.trim();
    if (cwd.trim() && cwd.trim() !== projPath) body.cwd = cwd.trim();
    if (sync) body.sync = sync;
    return body;
  };
  // Refresh, expand the target project, open the new session.
  const onLaunched = async (sess, expandPid) => {
    if (expandPid != null) { _codingCollapsed.delete(String(expandPid)); _codingPersistCollapsed(); }
    await _codingRefreshList();
    if (sess && sess.id != null) codingOpenSession(String(sess.id));
  };
  try {
    if (projectSel === '__new__') {
      // Create the project first, then launch a session into it.
      if (!newProjName) { showErr('New project name is required.'); return; }
      if (!cwd.trim()) { showErr('Repo path (working directory) is required.'); return; }
      const created = await api('/api/coding/projects', {
        method: 'POST', body: JSON.stringify({ name: newProjName, repo_path: cwd.trim() }),
      });
      if (!created || created.ok === false) {
        showErr((created && (created.error || created.message)) || 'Could not create project.'); return;
      }
      const newPid = created.project_id != null ? created.project_id : (created.project && created.project.id);
      if (newPid == null) { showErr('Project created but no id was returned.'); return; }
      await _codingRefreshList();   // so _codingFindProject() can resolve the new project's path
      const res = await api('/api/coding/project/' + encodeURIComponent(String(newPid)) + '/session', {
        method: 'POST', body: JSON.stringify(projectSessionBody(String(newPid))),
      });
      if (!res || res.ok === false) { showErr((res && (res.error || res.message)) || 'Launch failed.'); return; }
      await onLaunched(res.session || {}, newPid);
    } else if (projectSel) {
      // Existing project → project-scoped session endpoint.
      const res = await api('/api/coding/project/' + encodeURIComponent(projectSel) + '/session', {
        method: 'POST', body: JSON.stringify(projectSessionBody(projectSel)),
      });
      if (!res || res.ok === false) { showErr((res && (res.error || res.message)) || 'Launch failed.'); return; }
      await onLaunched(res.session || {}, projectSel);
    } else {
      // Auto — new project from the working directory (current behavior).
      // The API accepts cwd or repo_path for the directory; we send both keys set
      // to the same value so either server-side naming works.
      const payload = {
        cwd: cwd.trim(),
        repo_path: cwd.trim(),
        worktree,
        skip_permissions: skipPerms,
        host,
        title: title.trim(),
        prompt: initialPrompt.trim(),
      };
      if (model.trim()) payload.model = model.trim();
      if (sync) payload.sync = sync;
      const res = await api('/api/coding/launch', { method: 'POST', body: JSON.stringify(payload) });
      if (!res || res.ok === false) { showErr((res && (res.error || res.message)) || 'Launch failed.'); return; }
      await onLaunched(res.session || {}, null);
    }
  } catch (e) {
    showErr((e && e.message) || 'Launch failed.');
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = 'Launch session'; }
  }
}
window.codingLaunch = codingLaunch;

/* ── Discovered sessions (resume + rescan) ───────────────────────────────── */

// Resume a transcript-only (past) session: ask the backend to relaunch it on the
// device. On success it becomes a live tmux session within a few seconds, so we
// just refresh the list and re-open it (the detail pane will pick up the live
// terminal once the backend reports it running). Non-fatal on failure (e.g.
// "device offline") — we surface a message but never break the panel.
async function codingResumeSession(id) {
  const sid = String(id);
  if (!sid) return;
  // Busy-state the inline Resume affordance (cosmetic — the row re-renders on
  // refresh). Locate it via the row's data-id rather than a fragile onclick
  // attribute selector. Also handles the detail-pane Resume button.
  const esc = (window.CSS && CSS.escape) ? CSS.escape(sid) : sid.replace(/"/g, '\\"');
  const row = document.querySelector('.cdg-item[data-id="' + esc + '"]');
  const btn = (row && row.querySelector('.cdg-resume-btn')) || document.getElementById('codingResumeDetailBtn');
  if (btn) { btn.classList.add('cdg-resume-busy'); btn.textContent = 'Resuming…'; }
  try {
    const res = await api('/api/coding/session/' + encodeURIComponent(sid) + '/resume',
      { method: 'POST', body: JSON.stringify({}) });
    if (!res || res.ok === false) {
      const msg = (res && (res.error || res.message)) || 'Could not resume this session (is the device online?).';
      _codingFlash(msg);
      if (btn) { btn.classList.remove('cdg-resume-busy'); btn.textContent = 'Resume'; }
      return;
    }
    // The resumed session may keep the same id or be reported under a new one.
    const sess = (res && res.session) || {};
    const openId = sess.id != null ? String(sess.id) : sid;
    await _codingRefreshList();
    codingOpenSession(openId);
  } catch (e) {
    _codingFlash((e && e.message) || 'Could not resume this session.');
    if (btn) { btn.classList.remove('cdg-resume-busy'); btn.textContent = 'Resume'; }
  }
}
window.codingResumeSession = codingResumeSession;

// Relaunch an ENDED discovered session ON THE DEVICE: start a fresh desktop
// session at the same cwd, continuing the same conversation (claude --continue
// via resume_session_id). Routes through the project-scoped launch when the
// session belongs to a project, so it inherits the project's sync settings.
async function codingRelaunchDevice(id) {
  const sid = String(id || '');
  if (!sid) return;
  const s = (_codingCurrentSession && String(_codingCurrentSession.id) === sid)
    ? _codingCurrentSession : null;
  const cwd = (s && (s.cwd || s.repo_path)) || '';
  if (!cwd) {
    // Launch requires a cwd; without it the server 400s. Resume-on-server (which
    // works off the transcript) is the fallback here.
    _codingFlash('Can’t relaunch — this session has no folder. Try “Resume on server”.');
    return;
  }
  const csid = (s && s.claude_session_id) || '';
  const pid = (s && s.project_id) || null;
  const btn = document.querySelector('.cdg-ended-actions .cdg-btn-primary');
  if (btn) { btn.disabled = true; btn.textContent = 'Relaunching…'; }
  try {
    const body = { host: 'desktop', cwd: cwd };
    if (s && s.title) body.title = s.title;
    if (csid) body.resume_session_id = csid;
    const path = pid
      ? ('/api/coding/project/' + encodeURIComponent(pid) + '/session')
      : '/api/coding/launch';
    if (!pid) body.project_id = null;
    const res = await api(path, { method: 'POST', body: JSON.stringify(body) });
    if (!res || res.ok === false) {
      _codingFlash((res && (res.error || res.message)) || 'Could not relaunch on the device (is it online?).');
      if (btn) { btn.disabled = false; btn.textContent = 'Relaunch on device'; }
      return;
    }
    const sess = (res && res.session) || {};
    await _codingRefreshList();
    if (sess.id != null) codingOpenSession(String(sess.id));
  } catch (e) {
    _codingFlash('Relaunch failed: ' + ((e && e.message) || e));
    if (btn) { btn.disabled = false; btn.textContent = 'Relaunch on device'; }
  }
}
window.codingRelaunchDevice = codingRelaunchDevice;

// Force a fresh attach attempt for a session whose terminal detached/ended. Tears
// down any stale mount and re-opens the session, so a session that's come back
// re-mounts (and one that's still ended falls back to the ended panel).
function codingReopenTerminal(id) {
  const sid = String(id || _codingSelectedId || '');
  if (!sid) return;
  _codingTeardownTerminal();
  _codingDetailShellId = null;       // force a rebuild + a fresh terminal/start
  codingOpenSession(sid);
}
window.codingReopenTerminal = codingReopenTerminal;

// Force paired devices to re-scan + re-report their tmux + transcript sessions,
// then refresh the list. Subtle: spins the rescan button while it runs.
async function codingRescanDiscovered() {
  const btn = document.getElementById('codingRescanBtn');
  if (btn) { btn.classList.add('cdg-rescan-spin'); btn.disabled = true; }
  try {
    const res = await api('/api/coding/discover/refresh', { method: 'POST', body: JSON.stringify({}) });
    if (res && res.ok === false) _codingFlash((res.error || res.message) || 'Rescan request failed.');
  } catch (e) {
    _codingFlash((e && e.message) || 'Rescan request failed.');
  }
  // Give the device a beat to report back, then refresh (and once more shortly
  // after, since discovery is async over the bridge).
  await _codingRefreshList();
  setTimeout(() => { _codingRefreshList(); }, 2500);
  if (btn) { btn.classList.remove('cdg-rescan-spin'); btn.disabled = false; }
}
window.codingRescanDiscovered = codingRescanDiscovered;

// Tiny non-fatal toast for discovered-session actions. Falls back to a transient
// banner pinned to the sidebar head (no alert() so it never blocks the UI).
function _codingFlash(msg) {
  try {
    const host = document.getElementById('codingSide') || document.getElementById('codingList');
    if (!host) return;
    let el = document.getElementById('codingFlash');
    if (!el) {
      el = document.createElement('div');
      el.id = 'codingFlash';
      el.className = 'cdg-flash';
      host.insertBefore(el, host.firstChild);
    }
    el.textContent = String(msg || '');
    el.style.display = '';
    clearTimeout(_codingFlash._t);
    _codingFlash._t = setTimeout(() => { if (el) el.style.display = 'none'; }, 5000);
  } catch (_) {}
}

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
  _codingRefreshSyncStatus(id);
}

function _codingRenderDetail(session, subagents) {
  const detail = document.getElementById('codingDetail');
  if (!detail) return;
  const id = String(session.id != null ? session.id : _codingSelectedId || '');
  const subList = Array.isArray(subagents) ? subagents : [];
  _codingCurrentSession = session;   // cached for the ended panel's actions

  // A transcript-only (past, not-running) session has NO live tmux yet. Render a
  // summary pane with a Resume button instead of trying to attach a dead
  // terminal. Once Resume relaunches it (status flips to running), the next poll
  // falls through to the normal live-terminal shell below.
  if (_codingIsTranscriptIdle(session)) {
    _codingRenderTranscriptDetail(session, id);
    return;
  }
  // A discovered live session that ENDED (claude quit / tmux gone). No terminal
  // to attach — show the ended panel (Resume on server / Relaunch on device).
  if (_codingIsEnded(session)) {
    _codingRenderEndedDetail(session, id);
    return;
  }
  // If we WERE showing the transcript shell and the session is now live, drop the
  // marker so the live-terminal shell rebuilds cleanly.
  if (_codingDetailShellId === id && detail.querySelector('.cdg-transcript-detail')) {
    _codingDetailShellId = null;
  }

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
           <div class="cm-section-head"><span class="cm-section-title">Live terminal</span><span class="cm-section-count" style="font-weight:400;opacity:.6">${hostLabel} · type here to talk to claude</span><button type="button" class="cdg-term-fsbtn" id="codingTermFsBtn" onclick="codingToggleTermFullscreen()" title="Toggle fullscreen (Esc to exit)">⛶ Fullscreen</button></div>
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
            <select class="cdg-input" id="codingSetSyncDevice">${_codingDeviceOptionsHtml(_sc.device || '')}</select>
            <label class="cdg-label" for="codingSetSyncPath">Folder on that device</label>
            <input class="cdg-input" id="codingSetSyncPath" value="${_syncPath}" placeholder="~/code/your-project" autocomplete="off">
          </div>
          <div class="cdg-form-actions"><button type="button" class="cdg-btn-primary" id="codingSetSaveBtn" onclick="codingSaveSettings()">Save settings</button></div>
          <div class="cdg-form-err" id="codingSetErr" style="display:none"></div>
        </div>
        <div id="codingSyncStatus"></div>
        ${termSection}
      </div>`;
    _codingMountTerminal(id);   // server attaches local tmux; desktop streams over the bridge
  }
  _codingUpdateDetailStatus(session);
}

// Detail pane for a transcript-only (past) session: a read-only summary plus the
// Resume affordance. No live terminal. Built once per session (guarded by
// _codingDetailShellId + the .cdg-transcript-detail marker) so the 4s poll
// doesn't rebuild/flicker it; when Resume flips it to running the poll falls
// through to the live-terminal shell instead.
function _codingRenderTranscriptDetail(session, id) {
  const detail = document.getElementById('codingDetail');
  if (!detail) return;
  // Already showing this transcript's shell → nothing dynamic to update.
  if (_codingDetailShellId === id && detail.querySelector('.cdg-transcript-detail')) return;
  _codingTeardownTerminal();          // make sure any prior live terminal is gone
  _codingDetailShellId = id;          // mark this shell as built for `id`
  const title = session.title || session.cwd || session.repo_path || id;
  const cwd = session.cwd || session.repo_path || '';
  const summary = session.summary || session.last_message || '';
  const last = session.last_activity_at || session.updated_at || session.created_at || '';
  const claudeId = session.claude_session_id || '';
  const rows = [];
  if (cwd) rows.push(`<div class="cdg-meta-row"><span class="cdg-meta-key">Directory</span><span class="cdg-meta-val">${_cdgEsc(cwd)}</span></div>`);
  if (last) rows.push(`<div class="cdg-meta-row"><span class="cdg-meta-key">Last activity</span><span class="cdg-meta-val">${_cdgEsc(_cdgFmtTime(last))}</span></div>`);
  if (claudeId) rows.push(`<div class="cdg-meta-row"><span class="cdg-meta-key">Session id</span><span class="cdg-meta-val">${_cdgEsc(claudeId)}</span></div>`);
  detail.innerHTML = `
    <div class="cm-detail-head">
      <div class="cm-detail-titles">
        <div class="cm-detail-name">${_cdgEsc(title)}</div>
        <div class="cm-detail-slug">${_cdgEsc(cwd)}</div>
      </div>
      <div class="cdg-detail-status">
        <span class="cdg-dot cdg-dot-history" title="past session (not running)"></span>
        <span class="cdg-status-text">history</span>
        <button type="button" class="cdg-btn-primary" id="codingResumeDetailBtn" onclick="codingResumeSession('${_cdgEsc(id)}')">Resume</button>
        <button type="button" class="cdg-btn-secondary" onclick="codingClearDetail()">Close</button>
      </div>
    </div>
    <div class="cm-detail-body">
      <div class="cdg-transcript-detail">
        <div class="cm-section">
          <div class="cm-section-head"><span class="cm-section-title">Past session</span><span class="cm-section-count" style="font-weight:400;opacity:.6">discovered transcript · not running</span></div>
          <div class="cdg-hint">This is a previous <code>claude</code> conversation found on the device. It has no live terminal. <b>Resume</b> relaunches it on the device — it becomes a live session in a few seconds, then the terminal appears here.</div>
          ${rows.length ? `<div class="cdg-meta">${rows.join('')}</div>` : ''}
          ${summary ? `<div class="cdg-label">Summary</div><div class="cdg-transcript-summary">${_cdgEsc(summary)}</div>` : ''}
        </div>
      </div>
    </div>`;
}

// Detail pane for a DISCOVERED live session that ENDED (claude quit / tmux gone).
// No live terminal — offer the recovery actions instead of a dead terminal.
// Built once per session (guarded by _codingDetailShellId + the .cdg-ended-detail
// marker) so the 4s poll doesn't rebuild/flicker it.
function _codingRenderEndedDetail(session, id) {
  const detail = document.getElementById('codingDetail');
  if (!detail) return;
  if (_codingDetailShellId === id && detail.querySelector('.cdg-ended-detail')) return;
  _codingTeardownTerminal();          // make sure any prior live terminal is gone
  _codingDetailShellId = id;          // mark this shell as built for `id`
  const title = session.title || session.cwd || session.repo_path || id;
  const cwd = session.cwd || session.repo_path || '';
  const isServer = (session.host || 'server') === 'server'
    && !String(session.source || '').startsWith('discovered');
  // A SERVER-launched session that died (you ctrl-C'd claude): the recovery is a
  // Restart in the same cwd on the server — NOT "relaunch on device" / a terminal
  // re-attach (re-attaching the dead tmux is exactly what looped). A DISCOVERED
  // Mac session offers the device/server recovery actions.
  const hint = isServer
    ? `The <code>claude</code> for this session has stopped (you quit it / its tmux ended). There's no live terminal to attach — <b>Restart</b> launches it again in the same folder on the server.`
    : `The live <code>claude</code> for this session has stopped (its tmux session ended). There's no live terminal to attach. You can <b>relaunch it on the device</b> to keep working there, or <b>resume it on the server</b> (it continues from the synced transcript).`;
  const actions = isServer
    ? `<button type="button" class="cdg-btn-primary" onclick="codingRestart()">Restart</button>
       <button type="button" class="cdg-btn-secondary" onclick="codingDelete()">Delete</button>`
    : `<button type="button" class="cdg-btn-primary" onclick="codingRelaunchDevice('${_cdgEsc(id)}')">Relaunch on device</button>
       <button type="button" class="cdg-btn-secondary" onclick="codingResumeSession('${_cdgEsc(id)}')">Resume on server</button>
       <button type="button" class="cdg-btn-secondary" onclick="codingReopenTerminal('${_cdgEsc(id)}')">Reopen terminal</button>`;
  const sub = isServer ? 'claude is no longer running on the server'
                       : 'claude is no longer running on this device';
  detail.innerHTML = `
    <div class="cm-detail-head">
      <div class="cm-detail-titles">
        <div class="cm-detail-name">${_cdgEsc(title)}</div>
        <div class="cm-detail-slug">${_cdgEsc(cwd)}</div>
      </div>
      <div class="cdg-detail-status">
        <span class="cdg-dot cdg-dot-stopped" title="session ended (not running)"></span>
        <span class="cdg-status-text">ended</span>
        <button type="button" class="cdg-btn-secondary" onclick="codingClearDetail()">Close</button>
      </div>
    </div>
    <div class="cm-detail-body">
      <div class="cdg-ended-detail">
        <div class="cm-section">
          <div class="cm-section-head"><span class="cm-section-title">Session ended</span><span class="cm-section-count" style="font-weight:400;opacity:.6">${sub}</span></div>
          <div class="cdg-hint">${hint}</div>
          <div class="cdg-ended-actions" style="margin-top:14px;display:flex;gap:10px;flex-wrap:wrap;">
            ${actions}
          </div>
        </div>
      </div>
    </div>`;
}

function _codingUpdateDetailStatus(session) {
  // lifecycle class drives the Stop/Restart affordance; the display state
  // (working/waiting/idle) drives the dot + text.
  const lifecycle = _cdgStatusClass(session.status);
  const st = _cdgDisplayState(session);
  const dot = document.getElementById('codingStatusDot');
  const txt = document.getElementById('codingStatusText');
  const stop = document.getElementById('codingStopBtn');
  const restart = document.getElementById('codingRestartBtn');
  if (dot) dot.className = 'cdg-dot cdg-dot-' + st;
  if (txt) txt.textContent = _cdgStateLabel(st);
  const running = (lifecycle === 'running' || lifecycle === 'idle');
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
      // Copy/paste in the streamed terminal: ⌘C / Ctrl+Shift+C copies the
      // selection to the clipboard (instead of xterm swallowing it / sending
      // ^C), and ⌘V / Ctrl+Shift+V pastes the clipboard into the PTY. Plain
      // Ctrl+C is left alone so it still sends SIGINT.
      term.attachCustomKeyEventHandler((e) => {
        if (e.type !== 'keydown') return true;
        const k = (e.key || '').toLowerCase();
        const copyCombo = (e.metaKey && !e.ctrlKey && k === 'c')
                       || (e.ctrlKey && e.shiftKey && k === 'c');
        const pasteCombo = (e.metaKey && !e.ctrlKey && k === 'v')
                        || (e.ctrlKey && e.shiftKey && k === 'v');
        if (copyCombo) {
          try {
            const sel = term.getSelection();
            // Prefer the shared _copyText helper (ui.js) — it falls back to
            // document.execCommand('copy') when navigator.clipboard is absent
            // (plain-http / non-secure context, e.g. over the tunnel).
            if (sel) {
              if (typeof _copyText === 'function') _copyText(sel).catch(() => {});
              else if (navigator.clipboard) navigator.clipboard.writeText(sel);
            }
          } catch (_) {}
          return false;  // never forward ⌘C to the PTY
        }
        if (pasteCombo) {
          try {
            if (navigator.clipboard) navigator.clipboard.readText().then(txt => {
              if (txt) api('/api/terminal/input',
                { method: 'POST', body: JSON.stringify({ session_id: id, data: txt }) }).catch(() => {});
            }).catch(() => {});
          } catch (_) {}
          return false;  // we deliver the paste ourselves
        }
        return true;
      });
      const sendResize = () => {
        try { if (fit) fit.fit(); } catch (_) {}
        api('/api/terminal/resize',
          { method: 'POST', body: JSON.stringify({ session_id: id, rows: term.rows, cols: term.cols }) }).catch(() => {});
      };
      // THROTTLE the window-resize handler: a window drag fires dozens of resize
      // events/sec, each doing a full xterm reflow + a /resize POST + a tmux
      // SIGWINCH (tmux then repaints the whole pane) — a major lag amplifier.
      // Coalesce to a single trailing 150ms call. Fullscreen still calls
      // sendResize directly for an immediate refit.
      let _rzTimer = 0;
      const onWinResize = () => {
        if (_rzTimer) clearTimeout(_rzTimer);
        _rzTimer = setTimeout(sendResize, 150);
      };
      _codingTermResize = sendResize;
      _codingTermWinResize = onWinResize;
      window.addEventListener('resize', onWinResize);
      setTimeout(sendResize, 120);
      // BATCH incoming output with requestAnimationFrame: a burst of SSE frames
      // is buffered and flushed once per frame in a single term.write, smoothing
      // render to the display refresh instead of one synchronous write+reflow per
      // message (the client-side half of the terminal-lag fix).
      let _wbuf = '';
      let _wraf = 0;
      const _flushWrites = () => {
        _wraf = 0;
        const b = _wbuf; _wbuf = '';
        if (b && _codingTerm) _codingTerm.write(b);
      };
      const es = new EventSource('/api/terminal/output?session_id=' + encodeURIComponent(id), { withCredentials: true });
      _codingTermES = es;
      es.addEventListener('output', ev => {
        let text = ''; try { text = (JSON.parse(ev.data) || {}).text || ''; } catch (_) {}
        if (!text) return;
        _wbuf += text;
        if (!_wraf) _wraf = requestAnimationFrame(_flushWrites);
      });
      es.onerror = () => {
        // Don't let EventSource auto-reconnect against a dead/closed terminal —
        // that re-attached the (now dead) tmux on a loop, which was the ctrl-C
        // "infinite reload" storm. If this mount is no longer the active one,
        // close the stream for good.
        if (_codingTermMountedId !== id) { try { es.close(); } catch (_) {} }
      };
      es.addEventListener('terminal_closed', (ev) => {
        let reason = '';
        try { reason = (JSON.parse(ev.data) || {}).reason || ''; } catch (_) {}
        // The live PTY ended. Reset the mount state so the session can be RE-mounted
        // (the old bug: state stayed set, so re-selecting / the poll was a no-op
        // forever and the detached banner was sticky).
        const wasId = id;
        try { if (_codingTermES) _codingTermES.close(); } catch (_) {}
        _codingTermES = null;
        _codingTermMountedId = null;
        _codingDetailShellId = null;     // force the next render to rebuild the shell
        if (reason === 'ended') {
          // claude/tmux is gone (e.g. you ctrl-C'd it). The server reconciled the
          // row to stopped — refresh to the ended panel (Resume / Relaunch).
          if (String(_codingSelectedId || '') === String(wasId)) _codingRefreshDetail();
          return;
        }
        const msg = reason === 'disconnected'
          ? '[disconnected — your Mac dropped its connection; reopen when it’s back]'
          : '[detached — reopen this session to resume the live terminal]';
        if (_codingTerm) _codingTerm.write('\r\n\x1b[90m' + msg + '\x1b[0m\r\n');
      });
    }).catch((e) => {
      if (_codingDetailShellId !== id) return;
      // A discovered Mac session whose device is OFFLINE can't be attached live
      // (no process to attach to) — offer resume-to-server instead.
      let body = {}; try { body = JSON.parse((e && e.body) || '{}'); } catch (_) {}
      if (e && e.status === 409 && body.can_resume) {
        host.innerHTML = '';
        const wrap = document.createElement('div');
        wrap.style.cssText = 'padding:16px;color:#cbd5e1;font-size:13px;line-height:1.5;';
        wrap.innerHTML = 'Your Mac is offline, so the live session can’t be attached. ' +
          'You can <b>resume it on the server</b> to keep working (it continues from the synced transcript).';
        const btn = document.createElement('button');
        btn.textContent = 'Resume on server';
        btn.style.cssText = 'margin-top:12px;';
        btn.className = 'btn';
        btn.onclick = () => { try { codingResumeSession(id); } catch (_) {} };
        wrap.appendChild(document.createElement('br'));
        wrap.appendChild(btn);
        host.appendChild(wrap);
        return;
      }
      host.textContent = (e && e.message) || 'terminal failed to start';
    });
}

function _codingTeardownTerminal() {
  try { if (_codingTermES) _codingTermES.close(); } catch (_) {}
  try { if (_codingTermWinResize) window.removeEventListener('resize', _codingTermWinResize); } catch (_) {}
  // Detach the server-side PTY (does NOT kill the tmux session / claude).
  if (_codingTermMountedId) {
    api('/api/terminal/close', { method: 'POST', body: JSON.stringify({ session_id: _codingTermMountedId }) }).catch(() => {});
  }
  try { if (_codingTerm) _codingTerm.dispose(); } catch (_) {}
  _codingTerm = null; _codingTermES = null; _codingTermFit = null;
  _codingTermResize = null; _codingTermWinResize = null; _codingTermMountedId = null;
}

// Fullscreen the live terminal so the Claude session fills the viewport. Uses a
// CSS class (not the native Fullscreen API) so the EventSource stream, our
// header controls, and Esc-to-exit all keep working, then refits xterm + tells
// the server-side PTY the new cols/rows.
let _codingTermFs = false;
function codingToggleTermFullscreen() {
  const el = document.getElementById('codingTerm');
  if (!el) return;
  _codingTermFs = !_codingTermFs;
  el.classList.toggle('cdg-term-fs', _codingTermFs);
  document.body.classList.toggle('cdg-term-fs-open', _codingTermFs);
  const btn = document.getElementById('codingTermFsBtn');
  if (btn) btn.textContent = _codingTermFs ? '⛶ Exit fullscreen' : '⛶ Fullscreen';
  // Let the layout settle, then refit xterm to the new size + resize the PTY.
  setTimeout(() => { try { if (_codingTermResize) _codingTermResize(); } catch (_) {} }, 60);
  try { if (_codingTerm) _codingTerm.focus(); } catch (_) {}
}
window.codingToggleTermFullscreen = codingToggleTermFullscreen;
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && _codingTermFs) codingToggleTermFullscreen();
});

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
    if (res && res.ok === false) { _codingFlash(res.error || 'Restart failed.'); return; }
    // Force a full re-render so the live terminal re-attaches to the NEW tmux.
    _codingTeardownTerminal();
    _codingDetailShellId = null;
    await _codingRefreshDetail();
    _codingRefreshList();
  } catch (e) {
    _codingFlash((e && e.message) || 'Restart failed.');
  } finally {
    if (btn) { btn.disabled = false; btn.textContent = 'Restart'; }
  }
}
window.codingRestart = codingRestart;

async function codingDelete() {
  if (!_codingSelectedId) return;
  const ok = await showConfirmDialog({
    title: 'Delete session',
    message: 'Delete this coding session? This stops it and permanently removes it.',
    confirmLabel: 'Delete',
    cancelLabel: 'Cancel',
    danger: true,
  });
  if (!ok) return;
  const id = _codingSelectedId;
  try {
    await api('/api/coding/session/' + encodeURIComponent(id) + '/delete',
      { method: 'POST', body: JSON.stringify({}) });
    codingClearDetail();
    _codingRefreshList();
  } catch (e) {
    _codingFlash((e && e.message) || 'Delete failed.');
  }
}
window.codingDelete = codingDelete;

async function _codingRefreshSyncStatus(id) {
  const el = document.getElementById('codingSyncStatus');
  if (!el || String(_codingSelectedId) !== String(id)) return;
  let st;
  try { st = await api('/api/coding/session/' + encodeURIComponent(id) + '/sync'); }
  catch (_) { return; }
  if (String(_codingSelectedId) !== String(id)) return;
  if (!st || !st.enabled) { el.innerHTML = ''; return; }
  const online = !!st.device_online;
  const status = st.status || 'idle';
  const syncing = status === 'syncing' || status === 'opening' || status === 'connecting';
  const dotColor = online ? '#2ecc71' : '#888';
  // status label + color
  const labels = { synced: 'Up to date', syncing: 'Syncing…', opening: 'Connecting…',
    connecting: 'Connecting…',
    idle: online ? 'Idle' : 'Waiting for device', disconnected: 'Device offline',
    conflicts: 'Conflicts', error: 'Error', off: '' };
  let label = labels[status] || status;
  if (status === 'conflicts' && st.conflicts) label = `${st.conflicts} conflict${st.conflicts > 1 ? 's' : ''} (auto-resolving\u2026)`;
  if (st.healed && status !== 'conflicts') label += ` \u00b7 ${st.healed} auto-resolved`;
  if (!online && status !== 'disconnected') label = 'Device offline';
  const pct = (syncing && st.total) ? Math.round((st.done / st.total) * 100) : (status === 'synced' ? 100 : 0);
  const bar = syncing
    ? `<div style="height:6px;background:#1a1f2b;border-radius:4px;overflow:hidden;margin-top:6px">
         <div style="height:100%;width:${st.total ? pct : 40}%;background:#3b82f6;border-radius:4px;transition:width .3s"></div>
       </div>${st.total ? `<div class="cdg-hint">${st.done}/${st.total} files · ${pct}%</div>` : '<div class="cdg-hint">syncing…</div>'}`
    : '';
  el.innerHTML = `
    <div class="cm-section">
      <div class="cm-section-head">
        <span class="cm-section-title">Sync</span>
        <button type="button" class="cdg-btn-secondary" style="font-size:11px;padding:2px 8px" onclick="codingRefreshSync()">Refresh</button>
      </div>
      <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap">
        <span class="cdg-dot" style="background:${dotColor};width:9px;height:9px;border-radius:50%;display:inline-block"></span>
        <span>${_cdgEsc(st.device || 'device')}</span>
        <span style="opacity:.6">${online ? 'online' : 'disconnected'}</span>
        <span style="margin-left:auto;opacity:.85">${_cdgEsc(label)}</span>
      </div>
      ${bar}
      ${(status === 'error' && st.error) ? `<div class="cdg-hint" style="color:#e06c75;margin-top:6px;word-break:break-word">${_cdgEsc(st.error)}</div>` : ''}
    </div>`;
}

async function codingRefreshSync() {
  if (!_codingSelectedId) return;
  const id = _codingSelectedId;
  try { await api('/api/coding/session/' + encodeURIComponent(id) + '/sync/refresh', { method: 'POST', body: JSON.stringify({}) }); }
  catch (_) {}
  _codingRefreshSyncStatus(id);
}
window.codingRefreshSync = codingRefreshSync;

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

/* ── Live list-status poll ──────────────────────────────────────────────────
 * Keeps every visible session's dot + state chip live (working/waiting/idle)
 * while the Coding panel is shown — independent of which session is selected.
 * Updates the dots IN PLACE (no innerHTML rebuild) so it never disrupts the
 * user's clicking/scrolling. New/removed sessions still come in via the full
 * _codingRefreshList() on panel-open + after mutations.
 */
let _codingStatusPollTimer = null;
const _CODING_STATUS_POLL_MS = 5000;

function _codingApplyLiveStatus(sessions) {
  for (const s of (sessions || [])) {
    const id = String(s && s.id != null ? s.id : '');
    if (!id) continue;
    const item = document.querySelector(`.cdg-item[data-id="${CSS.escape(id)}"]`);
    if (!item) continue;
    const st = _cdgDisplayState(s);
    const dot = item.querySelector('.cdg-dot');
    if (dot) { dot.className = 'cdg-dot cdg-dot-' + st; dot.title = _cdgStateLabel(st); }
    let chip = item.querySelector('.cdg-item-state');
    if (st === 'waiting' || st === 'working') {
      if (!chip && dot) { chip = document.createElement('span'); dot.parentNode.insertBefore(chip, dot); }
      if (chip) { chip.className = 'cdg-item-state cdg-state-' + st; chip.textContent = _cdgStateLabel(st); }
    } else if (chip) {
      chip.remove();
    }
  }
}

let _codingListSig = '';
async function _codingPollStatusOnce() {
  try {
    const res = await api('/api/coding/sessions');
    const sessions = (res && res.sessions) || [];
    _codingRenderUsage((res && res.usage) || null);
    // Structure signature: which sessions exist + their name/source/project.
    // If it changed (a session appeared/vanished/was renamed), do a FULL refresh
    // so the list goes live; otherwise just update the dots in place (smooth).
    const sig = sessions
      .map(s => `${s.id}~${s.title || ''}~${s.source || ''}~${s.project_id || ''}`)
      .sort().join('|');
    if (sig !== _codingListSig) {
      _codingListSig = sig;
      await _codingRefreshList();   // scroll preserved inside _codingRenderList
    } else {
      _codingApplyLiveStatus(sessions);
    }
  } catch (_) { /* transient — retry next tick */ }
}

function _codingStartStatusPoll() {
  _codingStopStatusPoll();
  _codingStatusPollTimer = setInterval(() => {
    if (typeof _currentPanel === 'string' && _currentPanel !== 'coding') { _codingStopStatusPoll(); return; }
    if (typeof document !== 'undefined' && document.hidden) return;
    _codingPollStatusOnce();
  }, _CODING_STATUS_POLL_MS);
}

function _codingStopStatusPoll() {
  if (_codingStatusPollTimer) { clearInterval(_codingStatusPollTimer); _codingStatusPollTimer = null; }
}

/* ── Instant state-change stream (SSE) ───────────────────────────────────────
 * The primary update path: the server pushes a nudge the moment any session's
 * activity_state or lifecycle changes (hook-driven), so the panel updates
 * INSTANTLY instead of on the 4-5s poll. The polls above stay as a fallback if
 * this stream can't connect (mirrors the kanban events SSE). Nudges are
 * coalesced so a burst (e.g. several sessions finishing at once) is one refresh.
 */
function _codingOnEventNudge(e) {
  // A coding-event payload (finished / needs-input) → show an in-browser toast.
  try {
    if (e && e.data) {
      const d = JSON.parse(e.data);
      if (d && d.type === 'coding-event') {
        const t = d.title || (d.event === 'stop' ? '✅ Claude finished' : '🔔 Claude needs you');
        _codingFlash(`${t}${d.label ? ' — ' + d.label : ''}`);
      }
    }
  } catch (_) { /* malformed payload — ignore, the refetch below still runs */ }
  if (_codingEventsDebounce) return;   // a refresh is already scheduled
  _codingEventsDebounce = setTimeout(() => {
    _codingEventsDebounce = null;
    if (typeof _currentPanel === 'string' && _currentPanel !== 'coding') return;
    _codingPollStatusOnce();                       // list dots + structure
    if (_codingSelectedId) _codingRefreshDetail(); // the open session
  }, 120);
}

function _codingStartEventsStream() {
  _codingStopEventsStream();
  if (typeof EventSource === 'undefined') return;  // poll fallback covers it
  try {
    const url = new URL('/api/coding/events/stream', document.baseURI || location.href);
    const es = new EventSource(url.href, { withCredentials: true });
    es.addEventListener('coding', _codingOnEventNudge);
    // On error EventSource auto-reconnects; the polls remain as the backstop.
    _codingEventsES = es;
  } catch (_) { /* leave the polls as the sole update path */ }
}

function _codingStopEventsStream() {
  if (_codingEventsES) { try { _codingEventsES.close(); } catch (_) {} _codingEventsES = null; }
  if (_codingEventsDebounce) { clearTimeout(_codingEventsDebounce); _codingEventsDebounce = null; }
}

// Cleared from panels.js when the panel is switched away (mirrors how other
// panels stop their timers), but also self-guards inside the interval above.
function onCodingPanelLeave() { _codingStopPoll(); _codingStopStatusPoll(); _codingStopEventsStream(); _codingTeardownTerminal(); _codingDetailShellId = null; }
window.onCodingPanelLeave = onCodingPanelLeave;

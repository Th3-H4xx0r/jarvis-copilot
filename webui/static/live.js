// JarvisCopilot — Live Jarvis (web view). Phase 3 of the Live Jarvis design
// (docs/superpowers/specs/2026-09-21-live-jarvis-design.md §7.2).
//
// The web client never captures: it views and controls. Everything here is a
// read/act client of the frozen /api/live/* surface:
//
//   GET  /api/live/sessions                                → session list
//   GET  /api/live/transcript?live_session_id=&after_seq=   → backlog
//   GET  /api/live/events?live_session_id=&after_seq=       → SSE: seg, speaker,
//                                                             insight, state, resync
//   GET  /api/live/speakers                                 → voices + samples
//   POST /api/live/speaker/rename {speaker_id, name}
//   POST /api/live/speaker/merge  {from_id, into_id}
//   GET  /api/live/storage                                  → bytes + note
//   POST /api/live/delete {kind:"session"|"speaker_forget"|"speaker_audio", id}
//   GET/PUT /api/live/config
//   POST /api/live/factcheck {live_session_id, seq}
//   POST /api/live/translate {live_session_id, seq, target}
//
// Three things here are deliberate and worth not undoing:
//
//  1. Speaker labels are resolved at paint time through the label store in
//     live_labels.js, never baked into the DOM. That is what makes a
//     `speaker` frame (rename / merge / confirm) relabel utterances already on
//     screen — retroactively for a merge — with no reload. Segments keep the
//     speaker_id the server gave them; the store follows the alias chain.
//  2. A dropped SSE stream is the normal case (§8: a real iPhone drops about
//     once a minute), so the status line says "reconnecting", not "error", and
//     the cursor resumes from the last seq we hold.
//  3. Every endpoint can be missing. A 404 degrades to a visible, non-fatal
//     notice with a retry, because phase 1/2 may not be deployed on the box
//     this page is served from.
//
// Mounts: #liveSessionList (sidebar), #liveTabs, #liveHeaderActions,
// #liveStatus, #liveBody (main pane). Everything inside those is built here,
// which is also what lets live_fixture.html drive this file offline.

// ── state ───────────────────────────────────────────────────────────────────

let _liveSessions = [];
let _liveSessionsError = null;          // last failed /sessions response, if any
let _liveSessionId = null;
let _liveSessionRow = null;
let _liveSegs = [];                     // ordered by seq
const _liveSegNodes = new Map();        // seq → segment element
let _liveInsights = [];                 // {id, kind, seq, text, …}
const _liveInsightIds = new Set();      // de-dup across POST reply + SSE echo
let _liveLabelStore = null;
let _liveSSE = null;
let _liveSSEUrlSid = null;              // which session the open stream is for
let _liveSSERetry = null;
let _liveSSEStatus = 'idle';            // idle | connecting | live | reconnecting | unavailable
let _liveSSEFailures = 0;               // consecutive failures since the last successful open
let _liveTab = 'transcript';            // transcript | speakers | storage
let _liveStorage = null;
let _liveSpeakers = [];
let _liveConfig = null;
let _liveRuntimeState = {};             // last `state` frame
let _liveSettingsModal = null;
let _liveBooted = false;
// Guards a slow response landing under a later screen, the same way
// integrations.js guards its detail pane with _intgView.
let _liveRenderToken = 0;

const _LIVE_SSE_RETRY_MS = 3000;
// How many times a stream that has NEVER opened is retried before the status
// line admits it is not coming back. A stream that opened once is exempt.
const _LIVE_SSE_MAX_COLD_RETRIES = 5;
const _LIVE_TABS = [
  { id: 'transcript', label: 'Transcript' },
  { id: 'speakers', label: 'Speakers' },
  { id: 'storage', label: 'Storage' },
];
const _LIVE_CONFIG_BOOLS = ['enabled', 'monitor', 'fact_check', 'translate', 'memory_extraction', 'artifacts'];

// ── small helpers (fall back when ui.js/workspace.js are not loaded, so
//    live_fixture.html can drive this file with nothing else on the page) ────

function _lEsc(s) {
  if (typeof esc === 'function') return esc(s);
  return String(s == null ? '' : s).replace(/[&<>"']/g, c =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
function _lEl(id) { return document.getElementById(id); }
// "es" → "Spanish". Empty for a tag the browser cannot name, so the card shows
// nothing rather than a raw code.
function _liveLanguageName(code) {
  const tag = String(code || '').trim();
  if (!tag) return '';
  try {
    const names = new Intl.DisplayNames([navigator.language || 'en'], { type: 'language' });
    const name = names.of(tag) || names.of(tag.split('-')[0]);
    return name && name !== tag ? name : '';
  } catch (e) { return ''; }
}
function _lToast(msg, ms, type) {
  if (typeof showToast === 'function') showToast(msg, ms, type);
  else console.log('[live]', msg);
}
// The app's own dialogs — never the browser's, which cannot be styled or
// translated (tests/test_sprint33.py enforces this). If the helper is somehow
// absent the answer is "no": refusing a destructive action is the safe default,
// and a rename that silently does nothing is better than one that guesses.
function _lConfirm(opts) {
  if (typeof showConfirmDialog === 'function') return showConfirmDialog(opts);
  _lToast('Dialogs are unavailable, so this action was not run.', null, 'error');
  return Promise.resolve(false);
}
function _lPrompt(opts) {
  if (typeof showPromptDialog === 'function') return showPromptDialog(opts);
  _lToast('Dialogs are unavailable, so this action was not run.', null, 'error');
  return Promise.resolve(null);
}
function _lLabels() {
  return (typeof JCLiveLabels !== 'undefined') ? JCLiveLabels : null;
}

// One request helper for the whole view. Never throws: a missing endpoint is an
// expected state here, not an exception, and every caller wants to render
// something rather than abort. Returns {ok, data, status, error}.
async function _liveReq(path, opts) {
  try {
    if (typeof api === 'function') {
      const data = await api(path, opts);
      return { ok: true, data: data, status: 200 };
    }
    const rel = path.startsWith('/') ? path.slice(1) : path;
    const url = new URL(rel, document.baseURI || location.href);
    const res = await fetch(url.href, Object.assign(
      { credentials: 'include', headers: { 'Content-Type': 'application/json' } }, opts || {}));
    if (!res.ok) return { ok: false, status: res.status, error: 'HTTP ' + res.status };
    const ct = res.headers.get('content-type') || '';
    return { ok: true, status: res.status, data: ct.includes('application/json') ? await res.json() : await res.text() };
  } catch (e) {
    return { ok: false, status: (e && e.status) || 0, error: (e && e.message) || String(e) };
  }
}

function _liveJson(path, body, method) {
  return _liveReq(path, { method: method || 'POST', body: JSON.stringify(body || {}) });
}

// The wrapper key on the list endpoints is not pinned down by the protocol, so
// pull the array out of whatever shape arrives instead of rendering an empty
// screen over a naming difference.
function _liveArray(payload, preferred) {
  if (Array.isArray(payload)) return payload;
  if (!payload || typeof payload !== 'object') return [];
  for (const key of (preferred || [])) if (Array.isArray(payload[key])) return payload[key];
  for (const v of Object.values(payload)) if (Array.isArray(v)) return v;
  return [];
}

function _liveFmtBytes(n) {
  const L = _lLabels();
  return L ? L.formatBytes(n) : String(n || 0) + ' B';
}
function _liveFmtDuration(ms) {
  const L = _lLabels();
  return L ? L.formatDuration(ms) : Math.round((ms || 0) / 1000) + 's';
}
function _liveFmtSegTime(seg) {
  const L = _lLabels();
  if (!L) return '';
  return L.formatSegmentTime(seg && seg.ts_start_ms, _liveSessionRow && _liveSessionRow.started_at);
}
function _liveFmtWhen(epochSec) {
  const sec = Number(epochSec || 0);
  if (!sec) return '';
  const d = new Date(sec * 1000);
  if (isNaN(d.getTime())) return '';
  const today = new Date();
  const sameDay = d.toDateString() === today.toDateString();
  const time = String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
  return sameDay ? time : (d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' }) + ' ' + time);
}

// A fact-check citation is a URL a language model chose with web tools in hand.
// Escaping stops attribute injection but not a javascript:/data: href, so only
// real web schemes are allowed to become a link; anything else renders as text.
function _liveSafeUrl(raw) {
  const url = String(raw || '').trim();
  if (!url) return '';
  if (/^(https?:)?\/\//i.test(url)) return url;
  if (/^\/[^/]/.test(url)) return url;              // same-origin absolute path
  return '';
}

function _liveNote(text, cls) {
  return `<div class="live-note${cls ? ' ' + cls : ''}">${_lEsc(text)}</div>`;
}

// The one place that decides how a missing endpoint reads. Visible, explains
// itself, and offers the retry — but nothing else on the page breaks.
function _liveUnavailableHtml(what, res, retryFn) {
  const status = res && res.status ? res.status : 0;
  const why = status === 404
    ? `The server has no ${_lEsc(what)} endpoint yet (404). Live Jarvis needs phases 1–2 deployed.`
    : `Could not load ${_lEsc(what)}${status ? ' (HTTP ' + status + ')' : ''}. ${_lEsc((res && res.error) || '')}`;
  return `<div class="live-unavailable">
    <div class="live-unavailable-title">Live Jarvis is not answering</div>
    <div class="live-unavailable-body">${why}</div>
    ${retryFn ? `<button class="live-btn" onclick="${retryFn}">Retry</button>` : ''}
  </div>`;
}

// ── entry points (called from switchPanel in panels.js) ──────────────────────

async function loadLive(force) {
  _liveBooted = true;
  // Opening the panel (or hitting Refresh) is a deliberate "try again", so the
  // cold-retry budget starts over.
  _liveSSEFailures = 0;
  if (_liveSSEStatus === 'unavailable') _liveSSEStatus = 'idle';
  if (!_liveLabelStore && _lLabels()) _liveLabelStore = _lLabels().createLabelStore();
  _liveRenderTabs();
  _liveRenderHeaderActions();
  await _liveLoadSessions(force);
  await _liveLoadSpeakers();          // names must exist before the first paint
  _liveLoadStorage();                 // status line wants the total; don't block on it
  if (!_liveConfig) _liveLoadConfig();
  if (_liveSessionId) await _liveOpenSession(_liveSessionId, { keepStream: true });
  else _liveRenderBody();
}

// Leaving the panel must not leave a stream open in the background — same
// contract as onCodingPanelLeave()/onVoicePanelLeave().
function onLivePanelLeave() {
  _liveStopSSE();
}

// ── sessions (sidebar) ──────────────────────────────────────────────────────

async function _liveLoadSessions(force) {
  const box = _lEl('liveSessionList');
  if (box && !_liveSessions.length) box.innerHTML = _liveNote('Loading…');
  const res = await _liveReq('/api/live/sessions');
  if (!res.ok) {
    _liveSessions = [];
    // Remembered, because a later re-render of this list must not replace the
    // notice with "no sessions yet" — that would claim there is nothing to see
    // when the truth is that nobody answered.
    _liveSessionsError = res;
    _liveRenderSessionList();
    return;
  }
  _liveSessionsError = null;
  _liveSessions = _liveArray(res.data, ['sessions', 'live_sessions', 'items']);
  // Newest first. The endpoint already orders by started_at desc, but a client
  // that assumes order it did not enforce is a bug waiting for a server tweak.
  _liveSessions.sort((a, b) => Number(b.started_at || 0) - Number(a.started_at || 0));
  if (!_liveSessionId && _liveSessions.length) _liveSessionId = _liveSessions[0].id;
  _liveSessionRow = _liveSessions.find(s => s.id === _liveSessionId) || _liveSessionRow;
  _liveRenderSessionList();
  if (force === true && _liveSessionId) await _liveOpenSession(_liveSessionId, {});
}

function _liveRenderSessionList() {
  const box = _lEl('liveSessionList');
  if (!box) return;
  if (_liveSessionsError) {
    box.innerHTML = _liveUnavailableHtml('/api/live/sessions', _liveSessionsError, 'loadLive(true)');
    return;
  }
  if (!_liveSessions.length) {
    box.innerHTML = _liveNote('No live sessions yet. Start Live mode on a device with a mic.');
    return;
  }
  box.innerHTML = _liveSessions.map(s => {
    const recording = String(s.state || '') === 'recording';
    const title = s.title || s.source_label || s.device_id || 'Live session';
    return `<div class="live-session-item${s.id === _liveSessionId ? ' active' : ''}" data-live-session="${_lEsc(s.id)}">
      <div class="live-session-top">
        ${recording ? '<span class="live-rec-dot" aria-hidden="true"></span>' : ''}
        <span class="live-session-name" title="${_lEsc(title)}">${_lEsc(title)}</span>
      </div>
      <div class="live-session-meta">${_lEsc(_liveFmtWhen(s.started_at))}${
        s.source_label ? ' · ' + _lEsc(s.source_label) : (s.device_id ? ' · ' + _lEsc(s.device_id) : '')
      }${recording ? ' · recording' : ''}</div>
    </div>`;
  }).join('');
  box.querySelectorAll('[data-live-session]').forEach(el => {
    el.onclick = () => _liveOpenSession(el.dataset.liveSession, {});
  });
}

async function _liveOpenSession(sid, opts) {
  const options = opts || {};
  const changed = sid !== _liveSessionId;
  _liveSessionId = sid;
  _liveSessionRow = _liveSessions.find(s => s.id === sid) || null;
  if (changed) {
    _liveSSEFailures = 0;     // a different session gets its own retry budget
    _liveSegs = [];
    _liveSegNodes.clear();
    _liveInsights = [];
    _liveInsightIds.clear();
    _liveRuntimeState = {};
  }
  _liveRenderSessionList();
  _liveTab = 'transcript';
  _liveRenderTabs();
  _liveRenderBody();
  await _liveLoadTranscript();
  if (changed || !options.keepStream || _liveSSEUrlSid !== sid) _liveStartSSE();
  _liveRenderStatus();
}

// ── transcript ──────────────────────────────────────────────────────────────

async function _liveLoadTranscript(afterSeq) {
  if (!_liveSessionId) return;
  const from = afterSeq == null ? 0 : afterSeq;
  const res = await _liveReq('/api/live/transcript?live_session_id='
    + encodeURIComponent(_liveSessionId) + '&after_seq=' + encodeURIComponent(from));
  if (!res.ok) {
    const body = _lEl('liveTimeline') || _lEl('liveBody');
    if (body && _liveTab === 'transcript') {
      body.innerHTML = _liveUnavailableHtml('/api/live/transcript', res, 'loadLive(true)');
    }
    return;
  }
  const segs = _liveArray(res.data, ['segments', 'segs', 'transcript', 'items']);
  if (from === 0) {
    _liveSegs = segs.slice().sort((a, b) => Number(a.seq) - Number(b.seq));
    _liveSegNodes.clear();
  } else {
    for (const seg of segs) _liveMergeSeg(seg);
  }
  // A transcript payload may carry the session row and its own insights; take
  // them when offered rather than making a second round trip.
  if (res.data && typeof res.data === 'object' && !Array.isArray(res.data)) {
    if (res.data.session && typeof res.data.session === 'object') _liveSessionRow = res.data.session;
    for (const ins of _liveArray(res.data.insights, ['insights'])) _liveRecordInsight(ins);
  }
  if (_liveLabelStore) for (const seg of _liveSegs) _liveLabelStore.noteSegment(seg);
  if (_liveTab === 'transcript') _liveRenderBody();
  _liveRenderStatus();
}

// Insert or replace one segment in seq order. A stream can deliver out of
// order and can redeliver after a resume, so this is idempotent.
function _liveMergeSeg(seg) {
  if (!seg || seg.seq == null) return null;
  const seq = Number(seg.seq);
  const idx = _liveSegs.findIndex(s => Number(s.seq) === seq);
  if (idx >= 0) { _liveSegs[idx] = Object.assign({}, _liveSegs[idx], seg); return _liveSegs[idx]; }
  let at = _liveSegs.length;
  while (at > 0 && Number(_liveSegs[at - 1].seq) > seq) at--;
  _liveSegs.splice(at, 0, seg);
  if (_liveLabelStore) _liveLabelStore.noteSegment(seg);
  return seg;
}

function _liveLabelFor(seg) {
  if (_liveLabelStore) return _liveLabelStore.labelFor(seg);
  return { id: seg && seg.speaker_id, name: (seg && seg.local_label) || 'Speaker', provisional: true, kind: 'other' };
}

function _liveSegHtml(seg) {
  const label = _liveLabelFor(seg);
  const conf = seg.speaker_conf == null ? '' : Math.round(Number(seg.speaker_conf) * 100) + '%';
  // Which language a translation came out of. Without it a line of English
  // under a line of Chinese characters is just two sentences, and a
  // translation cannot be told from a correction.
  const from = seg.translation ? _liveLanguageName(seg.lang) : '';
  return `
    <div class="live-seg-head">
      <button class="live-chip${label.provisional ? ' provisional' : ''}${label.kind === 'me' ? ' me' : ''}"
              data-live-rename="${_lEsc(seg.seq)}"
              title="${label.provisional ? 'Provisional label — click to name this voice' : 'Click to rename this voice'}">
        <span class="live-chip-name">${_lEsc(label.name)}</span>${
          label.provisional ? '<span class="live-chip-mark" aria-label="provisional label">?</span>' : ''}
      </button>
      <span class="live-seg-time">${_lEsc(_liveFmtSegTime(seg))}</span>
      ${conf ? `<span class="live-seg-conf" title="Speaker match confidence">${_lEsc(conf)}</span>` : ''}
      ${seg.lang ? `<span class="live-seg-lang">${_lEsc(seg.lang)}</span>` : ''}
      <span class="live-seg-actions">
        <button class="live-act" data-live-act="factcheck" data-seq="${_lEsc(seg.seq)}" title="Fact-check this utterance">Fact-check</button>
        <button class="live-act" data-live-act="translate" data-seq="${_lEsc(seg.seq)}" title="Translate this utterance">Translate</button>
        <button class="live-act" data-live-act="copy" data-seq="${_lEsc(seg.seq)}" title="Copy the text">Copy</button>
      </span>
    </div>
    <div class="live-seg-text">${_lEsc(seg.text || '')}</div>
    <div class="live-seg-translation"${seg.translation ? '' : ' hidden'}>${_lEsc(seg.translation || '')}${
      from ? `<span class="live-seg-from">from ${_lEsc(from)}</span>` : ''}</div>`;
}

function _liveSegNode(seg) {
  const el = document.createElement('div');
  el.className = 'live-seg';
  el.dataset.seq = String(seg.seq);
  el.innerHTML = _liveSegHtml(seg);
  _liveBindSegNode(el, seg);
  _liveSegNodes.set(Number(seg.seq), el);
  return el;
}

function _liveBindSegNode(el, seg) {
  el.querySelectorAll('[data-live-act]').forEach(btn => {
    btn.onclick = () => _liveSegAction(btn.dataset.liveAct, Number(btn.dataset.seq), btn);
  });
  const chip = el.querySelector('[data-live-rename]');
  if (chip) chip.onclick = () => _liveRenameFromSegment(Number(seg.seq));
}

// Repaint one segment in place. This is the hook the `speaker` frames use:
// the DOM node stays, its chip is rebuilt from the label store.
function _liveRepaintSeg(seq) {
  const n = Number(seq);
  const el = _liveSegNodes.get(n);
  const seg = _liveSegs.find(s => Number(s.seq) === n);
  if (!el || !seg) return false;
  el.innerHTML = _liveSegHtml(seg);
  _liveBindSegNode(el, seg);
  return true;
}

// Repaint every segment attributed to any of these speaker ids — including ids
// that were merged away, since those chips are exactly the ones showing a
// stale name. Called with no ids it repaints everything, which is what a
// rename of an unknown voice or a resync needs.
function _liveRepaintSpeakers(ids) {
  const store = _liveLabelStore;
  const wanted = new Set((ids || []).filter(Boolean).map(String));
  let n = 0;
  for (const seg of _liveSegs) {
    if (wanted.size) {
      const raw = String(seg.speaker_id || '');
      const canon = store ? String(store.canonical(raw) || '') : raw;
      if (!wanted.has(raw) && !wanted.has(canon)) continue;
    }
    if (_liveRepaintSeg(seg.seq)) n++;
  }
  return n;
}

// ── insights (monitor notes, fact-check verdicts, translations) ──────────────

// Insights arrive twice in the normal case: once as the POST reply and once as
// the SSE echo. An id de-dups them; without one, the (kind, seq, text) triple
// does, which is stable enough for a note.
function _liveInsightKey(ins) {
  if (ins && ins.id) return 'id:' + ins.id;
  return ['k', ins && (ins.kind || ins.type || 'note'), ins && ins.seq, (ins && (ins.text || ins.summary || ins.verdict)) || ''].join('|');
}

function _liveRecordInsight(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const ins = {
    id: raw.id || null,
    kind: String(raw.kind || raw.type || 'note'),
    // `anchor_seq` is the line a conversation-level verdict actually
    // judged; without it the card lands after whatever was said last.
    seq: raw.seq != null ? Number(raw.seq)
       : (raw.anchor_seq != null ? Number(raw.anchor_seq) : null),
    title: raw.title || '',
    text: raw.text || raw.summary || raw.verdict || raw.note || raw.message || '',
    verdict: raw.verdict || '',
    confidence: raw.confidence != null ? raw.confidence : null,
    sources: Array.isArray(raw.sources) ? raw.sources : (Array.isArray(raw.citations) ? raw.citations : []),
    created_at: raw.created_at || raw.ts || null,
    pending: !!raw.pending,
  };
  const key = _liveInsightKey(ins);
  if (_liveInsightIds.has(key)) {
    // A real insight replacing our local "requested…" placeholder is the one
    // case where the same key should overwrite instead of being dropped.
    const at = _liveInsights.findIndex(x => _liveInsightKey(x) === key);
    if (at >= 0 && _liveInsights[at].pending && !ins.pending) _liveInsights[at] = ins;
    return _liveInsights[at] || null;
  }
  _liveInsightIds.add(key);
  _liveInsights.push(ins);
  return ins;
}

function _liveInsightLabel(kind) {
  const k = String(kind || '').toLowerCase();
  if (k.includes('fact')) return 'Fact-check';
  if (k.includes('trans')) return 'Translation';
  if (k.includes('monitor') || k.includes('note') || k.includes('digest')) return 'Monitor';
  if (k.includes('memory')) return 'Memory';
  if (k.includes('artifact')) return 'Artifact';
  return kind ? String(kind) : 'Insight';
}

// Only an outright "false". A substring test would catch "not false" and
// "unverifiable" has "verifiable" in it — both of which have burned this kind
// of check before.
function _liveVerdictIsFalse(verdict) {
  const v = String(verdict || '').trim().toLowerCase().replace(/[.!]+$/, '');
  return v === 'false' || v === 'incorrect' || v === 'untrue' || v === 'wrong';
}

function _liveInsightNode(ins) {
  const el = document.createElement('div');
  const kindClass = String(ins.kind || 'note').toLowerCase().replace(/[^a-z]+/g, '-');
  // A verdict of "false" is the one result worth reading from across the room,
  // so it gets the red accent. "misleading" and "unverifiable" deliberately do
  // not: they are not the same claim, and colouring them the same would make
  // the colour mean "a fact-check happened" rather than "this is wrong".
  const wrong = _liveVerdictIsFalse(ins.verdict) ? ' live-insight--false' : '';
  el.className = 'live-insight live-insight--' + kindClass + wrong
    + (ins.pending ? ' pending' : '');
  el.dataset.insightKey = _liveInsightKey(ins);
  const sources = (ins.sources || []).map(s => {
    const url = _liveSafeUrl(typeof s === 'string' ? s : (s.url || s.href || ''));
    const title = typeof s === 'string' ? s : (s.title || s.name || url);
    return url
      ? `<a class="live-insight-src" href="${_lEsc(url)}" target="_blank" rel="noopener noreferrer">${_lEsc(title)}</a>`
      : `<span class="live-insight-src">${_lEsc(title)}</span>`;
  }).join('');
  el.innerHTML = `
    <div class="live-insight-head">
      <span class="live-insight-kind">${_lEsc(_liveInsightLabel(ins.kind))}</span>
      ${ins.verdict ? `<span class="live-insight-verdict">${_lEsc(ins.verdict)}</span>` : ''}
      ${ins.confidence != null ? `<span class="live-insight-conf">${_lEsc(Math.round(Number(ins.confidence) * 100) + '%')}</span>` : ''}
      ${ins.seq != null ? `<span class="live-insight-anchor">on #${_lEsc(ins.seq)}</span>` : ''}
    </div>
    ${ins.title ? `<div class="live-insight-title">${_lEsc(ins.title)}</div>` : ''}
    <div class="live-insight-text">${ins.text ? _lEsc(ins.text)
      : (ins.pending ? '<span class="live-insight-spin" aria-hidden="true"></span>Checking the last few minutes…' : '')}</div>
    ${sources ? `<div class="live-insight-sources">${sources}</div>` : ''}`;
  return el;
}

// ── timeline render ─────────────────────────────────────────────────────────

function _liveTimelineHtmlEmpty() {
  if (!_liveSessionId) {
    return `<div class="main-view-empty">
      <div class="main-view-empty-title">No live session selected</div>
      <div class="main-view-empty-sub">Pick a session on the left. The web client views and controls Live Jarvis; capture happens on a device with a mic.</div>
    </div>`;
  }
  return `<div class="main-view-empty">
    <div class="main-view-empty-title">Nothing transcribed yet</div>
    <div class="main-view-empty-sub">Utterances appear here as they are recognised.</div>
  </div>`;
}

function _liveRenderTranscript() {
  const body = _lEl('liveBody');
  if (!body) return;
  body.innerHTML = '<div class="live-timeline" id="liveTimeline"></div>';
  const tl = _lEl('liveTimeline');
  _liveSegNodes.clear();
  if (!_liveSegs.length && !_liveInsights.length) {
    tl.innerHTML = _liveTimelineHtmlEmpty();
    return;
  }
  // Insights anchored to a segment sit directly under it; unanchored ones (the
  // monitor's rolling notes) land after the last segment they could refer to.
  const bySeq = new Map();
  const trailing = [];
  const lastSeq = _liveSegs.length ? Number(_liveSegs[_liveSegs.length - 1].seq) : -1;
  for (const ins of _liveInsights) {
    if (ins.seq != null && ins.seq <= lastSeq) {
      if (!bySeq.has(ins.seq)) bySeq.set(ins.seq, []);
      bySeq.get(ins.seq).push(ins);
    } else trailing.push(ins);
  }
  for (const seg of _liveSegs) {
    tl.appendChild(_liveSegNode(seg));
    for (const ins of (bySeq.get(Number(seg.seq)) || [])) tl.appendChild(_liveInsightNode(ins));
  }
  for (const ins of trailing) tl.appendChild(_liveInsightNode(ins));
  _liveScrollToEnd();
}

function _liveNearBottom() {
  const body = _lEl('liveBody');
  if (!body) return true;
  return (body.scrollHeight - body.scrollTop - body.clientHeight) < 120;
}
function _liveScrollToEnd() {
  const body = _lEl('liveBody');
  if (body) body.scrollTop = body.scrollHeight;
}

// Append without redrawing the transcript: a two-hour conversation must not
// re-render on every utterance, and the reader's scroll position is sacred
// unless they were already at the bottom.
function _liveAppendSegNode(seg) {
  const tl = _lEl('liveTimeline');
  if (!tl || _liveTab !== 'transcript') return;
  if (tl.querySelector('.main-view-empty')) tl.innerHTML = '';
  const stick = _liveNearBottom();
  const existing = _liveSegNodes.get(Number(seg.seq));
  if (existing) { _liveRepaintSeg(seg.seq); return; }
  const node = _liveSegNode(seg);
  // Out-of-order arrival: put it before the first later segment rather than at
  // the end, so the transcript stays readable in time order.
  let anchor = null;
  for (const [otherSeq, otherEl] of _liveSegNodes) {
    if (otherSeq > Number(seg.seq) && (!anchor || otherSeq < anchor.seq)) anchor = { seq: otherSeq, el: otherEl };
  }
  if (anchor) tl.insertBefore(node, anchor.el);
  else tl.appendChild(node);
  if (stick) _liveScrollToEnd();
}

function _liveAppendInsightNode(ins) {
  const tl = _lEl('liveTimeline');
  if (!tl || _liveTab !== 'transcript') return;
  if (tl.querySelector('.main-view-empty')) tl.innerHTML = '';
  const key = _liveInsightKey(ins);
  // Scanned rather than queried: the key embeds free text from the model, and
  // building a selector out of that is a needless way to throw.
  const prior = Array.from(tl.children).find(el => el.dataset && el.dataset.insightKey === key);
  const stick = _liveNearBottom();
  const node = _liveInsightNode(ins);
  if (prior) { prior.replaceWith(node); return; }
  const anchorEl = ins.seq != null ? _liveSegNodes.get(Number(ins.seq)) : null;
  if (anchorEl && anchorEl.nextSibling) tl.insertBefore(node, anchorEl.nextSibling);
  else if (anchorEl) tl.appendChild(node);
  else tl.appendChild(node);
  if (stick) _liveScrollToEnd();
}

// ── status line ─────────────────────────────────────────────────────────────

function _liveStreamLabel() {
  switch (_liveSSEStatus) {
    case 'live': return 'streaming';
    case 'connecting': return 'connecting…';
    case 'reconnecting': return 'reconnecting…';
    case 'unavailable': return 'stream unavailable';
    default: return 'idle';
  }
}

function _liveRenderStatus() {
  const el = _lEl('liveStatus');
  if (!el) return;
  const row = _liveSessionRow || {};
  const runtime = _liveRuntimeState || {};
  const recording = runtime.state
    ? String(runtime.state) === 'recording'
    : String(row.state || '') === 'recording';
  const paused = String(runtime.state || '') === 'paused';
  const stateText = paused ? 'Paused' : (recording ? 'Recording' : (row.id ? 'Ended' : 'No session'));
  const total = _liveStorage && _liveStorage.total_bytes != null
    ? _liveFmtBytes(_liveStorage.total_bytes)
    : (runtime.total_bytes != null ? _liveFmtBytes(runtime.total_bytes) : '—');
  const warn = runtime.warning || runtime.warnings || runtime.message || '';
  const warnText = Array.isArray(warn) ? warn.join(' · ') : warn;
  el.innerHTML = `
    <span class="live-status-item live-status-state${paused ? ' paused' : (recording ? ' rec' : '')}">
      ${recording && !paused ? '<span class="live-rec-dot" aria-hidden="true"></span>' : ''}${_lEsc(stateText)}
    </span>
    <span class="live-status-item">${_lEsc(_liveSegs.length)} utterance${_liveSegs.length === 1 ? '' : 's'}</span>
    <span class="live-status-item">${_lEsc(total)} stored</span>
    <span class="live-status-item live-status-stream live-status-stream--${_lEsc(_liveSSEStatus)}">${_lEsc(_liveStreamLabel())}</span>
    ${row.source_label || row.device_id ? `<span class="live-status-item">${_lEsc(row.source_label || row.device_id)}</span>` : ''}
    ${warnText ? `<span class="live-status-item live-status-warn">${_lEsc(warnText)}</span>` : ''}`;
}

// ── SSE ─────────────────────────────────────────────────────────────────────

function _liveLastSeq() {
  let max = 0;
  for (const seg of _liveSegs) max = Math.max(max, Number(seg.seq) || 0);
  return max;
}

function _liveStopSSE() {
  if (_liveSSERetry) { clearTimeout(_liveSSERetry); _liveSSERetry = null; }
  if (_liveSSE) { try { _liveSSE.close(); } catch (e) { /* already gone */ } }
  _liveSSE = null;
  _liveSSEUrlSid = null;
  if (_liveSSEStatus !== 'unavailable') _liveSSEStatus = 'idle';
}

function _liveStartSSE() {
  if (!_liveSessionId) return;
  _liveStopSSE();
  const sid = _liveSessionId;
  const url = 'api/live/events?live_session_id=' + encodeURIComponent(sid)
    + '&after_seq=' + encodeURIComponent(_liveLastSeq());
  let es;
  try {
    es = new EventSource(url);
  } catch (e) {
    _liveSSEStatus = 'unavailable';
    _liveRenderStatus();
    return;
  }
  _liveSSE = es;
  _liveSSEUrlSid = sid;
  _liveSSEStatus = 'connecting';
  _liveRenderStatus();

  es.onopen = () => {
    if (_liveSSE !== es) return;
    _liveSSEStatus = 'live';
    _liveSSEFailures = 0;         // a stream that connected earns a fresh budget
    _liveRenderStatus();
  };

  // Sent once on connect, carrying everything after the cursor we asked for.
  // This is what closes the gap a disconnect opened: without it, utterances
  // spoken while the stream was down would never appear until a manual
  // refresh. It can redeliver segments we already hold — seq makes that free.
  es.addEventListener('snapshot', ev => _liveOnSnapshotEvent(ev, sid, es));
  es.addEventListener('seg', ev => _liveOnSegEvent(ev, sid, es));
  es.addEventListener('speaker', ev => _liveOnSpeakerEvent(ev, sid, es));
  es.addEventListener('insight', ev => _liveOnInsightEvent(ev, sid, es));
  es.addEventListener('state', ev => _liveOnStateEvent(ev, sid, es));
  // The server sends this when a subscriber fell behind and events were
  // dropped for it. Anything could be missing, so refetch rather than carry on
  // looking healthy (same call the chat mirror makes).
  es.addEventListener('resync', () => {
    if (_liveSSE !== es) return;
    console.warn('[live] server dropped events for this client; resyncing', sid);
    _liveLoadTranscript(0);
    _liveLoadSpeakers();
  });

  // A dropped stream is the normal case here (§8), so this is a reconnect path,
  // not an error path. The browser only auto-reconnects a connection that was
  // established once, so a 404/401 on the handshake has to be retried by hand
  // or the view dies silently.
  es.onerror = () => {
    if (_liveSSE !== es) return;
    const closed = (typeof EventSource !== 'undefined') && es.readyState === EventSource.CLOSED;
    _liveSSEStatus = 'reconnecting';
    _liveRenderStatus();
    if (!closed) return;                 // browser is handling its own retry
    _liveSSE = null;
    _liveSSEFailures++;
    // A stream that has never connected is a missing or refused endpoint, not a
    // flaky phone. Retrying that forever every three seconds is a background
    // hammer nobody asked for, so it gives up and says so instead. A stream
    // that DID connect is the normal drop case and retries indefinitely.
    if (_liveSSEFailures > _LIVE_SSE_MAX_COLD_RETRIES) {
      _liveSSEStatus = 'unavailable';
      _liveRenderStatus();
      return;
    }
    if (_liveSSERetry) clearTimeout(_liveSSERetry);
    const delay = _LIVE_SSE_RETRY_MS * Math.min(_liveSSEFailures, 5);
    _liveSSERetry = setTimeout(() => {
      _liveSSERetry = null;
      if (_liveSessionId === sid && _liveBooted) _liveStartSSE();
    }, delay);
  };
}

function _liveParse(ev) {
  try { return JSON.parse((ev && ev.data) || '{}'); } catch (e) {
    console.warn('[live] bad frame', e);
    return null;
  }
}

function _liveOnSnapshotEvent(ev, sid, es) {
  if (_liveSSE !== es || _liveSessionId !== sid) return;
  const d = _liveParse(ev);
  if (!d) return;
  if (d.session && typeof d.session === 'object') _liveSessionRow = d.session;
  const segs = _liveArray(d.segments, ['segments']);
  let added = 0;
  for (const raw of segs) {
    if (!raw || raw.seq == null) continue;
    const known = _liveSegs.some(s => Number(s.seq) === Number(raw.seq));
    const merged = _liveMergeSeg(raw);
    if (!merged) continue;
    if (known) _liveRepaintSeg(merged.seq);
    else { _liveAppendSegNode(merged); added++; }
  }
  if (added) console.info('[live] snapshot filled', added, 'missed utterance(s)');
  _liveRenderStatus();
  _liveRenderSessionList();
}

function _liveOnSegEvent(ev, sid, es) {
  if (_liveSSE !== es || _liveSessionId !== sid) return;
  const d = _liveParse(ev);
  if (!d) return;
  // A frame may carry one segment or a batch, and may wrap it.
  const segs = Array.isArray(d) ? d : (Array.isArray(d.segments) ? d.segments : [d.segment || d]);
  for (const raw of segs) {
    if (!raw || raw.seq == null) continue;
    // partial:true is the device's in-progress guess (§2.2). Show it so the
    // transcript feels live, and let the final frame overwrite it in place.
    const merged = _liveMergeSeg(raw);
    if (merged) _liveAppendSegNode(merged);
  }
  _liveRenderStatus();
}

function _liveOnSpeakerEvent(ev, sid, es) {
  if (_liveSSE !== es) return;
  const d = _liveParse(ev);
  if (!d || !_liveLabelStore) return;
  const change = _liveLabelStore.applySpeakerEvent(d);
  if (change.op === 'merge') {
    const dead = String(d.from_id || d.from || '');
    const survivor = _liveLabelStore.canonical(dead);
    // Rewrite the ids we hold as well as aliasing them: a later resync or
    // append must not resurrect the dead label.
    _liveLabelStore.retagSegments(_liveSegs, dead, survivor);
    _liveRepaintSpeakers([dead, survivor]);
    // The merged-away voice must stop being its own row, or the Speakers view
    // shows two cards with the same name.
    _liveSpeakers = _liveSpeakers.filter(s => String(s.id) !== dead);
  } else if (change.segSeqs && change.segSeqs.length) {
    // op=confirm naming specific segments: pin them to the speaker, then
    // repaint just those.
    const spk = d.speaker_id || d.id || null;
    for (const seq of change.segSeqs) {
      const seg = _liveSegs.find(s => Number(s.seq) === Number(seq));
      if (!seg) continue;
      if (spk) seg.speaker_id = spk;
      seg.label_state = 'confirmed';
      if (d.speaker_conf != null) seg.speaker_conf = d.speaker_conf;
      _liveRepaintSeg(seq);
    }
  } else {
    _liveRepaintSpeakers(change.ids && change.ids.length ? change.ids : null);
  }
  // The speakers tab, if open, shows the same names.
  if (_liveTab === 'speakers') _liveRenderSpeakers();
  _liveRenderStatus();
}

function _liveOnInsightEvent(ev, sid, es) {
  if (_liveSSE !== es) return;
  const d = _liveParse(ev);
  if (!d) return;
  const list = Array.isArray(d) ? d : (Array.isArray(d.insights) ? d.insights : [d.insight || d]);
  for (const raw of list) {
    const ins = _liveRecordInsight(raw);
    if (!ins) continue;
    // A translation insight belongs under its utterance, not as a card, when
    // it carries the translated text for a segment we hold.
    if (String(ins.kind).toLowerCase().includes('trans') && ins.seq != null) {
      const seg = _liveSegs.find(s => Number(s.seq) === Number(ins.seq));
      if (seg && ins.text) {
        seg.translation = ins.text;
        _liveRepaintSeg(seg.seq);
        continue;
      }
    }
    _liveAppendInsightNode(ins);
  }
}

function _liveOnStateEvent(ev, sid, es) {
  if (_liveSSE !== es) return;
  const d = _liveParse(ev);
  if (!d) return;
  // The server reports a fallen-behind subscriber as a `state` frame carrying
  // warning:"resync" rather than a dedicated event, so that shape has to mean
  // the same thing as the `resync` event: refetch, do not carry on looking
  // healthy.
  if (String(d.warning || '') === 'resync') {
    console.warn('[live] server reported a resync for', sid);
    _liveLoadTranscript(0);
    _liveLoadSpeakers();
  }
  _liveRuntimeState = Object.assign({}, _liveRuntimeState, d);
  const storage = d.storage && typeof d.storage === 'object' ? d.storage : null;
  if (storage && storage.total_bytes != null) {
    _liveStorage = Object.assign({}, _liveStorage || {}, storage);
  } else if (d.total_bytes != null) {
    _liveStorage = Object.assign({}, _liveStorage || {}, { total_bytes: d.total_bytes });
  }
  if (d.state && _liveSessionRow) _liveSessionRow.state = d.state;
  _liveRenderStatus();
  _liveRenderSessionList();
}

// ── per-segment actions ─────────────────────────────────────────────────────

async function _liveSegAction(act, seq, btn) {
  const seg = _liveSegs.find(s => Number(s.seq) === Number(seq));
  if (!seg) return;
  if (act === 'copy') {
    try {
      await navigator.clipboard.writeText(seg.text || '');
      const old = btn.textContent;
      btn.textContent = 'Copied';
      setTimeout(() => { btn.textContent = old; }, 1200);
    } catch (e) { _lToast('Clipboard blocked by the browser', null, 'error'); }
    return;
  }
  if (act === 'factcheck') return _liveFactCheck(seq, btn);
  if (act === 'translate') return _liveTranslate(seq, btn);
}

function _liveBusy(btn, label) {
  if (!btn) return () => {};
  const old = btn.textContent;
  btn.disabled = true;
  btn.textContent = label;
  return () => { btn.disabled = false; btn.textContent = old; };
}

// The verdict may come back in the POST reply or over the stream; either is
// valid, so show a placeholder and let whichever arrives fill it in.
// The watcher endpoints answer {"ok":true,"result":{…}} — and a watcher that
// is switched off or that threw still comes back as HTTP 200 with
// result.ok === false. Unwrapping the envelope and honouring that inner flag
// is the difference between reporting a failure and rendering a blank card.
function _liveWatcherResult(res) {
  if (!res.ok) {
    return { failed: true, message: res.status === 404
      ? 'This server has no such endpoint yet'
      : (res.status === 503 ? 'Live watchers are unavailable on this server'
        : (res.error || 'HTTP ' + res.status)) };
  }
  const payload = (res.data && typeof res.data === 'object') ? res.data : {};
  const inner = (payload.result && typeof payload.result === 'object') ? payload.result
    : (payload.insight && typeof payload.insight === 'object' ? payload.insight : payload);
  if (inner && inner.ok === false) return { failed: true, message: inner.error || 'the watcher declined' };
  if (payload.error) return { failed: true, message: payload.error };
  return { failed: false, insight: inner };
}

async function _liveFactCheck(seq, btn) {
  const done = _liveBusy(btn, 'Checking…');
  const res = await _liveJson('/api/live/factcheck', { live_session_id: _liveSessionId, seq: Number(seq) });
  done();
  const out = _liveWatcherResult(res);
  if (out.failed) { _lToast('Fact-check failed: ' + out.message, null, 'error'); return; }
  const ins = out.insight;
  const hasText = ins && (ins.text || ins.verdict || ins.summary);
  const rec = _liveRecordInsight(hasText
    ? Object.assign({ kind: 'fact_check', seq: Number(seq) }, ins)
    // No body in the reply is legitimate: the verdict is fanned out over the
    // stream instead. Show it is coming rather than nothing at all.
    : { kind: 'fact_check', seq: Number(seq), pending: true });
  if (rec) _liveAppendInsightNode(rec);
}

async function _liveTranslate(seq, btn) {
  const target = (_liveConfig && _liveConfig.primary_language) || 'en';
  const done = _liveBusy(btn, 'Translating…');
  const res = await _liveJson('/api/live/translate', { live_session_id: _liveSessionId, seq: Number(seq), target: target });
  done();
  const out = _liveWatcherResult(res);
  if (out.failed) { _lToast('Translate failed: ' + out.message, null, 'error'); return; }
  const ins = out.insight || {};
  const text = ins.translation || ins.text || '';
  const seg = _liveSegs.find(s => Number(s.seq) === Number(seq));
  // A translation belongs under its utterance, not as a card beside it.
  if (text && seg) {
    seg.translation = text;
    _liveRepaintSeg(seq);
    return;
  }
  const rec = _liveRecordInsight({ kind: 'translation', seq: Number(seq), pending: !text, text: text });
  if (rec) _liveAppendInsightNode(rec);
}

// "Name this voice" from the transcript. A segment the server has not resolved
// yet has no id to hang a name on, and saying so is better than renaming the
// wrong voice.
async function _liveRenameFromSegment(seq) {
  const seg = _liveSegs.find(s => Number(s.seq) === Number(seq));
  if (!seg) return;
  if (!seg.speaker_id) {
    _lToast('This voice has no identity yet — the label is the device\'s guess. It can be named once the server resolves it.', 6000, 'warning');
    return;
  }
  const label = _liveLabelFor(seg);
  const suggested = /^Speaker \d+$/.test(label.name) ? '' : label.name;
  const name = await _lPrompt({
    title: 'Name this voice',
    message: `Heard saying: "${(seg.text || '').slice(0, 120)}"`,
    value: suggested,
    placeholder: 'e.g. Priya',
    confirmLabel: 'Save',
    selectAll: true,
  });
  if (name == null) return;
  await _liveRenameSpeaker(seg.speaker_id, String(name).trim());
}

async function _liveRenameSpeaker(speakerId, name) {
  const res = await _liveJson('/api/live/speaker/rename', { speaker_id: speakerId, name: name });
  if (!res.ok) {
    _lToast(res.status === 404 ? 'Speaker rename is not available on this server yet'
      : 'Rename failed: ' + (res.error || res.status), null, 'error');
    return false;
  }
  // Apply locally rather than waiting for the SSE echo: the person who typed
  // the name should see it immediately, and the echo is idempotent.
  if (_liveLabelStore) _liveLabelStore.rename(speakerId, name);
  _liveRepaintSpeakers([speakerId]);
  for (const s of _liveSpeakers) if (s.id === speakerId) s.name = name;
  if (_liveTab === 'speakers') _liveRenderSpeakers();
  _lToast(name ? 'Voice renamed to ' + name : 'Voice name cleared');
  return true;
}

// ── speakers view ───────────────────────────────────────────────────────────

async function _liveLoadSpeakers() {
  const res = await _liveReq('/api/live/speakers');
  if (!res.ok) {
    _liveSpeakers = [];
    if (_liveTab === 'speakers') {
      const body = _lEl('liveBody');
      if (body) body.innerHTML = _liveUnavailableHtml('/api/live/speakers', res, 'loadLive(true)');
    }
    return false;
  }
  _liveSpeakers = _liveArray(res.data, ['speakers', 'voices', 'items']);
  if (_liveLabelStore) {
    _liveLabelStore.setSpeakers(_liveSpeakers);
    // A response that predates a merge still lists the dead voice. Rendering it
    // would put two cards with the same name side by side, so it is dropped
    // here rather than being allowed to look like a second person.
    _liveSpeakers = _liveSpeakers.filter(s => String(_liveLabelStore.canonical(s.id)) === String(s.id));
  }
  // Names may have changed under us (another client renamed a voice), so the
  // transcript is repainted rather than left stale.
  _liveRepaintSpeakers(null);
  if (_liveTab === 'speakers') _liveRenderSpeakers();
  return true;
}

// The sample-utterance key is not pinned down by the protocol; accept the
// shapes the store could plausibly serialise to rather than showing nothing.
function _liveSamplesOf(spk) {
  const raw = spk.samples || spk.sample_utterances || spk.recent || spk.utterances || spk.examples || [];
  return (Array.isArray(raw) ? raw : []).map(s => (typeof s === 'string' ? { text: s } : s));
}

function _liveSpeakerDisplay(spk) {
  if (spk.name) return spk.name;
  if (_liveLabelStore) return _liveLabelStore.labelFor({ speaker_id: spk.id, label_state: 'confirmed' }).name;
  return spk.id;
}

function _liveRenderSpeakers() {
  const body = _lEl('liveBody');
  if (!body) return;
  if (!_liveSpeakers.length) {
    body.innerHTML = `<div class="main-view-empty">
      <div class="main-view-empty-title">No voices yet</div>
      <div class="main-view-empty-sub">A voice appears once Live Jarvis has heard it and minted an identity for it.</div>
    </div>`;
    return;
  }
  const others = _liveSpeakers;
  body.innerHTML = `<div class="live-speakers">${others.map(spk => {
    const samples = _liveSamplesOf(spk);
    const mergeOptions = others.filter(o => o.id !== spk.id).map(o =>
      `<option value="${_lEsc(o.id)}">${_lEsc(_liveSpeakerDisplay(o))}</option>`).join('');
    return `<section class="live-card" data-speaker="${_lEsc(spk.id)}">
      <div class="live-card-head">
        <div class="live-card-title">
          <span class="live-chip${spk.kind === 'me' ? ' me' : ''}">${_lEsc(_liveSpeakerDisplay(spk))}</span>
          ${spk.kind === 'me' ? '<span class="live-tag">you</span>' : ''}
        </div>
        <div class="live-card-meta">${_lEsc(spk.segment_count || 0)} utterance${Number(spk.segment_count) === 1 ? '' : 's'}
          · ${_lEsc(_liveFmtDuration(spk.speech_ms))} of speech
          ${spk.last_heard_at ? ' · last heard ' + _lEsc(_liveFmtWhen(spk.last_heard_at)) : ''}</div>
      </div>
      <div class="live-rename-row">
        <input class="live-input" type="text" value="${_lEsc(spk.name || '')}"
               placeholder="${_lEsc(_liveSpeakerDisplay(spk))}" data-rename-input="${_lEsc(spk.id)}"
               autocomplete="off" spellcheck="false">
        <button class="live-btn" data-rename-save="${_lEsc(spk.id)}">Save name</button>
        ${mergeOptions ? `<select class="live-select" data-merge-from="${_lEsc(spk.id)}">
          <option value="">Merge into…</option>${mergeOptions}
        </select>` : ''}
      </div>
      ${samples.length ? `<div class="live-samples">${samples.map(s => `
        <div class="live-sample">
          <span class="live-sample-time">${_lEsc(s.ts_start_ms != null ? _liveFmtSegTime(s) : '')}</span>
          <span class="live-sample-text">${_lEsc(s.text || '')}</span>
        </div>`).join('')}</div>`
      : _liveNote('No sample utterances returned for this voice.')}
      <div class="live-card-actions">
        <button class="live-btn live-btn--danger" data-forget="${_lEsc(spk.id)}">Forget this voice…</button>
        <button class="live-btn live-btn--danger" data-purge-audio="${_lEsc(spk.id)}">Delete every recording this voice is in…</button>
      </div>
    </section>`;
  }).join('')}</div>`;
  _liveBindSpeakerCards(body);
}

function _liveBindSpeakerCards(scope) {
  scope.querySelectorAll('[data-rename-save]').forEach(btn => {
    btn.onclick = async () => {
      const id = btn.dataset.renameSave;
      // The input next to this button, found by structure rather than by
      // building a selector out of a server-supplied id.
      const card = btn.closest('.live-card') || scope;
      const input = card.querySelector('[data-rename-input]');
      await _liveRenameSpeaker(id, input ? input.value.trim() : '');
    };
  });
  scope.querySelectorAll('[data-rename-input]').forEach(input => {
    input.onkeydown = ev => {
      if (ev.key !== 'Enter') return;
      ev.preventDefault();
      _liveRenameSpeaker(input.dataset.renameInput, input.value.trim());
    };
  });
  scope.querySelectorAll('[data-merge-from]').forEach(sel => {
    sel.onchange = async () => {
      const into = sel.value;
      if (!into) return;
      const from = sel.dataset.mergeFrom;
      sel.value = '';
      const fromName = _liveSpeakerDisplay(_liveSpeakers.find(s => s.id === from) || { id: from });
      const intoName = _liveSpeakerDisplay(_liveSpeakers.find(s => s.id === into) || { id: into });
      const ok = await _lConfirm({
        title: 'Merge these voices?',
        message: `Everything "${fromName}" said becomes "${intoName}", including utterances already in the transcript. `
          + 'This cannot be undone from here.',
        confirmLabel: 'Merge',
        danger: true,
      });
      if (!ok) return;
      await _liveMergeSpeakers(from, into);
    };
  });
  scope.querySelectorAll('[data-forget]').forEach(btn => {
    btn.onclick = () => _liveDelete('speaker_forget', btn.dataset.forget);
  });
  scope.querySelectorAll('[data-purge-audio]').forEach(btn => {
    btn.onclick = () => _liveDelete('speaker_audio', btn.dataset.purgeAudio);
  });
}

async function _liveMergeSpeakers(fromId, intoId) {
  const res = await _liveJson('/api/live/speaker/merge', { from_id: fromId, into_id: intoId });
  if (!res.ok) {
    _lToast(res.status === 404 ? 'Speaker merge is not available on this server yet'
      : 'Merge failed: ' + (res.error || res.status), null, 'error');
    return false;
  }
  if (_liveLabelStore) {
    const survivor = _liveLabelStore.merge(fromId, intoId);
    _liveLabelStore.retagSegments(_liveSegs, fromId, survivor);
  }
  _liveRepaintSpeakers([fromId, intoId]);
  _liveSpeakers = _liveSpeakers.filter(s => s.id !== fromId);
  if (_liveTab === 'speakers') _liveRenderSpeakers();
  _liveLoadSpeakers();      // pick up the server's merged counters
  _lToast('Voices merged');
  return true;
}

// ── storage view ────────────────────────────────────────────────────────────

async function _liveLoadStorage() {
  const res = await _liveReq('/api/live/storage');
  if (!res.ok) {
    if (_liveTab === 'storage') {
      const body = _lEl('liveBody');
      if (body) body.innerHTML = _liveUnavailableHtml('/api/live/storage', res, 'loadLive(true)');
    }
    _liveRenderStatus();
    return false;
  }
  _liveStorage = res.data || {};
  if (_liveTab === 'storage') _liveRenderStorage();
  _liveRenderStatus();
  return true;
}

function _liveSortedBySize(rows, key) {
  return (rows || []).slice().sort((a, b) => Number(b[key] || 0) - Number(a[key] || 0));
}

// The storage payload can still list a voice that has since been merged away,
// which would show two rows under one name. They are folded into the survivor
// rather than dropped — the bytes are real even though the id is not.
function _liveFoldMergedSpeakers(rows) {
  if (!_liveLabelStore) return rows || [];
  const out = new Map();
  for (const row of (rows || [])) {
    const id = String(_liveLabelStore.canonical(row.id) || row.id || '');
    const prev = out.get(id);
    if (!prev) { out.set(id, Object.assign({}, row, { id: id })); continue; }
    prev.approx_bytes = Number(prev.approx_bytes || 0) + Number(row.approx_bytes || 0);
    prev.speech_ms = Number(prev.speech_ms || 0) + Number(row.speech_ms || 0);
    prev.segment_count = Number(prev.segment_count || 0) + Number(row.segment_count || 0);
    if (!prev.name && row.name) prev.name = row.name;
    if (row.kind === 'me') prev.kind = 'me';
  }
  return Array.from(out.values());
}

function _liveRenderStorage() {
  const body = _lEl('liveBody');
  if (!body) return;
  if (!_liveStorage) { body.innerHTML = _liveNote('Loading…'); return; }
  const st = _liveStorage;
  const perSession = _liveSortedBySize(_liveArray(st.per_session, ['per_session']), 'bytes');
  const perDay = _liveSortedBySize(_liveArray(st.per_day, ['per_day']), 'bytes');
  const perSpeaker = _liveSortedBySize(
    _liveFoldMergedSpeakers(_liveArray(st.per_speaker_approx, ['per_speaker_approx'])), 'approx_bytes');

  body.innerHTML = `
    <div class="live-storage">
      <section class="live-card live-storage-total">
        <div class="live-storage-total-value">${_lEsc(_liveFmtBytes(st.total_bytes))}</div>
        <div class="live-storage-total-meta">${_lEsc(st.chunks || 0)} audio chunk${Number(st.chunks) === 1 ? '' : 's'} on disk</div>
      </section>

      <section class="live-card">
        <h4 class="live-card-h">By day <span class="live-count">${perDay.length}</span></h4>
        ${perDay.length ? perDay.map(d => `
          <div class="live-row">
            <span class="live-row-name">${_lEsc(d.day || '—')}</span>
            <span class="live-row-size">${_lEsc(_liveFmtBytes(d.bytes))}</span>
          </div>`).join('') : _liveNote('Nothing recorded yet.')}
        ${perDay.length ? _liveNote('A day is deleted by deleting the sessions it holds — the delete endpoint takes sessions, voices and voice-audio.') : ''}
      </section>

      <section class="live-card">
        <h4 class="live-card-h">By session <span class="live-count">${perSession.length}</span></h4>
        ${perSession.length ? perSession.map(s => `
          <div class="live-row">
            <span class="live-row-name" title="${_lEsc(s.live_session_id)}">${_lEsc(s.title || s.source_label || s.live_session_id)}</span>
            <span class="live-row-sub">${_lEsc(_liveFmtWhen(s.started_at))} · ${_lEsc(s.chunks || 0)} chunk${Number(s.chunks) === 1 ? '' : 's'}</span>
            <span class="live-row-size">${_lEsc(_liveFmtBytes(s.bytes))}</span>
            <button class="live-btn live-btn--danger live-btn--sm" data-del-session="${_lEsc(s.live_session_id)}">Delete…</button>
          </div>`).join('') : _liveNote('No session audio stored.')}
      </section>

      <section class="live-card">
        <h4 class="live-card-h">By voice <span class="live-count">${perSpeaker.length}</span>
          <span class="live-approx">approximate</span></h4>
        ${perSpeaker.length ? perSpeaker.map(s => `
          <div class="live-row">
            <span class="live-row-name">${_lEsc(s.name || _liveSpeakerDisplay(s))}</span>
            <span class="live-row-sub">${_lEsc(s.segment_count || 0)} utterance${Number(s.segment_count) === 1 ? '' : 's'} · ${_lEsc(_liveFmtDuration(s.speech_ms))}</span>
            <span class="live-row-size">≈ ${_lEsc(_liveFmtBytes(s.approx_bytes))}</span>
            <button class="live-btn live-btn--danger live-btn--sm" data-forget="${_lEsc(s.id)}">Forget…</button>
            <button class="live-btn live-btn--danger live-btn--sm" data-purge-audio="${_lEsc(s.id)}">Delete audio…</button>
          </div>`).join('') : _liveNote('No voices heard yet.')}
        ${st.note ? `<div class="live-storage-note">${_lEsc(st.note)}</div>` : ''}
      </section>
    </div>`;

  body.querySelectorAll('[data-del-session]').forEach(btn => {
    btn.onclick = () => _liveDelete('session', btn.dataset.delSession);
  });
  _liveBindSpeakerCards(body);
}

// The three delete kinds have genuinely different blast radii, so each gets its
// own wording. The audio one has to say out loud that it removes whole
// recordings and takes other people's voices with them (§3.1).
function _liveDeleteCopy(kind, id) {
  const spk = _liveSpeakers.find(s => s.id === id)
    || _liveArray(_liveStorage && _liveStorage.per_speaker_approx, ['per_speaker_approx']).find(s => s.id === id);
  const who = spk ? _liveSpeakerDisplay(spk) : id;
  const sess = _liveSessions.find(s => s.id === id)
    || _liveArray(_liveStorage && _liveStorage.per_session, ['per_session']).find(s => s.live_session_id === id);
  const sessName = sess ? (sess.title || sess.source_label || sess.device_id || id) : id;
  if (kind === 'session') {
    return {
      title: 'Delete this session?',
      message: `"${sessName}" — its transcript segments and its audio chunks are removed from disk. `
        + 'This cannot be undone.',
      confirmLabel: 'Delete session',
    };
  }
  if (kind === 'speaker_forget') {
    return {
      title: 'Forget this voice?',
      message: `The voiceprint for "${who}" and that voice's transcript rows are removed, so Jarvis will no longer `
        + 'recognise them. The recordings themselves are kept.',
      confirmLabel: 'Forget voice',
    };
  }
  return {
    title: 'Delete every recording this voice appears in?',
    message: `This deletes WHOLE audio chunks — every recording "${who}" can be heard in. `
      + 'Each chunk also contains everyone else who was speaking at the time, so other people\'s audio is '
      + 'deleted along with theirs. Transcripts of those moments lose their audio permanently. '
      + 'This cannot be undone.',
    confirmLabel: 'Delete the recordings',
  };
}

// What a delete did to remembered facts, in a sentence, or "" when there is
// nothing to say. Silence here is only correct when nothing was remembered:
// the server counts staged and unattributable entries precisely because they
// are STILL IN MEMORY.md after a delete that claimed to remove them.
function _liveDeleteFactSummary(data) {
  const parts = [];
  const n = key => Number(data[key] || 0);
  const one = key => n(key) === 1;
  if (n('facts_retracted')) {
    parts.push(n('facts_retracted') + (one('facts_retracted')
      ? ' remembered fact removed' : ' remembered facts removed'));
  }
  if (n('facts_retraction_staged')) {
    parts.push(n('facts_retraction_staged') + (one('facts_retraction_staged')
      ? ' is still in memory until you approve its removal'
      : ' are still in memory until you approve their removal'));
  }
  if (n('facts_unattributable')) {
    parts.push(n('facts_unattributable') + (one('facts_unattributable')
      ? ' could not be tied to this voice and was kept'
      : ' could not be tied to this voice and were kept'));
  }
  if (data.facts_retraction_failed) parts.push('memory was not updated: ' + data.facts_retraction_failed);
  if (data.facts_note) parts.push(String(data.facts_note));
  if (Array.isArray(data.warnings) && data.warnings.length) parts.push(data.warnings.join('; '));
  else if (data.warning) parts.push(String(data.warning));
  return parts.join('; ');
}

async function _liveDelete(kind, id) {
  const copy = _liveDeleteCopy(kind, id);
  const ok = await _lConfirm({
    title: copy.title, message: copy.message, confirmLabel: copy.confirmLabel, danger: true, focusCancel: true,
  });
  if (!ok) return false;
  const res = await _liveJson('/api/live/delete', { kind: kind, id: id });
  if (!res.ok) {
    _lToast(res.status === 404 ? 'Delete is not available on this server yet'
      : 'Delete failed: ' + (res.error || res.status), null, 'error');
    return false;
  }
  const data = res.data || {};
  const freed = data.freed_bytes != null ? ' — freed ' + _liveFmtBytes(data.freed_bytes) : '';
  // A delete that half-worked must not read as a delete that worked. The
  // server says so in `ok`, and what it could not do is in the fact counts —
  // a remembered fact is injected into every future agent's system prompt, so
  // "deleted" while one survives is the over-promise this reports.
  const detail = _liveDeleteFactSummary(data);
  const failed = data.ok === false;
  _lToast('Deleted' + freed + (detail ? ' — ' + detail : ''),
          failed || detail ? 9000 : null, failed ? 'error' : null);
  if (kind === 'session' && id === _liveSessionId) {
    _liveStopSSE();
    _liveSessionId = null;
    _liveSessionRow = null;
    _liveSegs = [];
    _liveSegNodes.clear();
    _liveInsights = [];
    _liveInsightIds.clear();
  }
  await _liveLoadSessions();
  await _liveLoadSpeakers();
  await _liveLoadStorage();
  if (_liveTab === 'transcript') _liveRenderBody();
  return true;
}

// ── settings modal (GET/PUT /api/live/config) ───────────────────────────────

async function _liveLoadConfig() {
  const res = await _liveReq('/api/live/config');
  if (!res.ok) return res;
  // The endpoint may answer with the section directly or wrapped in {config:…}.
  const data = res.data && typeof res.data === 'object' ? res.data : {};
  _liveConfig = (data.config && typeof data.config === 'object') ? data.config
    : ((data.live && typeof data.live === 'object') ? data.live : data);
  return res;
}

const _LIVE_CONFIG_HELP = {
  enabled: 'Master switch for ambient capture. Off means devices will not record.',
  monitor: 'The rolling-window watcher that can interject. Skipped when the window has little new speech.',
  fact_check: 'The Fact-check button, which checks the recent conversation. Uses a strong model with web search.',
  translate: 'Fills in translations for utterances that are not in the primary language.',
  memory_extraction: 'Writes durable facts to the configured memory provider when a window closes.',
  artifacts: 'On session end, produces a summary, decisions and action items.',
};

async function _liveOpenSettings() {
  const res = await _liveLoadConfig();
  if (!res.ok) {
    _lToast(res.status === 404 ? 'Live config endpoint is not available on this server yet'
      : 'Could not load Live settings: ' + (res.error || res.status), null, 'error');
    return;
  }
  _liveCloseSettings();
  const cfg = _liveConfig || {};
  const wrap = document.createElement('div');
  wrap.className = 'live-modal-overlay';
  wrap.id = 'liveSettingsModal';
  wrap.addEventListener('click', ev => { if (ev.target === wrap) _liveCloseSettings(); });
  const toggle = (key) => `
    <label class="live-toggle">
      <input type="checkbox" data-cfg="${key}"${cfg[key] ? ' checked' : ''}>
      <span class="live-toggle-body">
        <span class="live-toggle-name">${_lEsc(key.replace(/_/g, ' '))}</span>
        <span class="live-toggle-help">${_lEsc(_LIVE_CONFIG_HELP[key] || '')}</span>
      </span>
    </label>`;
  wrap.innerHTML = `
    <div class="live-modal" role="dialog" aria-modal="true" aria-labelledby="liveSettingsTitle">
      <h3 id="liveSettingsTitle">Live Jarvis settings</h3>
      <div class="live-modal-note">One source of truth — the same <code>live:</code> config the phone edits.</div>
      <div class="live-modal-section">${_LIVE_CONFIG_BOOLS.map(toggle).join('')}</div>
      <div class="live-modal-grid">
        <div class="live-modal-row">
          <label for="liveCfgWindow">Window (seconds)</label>
          <input type="number" id="liveCfgWindow" data-cfg="window_seconds" min="10" max="3600" step="10"
                 value="${_lEsc(cfg.window_seconds != null ? cfg.window_seconds : 120)}">
          <div class="live-modal-hint">How often the monitor looks at the rolling window.</div>
        </div>
        <div class="live-modal-row">
          <label for="liveCfgMinWords">Minimum new words</label>
          <input type="number" id="liveCfgMinWords" data-cfg="min_window_words" min="0" max="10000" step="5"
                 value="${_lEsc(cfg.min_window_words != null ? cfg.min_window_words : 25)}">
          <div class="live-modal-hint">Below this the window is skipped, so silence costs nothing.</div>
        </div>
        <div class="live-modal-row">
          <label for="liveCfgReply">Reply mode</label>
          <select id="liveCfgReply" data-cfg="reply_mode">
            <option value="text"${String(cfg.reply_mode) === 'text' ? ' selected' : ''}>Text</option>
            <option value="spoken"${String(cfg.reply_mode) === 'spoken' ? ' selected' : ''}>Spoken</option>
          </select>
          <div class="live-modal-hint">Spoken replies go to a device that declared it can speak.</div>
        </div>
        <div class="live-modal-row">
          <label for="liveCfgLang">Primary language</label>
          <input type="text" id="liveCfgLang" data-cfg="primary_language" autocomplete="off" spellcheck="false"
                 placeholder="en" value="${_lEsc(cfg.primary_language || '')}">
          <div class="live-modal-hint">Transcription locale, and the target the translate action uses.</div>
        </div>
        <div class="live-modal-row">
          <label for="liveCfgFactTokens">Fact-check budget (tokens)</label>
          <input type="number" id="liveCfgFactTokens" data-cfg="fact_check_tokens" min="50" max="100000" step="50"
                 value="${_lEsc(cfg.fact_check_tokens != null ? cfg.fact_check_tokens : 1000)}">
          <div class="live-modal-hint">How much recent conversation the Fact-check button sends.</div>
        </div>
        <div class="live-modal-row">
          <label for="liveCfgRollover">New session at (share of context)</label>
          <input type="number" id="liveCfgRollover" data-cfg="session_rollover_fraction" min="0.05" max="1" step="0.05"
                 value="${_lEsc(cfg.session_rollover_fraction != null ? cfg.session_rollover_fraction : 0.5)}">
          <div class="live-modal-hint">Recording rolls into a new session — and a new chat — once the transcript reaches this much of the model's context.</div>
        </div>
        <div class="live-modal-row live-modal-row--wide">
          <label for="liveCfgModel">Model</label>
          <select id="liveCfgModel" data-cfg="model">
            <option value="">Follow the app's model</option>
          </select>
          <div class="live-modal-hint">What Live thinks with: the monitor, the fact-check and the wrap-up. A per-task pin in <code>auxiliary:</code> still wins.</div>
        </div>
        <div class="live-modal-row live-modal-row--wide">
          <label for="liveCfgEmbed">Embedding model id</label>
          <input type="text" id="liveCfgEmbed" data-cfg="embed_model" autocomplete="off" spellcheck="false"
                 placeholder="ecapa-v1" value="${_lEsc(cfg.embed_model || '')}">
          <div class="live-modal-hint">A device whose id does not match this loses its on-device lane instead of corrupting voice identity.</div>
        </div>
      </div>
      <div class="live-modal-error" id="liveSettingsError" aria-live="polite"></div>
      <div class="live-modal-actions">
        <button type="button" class="live-btn" data-live-settings="cancel">Cancel</button>
        <button type="button" class="live-btn live-btn--primary" data-live-settings="save">Save</button>
      </div>
    </div>`;
  document.body.appendChild(wrap);
  _liveSettingsModal = wrap;
  wrap.querySelector('[data-live-settings="cancel"]').onclick = () => _liveCloseSettings();
  wrap.querySelector('[data-live-settings="save"]').onclick = () => _liveSaveSettings();
  _liveSettingsKeyHandler = ev => { if (ev.key === 'Escape') _liveCloseSettings(); };
  document.addEventListener('keydown', _liveSettingsKeyHandler, true);
  _liveFillModelOptions(wrap, cfg.model || '');
}

// The model row is populated after the modal is on screen: the list is a
// network call, and a settings dialog that waits for it before opening feels
// broken. Until it lands the row still shows the configured value, so a slow
// or missing /api/models cannot silently reset the setting on save.
async function _liveFillModelOptions(scope, current) {
  const sel = scope && scope.querySelector('#liveCfgModel');
  if (!sel) return;
  if (current) {
    const opt = document.createElement('option');
    opt.value = current;
    opt.textContent = current;
    opt.selected = true;
    sel.appendChild(opt);
  }
  const res = await _liveReq('/api/models');
  const groups = (res && res.ok && res.data && Array.isArray(res.data.groups)) ? res.data.groups : [];
  const seen = new Set(current ? [current] : []);
  for (const g of groups) {
    const og = document.createElement('optgroup');
    og.label = g.provider || g.provider_id || 'Configured';
    for (const m of (Array.isArray(g.models) ? g.models : [])) {
      if (!m || !m.id || seen.has(m.id)) continue;
      seen.add(m.id);
      const opt = document.createElement('option');
      opt.value = m.id;
      opt.textContent = m.label || m.id;
      og.appendChild(opt);
    }
    if (og.children.length) sel.appendChild(og);
  }
  sel.value = current || '';
}

let _liveSettingsKeyHandler = null;

function _liveCloseSettings() {
  if (_liveSettingsKeyHandler) {
    document.removeEventListener('keydown', _liveSettingsKeyHandler, true);
    _liveSettingsKeyHandler = null;
  }
  if (_liveSettingsModal && _liveSettingsModal.parentNode) _liveSettingsModal.parentNode.removeChild(_liveSettingsModal);
  _liveSettingsModal = null;
}

function _liveCollectSettings() {
  const scope = _liveSettingsModal;
  const out = {};
  if (!scope) return out;
  scope.querySelectorAll('[data-cfg]').forEach(input => {
    const key = input.dataset.cfg;
    if (input.type === 'checkbox') out[key] = !!input.checked;
    else if (input.type === 'number') {
      const n = Number(input.value);
      if (isFinite(n)) out[key] = n;
    } else out[key] = input.value.trim();
  });
  return out;
}

async function _liveSaveSettings() {
  const payload = _liveCollectSettings();
  const errEl = _lEl('liveSettingsError');
  if (payload.window_seconds != null && payload.window_seconds < 10) {
    if (errEl) errEl.textContent = 'Window must be at least 10 seconds.';
    return;
  }
  const res = await _liveReq('/api/live/config', { method: 'PUT', body: JSON.stringify(payload) });
  if (!res.ok) {
    const msg = res.status === 404 ? 'This server has no /api/live/config endpoint yet.'
      : 'Save failed: ' + (res.error || res.status);
    if (errEl) errEl.textContent = msg;
    else _lToast(msg, null, 'error');
    return;
  }
  // The reply carries the new effective config; take it as authoritative
  // rather than trusting a local merge, since the server validates and may
  // normalise values.
  const data = (res.data && typeof res.data === 'object') ? res.data : {};
  _liveConfig = (data.config && typeof data.config === 'object')
    ? data.config
    : Object.assign({}, _liveConfig || {}, payload);
  _liveCloseSettings();
  // The server drops keys it does not know. Silence there would make a
  // contract drift look like a working setting forever, which is the exact
  // failure its own comment warns about.
  const ignored = Array.isArray(data.ignored_keys) ? data.ignored_keys : [];
  if (ignored.length) _lToast('Saved, but the server ignored: ' + ignored.join(', '), 8000, 'warning');
  else _lToast('Live settings saved');
}

// ── chrome: tabs, header actions, body switch ───────────────────────────────

function _liveRenderTabs() {
  const el = _lEl('liveTabs');
  if (!el) return;
  el.innerHTML = _LIVE_TABS.map(tab => `
    <button class="live-tab${tab.id === _liveTab ? ' active' : ''}" role="tab"
            aria-selected="${tab.id === _liveTab}" data-live-tab="${tab.id}">${_lEsc(tab.label)}</button>`).join('');
  el.querySelectorAll('[data-live-tab]').forEach(btn => {
    btn.onclick = () => _liveSetTab(btn.dataset.liveTab);
  });
}

function _liveRenderHeaderActions() {
  const el = _lEl('liveHeaderActions');
  if (!el) return;
  el.innerHTML = `
    <button class="panel-head-btn has-tooltip has-tooltip--bottom" data-live-header="refresh"
            data-tooltip="Refresh" aria-label="Refresh">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21 12a9 9 0 1 1-3-6.7"/><polyline points="21 3 21 9 15 9"/></svg>
    </button>
    <button class="panel-head-btn has-tooltip has-tooltip--bottom" data-live-header="settings"
            data-tooltip="Live settings" aria-label="Live settings">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>
    </button>`;
  el.querySelectorAll('[data-live-header]').forEach(btn => {
    btn.onclick = () => {
      if (btn.dataset.liveHeader === 'settings') _liveOpenSettings();
      else loadLive(true);
    };
  });
}

function _liveSetTab(tab) {
  _liveTab = tab || 'transcript';
  _liveRenderTabs();
  _liveRenderBody();
  // Refresh the data the tab is about, so a panel is never stale on open.
  if (_liveTab === 'storage') _liveLoadStorage();
  if (_liveTab === 'speakers') _liveLoadSpeakers();
}

function _liveRenderBody() {
  _liveRenderToken++;
  if (_liveTab === 'speakers') _liveRenderSpeakers();
  else if (_liveTab === 'storage') _liveRenderStorage();
  else _liveRenderTranscript();
  _liveRenderStatus();
}

// The fixture harness and the browser console both want these.
if (typeof window !== 'undefined') {
  window.loadLive = loadLive;
  window.onLivePanelLeave = onLivePanelLeave;
  window._liveInternals = {
    seg: () => _liveSegs,
    insights: () => _liveInsights,
    labels: () => _liveLabelStore,
    setTab: _liveSetTab,
    openSettings: _liveOpenSettings,
    status: () => _liveSSEStatus,
  };
}

// A Background job's own chat view (agent harnesses): clicking a job card
// (harness_jobs.js) opens what the job is doing, drawn exactly like the chat —
// the question it was handed, then its reply, thinking and tool cards — live
// while it runs, its saved transcript after it ends. Read-only.
//
// Server: GET  api/harnesses/jobs/<chat>/<job>/view   → {job, task, messages, running, live}
//         GET  api/harnesses/jobs/<chat>/<job>/stream → /api/chat/stream's events, replayed
//              from the job's start then live, ending with `stream_end`.
// Drawing goes through the chat's own renderMessages({into, messages, toolCalls})
// (ui.js); an approval the job waits on is the chat's approval card
// (buildApprovalCardCopy, messages.js), answered for the job's hidden session.
// UMD: window.HarnessJobView in the page; the stream reader is require()-able
// under `node --test`.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.HarnessJobView = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  // ── the stream, as chat messages ─────────────────────────────────────────
  // The job's events become messages in the saved-session format (and live
  // tool cards in the chat's S.toolCalls format): text after a tool call is a
  // new assistant message, as it is when the chat saves a turn.
  function createFeed(task) {
    return { messages: task ? [{ role: 'user', content: String(task) }] : [],
             toolCalls: [], cur: -1, fresh: true, ended: false, approval: null };
  }

  function _assistant(f) {
    if (f.cur < 0 || f.fresh) {
      f.messages.push({ role: 'assistant', content: '', _ts: Date.now() / 1000 });
      f.cur = f.messages.length - 1;
      f.fresh = false;
    }
    return f.messages[f.cur];
  }

  // Apply one stream event. Returns whether anything shown changed.
  function feedEvent(f, name, d) {
    d = d && typeof d === 'object' ? d : {};
    const settles = { token: 1, reasoning: 1, tool_complete: 1, done: 1, apperror: 1, cancel: 1, stream_end: 1 };
    if (settles[name]) f.approval = null;   // the job moved on: nothing waits any more
    switch (name) {
      case 'token': {
        if (!d.text) return false;
        _assistant(f).content += String(d.text);
        return true;
      }
      case 'reasoning': {
        if (!d.text) return false;
        const m = _assistant(f);
        m.reasoning = (m.reasoning || '') + String(d.text);
        return true;
      }
      case 'interim_assistant': {
        const text = String(d.text || '').trim();
        if (text && !d.already_streamed) {
          const m = _assistant(f);
          m.content += (m.content ? '\n\n' : '') + text;
        }
        f.fresh = true;
        return !!text;
      }
      case 'tool': {
        if (!d.name || d.name === 'clarify') return false;
        const m = _assistant(f);
        const tid = d.tid || d.tool_call_id || `job-${f.toolCalls.length}`;
        (m.tool_calls = m.tool_calls || []).push({ id: tid, type: 'function', function: { name: d.name, arguments: '{}' } });
        f.toolCalls.push({ name: d.name, preview: d.preview || '', args: d.args || {}, snippet: '',
                           done: false, tid, assistant_msg_idx: f.cur });
        f.fresh = true;
        return true;
      }
      case 'tool_snippet': {
        const byId = d.tool_call_id ? f.toolCalls.find(c => c.tid === d.tool_call_id) : null;
        const tc = byId || [...f.toolCalls].reverse().find(c => c.name === d.name && !c.snippet);
        if (!tc) return false;
        tc.snippet = d.snippet || '';
        return true;
      }
      case 'tool_complete': {
        if (d.name === 'clarify') return false;
        let tc = [...f.toolCalls].reverse().find(c => c.done === false && (!d.name || c.name === d.name));
        if (!tc) {
          const m = _assistant(f);
          tc = { name: d.name || 'tool', preview: '', args: {}, snippet: '', tid: `job-${f.toolCalls.length}`,
                 assistant_msg_idx: f.cur };
          (m.tool_calls = m.tool_calls || []).push({ id: tc.tid, type: 'function', function: { name: tc.name, arguments: '{}' } });
          f.toolCalls.push(tc);
          f.fresh = true;
        }
        tc.preview = d.preview || tc.preview || '';
        tc.args = d.args || tc.args || {};
        tc.done = true;
        tc.is_error = !!d.is_error;
        if (d.duration !== undefined) tc.duration = d.duration;
        return true;
      }
      case 'approval': {
        const p = d.pending && typeof d.pending === 'object' ? d.pending : d;
        if (!p.approval_id && !p.command && !p.description) return false;
        f.approval = p;
        return true;
      }
      case 'apperror': {
        const label = d.type === 'cancelled' ? 'Task cancelled' : d.type === 'interrupted' ? 'Response interrupted' : 'Error';
        f.messages.push({ role: 'assistant', content: `**${label}:** ${d.message || 'the job stopped with an error.'}` });
        f.cur = f.messages.length - 1;
        f.fresh = true;
        f.ended = true;
        return true;
      }
      case 'cancel': {
        f.messages.push({ role: 'assistant', content: '*Task cancelled.*' });
        f.cur = f.messages.length - 1;
        f.fresh = true;
        f.ended = true;
        return true;
      }
      case 'done':
      case 'stream_end':
        f.ended = true;
        f.toolCalls.forEach(c => { c.done = true; });
        return true;
      default:
        return false;
    }
  }

  // Can "Always" be offered for this approval (a command with a pattern to remember)?
  function canAlways(p) {
    if (!p || p.kind === 'send') return false;
    if (typeof p.can_always === 'boolean') return p.can_always;
    return !!((Array.isArray(p.pattern_keys) && p.pattern_keys.length) || p.pattern_key);
  }

  const STATUS = { running: 'Running', done: 'Done', failed: 'Failed', stopped: 'Stopped', lost: 'Stopped' };

  // ── in the page ──────────────────────────────────────────────────────────
  const STREAM_EVENTS = ['token', 'reasoning', 'interim_assistant', 'tool', 'tool_snippet', 'tool_complete',
                         'approval', 'done', 'apperror', 'cancel', 'stream_end'];
  let el = null;           // the overlay, built on first open
  let st = null;           // the open view: {sid, id, gen, job, task, feed, es, ...}
  let gen = 0;

  const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g,
    c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const J = () => (typeof HarnessJobs !== 'undefined' ? HarnessJobs : null);
  const enc = encodeURIComponent;

  function _build() {
    el = document.createElement('div');
    el.className = 'harness-view-overlay';
    el.hidden = true;
    el.innerHTML =
      '<div class="harness-view" role="dialog" aria-modal="true" aria-labelledby="hjvTitle">' +
        '<div class="harness-view-head">' +
          '<div class="harness-view-titles">' +
            '<div class="harness-view-title-row"><span class="harness-view-title" id="hjvTitle"></span>' +
            '<span class="harness-view-pill"></span></div>' +
            '<div class="harness-view-sub"></div>' +
          '</div>' +
          '<button type="button" class="harness-view-stop" hidden>Stop</button>' +
          '<button type="button" class="harness-view-close" aria-label="Close">' +
            '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M18 6 6 18M6 6l12 12"/></svg>' +
          '</button>' +
        '</div>' +
        '<div class="harness-view-body">' +
          '<div class="messages-inner harness-view-inner"></div>' +
          '<div class="harness-view-approval"></div>' +
        '</div>' +
      '</div>';
    // First in the page: the chat's "last reply" lookups (read aloud) keep finding the chat's.
    document.body.prepend(el);
    el.addEventListener('click', ev => { if (ev.target === el) close(); });
    el.querySelector('.harness-view-close').addEventListener('click', close);
    el.querySelector('.harness-view-stop').addEventListener('click', ev => {
      if (st && J()) J().stop(st.sid, st.id, ev.currentTarget);
    });
    if (J()) J().onCard(_onCard);
  }

  const $q = sel => el.querySelector(sel);

  // While open (on document, capturing): Esc closes, Tab stays inside.
  function _onKey(ev) {
    if (!st) return;
    if (ev.key === 'Escape') { ev.preventDefault(); ev.stopPropagation(); close(); return; }
    // Enter here never answers the chat's own approval card (boot.js listens on document).
    if (ev.key === 'Enter') { ev.stopPropagation(); return; }
    if (ev.key !== 'Tab') return;
    const items = [...el.querySelectorAll('button:not([disabled]), [href], input, select, textarea, [tabindex]:not([tabindex="-1"])')]
      .filter(n => !n.hidden && n.offsetParent !== null);
    if (!items.length) return;
    const first = items[0], last = items[items.length - 1];
    if (ev.shiftKey && document.activeElement === first) { ev.preventDefault(); last.focus(); }
    else if (!ev.shiftKey && document.activeElement === last) { ev.preventDefault(); first.focus(); }
    else if (!el.contains(document.activeElement)) { ev.preventDefault(); first.focus(); }
  }

  function open(sid, id) {
    if (!sid || !id) return;
    if (!el) _build();
    if (st) _teardown();
    const mine = ++gen;
    st = { sid, id, gen: mine, job: (J() && J().cardFor(id)) || { id, status: 'running' }, task: '',
           feed: null, es: null, timer: null, drawTimer: null, ticker: null, retries: 0, pending: null, cardApproval: null,
           returnFocus: document.activeElement };
    st.cardApproval = (st.job.approval && st.job.approval.approval_id) || null;
    $q('.harness-view-inner').innerHTML = '<div class="harness-view-note">Loading…</div>';
    $q('.harness-view-approval').innerHTML = '';
    _header();
    el.hidden = false;
    document.addEventListener('keydown', _onKey, true);
    st.ticker = setInterval(_header, 1000);
    setTimeout(() => { if (st && st.gen === mine) $q('.harness-view-close').focus({ preventScroll: true }); }, 30);
    _load(mine);
  }

  function _teardown() {
    if (!st) return;
    if (st.es) { try { st.es.close(); } catch (e) { /* closed */ } }
    clearTimeout(st.timer);
    clearTimeout(st.drawTimer);
    clearInterval(st.ticker);
    st = null;
  }

  function close() {
    if (!st) return;
    const id = st.id;
    let back = st.returnFocus;
    _teardown();
    gen++;
    el.hidden = true;
    document.removeEventListener('keydown', _onKey, true);
    $q('.harness-view-inner').innerHTML = '';
    $q('.harness-view-approval').innerHTML = '';
    // The card may have been redrawn meanwhile: go back to its fresh copy.
    if (!back || !back.isConnected || back === document.body) back = document.querySelector(`.harness-job[data-job-id="${CSS.escape(id)}"] [data-job-open]`);
    if (back && typeof back.focus === 'function') back.focus({ preventScroll: true });
  }

  async function _view(mine) {
    const data = await api(`api/harnesses/jobs/${enc(st.sid)}/${enc(st.id)}/view`);
    if (!st || st.gen !== mine) return null;
    if (data && data.job) st.job = Object.assign({}, st.job, data.job);
    if (data && data.task) st.task = data.task;
    _header();
    return data || {};
  }

  async function _load(mine) {
    let data;
    try {
      data = await _view(mine);
    } catch (e) {
      if (st && st.gen === mine) _note(e && e.status === 404 ? 'This job is no longer around.' : 'Could not open this job.');
      return;
    }
    if (!data) return;
    if (Array.isArray(data.messages) && data.messages.length) { _renderSaved(data.messages); return; }
    _stream(mine);
  }

  function _note(text) {
    $q('.harness-view-inner').innerHTML = `<div class="harness-view-note">${esc(text)}</div>`;
  }

  // The job's run so far, then live. A reconnect replays from the start, so the
  // view starts over from a fresh feed rather than doubling what it shows.
  function _stream(mine) {
    if (typeof EventSource === 'undefined') { _note('This browser cannot follow the job live.'); return; }
    st.feed = createFeed(st.task);
    if (st.pending && st.pending.from === 'stream') {   // the replay brings it back if it still waits
      st.pending = null;
      $q('.harness-view-approval').innerHTML = '';
    }
    const url = new URL(`api/harnesses/jobs/${enc(st.sid)}/${enc(st.id)}/stream`, document.baseURI || location.href).href;
    const es = new EventSource(url, { withCredentials: true });
    st.es = es;
    _render();
    STREAM_EVENTS.forEach(name => es.addEventListener(name, ev => {
      if (!st || st.gen !== mine || st.es !== es) return;
      let d = {};
      try { d = JSON.parse(ev.data || '{}'); } catch (e) { /* keep {} */ }
      const changed = feedEvent(st.feed, name, d);
      if (name === 'approval' && st.feed.approval) _showApproval(st.feed.approval, 'stream');
      else if (!st.feed.approval && st.pending && st.pending.from === 'stream') _clearApproval();
      if (name === 'stream_end') { es.close(); _ended(mine); return; }
      if (changed) _schedule();
    }));
    es.onerror = () => {
      if (!st || st.gen !== mine || st.es !== es) return;
      es.close();
      if (st.feed.ended) { _ended(mine); return; }
      // Lost the feed mid-run: ask where the job stands, then follow it again.
      if (++st.retries > 5) { _render(); return; }
      st.timer = setTimeout(async () => {
        let data;
        try { data = await _view(mine); } catch (e) { data = null; }
        if (!st || st.gen !== mine) return;
        if (data && Array.isArray(data.messages) && data.messages.length) { _renderSaved(data.messages); return; }
        if (data && data.live) _stream(mine);
        else _render();
      }, 1500 * st.retries);
    };
  }

  async function _ended(mine) {
    st.es = null;
    _clearApproval();
    _render();
    try {
      const data = await _view(mine);
      if (data && Array.isArray(data.messages) && data.messages.length) _renderSaved(data.messages);
      else if (data && data.running && data.live && st && st.gen === mine) _stream(mine);
      else _render();
    } catch (e) { /* what the stream showed stays */ }
  }

  function _schedule() {
    if (!st || st.drawTimer) return;
    st.drawTimer = setTimeout(() => { if (st) { st.drawTimer = null; _render(); } }, 120);
  }

  // Drawing: the chat's own renderer into the view's container. A redraw keeps
  // what was unfolded and where it was scrolled (pinned to the end follows it).
  function _draw(messages, toolCalls, working) {
    const body = $q('.harness-view-body');
    const inner = $q('.harness-view-inner');
    const pinned = body.scrollHeight - body.scrollTop - body.clientHeight < 80;
    const top = body.scrollTop;
    const opened = sel => [...inner.querySelectorAll(sel)].map((n, i) => (n.matches('.open') ? i : -1)).filter(i => i >= 0);
    const openTools = opened('.tool-card'), openThinking = opened('.thinking-card');
    const openGroups = [...inner.querySelectorAll('.tool-call-group')]
      .map((n, i) => (n.classList.contains('tool-call-group-collapsed') ? -1 : i)).filter(i => i >= 0);
    if (typeof renderMessages === 'function') {
      renderMessages({ into: inner, messages, toolCalls });
    } else {
      inner.innerHTML = messages.map(m => `<div class="msg-row"><div class="msg-body">${esc(typeof m.content === 'string' ? m.content : '')}</div></div>`).join('');
    }
    const reopen = (sel, list, fn) => { const all = inner.querySelectorAll(sel); list.forEach(i => all[i] && fn(all[i])); };
    reopen('.tool-card', openTools, n => n.classList.add('open'));
    reopen('.thinking-card', openThinking, n => n.classList.add('open'));
    reopen('.tool-call-group', openGroups, n => {
      n.classList.remove('tool-call-group-collapsed');
      const s = n.querySelector('.tool-call-group-summary');
      if (s) s.setAttribute('aria-expanded', 'true');
    });
    if (working) {
      let turn = [...inner.children].filter(n => n.classList.contains('assistant-turn')).pop();
      if (!turn || turn !== inner.lastElementChild) {
        turn = typeof _createAssistantTurn === 'function' ? _createAssistantTurn() : document.createElement('div');
        inner.appendChild(turn);
      }
      const blocks = turn.querySelector('.assistant-turn-blocks') || turn;
      const dots = document.createElement('div');
      dots.className = 'assistant-segment harness-view-working';
      dots.innerHTML = '<div class="thinking"><div class="dot"></div><div class="dot"></div><div class="dot"></div></div>';
      blocks.appendChild(dots);
    }
    body.scrollTop = pinned ? body.scrollHeight : top;
  }

  function _render() {
    if (!st || !st.feed) return;   // no feed: the saved transcript is what shows
    const f = st.feed;
    const running = st.job.status === 'running' && !f.ended && !!st.es;
    _draw(f.messages, f.toolCalls, running && !st.pending);
    if (!running && !f.messages.some(m => m.role === 'assistant')) {
      const note = st.job.status === 'running' ? 'Lost the live feed. Close and open the job again to retry.'
        : 'Nothing was kept of what this job did.';
      $q('.harness-view-inner').insertAdjacentHTML('beforeend', `<div class="harness-view-note">${esc(note)}</div>`);
    }
  }

  function _renderSaved(messages) {
    if (st.es) { try { st.es.close(); } catch (e) { /* closed */ } st.es = null; }
    st.feed = null;
    _clearApproval();
    const list = (st.task ? [{ role: 'user', content: st.task }] : []).concat(messages.filter(m => m && m.role));
    _draw(list, [], false);
  }

  function _header() {
    if (!st || !el) return;
    const job = st.job;
    const H = J();
    const v = H ? H.view(job, Date.now() / 1000) : { state: job.status, title: job.label || 'Background' };
    $q('.harness-view-title').textContent = v.title || 'Background';
    const waiting = !!st.pending || !!(H && H.waitingOn(job));
    const pill = $q('.harness-view-pill');
    pill.textContent = waiting ? 'Needs approval' : (STATUS[v.state] || v.state || '');
    pill.className = 'harness-view-pill is-' + (waiting ? 'waiting' : esc(v.state));
    $q('.harness-view-sub').textContent = v.state === 'running'
      ? [v.model, v.detail, v.clock].filter(Boolean).join(' · ')
      : [v.model, v.line].filter(Boolean).join(' · ');
    const stop = $q('.harness-view-stop');
    stop.hidden = v.state !== 'running';
    stop.disabled = !!job.stopping;
    stop.textContent = job.stopping ? 'Stopping…' : 'Stop';
  }

  // A live card for this job (harness_job events): header in step; the
  // approval it waits on shows here too, and goes when the server says so.
  function _onCard(sid, card) {
    if (!st || sid !== st.sid || !card || card.id !== st.id) return;
    const was = st.job.status;
    st.job = Object.assign({}, st.job, card);
    const ap = card.approval && card.approval.approval_id ? card.approval : null;
    if (ap && !st.pending && !(J() && J().isAnswered(ap.approval_id))) _showApproval(ap, 'card');
    else if (!ap && st.pending && st.pending.approval_id === st.cardApproval) _clearApproval();
    st.cardApproval = ap ? ap.approval_id : null;
    _header();
    if (was === 'running' && card.status !== 'running' && !st.es) _load(st.gen);
  }

  function _showApproval(p, from) {
    if (!st) return;
    const aid = p.approval_id || '';
    if (aid && J() && J().isAnswered(aid)) return;
    if (st.pending && st.pending.approval_id === aid) return;
    const job = st.job;
    const cardAp = job.approval && job.approval.approval_id === aid ? job.approval : null;
    const sessionId = (from === 'card' ? p.session_id : '') || (cardAp && cardAp.session_id) || job.worker_session || p.session_id || '';
    st.pending = { approval_id: aid, from };
    const slot = $q('.harness-view-approval');
    slot.innerHTML = '';
    const card = typeof buildApprovalCardCopy === 'function' ? buildApprovalCardCopy(p, {
      canAlways: canAlways(p),
      onChoice: async choice => {
        if (!sessionId || !aid) throw new Error('nothing to answer');
        if (J()) await J().respond({ session_id: sessionId, approval_id: aid }, choice, st && st.id);
        if (st && st.pending && st.pending.approval_id === aid) _clearApproval();
      },
    }) : null;
    if (card) slot.appendChild(card);
    _header();
    _render();
    const body = $q('.harness-view-body');
    body.scrollTop = body.scrollHeight;
  }

  function _clearApproval() {
    if (!st || !st.pending) return;
    st.pending = null;
    $q('.harness-view-approval').innerHTML = '';
    _header();
    _schedule();
  }

  return { createFeed, feedEvent, canAlways, open, close,
           isOpen: () => !!st, current: () => (st ? { sid: st.sid, id: st.id } : null) };
});

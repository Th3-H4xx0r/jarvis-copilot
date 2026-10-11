// The background-job card under a reply (agent harnesses): a Background node
// working in the background shows its label, model, live step and a running
// clock with a Stop button, then collapses to one line when it ends. Cards come
// stored on the reply (`_meta.jobs`), live changes arrive as `harness_job`
// session events (sessions.js → HarnessJobs.apply) and a chat that opens with a
// running card asks GET api/harnesses/jobs/<session> where things stand.
// Card: {id, node, label, model, status: running|done|failed|stopped, started_at,
//        completed_at, steps, activity}; "lost" = stored running, server lost it.
// UMD: window.HarnessJobs in the page, require() under `node --test`.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory(require('./harness_format.js'));
  else root.HarnessJobs = factory(root.HarnessFormat);
})(typeof self !== 'undefined' ? self : this, function (HarnessFormat) {
  const pad = n => String(n).padStart(2, '0');
  const ENDED = new Set(['done', 'failed', 'stopped', 'lost']);

  // Running clock: "0:42", "4:12", "1:05:09".
  function clock(seconds) {
    const s = Math.max(0, Math.floor(Number(seconds) || 0));
    const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = s % 60;
    return h ? `${h}:${pad(m)}:${pad(r)}` : `${m}:${pad(r)}`;
  }

  // Elapsed in words: "42 s", "4m 12s", "1h 05m".
  function duration(seconds) {
    const s = Math.max(0, Math.round(Number(seconds) || 0));
    if (s < 60) return `${s} s`;
    if (s < 3600) return `${Math.floor(s / 60)}m ${pad(s % 60)}s`;
    return `${Math.floor(s / 3600)}h ${pad(Math.floor((s % 3600) / 60))}m`;
  }

  function shortModel(ref) {
    return HarnessFormat && HarnessFormat.shortModel ? HarnessFormat.shortModel(ref) : String(ref || '');
  }

  // The state a stored card is really in. An ended card is final (a live
  // "running" left over from a missed event never beats it); otherwise the
  // server's newest word wins — a live event, or catch-up, which answers for
  // every card of the chat ("lost" = cut short by a server restart).
  function resolve(card, live) {
    if (ENDED.has(card.status)) return card;
    return (live && live[card.id]) || card;
  }

  function view(card, now) {
    const label = String(card.label || 'Background');
    const ran = (Number(card.completed_at) || now) - (Number(card.started_at) || now);
    const steps = Number(card.steps) || 0;
    const v = { state: card.status || 'running', title: label, model: shortModel(card.model) };
    if (v.state === 'running') {
      v.detail = (card.activity || 'Starting') + (steps ? ` · step ${steps}` : '');
      v.clock = clock(now - (Number(card.started_at) || now));
      return v;
    }
    if (v.state === 'done') {
      v.line = `${label} · finished in ${duration(ran)}` + (steps ? ` · ${steps} step${steps === 1 ? '' : 's'}` : '');
    } else if (v.state === 'failed') {
      v.line = `${label} · couldn't finish (after ${duration(ran)})`;
    } else if (v.state === 'stopped') {
      v.line = `${label} · stopped after ${duration(ran)}`;
    } else {
      v.line = `${label} · stopped when the server restarted`;
    }
    return v;
  }

  // Keep the newest word on a job: a running update that arrives after the job
  // ended (events can cross) never brings the card back.
  function merge(live, card) {
    const was = live[card.id];
    if (was && ENDED.has(was.status) && !ENDED.has(card.status)) return was;
    live[card.id] = card;
    return card;
  }

  const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g,
    c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const ICON = { done: '✓', failed: '✕', stopped: '■', lost: '!' };

  function cardHtml(card, now) {
    const v = view(card, now);
    const id = esc(card.id);
    if (v.state !== 'running') {
      return `<div class="harness-job harness-job-${esc(v.state)}" data-job-id="${id}">` +
        `<span class="harness-job-icon" aria-hidden="true">${ICON[v.state] || '•'}</span>` +
        `<span class="harness-job-line">${esc(v.line)}</span></div>`;
    }
    return `<div class="harness-job harness-job-running" data-job-id="${id}" data-started="${esc(card.started_at)}">` +
      `<span class="harness-job-dot" aria-hidden="true"></span>` +
      `<div class="harness-job-main"><div class="harness-job-title"><b>${esc(v.title)}</b>` +
      (v.model ? ` <span class="harness-job-model">${esc(v.model)}</span>` : '') + `</div>` +
      `<div class="harness-job-detail">${esc(v.detail)}</div></div>` +
      `<span class="harness-job-clock">${esc(v.clock)}</span>` +
      (card.stopping
        ? `<button type="button" class="harness-job-stop" disabled>Stopping…</button>`
        : `<button type="button" class="harness-job-stop" data-job-stop="${id}" title="Stop this background job">Stop</button>`) +
      `</div>`;
  }

  // ── in the page ──────────────────────────────────────────────────────────
  const live = {};          // job id → latest card from the server
  const asking = new Set();
  const retryAt = {};       // chat → when a failed catch-up may ask again
  let ticker = null;
  const nowSec = () => Date.now() / 1000;

  function _sid() { return (typeof S !== 'undefined' && S.session && S.session.session_id) || ''; }

  // Draw the cards of one reply at the end of its turn row (idempotent).
  function renderInto(row, jobs, sid) {
    if (!row || !Array.isArray(jobs) || !jobs.length) return;
    let box = row.querySelector(':scope > .harness-jobs');
    if (!box) {
      box = document.createElement('div');
      box.className = 'harness-jobs';
      row.appendChild(box);
    }
    const now = nowSec();
    let needCatchUp = false;
    box.innerHTML = jobs.filter(j => j && j.id).map(j => {
      const card = resolve(j, live);
      if (card.status === 'running' && !live[j.id]) needCatchUp = true;  // nothing newer heard yet
      return cardHtml(card, now);
    }).join('');
    if (needCatchUp) catchUp(sid);
    _ensureTicker();
  }

  // Redraw every card on the page from the stored copies + what was heard
  // since (a chat restored from the rendered-HTML cache shows old clocks).
  function refresh() {
    const sid = _sid();
    document.querySelectorAll('.harness-jobs').forEach(box => {
      const ids = [...box.querySelectorAll('.harness-job')].map(el => el.dataset.jobId);
      const stored = _storedCards(ids);
      if (box.parentElement && stored.length) renderInto(box.parentElement, stored, sid);
    });
  }

  // A live card from the server: remember it, redraw it where it is shown and
  // keep the stored copy on the message in step (a re-render shows the same).
  function apply(sid, card) {
    if (!card || !card.id) return;
    card = merge(live, card);
    if (sid !== _sid()) return;
    const msgs = (typeof S !== 'undefined' && Array.isArray(S.messages)) ? S.messages : [];
    for (const m of msgs) {
      const jobs = m && m._meta && m._meta.jobs;
      if (!Array.isArray(jobs)) continue;
      const i = jobs.findIndex(j => j && j.id === card.id);
      if (i >= 0) jobs[i] = Object.assign({}, card);
    }
    try { if (typeof _sessionHtmlCache !== 'undefined') _sessionHtmlCache.delete(sid); } catch (e) { /* not on this page */ }
    document.querySelectorAll(`.harness-job[data-job-id="${CSS.escape(card.id)}"]`).forEach(el => {
      el.outerHTML = cardHtml(card, nowSec());
    });
    _ensureTicker();
  }

  // Ask the server where every card of a chat stands (a chat opened mid-job,
  // events missed while away or across a reconnect). Its answer covers every
  // stored card, so nothing is left guessing.
  async function catchUp(sid) {
    if (!sid || asking.has(sid) || typeof api !== 'function' || Date.now() < (retryAt[sid] || 0)) return;
    asking.add(sid);
    try {
      const data = await api(`api/harnesses/jobs/${encodeURIComponent(sid)}`);
      (data && data.jobs || []).forEach(c => merge(live, c));
      if (sid === _sid()) refresh();
    } catch (e) {
      // Every re-render would ask again; wait a while instead.
      retryAt[sid] = Date.now() + 30000;
      console.warn('[harness jobs] catch-up failed', e);
    } finally {
      asking.delete(sid);
    }
  }

  function _storedCards(ids) {
    const want = new Set(ids), out = [];
    const msgs = (typeof S !== 'undefined' && Array.isArray(S.messages)) ? S.messages : [];
    for (const m of msgs) {
      for (const j of ((m && m._meta && m._meta.jobs) || [])) if (j && want.has(j.id)) out.push(j);
    }
    return out;
  }

  async function stop(sid, id, btn) {
    if (btn) { btn.disabled = true; btn.textContent = 'Stopping…'; }
    try {
      await api(`api/harnesses/jobs/${encodeURIComponent(sid)}/${encodeURIComponent(id)}/stop`,
        { method: 'POST', body: '{}' });
    } catch (e) {
      if (btn) { btn.disabled = false; btn.textContent = 'Stop'; }
      if (typeof showToast === 'function') showToast(e.message || 'Could not stop the job');
    }
  }

  function _tick() {
    const els = document.querySelectorAll('.harness-job-running');
    if (!els.length) { clearInterval(ticker); ticker = null; return; }
    const now = nowSec();
    els.forEach(el => {
      const c = el.querySelector('.harness-job-clock');
      if (c) c.textContent = clock(now - (Number(el.dataset.started) || now));
    });
  }

  function _ensureTicker() {
    if (!ticker && document.querySelector('.harness-job-running')) ticker = setInterval(_tick, 1000);
  }

  if (typeof document !== 'undefined') {
    document.addEventListener('click', ev => {
      const btn = ev.target && ev.target.closest && ev.target.closest('[data-job-stop]');
      if (btn) stop(_sid(), btn.dataset.jobStop, btn);
    });
  }

  return { clock, duration, resolve, view, merge, cardHtml, renderInto, refresh, apply, catchUp, stop };
});

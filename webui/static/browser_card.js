// ── The live browser card (Contract A) ──────────────────────────────────────
// Every browser_* tool result starts {"card": {"kind": "browser_session",
// "session": "<id>"}, ...}. One card per session id, drawn under the first tool
// call of that session in the chat (outside the collapsed activity group), fed by
// GET /api/browser/sessions/<id> every 1.5 s while it is live:
//   * engine pill — Lightpanda / Server Chrome / Cloud · Steel — page title + host;
//   * a cloud session's live view inline, read-only (Take over makes it
//     interactive and pauses Jarvis; Hand back to Jarvis resumes);
//   * Run on cloud browser on Lightpanda / Chrome sessions (disabled with the
//     hint when no cloud browser is set up);
//   * the replay once the session has ended.
(function (root) {
  'use strict';

  const POLL_MS = 1500;
  const CONTINUE_TEXT = 'Continue that on the cloud browser.';
  const cards = new Map();      // session id → {el, data, timer, misses, sending}
  const owners = new Map();     // session id → {tid, row}
  let pass = 0, passScheduled = false;

  // Rows built in the same synchronous render pass are "live" even before they
  // are inserted into the document.
  function currentPass() {
    if (!passScheduled) {
      passScheduled = true;
      Promise.resolve().then(() => { passScheduled = false; pass += 1; });
    }
    return pass;
  }

  function sessionIn(tc) {
    const m = /"kind"\s*:\s*"browser_session"\s*,\s*"session"\s*:\s*"(b_[0-9a-f]{6,32})"/.exec((tc && tc.snippet) || '');
    return m ? m[1] : '';
  }

  function escHtml(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, c => (
      { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }

  function host(url) {
    try { return new URL(url).host.replace(/^www\./, ''); } catch (e) { return ''; }
  }

  function rel(path) { return String(path || '').replace(/^\//, ''); }

  function enginePill(d) {
    if (d.engine === 'cloud') return 'Cloud · ' + (d.provider_name || 'browser');
    if (d.engine === 'chrome') return 'Server Chrome';
    return 'Lightpanda';
  }

  function tagText(d) {
    if (d.takeover) return 'You have control';
    if (d.status === 'running') return 'Live';
    return 'Ended';
  }

  function apiCall(path, opts) {
    if (typeof api === 'function') return api(path, opts);
    return fetch(rel(path), Object.assign({ credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' } }, opts || {})).then(r => {
      if (!r.ok) return r.json().catch(() => ({})).then(b => { throw new Error(b.error || ('HTTP ' + r.status)); });
      return r.json();
    });
  }

  // ── drawing ────────────────────────────────────────────────────────────────

  function skeleton(id) {
    const el = document.createElement('div');
    el.className = 'plan-card browser-card';
    el.dataset.browserSession = id;
    el.innerHTML = `
      <div class="plan-card-head">
        <span class="browser-card-pill" data-bc="pill">Browser</span>
        <span class="plan-card-title" data-bc="title">Loading…</span>
        <span class="browser-card-host" data-bc="host"></span>
        <span class="plan-card-tag" data-bc="tag"></span>
      </div>
      <div class="browser-card-view" data-bc="view" hidden></div>
      <div class="plan-card-foot">
        <span class="plan-card-note" data-bc="note"></span>
        <span class="browser-card-actions" data-bc="actions"></span>
      </div>`;
    return el;
  }

  function q(el, name) { return el.querySelector(`[data-bc="${name}"]`); }

  function setView(card, d) {
    const view = q(card.el, 'view');
    const liveSrc = d.status === 'running' && d.engine === 'cloud'
      ? (d.takeover ? (d.live_interactive_url || d.live_url) : d.live_url) : null;
    if (liveSrc) {
      let frame = view.querySelector('iframe');
      if (!frame) {
        view.innerHTML = '';
        frame = document.createElement('iframe');
        frame.className = 'browser-card-frame';
        frame.setAttribute('sandbox', 'allow-scripts allow-same-origin allow-forms');
        frame.setAttribute('allow', 'clipboard-read; clipboard-write');
        frame.setAttribute('referrerpolicy', 'no-referrer');
        frame.title = 'Live view of the cloud browser';
        view.appendChild(frame);
      }
      if (frame.getAttribute('src') !== liveSrc) frame.setAttribute('src', liveSrc);
      frame.classList.toggle('is-interactive', !!d.takeover);
      frame.tabIndex = d.takeover ? 0 : -1;
      view.hidden = false;
      return;
    }
    if (d.replay_url && d.replay_status === 'ready') {
      let video = view.querySelector('video');
      const src = rel(d.replay_url);
      if (!video) {
        view.innerHTML = '';
        video = document.createElement('video');
        video.className = 'browser-card-video';
        video.controls = true;
        video.preload = 'metadata';
        video.playsInline = true;
        view.appendChild(video);
      }
      if (video.getAttribute('src') !== src) video.setAttribute('src', src);
      view.hidden = false;
      return;
    }
    view.innerHTML = '';
    view.hidden = true;
  }

  function noteFor(d) {
    if (d.status === 'running') {
      if (d.takeover) return 'Jarvis is paused while you use the browser.';
      if (d.engine === 'cloud') return d.live_url ? '' : 'This cloud browser has no live view.';
      if (d.move_requested) return 'Moving to the cloud browser on Jarvis’s next step.';
      return d.engine === 'lightpanda' ? 'Fast reader with no picture to show.' : 'Running on the server’s Chrome.';
    }
    if (d.replay_status === 'recording' || d.replay_status === 'encoding') return 'Preparing the replay…';
    if (d.replay_status === 'failed') return 'No replay' + (d.replay_error ? ` (${d.replay_error})` : '') + '.';
    return '';
  }

  function paint(card) {
    const d = card.data;
    if (!d) return;
    const el = card.el;
    el.classList.toggle('browser-card--ended', d.status !== 'running');
    q(el, 'pill').textContent = enginePill(d);
    q(el, 'title').textContent = d.title || host(d.url) || 'Browser';
    q(el, 'host').textContent = d.title ? host(d.url) : '';
    q(el, 'tag').textContent = tagText(d);
    setView(card, d);
    const note = q(el, 'note');
    note.textContent = card.error || noteFor(d);
    note.classList.toggle('plan-card-note--error', !!card.error);

    const actions = q(el, 'actions');
    const buttons = [];
    if (d.status === 'running' && d.engine === 'cloud' && d.live_interactive_url) {
      buttons.push(d.takeover
        ? `<button class="intg-btn intg-btn--primary" data-bc-act="handback">Hand back to Jarvis</button>`
        : `<button class="intg-btn" data-bc-act="takeover">Take over</button>`);
    }
    if (d.status === 'running' && d.engine === 'cloud' && d.live_url) {
      buttons.push(`<button class="intg-btn" data-bc-act="full">Full screen</button>`);
    }
    if (d.can_move_to_cloud && !d.move_requested) {
      const off = !d.cloud_ready;
      buttons.push(`<button class="intg-btn" data-bc-act="move"${off ? ' disabled' : ''}
        title="${escHtml(off ? (d.cloud_hint || '') : 'Run this task in the cloud browser so you can watch it')}">Run on cloud browser</button>`);
      if (off && d.cloud_hint && !card.error) note.textContent = d.cloud_hint;
    }
    const html = buttons.join('');
    if (actions.dataset.html !== html) {
      actions.dataset.html = html;
      actions.innerHTML = html;
      actions.querySelectorAll('[data-bc-act]').forEach(btn => {
        btn.onclick = ev => { ev.stopPropagation(); act(card, btn.dataset.bcAct, btn); };
      });
    }
  }

  // ── actions ────────────────────────────────────────────────────────────────

  async function act(card, what, btn) {
    const id = card.el.dataset.browserSession;
    card.error = '';
    if (what === 'full') {
      const view = q(card.el, 'view');
      if (view.requestFullscreen) view.requestFullscreen().catch(() => {});
      return;
    }
    if (btn) btn.disabled = true;
    try {
      if (what === 'takeover' || what === 'handback') {
        const res = await apiCall(`/api/browser/sessions/${id}/takeover`,
          { method: 'POST', body: JSON.stringify({ active: what === 'takeover' }) });
        card.data = Object.assign({}, card.data, { takeover: !!res.takeover });
      } else if (what === 'move') {
        const res = await apiCall(`/api/browser/sessions/${id}/move`,
          { method: 'POST', body: JSON.stringify({ to: 'cloud' }) });
        card.data = Object.assign({}, card.data, { move_requested: !!res.move_requested });
        if (res.move_requested && !res.turn_running) sendContinue();
      }
    } catch (e) {
      card.error = (e && e.message) || 'That did not work.';
    }
    paint(card);
    schedule(card, 200);
  }

  function sendContinue() {
    const box = typeof $ === 'function' ? $('msg') : document.getElementById('msg');
    if (!box || typeof send !== 'function') return;
    box.value = CONTINUE_TEXT;
    if (typeof autoResize === 'function') autoResize();
    send();
  }

  // ── polling ────────────────────────────────────────────────────────────────

  function wantsPolling(d) {
    if (!d) return true;
    if (d.status === 'running') return true;
    return d.replay_status === 'recording' || d.replay_status === 'encoding' || d.move_requested;
  }

  function schedule(card, ms) {
    clearTimeout(card.timer);
    card.timer = setTimeout(() => refresh(card), ms == null ? POLL_MS : ms);
  }

  async function refresh(card) {
    const id = card.el.dataset.browserSession;
    if (!card.el.isConnected) {
      card.misses = (card.misses || 0) + 1;
      if (card.misses > 2) { card.timer = null; return; }   // re-armed when drawn again
      schedule(card);
      return;
    }
    card.misses = 0;
    try {
      card.data = await apiCall(`/api/browser/sessions/${id}`);
      paint(card);
    } catch (e) {
      if (!card.data) { q(card.el, 'title').textContent = 'Browser'; q(card.el, 'note').textContent = (e && e.message) || ''; }
    }
    if (wantsPolling(card.data)) schedule(card);
    else card.timer = null;
  }

  function cardFor(id) {
    let card = cards.get(id);
    if (!card) {
      card = { el: skeleton(id), data: null, timer: null, misses: 0, error: '' };
      cards.set(id, card);
    }
    if (!card.timer && wantsPolling(card.data)) schedule(card, card.data ? POLL_MS : 0);
    return card.el;
  }

  // The tool card row for a browser tool call: the card (under the call that
  // first showed its session) plus the plain tool card, or null for a plain row.
  function toolRow(tc, plainCard) {
    const id = sessionIn(tc);
    if (!id) return null;
    const tid = (tc && (tc.tid || tc.callID)) || '';
    const owner = owners.get(id);
    const ownerLive = owner && owner.row && (owner.row.isConnected || owner.row._bcPass === pass);
    if (ownerLive && !(tid && owner.tid === tid)) return null;
    const row = document.createElement('div');
    row.className = 'tool-card-row plan-card-row browser-card-row';
    row._bcPass = currentPass();
    if (plainCard) row.appendChild(plainCard);
    row.appendChild(cardFor(id));
    owners.set(id, { tid, row });
    return row;
  }

  root.BrowserCard = { toolRow, cardFor, sessionIn, _cards: cards };
  if (typeof module !== 'undefined' && module.exports) module.exports = root.BrowserCard;
})(typeof window !== 'undefined' ? window : globalThis);

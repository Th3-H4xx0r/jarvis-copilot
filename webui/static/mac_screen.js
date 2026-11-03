'use strict';
// Mac screen sharing in the web UI (Contract B, webui/api/screen_share.py).
//
//  * mac_screen card: a computer task (computer_do) runs on a Mac screen share.
//    Its tool card carries the share (the result names "scr_…"; while the task
//    still runs, the chat's active task share). The card plays the Mac live
//    (WebRTC, inline), and the replay once the share has ended.
//  * full screen: tap the video → the Mac fills the window; mouse, wheel and
//    keys go to the Mac over the "input" data channel (coordinates normalised to
//    the shared display).
//  * Share Mac screen: an "anytime" share from the MacBook card (agents.js).
//
// This page is the offerer (recvonly video + data channel "input"); the Mac
// answers. Signals go through the server's long poll; the page sends its own
// `viewer` id, so a phone and this page can watch the same share at once.
(function (root) {
  const SHARE_RE = /\bscr_[0-9a-f]{16}\b/;

  function apiCall(path, opts) {
    if (typeof root.api === 'function') return root.api(path, opts || {});
    return fetch(path.replace(/^\//, ''), Object.assign({ credentials: 'include',
      headers: { 'Content-Type': 'application/json' } }, opts || {})).then(r => r.json());
  }
  const getJSON = (p) => apiCall(p);
  const postJSON = (p, body) => apiCall(p, { method: 'POST', body: JSON.stringify(body || {}) });
  const sleep = (ms) => new Promise(r => setTimeout(r, ms));
  const escHtml = (s) => String(s == null ? '' : s).replace(/[&<>"']/g,
    c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  // ── one WebRTC connection per share on this page ─────────────────────────
  class Viewer {
    constructor(shareId) {
      this.id = shareId;
      this.viewer = 'web-' + Math.random().toString(36).slice(2, 10);
      this.after = 0;
      this.closed = false;
      this.stream = null;
      this.state = 'connecting';
      this.listeners = new Set();
      this.dc = null;
      this.pc = null;
    }
    on(fn) { this.listeners.add(fn); return () => this.listeners.delete(fn); }
    emit() { for (const fn of this.listeners) { try { fn(this); } catch (_) { /* a card went away */ } } }
    setState(s) { if (this.state !== s) { this.state = s; this.emit(); } }

    async start() {
      let ice = [];
      try { ice = (await getJSON('/api/screen/ice')).ice_servers || []; } catch (_) { /* STUN-less still works on a LAN */ }
      if (this.closed) return;
      const pc = new RTCPeerConnection({ iceServers: ice });
      this.pc = pc;
      pc.addTransceiver('video', { direction: 'recvonly' });
      this.dc = pc.createDataChannel('input', { ordered: true });
      this.dc.onmessage = (e) => {
        try {
          const m = JSON.parse(e.data);
          if (m && m.t === 'error') { this.error = m.error; this.emit(); }
        } catch (_) { /* not ours */ }
      };
      pc.ontrack = (e) => {
        this.stream = (e.streams && e.streams[0]) || new MediaStream([e.track]);
        this.emit();
      };
      pc.onicecandidate = (e) => {
        if (!e.candidate || this.closed) return;
        const c = e.candidate;
        this.signal({ type: 'candidate', candidate: { candidate: c.candidate, sdpMid: c.sdpMid,
          sdpMLineIndex: c.sdpMLineIndex } });
      };
      pc.onconnectionstatechange = () => {
        const s = pc.connectionState;
        if (s === 'connected') this.setState('live');
        else if (s === 'failed') this.setState('failed');
        else if (s === 'disconnected') this.setState('connecting');
      };
      const offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      await this.signal({ type: 'offer', sdp: offer.sdp });
      this.poll();
    }

    signal(msg) {
      return postJSON(`/api/screen/shares/${this.id}/signal`,
        Object.assign({ from: 'viewer', viewer: this.viewer }, msg)).catch(() => null);
    }

    async poll() {
      let failures = 0;
      while (!this.closed) {
        let r;
        try {
          r = await getJSON(`/api/screen/shares/${this.id}/signal?for=viewer&after=${this.after}` +
                            `&viewer=${encodeURIComponent(this.viewer)}&wait=25`);
          failures = 0;
        } catch (e) {
          if (e && (e.status === 404 || e.status === 410)) { this.end(); return; }
          failures += 1;
          await sleep(Math.min(5000, 800 * failures));
          continue;
        }
        for (const m of (r && r.messages) || []) {
          this.after = Math.max(this.after, m.seq || 0);
          try { await this.handle(m); } catch (err) { console.warn('mac screen signal', err); }
        }
        if (r && r.status === 'ended') { this.end(); return; }
      }
    }

    async handle(m) {
      if (!this.pc || this.closed) return;
      if (m.type === 'answer' && m.sdp) {
        if (this.pc.signalingState === 'have-local-offer') {
          await this.pc.setRemoteDescription({ type: 'answer', sdp: m.sdp });
        }
      } else if (m.type === 'candidate' && m.candidate && m.candidate.candidate) {
        await this.pc.addIceCandidate(m.candidate);
      } else if (m.type === 'bye') {
        this.end();
      }
    }

    send(obj) {
      if (this.dc && this.dc.readyState === 'open') this.dc.send(JSON.stringify(obj));
    }

    end() {
      if (this.closed) return;
      this.closed = true;
      try { if (this.pc) this.pc.close(); } catch (_) { /* already closed */ }
      this.setState('ended');
      viewers.delete(this.id);
    }

    leave() {  // this page stops watching; the share itself goes on
      if (this.closed) return;
      this.signal({ type: 'bye' });
      this.end();
    }
  }

  const viewers = new Map();
  function viewerFor(id) {
    let v = viewers.get(id);
    if (!v || v.closed) {
      v = new Viewer(id);
      viewers.set(id, v);
      v.start().catch((e) => { v.error = String((e && e.message) || e); v.setState('failed'); });
    }
    return v;
  }

  // ── styles (kept with the feature) ───────────────────────────────────────
  function ensureStyles() {
    if (document.getElementById('macScreenStyles')) return;
    const s = document.createElement('style');
    s.id = 'macScreenStyles';
    s.textContent = `
.mac-screen-card{margin-top:8px;border:1px solid var(--border);border-radius:14px;background:var(--surface);overflow:hidden;max-width:min(560px,100%);}
.mac-screen-head{display:flex;align-items:center;gap:8px;padding:8px 12px;font-size:.8rem;color:var(--muted);}
.mac-screen-head b{color:var(--text);font-weight:600;}
.mac-screen-pill{font-size:.7rem;font-weight:600;padding:2px 8px;border-radius:999px;background:var(--accent-bg);color:var(--accent-text);}
.mac-screen-pill.is-live{background:var(--accent-bg-strong);}
.mac-screen-pill.is-off{background:var(--hover-bg);color:var(--muted);}
.mac-screen-head .mac-screen-gap{flex:1;}
.mac-screen-btn{font:inherit;font-size:.74rem;font-weight:600;padding:4px 10px;border-radius:999px;border:1px solid var(--accent-bg-strong);background:var(--accent-bg);color:var(--accent-text);cursor:pointer;}
.mac-screen-btn.is-stop{border-color:color-mix(in srgb,var(--error) 40%,transparent);background:color-mix(in srgb,var(--error) 14%,transparent);color:var(--error);}
.mac-screen-stage{position:relative;aspect-ratio:16/10;background:#000;cursor:zoom-in;}
.mac-screen-stage video{width:100%;height:100%;object-fit:contain;display:block;background:#000;}
.mac-screen-note{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;text-align:center;padding:16px;color:#c9c9c9;font-size:.82rem;pointer-events:none;}
.mac-screen-stage.is-replay{cursor:default;}
.mac-screen-overlay{position:fixed;inset:0;z-index:10050;background:#000;display:flex;flex-direction:column;}
.mac-screen-bar{display:flex;align-items:center;gap:10px;padding:8px 14px;background:rgba(20,20,20,.92);color:#eee;font-size:.82rem;}
.mac-screen-bar .mac-screen-gap{flex:1;}
.mac-screen-bar small{color:#9a9a9a;}
.mac-screen-full{flex:1;position:relative;outline:none;cursor:default;}
.mac-screen-full video{position:absolute;inset:0;width:100%;height:100%;object-fit:contain;}
`;
    document.head.appendChild(s);
  }

  // ── cards ────────────────────────────────────────────────────────────────
  const cards = new Map();      // share id → card element (kept across tool-card rebuilds)
  const shareByTid = new Map(); // live tool call → share id
  const waiting = new Map();    // live tool call → placeholder card while its share is looked up

  function statusText(share, v) {
    if (!share) return ['Connecting', ''];
    if (share.status === 'ended') return ['Ended', 'is-off'];
    if (v && v.state === 'live') return ['Live', 'is-live'];
    if (!share.mac_online) return ['Mac offline', 'is-off'];
    return [share.status === 'live' ? 'Connecting' : 'Waiting for the Mac', ''];
  }

  function makeCard(shareId, el) {
    ensureStyles();
    const card = el || document.createElement('div');
    card.className = 'mac-screen-card';
    card.dataset.share = shareId;
    card.innerHTML = '<div class="mac-screen-head"><b>Mac screen</b><span class="mac-screen-pill"></span>' +
      '<span class="mac-screen-gap"></span></div><div class="mac-screen-stage"><video muted playsinline autoplay></video>' +
      '<div class="mac-screen-note"></div></div>';
    cards.set(shareId, card);
    const st = { share: null, viewer: null, replayShown: false, endedAt: 0 };
    card._mac = st;
    const stage = card.querySelector('.mac-screen-stage');
    stage.addEventListener('click', () => {
      if (st.share && st.share.status !== 'ended') openFull(shareId, st.share);
    });
    refreshCard(shareId, card);
    return card;
  }

  function draw(card) {
    const st = card._mac;
    const share = st.share;
    const v = st.viewer;
    const [label, cls] = statusText(share, v);
    const pill = card.querySelector('.mac-screen-pill');
    pill.textContent = label;
    pill.className = 'mac-screen-pill ' + cls;
    const note = card.querySelector('.mac-screen-note');
    const video = card.querySelector('video');
    const stage = card.querySelector('.mac-screen-stage');
    if (share && share.status === 'ended') {
      if (share.replay_url && !st.replayShown) {
        st.replayShown = true;
        stage.classList.add('is-replay');
        video.srcObject = null;
        video.muted = true;
        video.controls = true;
        video.autoplay = false;
        video.preload = 'metadata';
        video.src = share.replay_url.replace(/^\//, '');
      }
      note.textContent = share.replay_url ? '' :
        (Date.now() - st.endedAt < 120000 ? 'The Mac is uploading the replay…' : (share.error || 'No replay for this one.'));
      return;
    }
    if (v && v.stream && video.srcObject !== v.stream) video.srcObject = v.stream;
    note.textContent = v && v.state === 'live' ? '' :
      (v && v.error) ? v.error :
      share && !share.mac_online ? 'Open the Jarvis app on your Mac to watch.' : 'Connecting to your Mac…';
  }

  async function refreshCard(shareId, card) {
    const st = card._mac;
    while (true) {
      if (!card.isConnected && st.seen) {  // left the page (a re-render keeps the element)
        await sleep(4000);
        if (!card.isConnected) { if (st.viewer) st.viewer.leave(); cards.delete(shareId); return; }
      }
      if (card.isConnected) st.seen = true;
      try {
        st.share = await getJSON(`/api/screen/shares/${shareId}`);
      } catch (e) {
        if (e && e.status === 404) { card.querySelector('.mac-screen-note').textContent = 'This share is gone.'; return; }
      }
      const share = st.share;
      if (share && share.status === 'ended') {
        if (!st.endedAt) st.endedAt = Date.now();
        if (st.viewer) { st.viewer.end(); st.viewer = null; }
        draw(card);
        if (share.replay_url || Date.now() - st.endedAt > 120000) return;
        await sleep(5000);
        continue;
      }
      if (share && !st.viewer && card.isConnected) {
        st.viewer = viewerFor(shareId);
        st.viewer.on(() => draw(card));
      }
      draw(card);
      await sleep(card.isConnected ? 3000 : 400);
    }
  }

  function cardFor(shareId) {
    return cards.get(shareId) || makeCard(shareId);
  }

  function shareIn(tc) {
    const m = SHARE_RE.exec(String((tc && tc.snippet) || ''));
    return m ? m[0] : null;
  }

  // While the task runs, its share is this chat's newest active task share.
  async function findLiveShare(tid, holder) {
    // ui.js's `S` is a script-level const, not a window property.
    // eslint-disable-next-line no-undef
    const sid = (typeof S !== 'undefined' && S && S.session && S.session.session_id) || '';
    const since = Date.now();
    while (Date.now() - since < 45000 && !shareByTid.has(tid)) {
      try {
        const r = await getJSON('/api/screen/shares?active=1');
        const hit = ((r && r.shares) || []).find(s => s.reason === 'task' && (!sid || s.session_id === sid));
        if (hit) {
          shareByTid.set(tid, hit.id);
          if (!cards.has(hit.id)) makeCard(hit.id, holder);
          else holder.replaceWith(cards.get(hit.id));
          waiting.delete(tid);
          return;
        }
      } catch (_) { /* try again */ }
      await sleep(1500);
    }
    waiting.delete(tid);
    if (!shareByTid.has(tid)) holder.remove();
  }

  /** The computer_do tool row: the usual tool card plus the Mac screen. Null → plain card. */
  function toolRow(tc, plainCard) {
    const tid = (tc && tc.tid) || '';
    let shareId = shareIn(tc) || (tid && shareByTid.get(tid)) || null;
    let screen = null;
    if (shareId) {
      if (tid) shareByTid.set(tid, shareId);
      const pending = tid && waiting.get(tid);
      if (pending && !cards.has(shareId)) { screen = makeCard(shareId, pending); waiting.delete(tid); }
      else screen = cardFor(shareId);
    } else if (tc && tc.done === false && tid) {
      screen = waiting.get(tid);
      if (!screen) {
        ensureStyles();
        screen = document.createElement('div');
        screen.className = 'mac-screen-card';
        screen.innerHTML = '<div class="mac-screen-head"><b>Mac screen</b><span class="mac-screen-pill">Starting</span></div>';
        waiting.set(tid, screen);
        findLiveShare(tid, screen);
      }
    }
    if (!screen) return null;
    const row = document.createElement('div');
    row.className = 'tool-card-row plan-card-row mac-screen-row';
    if (plainCard) row.appendChild(plainCard);
    row.appendChild(screen);
    return row;
  }

  // ── full screen with control ─────────────────────────────────────────────
  let overlay = null;

  function contentRect(video) {
    const r = video.getBoundingClientRect();
    const vw = video.videoWidth || 16, vh = video.videoHeight || 10;
    const scale = Math.min(r.width / vw, r.height / vh);
    const w = vw * scale, h = vh * scale;
    return { left: r.left + (r.width - w) / 2, top: r.top + (r.height - h) / 2, width: w, height: h };
  }

  function mods(e) {
    const m = [];
    if (e.metaKey) m.push('cmd');
    if (e.shiftKey) m.push('shift');
    if (e.altKey) m.push('alt');
    if (e.ctrlKey) m.push('ctrl');
    return m;
  }

  function openFull(shareId, share, opts) {
    ensureStyles();
    closeFull();
    const v = viewerFor(shareId);
    const ownsShare = !!(opts && opts.owns);
    const el = document.createElement('div');
    el.className = 'mac-screen-overlay';
    el.innerHTML = '<div class="mac-screen-bar"><b>Your Mac</b><small class="mac-screen-state"></small>' +
      '<span class="mac-screen-gap"></span>' +
      '<button type="button" class="mac-screen-btn is-stop" data-act="stop">Stop sharing</button>' +
      '<button type="button" class="mac-screen-btn" data-act="close">' + (ownsShare ? 'Close' : 'Exit full screen') +
      '</button></div><div class="mac-screen-full" tabindex="0"><video muted playsinline autoplay></video>' +
      '<div class="mac-screen-note"></div></div>';
    document.body.appendChild(el);
    const video = el.querySelector('video');
    const surface = el.querySelector('.mac-screen-full');
    const note = el.querySelector('.mac-screen-note');
    const stateEl = el.querySelector('.mac-screen-state');
    const paint = () => {
      if (v.stream && video.srcObject !== v.stream) video.srcObject = v.stream;
      stateEl.textContent = v.state === 'live' ? 'Live · your mouse and keys go to the Mac' :
        v.state === 'ended' ? 'Ended' : 'Connecting…';
      note.textContent = v.state === 'live' ? (v.error || '') : v.state === 'ended' ? 'The share has ended.' :
        v.error || 'Connecting to your Mac…';
    };
    const off = v.on(paint);
    paint();

    let lastMove = 0;
    const at = (e) => {
      const r = contentRect(video);
      return { x: Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)),
               y: Math.min(1, Math.max(0, (e.clientY - r.top) / r.height)) };
    };
    const button = (e) => (e.button === 2 ? 'right' : 'left');
    surface.addEventListener('mousemove', (e) => {
      const now = performance.now();
      if (now - lastMove < 30) return;
      lastMove = now;
      v.send(Object.assign({ t: 'move' }, at(e)));
    });
    surface.addEventListener('mousedown', (e) => {
      e.preventDefault();
      surface.focus();
      v.send(Object.assign({ t: 'down', button: button(e) }, at(e)));
    });
    surface.addEventListener('mouseup', (e) => {
      e.preventDefault();
      v.send(Object.assign({ t: 'up', button: button(e) }, at(e)));
    });
    surface.addEventListener('contextmenu', (e) => e.preventDefault());
    surface.addEventListener('wheel', (e) => {
      e.preventDefault();
      const k = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? 400 : 1;
      v.send({ t: 'scroll', dx: Math.round(e.deltaX * k), dy: Math.round(e.deltaY * k) });
    }, { passive: false });
    surface.addEventListener('keydown', (e) => {
      if (e.isComposing) return;
      e.preventDefault();
      if (['Meta', 'Shift', 'Alt', 'Control', 'CapsLock'].includes(e.key)) return;
      v.send({ t: 'key', key: e.key, mods: mods(e) });
    });
    surface.addEventListener('paste', (e) => {
      const text = e.clipboardData && e.clipboardData.getData('text/plain');
      if (text) { e.preventDefault(); v.send({ t: 'text', text }); }
    });
    // Touch: a tap is a click, a drag moves the pointer.
    surface.addEventListener('touchend', (e) => {
      const t = e.changedTouches && e.changedTouches[0];
      if (!t) return;
      e.preventDefault();
      v.send(Object.assign({ t: 'click', button: 'left', count: 1 }, at(t)));
    }, { passive: false });

    const close = () => {
      off();
      el.remove();
      overlay = null;
      if (ownsShare) postJSON(`/api/screen/shares/${shareId}/stop`, {}).catch(() => null);
    };
    el.querySelector('[data-act="close"]').addEventListener('click', close);
    el.querySelector('[data-act="stop"]').addEventListener('click', () => {
      postJSON(`/api/screen/shares/${shareId}/stop`, {}).catch(() => null);
      v.leave();
      off();
      el.remove();
      overlay = null;
    });
    overlay = { el, close };
    setTimeout(() => surface.focus(), 50);
  }

  function closeFull() { if (overlay) overlay.close(); }

  /** "Share Mac screen": an anytime share, straight to full screen. */
  async function startAnytime() {
    let share;
    try {
      share = await postJSON('/api/screen/shares', { reason: 'anytime' });
    } catch (e) {
      if (typeof root.showToast === 'function') root.showToast('Couldn’t start sharing: ' + ((e && e.message) || e));
      return null;
    }
    if (!share || !share.id) return null;
    openFull(share.id, share, { owns: true });
    return share.id;
  }

  root.MacScreen = { toolRow, cardFor, openFull, startAnytime, shareIn, _viewers: viewers };
  if (typeof module !== 'undefined' && module.exports) module.exports = root.MacScreen;
})(typeof window !== 'undefined' ? window : globalThis);

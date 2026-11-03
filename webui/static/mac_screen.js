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
  // A Viewer outlives its peer connections: when ICE fails (or stays
  // disconnected) it says bye for the old one and offers again under a fresh
  // viewer id, backing off; cards and the full-screen view keep listening to
  // the same object. After a few failed tries its state is 'failed' (it keeps
  // retrying slowly). `share` is the last share record a card or the full
  // screen fetched (mac_online drives "Open Jarvis on your Mac").
  const DROP_GRACE_MS = 5000;     // 'disconnected' this long → start over
  const ICE_TIMEOUT_MS = 20000;   // answered but never connected → start over
  const FAILED_AFTER = 3;         // tries before the state says 'failed'

  function newViewerId() { return 'web-' + Math.random().toString(36).slice(2, 10); }

  /** Reconnect delay after `n` failed tries: 1 s, 2 s, 4 s … 30 s. */
  function backoff(n) { return Math.min(30000, 1000 * Math.pow(2, Math.max(0, n - 1))); }

  class Viewer {
    constructor(shareId) {
      this.id = shareId;
      this.viewer = newViewerId();
      this.after = 0;
      this.closed = false;
      this.stream = null;
      this.state = 'connecting';
      this.listeners = new Set();
      this.dc = null;
      this.pc = null;
      this.share = null;
      this.error = '';
      this.tries = 0;          // failed connection attempts in a row
      this.gen = 0;            // which peer connection is current
      this.pending = [];       // remote candidates waiting for the answer
      this.outbox = Promise.resolve();
      this.timers = [];
    }
    on(fn) { this.listeners.add(fn); return () => this.listeners.delete(fn); }
    emit() { for (const fn of this.listeners) { try { fn(this); } catch (_) { /* a card went away */ } } }
    setState(s) { if (this.state !== s) { this.state = s; this.emit(); } }
    setShare(share) { if (share) { this.share = share; this.emit(); } }
    later(fn, ms) { const t = setTimeout(fn, ms); this.timers.push(t); return t; }
    clearTimers() { for (const t of this.timers) clearTimeout(t); this.timers = []; }

    start() { return this.connect(); }

    async connect() {
      const gen = ++this.gen;
      this.clearTimers();
      this.viewer = newViewerId();
      this.pending = [];
      let ice = [];
      try { ice = (await getJSON('/api/screen/ice')).ice_servers || []; } catch (_) { /* STUN-less still works on a LAN */ }
      if (this.closed || gen !== this.gen) return;
      const pc = new RTCPeerConnection({ iceServers: ice });
      this.pc = pc;
      const current = () => !this.closed && gen === this.gen;
      pc.addTransceiver('video', { direction: 'recvonly' });
      this.dc = pc.createDataChannel('input', { ordered: true });
      this.dc.onmessage = (e) => {
        try {
          const m = JSON.parse(e.data);
          if (m && m.t === 'error') { this.error = m.error; this.emit(); }
        } catch (_) { /* not ours */ }
      };
      pc.ontrack = (e) => {
        if (!current()) return;
        this.stream = (e.streams && e.streams[0]) || new MediaStream([e.track]);
        this.emit();
      };
      pc.onicecandidate = (e) => {
        if (!e.candidate || !current()) return;
        const c = e.candidate;
        this.signal({ type: 'candidate', candidate: { candidate: c.candidate, sdpMid: c.sdpMid,
          sdpMLineIndex: c.sdpMLineIndex } });
      };
      let dropTimer = null;
      const watch = () => {
        if (!current()) return;
        const s = pc.connectionState || pc.iceConnectionState;
        if (s === 'connected' || s === 'completed') {
          clearTimeout(dropTimer);
          this.tries = 0;
          this.error = this.error && /couldn.t connect/i.test(this.error) ? '' : this.error;
          this.setState('live');
        } else if (s === 'failed') {
          this.retry('failed');
        } else if (s === 'disconnected') {
          if (this.state === 'live') this.setState('connecting');
          clearTimeout(dropTimer);
          dropTimer = this.later(() => {
            if (current() && ['disconnected', 'failed'].includes(pc.connectionState || pc.iceConnectionState)) {
              this.retry('disconnected');
            }
          }, DROP_GRACE_MS);
        }
      };
      pc.onconnectionstatechange = watch;
      // Some browsers report ICE failure before (or instead of) connectionState.
      pc.oniceconnectionstatechange = () => { if (current() && pc.iceConnectionState === 'failed') this.retry('ice'); };
      const offer = await pc.createOffer();
      if (!current()) return;
      await pc.setLocalDescription(offer);
      // Everything for this viewer id comes after the offer, so after the newest
      // seq seen so far; an older generation's loop stops once its poll returns.
      const from = this.after;
      await this.signal({ type: 'offer', sdp: offer.sdp });
      this.poll(gen, this.viewer, from);
    }

    /** This peer connection is dead: say bye for it and offer again after a pause. */
    retry(why) {
      if (this.closed) return;
      const old = this.pc, oldId = this.viewer;
      this.gen += 1;               // the old connection's callbacks go quiet
      this.clearTimers();
      this.pc = null;
      this.dc = null;
      try { if (old) old.close(); } catch (_) { /* already closed */ }
      this.signal({ type: 'bye' }, oldId);
      this.tries += 1;
      if (this.tries >= FAILED_AFTER) {
        this.error = 'Couldn’t connect to your Mac — retrying.';
        this.setState('failed');
      } else {
        this.setState('connecting');
      }
      const gen = this.gen;
      this.later(() => {
        if (this.closed || gen !== this.gen) return;
        this.connect().catch((e) => { this.error = String((e && e.message) || e); this.retry('error'); });
      }, backoff(this.tries));
      return why;
    }

    /** Signals go out one at a time, in order (offer before its candidates). */
    signal(msg, as) {
      const body = Object.assign({ from: 'viewer', viewer: as || this.viewer }, msg);
      const p = this.outbox.then(() => postJSON(`/api/screen/shares/${this.id}/signal`, body)).catch(() => null);
      this.outbox = p;
      return p;
    }

    /** The long poll of one peer connection (`gen`, polling as `viewerId`). */
    async poll(gen, viewerId, after) {
      let failures = 0;
      while (!this.closed && gen === this.gen) {
        let r;
        try {
          r = await getJSON(`/api/screen/shares/${this.id}/signal?for=viewer&after=${after}` +
                            `&viewer=${encodeURIComponent(viewerId)}&wait=25`);
          failures = 0;
        } catch (e) {
          if (e && (e.status === 404 || e.status === 410)) { this.end(); return; }
          failures += 1;
          await sleep(Math.min(5000, 800 * failures));
          continue;
        }
        if (r && r.status === 'ended') { this.end(); return; }
        if (gen !== this.gen) return;  // this connection was replaced meanwhile
        for (const m of (r && r.messages) || []) {
          after = Math.max(after, m.seq || 0);
          this.after = Math.max(this.after, after);
          if (gen !== this.gen) return;
          try { await this.handle(m); } catch (err) { console.warn('mac screen signal', err); }
        }
      }
    }

    async handle(m) {
      const pc = this.pc;
      if (!pc || this.closed) return;
      if (m.type === 'answer' && m.sdp) {
        if (pc.signalingState !== 'have-local-offer') return;
        await pc.setRemoteDescription({ type: 'answer', sdp: m.sdp });
        const queued = this.pending;
        this.pending = [];
        for (const c of queued) { try { await pc.addIceCandidate(c); } catch (_) { /* stale */ } }
        // Answered but ICE never gets through (a blocked network, a dead TURN): start over.
        const gen = this.gen;
        this.later(() => {
          if (gen === this.gen && !this.closed && this.state !== 'live' &&
              !['connected', 'completed'].includes(pc.connectionState || pc.iceConnectionState)) this.retry('timeout');
        }, ICE_TIMEOUT_MS);
      } else if (m.type === 'candidate' && m.candidate && m.candidate.candidate) {
        // The Mac's candidates can arrive before its answer: hold them until it is set.
        if (!pc.remoteDescription) { if (this.pending.length < 64) this.pending.push(m.candidate); return; }
        await pc.addIceCandidate(m.candidate);
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
      this.clearTimers();
      try { if (this.pc) this.pc.close(); } catch (_) { /* already closed */ }
      this.setState('ended');
      if (viewers.get(this.id) === this) viewers.delete(this.id);
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
      v.start().catch((e) => { v.error = String((e && e.message) || e); v.retry('error'); });
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
    if (v && v.state === 'failed') return ['Can’t connect', 'is-off'];
    return [share.status === 'live' ? 'Connecting' : 'Waiting for the Mac', ''];
  }

  const MAC_OFFLINE = 'Open Jarvis on your Mac to share its screen.';

  /** The note over a not-yet-live picture (null when the picture is live). */
  function liveNote(share, v) {
    if (v && v.state === 'live') return null;
    if (v && v.state === 'ended') return 'The share has ended.';
    if (share && share.mac_online === false) return MAC_OFFLINE;
    if (v && v.error) return v.error;
    return 'Connecting to your Mac…';
  }

  // A task share's replay is uploaded by the Mac after the share ends; a long one
  // can take a while. Anytime shares are never recorded.
  const REPLAY_WAIT_MS = 10 * 60 * 1000;
  function replayMayCome(share, now) {
    if (!share || share.replay_url || share.reason !== 'task') return false;
    const ended = Date.parse(share.ended_at || '');
    return Number.isFinite(ended) && (now == null ? Date.now() : now) - ended < REPLAY_WAIT_MS;
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
    const st = { share: null, viewer: null, replayShown: false };
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
        replayMayCome(share) ? 'The Mac is uploading the replay…' : (share.error || 'No replay for this one.');
      return;
    }
    if (v && v.stream && video.srcObject !== v.stream) video.srcObject = v.stream;
    note.textContent = liveNote(share, v) || '';
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
        if (st.viewer) { st.viewer.end(); st.viewer = null; }
        draw(card);
        if (!replayMayCome(share)) return;
        await sleep(5000);
        continue;
      }
      if (share && !st.viewer && card.isConnected) {
        st.viewer = viewerFor(shareId);
        st.viewer.on(() => draw(card));
      }
      if (st.viewer) st.viewer.setShare(share);
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

  const avgX = (ts) => { let n = 0; for (const t of ts) n += t.clientX; return n / ts.length; };
  const avgY = (ts) => { let n = 0; for (const t of ts) n += t.clientY; return n / ts.length; };

  /**
   * A keydown as an input message. `key` is the KeyboardEvent.key, except that a
   * PC's Del key becomes "ForwardDelete" ("Delete" alone means backspace to the
   * Mac, which is what the iPhone's ⌫ sends); `code` is the physical key, which
   * the Mac uses for shortcuts (⌥F's key is "ƒ", ⌘⇧['s is "{").
   */
  function keyMessage(e) {
    const key = e.key === 'Delete' ? 'ForwardDelete' : e.key;
    const msg = { t: 'key', key, mods: mods(e) };
    if (e.code) msg.code = e.code;
    return msg;
  }

  function isPasteKey(e) {
    return !!(e.metaKey || e.ctrlKey) && !e.altKey && (e.code === 'KeyV' || String(e.key).toLowerCase() === 'v');
  }

  function openFull(shareId, share0, opts) {
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
      const share = v.share || share0;
      stateEl.textContent = v.state === 'live' ? 'Live · your mouse and keys go to the Mac' :
        v.state === 'ended' ? 'Ended' : v.state === 'failed' ? 'Can’t connect' :
        share && share.mac_online === false ? 'Mac offline' : 'Connecting…';
      const n = liveNote(share, v);
      note.textContent = n == null ? (v.error || '') : n;
    };
    const off = v.on(paint);
    paint();
    // Keep the share record fresh (mac_online, ended) while full screen is open.
    let watching = true;
    (async () => {
      while (watching && !v.closed) {
        try {
          const share = await getJSON(`/api/screen/shares/${shareId}`);
          if (!watching) return;
          v.setShare(share);
          if (share && share.status === 'ended') { v.end(); return; }
        } catch (e) {
          if (e && e.status === 404) { v.end(); return; }
        }
        await sleep(3000);
      }
    })();

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
    // ⌘V / Ctrl+V: let the browser fire `paste` so this computer's clipboard text
    // is typed on the Mac. No paste event (Safari on a non-editable element, or
    // no text on the clipboard) → press ⌘V on the Mac instead (its own clipboard).
    let pasteFallback = null;
    surface.addEventListener('keydown', (e) => {
      if (e.isComposing) return;
      if (['Meta', 'Shift', 'Alt', 'Control', 'CapsLock'].includes(e.key)) { e.preventDefault(); return; }
      const msg = keyMessage(e);
      if (isPasteKey(e)) {
        clearTimeout(pasteFallback);
        pasteFallback = setTimeout(() => { pasteFallback = null; v.send(msg); }, 250);
        return;  // no preventDefault: the paste event must fire
      }
      e.preventDefault();
      v.send(msg);
    });
    surface.addEventListener('paste', (e) => {
      const text = e.clipboardData && e.clipboardData.getData('text/plain');
      if (!text) return;
      e.preventDefault();
      clearTimeout(pasteFallback);
      pasteFallback = null;
      v.send({ t: 'text', text });
    });
    // Touch: a tap clicks, a one-finger swipe drags (down → move → up), two
    // fingers scroll.
    let touch = null;
    const SLOP = 8;
    surface.addEventListener('touchstart', (e) => {
      e.preventDefault();
      surface.focus();
      const t = e.touches[0];
      if (!t) return;
      if (e.touches.length > 1) {
        if (touch && touch.dragging) v.send(Object.assign({ t: 'up', button: 'left' }, at(touch.last)));
        touch = { scroll: true, y: avgY(e.touches), x: avgX(e.touches) };
        return;
      }
      touch = { start: { clientX: t.clientX, clientY: t.clientY }, last: { clientX: t.clientX, clientY: t.clientY },
                dragging: false, scroll: false, sent: 0 };
    }, { passive: false });
    surface.addEventListener('touchmove', (e) => {
      e.preventDefault();
      if (!touch) return;
      if (touch.scroll) {
        if (e.touches.length < 2) return;
        const x = avgX(e.touches), y = avgY(e.touches);
        v.send({ t: 'scroll', dx: Math.round((touch.x - x) * 2), dy: Math.round((touch.y - y) * 2) });
        touch.x = x; touch.y = y;
        return;
      }
      const t = e.touches[0];
      if (!t) return;
      touch.last = { clientX: t.clientX, clientY: t.clientY };
      if (!touch.dragging) {
        if (Math.hypot(t.clientX - touch.start.clientX, t.clientY - touch.start.clientY) < SLOP) return;
        touch.dragging = true;
        v.send(Object.assign({ t: 'down', button: 'left' }, at(touch.start)));
      }
      const now = performance.now();
      if (now - touch.sent < 30) return;
      touch.sent = now;
      v.send(Object.assign({ t: 'move' }, at(touch.last)));
    }, { passive: false });
    surface.addEventListener('touchend', (e) => {
      e.preventDefault();
      if (!touch || e.touches.length) return;
      const t = (e.changedTouches && e.changedTouches[0]) || touch.last;
      const done = touch;
      touch = null;
      if (done.scroll) return;
      if (done.dragging) {
        v.send(Object.assign({ t: 'up', button: 'left' }, at(t)));
      } else {
        v.send(Object.assign({ t: 'click', button: 'left', count: 1 }, at(done.start)));
      }
    }, { passive: false });
    surface.addEventListener('touchcancel', () => {
      if (touch && touch.dragging) v.send(Object.assign({ t: 'up', button: 'left' }, at(touch.last)));
      touch = null;
    });

    const close = () => {
      watching = false;
      clearTimeout(pasteFallback);
      off();
      el.remove();
      overlay = null;
      if (ownsShare) postJSON(`/api/screen/shares/${shareId}/stop`, {}).catch(() => null);
    };
    el.querySelector('[data-act="close"]').addEventListener('click', close);
    el.querySelector('[data-act="stop"]').addEventListener('click', () => {
      postJSON(`/api/screen/shares/${shareId}/stop`, {}).catch(() => null);
      watching = false;
      clearTimeout(pasteFallback);
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

  root.MacScreen = { toolRow, cardFor, openFull, startAnytime, shareIn, keyMessage, isPasteKey,
    replayMayCome, liveNote, backoff, _viewers: viewers, _Viewer: Viewer };
  if (typeof module !== 'undefined' && module.exports) module.exports = root.MacScreen;
})(typeof window !== 'undefined' ? window : globalThis);

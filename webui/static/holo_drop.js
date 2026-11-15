// Holo Drop on the web.
//
// Receive: an open Jarvis tab listens on /api/holo-drop/stream; the most recently used tab is
// the "Web" target. A drop shows a card bottom-right and does its action where the browser
// lets it (a download, a copy); opening a link needs his click (browsers block new tabs
// otherwise), so the card's Open button does it. Then it reports /landed.
// Send: the rail's Holo Drop button opens a small Orbit — drag a file in, paste a link or
// text, then click a device or fling the card toward it.
//
// Pure helpers are exported for node tests (holo_drop.test.js).
(function (root) {
  'use strict';

  var H = {
    tab: null,
    es: null,
    claimedAt: 0,

    /** image | video | file, from a File's MIME type. */
    kindOf: function (mime) {
      mime = String(mime || '');
      if (mime.indexOf('image/') === 0) return 'image';
      if (mime.indexOf('video/') === 0) return 'video';
      return 'file';
    },

    /** A pasted string as a drop: http(s) links travel as links, anything else as text. */
    fromText: function (s) {
      s = String(s || '').trim();
      if (!s) return null;
      if (/^https?:\/\/\S+$/i.test(s)) return { kind: 'link', url: s };
      return { kind: 'text', text: s };
    },

    /** What arriving here does, given what the browser allows without a click. */
    plan: function (drop) {
      var a = String(drop.action || 'open');
      var p = { save: a.indexOf('save') === 0, open: /open/.test(a), copy: /copy/.test(a) };
      if (drop.kind === 'link' || drop.kind === 'text') {
        return { auto: { copy: p.copy, save: p.save }, needsClick: p.open, outcome: H.outcome(a) };
      }
      // Files: "save" and "open" both download (the browser opens downloads its own way).
      return { auto: { download: p.save || p.open, copy: false }, needsClick: false, outcome: H.outcome(a) };
    },

    outcome: function (action) {
      return ({ save: 'saved', open: 'opened', copy: 'copied', save_open: 'saved_opened', save_copy: 'saved_copied' })[action] || 'shown';
    },

    words: function (outcome) {
      return ({ opened: 'Opened', saved: 'Saved', copied: 'Copied', saved_opened: 'Saved + opened',
        saved_copied: 'Saved + copied', shown: 'Shown' })[outcome] || 'Done';
    },

    /** Only web links ever open. */
    safeLink: function (url) {
      try { var u = new URL(String(url)); return (u.protocol === 'https:' || u.protocol === 'http:') ? u.href : null; }
      catch (e) { return null; }
    },

    /** The upload URL for a file drop. */
    uploadPath: function (file, target, action) {
      var q = new URLSearchParams({ kind: H.kindOf(file.type), target: target, name: file.name || 'Holo Drop',
        mime: file.type || 'application/octet-stream' });
      if (action) q.set('action', action);
      return 'api/holo-drop/drops/upload?' + q.toString();
    },

    /** Bubbles on a ring around the item: { id: {x, y} } in a w×h box (web has no bearings). */
    ring: function (devices, w, h) {
      var out = {}, n = devices.length, cx = w / 2, cy = h * 0.46, r = Math.min(w, h) * 0.36;
      devices.forEach(function (d, i) {
        var rad = ((360 / Math.max(1, n)) * i) * Math.PI / 180;
        out[d.id] = { x: cx + r * Math.sin(rad), y: cy - r * Math.cos(rad) };
      });
      return out;
    },

    /** The bubble a fling points at: within 35° of its direction (and fast enough). */
    flingTarget: function (vx, vy, origin, positions) {
      if (Math.hypot(vx, vy) < 300) return null;
      var ang = function (dx, dy) { var d = Math.atan2(dx, -dy) * 180 / Math.PI; return (d + 360) % 360; };
      var f = ang(vx, vy), best = null;
      Object.keys(positions).forEach(function (id) {
        var p = positions[id];
        var d = Math.abs(((ang(p.x - origin.x, p.y - origin.y) - f + 540) % 360) - 180);
        if (d <= 35 && (!best || d < best.d)) best = { id: id, d: d };
      });
      return best ? best.id : null;
    },
  };

  // ── browser only ──────────────────────────────────────────────────────────────
  if (typeof document === 'undefined') { root.JCHoloDrop = H; return; }

  function url(path) { return new URL(path, document.baseURI || location.href).href; }
  function headers(extra) {
    var h = Object.assign({}, extra || {});
    if (H.tab) h['X-Holo-Tab'] = H.tab;
    return h;
  }
  function call(method, path, body) {
    return fetch(url(path), { method: method, credentials: 'include',
      headers: headers(body ? { 'Content-Type': 'application/json' } : {}),
      body: body ? JSON.stringify(body) : undefined })
      .then(function (r) { return r.json().catch(function () { return {}; }).then(function (j) {
        if (!r.ok) throw new Error(j.error || ('Server said ' + r.status)); return j; }); });
  }
  function on() { return !root.JCPower || root.JCPower.isOn('holo-drop'); }
  function el(tag, cls, text) { var e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }

  // Receive ---------------------------------------------------------------------
  H.listen = function () {
    if (H.es || !on() || typeof EventSource === 'undefined') return;
    var es = new EventSource(url('api/holo-drop/stream'), { withCredentials: true });
    H.es = es;
    es.addEventListener('hello', function (ev) { try { H.tab = JSON.parse(ev.data).tab; H.claim(true); } catch (e) {} });
    es.addEventListener('drop', function (ev) { try { H.arrive(JSON.parse(ev.data)); } catch (e) {} });
    es.addEventListener('landed', function (ev) {
      try {
        var d = JSON.parse(ev.data);
        H.toast(d.state === 'failed' ? 'Didn’t land: ' + (d.error || 'the device couldn’t take it') : 'Landed · ' + H.words(d.outcome));
      } catch (e) {}
    });
    es.onerror = function () { if (!on()) H.stop(); };   // switched off: stop retrying
  };

  H.stop = function () { if (H.es) { H.es.close(); H.es = null; } H.tab = null; };

  /** This tab is the "Web" target (the last one he used) — at most every 30 s. */
  H.claim = function (force) {
    if (!H.tab || !on()) return;
    var now = Date.now();
    if (!force && now - H.claimedAt < 30000) return;
    H.claimedAt = now;
    call('POST', 'api/holo-drop/web-claim', { tab: H.tab }).catch(function () {});
  };

  H.arrive = function (drop) {
    if (!on() || !drop || !drop.id) return;
    var plan = H.plan(drop);
    var card = el('div', 'holo-card');
    card.setAttribute('role', 'status');
    var title = drop.kind === 'link' ? (drop.title || drop.url) : drop.kind === 'text' ? drop.text : (drop.name || 'A file');
    card.appendChild(el('div', 'holo-card-title', String(title || '').slice(0, 140)));
    var from = 'From ' + (drop.from_name || 'another device');
    var sub = el('div', 'holo-card-sub', from);
    card.appendChild(sub);
    if (drop.kind === 'text') card.appendChild(el('div', 'holo-card-text', String(drop.text || '')));
    var reported = false;
    var done = function (outcome) {
      sub.textContent = from + ' · ' + H.words(outcome);
      if (reported) return;
      reported = true;
      call('POST', 'api/holo-drop/drops/' + encodeURIComponent(drop.id) + '/landed', { outcome: outcome }).catch(function () {});
    };
    var row = el('div', 'holo-card-actions');
    var isFile = drop.kind !== 'link' && drop.kind !== 'text';
    var openBtn = el('button', 'jci-button' + (plan.needsClick ? ' jci-primary' : ''), isFile ? 'Download' : 'Open');
    openBtn.onclick = function () {
      if (drop.kind === 'link') { var u = H.safeLink(drop.url); if (u) window.open(u, '_blank', 'noopener'); }
      else if (drop.kind === 'text') { card.classList.add('holo-card-expanded'); }
      else { download(drop); }
      done(plan.needsClick ? plan.outcome : 'opened');
    };
    row.appendChild(openBtn);
    if (!isFile) {
      var copyBtn = el('button', 'jci-button', 'Copy');
      copyBtn.onclick = function () { copy(drop).then(function () { done('copied'); }, function () {}); };
      row.appendChild(copyBtn);
    }
    var closeBtn = el('button', 'jci-button holo-card-close', '×');
    closeBtn.setAttribute('aria-label', 'Dismiss');
    closeBtn.onclick = function () { card.remove(); };
    row.appendChild(closeBtn);
    card.appendChild(row);
    stack().appendChild(card);
    // What the browser allows without a click (link/text "save" lives in History).
    if (plan.auto.download) download(drop);
    var auto = plan.auto.copy ? copy(drop) : Promise.resolve();
    auto.then(function () { if (!plan.needsClick) done(plan.outcome); }, function () { /* the Copy button is there */ });
    if (!plan.needsClick) setTimeout(function () { if (!card.classList.contains('holo-card-expanded')) card.remove(); }, 12000);
  };

  function download(drop) {
    var a = el('a');
    a.href = url('api/holo-drop/drops/' + encodeURIComponent(drop.id) + '/content');
    a.download = drop.name || 'Holo Drop';
    document.body.appendChild(a); a.click(); a.remove();
  }

  function copy(drop) {
    var text = drop.kind === 'link' ? drop.url : drop.text;
    if (!navigator.clipboard || text == null) return Promise.reject(new Error('no clipboard'));
    return navigator.clipboard.writeText(String(text));
  }

  function stack() {
    var s = document.getElementById('holoStack');
    if (!s) { s = el('div', 'holo-stack'); s.id = 'holoStack'; document.body.appendChild(s); }
    return s;
  }

  H.toast = function (text) {
    var t = el('div', 'holo-card holo-toast', text);
    stack().appendChild(t);
    setTimeout(function () { t.remove(); }, 5000);
  };

  // Send ------------------------------------------------------------------------
  H.openOrbit = function () {
    if (!on() || document.querySelector('.holo-shade')) return;
    var item = null, action = null, devices = [];
    var shade = el('div', 'holo-shade');
    var box = el('div', 'holo-orbit');
    box.setAttribute('role', 'dialog');
    box.setAttribute('aria-label', 'Holo Drop');
    shade.appendChild(box);
    var close = function () { shade.remove(); document.removeEventListener('paste', onPaste); document.removeEventListener('keydown', onKey); };
    var onKey = function (e) { if (e.key === 'Escape') close(); };
    shade.onclick = function (e) { if (e.target === shade) close(); };
    box.appendChild(el('div', 'holo-orbit-title', 'Holo Drop'));
    var stage = el('div', 'holo-stage'); box.appendChild(stage);
    var card = el('div', 'holo-item', 'Drop a file here, or paste a link or text');
    var pick = el('input'); pick.type = 'file'; pick.style.display = 'none';
    pick.onchange = function () { if (pick.files[0]) setItem({ file: pick.files[0] }); };
    card.onclick = function () { if (!item) pick.click(); };
    stage.appendChild(card); box.appendChild(pick);
    var hint = el('div', 'holo-hint', 'Fling toward a device · or click one'); box.appendChild(hint);
    var chips = el('div', 'holo-chips'); box.appendChild(chips);
    [['save', 'Save'], ['open', 'Open'], ['copy', 'Copy'], ['save_open', 'Save + Open'], ['save_copy', 'Save + Copy']].forEach(function (c) {
      var b = el('button', 'holo-chip', c[1]);
      b.onclick = function () {
        action = action === c[0] ? null : c[0];
        Array.prototype.forEach.call(chips.children, function (x) { x.classList.toggle('on', x === b && !!action); });
      };
      chips.appendChild(b);
    });
    var closeBtn = el('button', 'jci-button holo-x', '×'); closeBtn.setAttribute('aria-label', 'Close'); closeBtn.onclick = close;
    box.appendChild(closeBtn);
    document.body.appendChild(shade);
    document.addEventListener('keydown', onKey);

    function setItem(it) {
      item = it;
      card.textContent = it.file ? it.file.name : it.kind === 'link' ? it.url : String(it.text).slice(0, 120);
      card.classList.add('has-item');
    }
    function onPaste(e) {
      var f = e.clipboardData && e.clipboardData.files && e.clipboardData.files[0];
      if (f) { setItem({ file: f }); return; }
      var it = H.fromText(e.clipboardData && e.clipboardData.getData('text'));
      if (it) setItem(it);
    }
    document.addEventListener('paste', onPaste);
    stage.ondragover = function (e) { e.preventDefault(); };
    stage.ondrop = function (e) {
      e.preventDefault();
      var f = e.dataTransfer.files && e.dataTransfer.files[0];
      if (f) setItem({ file: f }); else { var it = H.fromText(e.dataTransfer.getData('text')); if (it) setItem(it); }
    };

    function send(d) {
      if (!item) { hint.textContent = 'Drop a file or paste something first'; return; }
      hint.textContent = 'Sending to ' + d.name + '…';
      var p = item.file
        ? fetch(url(H.uploadPath(item.file, d.id, action)), { method: 'POST', credentials: 'include', headers: headers(), body: item.file })
            .then(function (r) { return r.json().catch(function () { return {}; }).then(function (j) { if (!r.ok) throw new Error(j.error || ('Server said ' + r.status)); return j; }); })
        : call('POST', 'api/holo-drop/drops', Object.assign({ target: d.id }, action ? { action: action } : {}, item));
      p.then(function (j) {
        var s = j.drop && j.drop.state;
        hint.textContent = s === 'landed' ? 'Landed on ' + d.name : s === 'held' ? 'Sent — waiting for ' + d.name : 'Sent to ' + d.name;
        setTimeout(close, 1800);
      }, function (e) { hint.textContent = String(e.message || e); });
    }

    call('GET', 'api/holo-drop/devices').then(function (j) {
      devices = (j.devices || []).filter(function (d) { return d.id !== 'web'; });
      var w = stage.clientWidth || 420, h = stage.clientHeight || 360;
      var pos = H.ring(devices, w, h);
      devices.forEach(function (d) {
        var b = el('button', 'holo-bubble' + (d.online ? '' : ' offline'), d.name);
        b.style.left = (pos[d.id].x - 34) + 'px'; b.style.top = (pos[d.id].y - 34) + 'px';
        b.setAttribute('aria-label', 'Drop on ' + d.name);
        b.onclick = function () { send(d); };
        stage.appendChild(b);
      });
      if (!devices.length) hint.textContent = 'No devices to drop onto right now';
      // Fling: drag the card and let go moving toward a bubble.
      var start = null, last = null;
      card.onpointerdown = function (e) {
        if (!item) return;
        start = last = { x: e.clientX, y: e.clientY, t: performance.now() };
        card.setPointerCapture(e.pointerId);
      };
      card.onpointermove = function (e) {
        if (!start) return;
        card.style.transform = 'translate(' + (e.clientX - start.x) + 'px,' + (e.clientY - start.y) + 'px)';
        last = { x: e.clientX, y: e.clientY, t: performance.now(), px: last.x, py: last.y, pt: last.t };
      };
      card.onpointerup = function () {
        if (!start) return;
        var dt = Math.max(1, last.t - (last.pt || start.t)) / 1000;
        var vx = (last.x - (last.px || start.x)) / dt, vy = (last.y - (last.py || start.y)) / dt;
        var id = H.flingTarget(vx, vy, { x: w / 2, y: h * 0.46 }, pos);
        start = null; card.style.transform = '';
        var d = devices.find(function (x) { return x.id === id; });
        if (d) send(d);
      };
    }, function (e) { hint.textContent = String(e.message || e); });
  };

  root.JCHoloDrop = H;
  document.addEventListener('DOMContentLoaded', function () { setTimeout(H.listen, 1500); });
  window.addEventListener('focus', function () { if (on()) { H.listen(); H.claim(); } else { H.stop(); } });
  document.addEventListener('pointerdown', function () { H.claim(); }, { passive: true });
})(typeof window !== 'undefined' ? window : globalThis);

if (typeof module !== 'undefined') module.exports = (typeof window !== 'undefined' ? window : globalThis).JCHoloDrop;

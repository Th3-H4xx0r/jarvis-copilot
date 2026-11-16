// Remote Desktop on the web (plan docs/superpowers/plans/2026-11-15-remote-desktop.md, Task 7).
//
// The PC card's "Remote Desktop" button calls JCRdp.open(deviceId, name):
// * on a Mac (the Agents page in Safari/Chrome or the Mac app) it opens Microsoft Windows App with
//   the PC's Tailscale address and username filled in (rdp:// URI, or a downloadable .rdp), after the
//   same readiness checks and game / someone-at-the-PC warnings as everywhere else — "Use the
//   browser instead" falls through to the in-browser session;
// * elsewhere it runs the in-browser session: POST /api/rdp/sessions → Face ID on his iPhone (polled)
//   → the Guacamole tunnel (/api/rdp/guac/<id>, rdp_guac.py) with vendored guacamole-common-js 1.5.5:
//   keyboard with Ctrl+Alt+Del / Win buttons, clipboard both ways, drag-and-drop upload and file
//   download through the "Jarvis" drive, PC sound, the session resized to the window, fullscreen.
// The flow and every message live in rdp_core.js (tested in rdp.test.js).
(function (root) {
  'use strict';

  var R = root.RdpCore;
  if (typeof document === 'undefined' || !R) return;

  var API = '/api/rdp';
  var POLL_MS = 1000, APPROVAL_MS = 65000;
  var KEY = { ctrl: 0xFFE3, alt: 0xFFE9, del: 0xFFFF, win: 0xFFEB };
  var S = { el: null, state: null, deviceId: '', client: null, tunnel: null, keyboard: null, fs: null,
            timers: {}, seq: 0, clip: '' };

  function on() { return !root.JCPower || root.JCPower.isOn('remote-desktop'); }
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function post(path, body) { return root.api(API + path, { method: 'POST', body: JSON.stringify(body || {}) }); }
  function toast(msg) {
    var t = S.el && S.el.querySelector('.rdpv-toast');
    if (!t) { if (typeof root.showToast === 'function') root.showToast(msg); return; }
    t.textContent = msg;
    t.classList.add('is-on');
    clearTimeout(S.timers.toast);
    S.timers.toast = setTimeout(function () { t.classList.remove('is-on'); }, 3500);
  }
  var ICON = {
    keys: '<path d="M2.5 5h11v6h-11z"/><path d="M5 7.5h.01M8 7.5h.01M11 7.5h.01M5.5 9.5h5"/>',
    win: '<path d="M3 3.5l4.2-.6v4.6H3zM8.3 2.8L13 2v5.5H8.3zM3 8.5h4.2v4.6L3 12.5zM8.3 8.5H13V14l-4.7-.7z"/>',
    clip: '<path d="M5.5 3h-1A1.5 1.5 0 003 4.5v8A1.5 1.5 0 004.5 14h7a1.5 1.5 0 001.5-1.5v-8A1.5 1.5 0 0011.5 3h-1"/><path d="M6 2h4v2.2H6z"/>',
    up: '<path d="M8 11V3M4.8 6.2L8 3l3.2 3.2M3 13h10"/>',
    files: '<path d="M2.5 4.5A1.5 1.5 0 014 3h2.6l1.4 1.5h4A1.5 1.5 0 0113.5 6v5.5A1.5 1.5 0 0112 13H4a1.5 1.5 0 01-1.5-1.5z"/>',
    full: '<path d="M3 6V3h3M10 3h3v3M13 10v3h-3M6 13H3v-3"/>',
  };
  function icon(name) { return '<svg viewBox="0 0 16 16" aria-hidden="true">' + ICON[name] + '</svg>'; }

  // ── open ─────────────────────────────────────────────────────────────────
  function open(deviceId, name) {
    if (!on()) { toast('Remote Desktop is switched off'); return; }
    if (S.el) close();
    S.deviceId = deviceId || '';
    S.seq++;
    S.state = R.initial(name || 'Your PC');
    if (R.isMac(root.navigator) && !root.__jcRdpBrowser) return openMac(name);
    shell();
    step({ type: 'start' });
  }

  function step(ev) {
    S.state = R.flow(S.state, ev);
    render();
    var s = S.state, seq = S.seq;
    if (s.phase === 'checking') {
      post('/sessions', { device_id: S.deviceId, client: 'web', confirm: !!s.confirm }).then(function (r) {
        if (seq === S.seq) step({ type: 'created', response: r || {} });
      }).catch(function (e) {
        if (seq !== S.seq) return;
        var body = {};
        try { body = JSON.parse(e.body || '{}'); } catch (x) { /* not JSON */ }
        step({ type: 'created', response: e.status === 409 ? { code: 'web_off', error: 'Remote Desktop is switched off' }
          : (body.code ? body : { code: 'failed', error: e.message || 'Remote Desktop didn’t start' }) });
      });
    } else if (s.phase === 'approving') {
      clearTimeout(S.timers.approve);
      S.timers.approve = setTimeout(function () { if (seq === S.seq) step({ type: 'timeout' }); }, APPROVAL_MS);
      poll(seq);
    } else if (s.phase === 'connecting') {
      clearTimeout(S.timers.approve);
      connect(seq);
    } else if (s.phase === 'error' || s.phase === 'ended') {
      clearTimeout(S.timers.approve);
      clearTimeout(S.timers.poll);
    }
  }

  function poll(seq) {
    clearTimeout(S.timers.poll);
    if (seq !== S.seq || S.state.phase !== 'approving') return;
    root.api(API + '/sessions/' + encodeURIComponent(S.state.sessionId)).then(function (b) {
      if (seq !== S.seq) return;
      step({ type: 'polled', session: (b && b.session) || {} });
    }).catch(function () { /* keep polling until the timeout */ }).then(function () {
      if (seq === S.seq && S.state.phase === 'approving') S.timers.poll = setTimeout(function () { poll(seq); }, POLL_MS);
    });
  }

  // ── the session (guacamole-common-js) ────────────────────────────────────
  function stageSize() {
    var stage = S.el.querySelector('.rdpv-stage');
    var dpr = Math.min(root.devicePixelRatio || 1, 2);
    return { w: Math.max(480, stage.clientWidth * dpr), h: Math.max(480, stage.clientHeight * dpr), dpr: dpr };
  }

  function connect(seq) {
    var G = root.Guacamole;
    if (!G) { step({ type: 'tunnel_error', message: 'The Remote Desktop client didn’t load' }); return; }
    var tunnel = new G.WebSocketTunnel(R.tunnelPath(S.state.sessionId));
    var client = new G.Client(tunnel);
    S.tunnel = tunnel;
    S.client = client;
    var display = client.getDisplay();
    var stage = S.el.querySelector('.rdpv-stage');
    var holder = S.el.querySelector('.rdpv-display');
    holder.innerHTML = '';
    holder.appendChild(display.getElement());

    function fit() {
      var dw = display.getWidth(), dh = display.getHeight();
      if (!dw || !dh) return;
      var scale = Math.min(stage.clientWidth / dw, stage.clientHeight / dh);
      display.scale(scale);
    }
    display.onresize = fit;
    S.fit = fit;

    function failed(status) {
      if (seq !== S.seq || (S.state.phase !== 'connecting' && S.state.phase !== 'connected')) return;
      step({ type: 'tunnel_error', message: (status && status.message) || 'The connection to the PC was lost',
             status: status && status.code });
    }
    client.onstatechange = function (st) {
      if (seq !== S.seq) return;
      if (st === 3 && S.state.phase === 'connecting') {            // CONNECTED
        clearTimeout(S.timers.connect);
        step({ type: 'tunnel_open' });
        fit();
        stage.focus();
      } else if (st === 5) {                                       // DISCONNECTED
        if (S.state.phase === 'connected') step({ type: 'ended' });
        else failed(null);                                         // never got there: never a hanging spinner
      }
    };
    client.onerror = failed;
    tunnel.onerror = failed;
    clearTimeout(S.timers.connect);
    S.timers.connect = setTimeout(function () {
      if (seq === S.seq && S.state.phase === 'connecting') failed({ message: 'The PC didn’t answer in time' });
    }, 30000);
    // our own notices (a file over 2 GB removed from the drive) ride the tunnel as "jc-notice"
    var handle = tunnel.oninstruction;
    tunnel.oninstruction = function (op, args) {
      if (op === 'jc-notice') { toast(args[0] || ''); return; }
      if (handle) handle(op, args);
    };
    client.onclipboard = function (stream, mimetype) {
      if (!/^text\//.test(mimetype)) { stream.sendAck('Unsupported', 0x0100); return; }
      var reader = new G.StringReader(stream), text = '';
      reader.ontext = function (t) { text += t; };
      reader.onend = function () {
        S.clip = text;
        var box = S.el && S.el.querySelector('.rdpv-clip textarea');
        if (box && document.activeElement !== box) box.value = text;
        try { if (navigator.clipboard && document.hasFocus()) navigator.clipboard.writeText(text); } catch (e) { /* no permission */ }
      };
    };
    client.onfilesystem = function (object, name) { S.fs = object; S.fsName = name; };

    // input: mouse on the display, keyboard while the session has focus
    var mouse = new G.Mouse(display.getElement());
    mouse.onEach(['mousedown', 'mouseup', 'mousemove'], function (e) { client.sendMouseState(e.state, true); });
    if (G.Mouse.Touchpad && ('ontouchstart' in root)) {
      var pad = new G.Mouse.Touchpad(display.getElement());
      pad.onEach(['mousedown', 'mouseup', 'mousemove'], function (e) { client.sendMouseState(e.state, true); });
    }
    var kb = new G.Keyboard(stage);
    kb.onkeydown = function (k) { client.sendKeyEvent(1, k); return true; };
    kb.onkeyup = function (k) { client.sendKeyEvent(0, k); };
    S.keyboard = kb;

    var size = stageSize();
    client.connect(R.connectQuery(size.w, size.h, size.dpr));
  }

  function keys(list) {
    if (!S.client) return;
    list.forEach(function (k) { S.client.sendKeyEvent(1, k); });
    list.slice().reverse().forEach(function (k) { S.client.sendKeyEvent(0, k); });
    var stage = S.el.querySelector('.rdpv-stage');
    if (stage) stage.focus();
  }

  function sendClipboard(text) {
    var G = root.Guacamole;
    if (!S.client || !G || !text) return;
    var writer = new G.StringWriter(S.client.createClipboardStream('text/plain'));
    writer.sendText(text);
    writer.sendEnd();
    S.clip = text;
    toast('Clipboard sent to the PC');
  }

  // ── files: the "Jarvis" drive ────────────────────────────────────────────
  function upload(files) {
    var G = root.Guacamole;
    if (!S.fs || !G) { toast('The PC’s Jarvis drive isn’t ready yet'); return; }
    Array.prototype.forEach.call(files, function (file) {
      var why = R.checkUpload(file);
      if (why) { toast(why); return; }
      var stream = S.fs.createOutputStream(file.type || 'application/octet-stream', '/' + file.name);
      toast('Uploading ' + file.name + '…');
      // as Guacamole's own client does: start once guacd has acknowledged the new file
      stream.onack = function (status) {
        if (status.isError()) { toast(file.name + ' didn’t upload: ' + (status.message || 'refused')); return; }
        var writer = new G.BlobWriter(stream);
        writer.onack = function (st) { if (st.isError()) toast(file.name + ' didn’t upload: ' + (st.message || 'refused')); };
        writer.oncomplete = function () { writer.sendEnd(); toast(file.name + ' is in the Jarvis drive on the PC'); listFiles(); };
        writer.onerror = function () { toast(file.name + ' didn’t upload'); };
        writer.sendBlob(file);
      };
    });
  }

  function listFiles() {
    var G = root.Guacamole;
    var box = S.el && S.el.querySelector('.rdpv-files-list');
    if (!box) return;
    if (!S.fs || !G) { box.innerHTML = '<div class="rdpv-muted">The Jarvis drive appears once the session is connected.</div>'; return; }
    box.innerHTML = '<div class="rdpv-muted">Reading…</div>';
    clearTimeout(S.timers.files);
    S.timers.files = setTimeout(function () {
      if (box.isConnected && /Reading/.test(box.textContent)) box.innerHTML = '<div class="rdpv-muted">Couldn’t read the Jarvis drive.</div>';
    }, 8000);
    S.fs.requestInputStream('/', function (stream, mimetype) {
      if (mimetype !== G.Object.STREAM_INDEX_MIMETYPE) { stream.sendAck('Unexpected', 0x0100); return; }
      var reader = new G.JSONReader(stream);
      stream.sendAck('Ready', 0x0000);          // guacd sends the index only once it's acknowledged
      reader.onend = function () {
        var entries = reader.getJSON() || {};
        var names = Object.keys(entries).filter(function (p) { return entries[p] !== G.Object.STREAM_INDEX_MIMETYPE; });
        box.innerHTML = names.length ? names.map(function (p) {
          return '<button type="button" class="rdpv-file" data-rdp="download" data-path="' + esc(p) + '">' +
            esc(p.replace(/^\//, '')) + '<span>Download</span></button>';
        }).join('') : '<div class="rdpv-muted">Empty. Files you save to the “Jarvis” drive on the PC show up here.</div>';
      };
    });
  }

  function download(path) {
    var G = root.Guacamole;
    if (!S.fs || !G) return;
    S.fs.requestInputStream(path, function (stream, mimetype) {
      var reader = new G.BlobReader(stream, mimetype);
      reader.onend = function () {
        var a = document.createElement('a');
        a.href = URL.createObjectURL(reader.getBlob());
        a.download = path.split('/').pop();
        document.body.appendChild(a);
        a.click();
        setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
      };
      stream.sendAck('OK', 0x0000);
    });
  }

  // ── the Mac: Microsoft Windows App ───────────────────────────────────────
  function openMac(name) {
    shell(true);
    renderMac({ loading: true });
    var seq = S.seq;
    root.api(API + '/status').then(function (b) {
      if (seq !== S.seq) return;
      var st = ((b && b.devices) || []).filter(function (d) { return d.device_id === S.deviceId; })[0] || null;
      var notReady = R.readiness(st, name);
      if (notReady) { renderMac({ error: notReady.message }); return; }
      var warn = R.warnFor(st);
      renderMac({ status: st, warn: warn ? R.warnText(Object.assign({ name: name }, { warn: warn.warn, gameName: warn.game_name })) : '' });
    }).catch(function (e) {
      if (seq === S.seq) renderMac({ error: e.status === 409 ? 'Remote Desktop is switched off' : 'Couldn’t read the PC’s status' });
    });
  }

  function renderMac(m) {
    var body = S.el.querySelector('.rdpv-card');
    var name = S.state.name;
    if (m.loading) { body.innerHTML = '<div class="rdpv-title">Remote Desktop</div><div class="rdpv-muted">Checking ' + esc(name) + '…</div>'; return; }
    if (m.error) {
      body.innerHTML = '<div class="rdpv-title">Remote Desktop</div><div class="rdpv-msg">' + esc(m.error) + '</div>' +
        '<div class="rdpv-actions"><button type="button" class="rdpv-btn" data-rdp="close">Close</button></div>';
      return;
    }
    S.macStatus = m.status;
    if (m.warn && !m.confirmed) {
      body.innerHTML = '<div class="rdpv-title">Remote Desktop</div><div class="rdpv-msg">' + esc(m.warn) + '</div>' +
        '<div class="rdpv-actions"><button type="button" class="rdpv-btn" data-rdp="close">Cancel</button>' +
        '<button type="button" class="rdpv-btn is-primary" data-rdp="mac-confirm">Connect anyway</button></div>';
      return;
    }
    body.innerHTML = '<div class="rdpv-title">Remote Desktop</div>' +
      '<div class="rdpv-msg">Opens ' + esc(name) + ' in Microsoft Windows App with its address and your username filled in. ' +
      'Windows App asks for your Windows password the first time and keeps it in your Mac’s keychain.</div>' +
      '<div class="rdpv-kv"><span>Address</span><b>' + esc(m.status.tailscale_ip) + '</b><span>Username</span><b>' + esc(m.status.username) + '</b></div>' +
      '<div class="rdpv-actions is-col"><button type="button" class="rdpv-btn is-primary" data-rdp="mac-open">Open in Windows App</button>' +
      '<button type="button" class="rdpv-btn" data-rdp="mac-file">Download .rdp file</button>' +
      '<a class="rdpv-link" href="https://apps.apple.com/app/windows-app/id1295203466" target="_blank" rel="noopener">Get Windows App</a>' +
      '<button type="button" class="rdpv-link" data-rdp="browser">Use the browser instead</button></div>';
  }

  function macFile() {
    var blob = new Blob([R.rdpFile(S.macStatus)], { type: 'application/x-rdp' });
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = (S.state.name || 'PC').replace(/[^\w.-]+/g, '-') + '.rdp';
    document.body.appendChild(a);
    a.click();
    setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
  }

  // ── drawing ──────────────────────────────────────────────────────────────
  function shell(mac) {
    var el = document.createElement('div');
    el.className = 'rdpv' + (mac ? ' is-mac' : '');
    el.setAttribute('role', 'dialog');
    el.setAttribute('aria-modal', 'true');
    el.setAttribute('aria-label', 'Remote Desktop');
    el.setAttribute('data-power', 'remote-desktop');
    el.innerHTML =
      '<header class="rdpv-bar">' +
        '<button type="button" class="rdpv-back" data-rdp="close" aria-label="Close Remote Desktop">‹</button>' +
        '<div class="rdpv-id"><div class="rdpv-name"></div><div class="rdpv-status"></div></div>' +
        '<div class="rdpv-tools">' +
          tool('cad', 'keys', 'Ctrl+Alt+Del') + tool('win', 'win', 'Win') + tool('clip', 'clip', 'Clipboard') +
          tool('upload', 'up', 'Upload') + tool('files', 'files', 'Files') + tool('full', 'full', 'Fullscreen') +
          '<button type="button" class="rdpv-btn is-danger" data-rdp="disconnect">Disconnect</button>' +
        '</div>' +
      '</header>' +
      '<div class="rdpv-stage" tabindex="0"><div class="rdpv-display"></div>' +
        '<div class="rdpv-card" role="status"></div>' +
        '<div class="rdpv-drop" aria-hidden="true"><span>Drop files to send them to the PC’s Jarvis drive</span></div>' +
      '</div>' +
      '<div class="rdpv-panel rdpv-clip" hidden><div class="rdpv-panel-h">Clipboard<button type="button" class="rdpv-x" data-rdp="panel-close" aria-label="Close">✕</button></div>' +
        '<textarea rows="5" placeholder="Text from the PC appears here. Paste here to send it to the PC."></textarea>' +
        '<div class="rdpv-actions"><button type="button" class="rdpv-btn is-primary" data-rdp="clip-send">Send to PC</button></div></div>' +
      '<div class="rdpv-panel rdpv-files" hidden><div class="rdpv-panel-h">Jarvis drive<button type="button" class="rdpv-x" data-rdp="panel-close" aria-label="Close">✕</button></div>' +
        '<div class="rdpv-files-list"></div>' +
        '<div class="rdpv-actions"><button type="button" class="rdpv-btn" data-rdp="files-refresh">Refresh</button>' +
        '<button type="button" class="rdpv-btn is-primary" data-rdp="upload">Upload…</button></div></div>' +
      '<input type="file" class="rdpv-file-input" multiple hidden>' +
      '<div class="rdpv-toast" role="status" aria-live="polite"></div>';
    document.body.appendChild(el);
    S.el = el;
    document.documentElement.classList.add('rdpv-lock');
    el.addEventListener('click', onClick);
    el.querySelector('.rdpv-file-input').addEventListener('change', function (e) { upload(e.target.files); e.target.value = ''; });
    var stage = el.querySelector('.rdpv-stage');
    stage.addEventListener('dragover', function (e) {
      if (S.state.phase !== 'connected') return;
      e.preventDefault(); el.classList.add('is-dropping');
    });
    stage.addEventListener('dragleave', function () { el.classList.remove('is-dropping'); });
    stage.addEventListener('drop', function (e) {
      e.preventDefault(); el.classList.remove('is-dropping');
      if (S.state.phase === 'connected' && e.dataTransfer) upload(e.dataTransfer.files);
    });
    // text the PC copied: the browser's own paste into the panel goes back the other way
    root.addEventListener('resize', onResize);
    document.addEventListener('keydown', onEsc, true);
    el.querySelector('.rdpv-name').textContent = S.state.name;
  }
  function tool(act, ic, label) {
    return '<button type="button" class="rdpv-tool" data-rdp="' + act + '" title="' + esc(label) + '" aria-label="' + esc(label) + '">' +
      icon(ic) + '<span>' + esc(label) + '</span></button>';
  }

  function render() {
    if (!S.el || S.el.classList.contains('is-mac')) return;
    var s = S.state;
    S.el.setAttribute('data-phase', s.phase);
    var status = { checking: 'Checking…', warn: 'Waiting for you', approving: 'Approve on your iPhone', connecting: 'Connecting…',
      connected: 'Connected', ended: 'Disconnected', error: 'Not connected' }[s.phase] || '';
    S.el.querySelector('.rdpv-status').innerHTML = (s.phase === 'connected' ? '<i class="rdpv-dot is-on"></i>' : '<i class="rdpv-dot"></i>') + esc(status);
    var card = S.el.querySelector('.rdpv-card');
    var html = '';
    if (s.phase === 'checking') {
      html = '<div class="rdpv-spinner" aria-hidden="true"></div><div class="rdpv-title">Checking ' + esc(s.name) + '…</div>';
    } else if (s.phase === 'warn') {
      html = '<div class="rdpv-title">Connect to ' + esc(s.name) + '?</div><div class="rdpv-msg">' + esc(R.warnText(s)) + '</div>' +
        '<div class="rdpv-actions"><button type="button" class="rdpv-btn" data-rdp="close">Cancel</button>' +
        '<button type="button" class="rdpv-btn is-primary" data-rdp="confirm">Connect anyway</button></div>';
    } else if (s.phase === 'approving') {
      html = '<div class="rdpv-faceid" aria-hidden="true"></div><div class="rdpv-title">Approve on your iPhone</div>' +
        '<div class="rdpv-msg">Face ID on your iPhone signs you in to ' + esc(s.name) + '. Jarvis fills your Windows password.</div>' +
        '<div class="rdpv-actions"><button type="button" class="rdpv-btn" data-rdp="close">Cancel</button></div>';
    } else if (s.phase === 'connecting') {
      html = '<div class="rdpv-spinner" aria-hidden="true"></div><div class="rdpv-title">Connecting to ' + esc(s.name) + '…</div>';
    } else if (s.phase === 'error') {
      html = '<div class="rdpv-title">Couldn’t connect</div><div class="rdpv-msg">' + esc(s.message) + '</div>' +
        '<div class="rdpv-actions"><button type="button" class="rdpv-btn" data-rdp="close">Close</button>' +
        (s.action === 'wake' ? '<button type="button" class="rdpv-btn is-primary" data-rdp="wake">Wake ' + esc(s.name) + '</button>'
          : '<button type="button" class="rdpv-btn is-primary" data-rdp="retry">Try again</button>') + '</div>';
    } else if (s.phase === 'ended') {
      html = '<div class="rdpv-title">Disconnected</div><div class="rdpv-msg">' + esc(s.name) + ' stays on the lock screen.</div>' +
        '<div class="rdpv-actions"><button type="button" class="rdpv-btn" data-rdp="close">Close</button>' +
        '<button type="button" class="rdpv-btn is-primary" data-rdp="retry">Reconnect</button></div>';
    }
    card.innerHTML = html;
    card.hidden = s.phase === 'connected';
  }

  // ── events ───────────────────────────────────────────────────────────────
  function onClick(e) {
    var t = e.target.closest('[data-rdp]');
    if (!t) return;
    var act = t.getAttribute('data-rdp');
    switch (act) {
      case 'close': close(); break;
      case 'disconnect': close(); break;
      case 'confirm': step({ type: 'confirm' }); break;
      case 'retry': teardown(); S.seq++; step({ type: 'start' }); break;
      case 'wake':
        root.api('/api/coding/agents/mac/wake', { method: 'POST', body: JSON.stringify({ device_id: S.deviceId }) })
          .then(function (r) { toast(r && r.ok === false ? (r.error || 'Couldn’t wake it') : 'Waking ' + S.state.name + '…'); })
          .catch(function (err) { toast(err.message || 'Couldn’t wake it'); });
        break;
      case 'cad': keys([KEY.ctrl, KEY.alt, KEY.del]); break;
      case 'win': keys([KEY.win]); break;
      case 'clip': panel('.rdpv-clip'); break;
      case 'clip-send': sendClipboard(S.el.querySelector('.rdpv-clip textarea').value); break;
      case 'files': panel('.rdpv-files'); listFiles(); break;
      case 'files-refresh': listFiles(); break;
      case 'upload': S.el.querySelector('.rdpv-file-input').click(); break;
      case 'download': download(t.getAttribute('data-path')); break;
      case 'panel-close': panel(null); break;
      case 'full':
        try { if (document.fullscreenElement) document.exitFullscreen(); else S.el.requestFullscreen(); } catch (x) { /* not allowed */ }
        break;
      case 'mac-confirm': renderMac({ status: S.macStatus, warn: 'x', confirmed: true }); break;
      case 'mac-open': root.location.href = R.rdpUri(S.macStatus); break;
      case 'mac-file': macFile(); break;
      case 'browser': {
        var dev = S.deviceId, nm = S.state.name;
        close();
        root.__jcRdpBrowser = true;
        try { open(dev, nm); } finally { root.__jcRdpBrowser = false; }
        break;
      }
    }
  }
  function panel(sel) {
    ['.rdpv-clip', '.rdpv-files'].forEach(function (p) {
      var el = S.el.querySelector(p);
      if (el) el.hidden = p !== sel || !el.hidden;
    });
    var clip = S.el.querySelector('.rdpv-clip textarea');
    if (sel === '.rdpv-clip' && clip && S.clip && !clip.value) clip.value = S.clip;
  }
  function onResize() {
    clearTimeout(S.timers.resize);
    S.timers.resize = setTimeout(function () {
      if (!S.el || !S.client || S.state.phase !== 'connected') return;
      var size = stageSize();
      S.client.sendSize(Math.round(size.w), Math.round(size.h));
      if (S.fit) S.fit();
    }, 250);
  }
  function onEsc(e) {
    if (e.key !== 'Escape' || !S.el) return;
    if (S.state && S.state.phase === 'connected') return;    // Esc belongs to the PC while connected
    close();
  }

  function teardown() {
    var sid = S.state && S.state.sessionId;
    if (S.keyboard) { S.keyboard.onkeydown = S.keyboard.onkeyup = null; S.keyboard = null; }
    if (S.client) { try { S.client.disconnect(); } catch (e) { /* gone */ } S.client = null; }
    S.tunnel = null; S.fs = null;
    if (sid) root.api(API + '/sessions/' + encodeURIComponent(sid), { method: 'DELETE' }).catch(function () {});
    Object.keys(S.timers).forEach(function (k) { clearTimeout(S.timers[k]); });
  }
  function close() {
    teardown();
    S.seq++;
    root.removeEventListener('resize', onResize);
    document.removeEventListener('keydown', onEsc, true);
    document.documentElement.classList.remove('rdpv-lock');
    if (S.el) S.el.remove();
    S.el = null;
  }

  root.JCRdp = { open: open, close: close };
})(this);

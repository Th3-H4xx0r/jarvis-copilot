// JarvisCopilot — Game Streaming on the web.
//
// A small card under the Game Streaming row on the Integrations page: whether a
// stream is running, and the one action to start one. The server side is
// api/game_streaming_routes.py; the full card and page live on the iPhone. This
// registers a native card with JCPower (power.js renders it inside the Power
// section) and carries data-power="game-streaming" so it hides when the
// integration is off. Black and white, like the rest of the Integrations page.

(function (root) {
  'use strict';

  var ID = 'game-streaming';

  var JCGameStreaming = {
    /// The status line under the card: "Streaming <app>" while live, else whether
    /// the host is reachable. Pure, for the node test.
    statusLine: function (status) {
      status = status || {};
      var live = status.live || {};
      if (live.active) return 'Streaming ' + (live.app || 'a game');
      if (status.reachable) {
        var n = (status.apps || []).length;
        return n ? ('Idle · ' + n + ' game' + (n === 1 ? '' : 's')) : 'Idle';
      }
      return 'Host unreachable';
    },
    /// The one main button's game and device: the first game + first target the
    /// host offers, or null when there's nothing to stream. Pure, for the test.
    primary: function (status) {
      status = status || {};
      var target = (status.targets || [])[0];
      if (!target) return null;
      var app = (status.apps || [])[0];
      return { game: (app && app.name) || 'a game', target: target.name };
    },
    /// Guess a device's type from its paired name. SHIELD/Fire/Google TV -> Android TV,
    /// iPhone/iPad -> iPhone, MacBook/iMac/Mac -> Mac, else Mac. Best-effort, editable.
    typeGuess: function (name) {
      var n = String(name == null ? '' : name).toLowerCase();
      function has(a) { return a.some(function (s) { return n.indexOf(s) >= 0; }); }
      if (has(['shield', 'fire tv', 'firestick', 'fire stick', 'google tv', 'android tv',
               'androidtv', 'nvidia', 'chromecast', 'mi box', 'onn', ' tv'])) return 'androidtv';
      if (has(['iphone', 'ipad', 'ipod'])) return 'ios';
      if (has(['macbook', 'imac', 'mac mini', 'mac studio', 'mac pro', 'mac'])) return 'mac';
      return 'mac';
    },
    /// The one setup status line, from GET /detect. Pure, for the test.
    detectHeadline: function (detect) {
      detect = detect || {};
      if (!detect.online) return 'Your PC is offline — turn it on to finish setup';
      if (detect.running && !detect.needs_login) return 'Found Sunshine on your gaming PC';
      if (detect.running) return 'Sunshine is running — add your Sunshine login below';
      return "Sunshine isn't running on your PC yet";
    },
    /// The editable device list: Sunshine's paired clients (type guessed or taken from a
    /// saved target), then any saved target Sunshine no longer lists. Pure, for the test.
    drafts: function (paired, targets) {
      paired = paired || []; targets = targets || [];
      var byName = {}; targets.forEach(function (t) { if (t && t.name) byName[t.name] = t; });
      var seen = {}, out = [];
      paired.forEach(function (p) {
        var ex = byName[p.name];
        out.push({ name: p.name, kind: ex ? ex.kind : JCGameStreaming.typeGuess(p.name),
                   tv_addr: (ex && ex.tv_addr) || '' });
        seen[p.name] = true;
      });
      targets.forEach(function (t) {
        if (t && t.name && !seen[t.name]) out.push({ name: t.name, kind: t.kind || 'mac', tv_addr: t.tv_addr || '' });
      });
      return out;
    },
  };

  var KIND_LABELS = [['mac', 'Mac'], ['androidtv', 'Android TV'], ['ios', 'iPhone']];

  if (typeof module !== 'undefined' && module.exports) { module.exports = JCGameStreaming; return; }
  root.JCGameStreaming = JCGameStreaming;

  function esc(s) { return (root.esc ? root.esc(s) : String(s == null ? '' : s)); }

  // Render the native card into `host` (power.js calls this for the game-streaming
  // row). Fetches status, then draws a status line and — when a stream can start —
  // one filled button.
  function renderCard(host, row) {
    host.setAttribute('data-power', ID);
    host.className = 'power-native-card gstream-card';
    host.innerHTML = '<div class="intg-card-meta gstream-line">…</div>';
    if (typeof api !== 'function') return;
    api('/api/game-streaming/status').then(function (status) {
      draw(host, status || {});
    }).catch(function () {
      var line = host.querySelector('.gstream-line'); if (line) line.textContent = 'Host unreachable';
    });
  }

  function draw(host, status) {
    var live = status.live || {};
    var primary = JCGameStreaming.primary(status);
    var parts = ['<div class="intg-card-meta gstream-line">' + esc(JCGameStreaming.statusLine(status)) + '</div>'];
    if (live.active) {
      parts.push('<div class="gstream-actions"><button type="button" class="btn secondary" data-gstream="stop">Stop</button></div>');
    } else if (primary) {
      parts.push('<div class="gstream-actions"><button type="button" class="btn primary" data-gstream="start">' +
        'Stream ' + esc(primary.game) + ' → ' + esc(primary.target) + '</button></div>');
    }
    host.innerHTML = parts.join('');
    var btn = host.querySelector('[data-gstream]');
    if (!btn) return;
    btn.onclick = function (ev) {
      ev.stopPropagation();
      btn.disabled = true;
      var act = btn.getAttribute('data-gstream');
      var call = act === 'stop'
        ? api('/api/game-streaming/stop', { method: 'POST', body: JSON.stringify({}) })
        : api('/api/game-streaming/start', { method: 'POST',
            body: JSON.stringify({ target: primary.target, game: primary.game }) });
      call.then(function (res) {
        var failed = res && res.ok === false;
        var detail = res && res.result && res.result.detail;
        if (typeof showToast === 'function') {
          showToast(failed ? (detail || 'Could not start the stream')
                           : (act === 'stop' ? 'Stopped' : 'Starting…'));
        }
        renderCard(host, { id: ID });
      }).catch(function (e) {
        btn.disabled = false;
        if (typeof showToast === 'function') showToast((e && e.message) || 'That didn’t work');
      });
    };
  }

  // The native setup section (replaces the generic settings form, so there is no JSON):
  // Sunshine status, the one login, and the device-type list with "Add a device".
  function renderSettings(hostEl, row) {
    hostEl.innerHTML = '<h4 class="intg-section-title">Set up</h4><div class="intg-card-meta">Checking your gaming PC…</div>';
    if (typeof api !== 'function') return;
    Promise.all([
      api('/api/game-streaming/detect').catch(function () { return {}; }),
      api('/api/game-streaming/status').catch(function () { return {}; }),
    ]).then(function (res) {
      drawSetup(hostEl, row, res[0] || {}, res[1] || {});
    });
  }

  function drawSetup(hostEl, row, detect, status) {
    var settings = row.settings || {};
    var pwSet = settings.password && settings.password.set;
    var drafts = JCGameStreaming.drafts(status.paired, status.targets);
    var deviceRows = drafts.map(function (d, i) {
      var opts = KIND_LABELS.map(function (k) {
        return '<option value="' + k[0] + '"' + (k[0] === d.kind ? ' selected' : '') + '>' + esc(k[1]) + '</option>';
      }).join('');
      var addr = d.kind === 'androidtv'
        ? '<input type="text" class="gstream-addr" data-i="' + i + '" placeholder="10.0.0.5:5555" value="' + esc(d.tv_addr || '') + '">'
        : '';
      return '<div class="intg-row power-setting"><div class="intg-row-main"><span class="intg-row-name">' +
        esc(d.name) + '</span>' + (addr ? '<div class="intg-row-sub">Its IP address on your network</div>' : '') + '</div>' +
        '<select class="gstream-kind" data-i="' + i + '">' + opts + '</select>' + addr + '</div>';
    }).join('');
    hostEl.innerHTML =
      '<h4 class="intg-section-title">Sunshine</h4>' +
      '<div class="intg-card-meta gstream-detect">' + esc(JCGameStreaming.detectHeadline(detect)) + '</div>' +
      '<div class="intg-row power-setting"><div class="intg-row-main"><span class="intg-row-name">Username</span></div>' +
        '<input type="text" id="gstreamUser" autocomplete="username" value="' + esc(settings.user || '') + '"></div>' +
      '<div class="intg-row power-setting"><div class="intg-row-main"><span class="intg-row-name">Password</span>' +
        '<div class="intg-row-sub">' + (pwSet ? 'Set' : 'Not set') + ' — the login you set in Sunshine itself</div></div>' +
        '<input type="password" id="gstreamPw" autocomplete="off" placeholder="Replace"></div>' +
      '<h4 class="intg-section-title">Your devices</h4>' +
      (deviceRows || '<div class="intg-card-meta">No devices yet — add one below.</div>') +
      '<div class="intg-row intg-row--click" id="gstreamAdd"><div class="intg-row-main">' +
        '<span class="intg-row-name">Add a device</span><span class="intg-row-sub">Pair a new Moonlight device with a PIN</span></div></div>' +
      '<div class="gstream-actions"><button type="button" class="btn primary" id="gstreamSave">Save</button></div>';

    hostEl.querySelectorAll('.gstream-kind').forEach(function (sel) {
      sel.onchange = function () {
        drafts[+sel.getAttribute('data-i')].kind = sel.value;
        drawSetup(hostEl, JCPower.row(ID) || row, detect, status);   // redraw so a TV shows its address
      };
    });
    hostEl.querySelectorAll('.gstream-addr').forEach(function (inp) {
      inp.oninput = function () { drafts[+inp.getAttribute('data-i')].tv_addr = inp.value; };
    });

    hostEl.querySelector('#gstreamAdd').onclick = function () {
      var name = window.prompt('A name for the new device'); if (!name) return;
      var pin = window.prompt('The PIN Moonlight shows on ' + name); if (!pin) return;
      api('/api/game-streaming/pair', { method: 'POST', body: JSON.stringify({ device: name, pin: pin }) })
        .then(function (res) {
          if (typeof showToast === 'function') showToast(res && res.ok ? 'Paired ' + name : (res && res.detail) || 'Pairing didn’t go through');
          renderSettings(hostEl, JCPower.row(ID) || row);
        }).catch(function (e) { if (typeof showToast === 'function') showToast((e && e.message) || 'That didn’t work'); });
    };

    hostEl.querySelector('#gstreamSave').onclick = function () {
      var btn = hostEl.querySelector('#gstreamSave');
      btn.disabled = true;
      var user = hostEl.querySelector('#gstreamUser').value;
      var pw = hostEl.querySelector('#gstreamPw').value;
      var changes = {};
      if (user !== (settings.user || '')) changes.user = user;
      if (pw) changes.password = pw;
      var steps = [];
      if (Object.keys(changes).length && root.JCPower) steps.push(JCPower.set(ID, { settings: changes }));
      steps.push(api('/api/game-streaming/targets', { method: 'POST', body: JSON.stringify({
        targets: drafts.map(function (d) {
          return { name: d.name, kind: d.kind, tv_addr: d.kind === 'androidtv' ? d.tv_addr : '' };
        }),
      }) }));
      Promise.all(steps).then(function () {
        if (typeof showToast === 'function') showToast('Saved');
        renderSettings(hostEl, JCPower.row(ID) || row);
      }).catch(function (e) {
        btn.disabled = false;
        if (typeof showToast === 'function') showToast((e && e.message) || 'That didn’t work');
      });
    };
  }

  // Register the native card + setup so power.js draws them inside the Game Streaming row.
  function register() {
    if (root.JCPower && root.JCPower.native) {
      root.JCPower.native[ID] = Object.assign({}, root.JCPower.native[ID],
        { card: renderCard, settings: renderSettings });
    }
  }

  if (typeof document !== 'undefined') {
    if (root.JCPower) register();
    else document.addEventListener('DOMContentLoaded', register);
  }
})(this);

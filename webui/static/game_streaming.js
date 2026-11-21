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
      if (status.needs_login) return 'Sunshine needs sign-in — check your password';
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
    detectHeadline: function (detect, pwSet) {
      detect = detect || {};
      if (!detect.online) return 'Your PC is offline — turn it on to finish setup';
      if (detect.running && !detect.needs_login) return 'Found Sunshine on your gaming PC';
      if (detect.running) {
        return pwSet
          ? 'That login was rejected — check your Sunshine password'
          : 'Sunshine is running — add your Sunshine login below';
      }
      return "Sunshine isn't running on your PC yet";
    },
    /// Which waiting pair request the pair panel answers: the current pick while it is
    /// still waiting, else the only one waiting, else none (the user picks). Pure.
    pairSelection: function (current, pairings) {
      pairings = pairings || [];
      if (current && pairings.some(function (p) { return p.id === current; })) return current;
      return pairings.length === 1 ? pairings[0].id : null;
    },
    /// The one line above the waiting list, from GET /pairings (or its 409). Pure.
    pairWaitingLine: function (reply) {
      if (!reply) return 'Looking for devices…';
      if (reply.offline) return 'Your PC is asleep or offline — wake it to pair';
      if (reply.needs_login) return 'Sunshine needs sign-in — check your password above';
      var pairings = reply.pairings || [];
      if (reply.reachable === false) return reply.detail || "Sunshine isn't running on your PC";
      if (!pairings.length) return reply.detail || PAIR_NONE_WAITING;
      if (pairings.length === 1) return 'Enter the PIN shown on ' + JCGameStreaming.pairLabel(pairings[0]);
      return "Pick the device that's showing a PIN";
    },
    /// A waiting request's name: Sunshine's client name, else its address. Pure.
    pairLabel: function (p) {
      p = p || {};
      return p.name || p.address || 'A device';
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
  var PAIR_NONE_WAITING = 'Waiting for a device… On the device, open Moonlight and tap your PC';
  var PAIR_POLL_MS = 2000;

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
    // Pre-fill the username from the PC's Sunshine state file when the user hasn't set one.
    var userVal = settings.user || (detect && detect.username) || '';
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
      '<div class="intg-card-meta gstream-detect">' + esc(JCGameStreaming.detectHeadline(detect, pwSet)) + '</div>' +
      '<div class="intg-row power-setting"><div class="intg-row-main"><span class="intg-row-name">Username</span></div>' +
        '<input type="text" id="gstreamUser" autocomplete="username" value="' + esc(userVal) + '"></div>' +
      '<div class="intg-row power-setting"><div class="intg-row-main"><span class="intg-row-name">Password</span>' +
        '<div class="intg-row-sub">' + (pwSet ? 'Set' : 'Not set') + ' — the login you set in Sunshine itself</div></div>' +
        '<input type="password" id="gstreamPw" autocomplete="off" placeholder="Replace"></div>' +
      '<h4 class="intg-section-title">Your devices</h4>' +
      (deviceRows || '<div class="intg-card-meta">No devices yet — add one below.</div>') +
      '<div class="intg-row intg-row--click" id="gstreamAdd"><div class="intg-row-main">' +
        '<span class="intg-row-name">Add a device</span><span class="intg-row-sub">Pair a new Moonlight device with a PIN</span></div></div>' +
      '<div class="gstream-pair" id="gstreamPair" hidden></div>' +
      '<div class="gstream-actions" id="gstreamSaveRow"><button type="button" class="btn primary" id="gstreamSave">Save</button></div>';

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
      openPairPanel(hostEl, row);
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

  // The pair panel: opens under "Add a device", polls GET /pairings every 2 s while open,
  // lists the Moonlight devices waiting to pair (the only one is picked for you), prefills
  // its name (editable) and answers it with the PIN it shows — Sunshine pairs a specific
  // waiting request, so the PIN goes with that request's pairing_id. Save hides meanwhile
  // so Pair is the one filled button.
  function openPairPanel(hostEl, row) {
    var panel = hostEl.querySelector('#gstreamPair');
    var saveRow = hostEl.querySelector('#gstreamSaveRow');
    if (!panel || !panel.hidden) return;
    var state = { reply: null, selected: null, name: '', nameEdited: false, pin: '', busy: false, error: '' };
    var timer = null;

    function close() {
      if (timer) { clearInterval(timer); timer = null; }
      panel.hidden = true;
      panel.innerHTML = '';
      if (saveRow) saveRow.hidden = false;
    }

    function pick(id) {
      state.selected = id;
      var p = ((state.reply && state.reply.pairings) || []).filter(function (x) { return x.id === id; })[0];
      if (p && !state.nameEdited) state.name = JCGameStreaming.pairLabel(p);
    }

    function canPair() {
      return !!state.selected && !state.busy && state.name.trim() && state.pin.trim().length >= 4;
    }

    function draw() {
      var pairings = (state.reply && state.reply.pairings) || [];
      var list = pairings.map(function (p) {
        var on = p.id === state.selected;
        return '<div class="intg-row intg-row--click gstream-pairing" role="button" tabindex="0" data-id="' + esc(p.id) + '"' +
          ' aria-pressed="' + (on ? 'true' : 'false') + '"><div class="intg-row-main"><span class="intg-row-name">' +
          esc(JCGameStreaming.pairLabel(p)) + '</span>' + (p.address ? '<span class="intg-row-sub">' + esc(p.address) + '</span>' : '') +
          '</div>' + (on ? '<span class="intg-row-sub gstream-picked">Selected</span>' : '') + '</div>';
      }).join('');
      var details = state.selected
        ? '<div class="intg-row power-setting"><div class="intg-row-main"><span class="intg-row-name">Name</span></div>' +
            '<input type="text" id="gstreamPairName" autocomplete="off" value="' + esc(state.name) + '"></div>' +
          '<div class="intg-row power-setting"><div class="intg-row-main"><span class="intg-row-name">PIN</span>' +
            '<div class="intg-row-sub">The 4-digit PIN Moonlight shows</div></div>' +
            '<input type="text" id="gstreamPairPin" inputmode="numeric" autocomplete="one-time-code" maxlength="8" placeholder="1234" value="' + esc(state.pin) + '"></div>'
        : '';
      panel.innerHTML =
        '<h4 class="intg-section-title">Waiting to pair</h4>' +
        '<div class="intg-card-meta gstream-pair-line">' + esc(JCGameStreaming.pairWaitingLine(state.reply)) + '</div>' +
        list + details +
        (state.error ? '<div class="intg-card-meta gstream-pair-error" role="alert">' + esc(state.error) + '</div>' : '') +
        '<div class="gstream-actions">' +
          '<button type="button" class="btn primary" id="gstreamPairGo"' + (canPair() ? '' : ' disabled') + '>' + (state.busy ? 'Pairing…' : 'Pair') + '</button> ' +
          '<button type="button" class="btn secondary" id="gstreamPairCancel">Cancel</button>' +
        '</div>';
      panel.querySelectorAll('.gstream-pairing').forEach(function (el) {
        function choose() { pick(el.getAttribute('data-id')); draw(); }
        el.onclick = choose;
        el.onkeydown = function (ev) { if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); choose(); } };
      });
      var nameIn = panel.querySelector('#gstreamPairName');
      if (nameIn) nameIn.oninput = function () { state.name = nameIn.value; state.nameEdited = true; syncGo(); };
      var pinIn = panel.querySelector('#gstreamPairPin');
      if (pinIn) pinIn.oninput = function () { state.pin = pinIn.value; syncGo(); };
      panel.querySelector('#gstreamPairCancel').onclick = close;
      panel.querySelector('#gstreamPairGo').onclick = submit;
    }

    // Typing must not redraw (that would drop focus): only flip the button's disabled state.
    function syncGo() {
      var go = panel.querySelector('#gstreamPairGo');
      if (go) go.disabled = !canPair();
    }

    function load() {
      if (!panel.isConnected) { close(); return; }
      if (state.loading) return;           // a slow PC: don't stack polls
      state.loading = true;
      api('/api/game-streaming/pairings').then(function (reply) {
        state.loading = false;
        apply(reply || {});
      }).catch(function (e) {
        state.loading = false;
        // 409 = the PC is asleep/offline; anything else, say what happened.
        var offline = e && (e.status === 409 || /asleep|offline/i.test(e.message || ''));
        apply(offline ? { offline: true, pairings: [] }
                      : { reachable: false, pairings: [], detail: (e && e.message) || 'Couldn’t reach your PC' });
      });
    }

    function apply(reply) {
      if (panel.hidden) return;
      var before = JSON.stringify([state.reply, state.selected]);
      state.reply = reply;
      var next = JCGameStreaming.pairSelection(state.selected, reply.pairings);
      if (next !== state.selected) pick(next);
      // Redraw only when what's shown changed, so a poll never steals focus mid-typing.
      if (JSON.stringify([state.reply, state.selected]) !== before) draw();
    }

    function submit() {
      if (!canPair()) return;
      state.busy = true; state.error = ''; draw();
      var name = state.name.trim();
      api('/api/game-streaming/pair', { method: 'POST', body: JSON.stringify({
        pairing_id: state.selected, device: name, pin: state.pin.trim() }) })
        .then(function (res) {
          state.busy = false;
          if (res && res.ok) {
            close();
            if (typeof showToast === 'function') showToast((res && res.detail) || ('Paired ' + name));
            renderSettings(hostEl, (root.JCPower && JCPower.row(ID)) || row);
            return;
          }
          state.error = (res && res.detail) || 'Pairing didn’t go through';
          draw();
        }).catch(function (e) {
          state.busy = false;
          state.error = (e && e.message) || 'That didn’t work';
          draw();
        });
    }

    panel.hidden = false;
    if (saveRow) saveRow.hidden = true;
    draw();
    load();
    timer = setInterval(load, PAIR_POLL_MS);
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

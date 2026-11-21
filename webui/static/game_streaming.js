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
  };

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

  // Register the native card so power.js draws it inside the Game Streaming row.
  function register() {
    if (root.JCPower && root.JCPower.native) {
      root.JCPower.native[ID] = Object.assign({}, root.JCPower.native[ID], { card: renderCard });
    }
  }

  if (typeof document !== 'undefined') {
    if (root.JCPower) register();
    else document.addEventListener('DOMContentLoaded', register);
  }
})(this);

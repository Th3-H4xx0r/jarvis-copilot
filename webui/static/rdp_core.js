// Remote Desktop on the web — the pure parts (no DOM): the connect flow, his words for every
// refusal, the 2 GB upload limit, the guac tunnel URL, and the Mac's Microsoft Windows App launch
// (.rdp file / rdp:// URI) with the same readiness and warnings as the iPhone.
// rdp.js draws it; node tests: rdp.test.js. Plan: docs/superpowers/plans/2026-11-15-remote-desktop.md.
(function (root) {
  'use strict';

  var MAX_UPLOAD = 2 * 1024 * 1024 * 1024;
  var IN_USE_IDLE = 120;
  var PASSWORD_REFUSED = 'Windows refused the saved password — update it in Jarvis on the PC (Settings → PC power)';
  // The server already turns guacd's sign-in failures (0x0301 / 0x0207 / "logon failure") into
  // PASSWORD_REFUSED. In the browser 0x0207 also means the tunnel itself dropped, so only 0x0301
  // (CLIENT_UNAUTHORIZED) and that exact message read as a refused password here.
  var AUTH_STATUSES = [0x0301];
  var TUNNEL_STATUSES = [0x0202, 0x0207, 0x0208, 0x0204];

  function copy(code, name) {
    name = name || 'Your PC';
    return {
      asleep: name + ' is asleep',
      offline: name + ' is offline',
      edition: name + ' runs Windows 11 Home. Remote Desktop needs Windows 11 Pro.',
      not_ready: 'Remote Desktop isn’t set up on ' + name + ' yet (Jarvis on the PC → Settings → PC power)',
      no_password: 'Save your Windows password in Jarvis on the PC first (Settings → PC power)',
      web_off: 'Remote Desktop from the web is switched off in its settings',
      password: PASSWORD_REFUSED,
      timeout: 'No answer on your iPhone in 60 seconds',
    }[code] || 'Remote Desktop didn’t start';
  }

  var R = {
    MAX_UPLOAD: MAX_UPLOAD,
    PASSWORD_REFUSED: PASSWORD_REFUSED,
    copy: copy,

    initial: function (name) { return { phase: 'idle', name: name || 'Your PC' }; },

    /**
     * idle → checking → warn (game|in_use) → approving ("Approve on your iPhone") → connecting →
     * connected → ended | error. Returns a new state; unknown events leave it as it is.
     */
    flow: function (s, ev) {
      s = s || R.initial();
      var base = { name: s.name };
      var t = ev && ev.type;
      if (t === 'start') return Object.assign(base, { phase: 'checking', confirm: false });
      if (t === 'cancel' || t === 'ended') return Object.assign(base, { phase: 'ended' });
      if (t === 'created' && s.phase === 'checking') {
        var r = ev.response || {};
        if (r.warn) return Object.assign(base, { phase: 'warn', warn: r.warn, gameName: r.game_name || '' });
        if (r.session && r.session.id) {
          return Object.assign(base, { phase: 'approving', sessionId: r.session.id, expiresAt: r.session.expires_at });
        }
        return R.error(s, r.code || 'failed', r.error);
      }
      if (t === 'confirm' && s.phase === 'warn') return Object.assign(base, { phase: 'checking', confirm: true });
      if (t === 'polled' && s.phase === 'approving') {
        var st = (ev.session || {}).state;
        if (st === 'approved' || st === 'connected') return Object.assign({}, s, { phase: 'connecting' });
        if (st === 'cancelled' || st === 'ended') return R.error(s, 'cancelled', (ev.session || {}).error || copy('timeout'));
        return s;
      }
      if (t === 'timeout' && s.phase === 'approving') return R.error(s, 'timeout');
      if (t === 'tunnel_open' && s.phase === 'connecting') return Object.assign({}, s, { phase: 'connected' });
      if (t === 'tunnel_error' && (s.phase === 'connecting' || s.phase === 'connected')) {
        var status = Number(ev.status);
        if (ev.message === PASSWORD_REFUSED || AUTH_STATUSES.indexOf(status) >= 0) return R.error(s, 'password');
        if (TUNNEL_STATUSES.indexOf(status) >= 0 && s.phase === 'connecting') {
          return R.error(s, 'tunnel', 'Couldn’t reach the Remote Desktop gateway on the server');
        }
        return R.error(s, 'tunnel', ev.message || 'The connection to the PC was lost');
      }
      return s;
    },

    error: function (s, code, message) {
      var out = { name: s.name, phase: 'error', code: code, message: message || copy(code, s.name) };
      if (code === 'asleep') out.action = 'wake';
      return out;
    },

    warnText: function (s) {
      if (s.warn === 'game') {
        return s.name + ' is in a game' + (s.gameName ? ' (' + s.gameName + ')' : '') +
          '. Connecting signs the PC’s screen out; the game keeps running.';
      }
      return 'Someone is using ' + s.name + '. Connecting signs the PC’s screen out.';
    },

    /** null when the file may go, else why not (checked before a byte is sent). */
    checkUpload: function (file) {
      if (file && file.size > MAX_UPLOAD) return file.name + ' is over 2 GB — send it another way';
      return null;
    },

    // Absolute: guacamole-common-js resolves a relative path against the PAGE path, so from a chat
    // (/session/…) it asked /session/api/rdp/guac/… and got the app page instead of the tunnel.
    tunnelPath: function (sid) { return '/api/rdp/guac/' + encodeURIComponent(sid); },

    /** The session size: the stage in device pixels, and its DPI. */
    connectQuery: function (w, h, dpr) {
      var r = dpr > 0 ? dpr : 1;
      return 'w=' + Math.round(w) + '&h=' + Math.round(h) + '&dpi=' + Math.round(96 * r);
    },

    // ── the Mac: Microsoft Windows App ────────────────────────────────────────
    rdpLines: function (st) {
      return [
        ['full address', 's', st.tailscale_ip],
        ['username', 's', st.username],
        ['prompt for credentials', 'i', '0'],
        ['redirectclipboard', 'i', '1'],
        ['audiomode', 'i', '0'],
        ['drivestoredirect', 's', '*'],
        ['dynamic resolution', 'i', '1'],
        ['screen mode id', 'i', '2'],
        ['authentication level', 'i', '2'],
      ];
    },

    /** The .rdp file Windows App opens (CRLF lines, as Microsoft writes them). */
    rdpFile: function (st) {
      return R.rdpLines(st).map(function (l) { return l[0] + ':' + l[1] + ':' + l[2]; }).join('\r\n') + '\r\n';
    },

    /** Microsoft's Remote Desktop URI: rdp://full%20address=s:<ip>&username=s:<user>&… */
    rdpUri: function (st) {
      // ":" after the type letter must be %3A: a bare "s:" reads as a port and macOS rejects the whole URL
      // (open/browsers then do nothing). Windows App decodes it (checked on his Mac 2026-11-16).
      return 'rdp://' + R.rdpLines(st).map(function (l) {
        return encodeURIComponent(l[0]) + '=' + l[1] + '%3A' + encodeURIComponent(String(l[2]));
      }).join('&');
    },

    /** Why the Mac can't open the PC yet (same words as the iPhone), or null. */
    readiness: function (st, name) {
      if (!st) return { code: 'offline', message: copy('offline', name) };
      if (/home/i.test(String(st.edition || ''))) return { code: 'edition', message: copy('edition', name) };
      if (!st.rdp_enabled || !st.tailscale_ip || !st.username) return { code: 'not_ready', message: copy('not_ready', name) };
      return null;
    },

    /** The game / someone-at-the-PC warning from the PC's status (the Mac asks before opening). */
    warnFor: function (st) {
      if (!st) return null;
      if (st.game) return { warn: 'game', game_name: st.game_name || String(st.game).replace(/\.exe$/i, '') };
      if (typeof st.idle_s === 'number' && st.idle_s < IN_USE_IDLE && !st.locked) return { warn: 'in_use' };
      return null;
    },

    /** A real Mac (an iPad reports "Macintosh" too, but has touch points). */
    isMac: function (nav) {
      nav = nav || {};
      return /Macintosh/.test(String(nav.userAgent || '')) && !((nav.maxTouchPoints || 0) > 1);
    },
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = R;
  root.RdpCore = R;
})(this);

// PC Stats on the web — the PC's Agents card numbers and the stats page (look B · Jarvis).
//
// Card: agents.js asks JCPcStats.cardHtml(row) for the Windows row; it shows CPU %, GPU %,
// the hottest temperature and the PC's estimated watts from GET /api/pc-stats/summary, read
// every 5 s while the card is on screen, plus View stats. Offline → "PC offline · last seen …".
//
// Page: a full-screen sheet over the app — header (orb, PC name, online/last seen, Live / 1 h /
// 24 h, dashboard switcher, Edit), the active dashboard on the 12-column grid (one column on a
// narrow window), then history: game sessions (tap → that session's graphs), energy and cost,
// marked moments and the 90-day health trend. GET /live every second only while the page is
// open and the tab visible (that's also what tells the PC someone is watching). Edit mode is
// pc_stats_edit.js. Everything hides while the pc-stats Power integration is off (409s close it).
//
// The active dashboard is this browser's own choice: localStorage["pcStats.active"].
(function (root) {
  'use strict';

  var C = root.JCPcStatsCore;
  if (typeof document === 'undefined' || !C) return;

  var API = '/api/pc-stats';
  var ACTIVE_KEY = 'pcStats.active';
  var LIVE_MS = 1000, CARD_MS = 5000, HIST_REFRESH_MS = 60000;
  var RANGES = { live: 0, '1h': 3600, '24h': 86400 };
  var DEFAULT_WINDOW = 300;
  var SERIES = ['#30D158', '#0A84FF', '#FF9F0A', '#5AC8FA', '#BF5AF2', '#FFD60A'];
  var KIND_NAMES = {
    hero: 'Hero number', number: 'Number', chart: 'Chart', bars: 'Bars', ring: 'Ring',
    sparkline: 'Sparkline', text: 'Text', session: 'Game session', moments: 'Marked moments',
  };

  var S = {
    open: false, el: null, deviceId: '', live: null, liveErr: '', catalog: null, settings: {},
    dashboards: [], active: '', range: 'live', series: {}, moments: [], sessions: [],
    energyPeriod: 'day', energy: null, health: null, healthLoading: false, edit: null,
    hover: null, timers: {}, charts: {}, menu: false, seq: 0,
  };
  var card = { cache: {}, timer: 0 };

  // ── small helpers ──────────────────────────────────────────────────────────
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function on() { return !root.JCPower || root.JCPower.isOn('pc-stats'); }
  function nowSec() { return Date.now() / 1000; }
  function qs(o) {
    return Object.keys(o).filter(function (k) { return o[k] !== undefined && o[k] !== null && o[k] !== ''; })
      .map(function (k) { return encodeURIComponent(k) + '=' + encodeURIComponent(o[k]); }).join('&');
  }
  function get(path, params) {
    var q = qs(Object.assign({ device_id: S.deviceId }, params || {}));
    return root.api(API + path + (q ? '?' + q : ''));
  }
  function storeGet(k) { try { return root.localStorage.getItem(k); } catch (e) { return null; } }
  function storeSet(k, v) { try { root.localStorage.setItem(k, v); } catch (e) { /* private mode */ } }
  function clock(t) { return new Date(t * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }); }
  function day(t) { return new Date(t * 1000).toLocaleDateString([], { weekday: 'short', day: 'numeric', month: 'short' }); }
  function when(t) {
    var d = new Date(t * 1000), today = new Date();
    return d.toDateString() === today.toDateString() ? 'Today ' + clock(t) : day(t) + ' · ' + clock(t);
  }
  function isOff(e) { return e && e.status === 409 && !/changed elsewhere/i.test(e.message || ''); }
  function toast(msg) {
    if (!S.el) { if (typeof root.showToast === 'function') root.showToast(msg); return; }
    var t = S.el.querySelector('.pcs-toast');
    t.textContent = msg;
    t.classList.add('is-on');
    clearTimeout(S.timers.toast);
    S.timers.toast = setTimeout(function () { t.classList.remove('is-on'); }, 3200);
  }
  function narrow() { return root.innerWidth < 760; }

  // ── the Agents card ────────────────────────────────────────────────────────
  function cardInner(id) {
    var s = card.cache[id];
    var btn = '<button type="button" class="agents-pill-btn" data-act="pc-stats" data-device="' + esc(id) + '">View stats</button>';
    if (!s) return '<div class="pcs-card-foot"><span class="agents-sleep-sub">Reading the PC…</span>' + btn + '</div>';
    if (s.error) return '<div class="pcs-card-foot"><span class="agents-sleep-sub">' + esc(s.error) + '</span>' + btn + '</div>';
    var line = C.statusLine({ online: s.online, at: s.at, sample: null }, nowSec());
    if (!s.online) {
      return '<div class="pcs-card-foot"><span class="agents-sleep-sub">' + esc(line) + '</span>' + btn + '</div>';
    }
    return '<div class="pcs-card-cells">' + C.summaryCells(s).map(function (c) {
      return '<div class="pcs-card-cell' + (c.ok ? '' : ' is-na') + '"><b>' + esc(c.num) +
        (c.unit ? '<small>' + esc(c.unit) + '</small>' : '') +
        (c.temp ? '<i class="pcs-card-dot"> · </i>' + esc(c.temp) + '<small class="is-deg">' + esc(c.tempUnit === '°C' ? '°' : c.tempUnit) + '</small>' : '') +
        '</b><span style="color:' + ({ CPU: C.TINTS.cpu, GPU: C.TINTS.gpu }[c.label] || C.TINTS.power) + '">' + esc(c.label) + '</span></div>';
    }).join('') + '</div><div class="pcs-card-foot"><span></span>' + btn + '</div>';
  }

  function cardTick() {
    card.timer = 0;
    if (document.hidden || !on()) return;
    var els = Array.prototype.filter.call(document.querySelectorAll('[data-pcs-card]'),
      function (el) { return el.offsetParent !== null; });
    if (!els.length) return;
    Promise.all(els.map(function (el) {
      var id = el.getAttribute('data-pcs-card');
      return root.api(API + '/summary?' + qs({ device_id: id })).then(function (s) {
        card.cache[id] = s;
      }).catch(function (e) {
        card.cache[id] = isOff(e) ? null : { error: 'Stats unavailable right now' };
        if (isOff(e) && root.JCPower) root.JCPower.refresh();
      }).then(function () {
        if (el.isConnected) el.innerHTML = cardInner(id);
      });
    })).then(function () { if (!card.timer) card.timer = setTimeout(cardTick, CARD_MS); });
  }

  function cardHtml(m) {
    if (!m || !on()) return '';
    if (!card.timer) card.timer = setTimeout(cardTick, card.cache[m.device_id] ? CARD_MS : 50);
    return '<div class="agents-sleep-row pcs-card" data-power="pc-stats" data-pcs-card="' + esc(m.device_id) + '">' +
      cardInner(m.device_id) + '</div>';
  }

  // ── data ───────────────────────────────────────────────────────────────────
  function dash() {
    if (S.edit) return S.edit.draft;
    return S.dashboards.filter(function (d) { return d.id === S.active; })[0] || S.dashboards[0] || null;
  }
  function setActive(id) {
    S.active = id;
    storeSet(ACTIVE_KEY, id);
  }
  function catalogKeys() {
    var keys = Object.keys((S.catalog && S.catalog.readings) || {});
    var r = (S.live && S.live.sample && S.live.sample.r) || {};
    Object.keys(r).forEach(function (k) { if (keys.indexOf(k) < 0 && C.info(k, S.catalog)) keys.push(k); });
    return keys;
  }
  function readCtx(style) {
    style = style || {};
    return { sample: S.live && S.live.sample, catalog: S.catalog, sensorDriver: S.settings.sensor_driver,
      decimals: style.decimals, unit: style.unit };
  }
  function infoOf(key) { return C.info(key, S.catalog) || { label: key, unit: '' }; }

  function loadDashboards() {
    return root.api(API + '/dashboards').then(function (b) {
      S.dashboards = b.dashboards || [];
      var want = storeGet(ACTIVE_KEY);
      if (!S.dashboards.some(function (d) { return d.id === S.active; })) {
        S.active = S.dashboards.some(function (d) { return d.id === want; }) ? want : ((S.dashboards[0] || {}).id || '');
      }
    });
  }

  function pollLive() {
    clearTimeout(S.timers.live);
    if (!S.open || document.hidden) return;
    var seq = S.seq;
    get('/live').then(function (l) {
      if (seq !== S.seq || !S.open) return;
      var prevAt = S.live && S.live.at;
      // the charts' window ends at "last seen" while offline: refetch when that changes
      var refetch = !S.live || !!S.live.online !== !!l.online;
      S.live = l;
      S.liveErr = '';
      if (!S.deviceId && l.device_id) S.deviceId = l.device_id;
      if (refetch) { S.series = {}; loadSeries(); } else if (l.at && l.at !== prevAt) appendLive(l);
      renderHeader();
      renderWidgets();
    }).catch(function (e) {
      if (isOff(e)) { close(); if (typeof root.showToast === 'function') root.showToast('PC Stats is off'); return; }
      S.liveErr = 'Can’t reach the server — retrying';
      renderHeader();
    }).then(function () {
      if (S.open && seq === S.seq) S.timers.live = setTimeout(pollLive, LIVE_MS);
    });
  }

  /** Every chart's (reading, window) and the time range it covers now. */
  function chartWindow(w) {
    var span = RANGES[S.range] || +((w.style || {}).window) || DEFAULT_WINDOW;
    var end = S.live && !S.live.online && S.live.at ? S.live.at : nowSec();
    return { t0: end - span, t1: end, span: span, gap: Math.max(35, 3 * span / 240) };
  }
  function hasChart(w) {
    var st = w.style || {};
    if (w.kind === 'hero') return st.chart !== 'none';
    if (w.kind === 'number') return st.chart === 'area' || st.chart === 'line';
    return w.kind === 'chart' || w.kind === 'sparkline';
  }
  function seriesKey(key, span) { return key + '|' + span + '|' + S.range; }

  function loadSeries(force) {
    var d = dash();
    if (!d || !S.open) return;
    var seq = S.seq;
    var wanted = {};
    d.widgets.forEach(function (w) {
      if (!hasChart(w)) return;
      var win = chartWindow(w);
      (w.kind === 'chart' ? w.readings : w.readings.slice(0, 1)).forEach(function (k) {
        wanted[seriesKey(k, win.span)] = { key: k, win: win };
      });
    });
    Object.keys(wanted).forEach(function (sk) {
      var have = S.series[sk];
      var stale = !have || force || (S.range !== 'live' && Date.now() - have.at > HIST_REFRESH_MS);
      if (!stale || (have && have.loading)) return;
      var item = wanted[sk];
      S.series[sk] = { pts: have ? have.pts : [], at: Date.now(), loading: true };
      get('/history', { key: item.key, from: Math.floor(item.win.t0), to: Math.ceil(item.win.t1), points: 240 })
        .then(function (b) {
          if (seq !== S.seq) return;
          var pts = (b.points || []).map(function (p) { return [p[0], p[1]]; });
          var cur = S.series[sk];
          // keep live samples that arrived while the history was on its way
          (cur ? cur.pts : []).forEach(function (p) { if (!pts.length || p[0] > pts[pts.length - 1][0]) pts.push(p); });
          S.series[sk] = { pts: pts, at: Date.now(), loading: false };
          renderWidgets();
        }).catch(function () { if (S.series[sk]) S.series[sk].loading = false; });
    });
  }

  function appendLive(l) {
    if (S.range !== 'live' || !l.sample) return;
    var r = l.sample.r || {};
    Object.keys(S.series).forEach(function (sk) {
      var parts = sk.split('|');
      if (parts[2] !== 'live') return;
      C.pushLive(S.series[sk].pts, l.at, r[parts[0]], +parts[1]);
    });
  }

  function seriesFor(key, w) {
    var win = chartWindow(w);
    var s = S.series[seriesKey(key, win.span)];
    return { pts: s ? s.pts : [], win: win, loading: !s || (s.loading && !s.pts.length) };
  }

  function loadMoments() {
    var seq = S.seq;
    return get('/moments', { from: Math.floor(nowSec() - 7 * 86400) }).then(function (b) {
      if (seq !== S.seq) return;
      S.moments = b.moments || [];
      renderWidgets();
      renderHistoryPart('moments');
    }).catch(function () { /* the list says it's empty */ });
  }
  function loadSessions() {
    var seq = S.seq;
    return get('/sessions', { limit: 20 }).then(function (b) {
      if (seq !== S.seq) return;
      S.sessions = b.sessions || [];
      renderWidgets();
      renderHistoryPart('sessions');
    }).catch(function () { S.sessions = []; renderHistoryPart('sessions'); });
  }
  function loadEnergy() {
    var seq = S.seq;
    S.energy = null;
    renderHistoryPart('energy');
    return get('/energy', { period: S.energyPeriod }).then(function (b) {
      if (seq !== S.seq) return;
      S.energy = b;
      renderHistoryPart('energy');
    }).catch(function () { S.energy = { buckets: [], error: true }; renderHistoryPart('energy'); });
  }
  function loadHealth() {
    if (S.health || S.healthLoading) return;
    S.healthLoading = true;
    var seq = S.seq;
    var t1 = nowSec(), t0 = t1 - 90 * 86400;
    var r = (S.live && S.live.sample && S.live.sample.r) || {};
    var fans = ['gpu.fan'].concat(Object.keys(r).filter(function (k) { return /^fan\./.test(k); }));
    var keys = ['gpu.temp', 'cpu.temp'].concat(fans);
    Promise.all(keys.map(function (k) {
      return get('/history', { key: k, from: Math.floor(t0), to: Math.ceil(t1), points: 2000 })
        .then(function (b) { return [k, (b.points || []).map(function (p) { return [p[0], p[1]]; })]; })
        .catch(function () { return [k, []]; });
    })).then(function (rows) {
      if (seq !== S.seq) return;
      S.healthLoading = false;
      S.health = { t0: t0, t1: t1, series: {}, fans: fans };
      rows.forEach(function (x) { S.health.series[x[0]] = x[1]; });
      renderHistoryPart('health');
    });
  }

  // ── icons (16 px line glyphs in the category tint) ─────────────────────────
  var ICONS = {
    gpu: '<rect x="1.5" y="4" width="13" height="8" rx="1.8"/><circle cx="6" cy="8" r="1.9"/><path d="M10.2 6.6h2.4M10.2 9.4h2.4M4 12v1.6M7 12v1.6"/>',
    cpu: '<rect x="4" y="4" width="8" height="8" rx="1.6"/><rect x="6.4" y="6.4" width="3.2" height="3.2" rx=".6"/><path d="M6.2 1.8V4M9.8 1.8V4M6.2 12v2.2M9.8 12v2.2M1.8 6.2H4M1.8 9.8H4M12 6.2h2.2M12 9.8h2.2"/>',
    frames: '<path d="M2.3 11.8a6 6 0 1 1 11.4 0"/><path d="M8 10.2l2.8-3.4"/><circle cx="8" cy="10.2" r=".8"/>',
    power: '<path d="M9.2 1.6L3.6 9.1h4.1L6.8 14.4l5.6-7.5H8.3z"/>',
    memory: '<rect x="1.5" y="4.6" width="13" height="6.4" rx="1.2"/><path d="M4.6 7v1.6M7 7v1.6M9.4 7v1.6M11.8 7v1.6M3.6 11v1.8M12.4 11v1.8"/>',
    network: '<path d="M5 2.6v10.6M5 13.2L2.6 10.8M5 13.2l2.4-2.4M11 13.4V2.8M11 2.8L8.6 5.2M11 2.8l2.4 2.4"/>',
    cooling: '<circle cx="8" cy="8" r="1.2"/><path d="M8 6.8C7.3 4.6 7.7 2.1 9.3 2.1s1.4 2.6-.5 4.8M9.2 8c2.2-.7 4.7-.3 4.7 1.3s-2.6 1.4-4.8-.5M8 9.2c.7 2.2.3 4.7-1.3 4.7S5.3 11.3 7.2 9.1M6.8 8C4.6 8.7 2.1 8.3 2.1 6.7S4.7 5.3 6.9 7.2"/>',
    temps: '<path d="M6.4 9.4V3.2a1.6 1.6 0 0 1 3.2 0v6.2a3.1 3.1 0 1 1-3.2 0z"/><path d="M8 6.4v4.4"/>',
    session: '<rect x="1.6" y="5" width="12.8" height="7" rx="3.5"/><path d="M4.4 8.5h2.4M5.6 7.3v2.4"/><circle cx="10.4" cy="7.8" r=".6"/><circle cx="11.8" cy="9.2" r=".6"/>',
    moments: '<path d="M3.5 14V2.5M3.5 3h8l-1.6 2.6L11.5 8.2h-8"/>',
    other: '<circle cx="8" cy="8" r="5.6"/>',
  };
  function icon(fam) { return '<svg class="pcs-ico" viewBox="0 0 16 16" aria-hidden="true">' + (ICONS[fam] || ICONS.other) + '</svg>'; }
  function windowLabel(span) {
    if (span < 3600) return Math.round(span / 60) + ' min';
    if (span < 86400) return Math.round(span / 3600) + ' h';
    return Math.round(span / 86400) === 1 ? '24 h' : Math.round(span / 86400) + ' days';
  }

  // ── charts ─────────────────────────────────────────────────────────────────
  /**
   * A chart: the centred moving average of each series (never raw spikes) on a 0–100 (%) or
   * 0–p98×1.15 scale, faint gridlines with their values at the right edge, moment markers, and
   * (opts.stats) "Min · Avg · Max" of the window underneath. series: [{key, pts, color, unit,
   * label}], mode 'area'|'line'. The plot stretches (viewBox 400×100, non-scaling strokes).
   */
  function chartHtml(id, series, t0, t1, mode, opts) {
    opts = opts || {};
    var W = 400, H = 100;
    var units = {};
    series.forEach(function (s) {
      s.raw = (s.pts || []).filter(function (p) { return p[0] >= t0 && p[0] <= t1; });
      (units[s.unit] = units[s.unit] || []).push(s.raw);
    });
    var doms = {};
    Object.keys(units).forEach(function (u) { doms[u] = C.domain(units[u], u); });
    var defs = '', body = '', labels = '';
    var first = series[0];
    if (first && opts.grid !== false) {
      var dm0 = doms[first.unit];
      C.gridLines(dm0[0], dm0[1]).forEach(function (v) {
        var y = (H - (v - dm0[0]) / (dm0[1] - dm0[0]) * H).toFixed(2);
        body += '<line class="pcs-grid-l" x1="0" x2="' + W + '" y1="' + y + '" y2="' + y + '" vector-effect="non-scaling-stroke"/>';
        labels += '<span class="pcs-gl" style="top:' + (y / H * 100).toFixed(2) + '%">' + esc(C.format(v, first.unit === '%' ? '%' : first.unit, v % 1 ? 1 : 0).num) + '</span>';
      });
    }
    var drawn = false;
    series.forEach(function (s, i) {
      var dm = doms[s.unit];
      var gap = Math.max(opts.gap || 0, 3 * C.medianStep(s.raw));
      var sm = C.smooth(s.raw, C.smoothWindow(s.raw.length), gap);
      var p = C.paths(sm, t0, t1, dm[0], dm[1], W, H, gap);
      if (!p.line) return;
      drawn = true;
      if (mode === 'area' && i === 0) {
        var gid = 'pcsg-' + id.replace(/[^a-z0-9_-]/gi, '') + '-' + i;
        defs += '<linearGradient id="' + gid + '" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="' + s.color +
          '" stop-opacity=".35"/><stop offset="1" stop-color="' + s.color + '" stop-opacity="0"/></linearGradient>';
        body += '<path d="' + p.area + '" fill="url(#' + gid + ')"/>';
      }
      body += '<path class="pcs-line" d="' + p.line + '" fill="none" stroke="' + s.color + '" stroke-width="' +
        (opts.thin ? 1.8 : 2.5) + '" stroke-linejoin="round" stroke-linecap="round" vector-effect="non-scaling-stroke"/>';
    });
    (opts.markers || []).forEach(function (m) {
      if (m.t < t0 || m.t > t1) return;
      var x = ((m.t - t0) / (t1 - t0) * W).toFixed(1);
      body += '<line class="pcs-mark" x1="' + x + '" x2="' + x + '" y1="0" y2="' + H + '" vector-effect="non-scaling-stroke"/>';
    });
    S.charts[id] = { series: series.map(function (s) { return { pts: s.raw, color: s.color, unit: s.unit, label: s.label, decimals: s.decimals }; }), t0: t0, t1: t1 };
    var marks = (opts.markers || []).filter(function (m) { return m.t >= t0 && m.t <= t1; }).map(function (m) {
      return '<span class="pcs-mark-dot" style="left:' + ((m.t - t0) / (t1 - t0) * 100).toFixed(2) + '%" title="' +
        esc(momentText(m)) + '"></span>';
    }).join('');
    var empty = drawn ? '' : '<span class="pcs-chart-empty">' + esc(opts.emptyText || 'No history yet') + '</span>';
    var stats = '';
    if (opts.stats && first) {
      var st = C.stats(first.raw);
      var f = function (v) { return esc(C.format(v, first.unit, first.decimals).num); };
      var unit = C.format(1, first.unit).unit;
      stats = '<div class="pcs-stats num">' + (st
        ? (series.length > 1 ? esc(first.label) + ' · ' : '') + 'Min <b>' + f(st.min) + '</b> · Avg <b>' + f(st.avg) + '</b> · Max <b>' + f(st.max) + '</b>' +
          (unit ? ' <span>' + esc(unit) + '</span>' : '')
        : '&nbsp;') + '</div>';
    }
    return '<div class="pcs-chart-wrap ' + (opts.cls || '') + (labels ? ' has-labels' : '') + '">' +
      '<div class="pcs-plot" data-chart="' + esc(id) + '"><svg class="pcs-chart" viewBox="0 0 ' + W + ' ' + H + '" preserveAspectRatio="none" aria-hidden="true">' +
      (defs ? '<defs>' + defs + '</defs>' : '') + body + '</svg>' + marks + empty + '</div>' +
      (labels ? '<div class="pcs-gls" aria-hidden="true">' + labels + '</div>' : '') + '</div>' + stats;
  }

  function markersFor(keys) {
    return S.moments.filter(function (m) { return keys.indexOf(m.key) >= 0; });
  }
  function momentText(m) {
    var info = infoOf(m.key);
    var f = C.format(m.value, info.unit);
    var th = C.format(m.threshold, info.unit);
    return (m.label || info.label) + (f.num ? ' · ' + f.num + ' ' + f.unit : '') +
      (th.num ? ' (mark at ' + th.num + ' ' + th.unit + ')' : '') + (m.duration_s ? ' · ' + C.duration(m.duration_s) : '');
  }

  function showHover(wrap, clientX) {
    var meta = S.charts[wrap.getAttribute('data-chart')];
    if (!meta) return;
    var rc = wrap.getBoundingClientRect();
    var frac = Math.max(0, Math.min(1, (clientX - rc.left) / Math.max(1, rc.width)));
    var t = meta.t0 + frac * (meta.t1 - meta.t0);
    var rows = meta.series.map(function (s) {
      var p = C.nearest(s.pts, t);
      if (!p || Math.abs(p[0] - t) > (meta.t1 - meta.t0) / 20) return '';
      var f = C.format(p[1], s.unit, s.decimals);
      return '<div><i style="background:' + s.color + '"></i>' + esc(s.label) + ' <b>' + esc(f.num) + ' ' + esc(f.unit) + '</b></div>';
    }).join('');
    var tip = wrap.querySelector('.pcs-tip');
    if (!tip) {
      tip = document.createElement('div');
      tip.className = 'pcs-tip';
      wrap.appendChild(tip);
      var cross = document.createElement('div');
      cross.className = 'pcs-cross';
      wrap.appendChild(cross);
    }
    wrap.querySelector('.pcs-cross').style.left = (frac * 100) + '%';
    tip.innerHTML = '<div class="pcs-tip-t">' + esc(meta.t1 - meta.t0 > 86400 ? day(t) + ' ' + clock(t) : clock(t)) + '</div>' +
      (rows || '<div class="pcs-tip-na">No reading</div>');
    tip.style.left = (frac * 100) + '%';
    tip.classList.toggle('is-left', frac > 0.6);
    S.hover = { id: wrap.getAttribute('data-chart'), x: clientX };
  }
  function clearHover(wrap) {
    S.hover = null;
    if (!wrap) return;
    var a = wrap.querySelector('.pcs-tip'), b = wrap.querySelector('.pcs-cross');
    if (a) a.remove();
    if (b) b.remove();
  }

  // ── widgets ────────────────────────────────────────────────────────────────
  function labelOf(w) {
    var st = w.style || {};
    if (st.label) return st.label;
    if (w.kind === 'session') return 'Game session';
    if (w.kind === 'moments') return 'Marked moments';
    return w.readings[0] ? infoOf(w.readings[0]).label : KIND_NAMES[w.kind];
  }
  /** The widget's tint: its own colour, else its first reading's category (Apple system colours). */
  function tintOf(w) {
    var st = w.style || {};
    if (st.color) return st.color;
    if (w.kind === 'session') return C.TINTS.frames;
    if (w.kind === 'moments') return C.TINTS.temps;
    if (w.kind === 'text' && !w.readings.length) return '#FFFFFF';
    return C.tint(w.readings[0]);
  }
  function famOf(w) {
    if (w.kind === 'session' || w.kind === 'moments') return w.kind;
    return C.family(w.readings[0]);
  }
  function estHtml(key, label) {
    return C.showEst(key, label, S.live && S.live.estimated, S.catalog) ? '<span class="pcs-est" title="Estimated">est.</span>' : '';
  }
  /** Tinted icon + label on the left, secondary context on the right ("Now", "5 min"). */
  function headHtml(w, right, estKey) {
    var label = labelOf(w);
    return '<div class="pcs-head"><span class="pcs-head-l" style="color:' + esc(tintOf(w)) + '">' + icon(famOf(w)) +
      '<span class="pcs-head-t">' + esc(label) + '</span></span>' + (estKey ? estHtml(estKey, label) : '') +
      '<span class="pcs-head-r">' + (right || '') + '</span></div>';
  }
  function plainHead(key, label, right) {
    return '<div class="pcs-head"><span class="pcs-head-l" style="color:' + esc(C.tint(key)) + '">' + icon(C.family(key)) +
      '<span class="pcs-head-t">' + esc(label) + '</span></span>' + estHtml(key, label) + '<span class="pcs-head-r">' + (right || '') + '</span></div>';
  }
  function contextOf(w) { return hasChart(w) ? esc(windowLabel(chartWindow(w).span)) : 'Now'; }

  /** A big value: rounded numerals, small grey unit; °C reads as ° (Apple's way). */
  function valueHtml(key, w, cls, lvl) {
    var st = w.style || {};
    var v = C.read(key, readCtx(st));
    if (!v.ok) {
      return '<div class="' + cls + ' pcs-na" title="' + esc(v.reason) + '">unavailable<small>' + esc(v.reason) + '</small></div>';
    }
    var unit = v.unit === '°C' ? '°' : v.unit;
    return '<div class="' + cls + ' num' + (lvl ? ' is-' + lvl : '') + '">' + esc(v.num) +
      (unit ? '<small' + (unit === '°' ? ' class="is-deg"' : '') + '>' + esc(unit) + '</small>' : '') + '</div>';
  }
  function metaHtml(keys, cls) {
    if (!keys || !keys.length) return '';
    return '<div class="pcs-meta ' + (cls || '') + '">' + keys.map(function (k) {
      var v = C.read(k, readCtx());
      var short = C.shortLabel(k, S.catalog);
      var est = C.showEst(k, short, S.live && S.live.estimated, S.catalog) ? ' <span class="pcs-est">est.</span>' : '';
      if (!v.ok) return '<span class="is-na" title="' + esc(infoOf(k).label + ': ' + v.reason) + '">' + esc(short) + ' unavailable</span>';
      // "1% low 118 fps" · "312 W" · "2.72 GHz" · "67° temp"
      var lead = short === '1% low';
      var unit = v.unit === '°C' ? '°' : v.unit;
      var trail = !lead && short && ['W', 'MHz', 'GHz'].indexOf(v.unit) < 0 ? ' ' + esc(short) : '';
      return '<span title="' + esc(infoOf(k).label) + '">' + (lead ? esc(short) + ' ' : '') + '<b class="num">' + esc(v.num) +
        (unit ? (unit === '°' ? '' : ' ') + esc(unit) : '') + '</b>' + trail + est + '</span>';
    }).join('') + '</div>';
  }
  var EXTRA = ['#FFFFFF', '#8E8E93', '#FF375F', '#AC8E68'];
  function colorOf(w, i) {
    if (i === 0) return tintOf(w);
    var used = [tintOf(w)];
    for (var j = 1; j < i; j++) used.push(colorOf(w, j));
    var c = C.tint(w.readings[i]);
    if (used.indexOf(c) < 0) return c;
    return EXTRA.filter(function (x) { return used.indexOf(x) < 0; })[0] || EXTRA[i % EXTRA.length];
  }

  function widgetChart(w, mode, keys, opts) {
    var series = keys.map(function (k, i) {
      var s = seriesFor(k, w);
      var info = infoOf(k);
      return { key: k, pts: s.pts, color: colorOf(w, i), unit: info.unit, label: info.label, decimals: (w.style || {}).decimals,
        win: s.win, loading: s.loading };
    });
    var win = series.length ? series[0].win : chartWindow(w);
    return chartHtml('w-' + w.id, series, win.t0, win.t1, mode, Object.assign({ gap: win.gap, markers: markersFor(keys),
      emptyText: series.some(function (s) { return s.loading; }) ? ' ' : 'No history yet' }, opts || {}));
  }

  var RENDER = {
    hero: function (w) {
      var key = w.readings[0], st = w.style || {};
      var ht = C.heroTemp(w);
      var lvl = ht.temp ? '' : C.level(C.read(key, readCtx(st)).value, st);
      var big = valueHtml(key, w, 'pcs-hero', lvl);
      if (ht.temp) {
        // "96% · 67°": the temperature at the same size; warn/crit tint it, not the load
        var tl = C.level(C.read(ht.temp, readCtx()).value, st);
        big += '<span class="pcs-hero-sep" aria-hidden="true">·</span>' + valueHtml(ht.temp, { style: { decimals: st.decimals } }, 'pcs-hero pcs-hero-t', tl);
      }
      return headHtml(w, contextOf(w), key) + '<div class="pcs-hero-row">' + big + '</div>' + metaHtml(ht.meta) +
        (st.chart !== 'none' ? widgetChart(w, st.chart === 'line' ? 'line' : 'area', [key], { cls: 'pcs-c-hero', stats: true }) : '');
    },
    number: function (w) {
      var key = w.readings[0], st = w.style || {};
      var lvl = C.level(C.read(key, readCtx(st)).value, st);
      if (!hasChart(w)) {   // no chart: the number sits at the bottom, like an Apple widget
        return headHtml(w, contextOf(w), key) + '<div class="pcs-num-foot">' + valueHtml(key, w, 'pcs-mid pcs-mid-xl', lvl) + metaHtml(st.meta) + '</div>';
      }
      return headHtml(w, contextOf(w), key) + valueHtml(key, w, 'pcs-mid', lvl) + metaHtml(st.meta) +
        widgetChart(w, st.chart, [key], { cls: 'pcs-c-low', grid: false });
    },
    chart: function (w) {
      var st = w.style || {};
      var legend = w.readings.map(function (k, i) {
        var v = C.read(k, readCtx(st));
        var info = infoOf(k);
        var unit = v.unit === '°C' ? '°' : v.unit;
        return '<span class="pcs-legend-i"><i style="background:' + colorOf(w, i) + '"></i>' + esc(w.readings.length > 1 ? C.shortLabel(k, S.catalog) || info.label : info.label) +
          estHtml(k, info.label) + ' <b class="num' + (v.ok ? '' : ' pcs-na') + '">' + esc(v.num) + (v.ok && unit ? (unit === '°' ? '' : ' ') + esc(unit) : '') + '</b></span>';
      }).join('');
      return headHtml(w, contextOf(w)) + '<div class="pcs-legend">' + legend + '</div>' +
        widgetChart(w, st.chart === 'area' ? 'area' : 'line', w.readings, { cls: 'pcs-c-fill', grid: w.h >= 3,
          stats: w.readings.length === 1 && w.h >= 3 });
    },
    bars: function (w) {
      var st = w.style || {};
      var r = (S.live && S.live.sample && S.live.sample.r) || {};
      var meta = st.meta || [];
      var headline = '';
      if (meta.length) {
        var hv = C.read(meta[0], readCtx({ decimals: st.decimals }));
        headline = hv.ok ? '<b class="num">' + esc(hv.num) + '</b> ' + esc(hv.unit === '°C' ? '°' : hv.unit) : '';
      }
      var sib = w.readings.map(function (k) { return r[k]; });
      var rows = w.readings.map(function (k) {
        var info = infoOf(k);
        var v = C.read(k, readCtx(st));
        var lvl = C.level(v.value, st);
        var frac = C.fraction(k, v.value, r, sib, info.unit);
        var unit = v.unit === '°C' ? '°' : v.unit;
        return '<div class="pcs-brow' + (lvl ? ' is-' + lvl : '') + '"><div class="pcs-brow-top"><span class="pcs-bname" title="' + esc(info.label) + '">' +
          esc(barName(k, info)) + estHtml(k, info.label) + '</span>' +
          '<span class="pcs-bval num' + (v.ok ? '' : ' pcs-na') + '" title="' + esc(v.reason) + '">' + esc(v.num) +
          (v.ok && unit ? (unit === '°' ? '' : ' ') + esc(unit) : '') + '</span></div>' +
          '<div class="pcs-btrack"><div class="pcs-bfill" style="width:' + (frac * 100).toFixed(1) + '%"></div></div></div>';
      }).join('');
      return headHtml(w, headline, meta[0]) + '<div class="pcs-bars">' + rows + '</div>' + metaHtml(meta.slice(1), 'is-foot');
    },
    ring: function (w) {
      var key = w.readings[0], st = w.style || {}, label = labelOf(w);
      var info = infoOf(key);
      var v = C.read(key, readCtx(st));
      var lvl = C.level(v.value, st);
      var r = (S.live && S.live.sample && S.live.sample.r) || {};
      var frac = C.fraction(key, v.value, r, [v.value], info.unit);
      // Activity ring: stroke 13% of the diameter, round caps, track = the tint at 20%
      var SW = 13, R = 50 - SW / 2, L = 2 * Math.PI * R, tint = tintOf(w);
      var gid = 'pcsr-' + w.id.replace(/[^a-z0-9_-]/gi, '');
      var unit = v.unit === '°C' ? '°' : v.unit;
      return '<div class="pcs-ring">' +
        '<svg viewBox="0 0 100 100" aria-hidden="true"><defs><linearGradient id="' + gid + '" x1="0" y1="0" x2="1" y2="1">' +
        '<stop offset="0" style="stop-color:color-mix(in srgb, ' + esc(tint) + ' 70%, #fff)"/><stop offset="1" stop-color="' + esc(tint) + '"/></linearGradient></defs>' +
        '<circle cx="50" cy="50" r="' + R + '" fill="none" stroke="' + esc(tint) + '" stroke-opacity=".2" stroke-width="' + SW + '"/>' +
        (frac > 0 ? '<circle cx="50" cy="50" r="' + R + '" class="pcs-ring-arc" fill="none" stroke="url(#' + gid + ')" stroke-width="' + SW +
          '" stroke-linecap="round" stroke-dasharray="' + Math.max(0.01, L * frac).toFixed(2) + ' ' + L.toFixed(2) + '" transform="rotate(-90 50 50)"/>' : '') +
        '</svg><div class="pcs-ring-v">' + (v.ok ? '<b class="num' + (lvl ? ' is-' + lvl : '') + '">' + esc(v.num) + '<small>' + esc(unit) + '</small></b>'
          : '<b class="pcs-na" title="' + esc(v.reason) + '">—</b>') +
        '<span>' + esc(label) + estHtml(key, label) + '</span>' + (v.ok ? '' : '<span class="pcs-ring-na">unavailable</span>') + '</div></div>' +
        // wide cards: ring on the left, the header and value beside it (Fitness-widget style)
        '<div class="pcs-ring-side">' + headHtml(w, '', key) + valueHtml(key, w, 'pcs-mid pcs-mid-xl', lvl) + '</div>';
    },
    sparkline: function (w) {
      var key = w.readings[0], st = w.style || {};
      var lvl = C.level(C.read(key, readCtx(st)).value, st);
      return headHtml(w, contextOf(w), key) + valueHtml(key, w, 'pcs-small', lvl) +
        widgetChart(w, 'line', [key], { cls: 'pcs-c-fill', thin: true, grid: false });
    },
    text: function (w) {
      var st = w.style || {};
      var vals = w.readings.map(function (k) {
        var v = C.read(k, readCtx(st));
        return '<span>' + esc(infoOf(k).label) + ' <b class="num' + (v.ok ? '' : ' pcs-na') + '">' + esc(v.num) +
          (v.ok && v.unit ? ' ' + esc(v.unit) : '') + '</b></span>';
      }).join('');
      return '<div class="pcs-text">' + esc(st.label || (w.readings.length ? '' : 'Text')) + '</div>' +
        (vals ? '<div class="pcs-meta">' + vals + '</div>' : '');
    },
    session: function (w) {
      var game = S.live && S.live.online && S.live.sample && S.live.sample.game;
      if (game) {
        return headHtml(w, 'Now') + '<div class="pcs-mid pcs-ellip">' + esc(game) + '</div>' +
          metaHtml(['fps', 'fps.low1', 'gpu.temp', 'power.total']);
      }
      var s = S.sessions[0];
      if (!s) return headHtml(w, '') + '<div class="pcs-empty-small">No game sessions yet. They appear here when a game runs on the PC.</div>';
      return '<button type="button" class="pcs-session-open" data-pcs="session" data-sid="' + esc(s.id) + '">' +
        headHtml(w, esc(when(s.start))) + '<div class="pcs-mid pcs-ellip">' + esc(s.title || s.exe || 'Game') + '</div>' +
        '<div class="pcs-meta">' + sessionMeta(s) + '</div></button>';
    },
    moments: function (w) {
      var list = S.moments.slice(-12).reverse();
      return headHtml(w, 'Last 7 days') + (list.length ? '<div class="pcs-chips">' + list.map(function (m) {
        return '<span class="pcs-chip" title="' + esc(momentText(m)) + '"><i></i>' + esc(when(m.t)) + ' · ' +
          esc(m.label || infoOf(m.key).label) + '</span>';
      }).join('') + '</div>' : '<div class="pcs-empty-small">Nothing marked in the last 7 days.</div>');
    },
  };
  function barName(k, info) {
    var short = { 'power.gpu': 'GPU', 'power.cpu': 'CPU', 'power.ram': 'RAM', 'power.disk': 'Disk', 'power.net': 'Network',
      'ram.used': 'RAM', 'gpu.vram_used': 'VRAM', 'disk.used': 'Disk C:', 'gpu.fan': 'GPU fan', 'cpu.load': 'CPU', 'gpu.load': 'GPU' }[k];
    return short || info.label;
  }
  function sessionMeta(s) {
    var parts = [];
    if (s.start && s.end) parts.push('<span><b class="num">' + esc(C.duration(s.end - s.start)) + '</b></span>');
    if (typeof s.fps_avg === 'number') parts.push('<span><b class="num">' + Math.round(s.fps_avg) + '</b> fps avg</span>');
    if (typeof s.fps_low1 === 'number') parts.push('<span>1% low <b class="num">' + Math.round(s.fps_low1) + '</b></span>');
    if (typeof s.gpu_temp_max === 'number') parts.push('<span>GPU peak <b class="num">' + Math.round(s.gpu_temp_max) + '°</b></span>');
    if (typeof s.energy_wh === 'number') parts.push('<span><b class="num">' + (s.energy_wh >= 1000 ? (s.energy_wh / 1000).toFixed(2) + ' kWh' : Math.round(s.energy_wh) + ' Wh') + '</b> <span class="pcs-est">est.</span></span>');
    return parts.join('');
  }

  function widgetBody(w) {
    var fn = RENDER[w.kind];
    if (!fn) return headHtml(w, '') + '<div class="pcs-empty-small">This widget kind isn’t known here yet.</div>';
    try { return fn(w); } catch (e) { return headHtml(w, '') + '<div class="pcs-empty-small">Couldn’t draw this widget.</div>'; }
  }
  function widgetFrame(w, idx) {
    var st = w.style || {};
    var styles = 'grid-column:' + (w.x + 1) + ' / span ' + w.w + ';grid-row:' + (w.y + 1) + ' / span ' + w.h +
      ';--h:' + w.h + ';order:' + idx + ';--tint:' + tintOf(w) + ';';
    var editing = !!S.edit;
    return '<div class="pcs-w pcs-k-' + esc(w.kind) + (st.color ? ' has-color' : '') + (editing && S.edit.selected === w.id ? ' is-selected' : '') +
      '" data-wid="' + esc(w.id) + '" style="' + esc(styles) + '"' + (editing ? ' tabindex="0" role="button" aria-label="' +
      esc(labelOf(w)) + ' — drag to move, Enter for settings"' : '') + '><div class="pcs-wb">' + widgetBody(w) + '</div>' +
      (editing ? '<span class="pcs-handle" data-handle="1" aria-hidden="true"></span>' : '') + '</div>';
  }

  // ── rendering ──────────────────────────────────────────────────────────────
  function shell() {
    var el = document.createElement('div');
    el.className = 'pcs';
    el.setAttribute('role', 'dialog');
    el.setAttribute('aria-modal', 'true');
    el.setAttribute('aria-label', 'PC Stats');
    el.setAttribute('data-power', 'pc-stats');
    el.innerHTML =
      '<div class="pcs-scroll">' +
        '<header class="pcs-top" id="pcsTop"></header>' +
        '<div class="pcs-banner" id="pcsBanner" hidden></div>' +
        '<div class="pcs-editbar" id="pcsEditbar" hidden></div>' +
        '<main class="pcs-grid" id="pcsGrid"></main>' +
        '<section class="pcs-history" id="pcsHistory">' +
          '<div class="pcs-h-sec"><div class="pcs-h-head"><h3>Game sessions</h3></div><div id="pcsSessions"></div></div>' +
          '<div class="pcs-h-sec"><div class="pcs-h-head"><h3>Energy &amp; cost</h3><div class="pcs-seg" id="pcsEnergySeg">' +
            ['day', 'week', 'month'].map(function (p) {
              return '<button type="button" data-pcs="energy" data-period="' + p + '">' + { day: 'Day', week: 'Week', month: 'Month' }[p] + '</button>';
            }).join('') + '</div></div><div id="pcsEnergy"></div></div>' +
          '<div class="pcs-h-sec"><div class="pcs-h-head"><h3>Marked moments</h3><span class="pcs-h-sub">Last 7 days</span></div><div id="pcsMoments"></div></div>' +
          '<div class="pcs-h-sec"><div class="pcs-h-head"><h3>Long-term health</h3><span class="pcs-h-sub">90 days</span></div><div id="pcsHealth"></div></div>' +
        '</section>' +
      '</div>' +
      '<div class="pcs-toast" role="status" aria-live="polite"></div>';
    return el;
  }

  function renderHeader() {
    var top = S.el && S.el.querySelector('#pcsTop');
    if (!top) return;
    var l = S.live;
    var name = (l && l.name) || 'Your PC';
    var status = S.liveErr || (l ? C.statusLine(l, nowSec()) : 'Connecting…');
    var d = dash();
    var html =
      '<button type="button" class="pcs-back" data-pcs="close" aria-label="Close PC Stats">‹</button>' +
      '<div class="pcs-id"><h1 class="pcs-name">' + esc(name) + '</h1><div class="pcs-status' +
        (l && !l.online ? ' is-off' : '') + '">' + (l && l.online ? '<i class="pcs-live-dot" aria-hidden="true"></i>' : '') + esc(status) + '</div></div>';
    if (!S.edit) {
      html += '<div class="pcs-pills" role="group" aria-label="Range">' + ['live', '1h', '24h'].map(function (r) {
        return '<button type="button" class="pcs-pill' + (S.range === r ? ' is-on' : '') + '" data-pcs="range" data-range="' + r +
          '" aria-pressed="' + (S.range === r) + '">' + { live: 'Live', '1h': '1 h', '24h': '24 h' }[r] + '</button>';
      }).join('') + '</div>' +
      '<div class="pcs-pills"><div class="pcs-menu-wrap"><button type="button" class="pcs-pill" data-pcs="menu" aria-haspopup="menu" aria-expanded="' +
        S.menu + '">' + esc(d ? d.name : 'Dashboards') + ' <span aria-hidden="true">▾</span></button>' + (S.menu ? menuHtml() : '') + '</div>' +
      '<button type="button" class="pcs-pill" data-pcs="edit"' + (d ? '' : ' disabled') + '>Edit</button></div>';
    }
    if (top._html !== html) { top.innerHTML = html; top._html = html; }
  }

  function menuHtml() {
    return '<div class="pcs-menu" role="menu">' + S.dashboards.map(function (d) {
      return '<button type="button" role="menuitemradio" aria-checked="' + (d.id === S.active) + '" data-pcs="switch" data-id="' + esc(d.id) + '">' +
        '<span class="pcs-check">' + (d.id === S.active ? '✓' : '') + '</span>' + esc(d.name) +
        (d.auto === 'game' ? '<span class="pcs-tag" title="The PC window switches to it while a game runs">Game</span>' : '') + '</button>';
    }).join('') + '<div class="pcs-menu-sep"></div><button type="button" role="menuitem" data-pcs="new-dash">New dashboard…</button></div>';
  }

  function renderWidgets() {
    var grid = S.el && S.el.querySelector('#pcsGrid');
    if (!grid || (S.edit && S.edit.dragging)) return;
    var d = dash();
    if (!d) {
      grid.innerHTML = '<div class="pcs-empty">' + (S.dashboards.length ? '' : 'Loading dashboards…') + '</div>';
      grid._html = '';
      return;
    }
    if (!d.widgets.length && !S.edit) { grid.innerHTML = emptyDash(); grid._html = ''; return; }
    var order = C.reflow(d.widgets);
    var rows = C.rows(d.widgets);
    grid.style.setProperty('--rows', String(Math.max(rows, 1) + (S.edit ? 2 : 0)));
    grid.classList.toggle('is-editing', !!S.edit);
    grid.classList.toggle('is-stale', !!(S.live && S.live.at && !S.live.online));
    var guides = S.edit && !narrow() ? '<div class="pcs-guides" aria-hidden="true">' + new Array(C.COLS + 1).join('<span></span>') + '</div>' : '';
    var waiting = !S.live || !S.live.at ? '<div class="pcs-wait">Waiting for the PC’s first reading. Open the Jarvis app on the PC with PC Stats on; history starts the moment it reports.</div>' : '';
    var html = waiting + guides + order.map(widgetFrame).join('');
    if (grid._html !== html) {
      grid.innerHTML = html;
      grid._html = html;
      if (S.hover) {
        var wrap = grid.querySelector('[data-chart="' + S.hover.id + '"]');
        if (wrap) showHover(wrap, S.hover.x);
      }
    }
  }
  function emptyDash() {
    return '<div class="pcs-empty"><b>This dashboard is empty.</b><span>Choose Edit, then + Widget to add readings.</span></div>';
  }

  function renderAll() {
    renderHeader();
    renderWidgets();
    if (root.JCPcStats.edit) root.JCPcStats.edit.renderBar();
  }

  // ── history ────────────────────────────────────────────────────────────────
  function renderHistoryPart(part) {
    if (!S.el) return;
    if (part === 'sessions') {
      var box = S.el.querySelector('#pcsSessions');
      box.innerHTML = !S.sessions.length ? '<div class="pcs-h-empty">No game sessions yet. Each game you play on the PC is recorded here with its frame rate, temperatures and energy.</div>'
        : '<div class="pcs-list">' + S.sessions.map(function (s) {
          return '<button type="button" class="pcs-row" data-pcs="session" data-sid="' + esc(s.id) + '"><div class="pcs-row-main">' +
            '<span class="pcs-row-title">' + esc(s.title || s.exe || 'Game') + '</span><span class="pcs-row-sub">' + esc(when(s.start)) + '</span></div>' +
            '<div class="pcs-meta">' + sessionMeta(s) + '</div><span class="pcs-row-chev" aria-hidden="true">›</span></button>';
        }).join('') + '</div>';
    } else if (part === 'energy') {
      renderEnergy(S.el.querySelector('#pcsEnergy'));
    } else if (part === 'moments') {
      var mb = S.el.querySelector('#pcsMoments');
      var list = S.moments.slice().reverse();
      mb.innerHTML = !list.length ? '<div class="pcs-h-empty">Nothing marked. Hot GPU or CPU, power spikes and frame drops are marked here and on the graphs — never as notifications.</div>'
        : '<div class="pcs-list">' + list.slice(0, 50).map(function (m) {
          var info = infoOf(m.key);
          var f = C.format(m.value, info.unit), th = C.format(m.threshold, info.unit);
          return '<div class="pcs-row is-static"><span class="pcs-mdot" aria-hidden="true"></span><div class="pcs-row-main">' +
            '<span class="pcs-row-title">' + esc(m.label || info.label) + '</span><span class="pcs-row-sub">' + esc(when(m.t)) +
            (m.duration_s ? ' · ' + esc(C.duration(m.duration_s)) : '') + '</span></div><div class="pcs-meta">' +
            (f.num ? '<span><b class="num">' + esc(f.num) + (f.unit === '°C' ? '°' : ' ' + esc(f.unit)) + '</b></span>' : '') +
            (th.num ? '<span>mark at ' + esc(th.num) + (th.unit === '°C' ? '°' : ' ' + esc(th.unit)) + '</span>' : '') + '</div></div>';
        }).join('') + '</div>';
    } else if (part === 'health') {
      var hb = S.el.querySelector('#pcsHealth');
      if (!S.health) { hb.innerHTML = '<div class="pcs-h-empty">' + (S.healthLoading ? 'Reading 90 days of history…' : '') + '</div>'; return; }
      var h = S.health;
      var temps = [['gpu.temp', 'GPU'], ['cpu.temp', 'CPU']].map(function (x, i) {
        return { key: x[0], pts: h.series[x[0]] || [], color: C.TINTS[i ? 'cpu' : 'gpu'], unit: '°C', label: x[1] };
      });
      var fans = h.fans.map(function (k, i) {
        return { key: k, pts: h.series[k] || [], color: [C.TINTS.cooling, '#FFFFFF', '#8E8E93', C.TINTS.cpu, C.TINTS.gpu][i % 5], unit: 'rpm', label: infoOf(k).label };
      });
      var gap = 3 * 3600;
      hb.innerHTML = '<div class="pcs-h-grid">' +
        '<div class="pcs-panel">' + plainHead('gpu.temp', 'Temperatures', '90 days') + legend(temps) +
          chartHtml('health-t', temps, h.t0, h.t1, 'line', { gap: gap, cls: 'pcs-h-chart', thin: true, markers: markersFor(['gpu.temp', 'cpu.temp']),
            emptyText: 'No temperature history yet', stats: true }) + '</div>' +
        '<div class="pcs-panel">' + plainHead('gpu.fan', 'Fans', '90 days') + legend(fans) +
          chartHtml('health-f', fans, h.t0, h.t1, 'line', { gap: gap, cls: 'pcs-h-chart', thin: true, emptyText: 'No fan history yet', stats: true }) + '</div></div>';
    }
  }
  function legend(series) {
    return '<div class="pcs-legend">' + series.map(function (s) {
      return '<span class="pcs-legend-i"><i style="background:' + s.color + '"></i>' + esc(s.label) + '</span>';
    }).join('') + '</div>';
  }

  function renderEnergy(box) {
    var seg = S.el.querySelectorAll('#pcsEnergySeg button');
    Array.prototype.forEach.call(seg, function (b) {
      b.classList.toggle('is-on', b.getAttribute('data-period') === S.energyPeriod);
      b.setAttribute('aria-pressed', String(b.getAttribute('data-period') === S.energyPeriod));
    });
    var e = S.energy;
    if (!e) { box.innerHTML = '<div class="pcs-h-empty">Loading…</div>'; return; }
    var buckets = e.buckets || [];
    var total = 0, cost = 0, max = 0;
    buckets.forEach(function (b) { total += b.kwh; cost += b.cost; max = Math.max(max, b.kwh); });
    if (!total) {
      box.innerHTML = '<div class="pcs-h-empty">' + (e.error ? 'Couldn’t read the energy history.' : 'No energy recorded yet. It’s worked out from the PC’s estimated watts as it runs.') + '</div>';
      return;
    }
    var fmtLabel = function (t) {
      var d = new Date(t * 1000);
      if (e.period === 'month') return d.toLocaleDateString([], { month: 'short' });
      if (e.period === 'week') return d.toLocaleDateString([], { day: 'numeric', month: 'short' });
      return d.toLocaleDateString([], { weekday: 'narrow' }) + ' ' + d.getDate();
    };
    box.innerHTML =
      '<div class="pcs-energy-head"><div><div class="pcs-mid num">' + total.toFixed(total < 10 ? 2 : 1) + '<small>kWh</small></div>' +
        '<div class="pcs-row-sub">' + { day: 'Last 14 days', week: 'Last 12 weeks', month: 'Last 12 months' }[e.period || S.energyPeriod] + ' · estimated</div></div>' +
        '<div class="pcs-energy-cost"><div class="pcs-mid num">' + esc(C.money(cost, e.currency)) + '</div>' +
        '<div class="pcs-row-sub">' + (e.price ? 'at ' + esc(C.money(e.price, e.currency)) + ' per kWh' : 'Set the electricity price in PC Stats settings') + '</div></div></div>' +
      '<div class="pcs-ebars">' + buckets.map(function (b) {
        var pct = max ? Math.max(b.kwh ? 2 : 0, b.kwh / max * 100) : 0;
        return '<div class="pcs-ebar" title="' + esc(fmtLabel(b.start) + ': ' + b.kwh.toFixed(2) + ' kWh · ' + C.money(b.cost, e.currency)) + '">' +
          '<div class="pcs-ebar-col"><div class="pcs-ecol-fill" style="height:' + pct.toFixed(1) + '%"></div></div>' +
          '<span>' + esc(fmtLabel(b.start)) + '</span></div>';
      }).join('') + '</div>';
  }

  // ── session detail ─────────────────────────────────────────────────────────
  function openSession(id) {
    var s = S.sessions.filter(function (x) { return x.id === id; })[0];
    if (!s) return;
    var t0 = s.start, t1 = s.end || nowSec();
    var keys = [['fps', 'Frame rate'], ['gpu.temp', 'GPU temperature'], ['cpu.temp', 'CPU temperature'], ['power.total', 'PC (est.)']];
    var sheet = openSheet(esc(s.title || s.exe || 'Game session'),
      '<div class="pcs-row-sub">' + esc(when(t0)) + ' – ' + esc(clock(t1)) + ' · ' + esc(C.duration(t1 - t0)) + '</div>' +
      '<div class="pcs-meta pcs-sess-meta">' + sessionMeta(s) +
        (typeof s.watts_avg === 'number' ? '<span><b class="num">' + Math.round(s.watts_avg) + ' W</b> avg <span class="pcs-est">est.</span></span>' : '') +
        (typeof s.watts_max === 'number' ? '<span><b class="num">' + Math.round(s.watts_max) + ' W</b> peak</span>' : '') +
        (typeof s.cpu_temp_max === 'number' ? '<span>CPU peak <b class="num">' + Math.round(s.cpu_temp_max) + '°</b></span>' : '') +
        (s.throttle_s ? '<span><b class="num">' + esc(C.duration(s.throttle_s)) + '</b> throttling</span>' : '') + '</div>' +
      '<div class="pcs-sess-grid">' + keys.map(function (k) {
        return '<div class="pcs-panel" data-skey="' + k[0] + '">' + plainHead(k[0], k[1]) + '<div class="pcs-h-empty">Loading…</div></div>';
      }).join('') + '</div>', 'is-wide');
    var span = Math.max(60, t1 - t0);
    var momentsIn = S.moments.filter(function (m) { return m.t >= t0 && m.t <= t1; });
    keys.forEach(function (k, i) {
      get('/history', { key: k[0], from: Math.floor(t0), to: Math.ceil(t1), points: 300 }).then(function (b) {
        var pts = (b.points || []).map(function (p) { return [p[0], p[1]]; });
        var info = infoOf(k[0]);
        var panel = sheet.querySelector('[data-skey="' + k[0] + '"]');
        if (!panel) return;
        panel.innerHTML = plainHead(k[0], k[1]) +
          chartHtml('sess-' + k[0], [{ key: k[0], pts: pts, color: C.tint(k[0]), unit: info.unit, label: info.label }], t0, t1,
            i === 0 ? 'area' : 'line', { gap: Math.max(35, 3 * span / 300), cls: 'pcs-h-chart', markers: momentsIn.filter(function (m) { return m.key === k[0]; }),
              emptyText: 'Not recorded for this session', stats: true });
      }).catch(function () {
        var panel = sheet.querySelector('[data-skey="' + k[0] + '"]');
        if (panel) panel.innerHTML = plainHead(k[0], k[1]) + '<div class="pcs-h-empty">Couldn’t load this graph.</div>';
      });
    });
  }

  /** A sheet over the page (session detail, widget library, settings). Returns its body element. */
  function openSheet(titleHtml, bodyHtml, cls, onClose) {
    closeSheet();
    var wrap = document.createElement('div');
    wrap.className = 'pcs-sheet-wrap' + (cls ? ' for-' + cls : '');
    wrap.innerHTML = '<div class="pcs-sheet ' + (cls || '') + '" role="dialog" aria-modal="true" aria-label="' +
      esc(titleHtml.replace(/<[^>]+>/g, '')) + '"><div class="pcs-sheet-head"><h3>' + titleHtml + '</h3>' +
      '<button type="button" class="pcs-x" data-pcs="sheet-close" aria-label="Close">✕</button></div>' +
      '<div class="pcs-sheet-body">' + bodyHtml + '</div></div>';
    wrap.addEventListener('pointerdown', function (e) { if (e.target === wrap) closeSheet(); });
    wrap._onClose = onClose;
    S.el.appendChild(wrap);
    var x = wrap.querySelector('.pcs-x');
    if (x) x.focus();
    return wrap.querySelector('.pcs-sheet-body');
  }
  function closeSheet() {
    var w = S.el && S.el.querySelector('.pcs-sheet-wrap');
    if (!w) return false;
    var cb = w._onClose;
    w.remove();
    if (cb) cb();
    return true;
  }

  // ── events ─────────────────────────────────────────────────────────────────
  function onClick(e) {
    var t = e.target.closest('[data-pcs]');
    if (S.menu && (!t || ['menu', 'switch', 'new-dash'].indexOf(t.getAttribute('data-pcs')) < 0)) {
      S.menu = false; renderHeader();
    }
    if (!t || t.disabled) return;
    // while editing, the grid's own buttons (a session card) don't fire: a click selects
    if (S.edit && t.closest('#pcsGrid')) return;
    switch (t.getAttribute('data-pcs')) {
      case 'close': close(); break;
      case 'range':
        S.range = t.getAttribute('data-range');
        S.hover = null;
        renderHeader(); renderWidgets(); loadSeries();
        break;
      case 'menu': S.menu = !S.menu; renderHeader(); break;
      case 'switch':
        S.menu = false;
        setActive(t.getAttribute('data-id'));
        renderAll(); loadSeries();
        break;
      case 'new-dash': S.menu = false; renderHeader(); if (root.JCPcStats.edit) root.JCPcStats.edit.newDashboard(); break;
      case 'edit': if (root.JCPcStats.edit) root.JCPcStats.edit.begin(); break;
      case 'session': openSession(t.getAttribute('data-sid')); break;
      case 'energy': S.energyPeriod = t.getAttribute('data-period'); loadEnergy(); break;
      case 'sheet-close': closeSheet(); break;
      default: if (root.JCPcStats.edit) root.JCPcStats.edit.onClick(t, e);
    }
  }
  function onKey(e) {
    if (e.key !== 'Escape') return;
    if (S.menu) { S.menu = false; renderHeader(); return; }
    if (closeSheet()) return;
    if (S.edit && root.JCPcStats.edit) { root.JCPcStats.edit.cancel(); return; }
    close();
  }
  function onMove(e) {
    var wrap = e.target.closest && e.target.closest('[data-chart]');
    if (wrap && !(S.edit && S.edit.dragging)) showHover(wrap, e.clientX);
  }
  function onLeave(e) {
    var wrap = e.target.closest && e.target.closest('[data-chart]');
    if (wrap && !wrap.contains(e.relatedTarget)) clearHover(wrap);
  }
  function onVisible() {
    if (!S.open) return;
    if (!document.hidden) { pollLive(); loadSeries(); } else clearTimeout(S.timers.live);
  }
  function onResize() {
    if (!S.open) return;
    clearTimeout(S.timers.resize);
    S.timers.resize = setTimeout(function () { S.el.querySelector('#pcsGrid')._html = ''; renderWidgets(); }, 120);
  }

  // ── open / close ───────────────────────────────────────────────────────────
  function open(deviceId) {
    if (!on()) { if (typeof root.showToast === 'function') root.showToast('PC Stats is off'); return; }
    if (S.open) close();
    S.seq++;
    S.open = true;
    S.deviceId = deviceId || '';
    S.live = null; S.liveErr = ''; S.series = {}; S.charts = {}; S.health = null; S.healthLoading = false;
    S.edit = null; S.menu = false; S.range = 'live'; S.hover = null;
    S.el = shell();
    document.body.appendChild(S.el);
    S.el.addEventListener('click', onClick);
    S.el.addEventListener('pointermove', onMove);
    S.el.addEventListener('pointerout', onLeave);
    document.addEventListener('keydown', onKey);
    document.addEventListener('visibilitychange', onVisible);
    root.addEventListener('resize', onResize);
    document.documentElement.classList.add('pcs-lock');
    renderAll();
    renderHistoryPart('sessions'); renderHistoryPart('moments'); renderHistoryPart('health');
    var seq = S.seq;
    Promise.all([
      root.api(API + '/catalog').then(function (c) { S.catalog = c; }).catch(function () { S.catalog = { readings: {} }; }),
      root.api(API + '/settings').then(function (b) { S.settings = b.settings || {}; }).catch(function () { /* defaults */ }),
      loadDashboards().catch(function (e) { if (isOff(e)) throw e; toast('Couldn’t load the dashboards'); }),
    ]).then(function () {
      if (seq !== S.seq) return;
      renderAll();
      loadSeries();
    }).catch(function (e) { if (isOff(e)) close(); });
    pollLive();
    loadMoments(); loadSessions(); loadEnergy();
    var hist = S.el.querySelector('#pcsHealth');
    if (typeof IntersectionObserver === 'function') {
      var io = new IntersectionObserver(function (ents) {
        if (ents.some(function (x) { return x.isIntersecting; })) { io.disconnect(); loadHealth(); renderHistoryPart('health'); }
      }, { root: S.el.querySelector('.pcs-scroll'), rootMargin: '200px' });
      io.observe(hist);
      S.io = io;
    } else loadHealth();
    S.timers.hist = setInterval(function () { if (!document.hidden) { loadSeries(); loadMoments(); } }, HIST_REFRESH_MS);
    var back = S.el.querySelector('.pcs-back');
    if (back) back.focus();
  }

  function close() {
    if (!S.open) return;
    S.open = false;
    S.seq++;
    clearTimeout(S.timers.live); clearInterval(S.timers.hist); clearTimeout(S.timers.toast);
    if (S.io) { S.io.disconnect(); S.io = null; }
    document.removeEventListener('keydown', onKey);
    document.removeEventListener('visibilitychange', onVisible);
    root.removeEventListener('resize', onResize);
    document.documentElement.classList.remove('pcs-lock');
    if (S.el) S.el.remove();
    S.el = null;
    S.edit = null;
  }

  root.JCPcStats = {
    open: open,
    close: close,
    cardHtml: cardHtml,
    // for pc_stats_edit.js
    _page: {
      S: S, esc: esc, dash: dash, setActive: setActive, catalogKeys: catalogKeys, infoOf: infoOf, labelOf: labelOf,
      renderAll: renderAll, renderWidgets: renderWidgets, renderHeader: renderHeader, loadSeries: loadSeries,
      loadDashboards: loadDashboards, openSheet: openSheet, closeSheet: closeSheet, toast: toast, narrow: narrow,
      KIND_NAMES: KIND_NAMES, SERIES: SERIES, API: API,
    },
    edit: null,
  };
})(this);

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
  var SERIES = ['#8fdcff', '#eef2f7', '#5f86a8', '#b6ecd2', '#ffd38a', '#c9b8ff'];
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
        (c.unit ? '<small>' + esc(c.unit) + '</small>' : '') + '</b><span>' + esc(c.label) + '</span></div>';
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

  // ── charts ─────────────────────────────────────────────────────────────────
  /**
   * An SVG chart in a box that stretches (viewBox 400×100, non-scaling strokes). series:
   * [{key, pts, color, unit, label}], mode 'area'|'line'. Markers: moments in range.
   */
  function chartHtml(id, series, t0, t1, mode, opts) {
    opts = opts || {};
    var W = 400, H = 100;
    var units = {};
    series.forEach(function (s) { (units[s.unit] = units[s.unit] || []).push(s.pts); });
    var doms = {};
    Object.keys(units).forEach(function (u) { doms[u] = C.domain(units[u], u); });
    var defs = '', body = '';
    series.forEach(function (s, i) {
      var dm = doms[s.unit];
      var p = C.paths(s.pts, t0, t1, dm[0], dm[1], W, H, Math.max(opts.gap || 0, 3 * C.medianStep(s.pts)));
      if (!p.line) return;
      if (mode === 'area' && i === 0) {
        var gid = 'pcsg-' + id.replace(/[^a-z0-9_-]/gi, '') + '-' + i;
        defs += '<linearGradient id="' + gid + '" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="' + s.color +
          '" stop-opacity=".34"/><stop offset="1" stop-color="' + s.color + '" stop-opacity="0"/></linearGradient>';
        body += '<path d="' + p.area + '" fill="url(#' + gid + ')"/>';
      }
      body += '<path class="pcs-line" d="' + p.line + '" fill="none" stroke="' + s.color + '" stroke-width="' +
        (opts.thin ? 1.4 : 2) + '" vector-effect="non-scaling-stroke"/>';
    });
    (opts.markers || []).forEach(function (m) {
      if (m.t < t0 || m.t > t1) return;
      var x = ((m.t - t0) / (t1 - t0) * W).toFixed(1);
      body += '<line class="pcs-mark" x1="' + x + '" x2="' + x + '" y1="0" y2="' + H + '" vector-effect="non-scaling-stroke"/>';
    });
    S.charts[id] = { series: series, t0: t0, t1: t1 };
    var marks = (opts.markers || []).filter(function (m) { return m.t >= t0 && m.t <= t1; }).map(function (m) {
      return '<span class="pcs-mark-dot" style="left:' + ((m.t - t0) / (t1 - t0) * 100).toFixed(2) + '%" title="' +
        esc(momentText(m)) + '"></span>';
    }).join('');
    var empty = !body.replace(/<line[^>]*>/g, '') ? '<span class="pcs-chart-empty">' + esc(opts.emptyText || 'No history yet') + '</span>' : '';
    return '<div class="pcs-chart-wrap ' + (opts.cls || '') + '" data-chart="' + esc(id) + '">' +
      '<svg class="pcs-chart" viewBox="0 0 ' + W + ' ' + H + '" preserveAspectRatio="none" aria-hidden="true">' +
      (defs ? '<defs>' + defs + '</defs>' : '') + body + '</svg>' + marks + empty + '</div>';
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
  function estHtml(key, label) {
    return C.showEst(key, label, S.live && S.live.estimated, S.catalog) ? '<span class="pcs-est" title="Estimated">est.</span>' : '';
  }
  function valueHtml(key, w, cls) {
    var st = w.style || {};
    var v = C.read(key, readCtx(st));
    if (!v.ok) {
      return '<div class="' + cls + ' pcs-na" title="' + esc(v.reason) + '">unavailable<small>' + esc(v.reason) + '</small></div>';
    }
    return '<div class="' + cls + ' num">' + esc(v.num) + (v.unit ? '<small>' + esc(v.unit) + '</small>' : '') + '</div>';
  }
  function metaHtml(keys, cls) {
    if (!keys || !keys.length) return '';
    return '<div class="pcs-meta ' + (cls || '') + '">' + keys.map(function (k) {
      var v = C.read(k, readCtx());
      var short = C.shortLabel(k, S.catalog);
      var est = C.showEst(k, short, S.live && S.live.estimated, S.catalog) ? ' <span class="pcs-est">est.</span>' : '';
      if (!v.ok) return '<span class="is-na" title="' + esc(infoOf(k).label + ': ' + v.reason) + '">' + esc(short) + ' unavailable</span>';
      // "1% low 118 fps" · "312 W" · "2.72 GHz" · "67 °C temp"
      var lead = short === '1% low';
      var trail = !lead && short && ['W', 'MHz', 'GHz'].indexOf(v.unit) < 0 ? ' ' + esc(short) : '';
      return '<span title="' + esc(infoOf(k).label) + '">' + (lead ? esc(short) + ' ' : '') + '<b class="num">' + esc(v.num) +
        (v.unit ? ' ' + esc(v.unit) : '') + '</b>' + trail + est + '</span>';
    }).join('') + '</div>';
  }
  function colorOf(w, i) {
    var st = w.style || {};
    if (i === 0 && st.color) return st.color;
    return SERIES[i % SERIES.length];
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
      var key = w.readings[0], st = w.style || {}, label = labelOf(w);
      var ht = C.heroTemp(w);
      var big = valueHtml(key, w, 'pcs-hero');
      if (ht.temp) {
        // "96% · 67°C": the temperature at the hero size; warn/crit tint it, not the load
        var tv = C.read(ht.temp, readCtx({ decimals: st.decimals }));
        var lvl = C.level(tv.value, st);
        big = '<div class="pcs-hero-row">' + big + '<span class="pcs-hero-sep" aria-hidden="true">·</span>' +
          (tv.ok ? '<div class="pcs-hero pcs-hero-t num' + (lvl ? ' is-' + lvl : '') + '" title="' + esc(tv.label) + '">' + esc(tv.num) +
            '<small>' + esc(tv.unit) + '</small></div>'
            : '<div class="pcs-hero pcs-hero-t pcs-na" title="' + esc(tv.label + ': ' + tv.reason) + '">temp<small>unavailable</small></div>') + '</div>';
      }
      return '<div class="pcs-lab">' + esc(label) + estHtml(key, label) + '</div>' +
        big + metaHtml(ht.meta) +
        (st.chart !== 'none' ? widgetChart(w, st.chart === 'line' ? 'line' : 'area', [key], { cls: 'pcs-area' }) : '');
    },
    number: function (w) {
      var key = w.readings[0], st = w.style || {}, label = labelOf(w);
      return '<div class="pcs-lab">' + esc(label) + estHtml(key, label) + '</div>' + valueHtml(key, w, 'pcs-mid') +
        metaHtml(st.meta) + (hasChart(w) ? widgetChart(w, st.chart, [key], { cls: 'pcs-area is-low' }) : '');
    },
    chart: function (w) {
      var st = w.style || {};
      var legend = w.readings.map(function (k, i) {
        var v = C.read(k, readCtx(st));
        var info = infoOf(k);
        return '<span class="pcs-legend-i"><i style="background:' + colorOf(w, i) + '"></i>' + esc(info.label) +
          estHtml(k, info.label) + ' <b class="num' + (v.ok ? '' : ' pcs-na') + '">' + esc(v.num) + (v.ok && v.unit ? ' ' + esc(v.unit) : '') + '</b></span>';
      }).join('');
      return '<div class="pcs-lab">' + esc(labelOf(w)) + '</div><div class="pcs-legend">' + legend + '</div>' +
        widgetChart(w, st.chart === 'area' ? 'area' : 'line', w.readings, { cls: 'pcs-fill' });
    },
    bars: function (w) {
      var st = w.style || {};
      var r = (S.live && S.live.sample && S.live.sample.r) || {};
      var meta = st.meta || [];
      var head = meta.length ? valueHtml(meta[0], { style: { decimals: st.decimals } }, 'pcs-mid') : '';
      var sib = w.readings.map(function (k) { return r[k]; });
      var rows = w.readings.map(function (k) {
        var info = infoOf(k);
        var v = C.read(k, readCtx(st));
        var lvl = C.level(v.value, st);
        var frac = C.fraction(k, v.value, r, sib, info.unit);
        return '<div class="pcs-barrow' + (lvl ? ' is-' + lvl : '') + '"><span class="pcs-barname" title="' + esc(info.label) + '">' +
          esc(barName(k, info)) + estHtml(k, info.label) + '</span>' +
          '<div class="pcs-track"><div class="pcs-fill-bar" style="width:' + (frac * 100).toFixed(1) + '%"></div></div>' +
          '<span class="pcs-barval num' + (v.ok ? '' : ' pcs-na') + '" title="' + esc(v.reason) + '">' + esc(v.num) +
          (v.ok && v.unit ? ' ' + esc(v.unit) : '') + '</span></div>';
      }).join('');
      return '<div class="pcs-lab">' + esc(labelOf(w)) + (meta[0] ? estHtml(meta[0], labelOf(w)) : '') + '</div>' + head +
        '<div class="pcs-bars">' + rows + '</div>' + metaHtml(meta.slice(1), 'is-foot');
    },
    ring: function (w) {
      var key = w.readings[0], st = w.style || {}, label = labelOf(w);
      var info = infoOf(key);
      var v = C.read(key, readCtx(st));
      var r = (S.live && S.live.sample && S.live.sample.r) || {};
      var frac = C.fraction(key, v.value, r, [v.value], info.unit);
      var R = 42, L = 2 * Math.PI * R;
      return '<div class="pcs-lab">' + esc(label) + estHtml(key, label) + '</div><div class="pcs-ring">' +
        '<svg viewBox="0 0 100 100" aria-hidden="true"><circle cx="50" cy="50" r="' + R + '" class="pcs-ring-track"/>' +
        '<circle cx="50" cy="50" r="' + R + '" class="pcs-ring-fill" stroke-dasharray="' + (L * frac).toFixed(1) + ' ' + L.toFixed(1) +
        '" transform="rotate(-90 50 50)"/></svg>' +
        '<div class="pcs-ring-v">' + (v.ok ? '<b class="num">' + esc(v.num) + '</b><small>' + esc(v.unit) + '</small>'
          : '<span class="pcs-na" title="' + esc(v.reason) + '">unavailable</span>') + '</div></div>';
    },
    sparkline: function (w) {
      var key = w.readings[0], st = w.style || {}, label = labelOf(w);
      var v = C.read(key, readCtx(st));
      return '<div class="pcs-spark-head"><div class="pcs-lab">' + esc(label) + estHtml(key, label) + '</div>' +
        '<div class="pcs-small num' + (v.ok ? '' : ' pcs-na') + '" title="' + esc(v.reason) + '">' + esc(v.num) +
        (v.ok && v.unit ? '<small>' + esc(v.unit) + '</small>' : '') + '</div></div>' +
        widgetChart(w, 'line', [key], { cls: 'pcs-fill', thin: true });
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
        return '<div class="pcs-lab">' + esc(labelOf(w)) + ' · now</div><div class="pcs-mid pcs-ellip">' + esc(game) + '</div>' +
          metaHtml(['fps', 'fps.low1', 'gpu.temp', 'power.total']);
      }
      var s = S.sessions[0];
      if (!s) return '<div class="pcs-lab">' + esc(labelOf(w)) + '</div><div class="pcs-empty-small">No game sessions yet. They appear here when a game runs on the PC.</div>';
      return '<button type="button" class="pcs-session-open" data-pcs="session" data-sid="' + esc(s.id) + '">' +
        '<div class="pcs-lab">' + esc(labelOf(w)) + ' · last</div><div class="pcs-mid pcs-ellip">' + esc(s.title || s.exe || 'Game') + '</div>' +
        '<div class="pcs-meta">' + sessionMeta(s) + '</div></button>';
    },
    moments: function (w) {
      var list = S.moments.slice(-12).reverse();
      return '<div class="pcs-lab">' + esc(labelOf(w)) + '</div>' + (list.length ? '<div class="pcs-chips">' + list.map(function (m) {
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
    if (typeof s.gpu_temp_max === 'number') parts.push('<span>GPU peak <b class="num">' + Math.round(s.gpu_temp_max) + ' °C</b></span>');
    if (typeof s.energy_wh === 'number') parts.push('<span><b class="num">' + (s.energy_wh >= 1000 ? (s.energy_wh / 1000).toFixed(2) + ' kWh' : Math.round(s.energy_wh) + ' Wh') + '</b> <span class="pcs-est">est.</span></span>');
    return parts.join('');
  }

  function widgetBody(w) {
    var fn = RENDER[w.kind];
    if (!fn) return '<div class="pcs-lab">' + esc(w.kind) + '</div><div class="pcs-empty-small">This widget kind isn’t known here yet.</div>';
    try { return fn(w); } catch (e) { return '<div class="pcs-lab">' + esc(labelOf(w)) + '</div><div class="pcs-empty-small">Couldn’t draw this widget.</div>'; }
  }
  function widgetLevel(w) {
    if (['hero', 'number', 'ring', 'sparkline'].indexOf(w.kind) < 0 || !w.readings[0]) return '';
    var ht = w.kind === 'hero' ? C.heroTemp(w) : null;
    if (ht && ht.temp) {
      var tl = C.level(C.read(ht.temp, readCtx()).value, w.style);
      return tl ? 'temp-' + tl : '';
    }
    return C.level(C.read(w.readings[0], readCtx(w.style)).value, w.style);
  }
  function widgetFrame(w, idx) {
    var st = w.style || {};
    var lvl = widgetLevel(w);
    var styles = 'grid-column:' + (w.x + 1) + ' / span ' + w.w + ';grid-row:' + (w.y + 1) + ' / span ' + w.h +
      ';--h:' + w.h + ';order:' + idx + ';' + (st.color ? '--pcs-c:' + st.color + ';' : '');
    var editing = !!S.edit;
    return '<div class="pcs-w pcs-k-' + esc(w.kind) + (lvl ? ' is-' + lvl : '') + (st.color ? ' has-color' : '') + (editing && S.edit.selected === w.id ? ' is-selected' : '') +
      '" data-wid="' + esc(w.id) + '" style="' + styles + '"' + (editing ? ' tabindex="0" role="button" aria-label="' +
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
      '<div class="pcs-orb' + (l && l.online ? ' is-on' : '') + '" aria-hidden="true"></div>' +
      '<div class="pcs-id"><div class="pcs-name">' + esc(name) + '</div><div class="pcs-status' +
        (l && !l.online ? ' is-off' : '') + '">' + esc(status) + '</div></div>';
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
            (f.num ? '<span><b class="num">' + esc(f.num) + ' ' + esc(f.unit) + '</b></span>' : '') +
            (th.num ? '<span>mark at ' + esc(th.num) + ' ' + esc(th.unit) + '</span>' : '') + '</div></div>';
        }).join('') + '</div>';
    } else if (part === 'health') {
      var hb = S.el.querySelector('#pcsHealth');
      if (!S.health) { hb.innerHTML = '<div class="pcs-h-empty">' + (S.healthLoading ? 'Reading 90 days of history…' : '') + '</div>'; return; }
      var h = S.health;
      var temps = [['gpu.temp', 'GPU'], ['cpu.temp', 'CPU']].map(function (x, i) {
        return { key: x[0], pts: h.series[x[0]] || [], color: SERIES[i], unit: '°C', label: x[1] + ' temperature' };
      });
      var fans = h.fans.map(function (k, i) {
        return { key: k, pts: h.series[k] || [], color: SERIES[i % SERIES.length], unit: 'rpm', label: infoOf(k).label };
      });
      var gap = 3 * 3600;
      hb.innerHTML = '<div class="pcs-h-grid">' +
        '<div class="pcs-panel"><div class="pcs-lab">Temperatures · daily trend</div>' + legend(temps) +
          chartHtml('health-t', temps, h.t0, h.t1, 'line', { gap: gap, cls: 'pcs-h-chart', thin: true, markers: markersFor(['gpu.temp', 'cpu.temp']),
            emptyText: 'No temperature history yet' }) + '</div>' +
        '<div class="pcs-panel"><div class="pcs-lab">Fans</div>' + legend(fans) +
          chartHtml('health-f', fans, h.t0, h.t1, 'line', { gap: gap, cls: 'pcs-h-chart', thin: true, emptyText: 'No fan history yet' }) + '</div></div>';
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
        (typeof s.cpu_temp_max === 'number' ? '<span>CPU peak <b class="num">' + Math.round(s.cpu_temp_max) + ' °C</b></span>' : '') +
        (s.throttle_s ? '<span><b class="num">' + esc(C.duration(s.throttle_s)) + '</b> throttling</span>' : '') + '</div>' +
      '<div class="pcs-sess-grid">' + keys.map(function (k) {
        return '<div class="pcs-panel" data-skey="' + k[0] + '"><div class="pcs-lab">' + esc(k[1]) + '</div><div class="pcs-h-empty">Loading…</div></div>';
      }).join('') + '</div>', 'is-wide');
    var span = Math.max(60, t1 - t0);
    var momentsIn = S.moments.filter(function (m) { return m.t >= t0 && m.t <= t1; });
    keys.forEach(function (k, i) {
      get('/history', { key: k[0], from: Math.floor(t0), to: Math.ceil(t1), points: 300 }).then(function (b) {
        var pts = (b.points || []).map(function (p) { return [p[0], p[1]]; });
        var info = infoOf(k[0]);
        var panel = sheet.querySelector('[data-skey="' + k[0] + '"]');
        if (!panel) return;
        var stats = '';
        if (pts.length) {
          var vals = pts.map(function (p) { return p[1]; });
          var avg = vals.reduce(function (a, b) { return a + b; }, 0) / vals.length;
          var fa = C.format(avg, info.unit), fm = C.format(Math.max.apply(null, vals), info.unit);
          stats = '<div class="pcs-meta"><span>avg <b class="num">' + esc(fa.num) + ' ' + esc(fa.unit) + '</b></span><span>peak <b class="num">' +
            esc(fm.num) + ' ' + esc(fm.unit) + '</b></span></div>';
        }
        panel.innerHTML = '<div class="pcs-lab">' + esc(k[1]) + estHtml(k[0], k[1]) + '</div>' + stats +
          chartHtml('sess-' + k[0], [{ key: k[0], pts: pts, color: SERIES[0], unit: info.unit, label: info.label }], t0, t1,
            i === 0 ? 'area' : 'line', { gap: Math.max(35, 3 * span / 300), cls: 'pcs-h-chart', markers: momentsIn.filter(function (m) { return m.key === k[0]; }),
              emptyText: 'Not recorded for this session' });
      }).catch(function () {
        var panel = sheet.querySelector('[data-skey="' + k[0] + '"]');
        if (panel) panel.innerHTML = '<div class="pcs-lab">' + esc(k[1]) + '</div><div class="pcs-h-empty">Couldn’t load this graph.</div>';
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

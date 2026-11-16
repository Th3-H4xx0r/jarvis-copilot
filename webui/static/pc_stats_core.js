// PC Stats on the web — the pure parts (no DOM): the 12-column grid (snap, overlap, auto-place,
// reflow), how a reading reads (value, unit, "unavailable" with its reason, the "est." badge,
// amber/red), the card's four numbers and the SVG chart paths.
//
// pc_stats.js (the page and the Agents card) and pc_stats_edit.js (edit mode) build on this;
// node tests: pc_stats.test.js. The dashboard model and reading catalog come from the server
// (webui/api/pc_stats_catalog.py, GET /api/pc-stats/catalog).
(function (root) {
  'use strict';

  var COLS = 12;
  var DYNAMIC = /^(fan|temp)\.[a-z0-9_]{1,40}$/;
  var DRIVER_KEYS = { 'cpu.temp': 1, 'cpu.power': 1 };
  var FRAME_KEYS = { fps: 1, 'fps.low1': 1, frametime: 1 };
  var SIZES = {
    hero: [6, 4], number: [3, 2], chart: [6, 4], bars: [4, 4], ring: [3, 2],
    sparkline: [3, 2], text: [4, 1], session: [4, 3], moments: [12, 2],
  };
  var DECIMALS = { '%': 0, '°C': 0, MHz: 0, W: 0, rpm: 0, fps: 0, GB: 1, 'MB/s': 1, ms: 1 };
  // Short words for meta rows ("67 °C temp", "1% low 118").
  var SHORT = {
    'cpu.temp': 'temp', 'gpu.temp': 'temp', 'gpu.hotspot': 'junction', 'gpu.vram_used': 'VRAM',
    'gpu.vram_total': 'VRAM total', 'fps.low1': '1% low', 'ram.used': 'RAM', 'ram.commit': 'commit',
    'disk.used': 'disk', 'disk.read': 'read', 'disk.write': 'write', 'net.down': 'down', 'net.up': 'up',
    'gpu.fan': 'fan', 'power.total': 'PC (est.)', 'cpu.load': 'CPU', 'gpu.load': 'GPU',
  };
  // A bar's "full": its pair, else a sensible top for the unit.
  var PAIRS = { 'ram.used': 'ram.total', 'ram.commit': 'ram.total', 'gpu.vram_used': 'gpu.vram_total' };

  function num(v) { return typeof v === 'number' && isFinite(v); }
  function rect(w) { return { x: w.x | 0, y: w.y | 0, w: Math.max(1, w.w | 0), h: Math.max(1, w.h | 0) }; }

  var C = {
    COLS: COLS,

    // ── grid ────────────────────────────────────────────────────────────────
    overlaps: function (a, b) {
      return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
    },

    /** Inside the grid and clear of every other widget (the one with moved.id is ignored). */
    canPlace: function (widgets, moved, cols) {
      cols = cols || COLS;
      if (moved.x < 0 || moved.y < 0 || moved.w < 1 || moved.h < 1 || moved.x + moved.w > cols) return false;
      for (var i = 0; i < widgets.length; i++) {
        var o = widgets[i];
        if (o.id === moved.id) continue;
        if (C.overlaps(moved, o)) return false;
      }
      return true;
    },

    /** Pulls a rect back onto the grid (never wider than it, never left of 0). */
    clampRect: function (r, cols) {
      cols = cols || COLS;
      var w = Math.min(cols, Math.max(1, Math.round(r.w)));
      var h = Math.max(1, Math.round(r.h));
      var x = Math.min(cols - w, Math.max(0, Math.round(r.x)));
      var y = Math.max(0, Math.round(r.y));
      return { x: x, y: y, w: w, h: h };
    },

    /** Grid steps for a pointer move of px pixels over cells of `cell` px with `gap` px between. */
    steps: function (px, cell, gap) {
      var pitch = cell + (gap || 0);
      return pitch > 0 ? Math.round(px / pitch) : 0;
    },

    /** Where a drag lands: the start rect moved by the pointer delta, snapped and kept on the grid. */
    snapMove: function (start, dx, dy, cellW, cellH, gap, cols) {
      var r = C.clampRect({ x: start.x + C.steps(dx, cellW, gap), y: start.y + C.steps(dy, cellH, gap),
        w: start.w, h: start.h }, cols);
      return r;
    },

    /** A corner-handle resize: the start size plus the pointer delta, snapped, ≥ 1×1, inside the grid. */
    snapResize: function (start, dx, dy, cellW, cellH, gap, cols) {
      cols = cols || COLS;
      var w = Math.max(1, Math.min(cols - start.x, start.w + C.steps(dx, cellW, gap)));
      var h = Math.max(1, start.h + C.steps(dy, cellH, gap));
      return { x: start.x, y: start.y, w: w, h: h };
    },

    /** The first free w×h slot reading rows top to bottom, left to right (below everything if full). */
    autoPlace: function (widgets, w, h, cols) {
      cols = cols || COLS;
      w = Math.min(cols, Math.max(1, w));
      var bottom = 0;
      widgets.forEach(function (o) { bottom = Math.max(bottom, (o.y | 0) + (o.h | 0)); });
      for (var y = 0; y <= bottom; y++) {
        for (var x = 0; x + w <= cols; x++) {
          var r = { id: '\u0000', x: x, y: y, w: w, h: h };
          if (C.canPlace(widgets, r, cols)) return { x: x, y: y };
        }
      }
      return { x: 0, y: bottom };
    },

    /** Reading order for one column (narrow screens): top to bottom, then left to right. */
    reflow: function (widgets) {
      return (widgets || []).slice().sort(function (a, b) { return (a.y - b.y) || (a.x - b.x); });
    },

    /** Rows the grid needs to show every widget. */
    rows: function (widgets) {
      var n = 0;
      (widgets || []).forEach(function (w) { n = Math.max(n, (w.y | 0) + (w.h | 0)); });
      return n;
    },

    defaultSize: function (kind) {
      var s = SIZES[kind] || [3, 2];
      return { w: s[0], h: s[1] };
    },

    /** A widget id not used yet on this dashboard ("cpu", "cpu-2", …). */
    newId: function (base, widgets) {
      base = String(base || 'widget').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || 'widget';
      var used = {};
      (widgets || []).forEach(function (w) { used[w.id] = 1; });
      if (!used[base]) return base;
      for (var i = 2; ; i++) if (!used[base + '-' + i]) return base + '-' + i;
    },

    /** A dashboard id from its name, unique among `taken`. */
    slug: function (name, taken) {
      var s = String(name || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40) || 'dashboard';
      var used = {};
      (taken || []).forEach(function (t) { used[t] = 1; });
      if (!used[s]) return s;
      for (var i = 2; ; i++) if (!used[s + '-' + i]) return s + '-' + i;
    },

    // ── readings ────────────────────────────────────────────────────────────
    /** {label, unit, group, estimated} for a fixed key or a named fan/temperature; null if unknown. */
    info: function (key, catalog) {
      var readings = (catalog && catalog.readings) || catalog || {};
      if (readings[key]) return readings[key];
      if (DYNAMIC.test(String(key))) {
        var parts = String(key).split('.');
        var name = parts[1].replace(/_/g, ' ').replace(/\b\w/g, function (c) { return c.toUpperCase(); });
        return { label: name, unit: parts[0] === 'fan' ? 'rpm' : '°C', group: parts[0] === 'fan' ? 'cooling' : 'temps',
          estimated: false };
      }
      return null;
    },

    shortLabel: function (key, catalog) {
      if (SHORT[key] !== undefined) return SHORT[key];
      var i = C.info(key, catalog);
      return i ? i.label : key;
    },

    /** "12.3" / "2.72 GHz": the number and unit as shown. Decimals: the widget's, else the unit's. */
    format: function (v, unit, decimals) {
      if (!num(v)) return { num: '', unit: unit || '' };
      var d = num(decimals) ? Math.max(0, Math.min(3, decimals | 0)) : null;
      if (unit === 'MHz' && d === null && Math.abs(v) >= 1000) return { num: (v / 1000).toFixed(2), unit: 'GHz' };
      if (d === null) d = DECIMALS[unit] !== undefined ? DECIMALS[unit] : (Math.abs(v) < 10 ? 1 : 0);
      var s = v.toFixed(d);
      if (s === '-0' || /^-0\.0+$/.test(s)) s = s.slice(1);
      return { num: s, unit: unit || '' };
    },

    /** Why a reading isn't in the sample, in his words. */
    reason: function (key, ctx) {
      ctx = ctx || {};
      if (!ctx.hasSample) return 'no readings yet';
      if (ctx.sensorDriver === false && (DRIVER_KEYS[key] || DYNAMIC.test(key))) return 'needs the sensor driver';
      if (FRAME_KEYS[key] && !ctx.game) return 'no game running';
      return 'not reported by this PC';
    },

    /**
     * How one reading reads now: {ok, value, num, unit, label, reason}. A reading the sample
     * doesn't carry is unavailable (never 0).
     * ctx: {sample: {r, game}, catalog, sensorDriver, decimals, unit}
     */
    read: function (key, ctx) {
      ctx = ctx || {};
      var sample = ctx.sample || null;
      var r = (sample && sample.r) || {};
      var info = C.info(key, ctx.catalog) || { label: key, unit: '' };
      var unit = ctx.unit || info.unit || '';
      var v = r[key];
      if (!num(v)) {
        return { ok: false, value: null, num: 'unavailable', unit: '', label: info.label,
          reason: C.reason(key, { hasSample: !!sample, sensorDriver: ctx.sensorDriver, game: sample && sample.game }) };
      }
      var f = C.format(v, unit, ctx.decimals);
      return { ok: true, value: v, num: f.num, unit: f.unit, label: info.label, reason: '' };
    },

    /**
     * A load hero shows its temperature at the same size beside the % ("96% · 67°C"): the
     * temperature from its meta (same part first: gpu.load → gpu.temp), dropped from the meta
     * row; the widget's warn/crit then apply to that temperature. {temp, meta} — temp null if not.
     */
    heroTemp: function (w) {
      var key = (w && w.readings && w.readings[0]) || '';
      var meta = ((w && w.style && w.style.meta) || []).slice();
      if (!/\.load$/.test(key)) return { temp: null, meta: meta };
      var isTemp = function (k) { return /\.temp$/.test(k) || /^temp\./.test(k); };
      var same = key.replace(/\.load$/, '.temp');
      var temp = meta.indexOf(same) >= 0 ? same : (meta.filter(isTemp)[0] || null);
      return { temp: temp, meta: temp ? meta.filter(function (k) { return k !== temp; }) : meta };
    },

    /** Estimated by the PC (this sample's list) or by nature (the catalog). */
    isEstimated: function (key, estimated, catalog) {
      if ((estimated || []).indexOf(key) >= 0) return true;
      var i = C.info(key, catalog);
      return !!(i && i.estimated);
    },

    /** The "est." badge, unless the label already says so ("PC (est.)"). */
    showEst: function (key, label, estimated, catalog) {
      if (/\best\b\.?/i.test(String(label || ''))) return false;
      return C.isEstimated(key, estimated, catalog);
    },

    /** '' | 'warn' | 'crit' from the widget's thresholds (crit wins). */
    level: function (value, style) {
      style = style || {};
      if (!num(value)) return '';
      if (num(style.crit) && value >= style.crit) return 'crit';
      if (num(style.warn) && value >= style.warn) return 'warn';
      return '';
    },

    /** 0–1 fill of a bar/ring: % of 100, a pair's total, W of the PC total, rpm of the fastest. */
    fraction: function (key, value, r, siblings, unit) {
      if (!num(value)) return 0;
      r = r || {};
      var top;
      if (PAIRS[key] && num(r[PAIRS[key]]) && r[PAIRS[key]] > 0) top = r[PAIRS[key]];
      else if (unit === '%') top = 100;
      else if (unit === '°C') top = 100;
      else if (unit === 'W') {
        top = num(r['power.total']) && key !== 'power.total' ? r['power.total'] : 0;
        if (!top) (siblings || []).forEach(function (v) { if (num(v)) top += v; });
      } else if (unit === 'rpm') {
        top = 3000;
        (siblings || []).forEach(function (v) { if (num(v)) top = Math.max(top, v); });
      } else {
        top = 0;
        (siblings || []).forEach(function (v) { if (num(v)) top = Math.max(top, v); });
      }
      if (!(top > 0)) return 0;
      return Math.max(0, Math.min(1, value / top));
    },

    // ── time and the Agents card ────────────────────────────────────────────
    ago: function (seconds) {
      var s = Math.max(0, seconds);
      if (s < 60) return 'just now';
      if (s < 3600) return Math.floor(s / 60) + ' min ago';
      if (s < 86400) return Math.floor(s / 3600) + ' h ago';
      var d = Math.floor(s / 86400);
      return d === 1 ? 'yesterday' : d + ' days ago';
    },

    duration: function (seconds) {
      var s = Math.max(0, Math.round(seconds || 0));
      var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
      if (h) return h + ' h ' + (m ? m + ' min' : '');
      if (m) return m + ' min';
      return s + ' s';
    },

    /** The header/card line: "Online", "Online · Playing X", "PC offline · last seen …". */
    statusLine: function (live, nowSec) {
      if (!live || !live.at) return 'Waiting for the PC’s first reading';
      if (live.online) {
        var g = live.sample && live.sample.game;
        return g ? 'Online · Playing ' + g : 'Online';
      }
      return 'PC offline · last seen ' + C.ago(nowSec - live.at);
    },

    /** The card's numbers from GET /summary: CPU and GPU usage each with its temperature beside it
     *  at the same size (his ask), then watts; a missing one says unavailable (never 0). */
    summaryCells: function (s) {
      s = s || {};
      function cell(label, v, unit, temp) {
        var c = num(v) ? (function () { var f = C.format(v, unit); return { label: label, num: f.num, unit: f.unit, ok: true }; })()
          : { label: label, num: 'unavailable', unit: '', ok: false };
        if (num(temp)) { c.temp = C.format(temp, '°C').num; c.tempUnit = '°C'; }
        return c;
      }
      return [cell('CPU', s.cpu, '%', s.cpu_temp), cell('GPU', s.gpu, '%', s.gpu_temp), cell('PC (est.)', s.watts, 'W')];
    },

    // ── charts ──────────────────────────────────────────────────────────────
    /** [lo, hi] for a set of series: 0–100 for %, else 0 to a little over the top. */
    domain: function (seriesList, unit) {
      if (unit === '%') return [0, 100];
      var hi = -Infinity, lo = Infinity;
      seriesList.forEach(function (pts) {
        pts.forEach(function (p) { if (num(p[1])) { hi = Math.max(hi, p[1]); lo = Math.min(lo, p[1]); } });
      });
      if (!isFinite(hi)) return [0, 1];
      lo = Math.min(0, lo);
      if (hi <= lo) hi = lo + 1;
      return [lo, hi + (hi - lo) * 0.15];
    },

    /**
     * Smoothed SVG path(s) for points [[t, v], …] over [t0, t1] in a w×h box. A gap longer than
     * `gapSec` (the PC was off) breaks the line. Returns {line, area} path strings.
     */
    paths: function (pts, t0, t1, lo, hi, w, h, gapSec) {
      var span = Math.max(1e-9, t1 - t0), range = Math.max(1e-9, hi - lo);
      var segs = [], cur = [], last = null;
      (pts || []).forEach(function (p) {
        if (!num(p[0]) || !num(p[1]) || p[0] < t0 || p[0] > t1) return;
        if (last !== null && gapSec && p[0] - last > gapSec && cur.length) { segs.push(cur); cur = []; }
        var x = (p[0] - t0) / span * w;
        var y = h - (Math.max(lo, Math.min(hi, p[1])) - lo) / range * h;
        cur.push([+x.toFixed(2), +y.toFixed(2)]);
        last = p[0];
      });
      if (cur.length) segs.push(cur);
      var line = '', area = '';
      segs.forEach(function (s) {
        if (s.length === 1) s = [s[0], [Math.min(w, s[0][0] + 1), s[0][1]]];
        var d = 'M' + s[0][0] + ',' + s[0][1];
        for (var i = 1; i < s.length; i++) {
          var cx = +((s[i - 1][0] + s[i][0]) / 2).toFixed(2);
          d += ' C' + cx + ',' + s[i - 1][1] + ' ' + cx + ',' + s[i][1] + ' ' + s[i][0] + ',' + s[i][1];
        }
        line += (line ? ' ' : '') + d;
        area += (area ? ' ' : '') + d + ' L' + s[s.length - 1][0] + ',' + h + ' L' + s[0][0] + ',' + h + ' Z';
      });
      return { line: line, area: area };
    },

    /** Typical spacing of a series (median step) — a gap is only a gap when well beyond it. */
    medianStep: function (pts) {
      var d = [];
      for (var i = 1; i < (pts || []).length; i++) d.push(pts[i][0] - pts[i - 1][0]);
      if (!d.length) return 0;
      d.sort(function (a, b) { return a - b; });
      return d[Math.floor(d.length / 2)];
    },

    /** The point nearest time t (for the hover readout). */
    nearest: function (pts, t) {
      var best = null, bd = Infinity;
      (pts || []).forEach(function (p) { var d = Math.abs(p[0] - t); if (d < bd) { bd = d; best = p; } });
      return best;
    },

    /** Keeps a live series inside its window and adds a sample only when it is newer. */
    pushLive: function (pts, t, v, windowSec) {
      if (!num(t) || !num(v)) return pts;
      if (pts.length && pts[pts.length - 1][0] >= t) return pts;
      pts.push([t, v]);
      var cut = t - windowSec;
      while (pts.length && pts[0][0] < cut) pts.shift();
      return pts;
    },

    /** "$0.31" in his currency (a bad currency code falls back to the number + code). */
    money: function (v, currency) {
      var n = num(v) ? v : 0;
      try {
        return new Intl.NumberFormat(undefined, { style: 'currency', currency: currency || 'USD',
          maximumFractionDigits: n < 1 ? 3 : 2 }).format(n);
      } catch (e) { return n.toFixed(2) + ' ' + (currency || ''); }
    },
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = C;
  root.JCPcStatsCore = C;
})(this);

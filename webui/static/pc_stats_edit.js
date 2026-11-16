// PC Stats on the web — edit mode for the stats page (pc_stats.js).
//
// Works on a copy of the active dashboard: drag a widget to move it and its corner handle to
// resize it (both snap to the 12-column grid; a spot that overlaps another widget is refused),
// "+ Widget" opens the library (kinds × the catalog's readings), clicking a widget opens its
// settings (readings, chart, colour, amber/red thresholds, window, label, decimals, meta), and
// the bar renames the dashboard, sets it as the PC's game dashboard or deletes it. Save →
// PUT /api/pc-stats/dashboards/<id> with the revision it started from; a 409 means it changed
// on another device: that copy is loaded and he's told. Keyboard: arrows move the focused
// widget, Shift+arrows resize it, Enter opens its settings, Delete removes it.
(function (root) {
  'use strict';

  var C = root.JCPcStatsCore;
  var PS = root.JCPcStats;
  if (typeof document === 'undefined' || !C || !PS) return;
  var P = PS._page, S = P.S, esc = P.esc;

  var KIND_HELP = {
    hero: 'Big number, details and a glowing chart', number: 'One reading, large', chart: 'Readings over time',
    bars: 'A breakdown, like power by part', ring: 'A gauge', sparkline: 'A number with a trend line',
    text: 'A heading or note', session: 'The game running now, or the last one', moments: 'Recent marked moments',
    stats: 'Many numbers, each with a tiny trend',
  };
  var NO_READING = { text: 1, session: 1, moments: 1 };
  var MULTI = { chart: 1, bars: 1, text: 1, stats: 1 };
  var CHARTED = { hero: 1, number: 1, chart: 1 };
  var THRESHOLDS = { hero: 1, number: 1, ring: 1, sparkline: 1, bars: 1 };
  var WINDOWED = { hero: 1, number: 1, chart: 1, sparkline: 1, stats: 1 };
  var META = { hero: 1, number: 1, bars: 1 };
  var WINDOWS = [[60, '1 min'], [300, '5 min'], [900, '15 min'], [3600, '1 h'], [21600, '6 h'], [86400, '24 h']];
  // Apple system colours (dark): green, blue, purple, yellow, teal, indigo, cyan, orange, pink, white
  var SWATCHES = ['#30d158', '#0a84ff', '#bf5af2', '#ffd60a', '#64d2ff', '#5e5ce6', '#5ac8fa', '#ff9f0a', '#ff375f', '#ffffff'];
  var GROUPS = { cpu: 'CPU', gpu: 'GPU', frames: 'Frames', memory: 'Memory', disk: 'Disk', network: 'Network',
    power: 'Power', cooling: 'Fans', temps: 'Temperatures' };

  function clone(o) { return JSON.parse(JSON.stringify(o)); }
  function draft() { return S.edit && S.edit.draft; }
  function widget(id) { return (draft() ? draft().widgets : []).filter(function (w) { return w.id === id; })[0] || null; }
  function redraw() {
    var g = S.el && S.el.querySelector('#pcsGrid');
    if (g) g._html = '';
    P.renderWidgets();
  }
  function grouped(keys) {
    var out = {};
    keys.forEach(function (k) {
      var g = P.infoOf(k).group || 'other';
      (out[g] = out[g] || []).push(k);
    });
    return Object.keys(out).map(function (g) { return [GROUPS[g] || g, out[g]]; });
  }

  // ── begin / end ────────────────────────────────────────────────────────────
  function begin() {
    var d = P.dash();
    if (!d || S.edit) return;
    S.edit = { draft: clone(d), selected: null, isNew: false, errors: [] };
    attach();
    P.renderAll();
  }
  function newDashboard() {
    var body = P.openSheet('New dashboard',
      '<form class="pcs-form" data-pcs-form="new-dash"><label class="pcs-field"><span>Name</span>' +
      '<input type="text" name="name" maxlength="40" placeholder="e.g. Racing" required autocomplete="off"></label>' +
      '<div class="pcs-form-actions"><button type="button" class="pcs-btn" data-pcs="sheet-close">Cancel</button>' +
      '<button type="submit" class="pcs-btn is-primary">Create</button></div></form>', 'is-narrow');
    var form = body.querySelector('form');
    var input = form.querySelector('input');
    input.focus();
    form.addEventListener('submit', function (e) {
      e.preventDefault();
      var name = input.value.trim();
      if (!name) return;
      var id = C.slug(name, S.dashboards.map(function (d) { return d.id; }));
      P.closeSheet();
      S.edit = { draft: { id: id, name: name, auto: null, widgets: [] }, selected: null, isNew: true, errors: [] };
      attach();
      P.renderAll();
      openLibrary();
    });
  }
  function cancel() {
    S.edit = null;
    P.closeSheet();
    P.renderAll();
    redraw();
  }

  function save() {
    var d = draft();
    if (!d || S.edit.saving) return;
    if (!d.name || !d.name.trim()) { S.edit.errors = ['Give the dashboard a name.']; renderBar(); return; }
    var body = clone(d);
    var rev = body.rev;
    delete body.rev;
    S.edit.saving = true;
    renderBar();
    root.api(P.API + '/dashboards/' + encodeURIComponent(body.id), { method: 'PUT',
      body: JSON.stringify({ dashboard: body, rev: S.edit.isNew ? null : rev }) })
      .then(function (res) {
        store(res.dashboard);
        P.setActive(res.dashboard.id);
        S.edit = null;
        P.closeSheet();
        P.renderAll(); redraw(); P.loadSeries();
        P.toast('Saved');
      })
      .catch(function (e) {
        if (!S.edit) return;
        S.edit.saving = false;
        var j = {};
        try { j = JSON.parse(e.body || '{}'); } catch (x) { /* not JSON */ }
        if (e.status === 409 && j.dashboard) {
          store(j.dashboard);
          S.edit = null;
          P.closeSheet();
          P.renderAll(); redraw(); P.loadSeries();
          P.toast('Changed elsewhere — reloaded');
          return;
        }
        if (e.status === 409) { cancel(); P.toast('PC Stats is off'); return; }
        S.edit.errors = Array.isArray(j.errors) && j.errors.length ? j.errors : [e.message || 'Couldn’t save'];
        renderBar();
      });
  }
  function store(d) {
    var i = S.dashboards.findIndex(function (x) { return x.id === d.id; });
    if (i >= 0) S.dashboards[i] = d; else S.dashboards.push(d);
  }

  function deleteDashboard() {
    var d = draft();
    if (!d) return;
    if (S.edit.isNew) { cancel(); return; }
    if (S.dashboards.length <= 1) { P.toast('Keep at least one dashboard'); return; }
    if (!root.confirm('Delete the “' + d.name + '” dashboard on every device? This can’t be undone.')) return;
    root.api(P.API + '/dashboards/' + encodeURIComponent(d.id), { method: 'DELETE' }).then(function () {
      S.dashboards = S.dashboards.filter(function (x) { return x.id !== d.id; });
      P.setActive((S.dashboards[0] || {}).id || '');
      S.edit = null;
      P.closeSheet();
      P.renderAll(); redraw(); P.loadSeries();
      P.toast('Dashboard deleted');
    }).catch(function (e) { P.toast(e.message || 'Couldn’t delete it'); });
  }

  // ── the edit bar ───────────────────────────────────────────────────────────
  function renderBar() {
    var bar = S.el && S.el.querySelector('#pcsEditbar');
    if (!bar) return;
    if (!S.edit) { bar.hidden = true; bar.innerHTML = ''; return; }
    var d = draft();
    var focused = document.activeElement && bar.contains(document.activeElement) ? document.activeElement.name : '';
    bar.hidden = false;
    bar.innerHTML =
      '<div class="pcs-editbar-row">' +
        '<input class="pcs-input pcs-name-input" name="dash-name" value="' + esc(d.name) + '" maxlength="40" aria-label="Dashboard name">' +
        '<button type="button" class="pcs-switch" role="switch" data-pcs="auto" aria-checked="' + (d.auto === 'game') + '" ' +
          'title="The PC window switches to this dashboard while a game runs"><span class="pcs-switch-track" aria-hidden="true"></span>Show while gaming</button>' +
        '<span class="pcs-grow"></span>' +
        '<button type="button" class="pcs-btn" data-pcs="add">+ Widget</button>' +
        '<button type="button" class="pcs-btn is-danger" data-pcs="delete-dash">Delete dashboard</button>' +
        '<button type="button" class="pcs-btn" data-pcs="cancel">Cancel</button>' +
        '<button type="button" class="pcs-btn is-primary" data-pcs="save"' + (S.edit.saving ? ' disabled' : '') + '>' +
          (S.edit.saving ? 'Saving…' : 'Save') + '</button>' +
      '</div>' +
      '<div class="pcs-editbar-hint">' + (P.narrow() ? 'Tap a widget to change it. Size and order are in its settings.'
        : 'Drag to move · drag the corner to resize · click for settings') + '</div>' +
      (S.edit.errors && S.edit.errors.length ? '<div class="pcs-errors" role="alert">' + S.edit.errors.map(esc).join('<br>') + '</div>' : '');
    var name = bar.querySelector('[name="dash-name"]');
    name.addEventListener('input', function () { d.name = name.value; });
    if (focused === 'dash-name') { name.focus(); name.setSelectionRange(name.value.length, name.value.length); }
  }

  // ── clicks ─────────────────────────────────────────────────────────────────
  function onClick(t) {
    switch (t.getAttribute('data-pcs')) {
      case 'add': openLibrary(); break;
      case 'save': save(); break;
      case 'cancel': cancel(); break;
      case 'delete-dash': deleteDashboard(); break;
      case 'auto': draft().auto = draft().auto === 'game' ? null : 'game'; renderBar(); break;
      case 'lib-kind': libraryReadings(t.getAttribute('data-kind')); break;
      case 'lib-back': openLibrary(); break;
      case 'lib-add': addWidget(t.getAttribute('data-kind'), t.getAttribute('data-key')); break;
      case 'w-delete': removeWidget(t.getAttribute('data-wid')); break;
      case 'w-color':
        setStyle(t.getAttribute('data-wid'), 'color', t.getAttribute('data-color') || null);
        pick(t);
        break;
      case 'w-chart':
        setStyle(t.getAttribute('data-wid'), 'chart', t.getAttribute('data-chart'));
        pick(t);
        break;
    }
  }

  /** Marks the chosen swatch / segment among its siblings without redrawing the form. */
  function pick(t) {
    Array.prototype.forEach.call(t.parentNode.children, function (b) {
      if (!b.hasAttribute('data-pcs')) return;
      b.classList.toggle('is-on', b === t);
      b.setAttribute('aria-pressed', String(b === t));
    });
  }

  // ── library ────────────────────────────────────────────────────────────────
  function kindIcon(kind) {
    var paths = {
      hero: '<text x="4" y="15" font-size="11" font-weight="700" fill="currentColor">96</text><path d="M2 26 C10 20 14 24 20 18 S30 16 38 12 L38 30 L2 30 Z" fill="currentColor" opacity=".25"/><path d="M2 26 C10 20 14 24 20 18 S30 16 38 12" fill="none" stroke="currentColor" stroke-width="1.6"/>',
      number: '<text x="6" y="22" font-size="15" font-weight="700" fill="currentColor">72°</text>',
      chart: '<path d="M2 24 C8 14 14 22 20 12 S32 18 38 8" fill="none" stroke="currentColor" stroke-width="1.6"/><path d="M2 28 C10 24 16 26 22 22 S34 24 38 20" fill="none" stroke="currentColor" stroke-width="1.2" opacity=".5"/>',
      bars: '<rect x="2" y="7" width="30" height="4" rx="2" fill="currentColor"/><rect x="2" y="15" width="20" height="4" rx="2" fill="currentColor" opacity=".7"/><rect x="2" y="23" width="12" height="4" rx="2" fill="currentColor" opacity=".45"/>',
      ring: '<circle cx="20" cy="16" r="11" fill="none" stroke="currentColor" stroke-width="3" opacity=".25"/><path d="M20 5 A11 11 0 1 1 9 16" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round"/>',
      sparkline: '<text x="2" y="11" font-size="9" font-weight="700" fill="currentColor">38%</text><path d="M2 26 L9 21 L15 24 L22 16 L29 19 L38 13" fill="none" stroke="currentColor" stroke-width="1.4"/>',
      text: '<rect x="2" y="10" width="30" height="4" rx="2" fill="currentColor"/><rect x="2" y="18" width="20" height="3" rx="1.5" fill="currentColor" opacity=".5"/>',
      session: '<rect x="3" y="8" width="34" height="18" rx="4" fill="none" stroke="currentColor" stroke-width="1.6"/><circle cx="12" cy="17" r="2.2" fill="currentColor"/><path d="M25 15 h6 M28 12 v6" stroke="currentColor" stroke-width="1.6"/>',
      stats: '<text x="2" y="10" font-size="8" font-weight="700" fill="currentColor">72°</text><text x="22" y="10" font-size="8" font-weight="700" fill="currentColor">96%</text><path d="M2 16 L6 14 L10 15 L16 12" fill="none" stroke="currentColor" stroke-width="1.2"/><path d="M22 16 L26 13 L30 15 L36 11" fill="none" stroke="currentColor" stroke-width="1.2"/><text x="2" y="28" font-size="8" font-weight="700" fill="currentColor" opacity=".6">5.4</text><text x="22" y="28" font-size="8" font-weight="700" fill="currentColor" opacity=".6">312</text>',
      moments: '<path d="M2 24 C10 18 16 22 22 14 S32 16 38 10" fill="none" stroke="currentColor" stroke-width="1.4" opacity=".6"/><circle cx="22" cy="14" r="3" fill="#f5b14a"/><path d="M22 4 V30" stroke="#f5b14a" stroke-width="1" stroke-dasharray="2 2"/>',
    };
    return '<svg viewBox="0 0 40 32" aria-hidden="true">' + (paths[kind] || '') + '</svg>';
  }
  function openLibrary() {
    var kinds = (S.catalog && S.catalog.widget_kinds) || Object.keys(P.KIND_NAMES);
    P.openSheet('Add a widget', '<div class="pcs-lib">' + kinds.map(function (k) {
      return '<button type="button" class="pcs-lib-kind" data-pcs="lib-kind" data-kind="' + esc(k) + '">' + kindIcon(k) +
        '<b>' + esc(P.KIND_NAMES[k] || k) + '</b><span>' + esc(KIND_HELP[k] || '') + '</span></button>';
    }).join('') + '</div>', 'is-wide');
  }
  function libraryReadings(kind) {
    if (NO_READING[kind]) { addWidget(kind, ''); return; }
    var r = (S.live && S.live.sample && S.live.sample.r) || {};
    var body = P.openSheet('<button type="button" class="pcs-x is-back" data-pcs="lib-back" aria-label="Back">‹</button>' +
      esc(P.KIND_NAMES[kind] || kind) + ' · choose a reading',
      '<input class="pcs-input pcs-search" type="search" placeholder="Search readings" aria-label="Search readings">' +
      '<div class="pcs-lib-readings">' + grouped(P.catalogKeys().filter(function (k) { return MULTI[kind] || !/\*$/.test(k); })).map(function (g) {
        return '<div class="pcs-lib-group"><div class="pcs-lib-gname">' + esc(g[0]) + '</div>' + g[1].map(function (k) {
          var info = P.infoOf(k);
          var v = C.read(k, { sample: S.live && S.live.sample, catalog: S.catalog, sensorDriver: S.settings.sensor_driver });
          return '<button type="button" class="pcs-lib-reading" data-pcs="lib-add" data-kind="' + esc(kind) + '" data-key="' + esc(k) +
            '" data-search="' + esc((info.label + ' ' + k + ' ' + g[0]).toLowerCase()) + '"><span>' + esc(info.label) +
            (info.estimated ? ' <span class="pcs-est">est.</span>' : '') + '</span><small class="' + (k in r ? '' : 'pcs-na') + '">' +
            esc(/\*$/.test(k) ? C.expand([k], S.live && S.live.sample).length + ' now' : v.ok ? v.num + (v.unit ? ' ' + v.unit : '') : (S.live && S.live.at ? 'not reported' : info.unit)) + '</small></button>';
        }).join('') + '</div>';
      }).join('') + '</div>', 'is-wide');
    var search = body.querySelector('.pcs-search');
    search.focus();
    search.addEventListener('input', function () {
      var q = search.value.trim().toLowerCase();
      body.querySelectorAll('.pcs-lib-reading').forEach(function (b) {
        b.hidden = !!q && b.getAttribute('data-search').indexOf(q) < 0;
      });
      body.querySelectorAll('.pcs-lib-group').forEach(function (g) {
        g.hidden = !g.querySelector('.pcs-lib-reading:not([hidden])');
      });
    });
  }
  function addWidget(kind, key) {
    var d = draft();
    if (!d) return;
    if (d.widgets.length >= 64) { P.toast('A dashboard holds up to 64 widgets'); return; }
    var size = C.defaultSize(kind);
    var at = C.autoPlace(d.widgets, size.w, size.h);
    var style = {};
    if (kind === 'hero') style.chart = 'area';
    if (kind === 'chart') { style.chart = 'line'; style.window = 300; }
    if (kind === 'text') style.label = 'Heading';
    var w = { id: C.newId(key ? key.split('.').pop() === 'load' ? key.split('.')[0] : key.replace('.', '-') : kind, d.widgets),
      kind: kind, x: at.x, y: at.y, w: Math.min(C.COLS, size.w), h: size.h, readings: key ? [key] : [], style: style };
    d.widgets.push(w);
    S.edit.selected = w.id;
    redraw();
    P.loadSeries();
    openSettings(w.id);
    var el = S.el.querySelector('[data-wid="' + w.id + '"]');
    if (el && el.scrollIntoView) el.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  }
  function removeWidget(id) {
    var d = draft();
    d.widgets = d.widgets.filter(function (w) { return w.id !== id; });
    S.edit.selected = null;
    P.closeSheet();
    redraw();
  }

  // ── widget settings ────────────────────────────────────────────────────────
  function setStyle(id, key, value) {
    var w = widget(id);
    if (!w) return;
    w.style = w.style || {};
    if (value === null || value === undefined || value === '' || (typeof value === 'number' && !isFinite(value))) delete w.style[key];
    else w.style[key] = value;
    redraw();
    if (key === 'window' || key === 'chart') P.loadSeries();
  }
  function readingOptions(selected, keys) {
    keys = keys.filter(function (k) { return !/\*$/.test(k); });
    return grouped(keys).map(function (g) {
      return '<optgroup label="' + esc(g[0]) + '">' + g[1].map(function (k) {
        return '<option value="' + esc(k) + '"' + (k === selected ? ' selected' : '') + '>' + esc(P.infoOf(k).label) + '</option>';
      }).join('') + '</optgroup>';
    }).join('');
  }
  function checklist(name, chosen, keys) {
    return '<div class="pcs-checks" data-check="' + name + '">' + grouped(keys).map(function (g) {
      return '<div class="pcs-lib-gname">' + esc(g[0]) + '</div>' + g[1].map(function (k) {
        return '<label class="pcs-check-row"><input type="checkbox" value="' + esc(k) + '"' + (chosen.indexOf(k) >= 0 ? ' checked' : '') + '>' +
          '<span>' + esc(P.infoOf(k).label) + '</span></label>';
      }).join('');
    }).join('') + '</div>';
  }

  function openSettings(id) {
    var w = widget(id);
    if (!w) return;
    S.edit.selected = id;
    var st = w.style || {};
    var keys = P.catalogKeys();
    w.readings.forEach(function (k) { if (keys.indexOf(k) < 0) keys.push(k); });
    var f = [];
    f.push('<label class="pcs-field"><span>Label</span><input class="pcs-input" data-f="label" maxlength="60" value="' +
      esc(st.label || '') + '" placeholder="' + esc(w.readings[0] ? P.infoOf(w.readings[0]).label : P.KIND_NAMES[w.kind]) + '"></label>');
    if (!NO_READING[w.kind] || w.kind === 'text') {
      if (MULTI[w.kind]) f.push('<div class="pcs-field"><span>Readings</span>' + checklist('readings', w.readings, keys) + '</div>');
      else f.push('<label class="pcs-field"><span>Reading</span><select class="pcs-input" data-f="reading">' + readingOptions(w.readings[0], keys) + '</select></label>');
    }
    if (CHARTED[w.kind]) {
      var cur = st.chart || (w.kind === 'hero' ? 'area' : (w.kind === 'chart' ? 'line' : 'none'));
      f.push('<div class="pcs-field"><span>Chart</span><div class="pcs-seg">' + ['area', 'line', 'none'].map(function (c) {
        return '<button type="button" data-pcs="w-chart" data-wid="' + esc(id) + '" data-chart="' + c + '" class="' + (cur === c ? 'is-on' : '') +
          '" aria-pressed="' + (cur === c) + '">' + { area: 'Area', line: 'Line', none: 'None' }[c] + '</button>';
      }).join('') + '</div></div>');
    }
    if (WINDOWED[w.kind]) {
      var win = +st.window || 300;
      f.push('<label class="pcs-field"><span>Time window <small>(Live)</small></span><select class="pcs-input" data-f="window">' + WINDOWS.map(function (o) {
        return '<option value="' + o[0] + '"' + (o[0] === win ? ' selected' : '') + '>' + o[1] + '</option>';
      }).join('') + '</select></label>');
    }
    if (w.kind !== 'session' && w.kind !== 'moments' && w.kind !== 'text') {
      f.push('<div class="pcs-field"><span>Colour</span><div class="pcs-swatches">' +
        '<button type="button" class="pcs-swatch is-default' + (!st.color ? ' is-on' : '') + '" data-pcs="w-color" data-wid="' + esc(id) + '" data-color="" title="Category colour">A</button>' +
        SWATCHES.map(function (c) {
          return '<button type="button" class="pcs-swatch' + (st.color && st.color.toLowerCase() === c ? ' is-on' : '') + '" style="--sw:' + c +
            '" data-pcs="w-color" data-wid="' + esc(id) + '" data-color="' + c + '" aria-label="Colour ' + c + '"></button>';
        }).join('') + '<input type="color" class="pcs-color" data-f="color" value="' + esc(st.color || '#0a84ff') + '" aria-label="Custom colour"></div></div>');
    }
    if (THRESHOLDS[w.kind]) {
      f.push('<div class="pcs-field-row"><label class="pcs-field"><span>Amber at</span><input class="pcs-input" type="number" step="any" data-f="warn" value="' +
        esc(st.warn == null ? '' : st.warn) + '" placeholder="Off"></label><label class="pcs-field"><span>Red at</span><input class="pcs-input" type="number" step="any" data-f="crit" value="' +
        esc(st.crit == null ? '' : st.crit) + '" placeholder="Off"></label></div>');
    }
    if (w.kind !== 'session' && w.kind !== 'moments') {
      f.push('<label class="pcs-field"><span>Decimals</span><select class="pcs-input" data-f="decimals">' + ['', 0, 1, 2, 3].map(function (n) {
        return '<option value="' + n + '"' + (String(st.decimals == null ? '' : st.decimals) === String(n) ? ' selected' : '') + '>' + (n === '' ? 'Automatic' : n) + '</option>';
      }).join('') + '</select></label>');
    }
    if (META[w.kind]) f.push('<div class="pcs-field"><span>' + (w.kind === 'bars' ? 'Headline and details' : 'Details row') + '</span>' + checklist('meta', st.meta || [], keys) + '</div>');
    f.push('<div class="pcs-field-row"><label class="pcs-field"><span>Width</span><input class="pcs-input" type="number" min="1" max="12" data-f="w" value="' + w.w +
      '"></label><label class="pcs-field"><span>Height</span><input class="pcs-input" type="number" min="1" max="24" data-f="h" value="' + w.h + '"></label></div>');
    f.push('<div class="pcs-form-actions"><button type="button" class="pcs-btn is-danger" data-pcs="w-delete" data-wid="' + esc(id) + '">Delete widget</button>' +
      '<button type="button" class="pcs-btn is-primary" data-pcs="sheet-close">Done</button></div>');

    var body = P.openSheet(esc(P.KIND_NAMES[w.kind] || w.kind) + ' settings', '<div class="pcs-form">' + f.join('') + '</div>', 'is-side', function () {
      if (S.edit) { S.edit.selected = null; redraw(); }
    });
    redraw();
    body.addEventListener('change', function (e) { onField(id, e.target, true); });
    body.addEventListener('input', function (e) { if (e.target.matches('[data-f="label"],[data-f="color"]')) onField(id, e.target, false); });
  }

  function onField(id, el, final) {
    var w = widget(id);
    if (!w) return;
    var f = el.getAttribute('data-f');
    var check = el.closest('[data-check]');
    if (check) {
      var vals = Array.prototype.map.call(check.querySelectorAll('input:checked'), function (i) { return i.value; });
      if (check.getAttribute('data-check') === 'readings') {
        if (!vals.length && w.kind !== 'text') { el.checked = true; P.toast('Keep at least one reading'); return; }
        w.readings = vals;
        redraw(); P.loadSeries();
      } else setStyle(id, 'meta', vals.length ? vals : null);
      return;
    }
    if (f === 'label') setStyle(id, 'label', el.value.trim() || null);
    else if (f === 'reading') { w.readings = [el.value]; redraw(); P.loadSeries(); }
    else if (f === 'window') setStyle(id, 'window', parseInt(el.value, 10));
    else if (f === 'color') setStyle(id, 'color', el.value);
    else if (f === 'warn' || f === 'crit') setStyle(id, f, el.value === '' ? null : parseFloat(el.value));
    else if (f === 'decimals') setStyle(id, 'decimals', el.value === '' ? null : parseInt(el.value, 10));
    else if (f === 'w' || f === 'h') {
      var n = parseInt(el.value, 10);
      if (!(n >= 1)) { el.value = w[f]; return; }
      var next = { id: w.id, x: w.x, y: w.y, w: w.w, h: w.h };
      next[f] = n;
      if (f === 'w' && next.x + next.w > C.COLS) next.x = Math.max(0, C.COLS - next.w);
      next.w = Math.min(C.COLS, next.w);
      if (!C.canPlace(draft().widgets, next)) { el.value = w[f]; P.toast('That would overlap another widget'); return; }
      w.x = next.x; w.w = next.w; w.h = next.h;
      redraw();
    }
    if (f === 'color') {
      Array.prototype.forEach.call(el.parentNode.querySelectorAll('.pcs-swatch'), function (b) { b.classList.remove('is-on'); });
    }
  }

  // ── drag, resize, keyboard ─────────────────────────────────────────────────
  var drag = null;

  function attach() {
    if (!S.el || S.el._pcsEdit) return;
    S.el._pcsEdit = true;
    var grid = S.el.querySelector('#pcsGrid');
    grid.addEventListener('pointerdown', onDown);
    grid.addEventListener('keydown', onKey);
  }
  function metrics(grid) {
    var cs = root.getComputedStyle(grid);
    var gapX = parseFloat(cs.columnGap) || 0, gapY = parseFloat(cs.rowGap) || 0;
    var inner = grid.clientWidth - (parseFloat(cs.paddingLeft) || 0) - (parseFloat(cs.paddingRight) || 0);
    return { cellW: (inner - gapX * (C.COLS - 1)) / C.COLS, cellH: parseFloat(cs.gridAutoRows) || 64, gapX: gapX, gapY: gapY };
  }

  function onDown(e) {
    if (!S.edit || e.button !== 0) return;
    var el = e.target.closest('.pcs-w');
    if (!el) return;
    var w = widget(el.getAttribute('data-wid'));
    if (!w) return;
    var resize = !!e.target.closest('[data-handle]');
    e.preventDefault();
    drag = { w: w, el: el, resize: resize, start: { x: w.x, y: w.y, w: w.w, h: w.h }, px: e.clientX, py: e.clientY,
      moved: false, cand: null, m: metrics(el.parentNode), id: e.pointerId };
    try { el.setPointerCapture(e.pointerId); } catch (x) { /* old browser */ }
    el.addEventListener('pointermove', onDrag);
    el.addEventListener('pointerup', onUp);
    el.addEventListener('pointercancel', onUp);
  }
  function onDrag(e) {
    if (!drag) return;
    var dx = e.clientX - drag.px, dy = e.clientY - drag.py;
    if (!drag.moved && Math.hypot(dx, dy) < 5) return;
    if (P.narrow()) return;   // one column: sizes and order live in the settings
    if (!drag.moved) {
      drag.moved = true;
      S.edit.dragging = true;
      drag.el.classList.add(drag.resize ? 'is-resizing' : 'is-dragging');
      drag.ghost = document.createElement('div');
      drag.ghost.className = 'pcs-ghost';
      drag.el.parentNode.appendChild(drag.ghost);
    }
    var m = drag.m;
    // rows and columns have different gaps; steps use each axis's own pitch
    var cand = drag.resize
      ? C.snapResize(drag.start, dx, 0, m.cellW, m.cellH, m.gapX)
      : C.snapMove(drag.start, dx, 0, m.cellW, m.cellH, m.gapX);
    var ry = C.steps(dy, m.cellH, m.gapY);
    if (drag.resize) cand.h = Math.max(1, drag.start.h + ry); else cand.y = Math.max(0, drag.start.y + ry);
    drag.cand = cand;
    var ok = C.canPlace(draft().widgets, { id: drag.w.id, x: cand.x, y: cand.y, w: cand.w, h: cand.h });
    drag.ok = ok;
    var g = drag.ghost.style;
    g.gridColumn = (cand.x + 1) + ' / span ' + cand.w;
    g.gridRow = (cand.y + 1) + ' / span ' + cand.h;
    drag.ghost.classList.toggle('is-bad', !ok);
    var grid = drag.el.parentNode;
    var rows = Math.max(C.rows(draft().widgets), cand.y + cand.h) + 2;
    grid.style.setProperty('--rows', String(rows));
    if (drag.resize) {
      drag.el.style.gridColumn = (cand.x + 1) + ' / span ' + cand.w;
      drag.el.style.gridRow = (cand.y + 1) + ' / span ' + cand.h;
    } else {
      drag.el.style.transform = 'translate(' + dx + 'px,' + dy + 'px)';
    }
  }
  function onUp(e) {
    if (!drag) return;
    var d = drag;
    drag = null;
    d.el.removeEventListener('pointermove', onDrag);
    d.el.removeEventListener('pointerup', onUp);
    d.el.removeEventListener('pointercancel', onUp);
    try { d.el.releasePointerCapture(d.id); } catch (x) { /* gone */ }
    if (d.ghost) d.ghost.remove();
    if (!S.edit) return;
    S.edit.dragging = false;
    if (!d.moved) {
      if (e.type === 'pointerup') openSettings(d.w.id);
      return;
    }
    if (d.cand && d.ok) {
      d.w.x = d.cand.x; d.w.y = d.cand.y; d.w.w = d.cand.w; d.w.h = d.cand.h;
    } else if (d.cand) {
      P.toast('That spot is taken');
    }
    redraw();
  }

  function onKey(e) {
    if (!S.edit) return;
    var el = e.target.closest && e.target.closest('.pcs-w');
    if (!el || el !== e.target) return;
    var w = widget(el.getAttribute('data-wid'));
    if (!w) return;
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); openSettings(w.id); return; }
    if (e.key === 'Delete' || e.key === 'Backspace') { e.preventDefault(); removeWidget(w.id); return; }
    var dir = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] }[e.key];
    if (!dir) return;
    e.preventDefault();
    var next = e.shiftKey
      ? { id: w.id, x: w.x, y: w.y, w: w.w + dir[0], h: w.h + dir[1] }
      : { id: w.id, x: w.x + dir[0], y: w.y + dir[1], w: w.w, h: w.h };
    if (!C.canPlace(draft().widgets, next)) return;
    w.x = next.x; w.y = next.y; w.w = next.w; w.h = next.h;
    redraw();
    var again = S.el.querySelector('[data-wid="' + w.id + '"]');
    if (again) again.focus();
  }

  PS.edit = {
    begin: begin, cancel: cancel, save: save, newDashboard: newDashboard, renderBar: renderBar,
    onClick: onClick, openSettings: openSettings,
  };
})(this);

// JarvisCopilot — Power integrations on the web.
//
// Built-in features you switch on/off and configure on the Integrations page (the
// server side is jarvis_power/). This file:
//   - keeps JCPower.rows fresh from GET /api/power (load, focus, every minute);
//   - hides every element marked data-power="<id>" while that integration is off
//     (unknown or unreachable = on: a failed fetch never hides anything);
//   - draws the Power section at the top of the Integrations sidebar and each Power
//     integration's page (switch, JSON page, links, settings form, schedules/data).
// Protected integrations switch off only after Face ID on the iPhone; the switch
// says so while it waits.

(function (root) {
  'use strict';

  var JCPower = {
    rows: [],
    pending: {},
    native: {},          // id -> {card(el,row), page(el,row), settings(el,row)} when a native view exists
    isOn: function (id) {
      for (var i = 0; i < JCPower.rows.length; i++) {
        if (JCPower.rows[i].id === id) return JCPower.rows[i].enabled !== false;
      }
      return true;
    },
    row: function (id) {
      for (var i = 0; i < JCPower.rows.length; i++) if (JCPower.rows[i].id === id) return JCPower.rows[i];
      return null;
    },
    /** Rows from a /api/power reply; hides/shows data-power elements. */
    version: null,
    apply: function (body, doc) {
      JCPower.changed = !!body && body.version !== JCPower.version;
      JCPower.version = body ? body.version : null;
      JCPower.rows = (body && body.integrations) || [];
      JCPower.rows.forEach(function (r) { if (r.enabled === false) delete JCPower.pending[r.id]; });
      JCPower.applyGates(doc || (typeof document !== 'undefined' ? document : null));
    },
    applyGates: function (doc) {
      if (!doc || !doc.querySelectorAll) return;
      var els = doc.querySelectorAll('[data-power]');
      for (var i = 0; i < els.length; i++) {
        var el = els[i];
        var off = !JCPower.isOn(el.getAttribute('data-power'));
        if (el.classList) el.classList.toggle('power-off', off);
      }
    },
    refresh: function () {
      if (typeof api !== 'function') return Promise.resolve();
      return api('/api/power').then(function (body) {
        JCPower.apply(body);
        if (typeof _powerRerender === 'function') _powerRerender();
      }).catch(function () { /* keep what we had */ });
    },
    /** {enabled?, settings?} -> {ok, row} | {ok:false, pending} | throws with the server's error. */
    set: function (id, body) {
      var payload = Object.assign({ client: JCPower.client() }, body);
      return api('/api/power/' + encodeURIComponent(id), { method: 'POST', body: JSON.stringify(payload) })
        .then(function (res) {
          if (res && res.pending) JCPower.pending[id] = true;
          return JCPower.refresh().then(function () { return res; });
        });
    },
    client: function () {
      return (typeof location !== 'undefined' && /[?&]embed=mac/.test(location.search)) ? 'mac' : 'web';
    },
    /** The Mac draws the Power section natively and embeds only the regular list. */
    embeddedForMac: function () {
      return typeof location !== 'undefined' && /[?&]embed=mac-regular/.test(location.search);
    },
    subtitle: function (r) {
      if (JCPower.pending[r.id]) return 'Waiting for Face ID on your iPhone';
      if (r.enabled === false) return 'Off';
      return r.status_line || r.summary || '';
    },
    secretLabel: function (v) { return v && v.set ? 'Set' : 'Not set'; },
  };

  if (typeof module !== 'undefined' && module.exports) { module.exports = JCPower; return; }
  root.JCPower = JCPower;

  // ── sidebar section ───────────────────────────────────────────────────────
  var _powerView = '';

  root.powerSidebarSection = function (box) {
    if (JCPower.embeddedForMac() || !JCPower.rows.length) return;
    box.insertAdjacentHTML('beforeend', '<div class="intg-group-label">Power</div>');
    JCPower.rows.forEach(function (r) {
      var el = document.createElement('div');
      el.className = 'cron-item intg-card power-card' + (r.enabled === false ? ' power-card--off' : '');
      el.id = 'power-' + r.id;
      if (_powerView === r.id) el.classList.add('active');
      el.innerHTML =
        '<div class="intg-card-head">' +
          '<span class="intg-card-icon" aria-hidden="true">' + _intgIcon('bolt') + '</span>' +
          '<span class="cron-name">' + esc(r.name) + '</span>' +
          '<span class="power-tag">Power</span>' +
          '<label class="power-switch" title="' + esc(r.name) + ' on">' +
            '<input type="checkbox"' + (r.enabled !== false ? ' checked' : '') +
            (JCPower.pending[r.id] ? ' disabled' : '') + '><span></span></label>' +
        '</div>' +
        '<div class="intg-card-meta">' + esc(JCPower.subtitle(r)) + '</div>' +
        (r.error ? '<div class="intg-card-meta intg-note--error">' + esc(r.error) + '</div>' : '');
      var sw = el.querySelector('input');
      sw.onclick = function (ev) { ev.stopPropagation(); };
      sw.onchange = function () { _powerFlip(r, sw.checked, sw); };
      el.onclick = function () { root.openPowerIntegration(r.id); };
      box.appendChild(el);
    });
    box.insertAdjacentHTML('beforeend', '<div class="intg-group-label">Integrations</div>');
  };

  function _powerFlip(r, on, sw) {
    JCPower.set(r.id, { enabled: on }).then(function (res) {
      if (res && res.pending && typeof showToast === 'function') showToast('Approve with Face ID on your iPhone');
    }).catch(function (e) {
      if (sw) sw.checked = !on;
      if (typeof showToast === 'function') showToast(e.message || 'That didn’t work');
    });
  }

  // ── detail page ───────────────────────────────────────────────────────────
  root.openPowerIntegration = function (id) {
    _powerView = id;
    if (typeof _intgView !== 'undefined') _intgView = 'power:' + id;
    document.querySelectorAll('.cron-item').forEach(function (e) { e.classList.remove('active'); });
    var card = document.getElementById('power-' + id);
    if (card) card.classList.add('active');
    if (typeof _clearCronDetail === 'function') _clearCronDetail();
    _powerView = id;
    if (typeof _intgView !== 'undefined') _intgView = 'power:' + id;
    _powerRender(id);
  };

  function _powerRerender() {
    if (_powerView && typeof _intgView !== 'undefined' && _intgView === 'power:' + _powerView) _powerRender(_powerView);
    var box = document.getElementById('cronList');
    if (box && JCPower.changed && typeof renderIntegrationsSidebar === 'function' && document.querySelector('.power-card')) {
      renderIntegrationsSidebar(box);
    }
  }
  root._powerRerender = _powerRerender;

  function _powerRender(id) {
    var r = JCPower.row(id);
    var title = document.getElementById('taskDetailTitle');
    var body = document.getElementById('taskDetailBody');
    var empty = document.getElementById('taskDetailEmpty');
    if (!r || !body) return;
    if (empty) empty.style.display = 'none';
    body.style.display = '';
    if (title) title.textContent = r.name;
    var links = (r.links || []).filter(function (l) { return l.platform === 'web'; });
    body.innerHTML =
      '<div class="intg-detail power-detail">' +
        '<div class="power-head">' +
          '<div><span class="power-state">' + (r.enabled !== false ? 'On' : 'Off') + '</span>' +
          '<span class="power-tag">Power</span>' + (r.protected ? '<span class="power-tag">Face ID</span>' : '') +
          '<div class="intg-card-meta">' + esc(JCPower.subtitle(r)) + '</div></div>' +
          '<label class="power-switch"><input type="checkbox" id="powerSwitch"' + (r.enabled !== false ? ' checked' : '') +
          (JCPower.pending[r.id] ? ' disabled' : '') + '><span></span></label>' +
        '</div>' +
        '<p class="intg-detail-desc">' + esc(r.summary || '') + '</p>' +
        (r.error ? '<div class="intg-note intg-note--error">' + esc(r.error) + '</div>' : '') +
        '<div id="powerPageUI"></div>' +
        (links.length && r.enabled !== false ? '<section class="intg-section"><h4 class="intg-section-title">Open</h4>' +
          links.map(function (l) {
            return '<div class="intg-row intg-row--click" data-power-link="' + esc(l.target) + '"><div class="intg-row-main"><span class="intg-row-name">' +
              esc(l.label) + '</span></div></div>';
          }).join('') + '</section>' : '') +
        '<section class="intg-section" id="powerSettings"></section>' +
        '<section class="intg-section"><div class="intg-row intg-row--click" id="powerData"><div class="intg-row-main">' +
          '<span class="intg-row-name">Schedules, skills and data</span><span class="intg-row-sub">What it keeps and runs</span></div></div></section>' +
      '</div>';
    var sw = document.getElementById('powerSwitch');
    sw.onchange = function () { _powerFlip(r, sw.checked, sw); };
    body.querySelectorAll('[data-power-link]').forEach(function (el) {
      el.onclick = function () { _powerOpenLink(el.getAttribute('data-power-link')); };
    });
    document.getElementById('powerData').onclick = function () {
      if (typeof openIntegration === 'function') openIntegration(r.space);
    };
    _powerSettings(document.getElementById('powerSettings'), r);
    if (r.has_page && r.enabled !== false && typeof _intgMountUI === 'function') {
      _intgMountUI(document.getElementById('powerPageUI'), '/api/power', r.id, 'page');
    }
  }

  function _powerOpenLink(target) {
    if (target === 'kanban' || target === 'security') { switchPanel(target); return; }
    if (target === 'imessage' && typeof openIMessageMemory === 'function') { openIMessageMemory(); return; }
  }

  function _powerSettings(host, r) {
    var native = JCPower.native[r.id];
    if (native && native.settings) { native.settings(host, r); return; }
    var schema = r.settings_schema || [];
    if (!schema.length) { host.innerHTML = ''; return; }
    host.innerHTML = '<h4 class="intg-section-title">Settings</h4>' + schema.map(function (s) {
      var v = (r.settings || {})[s.key];
      var help = s.help ? '<div class="intg-row-sub">' + esc(s.help) + '</div>' : '';
      var field;
      if (s.kind === 'toggle') {
        field = '<input type="checkbox" data-key="' + esc(s.key) + '"' + (v ? ' checked' : '') + '>';
      } else if (s.kind === 'picker') {
        field = '<select data-key="' + esc(s.key) + '">' + (s.options || []).map(function (o) {
          return '<option value="' + esc(o.value) + '"' + (String(o.value) === String(v) ? ' selected' : '') + '>' + esc(o.label) + '</option>';
        }).join('') + '</select>';
      } else if (s.kind === 'secret') {
        field = '<span class="intg-row-sub">' + JCPower.secretLabel(v) + '</span> ' +
          '<input type="password" placeholder="Replace" autocomplete="off" data-key="' + esc(s.key) + '">';
      } else {
        field = '<input type="' + (s.kind === 'number' ? 'number' : 'text') + '" data-key="' + esc(s.key) + '" value="' +
          esc(v == null ? '' : v) + '">' + (s.unit ? ' <span class="intg-row-sub">' + esc(s.unit) + '</span>' : '');
      }
      return '<div class="intg-row power-setting"><div class="intg-row-main"><span class="intg-row-name">' +
        esc(s.label) + '</span>' + help + '</div>' + field + '</div>';
    }).join('');
    host.querySelectorAll('[data-key]').forEach(function (input) {
      input.onchange = function () {
        var key = input.getAttribute('data-key');
        var kind = (schema.filter(function (s) { return s.key === key; })[0] || {}).kind;
        var value = kind === 'toggle' ? input.checked : (kind === 'number' ? Number(input.value) : input.value);
        if (kind === 'secret' && !value) return;
        var change = {}; change[key] = value;
        JCPower.set(r.id, { settings: change }).then(function (res) {
          if (res && res.pending && typeof showToast === 'function') showToast('Approve the change with Face ID on your iPhone');
        }).catch(function (e) { if (typeof showToast === 'function') showToast(e.message || 'That didn’t work'); });
      };
    });
  }

  // ── keep fresh ────────────────────────────────────────────────────────────
  if (typeof document !== 'undefined') {
    document.addEventListener('DOMContentLoaded', function () { JCPower.refresh(); });
    root.addEventListener('focus', function () { JCPower.refresh(); });
    setInterval(function () { if (!document.hidden) JCPower.refresh(); }, 60000);
  }
})(this);

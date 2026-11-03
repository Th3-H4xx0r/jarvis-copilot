// JarvisCopilot — Devices tab.
//
// Pulls paired-device records from /api/devices and renders:
//   - sidebar list (#devicesList)        : compact rows w/ name, online dot
//   - main pane    (#devicesMainContent) : detailed cards w/ revoke / logout
//
// Pairing-from-UI: clicking the "+" button POSTs /api/devices/pair/start,
// shows a modal with the code + URL, polls /api/auth/pair/status until
// claimed/expired/cancelled.

let _devicesData = [];
let _devicesPollTimer = null;
let _devicesPairModalEl = null;
let _devicesPairPollTimer = null;
let _devicesPairCurrentCode = null;
// CF Access service token for the current pairing session (when tunneled), so
// the QR/deep-link can carry it to a tunnel-first device. Cleared between runs.
let _devicesPairCfAccess = null;
const _DEVICES_LIVE_REFRESH_MS = 10000;

function _devEsc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function _devFmtAge(ts) {
  if (!ts) return '—';
  const ms = Date.now() - (Number(ts) * 1000);
  if (ms < 0) return 'just now';
  const s = Math.floor(ms / 1000);
  if (s < 60) return s + 's ago';
  const m = Math.floor(s / 60);
  if (m < 60) return m + 'm ago';
  const h = Math.floor(m / 60);
  if (h < 24) return h + 'h ago';
  const d = Math.floor(h / 24);
  return d + 'd ago';
}

function _devFmtUserAgent(ua) {
  if (!ua) return '';
  // Trim to a short label — browser/OS hints if we can identify them.
  const u = ua.toLowerCase();
  let browser = 'Browser';
  if (u.includes('firefox/')) browser = 'Firefox';
  else if (u.includes('edg/')) browser = 'Edge';
  else if (u.includes('chrome/')) browser = 'Chrome';
  else if (u.includes('safari/') && !u.includes('chrome/')) browser = 'Safari';
  let os = '';
  if (u.includes('iphone') || u.includes('ipad')) os = 'iOS';
  else if (u.includes('android')) os = 'Android';
  else if (u.includes('mac os')) os = 'macOS';
  else if (u.includes('windows')) os = 'Windows';
  else if (u.includes('linux')) os = 'Linux';
  return os ? `${browser} · ${os}` : browser;
}

async function loadDevices(force) {
  const listEl = document.getElementById('devicesList');
  const mainEl = document.getElementById('devicesMainContent');
  try {
    const res = await fetch('/api/devices', { credentials: 'same-origin' });
    if (!res.ok) throw new Error('HTTP ' + res.status);
    const data = await res.json();
    _devicesData = (data && data.devices) || [];
    _renderDevicesSidebar();
    _renderDevicesMain();
  } catch (e) {
    if (listEl) listEl.innerHTML = `<div class="dev-error">Could not load devices: ${_devEsc(e.message)}</div>`;
    if (mainEl) mainEl.innerHTML = `<div class="dev-page"><div class="dev-card dev-empty"><div class="dev-empty-title">Could not load devices</div><p class="dev-empty-sub">Check the connection to the server and try again.</p></div></div>`;
  }

  if (force && _devicesPollTimer) clearInterval(_devicesPollTimer);
  if (!_devicesPollTimer) {
    _devicesPollTimer = setInterval(() => {
      if (typeof _currentPanel !== 'undefined' && _currentPanel === 'devices') {
        loadDevices();
      }
    }, _DEVICES_LIVE_REFRESH_MS);
  }
}

// Line icons (phone app's device glyphs) — stroke = currentColor.
const _DEV_ICONS = {
  phone: '<rect x="7" y="2.5" width="10" height="19" rx="2.5"/><line x1="11" y1="18.5" x2="13" y2="18.5"/>',
  laptop: '<rect x="4" y="5" width="16" height="11" rx="1.5"/><line x1="2" y1="19" x2="22" y2="19"/>',
  monitor: '<rect x="3" y="4" width="18" height="12" rx="1.5"/><line x1="12" y1="16" x2="12" y2="20"/><line x1="8" y1="20" x2="16" y2="20"/>',
  pod: '<circle cx="12" cy="12" r="8"/><circle cx="12" cy="12" r="2.5"/>',
  chevron: '<polyline points="9 6 15 12 9 18"/>',
};
function _devIcon(name, cls) {
  return `<svg class="${cls || 'dev-icon'}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${_DEV_ICONS[name] || _DEV_ICONS.monitor}</svg>`;
}

// What kind of thing a device record is: [icon, label]. Falls back to the
// browser/OS hint from the user agent so a plain web login still reads well.
function _devKind(d) {
  const k = String(d.kind || '').toLowerCase();
  const ua = String(d.user_agent || '').toLowerCase();
  if (k.includes('ios') || ua.includes('iphone')) return ['phone', 'iPhone'];
  if (k.includes('mobile') || k.includes('android') || ua.includes('android')) return ['phone', 'Phone'];
  if (k.includes('watch')) return ['phone', 'Watch'];
  if (k.includes('pod')) return ['pod', 'Pod'];
  if (k.includes('mac') || ua.includes('mac os')) return ['laptop', 'Mac'];
  if (k.includes('desktop') || k.includes('computer')) return ['monitor', 'Computer'];
  return ['monitor', _devFmtUserAgent(d.user_agent) || 'Browser'];
}

function _renderDevicesSidebar() {
  const el = document.getElementById('devicesList');
  if (!el) return;
  if (!_devicesData.length) {
    el.innerHTML = `<div class="dev-side-empty">No devices paired yet<button class="btn primary dev-side-pair" onclick="startPairingFromUI()">Pair a device</button></div>`;
    return;
  }
  const rows = _devicesData.map(d => {
    const skills = (d.skills && d.skills.length)
      ? `<span class="dev-row-count">${d.skills.length} skills</span>`
      : '';
    return `<div class="device-row" data-id="${_devEsc(d.id)}">
      <span class="dev-dot${d.online ? ' is-online' : ''}"></span>
      <div class="dev-row-main">
        <div class="dev-row-name">${_devEsc(d.name || 'device')}</div>
        <div class="dev-row-sub">${_devEsc(d.ip || '—')} · ${_devEsc(_devFmtAge(d.paired_at))}</div>
      </div>
      ${skills}
    </div>`;
  });
  el.innerHTML = rows.join('');
}

function _renderDevicesMain() {
  const el = document.getElementById('devicesMainContent');
  if (!el) return;
  if (!_devicesData.length) {
    el.innerHTML = `
      <div class="dev-page">
        <div class="dev-card dev-empty">
          <div class="dev-empty-title">No devices paired</div>
          <p class="dev-empty-sub">Devices you pair with this server appear here, with the skills each one is allowed to run.</p>
        </div>
        <button class="dev-pair-btn" onclick="startPairingFromUI()">Pair a device</button>
      </div>`;
    return;
  }
  const cards = _devicesData.map(d => {
    const [icon, kindLabel] = _devKind(d);
    const n = (d.skills && d.skills.length) || 0;
    const skillsHtml = n
      ? `<details class="dev-skills">
          <summary class="dev-foot"><span>${n} skill${n === 1 ? '' : 's'} granted</span>${_devIcon('chevron', 'dev-chev')}</summary>
          <div class="dev-skill-list">
            ${d.skills.map(s => `<div class="dev-skill"><div class="dev-skill-name">${_devEsc(s.name)}</div>${s.description ? `<div class="dev-skill-desc">${_devEsc(s.description)}</div>` : ''}</div>`).join('')}
          </div>
        </details>`
      : `<div class="dev-foot is-static"><span>No skills granted</span></div>`;
    const seen = d.last_seen || d.paired_at;
    return `<div class="device-card dev-card" data-id="${_devEsc(d.id)}" data-name="${_devEsc(d.name)}">
      <div class="dev-head">
        <span class="dev-kind-icon">${_devIcon(icon)}</span>
        <div class="dev-head-main">
          <div class="dev-name">${_devEsc(d.name || 'device')}</div>
          <div class="dev-sub"><span class="dev-dot${d.online ? ' is-online' : ''}"></span>${_devEsc(kindLabel)} · ${d.online ? 'Online' : 'Offline'} · ${_devEsc(_devFmtAge(seen))}</div>
        </div>
        <div class="dev-actions">
          <button class="btn secondary device-logout-btn">Log out</button>
          <button class="btn device-revoke-btn">Revoke</button>
        </div>
      </div>
      <div class="dev-facts">
        <span>IP</span><span class="is-mono">${_devEsc(d.ip || '—')}</span>
        <span>Paired</span><span>${_devEsc(_devFmtAge(d.paired_at))}</span>
        <span>Client</span><span>${_devEsc(_devFmtUserAgent(d.user_agent) || '—')}</span>
        <span>Device ID</span><span class="is-mono">${_devEsc((d.id || '').slice(0, 12))}</span>
      </div>
      ${skillsHtml}
    </div>`;
  });
  el.innerHTML = `
    <div class="dev-page">
      <div class="dev-sec"><span>Paired devices</span><span class="dev-sec-count">${_devicesData.length}</span></div>
      ${cards.join('')}
      <button class="dev-pair-btn" onclick="startPairingFromUI()">Pair another device</button>
    </div>`;
}

function selectDevice(id) {
  // Scroll the corresponding card into view in the main area.
  const card = document.querySelector(`#devicesMainContent .device-card[data-id="${CSS.escape(id)}"]`)
    || [...document.querySelectorAll('#devicesMainContent .device-card')]
        .find(c => c.innerHTML.includes(id.slice(0, 12)));
  if (card) card.scrollIntoView({ behavior: 'smooth', block: 'center' });
  document.querySelectorAll('#devicesList .device-row').forEach(r => {
    r.classList.toggle('is-selected', r.dataset.id === id);
  });
}

async function revokeDevice(id, name) {
  if (!confirm(`Revoke pairing for "${name || 'device'}"?\nThe device will be logged out and removed from the list.`)) return;
  try {
    const res = await fetch('/api/devices/' + encodeURIComponent(id), {
      method: 'DELETE',
      credentials: 'same-origin',
      headers: { 'X-Requested-With': 'fetch' },
    });
    if (!res.ok) throw new Error('HTTP ' + res.status);
    await loadDevices(true);
  } catch (e) {
    alert('Failed to revoke device: ' + e.message);
  }
}

async function logoutDevice(id, name) {
  if (!confirm(`Log "${name || 'device'}" out?\nThe device stays paired but will need to re-authenticate.`)) return;
  try {
    const res = await fetch('/api/devices/' + encodeURIComponent(id) + '/logout', {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'X-Requested-With': 'fetch', 'Content-Type': 'application/json' },
      body: '{}',
    });
    if (!res.ok) throw new Error('HTTP ' + res.status);
    await loadDevices(true);
  } catch (e) {
    alert('Failed to log out device: ' + e.message);
  }
}

// ── Pair-from-UI modal ────────────────────────────────────────────────────

async function startPairingFromUI() {
  try {
    const res = await fetch('/api/devices/pair/start', {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'fetch' },
      body: '{"ttl":600}',
    });
    if (!res.ok) throw new Error('HTTP ' + res.status);
    const info = await res.json();
    _devicesPairCurrentCode = info.code;
    _devicesPairCfAccess = (info.cf_access && info.cf_access.client_id) ? info.cf_access : null;
    _openPairModal(info.code, info.expires_at);
    _startPairPolling(info.code);
  } catch (e) {
    alert('Failed to start pairing: ' + e.message);
  }
}

function _pairUrl() {
  // Same scheme + host the page itself is on, with the /pair path.
  const loc = window.location;
  return loc.protocol + '//' + loc.host + '/pair';
}

function _pairDeepLink(code) {
  // jarviscopilot://pair?server=<urlencoded>&code=<code>[&cf_id=…&cf_secret=…]
  // The mobile app registers this scheme and pre-fills its Pair page. The CF
  // Access service token (when present) is included so a single scan carries
  // everything the device needs — the real qrcode-generator lib auto-sizes the
  // QR to any version, so the ~170-byte payload fits fine (the old hand-rolled
  // encoder capped at v5/84 bytes, which is why this used to be split out).
  const loc = window.location;
  const serverUrl = loc.protocol + '//' + loc.host;
  let link = 'jarviscopilot://pair?server=' + encodeURIComponent(serverUrl) +
             '&code=' + encodeURIComponent(code);
  const cf = _devicesPairCfAccess;
  if (cf && cf.client_id && cf.client_secret) {
    link += '&cf_id=' + encodeURIComponent(cf.client_id) +
            '&cf_secret=' + encodeURIComponent(cf.client_secret);
  }
  return link;
}

// Lazy-load the battle-tested qrcode-generator lib (MIT) from jsdelivr — the
// app's CSP already allows cdn.jsdelivr.net (prism/xterm load from there). The
// previous hand-rolled encoder produced QR codes that looked right but didn't
// decode on a real scanner (v5 alignment/timing edge cases), so we delegate to
// a proven implementation. Returns a promise resolving to the `qrcode` global.
let _qrLibPromise = null;
function _loadQrLib() {
  if (window.qrcode) return Promise.resolve(window.qrcode);
  if (_qrLibPromise) return _qrLibPromise;
  _qrLibPromise = new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = 'https://cdn.jsdelivr.net/npm/qrcode-generator@1.4.4/qrcode.js';
    s.onload = () => window.qrcode ? resolve(window.qrcode) : reject(new Error('qrcode global missing'));
    s.onerror = () => reject(new Error('failed to load QR library'));
    document.head.appendChild(s);
  });
  return _qrLibPromise;
}

// Render the QR into the element with id `targetId` once the lib loads. The
// URL + pairing code shown alongside are the reliable fallback, so on failure
// we just hide the QR area rather than blocking pairing.
function _renderQrInto(targetId, text, opts) {
  opts = opts || {};
  const size = opts.size || 280;        // displayed px (square)
  const bg = opts.bg || '#ffffff';
  _loadQrLib().then((qrcode) => {
    const el = document.getElementById(targetId);
    if (!el) return;
    // EC level 'L' = max data capacity / fewest modules for our ~170-byte
    // payload, so the QR stays as coarse (easy to scan) as possible. type 0
    // auto-picks the smallest version that fits.
    const qr = qrcode(0, 'L');
    qr.addData(text);
    qr.make();
    const count = qr.getModuleCount();
    const margin = 4;                   // quiet zone in modules (spec: >=4)
    const total = count + margin * 2;
    // Build the SVG ourselves so we can scale it to a FIXED display size via a
    // viewBox — the lib's integer cellSize would otherwise shrink a dense QR.
    let rects = '';
    for (let r = 0; r < count; r++) {
      for (let c = 0; c < count; c++) {
        if (qr.isDark(r, c)) {
          rects += '<rect x="' + (c + margin) + '" y="' + (r + margin) + '" width="1.02" height="1.02" fill="#0a0e1a"/>';
        }
      }
    }
    el.innerHTML =
      '<svg width="' + size + '" height="' + size + '" viewBox="0 0 ' + total + ' ' + total + '" ' +
      'shape-rendering="crispEdges" style="background:' + bg + ';border-radius:8px" ' +
      'xmlns="http://www.w3.org/2000/svg">' + rects + '</svg>';
  }).catch(() => {
    const el = document.getElementById(targetId);
    if (el) el.innerHTML = '<div class="pair-qr-off">QR unavailable. Use the address and code below.</div>';
  });
}


// When the server is behind a Cloudflare tunnel, the device must send the CF
// Access service token on its pair request (it 302s to SSO otherwise). The token
// is too big for the QR, so show it here for the user to paste into the device's
// "Cloudflare service token" field. Empty string when no token is configured.
function _pairCfTokenBlock() {
  const cf = _devicesPairCfAccess;
  if (!cf || !cf.client_id || !cf.client_secret) return '';
  const fld = (label, val) =>
    `<div class="pair-cf-field">
       <div class="pair-cf-label">${label}</div>
       <div class="pair-cf-row">
         <code class="pair-cf-val">${_devEsc(val)}</code>
         <button type="button" class="pair-cf-copy" onclick="_pairCopy(this,'${_devEsc(val).replace(/'/g, "\\'")}')">Copy</button>
       </div>
     </div>`;
  return `
    <div class="pair-cf">
      <div class="pair-cf-title">Cloudflare Access: paste these into the device’s “service token” field</div>
      <div class="pair-cf-text">This server is behind a Cloudflare tunnel, so the device needs these to connect (it can’t do browser login). Enter them in the app’s pair screen before pairing.</div>
      <div class="pair-cf-warn">One-time setup: add this token to your Access policy, or pairing gets redirected to login (HTTP 302). In Cloudflare: <b>Zero Trust → Access → Applications →</b> your app <b>→ Policies → add a policy →</b> set <b>Action = Service Auth</b> (not “Allow”: an Allow policy still demands a browser login, so the token alone gives a 302) and rule <b>Include → Service Token →</b> this token.</div>
      ${fld('Client ID', cf.client_id)}
      ${fld('Client Secret', cf.client_secret)}
    </div>`;
}

// expose a copy helper for the inline buttons
window._pairCopy = function (btn, val) {
  try {
    navigator.clipboard.writeText(val);
    const old = btn.textContent;
    btn.textContent = 'Copied';
    setTimeout(() => { btn.textContent = old; }, 1200);
  } catch (e) { /* clipboard blocked — user can select the code manually */ }
};

function _openPairModal(code, expiresAt) {
  _closePairModal();
  const wrap = document.createElement('div');
  wrap.id = 'pair-modal';
  // Center + allow the overlay itself to scroll on short viewports (padding so
  // the card never touches the edges). align-items:flex-start keeps the top of
  // a tall card reachable instead of clipping it above the fold.
  wrap.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.6);display:flex;align-items:flex-start;justify-content:center;z-index:9999;backdrop-filter:blur(4px);overflow-y:auto;padding:20px 0';
  wrap.addEventListener('click', ev => { if (ev.target === wrap) _cancelPair(); });
  wrap.innerHTML = `
    <div class="pair-card" role="dialog" aria-modal="true" aria-labelledby="pair-title" style="background:var(--card-bg,#14203a);border:1px solid var(--border,rgba(255,255,255,.08));border-radius:18px;padding:28px;max-width:420px;width:calc(100% - 32px);box-shadow:0 20px 60px rgba(0,0,0,.45);position:relative;max-height:calc(100vh - 40px);overflow-y:auto;margin:auto">
      <button class="pair-close" onclick="_cancelPair()" aria-label="Close"><svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><line x1="6" y1="6" x2="18" y2="18"/><line x1="18" y1="6" x2="6" y2="18"/></svg></button>
      <div class="pair-body">
        <h2 class="pair-title" id="pair-title">Pair a new device</h2>
        <p class="pair-lead">Scan with the JarvisCopilot app on your phone</p>
        <div id="pair-qr" class="pair-qr">Generating QR…</div>
        <p class="pair-hint">Or open this address in a browser</p>
        <div class="pair-url">${_devEsc(_pairUrl())}</div>
        <p class="pair-hint">Then enter this code</p>
        <div id="pair-code-display" class="pair-code">${_devEsc(code)}</div>
        ${_pairCfTokenBlock()}
        <div id="pair-status" class="pair-status">
          <span class="pair-spin"></span>
          Waiting for the device <span id="pair-countdown"></span>
        </div>
      </div>
    </div>
    <style>@keyframes pair-spin{to{transform:rotate(360deg)}}</style>`;
  document.body.appendChild(wrap);
  _devicesPairModalEl = wrap;
  _renderQrInto('pair-qr', _pairDeepLink(code), { size: 280, bg: '#ffffff' });
  _updatePairCountdown(expiresAt);
}

function _closePairModal() {
  if (_devicesPairPollTimer) { clearInterval(_devicesPairPollTimer); _devicesPairPollTimer = null; }
  if (_devicesPairModalEl && _devicesPairModalEl.parentNode) _devicesPairModalEl.parentNode.removeChild(_devicesPairModalEl);
  _devicesPairModalEl = null;
}

let _pairCountdownTimer = null;
function _updatePairCountdown(expiresAt) {
  if (_pairCountdownTimer) clearInterval(_pairCountdownTimer);
  const tick = () => {
    const el = document.getElementById('pair-countdown');
    if (!el) { clearInterval(_pairCountdownTimer); return; }
    const remaining = Math.max(0, Math.floor(expiresAt - (Date.now() / 1000)));
    const m = Math.floor(remaining / 60), s = remaining % 60;
    el.textContent = `(${m}:${s.toString().padStart(2, '0')})`;
    if (remaining <= 0) clearInterval(_pairCountdownTimer);
  };
  tick();
  _pairCountdownTimer = setInterval(tick, 1000);
}

function _startPairPolling(code) {
  if (_devicesPairPollTimer) clearInterval(_devicesPairPollTimer);
  _devicesPairPollTimer = setInterval(async () => {
    try {
      const res = await fetch('/api/auth/pair/status?code=' + encodeURIComponent(code), { credentials: 'same-origin' });
      if (!res.ok) return;
      const state = await res.json();
      if (state.status === 'claimed') {
        clearInterval(_devicesPairPollTimer);
        const statusEl = document.getElementById('pair-status');
        if (statusEl) statusEl.innerHTML = `<span class="pair-done">Paired with ${_devEsc(state.device_name || 'device')}</span>`;
        setTimeout(() => { _closePairModal(); loadDevices(true); }, 1500);
      } else if (state.status === 'expired' || state.status === 'unknown') {
        clearInterval(_devicesPairPollTimer);
        const statusEl = document.getElementById('pair-status');
        if (statusEl) statusEl.innerHTML = `<span class="pair-expired">The code expired before a device paired</span>`;
      }
    } catch (e) { /* ignore transient errors */ }
  }, 1000);
}

function _cancelPair() {
  const code = _devicesPairCurrentCode;
  _closePairModal();
  if (code) {
    fetch('/api/devices/pair/cancel', {
      method: 'POST', credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'fetch' },
      body: JSON.stringify({ code }),
    }).catch(() => {});
  }
}

// ── Event delegation ──────────────────────────────────────────────────────
// The card / row markup is regenerated by render*() every refresh, so we
// can't bind handlers per-button — they'd disappear on the next innerHTML
// swap. Using inline onclick="…(name)" was the previous approach but
// broke when device names contained apostrophes ("Pranav's iPhone") —
// the HTML-escaped &#39; closed the JS string mid-attribute and the whole
// row failed to parse, leaving Revoke / Log out non-functional. Wiring
// once at script load via delegation avoids the quoting problem entirely.
document.addEventListener('click', ev => {
  const target = ev.target;
  if (!(target instanceof Element)) return;

  // Revoke / Log out buttons inside a .device-card.
  const card = target.closest('.device-card');
  if (card) {
    const id = card.dataset.id || '';
    const name = card.dataset.name || '';
    if (!id) return;
    if (target.classList.contains('device-revoke-btn')) {
      ev.preventDefault();
      revokeDevice(id, name);
      return;
    }
    if (target.classList.contains('device-logout-btn')) {
      ev.preventDefault();
      logoutDevice(id, name);
      return;
    }
  }

  // Sidebar row click → scroll the matching card into view.
  const row = target.closest('#devicesList .device-row');
  if (row && row.dataset.id) {
    selectDevice(row.dataset.id);
  }
});

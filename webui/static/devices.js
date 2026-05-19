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
    if (listEl) listEl.innerHTML = `<div style="padding:12px;color:var(--danger,#e94560);font-size:12px">Failed to load devices: ${_devEsc(e.message)}</div>`;
    if (mainEl) mainEl.innerHTML = `<div style="color:var(--danger,#e94560);font-size:13px">Failed to load devices.</div>`;
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

function _renderDevicesSidebar() {
  const el = document.getElementById('devicesList');
  if (!el) return;
  if (!_devicesData.length) {
    el.innerHTML = `<div style="padding:18px 12px;color:var(--muted);font-size:12px;text-align:center;line-height:1.5">No devices paired yet.<br><button class="btn primary" style="margin-top:12px;padding:6px 14px;font-size:12px" onclick="startPairingFromUI()">Pair a device</button></div>`;
    return;
  }
  const rows = _devicesData.map(d => {
    const dot = d.online
      ? '<span style="display:inline-block;width:8px;height:8px;border-radius:50%;background:#7ae597;box-shadow:0 0 6px rgba(122,229,151,.6);flex-shrink:0"></span>'
      : '<span style="display:inline-block;width:8px;height:8px;border-radius:50%;background:rgba(255,255,255,.15);flex-shrink:0"></span>';
    const skillsBadge = (d.skills && d.skills.length)
      ? `<span style="margin-left:auto;font-size:10px;background:rgba(124,185,255,.15);color:#7cb9ff;padding:2px 6px;border-radius:8px">${d.skills.length} skills</span>`
      : '';
    return `<div class="device-row" data-id="${_devEsc(d.id)}" style="display:flex;align-items:center;gap:8px;padding:8px 10px;border-radius:8px;cursor:pointer;font-size:13px">
      ${dot}
      <div style="flex:1;min-width:0;overflow:hidden">
        <div style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${_devEsc(d.name || 'device')}</div>
        <div style="font-size:10px;color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${_devEsc(d.ip || '—')} · ${_devEsc(_devFmtAge(d.paired_at))}</div>
      </div>
      ${skillsBadge}
    </div>`;
  });
  el.innerHTML = rows.join('');
}

function _renderDevicesMain() {
  const el = document.getElementById('devicesMainContent');
  if (!el) return;
  if (!_devicesData.length) {
    el.innerHTML = `
      <div style="max-width:540px;margin:24px auto;text-align:center">
        <div style="font-size:48px;margin-bottom:12px;opacity:.4">📱</div>
        <h2 style="font-size:18px;margin-bottom:8px">No devices paired</h2>
        <p style="color:var(--muted);font-size:13px;line-height:1.6;margin-bottom:18px">Pair a phone, tablet, or another machine to give it access to this server.</p>
        <button class="btn primary" onclick="startPairingFromUI()">Pair a new device</button>
      </div>`;
    return;
  }
  const cards = _devicesData.map(d => {
    const skillsHtml = (d.skills && d.skills.length)
      ? `<div style="margin-top:10px"><div style="font-size:11px;color:var(--muted);margin-bottom:4px">Exposed skills (${d.skills.length})</div>
          <div style="display:flex;flex-wrap:wrap;gap:6px">
            ${d.skills.map(s => `<span title="${_devEsc(s.description || '')}" style="font-size:11px;background:rgba(124,185,255,.15);color:#7cb9ff;padding:3px 8px;border-radius:8px;font-family:ui-monospace,Menlo,monospace">${_devEsc(s.name)}</span>`).join('')}
          </div></div>`
      : '';
    const onlineBadge = d.online
      ? `<span style="font-size:11px;background:rgba(122,229,151,.15);color:#7ae597;padding:2px 8px;border-radius:8px">● online</span>`
      : `<span style="font-size:11px;background:rgba(255,255,255,.05);color:var(--muted);padding:2px 8px;border-radius:8px">offline</span>`;
    return `<div class="device-card" data-id="${_devEsc(d.id)}" data-name="${_devEsc(d.name)}" style="background:var(--card-bg,rgba(255,255,255,.03));border:1px solid var(--border,rgba(255,255,255,.08));border-radius:12px;padding:14px 16px;margin-bottom:12px">
      <div style="display:flex;align-items:center;gap:10px;margin-bottom:6px">
        <div style="font-size:14px;font-weight:600">${_devEsc(d.name || 'device')}</div>
        ${onlineBadge}
        <div style="margin-left:auto;display:flex;gap:6px">
          <button class="btn secondary device-logout-btn" style="padding:4px 10px;font-size:11px">Log out</button>
          <button class="btn device-revoke-btn" style="padding:4px 10px;font-size:11px;background:rgba(233,69,96,.15);color:#ff7a8a;border:1px solid rgba(233,69,96,.3)">Revoke</button>
        </div>
      </div>
      <div style="font-size:12px;color:var(--muted);display:grid;grid-template-columns:auto 1fr;column-gap:14px;row-gap:3px;line-height:1.6">
        <span>IP</span>          <span style="font-family:ui-monospace,Menlo,monospace">${_devEsc(d.ip || '—')}</span>
        <span>Paired</span>      <span>${_devEsc(_devFmtAge(d.paired_at))}</span>
        <span>Client</span>      <span>${_devEsc(_devFmtUserAgent(d.user_agent))}</span>
        <span>Device ID</span>   <span style="font-family:ui-monospace,Menlo,monospace;opacity:.7">${_devEsc((d.id || '').slice(0, 12))}</span>
      </div>
      ${skillsHtml}
    </div>`;
  });
  el.innerHTML = `
    <div style="max-width:720px;margin:0 auto">
      <div style="display:flex;align-items:center;margin-bottom:14px">
        <div style="font-size:12px;color:var(--muted)">${_devicesData.length} device${_devicesData.length === 1 ? '' : 's'}</div>
        <button class="btn primary" style="margin-left:auto;padding:6px 14px;font-size:12px" onclick="startPairingFromUI()">+ Pair new device</button>
      </div>
      ${cards.join('')}
    </div>`;
}

function selectDevice(id) {
  // Scroll the corresponding card into view in the main area.
  const card = document.querySelector(`#devicesMainContent .device-card[data-id="${CSS.escape(id)}"]`)
    || [...document.querySelectorAll('#devicesMainContent .device-card')]
        .find(c => c.innerHTML.includes(id.slice(0, 12)));
  if (card) card.scrollIntoView({ behavior: 'smooth', block: 'center' });
  document.querySelectorAll('#devicesList .device-row').forEach(r => {
    r.style.background = (r.dataset.id === id) ? 'rgba(255,255,255,.05)' : '';
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

function _openPairModal(code, expiresAt) {
  _closePairModal();
  const wrap = document.createElement('div');
  wrap.id = 'pair-modal';
  wrap.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.6);display:flex;align-items:center;justify-content:center;z-index:9999;backdrop-filter:blur(4px)';
  wrap.addEventListener('click', ev => { if (ev.target === wrap) _cancelPair(); });
  wrap.innerHTML = `
    <div style="background:var(--card-bg,#14203a);border:1px solid var(--border,rgba(255,255,255,.08));border-radius:18px;padding:28px;max-width:420px;width:calc(100% - 32px);box-shadow:0 20px 60px rgba(0,0,0,.45);position:relative">
      <button onclick="_cancelPair()" style="position:absolute;top:12px;right:12px;background:none;border:none;color:var(--muted);font-size:22px;cursor:pointer;width:28px;height:28px;border-radius:8px">×</button>
      <div style="text-align:center">
        <div style="width:56px;height:56px;border-radius:14px;background:linear-gradient(145deg,#f0b341,#e0552b);display:flex;align-items:center;justify-content:center;font-weight:800;font-size:22px;color:#fff;margin:0 auto 14px">JC</div>
        <h2 style="font-size:18px;margin-bottom:8px">Pair a new device</h2>
        <p style="color:var(--muted);font-size:13px;margin-bottom:18px;line-height:1.5">Open this URL on the new device:</p>
        <div style="background:rgba(255,255,255,.04);border:1px solid rgba(255,255,255,.08);border-radius:10px;padding:10px 14px;margin-bottom:14px;font-family:ui-monospace,Menlo,monospace;font-size:13px;word-break:break-all;text-align:center">${_devEsc(_pairUrl())}</div>
        <p style="color:var(--muted);font-size:13px;margin-bottom:8px">Then enter this code:</p>
        <div id="pair-code-display" style="font-family:ui-monospace,Menlo,monospace;font-size:32px;font-weight:800;letter-spacing:6px;color:#f0b341;background:rgba(240,179,65,.08);border:1px dashed rgba(240,179,65,.3);border-radius:12px;padding:14px;margin-bottom:14px">${_devEsc(code)}</div>
        <div id="pair-status" style="font-size:13px;color:var(--muted);min-height:22px">
          <span style="display:inline-block;width:10px;height:10px;border:2px solid #f0b341;border-top-color:transparent;border-radius:50%;animation:pair-spin .9s linear infinite;margin-right:6px;vertical-align:-1px"></span>
          Waiting for device... <span id="pair-countdown"></span>
        </div>
      </div>
    </div>
    <style>@keyframes pair-spin{to{transform:rotate(360deg)}}</style>`;
  document.body.appendChild(wrap);
  _devicesPairModalEl = wrap;
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
        if (statusEl) statusEl.innerHTML = `<span style="color:#7ae597">✓ Paired with ${_devEsc(state.device_name || 'device')}</span>`;
        setTimeout(() => { _closePairModal(); loadDevices(true); }, 1500);
      } else if (state.status === 'expired' || state.status === 'unknown') {
        clearInterval(_devicesPairPollTimer);
        const statusEl = document.getElementById('pair-status');
        if (statusEl) statusEl.innerHTML = `<span style="color:#ff9c5a">⌛ Code expired without a pairing.</span>`;
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

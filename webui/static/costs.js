// Insights → Costs: what every service Jarvis uses is costing (api/costs_routes.py).
// The Usage | Costs switch lives in the Insights header; the period picker and the
// refresh button in the side panel drive whichever tab is showing.

const COSTS = {data: null, detail: null, detailId: null};
const _COSTS_TAB_KEY = 'jarviscopilot-insights-tab';
// Series colours for the stacked chart: the accent first, then hues far apart from it
// and from each other so neighbouring services never match.
// One accent leads; the rest are neutral steps (2026-11-03 phone design brief).
const _COSTS_SERIES = ['var(--accent)', '#C9CFDB', '#9AA2B3', '#727A8C', '#555C6B'];
const _COSTS_OTHER = '#3D424E';
const _COSTS_TOP_N = 5;
const _COSTS_EST = 'color-mix(in srgb, var(--accent) 38%, transparent)';

function costsTabActive() {
  try { return localStorage.getItem(_COSTS_TAB_KEY) === 'costs'; } catch (_) { return false; }
}

function setInsightsTab(tab) {
  try { localStorage.setItem(_COSTS_TAB_KEY, tab === 'costs' ? 'costs' : 'usage'); } catch (_) {}
  _syncInsightsTabs();
  if (tab === 'costs') loadCosts(); else loadInsights();
}

function _syncInsightsTabs() {
  const costs = costsTabActive();
  document.querySelectorAll('.insights-tab').forEach(b => {
    const on = (b.dataset.tab === 'costs') === costs;
    b.classList.toggle('active', on);
    b.setAttribute('aria-selected', on ? 'true' : 'false');
  });
  const usage = $('insightsContent'), costsBox = $('costsContent');
  if (usage) usage.style.display = costs ? 'none' : '';
  if (costsBox) costsBox.style.display = costs ? '' : 'none';
}

function _costsDays() {
  return Number((($('insightsPeriod') || {}).value) || 30);
}

// ── formatting ────────────────────────────────────────────────────────────

function _usd(v, approx) {
  if (v === null || v === undefined || isNaN(Number(v))) return '—';
  const n = Number(v);
  const pre = approx && n > 0 ? '≈' : '';
  if (n > 0 && n < 0.01) return pre + '<$0.01';
  const digits = n >= 100 ? 0 : 2;
  return pre + '$' + n.toLocaleString(undefined, {minimumFractionDigits: digits, maximumFractionDigits: digits});
}

function _costsAgo(ts) {
  if (!ts) return 'never';
  const s = Math.max(0, Date.now() / 1000 - Number(ts));
  if (s < 90) return 'just now';
  if (s < 3600) return Math.round(s / 60) + ' min ago';
  if (s < 86400) return Math.round(s / 3600) + ' h ago';
  return Math.round(s / 86400) + ' d ago';
}

function _costsDayLabel(day) {
  const d = new Date(day + 'T12:00:00');
  return isNaN(d) ? day : d.toLocaleDateString(undefined, {month: 'short', day: 'numeric'});
}

const _COSTS_STATUS = {
  billing: ['Billing API', 'ok'],
  estimated: ['Estimated', 'est'],
  subscription: ['Plan', 'plan'],
  needs_price: ['Needs price', 'warn'],
  free: ['Free', 'free'],
  error: ['Sync error', 'err'],
};

function _costsPill(status) {
  const [label, tone] = _COSTS_STATUS[status] || [status, 'est'];
  return `<span class="costs-pill costs-pill-${tone}">${esc(label)}</span>`;
}

function _isApprox(card) {
  const src = card.sources || [];
  return card.kind === 'usage' && !src.includes('billing') && src.includes('estimate');
}

function _costsUnitsLine(u) {
  u = u || {};
  const parts = [];
  if (u.calls) parts.push(Number(u.calls).toLocaleString() + ' calls');
  if (u.searches) parts.push(Number(u.searches).toLocaleString() + ' searches');
  if (u.audio_seconds) parts.push((u.audio_seconds / 60).toFixed(u.audio_seconds < 600 ? 1 : 0) + ' min audio');
  if (u.bytes) parts.push((u.bytes / 1000).toFixed(1) + ' KB text');
  if (u.api_equiv_usd) parts.push('would be ' + _usd(u.api_equiv_usd) + ' on the API');
  return parts.join(' · ');
}

function _spark(values) {
  const vals = (values || []).map(Number);
  const max = Math.max(...vals, 0);
  if (!vals.length || max <= 0) return '<svg class="costs-spark" viewBox="0 0 60 18" aria-hidden="true"></svg>';
  const w = 60, h = 18, step = vals.length > 1 ? w / (vals.length - 1) : w;
  const pts = vals.map((v, i) => `${(i * step).toFixed(1)},${(h - 1 - (v / max) * (h - 3)).toFixed(1)}`).join(' ');
  return `<svg class="costs-spark" viewBox="0 0 ${w} ${h}" aria-hidden="true"><polyline points="${pts}" fill="none" stroke="var(--accent)" stroke-width="1.5" stroke-linejoin="round" stroke-linecap="round"/></svg>`;
}

function _jsArg(s) {
  // A service id inside an inline handler: ids are [a-z0-9-] but never trust that.
  return esc(JSON.stringify(String(s)));
}

// ── loading ───────────────────────────────────────────────────────────────

async function loadCosts(refresh) {
  const box = $('costsContent');
  if (!box) return;
  _syncInsightsTabs();
  const btn = $('insightsRefreshBtn');
  if (refresh && btn) { btn.style.opacity = '0.5'; btn.disabled = true; }
  if (!COSTS.data) box.innerHTML = `<div class="insights-empty">${esc(t('loading'))}</div>`;
  try {
    if (refresh) await api('/api/costs/refresh', {method: 'POST', body: '{}'});
    COSTS.data = await api(`/api/costs?days=${_costsDays()}`);
    if (COSTS.detailId) await _loadCostDetail(COSTS.detailId);
    else _renderCosts();
  } catch (e) {
    box.innerHTML = `<div class="insights-card"><div class="costs-error">${esc(t('error_prefix') + e.message)}</div></div>`;
  } finally {
    if (refresh && btn) { btn.style.opacity = ''; btn.disabled = false; }
  }
}

async function _loadCostDetail(id) {
  COSTS.detailId = id;
  COSTS.detail = await api(`/api/costs/service?id=${encodeURIComponent(id)}&days=${_costsDays()}`);
  _renderCostDetail();
}

function openCostService(id) {
  const box = $('costsContent');
  if (box) box.innerHTML = `<div class="insights-empty">${esc(t('loading'))}</div>`;
  _loadCostDetail(id).catch(e => {
    if (box) box.innerHTML = `<div class="insights-card"><div class="costs-error">${esc(e.message)}</div></div>`;
  });
}

function closeCostService() {
  COSTS.detailId = null;
  COSTS.detail = null;
  loadCosts();
}

// ── overview ──────────────────────────────────────────────────────────────

function _costsSeries(d) {
  // The top services by period total get their own colour; the rest share "Other".
  const ranked = (d.services || []).filter(s => (s.period_total || 0) > 0)
    .sort((a, b) => (b.period_total || 0) - (a.period_total || 0));
  const top = ranked.slice(0, _COSTS_TOP_N);
  const names = {};
  (d.services || []).concat(d.available || []).forEach(s => { names[s.id] = s.name; });
  return {
    keys: top.map(s => s.id),
    color: Object.fromEntries(top.map((s, i) => [s.id, _COSTS_SERIES[i % _COSTS_SERIES.length]])),
    names,
    hasOther: ranked.length > top.length,
  };
}

function _costsWeekly(daily) {
  // A long period gets weekly bars so a year still fits.
  if (daily.length <= 62) return daily;
  const rows = [];
  for (let i = 0; i < daily.length; i += 7) {
    const chunk = daily.slice(i, i + 7);
    const by = {};
    chunk.forEach(r => Object.entries(r.by_service || {}).forEach(([k, v]) => { by[k] = (by[k] || 0) + v; }));
    rows.push({day: chunk[0].day, end: chunk[chunk.length - 1].day,
               total: chunk.reduce((a, r) => a + (r.total || 0), 0), by_service: by});
  }
  return rows;
}

function _costsChart(daily, series) {
  if (!daily.length || !daily.some(r => r.total > 0)) {
    return `<div class="insights-empty">No spend recorded in this period yet.</div>`;
  }
  const rows = _costsWeekly(daily);
  const max = Math.max(...rows.map(r => r.total || 0), 0.0001);
  const labelEvery = Math.max(Math.ceil(rows.length / 7), 1);
  const bars = rows.map((r, idx) => {
    const segs = [];
    let other = 0;
    Object.entries(r.by_service || {}).forEach(([k, v]) => {
      if (series.color[k]) segs.push([k, v]); else other += v;
    });
    segs.sort((a, b) => series.keys.indexOf(a[0]) - series.keys.indexOf(b[0]));
    if (other > 0) segs.push(['_other', other]);
    const label = r.end ? `${_costsDayLabel(r.day)} – ${_costsDayLabel(r.end)}` : _costsDayLabel(r.day);
    const tip = label + ' · ' + _usd(r.total) + segs.map(([k, v]) =>
      `\n${k === '_other' ? 'Other' : (series.names[k] || k)}: ${_usd(v)}`).join('');
    const stack = segs.map(([k, v]) => {
      const pct = Math.max(v / max * 100, v > 0 ? 1 : 0).toFixed(2);
      return `<div style="height:${pct}%;background:${k === '_other' ? _COSTS_OTHER : series.color[k]}"></div>`;
    }).reverse().join('');
    const show = idx === 0 || idx === rows.length - 1 || idx % labelEvery === 0;
    return `<div class="costs-bar" title="${esc(tip)}" tabindex="0" aria-label="${esc(tip)}"><div class="costs-bar-stack">${stack}</div><span>${show ? esc(_costsDayLabel(r.day)) : ''}</span></div>`;
  }).join('');
  const legend = series.keys.map(k => `<span><i style="background:${series.color[k]}"></i>${esc(series.names[k] || k)}</span>`).join('') +
    (series.hasOther ? `<span><i style="background:${_COSTS_OTHER}"></i>Other</span>` : '');
  return `<div class="costs-chart">${bars}</div><div class="costs-legend">${legend}</div>`;
}

function _costsServiceRow(s, series) {
  const color = series && series.color[s.id];
  const dot = `<i class="costs-dot"${color ? ` style="background:${color}"` : ''}></i>`;
  const units = _costsUnitsLine(s.units);
  const balance = s.balance_usd !== null && s.balance_usd !== undefined
    ? `<span class="costs-chip">${_usd(s.balance_usd)}${s.limit_usd ? ' of ' + _usd(s.limit_usd) : ''} left</span>` : '';
  const open = `openCostService(${_jsArg(s.id)})`;
  // A service not in use yet (series === null) offers to connect, not a $0.00.
  const action = !series ? (s.kind === 'subscription' && !(s.fields || []).length ? 'Add price'
                             : (s.fields || []).length ? 'Connect' : 'Details')
    : s.status === 'needs_price' ? 'Set price' : '';
  const amount = action
    ? `<button type="button" class="costs-link-btn" onclick="event.stopPropagation();${open}">${action}</button>`
    : `<span class="costs-amount">${s.kind === 'free' ? 'Free' : _usd(s.period_total, _isApprox(s))}</span>`;
  const pill = series ? _costsPill(s.status) : '';
  return `<div class="costs-row" role="button" tabindex="0" onclick="${open}" onkeydown="if(event.key==='Enter')${open}">
    <div class="costs-row-main">${dot}<div class="costs-row-text"><div class="costs-row-name">${esc(s.name)} ${pill}</div>
      <div class="costs-row-sub">${esc(s.category || '')}${units ? ' · ' + esc(units) : ''}</div>${balance}</div></div>
    <div class="costs-row-side">${s.kind === 'free' || !series ? '' : _spark(s.spark)}${amount}</div>
  </div>`;
}

function _renderCosts() {
  const box = $('costsContent');
  const d = COSTS.data;
  if (!box || !d) return;
  const tot = d.totals || {};
  const prev = tot.previous_period;
  let delta = '';
  if (prev !== null && prev !== undefined && prev > 0) {
    const pct = ((tot.period - prev) / prev) * 100;
    const up = pct >= 0;
    delta = `<span class="costs-delta ${up ? 'up' : 'down'}">${up ? '▲' : '▼'} ${Math.abs(pct).toFixed(0)}% vs the ${d.days} days before</span>`;
  }
  const bySource = tot.by_source || {};
  const approxShare = tot.period > 0 ? (bySource.estimate || 0) / tot.period : 0;
  const head = `<div class="insights-card costs-hero">
    <div class="costs-hero-main"><div class="costs-hero-label">Last ${d.days} days</div>
      <div class="costs-hero-value">${_usd(tot.period)}</div>${delta}</div>
    <div class="costs-hero-stats">
      <div><span>Month to date</span><b>${_usd(tot.month_to_date)}</b></div>
      <div><span>Projected month</span><b>${_usd(tot.projected_month, true)}</b></div>
      <div><span>Estimated share</span><b>${(approxShare * 100).toFixed(0)}%</b></div>
    </div></div>`;

  const b = d.budget || {};
  const tone = b.used_pct >= 100 ? ' over' : b.used_pct >= 80 ? ' near' : '';
  const budget = b.monthly_usd
    ? `<div class="insights-card costs-budget"><div class="costs-budget-top"><span>Monthly budget · ${_usd(tot.month_to_date)} of ${_usd(b.monthly_usd)}</span><button type="button" class="costs-link-btn" onclick="setCostsBudget()">Change</button></div>
        <div class="costs-budget-track"><div class="costs-budget-fill${tone}" style="width:${Math.min(b.used_pct || 0, 100)}%"></div></div></div>`
    : `<div class="costs-budget-empty"><button type="button" class="costs-link-btn" onclick="setCostsBudget()">Set a monthly budget</button></div>`;

  const series = _costsSeries(d);
  const chart = `<div class="insights-card"><div class="insights-card-title">Daily spend</div>${_costsChart(d.daily || [], series)}</div>`;

  const paid = (d.services || []).filter(s => s.kind !== 'free');
  const free = (d.services || []).filter(s => s.kind === 'free');
  const list = `<div class="insights-card"><div class="insights-card-title">Services</div>
    ${paid.map(s => _costsServiceRow(s, series)).join('') || '<div class="insights-empty">Nothing yet.</div>'}
    ${free.length ? `<div class="costs-free-line">Free: ${free.map(s => esc(s.name)).join(', ')}</div>` : ''}</div>`;

  const available = (d.available || []).length
    ? `<div class="insights-card"><div class="insights-card-title">Available to connect</div>${d.available.map(s => _costsServiceRow(s, null)).join('')}</div>` : '';

  const add = `<div class="insights-card"><div class="insights-card-title">Add a subscription</div>
    <form class="costs-form costs-add" onsubmit="event.preventDefault();addCostsSubscription(this)">
      <input name="name" placeholder="Name (e.g. Domain, Apple Developer)" maxlength="60" required>
      <input name="amount" type="number" min="0" step="0.01" placeholder="Price $" required>
      <select name="interval"><option value="month">per month</option><option value="year">per year</option></select>
      <button type="submit" class="costs-btn">Add</button>
    </form></div>`;

  const foot = `<div class="costs-foot">Billing APIs synced ${esc(_costsAgo(d.last_run))} · ≈ = Jarvis's own count × list price · ↻ syncs now</div>`;
  box.innerHTML = head + budget + chart + list + available + add + foot;
}

async function setCostsBudget() {
  const cur = (COSTS.data && COSTS.data.budget && COSTS.data.budget.monthly_usd) || '';
  const v = await showPromptDialog({title: 'Monthly budget', message: 'USD per month. Leave empty to remove it.',
                                    value: cur ? String(cur) : '', placeholder: '150', inputType: 'number'});
  if (v === null || v === undefined) return;
  try {
    await api('/api/costs/budget', {method: 'POST', body: JSON.stringify({monthly_usd: String(v).trim() || null})});
    loadCosts();
  } catch (e) { showToast(e.message, 4000, 'error'); }
}

async function addCostsSubscription(form) {
  const body = {name: form.name.value, amount_usd: form.amount.value, interval: form.interval.value};
  try {
    await api('/api/costs/subscription', {method: 'POST', body: JSON.stringify(body)});
    showToast('Subscription added', 2500);
    loadCosts();
  } catch (e) { showToast(e.message, 4000, 'error'); }
}

// ── one service ───────────────────────────────────────────────────────────

function _costsDetailChart(daily) {
  if (!daily.some(r => r.effective > 0)) return '';
  // Weekly bars past ~2 months, like the overview, so 365 days fits a phone.
  let rows = daily;
  if (daily.length > 62) {
    rows = [];
    for (let i = 0; i < daily.length; i += 7) {
      const chunk = daily.slice(i, i + 7);
      const sum = k => chunk.reduce((a, r) => a + (Number(r[k]) || 0), 0);
      const any = k => chunk.some(r => r[k] !== null && r[k] !== undefined);
      rows.push({day: chunk[0].day, effective: sum('effective'),
                 billing: any('billing') ? sum('billing') : null, estimate: any('estimate') ? sum('estimate') : null,
                 source: chunk.some(r => r.source === 'estimate') && !chunk.some(r => r.source === 'billing') ? 'estimate' : 'billing'});
    }
  }
  const max = Math.max(...rows.map(r => r.effective || 0), 0.0001);
  const every = Math.max(Math.ceil(rows.length / 7), 1);
  const bars = rows.map((r, i) => {
    const both = r.billing !== null && r.billing !== undefined && r.estimate !== null && r.estimate !== undefined;
    const tip = `${_costsDayLabel(r.day)} · ${_usd(r.effective, r.source === 'estimate')}` +
      (both ? ` (Jarvis estimated ${_usd(r.estimate)})` : '');
    const pct = Math.max((r.effective || 0) / max * 100, r.effective > 0 ? 1 : 0).toFixed(2);
    const show = i === 0 || i === rows.length - 1 || i % every === 0;
    return `<div class="costs-bar" title="${esc(tip)}" tabindex="0" aria-label="${esc(tip)}"><div class="costs-bar-stack"><div style="height:${pct}%;background:${r.source === 'estimate' ? _COSTS_EST : 'var(--accent)'}"></div></div><span>${show ? esc(_costsDayLabel(r.day)) : ''}</span></div>`;
  }).join('');
  return `<div class="insights-card"><div class="insights-card-title">Daily</div><div class="costs-chart">${bars}</div>
    <div class="costs-legend"><span><i style="background:var(--accent)"></i>Billed / plan</span><span><i style="background:${_COSTS_EST}"></i>Estimated</span></div></div>`;
}

function _renderCostDetail() {
  const box = $('costsContent');
  const det = COSTS.detail;
  if (!box || !det) return;
  const s = det.service;
  const id = _jsArg(s.id);
  const approx = _isApprox(s);
  const free = s.kind === 'free';
  const stats = [
    [`Last ${det.days} days`, free ? 'Free' : _usd(s.period_total, approx)],
    ['Month to date', free ? 'Free' : _usd(s.month_to_date, approx)],
  ];
  if (s.billing_total !== null && s.billing_total !== undefined && s.estimate_total !== null && s.estimate_total !== undefined) {
    stats.push(['Jarvis estimated', _usd(s.estimate_total, true)]);
  }
  if (s.balance_usd !== null && s.balance_usd !== undefined) {
    stats.push(['Balance', _usd(s.balance_usd) + (s.limit_usd ? ' of ' + _usd(s.limit_usd) : '')]);
  }
  if (s.plan_usage_usd) stats.push(['Plan usage', _usd(s.plan_usage_usd)]);
  if (s.units && s.units.api_equiv_usd) stats.push(['Same calls on the API', _usd(s.units.api_equiv_usd, true)]);

  const units = _costsUnitsLine(s.units);
  const head = `<div class="costs-detail-head">
      <button type="button" class="costs-back" onclick="closeCostService()">‹ All services</button>
      <div class="costs-detail-title">${esc(s.name)} ${_costsPill(s.status)}</div>
      <div class="costs-row-sub">${esc(s.category || '')}${units ? ' · ' + esc(units) : ''}</div>
    </div>
    <div class="insights-card costs-detail-stats">${stats.map(([k, v]) => `<div><span>${esc(k)}</span><b>${esc(v)}</b></div>`).join('')}</div>`;

  const errorBox = s.error ? `<div class="insights-card costs-error">Last sync failed: ${esc(s.error)}</div>` : '';
  const link = s.url && /^https:\/\//.test(s.url) ? ` <a href="${esc(s.url)}" target="_blank" rel="noopener">Billing page ↗</a>` : '';
  const help = `<div class="insights-card costs-help">${esc(s.help || '')}${link}
    ${s.billing_connected ? `<div class="costs-row-sub">Synced ${esc(_costsAgo(s.last_synced))}</div>` : ''}</div>`;

  const chart = _costsDetailChart(det.daily || []);

  const models = (det.models || []).length
    ? `<div class="insights-card"><div class="insights-card-title">Models</div><div class="insights-table costs-table"><div class="insights-table-head"><span>Model</span><span>Calls</span><span>${s.kind === 'usage' ? 'Cost' : 'API value'}</span></div>${
        det.models.map(m => `<div class="insights-table-row"><span class="insights-model-name" title="${esc(m.model)}">${esc(m.model)}</span><span>${Number(m.calls).toLocaleString()}</span><span>${m.unpriced && !m.cost_usd ? '—' : _usd(m.cost_usd, true)}</span></div>`).join('')}</div></div>` : '';

  const items = (det.billing_items || []).length
    ? `<div class="insights-card"><div class="insights-card-title">Billed items</div><div class="insights-table costs-table"><div class="insights-table-head"><span>Item</span><span></span><span>Cost</span></div>${
        det.billing_items.map(it => `<div class="insights-table-row"><span class="insights-model-name" title="${esc(it.item)}">${esc(it.item)}</span><span></span><span>${_usd(it.cost_usd)}</span></div>`).join('')}</div></div>` : '';

  let connect = '';
  if ((s.fields || []).length) {
    connect = `<div class="insights-card"><div class="insights-card-title">Connect billing</div>
      <form class="costs-form" onsubmit="event.preventDefault();saveCostKeys(${id},this)">
        ${s.fields.map(f => `<label><span>${esc(f.label)}${f.is_set ? ' <em class="costs-saved">saved</em>' : ''}</span>
          <input name="${esc(f.key)}" type="${f.kind === 'secret' ? 'password' : 'text'}" autocomplete="off" spellcheck="false"
                 placeholder="${esc(f.is_set ? 'Saved. Paste a new one to replace it' : (f.placeholder || ''))}"></label>`).join('')}
        <button type="submit" class="costs-btn">Save &amp; sync</button>
      </form></div>`;
  }

  let plan = '';
  if (s.kind === 'subscription') {
    const sub = s.subscription || {};
    const chips = (s.suggested_plans || []).map(p =>
      `<button type="button" class="costs-chip-btn" onclick="fillCostPlan(this.form,${Number(p.amount_usd)},${_jsArg(p.interval)},${_jsArg(p.label)})">${esc(p.label)} · ${_usd(p.amount_usd)}/${p.interval === 'year' ? 'yr' : 'mo'}</button>`).join('');
    const amount = sub.amount_usd === null || sub.amount_usd === undefined ? '' : String(sub.amount_usd);
    plan = `<div class="insights-card"><div class="insights-card-title">Plan price</div>
      <form class="costs-form" onsubmit="event.preventDefault();saveCostPlan(${id},this)">
        ${chips ? `<div class="costs-chips">${chips}</div>` : ''}
        <div class="costs-form-row">
          <input name="plan" placeholder="Plan name" maxlength="60" value="${esc(sub.plan || '')}">
          <input name="amount" type="number" min="0" step="0.01" placeholder="Price $" value="${esc(amount)}" required>
          <select name="interval"><option value="month"${sub.interval !== 'year' ? ' selected' : ''}>per month</option><option value="year"${sub.interval === 'year' ? ' selected' : ''}>per year</option></select>
        </div>
        <label><span>Paying since (optional)</span><input name="since" type="date" value="${esc(sub.since || '')}"></label>
        <div class="costs-form-row"><button type="submit" class="costs-btn">Save price</button>
          ${s.subscription ? `<button type="button" class="costs-btn ghost" onclick="clearCostPlan(${id}, ${s.custom ? 'true' : 'false'})">${s.custom ? 'Delete subscription' : 'Clear price'}</button>` : ''}</div>
      </form></div>`;
  }

  const disconnect = (s.fields || []).some(f => f.is_set && f.billing_only)
    ? `<div class="costs-foot"><button type="button" class="costs-link-btn danger" onclick="disconnectCostService(${id})">Disconnect billing</button></div>` : '';

  box.innerHTML = head + errorBox + help + chart + models + items + connect + plan + disconnect;
}

async function saveCostKeys(id, form) {
  const fields = {};
  Array.from(form.querySelectorAll('input')).forEach(i => { if (i.value.trim()) fields[i.name] = i.value.trim(); });
  if (!Object.keys(fields).length) { showToast('Paste a key first', 2500); return; }
  const btn = form.querySelector('button[type=submit]');
  if (btn) { btn.disabled = true; btn.textContent = 'Syncing…'; }
  try {
    const res = await api('/api/costs/connect', {method: 'POST', body: JSON.stringify({service: id, fields, days: _costsDays()})});
    const sync = res && res.sync;
    if (sync && sync.ok === false) showToast('Saved, but the sync failed: ' + sync.error, 6000, 'error');
    else if (res && res.pending) showToast('Saved. Syncing now; check back in a minute.', 4000);
    else showToast('Connected', 2500);
    COSTS.detail = (res && res.detail) || COSTS.detail;
    _renderCostDetail();
  } catch (e) {
    showToast(e.message, 4000, 'error');
    if (btn) { btn.disabled = false; btn.textContent = 'Save & sync'; }
  }
}

function fillCostPlan(form, amount, interval, label) {
  form.amount.value = amount;
  form.interval.value = interval === 'year' ? 'year' : 'month';
  form.plan.value = label;
}

async function saveCostPlan(id, form) {
  const body = {service: id, amount_usd: form.amount.value, interval: form.interval.value,
                plan: form.plan.value, since: form.since.value || null};
  try {
    await api('/api/costs/subscription', {method: 'POST', body: JSON.stringify(body)});
    showToast('Saved', 2000);
    await _loadCostDetail(id);
  } catch (e) { showToast(e.message, 4000, 'error'); }
}

async function clearCostPlan(id, custom) {
  const ok = await showConfirmDialog({title: custom ? 'Delete this subscription?' : 'Clear the plan price?',
    message: custom ? 'Its history goes too.' : 'The days counted at this price are removed.',
    confirmLabel: custom ? 'Delete' : 'Clear', danger: true});
  if (!ok) return;
  try {
    await api('/api/costs/subscription', {method: 'POST', body: JSON.stringify({service: id, amount_usd: null})});
    if (custom) closeCostService(); else await _loadCostDetail(id);
  } catch (e) { showToast(e.message, 4000, 'error'); }
}

async function disconnectCostService(id) {
  const ok = await showConfirmDialog({title: 'Disconnect billing?',
    message: 'The billing key saved here is removed. History stays.', confirmLabel: 'Disconnect', danger: true});
  if (!ok) return;
  try {
    const res = await api('/api/costs/disconnect', {method: 'POST', body: JSON.stringify({service: id})});
    if (res && !res.removed_keys) {
      showToast('That key also runs the service. Remove it in Settings → Providers.', 5000);
    }
    await _loadCostDetail(id);
  } catch (e) { showToast(e.message, 4000, 'error'); }
}

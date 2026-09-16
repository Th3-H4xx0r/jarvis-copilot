// JarvisCopilot — Integrations.
//
// This is what the Tasks tab became. A scheduled job no longer floats on its own:
// it belongs to an integration, alongside the data that integration keeps in the
// registry and the skills written for it. The sidebar lists integrations; picking
// one shows its schedules, its data and its skills in the main pane.
//
//   sidebar  #cronList      → renderIntegrationsSidebar(), called from loadCrons()
//   detail   #taskDetailBody → openIntegration() → schedules / data / skills
//
// Schedules still open through openCronDetail() in panels.js — a schedule is still
// a cron job, so run/pause/edit are unchanged. Only the way in is different.

let _intgList = [];
let _intgCurrent = null;       // id of the integration shown in the main pane

// ── sidebar ──────────────────────────────────────────────────────────────────
async function loadIntegrations(animate) {
  return loadCrons(animate);   // fetches jobs, then calls back into the sidebar render
}

async function renderIntegrationsSidebar(box) {
  if (!box) return;
  let data;
  try {
    data = await api('/api/integrations');
  } catch (e) {
    box.innerHTML = `<div class="intg-note intg-note--error">${esc(t('error_prefix'))}${esc(e.message)}</div>`;
    return;
  }
  _intgList = data.integrations || [];
  if (!_intgList.length) {
    box.innerHTML = `<div class="intg-note">${esc(t('intg_none'))}</div>`;
    return;
  }
  box.innerHTML = '';
  for (const item of _intgList) box.appendChild(_intgCard(item));
}

function _intgCard(item) {
  const el = document.createElement('div');
  el.className = 'cron-item intg-card';
  el.id = 'intg-' + item.id;
  if (item.id === _intgCurrent) el.classList.add('active');
  const paused = item.status && item.status !== 'active';
  const unread = _intgHasNewRun(item.id);
  el.innerHTML = `
    <div class="intg-card-head">
      <span class="intg-card-icon" aria-hidden="true">${esc(_intgGlyph(item.icon))}</span>
      <span class="cron-name" title="${esc(item.name)}">${esc(item.name)}</span>
      ${unread ? '<span class="intg-card-dot" title="New run"></span>' : ''}
      ${paused ? `<span class="cron-status paused">${esc(item.status)}</span>` : ''}
    </div>
    ${item.description ? `<div class="intg-card-desc">${esc(item.description)}</div>` : ''}
    <div class="intg-card-meta">${esc(_intgMeta(item))}</div>`;
  el.onclick = () => openIntegration(item.id);
  return el;
}

function _intgMeta(item) {
  const bits = [];
  const sched = item.schedule_count || 0;
  if (sched) {
    const off = sched - (item.enabled_schedule_count || 0);
    bits.push(sched + (sched === 1 ? ' schedule' : ' schedules') + (off ? ` (${off} off)` : ''));
  }
  if (item.record_count) bits.push(item.record_count.toLocaleString() + ' records');
  else if (item.document_count) bits.push(item.document_count + ' stored');
  if (item.skill_count) bits.push(item.skill_count + (item.skill_count === 1 ? ' skill' : ' skills'));
  return bits.length ? bits.join(' · ') : 'nothing yet';
}

// One glyph per integration. The icon field is a plain word so the phone and the
// web can each draw it their own way; here that means an emoji.
const _INTG_GLYPHS = {
  music: '🎧', envelope: '✉️', house: '🏠', airplane: '✈️', chips: '🎲',
  chart: '📈', dots: '⋯', clock: '⏱', bolt: '⚡', book: '📓', heart: '❤️',
};
function _intgGlyph(icon) { return _INTG_GLYPHS[String(icon || '').toLowerCase()] || '◈'; }

// ── detail ───────────────────────────────────────────────────────────────────
async function openIntegration(id) {
  _intgCurrent = id;
  document.querySelectorAll('.cron-item').forEach(e => e.classList.remove('active'));
  const card = $('intg-' + id);
  if (card) card.classList.add('active');
  if (typeof _clearCronDetail === 'function') _clearCronDetail();   // drop any open job
  _intgCurrent = id;                                               // _clearCronDetail may re-render

  const title = $('taskDetailTitle'), body = $('taskDetailBody'), empty = $('taskDetailEmpty');
  if (empty) empty.style.display = 'none';
  if (body) { body.style.display = ''; body.innerHTML = `<div class="intg-note">${esc(t('loading'))}</div>`; }

  let data;
  try {
    data = await api('/api/integrations/' + encodeURIComponent(id));
  } catch (e) {
    if (body) body.innerHTML = `<div class="intg-note intg-note--error">${esc(e.message)}</div>`;
    return;
  }
  if (_intgCurrent !== id) return;                                 // user moved on while loading
  if (title) title.textContent = `${_intgGlyph(data.icon)}  ${data.name || id}`;
  if (body) body.innerHTML = _intgDetailHtml(data);
  _intgBindDetail(data);
}

function _intgDetailHtml(d) {
  const schedules = d.schedules || [], collections = d.collections || [],
        // imported_files is the one-time migration's own bookkeeping, not data
        // this integration keeps.
        documents = (d.documents || []).filter(doc => doc.key !== 'imported_files'),
        skills = d.skills || [];
  const paused = d.status && d.status !== 'active';
  return `
    <div class="intg-detail">
      ${d.description ? `<p class="intg-detail-desc">${esc(d.description)}</p>` : ''}
      <div class="intg-detail-actions">
        <button class="intg-btn" data-act="new-schedule">New schedule</button>
        <button class="intg-btn" data-act="toggle">${paused ? 'Resume' : 'Pause'} integration</button>
        <button class="intg-btn intg-btn--danger" data-act="delete">Delete</button>
      </div>

      <section class="intg-section">
        <h4 class="intg-section-title">Schedules <span class="intg-count">${schedules.length}</span></h4>
        ${schedules.length ? schedules.map(s => `
          <div class="intg-row intg-row--click" data-job="${esc(s.id)}">
            <div class="intg-row-main">
              <span class="intg-row-name">${esc(s.name || s.id)}</span>
              <span class="intg-row-sub">${esc(_intgWhen(s))}</span>
            </div>
            ${_intgProfileBadge(s)}${_intgStatusPill(s)}
          </div>`).join('') : `<div class="intg-empty-row">No schedules yet.</div>`}
      </section>

      <section class="intg-section">
        <h4 class="intg-section-title">Data <span class="intg-count">${collections.length + documents.length}</span></h4>
        ${collections.map(c => `
          <div class="intg-row intg-row--click" data-collection="${esc(c.name)}">
            <div class="intg-row-main">
              <span class="intg-row-name">${esc(c.name)}</span>
              <span class="intg-row-sub">${esc(c.description || 'no description yet')}</span>
            </div>
            <span class="intg-row-count">${Number(c.count || 0).toLocaleString()}</span>
          </div>`).join('')}
        ${documents.map(doc => `
          <div class="intg-row intg-row--click" data-document="${esc(doc.key)}">
            <div class="intg-row-main">
              <span class="intg-row-name">${esc(doc.key)}</span>
              <span class="intg-row-sub">${esc(doc.description || 'a stored document')}</span>
            </div>
            <span class="intg-row-count">${_intgBytes(doc.bytes)}</span>
          </div>`).join('')}
        ${!collections.length && !documents.length ? `<div class="intg-empty-row">Nothing stored yet.</div>` : ''}
      </section>

      <section class="intg-section">
        <h4 class="intg-section-title">Skills <span class="intg-count">${skills.length}</span></h4>
        ${skills.length ? skills.map(s => `
          <div class="intg-row">
            <div class="intg-row-main">
              <span class="intg-row-name">${esc(s.name)}</span>
              <span class="intg-row-sub">${esc(s.description || '')}</span>
            </div>
          </div>`).join('')
        : `<div class="intg-empty-row">No skills claim this integration. A skill joins one by
             naming it in its front matter: <code>integration: ${esc(d.id)}</code>.</div>`}
      </section>
    </div>`;
}

function _intgBindDetail(d) {
  const body = $('taskDetailBody');
  if (!body) return;
  body.querySelectorAll('[data-job]').forEach(row => {
    row.onclick = () => { if (typeof openCronDetail === 'function') openCronDetail(row.dataset.job); };
  });
  body.querySelectorAll('[data-collection]').forEach(row => {
    row.onclick = () => openIntegrationRecords(d.id, row.dataset.collection);
  });
  body.querySelectorAll('[data-document]').forEach(row => {
    row.onclick = () => openIntegrationDocument(d.id, row.dataset.document);
  });
  const act = sel => body.querySelector(`[data-act="${sel}"]`);
  const newBtn = act('new-schedule');
  if (newBtn) newBtn.onclick = () => {
    _intgPendingForNewJob = d.id;
    if (typeof openCronCreate === 'function') openCronCreate();
  };
  const toggle = act('toggle');
  if (toggle) toggle.onclick = () => _intgSetStatus(d.id, d.status === 'active' ? 'paused' : 'active');
  const del = act('delete');
  if (del) del.onclick = () => _intgDelete(d);
}

// Which integration a job created from the Integrations page belongs to. Read by
// saveCronForm() in panels.js when it POSTs, then cleared.
let _intgPendingForNewJob = null;

// Which agent profile a schedule runs under. This used to sit on the Tasks list
// row; the schedule row inside its integration is where it lives now.
function _intgProfileBadge(s) {
  const job = _intgJob(s.id);
  if (!job || typeof _cronProfileLabel !== 'function') return '';
  return `<span class="cron-profile-badge" title="${esc(_cronProfileTitle(job.profile))}">${esc(_cronProfileLabel(job.profile))}</span>`;
}

function _intgJob(id) {
  return typeof _cronList !== 'undefined' && _cronList ? _cronList.find(j => j.id === id) : null;
}

// A job's real status lives in panels.js (paused, needs attention, schedule error).
// Use it when the job is in _cronList; fall back to the schedule's own enabled flag.
function _intgStatusPill(s) {
  const job = _intgJob(s.id);
  if (job && typeof _cronStatusMeta === 'function') {
    const meta = _cronStatusMeta(job);
    return `<span class="cron-status ${meta.listClass}">${esc(meta.label)}</span>`;
  }
  const off = s.enabled === false;
  return `<span class="cron-status ${off ? 'paused' : 'active'}">${off ? 'paused' : 'on'}</span>`;
}

// The unread dot the Tasks list used to show, rolled up to the integration.
function _intgHasNewRun(id) {
  if (typeof _cronNewJobIds === 'undefined' || !_cronNewJobIds.size) return false;
  if (typeof _cronList === 'undefined' || !_cronList) return false;
  return _cronList.some(j => ((j.integration || 'general') === id)
                             && _cronNewJobIds.has(String(j.id)));
}

function _intgWhen(s) {
  const sch = s.schedule;
  let when = '';
  if (sch && typeof sch === 'object') {
    if (sch.kind === 'interval') when = `every ${sch.minutes} min`;
    else if (sch.expr) when = sch.expr;
    else when = sch.kind || '';
  } else if (sch) when = String(sch);
  if (s.next_run) when += ' · next ' + _intgTime(s.next_run);
  return when;
}

function _intgTime(ts) {
  if (!ts) return '';
  const d = new Date(Number(ts) * (Number(ts) > 1e12 ? 1 : 1000));
  if (isNaN(d.getTime())) return '';
  return d.toLocaleString(undefined, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
}

function _intgBytes(n) {
  n = Number(n || 0);
  if (n < 1024) return n + ' B';
  if (n < 1024 * 1024) return Math.round(n / 1024) + ' KB';
  return (n / (1024 * 1024)).toFixed(1) + ' MB';
}

// ── data views ───────────────────────────────────────────────────────────────
async function openIntegrationRecords(id, collection) {
  const body = $('taskDetailBody'), title = $('taskDetailTitle');
  if (!body) return;
  body.innerHTML = `<div class="intg-note">${esc(t('loading'))}</div>`;
  let data;
  try {
    data = await api(`/api/integrations/${encodeURIComponent(id)}/records?collection=${encodeURIComponent(collection)}&limit=100`);
  } catch (e) {
    body.innerHTML = `<div class="intg-note intg-note--error">${esc(e.message)}</div>`;
    return;
  }
  if (title) title.textContent = `${collection} — ${id}`;
  const rows = data.records || [];
  // Columns come from the records themselves: the registry does not impose a shape,
  // so the table shows whatever fields these records actually carry.
  const columns = [];
  for (const r of rows) for (const k of Object.keys(r)) {
    if (k !== 'ts' && k !== 'id' && !columns.includes(k)) columns.push(k);
  }
  body.innerHTML = `
    <div class="intg-detail">
      <button class="intg-btn intg-back" data-act="back">← ${esc(id)}</button>
      <div class="intg-note">${rows.length} record${rows.length === 1 ? '' : 's'}, newest first.</div>
      <div class="intg-table-wrap">
        <table class="intg-table">
          <thead><tr><th>when</th>${columns.map(c => `<th>${esc(c)}</th>`).join('')}</tr></thead>
          <tbody>${rows.map(r => `<tr>
            <td class="intg-td-when">${esc(_intgTime(r.ts))}</td>
            ${columns.map(c => `<td>${esc(_intgCell(r[c]))}</td>`).join('')}
          </tr>`).join('')}</tbody>
        </table>
      </div>
    </div>`;
  const back = body.querySelector('[data-act="back"]');
  if (back) back.onclick = () => openIntegration(id);
}

async function openIntegrationDocument(id, key) {
  const body = $('taskDetailBody'), title = $('taskDetailTitle');
  if (!body) return;
  body.innerHTML = `<div class="intg-note">${esc(t('loading'))}</div>`;
  let data;
  try {
    data = await api(`/api/integrations/${encodeURIComponent(id)}/documents/${encodeURIComponent(key)}`);
  } catch (e) {
    body.innerHTML = `<div class="intg-note intg-note--error">${esc(e.message)}</div>`;
    return;
  }
  if (title) title.textContent = `${key} — ${id}`;
  body.innerHTML = `
    <div class="intg-detail">
      <button class="intg-btn intg-back" data-act="back">← ${esc(id)}</button>
      ${data.description ? `<div class="intg-note">${esc(data.description)}</div>` : ''}
      <pre class="intg-doc">${esc(JSON.stringify(data.body, null, 2))}</pre>
    </div>`;
  const back = body.querySelector('[data-act="back"]');
  if (back) back.onclick = () => openIntegration(id);
}

function _intgCell(value) {
  if (value === null || value === undefined) return '';
  if (typeof value === 'object') return JSON.stringify(value).slice(0, 120);
  return String(value).slice(0, 120);
}

// ── create / pause / delete ──────────────────────────────────────────────────
async function openIntegrationCreate() {
  const name = await showPromptDialog({
    title: 'New integration',
    message: 'What should Jarvis call it? It gets its own data, schedules and skills.',
    placeholder: 'Gym Sessions',
  });
  if (!name) return;
  try {
    const made = await api('/api/integrations', { method: 'POST', body: JSON.stringify({ name }) });
    await loadIntegrations();
    if (made && made.id) openIntegration(made.id);
    showToast(`${name} created`);
  } catch (e) { showToast('Could not create it: ' + e.message, 4000); }
}

async function _intgSetStatus(id, status) {
  try {
    await api(`/api/integrations/${encodeURIComponent(id)}/status`,
              { method: 'POST', body: JSON.stringify({ status }) });
    await loadIntegrations();
    openIntegration(id);
  } catch (e) { showToast('Could not change it: ' + e.message, 4000); }
}

async function _intgDelete(d) {
  const count = (d.schedules || []).length;
  const ok = await showConfirmDialog({
    title: `Delete ${d.name}?`,
    message: count
      ? `Its ${count} schedule${count === 1 ? '' : 's'} and everything it has stored go with it. This cannot be undone.`
      : 'Everything it has stored goes with it. This cannot be undone.',
    confirmLabel: 'Delete',
    danger: true,
    focusCancel: true,
  });
  if (!ok) return;
  try {
    await api('/api/integrations/' + encodeURIComponent(d.id), { method: 'DELETE' });
    _intgCurrent = null;
    if (typeof _clearCronDetail === 'function') _clearCronDetail();
    await loadIntegrations();
    showToast(`${d.name} deleted`);
  } catch (e) { showToast('Could not delete it: ' + e.message, 4000); }
}

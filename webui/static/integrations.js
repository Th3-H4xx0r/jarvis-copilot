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
// Which screen the main pane is showing. Every async render checks it is still the
// current one before writing, so a slow response cannot land under a later screen.
let _intgView = '';

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

  _intgView = `integration:${id}`;
  const mine = _intgView;
  let data;
  try {
    data = await api('/api/integrations/' + encodeURIComponent(id));
  } catch (e) {
    if (_intgView !== mine) return;
    if (body) body.innerHTML = `<div class="intg-note intg-note--error">${esc(e.message)}</div>`;
    return;
  }
  if (_intgView !== mine) return;                                  // user moved on while loading
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
        <button class="intg-btn intg-btn--danger" data-act="delete">Delete…</button>
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
            ${_intgDeleteButton('schedule', s.id, s.name || s.id)}
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
            ${_intgDeleteButton('collection', c.name, c.name, Number(c.count || 0))}
          </div>`).join('')}
        ${documents.map(doc => `
          <div class="intg-row intg-row--click" data-document="${esc(doc.key)}">
            <div class="intg-row-main">
              <span class="intg-row-name">${esc(doc.key)}</span>
              <span class="intg-row-sub">${esc(doc.description || 'a stored document')}</span>
            </div>
            <span class="intg-row-count">${_intgBytes(doc.bytes)}</span>
            ${_intgDeleteButton('document', doc.key, doc.key)}
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
            ${_intgDeleteButton('skill', s.name, s.name)}
          </div>`).join('')
        : `<div class="intg-empty-row">No skills claim this integration. A skill joins one by
             naming it in its front matter: <code>integration: ${esc(d.id)}</code>.</div>`}
      </section>
    </div>`;
}

// A row's delete. `what` decides which confirmation it opens.
function _intgDeleteButton(what, id, label, count) {
  return `<button class="intg-row-del" title="Delete ${esc(label)}"
    data-del="${esc(what)}" data-del-id="${esc(id)}" data-del-label="${esc(label)}"
    data-del-count="${Number(count || 0)}" aria-label="Delete ${esc(label)}">×</button>`;
}

function _intgBindDetail(d) {
  const body = $('taskDetailBody');
  if (!body) return;
  body.querySelectorAll('[data-job]').forEach(row => {
    row.onclick = () => {
      if (typeof openCronDetail === 'function') openCronDetail(row.dataset.job);
      // openCronDetail clears .active from every .cron-item and looks for a row
      // that no longer exists; the integration stays the selected thing.
      const card = $('intg-' + _intgCurrent);
      if (card) card.classList.add('active');
    };
  });
  body.querySelectorAll('[data-del]').forEach(btn => {
    btn.onclick = event => {
      event.stopPropagation();          // the row behind it opens on click
      _intgDeleteRow(d, btn.dataset);
    };
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
    if (typeof openCronCreate === 'function') openCronCreate();
    // After openCronCreate, which clears the flag: this form is the one that
    // belongs to this integration.
    _intgPendingForNewJob = d.id;
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
  // Cron records ISO strings (next_run_at); the registry records epoch seconds.
  const n = Number(ts);
  const d = Number.isFinite(n) && String(ts).trim() !== ''
    ? new Date(n * (n > 1e12 ? 1 : 1000))
    : new Date(String(ts));
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
  _intgCurrent = id;
  _intgView = `records:${id}:${collection}`;
  const mine = _intgView;
  body.innerHTML = `<div class="intg-note">${esc(t('loading'))}</div>`;
  let data;
  try {
    data = await api(`/api/integrations/${encodeURIComponent(id)}/records?collection=${encodeURIComponent(collection)}&limit=100`);
  } catch (e) {
    if (_intgView !== mine) return;
    body.innerHTML = `<div class="intg-note intg-note--error">${esc(e.message)}</div>`;
    return;
  }
  if (_intgView !== mine) return;        // the user moved on while this was loading
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
  _intgCurrent = id;
  _intgView = `document:${id}:${key}`;
  const mine = _intgView;
  body.innerHTML = `<div class="intg-note">${esc(t('loading'))}</div>`;
  let data;
  try {
    data = await api(`/api/integrations/${encodeURIComponent(id)}/documents/${encodeURIComponent(key)}`);
  } catch (e) {
    if (_intgView !== mine) return;
    body.innerHTML = `<div class="intg-note intg-note--error">${esc(e.message)}</div>`;
    return;
  }
  if (_intgView !== mine) return;
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
/// Setting one up is a conversation, not a form.
///
/// The server opens a session pinned to this one job — the registry, cron and
/// skill tools, and a directive telling it to ask for what it needs and build
/// each piece as it is settled — and we hand the user to the chat panel, which
/// already streams that, draws its tool cards and lets them answer. The phone
/// does the same thing inside a full-screen sheet.
async function openIntegrationCreate() {
  let setup;
  try {
    setup = await api('/api/integrations/setup/start', {
      method: 'POST',
      // The profile this tab is on, like every other session we create.
      body: JSON.stringify({ name: '', profile: (typeof _cronProfile !== 'undefined' && _cronProfile) || (S && S.profile) || '' }),
    });
  } catch (e) {
    showToast('Could not start: ' + e.message, 4000);
    return;
  }
  if (typeof switchPanel === 'function') switchPanel('chat');
  if (typeof loadSession === 'function') await loadSession(setup.session_id);
  const composer = $('msg');
  if (composer) {
    composer.value = 'Help me set up a new integration.';
    composer.focus();
    composer.setSelectionRange(composer.value.length, composer.value.length);
  }
  showToast('Tell Jarvis what you want it to track');
}

async function _intgSetStatus(id, status) {
  try {
    await api(`/api/integrations/${encodeURIComponent(id)}/status`,
              { method: 'POST', body: JSON.stringify({ status }) });
    await loadIntegrations();
    openIntegration(id);
  } catch (e) { showToast('Could not change it: ' + e.message, 4000); }
}

/// One row's delete: confirm in the row's own terms, then do it and redraw.
async function _intgDeleteRow(d, data) {
  const label = data.delLabel, id = data.delId;
  if (data.del === 'skill') return _intgDeleteSkill(d, id, label);

  const message = data.del === 'collection'
    ? `Every record in it goes — ${Number(data.delCount).toLocaleString()} of them. This cannot be undone.`
    : data.del === 'schedule'
      ? 'It stops running and its history goes with it. This cannot be undone.'
      : 'What it holds goes with it. This cannot be undone.';
  const ok = await showConfirmDialog({
    title: `Delete ${label}?`, message, confirmLabel: 'Delete', danger: true, focusCancel: true,
  });
  if (!ok) return;
  try {
    if (data.del === 'schedule') {
      await api('/api/crons/delete', { method: 'POST', body: JSON.stringify({ job_id: id }) });
    } else {
      const part = data.del === 'collection' ? 'collections' : 'documents';
      await api(`/api/integrations/${encodeURIComponent(d.id)}/${part}/${encodeURIComponent(id)}`,
                { method: 'DELETE' });
    }
    showToast(`${label} deleted`);
  } catch (e) { showToast('Could not delete it: ' + e.message, 4000); }
  await loadIntegrations();
  openIntegration(d.id);
}

/// A skill gets a choice, not a yes/no: unlinking it is cheap to undo, taking it
/// out of service is not, and the two must never be one button.
async function _intgDeleteSkill(d, name, label) {
  const mode = await showChoiceDialog({
    title: `Delete ${label}?`,
    message: 'Removing it from this integration leaves the skill alone. '
           + 'Deleting it takes it out of service everywhere.',
    choices: [
      { value: 'unlink', label: 'Remove from this integration' },
      { value: 'file', label: 'Delete the skill entirely', danger: true },
    ],
  });
  if (!mode) return;
  try {
    await api(`/api/integrations/${encodeURIComponent(d.id)}/skills/${encodeURIComponent(name)}?mode=${mode}`,
              { method: 'DELETE' });
    showToast(mode === 'file' ? `${label} deleted` : `${label} removed from ${d.name}`);
  } catch (e) { showToast('Could not delete it: ' + e.message, 4000); }
  await loadIntegrations();
  openIntegration(d.id);
}

/// Deleting an integration asks which parts.
///
/// The four mean different things: dropping the data leaves the schedules running
/// against nothing, removing the schedules leaves the history readable, and taking
/// a skill out of service reaches past this integration entirely. So the sheet asks,
/// says what the answer adds up to, and only then offers a red button.
async function _intgDelete(d) {
  const counts = {
    schedules: (d.schedules || []).length,
    collections: (d.collections || []).length,
    documents: (d.documents || []).length,
    skills: (d.skills || []).length,
  };
  const parts = await _intgDeleteSheet(d, counts);
  if (!parts) return;
  try {
    await api('/api/integrations/' + encodeURIComponent(d.id),
              { method: 'DELETE', body: JSON.stringify(parts) });
    showToast(parts.space ? `${d.name} deleted` : 'Removed');
  } catch (e) {
    showToast('Could not delete it: ' + e.message, 4000);
    return;
  }
  if (parts.space) {
    _intgCurrent = null;
    if (typeof _clearCronDetail === 'function') _clearCronDetail();
    await loadIntegrations();
  } else {
    await loadIntegrations();
    openIntegration(d.id);
  }
}

function _intgDeleteSheet(d, counts) {
  const plural = (n, noun) => `${n} ${noun}${n === 1 ? '' : 's'}`;
  const dataDetail = counts.collections + counts.documents
    ? [counts.collections ? plural(counts.collections, 'collection') : '',
       counts.documents ? plural(counts.documents, 'document') : ''].filter(Boolean).join(', ')
    : 'Nothing stored';
  const rows = [
    ['schedules', 'Schedules', plural(counts.schedules, 'schedule'), true],
    ['data', 'Data', dataDetail, true],
    ['skills', 'Skills', plural(counts.skills, 'skill'), true],
    ['skill_files', 'Also delete their files',
     'Otherwise they just stop belonging here', false, true],
    ['space', 'The integration itself', d.id, true],
  ];
  return _intgModal({
    title: `Delete ${d.name}`,
    bodyHtml: `<div class="intg-choice-list">${rows.map(([key, label, note, on, indented]) => `
        <label class="intg-choice${indented ? ' intg-choice--sub' : ''}">
          <input type="checkbox" data-part="${esc(key)}" ${on ? 'checked' : ''}>
          <span><span class="intg-choice-name">${esc(label)}</span>
            <span class="intg-choice-note">${esc(note)}</span></span>
        </label>`).join('')}</div>
      <div class="intg-choice-summary" data-summary></div>`,
    confirmLabel: 'Delete',
    danger: true,
    wire: (root, setEnabled) => {
      const read = () => {
        const parts = {};
        root.querySelectorAll('[data-part]').forEach(box => { parts[box.dataset.part] = box.checked; });
        return parts;
      };
      const refresh = () => {
        const parts = read();
        const bits = [];
        if (parts.schedules && counts.schedules) bits.push(plural(counts.schedules, 'schedule'));
        const data = counts.collections + counts.documents;
        if (parts.data && data) bits.push(plural(data, 'data set'));
        if (parts.skills && counts.skills) {
          bits.push(plural(counts.skills, 'skill') + (parts.skill_files ? ' (and their files)' : ''));
        }
        if (parts.space) bits.push('the integration itself');
        const summary = root.querySelector('[data-summary]');
        const nothing = !parts.schedules && !parts.data && !parts.skills && !parts.space;
        summary.textContent = nothing ? 'Nothing selected.'
          : `This removes ${bits.slice(0, -1).join(', ')}${bits.length > 1 ? ' and ' : ''}${bits[bits.length - 1]}. It cannot be undone.`;
        summary.classList.toggle('intg-choice-summary--live', !nothing);
        setEnabled(!nothing);
      };
      root.querySelectorAll('[data-part]').forEach(box => { box.onchange = refresh; });
      refresh();
      return read;
    },
  });
}

/// A dialog with one button per choice, for a decision that is not yes/no.
function showChoiceDialog({ title, message, choices }) {
  return _intgModal({
    title,
    bodyHtml: `<p class="intg-modal-msg">${esc(message)}</p>`,
    buttons: choices.map(c => ({ value: c.value, label: c.label, danger: c.danger })),
  });
}

/// The one modal these dialogs are built from. Resolves with the chosen value, or
/// null when it is dismissed.
function _intgModal({ title, bodyHtml, confirmLabel, danger, wire, buttons }) {
  return new Promise(resolve => {
    const overlay = document.createElement('div');
    overlay.className = 'intg-modal-overlay';
    const actions = buttons
      ? buttons.map((b, i) => `<button class="intg-btn${b.danger ? ' intg-btn--danger' : ''}" data-choice="${i}">${esc(b.label)}</button>`).join('')
      : `<button class="intg-btn intg-btn--danger" data-confirm>${esc(confirmLabel || 'OK')}</button>`;
    overlay.innerHTML = `
      <div class="intg-modal" role="dialog" aria-modal="true" aria-label="${esc(title)}">
        <div class="intg-modal-title">${esc(title)}</div>
        <div class="intg-modal-body">${bodyHtml}</div>
        <div class="intg-modal-actions">
          <button class="intg-btn" data-cancel>Cancel</button>
          ${actions}
        </div>
      </div>`;
    document.body.appendChild(overlay);

    const close = value => {
      document.removeEventListener('keydown', onKey);
      overlay.remove();
      resolve(value);
    };
    const onKey = e => { if (e.key === 'Escape') close(null); };
    document.addEventListener('keydown', onKey);
    overlay.onclick = e => { if (e.target === overlay) close(null); };
    overlay.querySelector('[data-cancel]').onclick = () => close(null);

    const confirmBtn = overlay.querySelector('[data-confirm]');
    let read = () => true;
    if (wire) read = wire(overlay, on => { if (confirmBtn) confirmBtn.disabled = !on; });
    if (confirmBtn) confirmBtn.onclick = () => close(read());
    overlay.querySelectorAll('[data-choice]').forEach(btn => {
      btn.onclick = () => close(buttons[Number(btn.dataset.choice)].value);
    });
    setTimeout(() => (overlay.querySelector('[data-confirm],[data-choice]') || overlay
      .querySelector('[data-cancel]')).focus(), 0);
  });
}

// ── the plan card ────────────────────────────────────────────────────────────
// When Jarvis proposes an integration it does not create one. It calls
// integration_plan_propose, and that tool call renders here as a card the user
// acts on: what it is for, the schedules it wants, the data it will keep, the
// skills it would write, then Create or Cancel. Nothing exists until Create.
//
// The layout is fixed on purpose. The model fills the slots with text and
// nothing else, which is what keeps every card looking like the app rather than
// like whatever the model felt like emitting that turn.

function _intgPlanIdFrom(tc) {
  // The tool result starts {"ok": true, "plan": {"id": "...", so the id survives
  // the 200-character snippet the chat keeps.
  const m = /"plan"\s*:\s*\{\s*"id"\s*:\s*"([A-Za-z0-9]+)"/.exec(tc && tc.snippet || '');
  return m ? m[1] : '';
}

function buildIntegrationPlanCard(tc) {
  const planId = _intgPlanIdFrom(tc);
  if (!planId) return null;
  const row = document.createElement('div');
  row.className = 'tool-card-row plan-card-row';
  row.innerHTML = `<div class="plan-card plan-card--loading"><div class="plan-card-body">${esc(t('loading'))}</div></div>`;
  _intgPlanFill(row, planId);
  return row;
}

async function _intgPlanFill(row, planId) {
  let plan;
  try {
    plan = await api('/api/integrations/plans/' + encodeURIComponent(planId));
  } catch (e) {
    row.innerHTML = `<div class="plan-card"><div class="plan-card-body">${esc(e.message)}</div></div>`;
    return;
  }
  row.innerHTML = _intgPlanHtml(plan);
  const act = name => row.querySelector(`[data-plan-act="${name}"]`);
  const create = act('approve'), cancel = act('cancel'), open = act('open');
  if (create) create.onclick = () => _intgPlanDecide(row, plan, 'approve');
  if (cancel) cancel.onclick = () => _intgPlanDecide(row, plan, 'cancel');
  if (open) open.onclick = () => {
    if (typeof switchPanel === 'function') switchPanel('tasks');
    openIntegration(plan.space_id);
  };
}

function _intgPlanHtml(plan) {
  const status = plan.status || 'pending';
  const schedules = plan.schedules || [], collections = plan.collections || [],
        skills = plan.skills || [];
  const section = (label, items, render) => items.length ? `
    <div class="plan-card-section">
      <div class="plan-card-section-label">${esc(label)}</div>
      ${items.map(render).join('')}
    </div>` : '';

  return `
    <div class="plan-card plan-card--${esc(status)}">
      <div class="plan-card-head">
        <span class="plan-card-icon" aria-hidden="true">${esc(_intgGlyph(plan.icon))}</span>
        <span class="plan-card-title">${esc(plan.name || '')}</span>
        <span class="plan-card-tag">${esc(_intgPlanTag(status))}</span>
      </div>
      <div class="plan-card-body">
        <p class="plan-card-summary">${esc(plan.summary || '')}</p>
        ${section('Schedules', schedules, s => `
          <div class="plan-card-item">
            <div class="plan-card-item-head">
              <span class="plan-card-item-name">${esc(s.name)}</span>
              <span class="plan-card-item-when">${esc(s.schedule)}</span>
            </div>
            <div class="plan-card-item-note">${esc(s.purpose)}</div>
          </div>`)}
        ${section('Data', collections, c => `
          <div class="plan-card-item">
            <div class="plan-card-item-head"><span class="plan-card-item-name">${esc(c.name)}</span></div>
            <div class="plan-card-item-note">${esc(c.description)}</div>
          </div>`)}
        ${section('Skills', skills, s => `
          <div class="plan-card-item">
            <div class="plan-card-item-head"><span class="plan-card-item-name">${esc(s.name)}</span></div>
            <div class="plan-card-item-note">${esc(s.purpose)}</div>
          </div>`)}
      </div>
      <div class="plan-card-foot">${_intgPlanFootHtml(plan, status)}</div>
    </div>`;
}

function _intgPlanTag(status) {
  if (status === 'approved') return 'Created';
  if (status === 'cancelled') return 'Cancelled';
  return 'Proposed';
}

function _intgPlanFootHtml(plan, status) {
  if (status === 'approved') {
    return `<span class="plan-card-note">Running as <code>${esc(plan.space_id)}</code>.</span>
            <button class="intg-btn" data-plan-act="open">Open it</button>`;
  }
  if (status === 'cancelled') {
    return `<span class="plan-card-note">Nothing was created.</span>`;
  }
  return `<span class="plan-card-note">Nothing exists until you say so.</span>
          <button class="intg-btn" data-plan-act="cancel">Cancel</button>
          <button class="intg-btn intg-btn--primary" data-plan-act="approve">Create</button>`;
}

async function _intgPlanDecide(row, plan, action) {
  const foot = row.querySelector('.plan-card-foot');
  if (foot) foot.innerHTML = `<span class="plan-card-note">${action === 'approve' ? 'Creating…' : 'Cancelling…'}</span>`;
  try {
    await api(`/api/integrations/plans/${encodeURIComponent(plan.id)}/${action}`, { method: 'POST' });
  } catch (e) {
    // Usually "that plan was already approved" — decided on another device. The
    // card's job is to show what is true, so refetch rather than sit on the error.
    showToast(e.message, 4000);
  }
  await _intgPlanFill(row, plan.id);
  if (action === 'approve') {
    showToast(`${plan.name} created`);
    if (_currentPanel === 'tasks') loadIntegrations();
  }
}

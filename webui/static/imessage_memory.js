// JarvisCopilot — iMessage memory (Integrations page).
//
// His Mac uploads the chats he lets Jarvis remember; the server turns each quiet
// conversation into a transcript memory plus facts. This screen is the control
// panel: on/off, what model or harness analyses the chats, which chats count,
// who is never remembered, and a manual backfill over a date range.
//
//   sidebar  pinned card from renderIntegrationsSidebar() → openIMessageMemory()
//   detail   #taskDetailBody, guarded by _intgView like the other screens
//   api      /api/imessage-memory (webui/api/imessage_memory_routes.py)

const _IMM_VIEW = 'imessage-memory';
let _immCard = null;
let _immSearch = '';
let _immPoll = null;
let _immChooseChats = null;        // Set of guids when the backfill is narrowed
let _immRange = null;              // {from, to} input values, kept across re-renders

function _immCardEl(card) {
  const el = document.createElement('div');
  el.className = 'cron-item intg-card';
  el.id = 'intg-imessage-memory';
  if (_intgView === _IMM_VIEW) el.classList.add('active');
  el.innerHTML = `
    <div class="intg-card-head">
      <span class="intg-card-icon" aria-hidden="true">💬</span>
      <span class="cron-name">iMessage memory</span>
      ${card && card.active_job ? '<span class="cron-status">backfilling</span>' : ''}
    </div>
    <div class="intg-card-desc">Remembers the chats you pick from your Mac.</div>
    <div class="intg-card-meta">${esc(_immSubtitle(card))}</div>`;
  el.onclick = () => openIMessageMemory();
  return el;
}

function _immSubtitle(card) {
  if (!card) return '';
  if (!card.mac_seen_at) return 'Mac not seen yet';
  if (!card.enabled) return 'Off';
  const on = (card.chats || []).filter(c => c.effective).length;
  return `On · ${on} ${on === 1 ? 'chat' : 'chats'} · ${(card.totals && card.totals.memories) || 0} memories`;
}

// The pinned card, filled in once the state arrives (the sidebar never waits on it).
function immSidebarCard() {
  const el = _immCardEl(_immCard);
  api('/api/imessage-memory').then(card => {
    _immCard = card;
    if (el.isConnected) el.replaceWith(_immCardEl(card));
  }).catch(() => {});
  return el;
}

async function openIMessageMemory() {
  document.querySelectorAll('.cron-item').forEach(e => e.classList.remove('active'));
  if (typeof _clearCronDetail === 'function') _clearCronDetail();
  _intgCurrent = null;
  _intgView = _IMM_VIEW;
  const card = $('intg-imessage-memory');
  if (card) card.classList.add('active');
  const title = $('taskDetailTitle'), body = $('taskDetailBody'), empty = $('taskDetailEmpty');
  if (empty) empty.style.display = 'none';
  if (title) title.textContent = '💬  iMessage memory';
  if (body) { body.style.display = ''; body.innerHTML = `<div class="intg-note">${esc(t('loading'))}</div>`; }
  try {
    const state = await api('/api/imessage-memory');
    if (_intgView !== _IMM_VIEW) return;
    _immCard = state;
    _immRender();
  } catch (e) {
    if (_intgView !== _IMM_VIEW) return;
    if (body) body.innerHTML = `<div class="intg-note intg-note--error">${esc(e.message)}</div>`;
  }
}

function _immWhen(ts) {
  if (!ts) return '';
  return new Date(ts * 1000).toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
}

function _immAgo(ts) {
  if (!ts) return 'never';
  const s = Math.max(0, Date.now() / 1000 - ts);
  if (s < 90) return 'just now';
  if (s < 3600) return `${Math.round(s / 60)} min ago`;
  if (s < 86400) return `${Math.round(s / 3600)} h ago`;
  return _immWhen(ts);
}

// <input type=datetime-local> value for a Date, in local time.
function _immLocalInput(d) {
  const pad = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function _immRender() {
  const body = $('taskDetailBody');
  if (!body || !_immCard) return;
  const c = _immCard;
  const warn = !c.memory_active
    ? 'Long-term memory (jarvis_memory) isn’t the active memory, so nothing is saved until it is.'
    : (!c.mac_seen_at ? 'Your Mac hasn’t checked in yet. Make sure the Jarvis Mac app is running and has Full Disk Access.'
      : (c.mac_connected === false ? 'Your Mac is offline — backfills and previews wait until it’s back.' : ''));
  const q = _immSearch.trim().toLowerCase();
  const chats = (c.chats || []).filter(ch => !q || (ch.name || '').toLowerCase().includes(q)
    || (ch.participants || []).some(p => `${p.label} ${p.handle}`.toLowerCase().includes(q)));
  const job = c.active_job;
  const now = new Date();
  const range = _immRange || { from: _immLocalInput(new Date(now.getTime() - 7 * 86400000)), to: _immLocalInput(now) };
  const skipKeys = new Set((c.skip || []).map(s => String(s.handle)));
  const people = [];
  const seen = new Set();
  for (const ch of c.chats || []) for (const p of ch.participants || []) {
    if (!p.handle || seen.has(p.handle) || skipKeys.has(p.handle)) continue;
    seen.add(p.handle);
    people.push(p);
  }
  people.sort((a, b) => String(a.label).localeCompare(String(b.label)));

  body.innerHTML = `
    <div class="intg-detail imm">
      <p class="intg-detail-desc">Your Mac reads the chats you pick here. Each conversation becomes a
        memory (who, when, what was said) plus facts like addresses and plans, so Jarvis can answer
        “what was I talking to Sam about yesterday?”. Codes and one-time passwords are never sent.</p>
      ${warn ? `<div class="intg-note intg-note--error">${esc(warn)}</div>` : ''}

      <section class="intg-section">
        <label class="imm-switch"><input type="checkbox" data-imm="enabled" ${c.enabled ? 'checked' : ''}>
          <span>Remember my iMessages</span></label>
        <div class="imm-status">
          <span>Mac last seen: ${esc(_immAgo(c.mac_seen_at))}</span>
          <span>Memories: ${Number((c.totals && c.totals.memories) || 0).toLocaleString()}${
            c.totals && c.totals.pending ? ` · ${c.totals.pending} messages waiting` : ''}</span>
          ${c.runs_on ? `<span>Runs on: ${esc(c.runs_on)}</span>` : ''}
        </div>
      </section>

      <section class="intg-section">
        <h4 class="intg-section-title">Fact cards${c.pending_facts ? ` <span class="intg-count">${c.pending_facts} waiting</span>` : ''}</h4>
        <label class="imm-switch"><input type="checkbox" data-imm="ask_facts" ${c.ask_facts !== false ? 'checked' : ''}>
          <span>Ask before saving facts</span></label>
        <div class="imm-hint">New conversations’ facts wait as Store / Skip cards on your iPhone’s home screen and
          save themselves after a day. Off: facts are saved straight away.</div>
        <label class="imm-switch"><input type="checkbox" data-imm="push_facts" ${c.push_facts !== false ? 'checked' : ''}
          ${c.ask_facts === false ? 'disabled' : ''}><span>Lock-screen notifications</span></label>
      </section>

      <section class="intg-section">
        <h4 class="intg-section-title">Model or harness</h4>
        <div class="imm-hint">Uses the memory model — change it in Long-term Memory.</div>
      </section>

      <section class="intg-section">
        <h4 class="intg-section-title">Chats <span class="intg-count">${(c.chats || []).filter(x => x.effective).length}/${(c.chats || []).length}</span></h4>
        <input class="imm-input" type="search" placeholder="Search chats" data-imm="search" value="${esc(_immSearch)}">
        <div class="imm-hint">New one-to-one chats are on; group chats are off until you tick them.</div>
        ${chats.length ? chats.map(ch => `
          <div class="intg-row">
            <input type="checkbox" data-imm-pick="${esc(ch.guid)}" ${ch.effective ? 'checked' : ''}
              aria-label="Remember ${esc(ch.name)}">
            <div class="intg-row-main imm-open" data-imm-open="${esc(ch.guid)}" title="Preview messages">
              <span class="intg-row-name">${esc(ch.name || ch.guid)}${ch.is_group ? ' <span class="imm-pill">Group</span>' : ''}</span>
              <span class="intg-row-sub">${esc(_immWhen(ch.last_message_at))}${ch.remembered ? ` · ${ch.remembered} remembered` : ''}</span>
            </div>
            ${ch.remembered ? `<button class="intg-row-del" title="Forget memories from this chat"
              data-imm-forget="${esc(ch.guid)}" data-imm-name="${esc(ch.name)}" aria-label="Forget memories from ${esc(ch.name)}">×</button>` : ''}
          </div>`).join('') : `<div class="intg-empty-row">${(c.chats || []).length ? 'No chats match.' : 'No chats yet — they appear once your Mac checks in.'}</div>`}
      </section>

      <section class="intg-section">
        <h4 class="intg-section-title">Never remember <span class="intg-count">${(c.skip || []).length}</span></h4>
        ${(c.skip || []).map(s => `
          <div class="intg-row">
            <div class="intg-row-main"><span class="intg-row-name">${esc(s.label || s.handle)}</span>
              <span class="intg-row-sub">${esc(s.handle)}</span></div>
            <button class="intg-row-del" data-imm-unskip="${esc(s.handle)}" aria-label="Remove ${esc(s.label || s.handle)}">×</button>
          </div>`).join('')}
        <div class="imm-row">
          <select class="imm-input" data-imm="skip-add"><option value="">Add a person…</option>
            ${people.map(p => `<option value="${esc(p.handle)}" data-label="${esc(p.label)}">${esc(p.label)}${p.label !== p.handle ? ` (${esc(p.handle)})` : ''}</option>`).join('')}
          </select>
        </div>
      </section>

      <section class="intg-section">
        <h4 class="intg-section-title">Backfill</h4>
        ${job ? `
          <div class="intg-row">
            <div class="intg-row-main">
              <span class="intg-row-name">${esc(job.status === 'pending'
                ? (c.mac_connected === false ? 'Waiting for your Mac (offline)…' : 'Waiting for your Mac…')
                : job.status === 'analyzing'
                  ? `Analysing conversations — ${Number(job.analyzed || 0).toLocaleString()} of ${Number(job.received || 0).toLocaleString()} messages`
                  : 'Uploading from your Mac…')} ·
                ${esc(_immWhen(job.start))} → ${esc(_immWhen(job.end))}</span>
              <progress class="imm-progress" max="1" value="${job.received ? Math.min(1, (job.analyzed || 0) / job.received) : 0}"></progress>
              <span class="intg-row-sub">${job.stored} conversations saved · ${job.skipped} already remembered</span>
            </div>
            <button class="intg-btn" data-imm="stop">Stop</button>
          </div>` : `
          <div class="imm-row">
            <label>From <input class="imm-input" type="datetime-local" data-imm="from" value="${esc(range.from)}"></label>
            <label>To <input class="imm-input" type="datetime-local" data-imm="to" value="${esc(range.to)}"></label>
          </div>
          <div class="imm-row">
            <button class="intg-btn" data-imm-preset="7">Last week</button>
            <button class="intg-btn" data-imm-preset="30">Last month</button>
            <button class="intg-btn" data-imm-preset="91">Last 3 months</button>
          </div>
          <div class="imm-row">
            <select class="imm-input" data-imm="scope">
              <option value="all"${_immChooseChats ? '' : ' selected'}>All ticked chats</option>
              <option value="choose"${_immChooseChats ? ' selected' : ''}>Choose chats…</option>
            </select>
            <button class="intg-btn intg-btn--primary" data-imm="run">Run backfill</button>
          </div>
          ${_immChooseChats ? `<div class="imm-choose">${(c.chats || []).filter(x => x.effective).map(ch => `
            <label class="intg-choice"><input type="checkbox" data-imm-choose="${esc(ch.guid)}"
              ${_immChooseChats.has(ch.guid) ? 'checked' : ''}><span class="intg-choice-name">${esc(ch.name)}</span></label>`).join('')
            || '<div class="intg-empty-row">Tick some chats first.</div>'}</div>` : ''}`}
        ${(c.jobs || []).filter(j => !job || j.id !== job.id).slice(0, 5).map(j => `
          <div class="intg-row">
            <div class="intg-row-main">
              <span class="intg-row-name">${esc(_immWhen(j.start))} → ${esc(_immWhen(j.end))}</span>
              <span class="intg-row-sub">${esc(j.status)}${j.error ? ': ' + esc(j.error) : ''} · ${j.stored} saved · ${j.skipped} already remembered</span>
            </div>
          </div>`).join('')}
      </section>
    </div>`;
  _immBind(body);
  _immSchedulePoll();
}

async function _immPost(path, payload) {
  try {
    return await api('/api/imessage-memory' + path, { method: 'POST', body: JSON.stringify(payload) });
  } catch (e) {
    if (typeof showToast === 'function') showToast(e.message || 'Request failed');
    return null;
  }
}

async function _immUpdate(path, payload) {
  const card = await _immPost(path, payload);
  if (card && card.chats) {
    _immCard = card;
    if (_intgView === _IMM_VIEW) _immRender();
  } else {
    await _immReload();
  }
}

async function _immReload() {
  try {
    const card = await api('/api/imessage-memory');
    _immCard = card;
    const body = $('taskDetailBody');
    if (_intgView === _IMM_VIEW && body && body.querySelector('.imm')) _immRender();
  } catch (e) {}
}

function _immBind(body) {
  const q = sel => body.querySelector(`[data-imm="${sel}"]`);
  const enabled = q('enabled');
  if (enabled) enabled.onchange = () => _immUpdate('/settings', { enabled: enabled.checked });
  const search = q('search');
  if (search) search.oninput = () => {
    _immSearch = search.value;
    const pos = search.selectionStart;
    _immRender();
    const again = $('taskDetailBody').querySelector('[data-imm="search"]');
    if (again) { again.focus(); again.setSelectionRange(pos, pos); }
  };
  body.querySelectorAll('[data-imm-pick]').forEach(box => {
    box.onchange = () => _immUpdate('/chat', { guid: box.dataset.immPick, pick: box.checked });
  });
  body.querySelectorAll('[data-imm-forget]').forEach(btn => {
    btn.onclick = () => _immForget(btn.dataset.immForget, btn.dataset.immName);
  });
  body.querySelectorAll('[data-imm-unskip]').forEach(btn => {
    btn.onclick = () => _immUpdate('/settings', {
      skip: (_immCard.skip || []).filter(s => s.handle !== btn.dataset.immUnskip) });
  });
  const add = q('skip-add');
  if (add) add.onchange = () => {
    const opt = add.selectedOptions[0];
    if (!opt || !opt.value) return;
    _immUpdate('/settings', { skip: [...(_immCard.skip || []), { handle: opt.value, label: opt.dataset.label || '' }] });
  };
  body.querySelectorAll('[data-imm-preset]').forEach(btn => {
    btn.onclick = () => {
      const now = new Date();
      q('from').value = _immLocalInput(new Date(now.getTime() - Number(btn.dataset.immPreset) * 86400000));
      q('to').value = _immLocalInput(now);
      _immRange = { from: q('from').value, to: q('to').value };
    };
  });
  ['from', 'to'].forEach(k => {
    const input = q(k);
    if (input) input.onchange = () => { _immRange = { from: q('from').value, to: q('to').value }; };
  });
  const scope = q('scope');
  if (scope) scope.onchange = () => {
    _immChooseChats = scope.value === 'choose' ? new Set() : null;
    _immRender();
  };
  body.querySelectorAll('[data-imm-choose]').forEach(box => {
    box.onchange = () => {
      if (!_immChooseChats) return;
      if (box.checked) _immChooseChats.add(box.dataset.immChoose);
      else _immChooseChats.delete(box.dataset.immChoose);
    };
  });
  for (const key of ['ask_facts', 'push_facts']) {
    const box = q(key);
    if (box) box.onchange = () => _immUpdate('/settings', { [key]: box.checked });
  }
  body.querySelectorAll('[data-imm-open]').forEach(el => {
    el.onclick = () => _immPreview(el.dataset.immOpen);
  });
  const run = q('run');
  if (run) run.onclick = async () => {
    const from = new Date(q('from').value).getTime() / 1000;
    const to = new Date(q('to').value).getTime() / 1000;
    if (!(from < to)) { if (typeof showToast === 'function') showToast('“From” must be before “To”.'); return; }
    const payload = { from, to };
    if (_immChooseChats) {
      if (!_immChooseChats.size) { if (typeof showToast === 'function') showToast('Choose at least one chat.'); return; }
      payload.chats = [..._immChooseChats];
    }
    run.disabled = true;
    const res = await _immPost('/backfill', payload);
    if (res && res.ok) { _immChooseChats = null; _immRange = null; }
    await _immReload();
  };
  const stop = q('stop');
  if (stop) stop.onclick = async () => {
    stop.disabled = true;
    await _immPost('/backfill/stop', { id: _immCard.active_job.id });
    await _immReload();
  };
}

// A chat's last messages, asked of the Mac live (nothing is kept on the server),
// with the chat's tick as the dialog's action.
async function _immPreview(guid) {
  const chat = ((_immCard && _immCard.chats) || []).find(ch => ch.guid === guid);
  if (!chat) return;
  const time = ts => new Date(ts * 1000).toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
  const choice = await _intgModal({
    title: chat.name || 'Chat',
    bodyHtml: `<div class="imm-tabs" role="tablist">
        <button class="imm-tab imm-tab--on" role="tab" data-imm-tab="messages">Messages</button>
        <button class="imm-tab" role="tab" data-imm-tab="memories">Memories</button>
      </div>
      <div class="imm-preview" data-imm-pane="messages"><div class="intg-note">Asking your Mac…</div></div>
      <div class="imm-preview" data-imm-pane="memories" hidden></div>`,
    buttons: [{ label: chat.effective ? 'Stop remembering' : 'Remember this chat', value: !chat.effective }],
    wire: overlay => {
      const box = overlay.querySelector('[data-imm-pane="messages"]');
      const memBox = overlay.querySelector('[data-imm-pane="memories"]');
      overlay.querySelector('.intg-modal').classList.add('imm-preview-modal');
      let memLoaded = false;
      overlay.querySelectorAll('[data-imm-tab]').forEach(tab => {
        tab.onclick = () => {
          const which = tab.dataset.immTab;
          overlay.querySelectorAll('[data-imm-tab]').forEach(t => t.classList.toggle('imm-tab--on', t === tab));
          box.hidden = which !== 'messages';
          memBox.hidden = which !== 'memories';
          if (which === 'memories' && !memLoaded) { memLoaded = true; _immLoadMemories(memBox, guid); }
        };
      });
      api('/api/imessage-memory/preview?guid=' + encodeURIComponent(guid)).then(res => {
        const msgs = res.messages || [];
        box.innerHTML = msgs.length ? msgs.map(m => `
          <div class="imm-bubble${m.is_from_me ? ' imm-bubble--me' : ''}">
            ${!m.is_from_me && chat.is_group ? `<div class="imm-bubble-who">${esc(m.sender)}</div>` : ''}
            <div class="imm-bubble-text">${esc(m.text)}</div>
            <div class="imm-bubble-time">${esc(time(m.ts))}</div>
          </div>`).join('') : '<div class="intg-note">No messages in this chat.</div>';
        box.scrollTop = box.scrollHeight;
      }).catch(e => {
        box.innerHTML = `<div class="intg-note intg-note--error">${esc(e.message || 'Couldn’t load the chat.')}</div>`;
      });
      return () => true;
    },
  });
  if (choice === true || choice === false) await _immUpdate('/chat', { guid, pick: choice });
}

// What Jarvis holds from one chat: saved facts, facts waiting for Store/Skip,
// and saved conversations — each saved one deletable on its own.
async function _immLoadMemories(box, guid) {
  const when = ts => new Date(ts * 1000).toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
  box.innerHTML = '<div class="intg-note">Loading…</div>';
  let data;
  try {
    data = await api('/api/imessage-memory/memories?guid=' + encodeURIComponent(guid));
  } catch (e) {
    box.innerHTML = `<div class="intg-note intg-note--error">${esc(e.message || 'Couldn’t load memories.')}</div>`;
    return;
  }
  const facts = data.facts || [], waiting = data.waiting || [], convos = data.conversations || [];
  if (!facts.length && !waiting.length && !convos.length) {
    box.innerHTML = '<div class="intg-note">Nothing remembered from this chat yet.</div>';
    return;
  }
  const del = id => `<button class="intg-row-del" title="Delete this memory" data-imm-del="${esc(id)}" aria-label="Delete this memory">×</button>`;
  box.innerHTML = `
    ${facts.length ? `<h4 class="intg-section-title">Facts <span class="intg-count">${facts.length}</span></h4>
      ${facts.map(f => `<div class="intg-row"><div class="intg-row-main"><span class="imm-mem-text">${esc(f.text)}</span>
        <span class="intg-row-sub">${esc(when(f.at))}</span></div>${del(f.id)}</div>`).join('')}` : ''}
    ${waiting.length ? `<h4 class="intg-section-title">Waiting for you <span class="intg-count">${waiting.length}</span></h4>
      ${waiting.map(f => `<div class="intg-row"><div class="intg-row-main"><span class="imm-mem-text">${esc(f.fact)}</span>
        <span class="intg-row-sub">Saves itself ${esc(when(f.expires_at))}</span></div>
        <button class="intg-btn" data-imm-decide="${esc(f.id)}" data-store="1">Store</button>
        <button class="intg-btn" data-imm-decide="${esc(f.id)}" data-store="0">Skip</button></div>`).join('')}` : ''}
    ${convos.length ? `<h4 class="intg-section-title">Conversations <span class="intg-count">${convos.length}</span></h4>
      ${convos.map(c => `<div class="intg-row imm-convo"><div class="intg-row-main">
        <span class="intg-row-name">${esc((c.text.split('\n')[0] || '').slice(0, 140))}</span>
        <pre class="imm-mem-convo">${esc(c.text.split('\n').slice(1).join('\n'))}</pre></div>${del(c.id)}</div>`).join('')}` : ''}`;
  box.querySelectorAll('[data-imm-del]').forEach(btn => {
    btn.onclick = async () => {
      btn.disabled = true;
      const res = await _immPost('/memories/delete', { id: btn.dataset.immDel });
      if (res && res.deleted) btn.closest('.intg-row').remove();
      else btn.disabled = false;
    };
  });
  box.querySelectorAll('[data-imm-decide]').forEach(btn => {
    btn.onclick = async () => {
      btn.closest('.intg-row').querySelectorAll('button').forEach(b => { b.disabled = true; });
      const res = await _immPost('/facts/decide', { ids: [btn.dataset.immDecide], store: btn.dataset.store === '1' });
      if (res && res.ok) _immLoadMemories(box, guid);
      else btn.closest('.intg-row').querySelectorAll('button').forEach(b => { b.disabled = false; });
    };
  });
  box.querySelectorAll('.imm-convo .intg-row-main').forEach(el => {
    el.onclick = () => el.classList.toggle('imm-convo--open');
  });
}

async function _immForget(guid, name) {
  const ok = await showConfirmDialog({
    title: 'Forget this chat?',
    message: `Delete everything Jarvis remembered from ${name}? New messages are still remembered while the chat is ticked.`,
    confirmLabel: 'Forget', danger: true });
  if (!ok) return;
  const res = await _immPost('/forget', { guid });
  if (res && typeof showToast === 'function') showToast(`Forgot ${res.forgotten} memories from ${name}`);
  await _immReload();
}

// While a backfill runs and this screen is open, refresh its progress every 5 s.
function _immSchedulePoll() {
  clearTimeout(_immPoll);
  if (!_immCard || !_immCard.active_job) return;
  _immPoll = setTimeout(async () => {
    const body = $('taskDetailBody');
    // Gone the moment another screen (a schedule, a form) takes the pane:
    // those don't all reset _intgView, so the pane itself is the check.
    if (_intgView !== _IMM_VIEW || !body || !body.querySelector('.imm')) return;
    if (document.hidden) return _immSchedulePoll();
    const typing = document.activeElement && body.contains(document.activeElement)
      && /INPUT|SELECT|TEXTAREA/.test(document.activeElement.tagName);
    if (!typing) await _immReload(); else _immSchedulePoll();
  }, 5000);
}

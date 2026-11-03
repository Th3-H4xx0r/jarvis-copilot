'use strict';
// The iPhone app's shell on the web (JARVIS skin):
//
//  * a floating tab bar — Chat · Voice · Agents · Devices · More — at the
//    bottom on phone-sized screens, exactly like the app;
//  * "More": every other page as a grid of tiles (a sheet on phones, a
//    popover beside the rail on desktop, where the rail keeps only the phone's
//    tabs + More + Settings);
//  * on phones the model/harness pill moves up into the header, like the
//    app's "✦ Auto" pill.
//
// Pages are opened with the app's own switchPanel(); tabs light up through its
// usual [data-panel] → .active toggling. Icons are cloned from the rail so the
// two never drift.
(function () {
  const PRIMARY = ['chat', 'voice', 'agents', 'devices'];
  const LABELS = { chat: 'Chat', voice: 'Voice', agents: 'Agents', devices: 'Devices', tasks: 'Integrations',
    kanban: 'Kanban', skills: 'Skills', memory: 'Memory', workspaces: 'Spaces', profiles: 'Profiles',
    todos: 'Todos', insights: 'Insights', logs: 'Server logs', selfimprovement: 'Learning',
    codememory: 'Code memory', live: 'Live', settings: 'Settings' };
  const MORE_ICON = '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/></svg>';
  const PHONE = window.matchMedia('(max-width: 767px)');

  function railIcon(panel) {
    const b = document.querySelector('.rail .nav-tab[data-panel="' + panel + '"] svg');
    return b ? b.outerHTML : '';
  }

  // A page without a name here uses the rail's own tooltip.
  function railLabel(panel) {
    const b = document.querySelector('.rail .nav-tab[data-panel="' + panel + '"]');
    return (b && (b.getAttribute('data-tooltip') || b.getAttribute('aria-label'))) || panel;
  }

  function morePanels() {
    return [...document.querySelectorAll('.rail .nav-tab[data-panel]')]
      .map(b => b.dataset.panel)
      .filter((p, i, a) => p && !PRIMARY.includes(p) && a.indexOf(p) === i);
  }

  function open(panel) {
    closeMore();
    if (typeof switchPanel === 'function') switchPanel(panel, { fromRailClick: true });
  }

  // ── More (sheet on phones, popover on desktop) ───────────────────────────
  let moreEl = null;
  function buildMore() {
    moreEl = document.createElement('div');
    moreEl.className = 'jc-more';
    moreEl.hidden = true;
    moreEl.innerHTML = '<div class="jc-more-scrim"></div><div class="jc-more-card" role="dialog" aria-label="More">' +
      '<div class="jc-more-title">More</div><div class="jc-more-grid"></div></div>';
    const grid = moreEl.querySelector('.jc-more-grid');
    morePanels().forEach(p => {
      const t = document.createElement('button');
      t.type = 'button';
      t.className = 'jc-more-tile';
      t.dataset.panel = p;               // lights up with the app's own active toggling
      t.innerHTML = '<span class="jc-more-icon">' + railIcon(p) + '</span><span class="jc-more-label">' +
        (LABELS[p] || railLabel(p)) + '</span>';
      t.addEventListener('click', () => open(p));
      grid.appendChild(t);
    });
    moreEl.querySelector('.jc-more-scrim').addEventListener('click', closeMore);
    document.addEventListener('keydown', e => { if (e.key === 'Escape') closeMore(); });
    document.body.appendChild(moreEl);
  }
  function toggleMore() { if (moreEl.hidden) openMore(); else closeMore(); }
  function openMore() { moreEl.hidden = false; document.body.classList.add('jc-more-open'); syncMore(); }
  function closeMore() { if (moreEl) { moreEl.hidden = true; document.body.classList.remove('jc-more-open'); } }

  // ── tab bar (phones) ──────────────────────────────────────────────────────
  function buildTabbar() {
    const bar = document.createElement('nav');
    bar.className = 'jc-tabbar';
    bar.setAttribute('aria-label', 'Tabs');
    PRIMARY.forEach(p => {
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'jc-tab';
      b.dataset.panel = p;
      b.innerHTML = railIcon(p) + '<span>' + LABELS[p] + '</span>';
      b.addEventListener('click', () => open(p));
      bar.appendChild(b);
    });
    const more = document.createElement('button');
    more.type = 'button';
    more.className = 'jc-tab jc-tab-more';
    more.innerHTML = MORE_ICON + '<span>More</span>';
    more.addEventListener('click', toggleMore);
    bar.appendChild(more);
    document.body.appendChild(bar);
  }

  // ── desktop rail: the phone's tabs, then More, then Settings ─────────────
  function buildRailMore() {
    const rail = document.querySelector('.rail');
    if (!rail) return;
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'rail-btn jc-rail-more has-tooltip';
    b.setAttribute('data-tooltip', 'More');
    b.setAttribute('aria-label', 'More');
    b.innerHTML = MORE_ICON;
    b.addEventListener('click', toggleMore);
    const anchor = rail.querySelector('.nav-tab[data-panel="devices"]');
    if (anchor && anchor.nextSibling) rail.insertBefore(b, anchor.nextSibling); else rail.appendChild(b);
  }

  // "More" reads as selected while one of its pages is open.
  function syncMore() {
    const active = document.querySelector('.rail .nav-tab.active[data-panel]');
    const inMore = !!(active && !PRIMARY.includes(active.dataset.panel));
    document.querySelectorAll('.jc-tab-more, .jc-rail-more').forEach(b => b.classList.toggle('active', inMore));
  }

  // ── phones: the model pill lives in the header ───────────────────────────
  let pillHome = null;
  function placePill() {
    const pill = document.getElementById('harnessChipChat');
    const bar = document.querySelector('.app-titlebar');
    if (!pill || !bar) return;
    if (!pillHome) pillHome = { parent: pill.parentNode, next: pill.nextSibling };
    if (PHONE.matches) {
      if (pill.parentNode !== bar) bar.insertBefore(pill, bar.querySelector('#btnTitlebarNewChat'));
      pill.classList.add('jc-header-pill');
    } else if (pill.parentNode === bar) {
      pillHome.parent.insertBefore(pill, pillHome.next);
      pill.classList.remove('jc-header-pill');
    }
  }

  function init() {
    if (document.documentElement.dataset.skin !== 'jarvis') return;
    if (document.querySelector('.jc-tabbar')) return;
    document.body.classList.add('jc-shell');
    buildMore();
    buildTabbar();
    buildRailMore();
    placePill();
    PHONE.addEventListener('change', () => { placePill(); closeMore(); });
    if (typeof window.switchPanel === 'function') {
      const orig = window.switchPanel;
      window.switchPanel = async function (name, opts) {
        const r = await orig.call(this, name, opts);
        syncMore();
        return r;
      };
    }
    // The page that was open before the tabs existed lights its tab too.
    const current = document.querySelector('.rail .nav-tab.active[data-panel]');
    if (current) document.querySelectorAll('.jc-tab[data-panel], .jc-more-tile').forEach(b =>
      b.classList.toggle('active', b.dataset.panel === current.dataset.panel));
    syncMore();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => setTimeout(init, 0));
  else setTimeout(init, 0);
})();

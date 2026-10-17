/* ============================================================================
 * Agents terminal — the xterm mount for an agent session's `claude attach` PTY.
 *
 * Lifted from the old Coding panel's live terminal (coding.js), which was the
 * best terminal code in the repo: batched requestAnimationFrame writes, a
 * throttled resize, ⌘C/⌘V copy and paste, and honest close reasons. Used by
 * the Agents panel's terminal drawer (agents.js) and, full screen, by
 * agents_terminal.html inside the iPhone's WKWebView.
 *
 *   AgentsTerminal.mount(el, terminalId, {fontSize, onClosed}) -> bool
 *   AgentsTerminal.close({keepalive})   detaches the PTY (the session keeps running)
 *   AgentsTerminal.refit()              refit to the host and tell the PTY
 *   AgentsTerminal.focus()
 *
 * `terminalId` comes from POST /api/coding/agents/terminal/start; it drives the
 * existing /api/terminal/{output,input,resize,close} endpoints as session_id.
 * Needs xterm (window.Terminal) and, optionally, its fit addon.
 * ========================================================================== */
(function () {
  'use strict';

  let _term = null;       // xterm instance
  let _fit = null;        // FitAddon
  let _es = null;         // EventSource for the PTY's output
  let _tid = null;        // terminal id this mount drives
  let _host = null;       // element the terminal lives in
  let _onWinResize = null;
  let _ro = null;         // ResizeObserver on the host (drawer drags, fullscreen)
  let _rzTimer = 0;
  let _sendResize = null;

  // URLs resolve against <base> (index.html and agents_terminal.html both set
  // one at the app root), so a subpath mount like /jarvis/ keeps working.
  function _url(path) {
    const rel = String(path || '').replace(/^\//, '');
    return new URL(rel, document.baseURI || location.href).href;
  }

  function _post(path, body, opts) {
    const init = Object.assign({
      method: 'POST', credentials: 'include',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body || {}),
    }, opts || {});
    return fetch(_url(path), init).then((res) => {
      if (!res.ok) throw new Error('HTTP ' + res.status);
      return res;
    });
  }

  function _copy(text) {
    if (!text) return;
    try {
      // Prefer the shared helper (ui.js): it falls back to execCommand('copy')
      // where navigator.clipboard is missing (plain http over the tunnel).
      if (typeof window._copyText === 'function') { window._copyText(text).catch(() => {}); return; }
      if (navigator.clipboard) navigator.clipboard.writeText(text).catch(() => {});
    } catch (_) { /* nothing to copy into */ }
  }

  function _closedNote(reason) {
    if (reason === 'ended') return '[the session ended]';
    if (reason === 'disconnected') return '[disconnected: the Mac dropped its connection; reopen when it’s back]';
    return '[detached: reopen the terminal to resume]';
  }

  function mount(el, terminalId, opts) {
    const o = opts || {};
    close();
    if (!el || !terminalId) return false;
    if (!window.Terminal) {
      el.textContent = 'The terminal couldn’t load (xterm is missing).';
      return false;
    }
    const tid = String(terminalId);
    const term = new window.Terminal({
      cursorBlink: true,
      fontSize: o.fontSize || 13,
      fontFamily: 'Menlo, Monaco, Consolas, "Liberation Mono", monospace',
      scrollback: 4000,
      convertEol: false,
      theme: { background: '#0a0d13' },
    });
    let fit = null;
    if (window.FitAddon && typeof window.FitAddon.FitAddon === 'function') {
      fit = new window.FitAddon.FitAddon();
      term.loadAddon(fit);
    }
    el.textContent = '';
    term.open(el);
    try { if (fit) fit.fit(); } catch (_) { /* host not laid out yet */ }
    _term = term; _fit = fit; _tid = tid; _host = el;

    const input = (data) => _post('/api/terminal/input', { session_id: tid, data }).catch(() => {});
    term.onData(input);

    // ⌘C / Ctrl+Shift+C copies the selection (instead of sending ^C), ⌘V /
    // Ctrl+Shift+V pastes into the PTY. Plain Ctrl+C still interrupts.
    term.attachCustomKeyEventHandler((e) => {
      if (e.type !== 'keydown') return true;
      const k = (e.key || '').toLowerCase();
      const copyCombo = (e.metaKey && !e.ctrlKey && k === 'c') || (e.ctrlKey && e.shiftKey && k === 'c');
      const pasteCombo = (e.metaKey && !e.ctrlKey && k === 'v') || (e.ctrlKey && e.shiftKey && k === 'v');
      if (copyCombo) {
        try { _copy(term.getSelection()); } catch (_) { /* no selection */ }
        return false;
      }
      if (pasteCombo) {
        try {
          if (navigator.clipboard) {
            navigator.clipboard.readText().then((txt) => { if (txt) input(txt); }).catch(() => {});
          }
        } catch (_) { /* clipboard blocked */ }
        return false;
      }
      return true;
    });

    const sendResize = () => {
      if (_tid !== tid || !_term) return;
      try { if (fit) fit.fit(); } catch (_) { /* hidden */ }
      _post('/api/terminal/resize', { session_id: tid, rows: term.rows, cols: term.cols }).catch(() => {});
    };
    _sendResize = sendResize;
    // THROTTLED: a window or drawer drag fires dozens of resizes a second, each
    // a full xterm reflow + a POST + a SIGWINCH repaint. One trailing call.
    const throttled = () => {
      if (_rzTimer) clearTimeout(_rzTimer);
      _rzTimer = setTimeout(sendResize, 150);
    };
    _onWinResize = throttled;
    window.addEventListener('resize', throttled);
    if (typeof ResizeObserver === 'function') {
      _ro = new ResizeObserver(throttled);
      _ro.observe(el);
    }
    setTimeout(sendResize, 120);

    // BATCH output: a burst of SSE frames is buffered and written once per
    // animation frame instead of one write + reflow per message.
    let wbuf = '';
    let wraf = 0;
    const flush = () => {
      wraf = 0;
      const b = wbuf; wbuf = '';
      if (b && _term === term) term.write(b);
    };
    const es = new EventSource(_url('/api/terminal/output?session_id=' + encodeURIComponent(tid)),
      { withCredentials: true });
    _es = es;
    es.addEventListener('output', (ev) => {
      let text = '';
      try { text = (JSON.parse(ev.data) || {}).text || ''; } catch (_) { /* bad frame */ }
      if (!text) return;
      wbuf += text;
      if (!wraf) wraf = requestAnimationFrame(flush);
    });
    es.onerror = () => {
      // Never let EventSource reconnect against a terminal this mount no longer
      // drives: re-attaching a dead PTY on a loop was the old "infinite reload".
      if (_tid !== tid) { try { es.close(); } catch (_) { /* closed */ } }
    };
    es.addEventListener('terminal_closed', (ev) => {
      let reason = '';
      try { reason = (JSON.parse(ev.data) || {}).reason || ''; } catch (_) { /* no reason */ }
      try { es.close(); } catch (_) { /* closed */ }
      if (_es === es) _es = null;
      if (_term === term) term.write('\r\n\x1b[90m' + _closedNote(reason) + '\x1b[0m\r\n');
      if (typeof o.onClosed === 'function') {
        try { o.onClosed(reason || 'detached'); } catch (_) { /* caller's problem */ }
      }
    });
    return true;
  }

  // Detach the server-side PTY (the agent session itself keeps running).
  function close(opts) {
    const tid = _tid;
    try { if (_es) _es.close(); } catch (_) { /* closed */ }
    try { if (_onWinResize) window.removeEventListener('resize', _onWinResize); } catch (_) { /* gone */ }
    try { if (_ro) _ro.disconnect(); } catch (_) { /* gone */ }
    if (_rzTimer) clearTimeout(_rzTimer);
    if (tid) {
      const extra = (opts && opts.keepalive) ? { keepalive: true } : null;
      _post('/api/terminal/close', { session_id: tid }, extra).catch(() => {});
    }
    try { if (_term) _term.dispose(); } catch (_) { /* disposed */ }
    _term = null; _fit = null; _es = null; _tid = null; _host = null;
    _onWinResize = null; _ro = null; _rzTimer = 0; _sendResize = null;
  }

  function refit() { if (_sendResize) _sendResize(); }
  function focus() { try { if (_term) _term.focus(); } catch (_) { /* gone */ } }
  function current() { return _tid; }

  window.AgentsTerminal = { mount, close, refit, focus, current };
})();

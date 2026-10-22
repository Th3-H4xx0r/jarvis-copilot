/* jarvis_memory.js — webui "Long-term Memory" full-screen panel.
 *
 * Self-registering: clones the Code-Memory nav button (matching styling),
 * injects a MAIN-AREA view (#mainJmemory, a child of <main class="main">, like
 * #mainCodememory) so hiding the sidebar (cm-fullwidth) shows it full-screen.
 * Shows status (provider/model/info), search, insights, and a live memory-only
 * log feed. Backed by /api/jarvis-memory/*.
 */
(function () {
  "use strict";

  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  function ago(ts) {
    if (!ts) return "";
    var d = Date.now() / 1000 - ts;
    if (d < 60) return "just now";
    if (d < 3600) return Math.floor(d / 60) + "m ago";
    if (d < 86400) return Math.floor(d / 3600) + "h ago";
    return Math.floor(d / 86400) + "d ago";
  }

  // ── Panel container (in the MAIN area, not the sidebar) ──
  function ensurePanel() {
    if (document.getElementById("mainJmemory")) return;
    var main = document.querySelector("main.main");
    if (!main) return;
    var div = document.createElement("div");
    div.id = "mainJmemory";
    div.style.cssText = "display:none;flex-direction:column;height:100%;min-height:0;";
    div.innerHTML =
      '<div class="cm-header"><div class="cm-header-title">Long-term memory</div></div>' +
      '<div id="jmemBody" style="padding:16px;overflow:auto;flex:1 1 auto;min-height:0;box-sizing:border-box"></div>';
    main.appendChild(div);
  }

  function showPanel() {
    ensurePanel();
    var chat = document.getElementById("mainChat");
    if (chat) chat.style.display = "none";              // override the default-visible main view
    var el = document.getElementById("mainJmemory");
    if (el) el.style.display = "flex";
    document.body.classList.add("cm-fullwidth");        // hide the chat sidebar -> full screen
    document.querySelectorAll("[data-panel]").forEach(function (b) {
      b.classList.toggle("active", b.dataset.panel === "jmemory");
    });
  }

  function hidePanel() {
    var el = document.getElementById("mainJmemory");
    if (el) el.style.display = "none";
    var chat = document.getElementById("mainChat");
    if (chat) chat.style.display = "";                  // restore (CSS decides the real view)
    document.body.classList.remove("cm-fullwidth");
  }

  function injectNavButtons() {
    document.querySelectorAll('[data-panel="codememory"]').forEach(function (src) {
      if (src.nextElementSibling && src.nextElementSibling.getAttribute("data-panel") === "jmemory") return;
      var btn = src.cloneNode(true);
      btn.setAttribute("data-panel", "jmemory");
      btn.setAttribute("data-tooltip", "Long-term Memory");
      if (btn.hasAttribute("aria-label")) btn.setAttribute("aria-label", "Long-term Memory");
      if (btn.hasAttribute("data-label")) btn.setAttribute("data-label", "Memory+");
      btn.removeAttribute("data-i18n-title");
      btn.removeAttribute("onclick");
      btn.innerHTML =
        '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" ' +
        'stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
        '<path d="M4 6h10"/><path d="M4 12h8"/><path d="M4 18h6"/>' +
        '<path d="M18 3l1.2 3.2L22.4 7l-3.2 1.2L18 11l-1.2-2.8L13.6 7l3.2-.8z"/></svg>';
      btn.onclick = function () {
        showPanel();
        window.loadJarvisMemory();
      };
      src.insertAdjacentElement("afterend", btn);
    });
  }

  function attachLeaveHandlers() {
    // When any OTHER nav button is clicked, restore the chat view + sidebar.
    document.querySelectorAll("[data-panel]").forEach(function (b) {
      if (b.dataset.panel === "jmemory" || b._jmLeave) return;
      b._jmLeave = true;
      b.addEventListener("click", function () { hidePanel(); }, true);  // capture: before switchPanel
    });
  }

  // ── Map / List switch ──
  var VIEW_KEY = "jmem-view";
  var SEG = "font-size:12px;padding:6px 16px;border:none;cursor:pointer;background:transparent;color:var(--muted)";
  var _view = "map";
  try { if (localStorage.getItem(VIEW_KEY) === "list") _view = "list"; } catch (e) {}

  function setView(v) {
    _view = v === "list" ? "list" : "map";
    try { localStorage.setItem(VIEW_KEY, _view); } catch (e) {}
    applyView();
  }

  function applyView() {
    var map = document.getElementById("jmemMapView");
    var list = document.getElementById("jmemListView");
    if (!map || !list) return;
    map.style.display = _view === "map" ? "block" : "none";
    list.style.display = _view === "list" ? "block" : "none";
    ["jmemViewMap", "jmemViewList"].forEach(function (id) {
      var b = document.getElementById(id);
      if (!b) return;
      var on = b.getAttribute("data-view") === _view;
      b.setAttribute("aria-selected", on ? "true" : "false");
      b.style.background = on ? "var(--accent-bg-strong,var(--accent-bg,transparent))" : "transparent";
      b.style.color = on ? "var(--text,var(--fg))" : "var(--muted)";
      b.style.fontWeight = on ? "600" : "400";
    });
    if (_view === "map" && window.MemoryMap) {
      try { MemoryMap.mount(map); MemoryMap.show(); } catch (e) { /* the list still works */ }
    }
  }

  // ── Recent recalls (List side) ──
  async function loadRecalls() {
    var el = document.getElementById("jmemRecalls");
    if (!el || !window.MemoryGraph) return;
    var d = null;
    try {
      var r = await fetch(MemoryGraph.recallsUrl({ limit: 30 }));
      d = r.ok ? await r.json() : null;
    } catch (e) { d = null; }
    var head = '<div style="font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em;margin-bottom:6px">Recent recalls</div>';
    if (!d) { el.innerHTML = head + '<div style="font-size:12px;color:var(--muted)">Couldn’t load recent recalls.</div>'; return; }
    var rows = Array.isArray(d.recalls) ? d.recalls : [];
    if (!rows.length) {
      el.innerHTML = head + '<div style="font-size:12px;color:var(--muted)">No recalls yet — they appear when Jarvis uses a memory in a reply.</div>';
      return;
    }
    el.innerHTML = head + '<div style="max-height:260px;overflow:auto;border:1px solid var(--border);border-radius:10px">' +
      rows.map(function (rc) {
        var nm = (rc.memory_ids || []).length, ne = (rc.entity_ids || []).length;
        var meta = [ago(rc.ts), nm + (nm === 1 ? " memory" : " memories"), ne ? ne + (ne === 1 ? " node" : " nodes") : "",
          rc.ms != null ? Math.round(rc.ms) + " ms" : ""].filter(Boolean).join(" · ");
        return '<button type="button" class="jmem-recall-row" data-recall="' + esc(rc.id) + '" data-query="' + esc(rc.query) + '" ' +
          'style="display:block;width:100%;text-align:left;padding:8px 10px;border:none;border-bottom:1px solid var(--border);' +
          'background:none;color:var(--text,var(--fg));cursor:pointer">' +
          '<div style="font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">' + esc(rc.query || "(no text)") + "</div>" +
          '<div style="font-size:11px;color:var(--muted);margin-top:2px">' + esc(meta) + "</div></button>";
      }).join("") + "</div>";
    el.querySelectorAll(".jmem-recall-row").forEach(function (b) {
      b.addEventListener("click", function () { openRecall(b.getAttribute("data-recall"), b.getAttribute("data-query")); });
    });
  }

  // Open the panel's map lit up on one recall (Recent recalls row or chat chip).
  function openRecall(recallId, query) {
    if (recallId == null || recallId === "") return;
    showPanel();
    var body = renderShell();
    var fresh = body && !body.dataset.loadedOnce;
    setView("map");
    if (window.MemoryMap) {
      try { MemoryMap.highlightRecall(recallId, query || ""); } catch (e) {}
    }
    if (fresh) window.loadJarvisMemory();
  }

  window.JarvisMemory = { openRecall: openRecall };

  // ── Chat chip: "memories used" under replies that used long-term memory ──
  // One request per open chat (cached), refreshed once per completed reply.
  var _chipCache = {};
  var _chipOrder = [];
  var _chipTimer = null;

  function _chipSid() {
    try { return (typeof S !== "undefined" && S && S.session && S.session.session_id) || null; } catch (e) { return null; }
  }

  function _chipMessages() {
    try { return (typeof S !== "undefined" && S && Array.isArray(S.messages)) ? S.messages : []; } catch (e) { return []; }
  }

  function _chipBusy(inner) {
    try {
      if (typeof S !== "undefined" && S && S.busy) return true;
    } catch (e) {}
    return !!inner.querySelector("#liveAssistantTurn, [data-live-assistant]");
  }

  function scheduleChips() {
    clearTimeout(_chipTimer);
    _chipTimer = setTimeout(function () { try { decorateChips(); } catch (e) { /* never break chat */ } }, 250);
  }

  function fetchChipRecalls(sid, count) {
    var prev = _chipCache[sid];
    var c = { recalls: prev ? prev.recalls : [], count: count, inflight: true };
    _chipCache[sid] = c;
    if (_chipOrder.indexOf(sid) < 0) {
      _chipOrder.push(sid);
      while (_chipOrder.length > 20) delete _chipCache[_chipOrder.shift()];
    }
    var url;
    try { url = MemoryGraph.recallsUrl({ sessionId: sid, limit: 100 }); } catch (e) { c.inflight = false; return; }
    fetch(url).then(function (r) { return r.ok ? r.json() : null; }).then(function (d) {
      if (d && Array.isArray(d.recalls)) c.recalls = d.recalls;
    }).catch(function () { /* no chips, chat unaffected */ }).then(function () {
      c.inflight = false;
      if (_chipSid() === sid) scheduleChips();
    });
  }

  function decorateChips() {
    var inner = document.getElementById("msgInner");
    var sid = _chipSid();
    if (!inner || !sid || !window.MemoryGraph) return;
    var msgs = _chipMessages();
    var c = _chipCache[sid];
    var busy = _chipBusy(inner);
    if (!c) { if (!busy) fetchChipRecalls(sid, msgs.length); return; }
    if (c.inflight) return;
    if (!busy && msgs.length > c.count) { fetchChipRecalls(sid, msgs.length); return; }
    if (!c.recalls.length) return;
    var users = [];
    msgs.forEach(function (m, i) {
      if (m && m.role === "user") users.push({ key: i, text: MemoryGraph.messageText(m.content), ts: m._ts || m.timestamp });
    });
    var matched = MemoryGraph.matchRecalls(users, c.recalls);
    inner.querySelectorAll('.msg-row[data-role="user"][data-msg-idx]').forEach(function (row) {
      var rc = matched[Number(row.dataset.msgIdx)];
      if (!rc) return;
      var turn = null;
      for (var el = row.nextElementSibling; el; el = el.nextElementSibling) {
        if (el.matches('.msg-row[data-role="user"]')) break;
        if (el.classList.contains("assistant-turn")) { turn = el; break; }
      }
      if (!turn || turn.id === "liveAssistantTurn" || turn.querySelector("[data-live-assistant]")) return;
      var host = turn.querySelector(".assistant-turn-blocks") || turn;
      var have = host.querySelector(":scope > .jmem-recall-chip");
      if (have && have.getAttribute("data-recall") === String(rc.id)) return;
      if (have) have.remove();
      var n = (rc.memory_ids || []).length;
      var chip = document.createElement("button");
      chip.type = "button";
      chip.className = "jmem-recall-chip";
      chip.setAttribute("data-recall", String(rc.id));
      chip.setAttribute("data-query", String(rc.query || ""));
      chip.title = "Show the memories Jarvis used on the map";
      chip.style.cssText = "display:inline-flex;align-items:center;gap:5px;margin:4px 0 2px;padding:2px 9px;font-size:11px;" +
        "border:1px solid var(--border);border-radius:999px;background:transparent;color:var(--muted);cursor:pointer";
      chip.innerHTML = '<svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">' +
        '<circle cx="12" cy="12" r="3"/><circle cx="4" cy="6" r="2"/><circle cx="20" cy="6" r="2"/><circle cx="12" cy="21" r="2"/>' +
        '<path d="M6 7l4 3M18 7l-4 3M12 15v4"/></svg>' +
        esc(n ? n + (n === 1 ? " memory used" : " memories used") : "memories used");
      host.appendChild(chip);
    });
  }

  function initChips() {
    var inner = document.getElementById("msgInner");
    if (!inner || inner._jmemChips || !window.MutationObserver) return;
    inner._jmemChips = true;
    try {
      // Re-renders replace #msgInner's children; a finished stream drops the live markers.
      new MutationObserver(scheduleChips).observe(inner, { childList: true });
      new MutationObserver(scheduleChips).observe(inner, {
        subtree: true, attributes: true, attributeFilter: ["id", "data-live-assistant"],
      });
    } catch (e) { return; }
    document.addEventListener("click", function (ev) {
      var b = ev.target && ev.target.closest ? ev.target.closest(".jmem-recall-chip") : null;
      if (!b) return;
      ev.preventDefault();
      ev.stopPropagation();
      try { openRecall(b.getAttribute("data-recall"), b.getAttribute("data-query")); } catch (e) {}
    });
    scheduleChips();
  }

  // ── Body sections ──
  function renderShell() {
    ensurePanel();
    var body = document.getElementById("jmemBody");
    if (!body) return null;
    if (!body.dataset.built) {
      body.dataset.built = "1";
      body.innerHTML =
        '<div id="jmemStatus" style="display:flex;flex-wrap:wrap;gap:6px;margin-bottom:12px"></div>' +
        '<div role="tablist" aria-label="Memory view" style="display:inline-flex;border:1px solid var(--border);border-radius:10px;overflow:hidden;margin-bottom:12px">' +
        '<button type="button" role="tab" id="jmemViewMap" data-view="map" style="' + SEG + '">Map</button>' +
        '<button type="button" role="tab" id="jmemViewList" data-view="list" style="' + SEG + ';border-left:1px solid var(--border)">List</button>' +
        '</div>' +
        '<div id="jmemMapView" style="display:none"></div>' +
        '<div id="jmemListView" style="display:none">' +
        '<div id="jmemModel" style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-bottom:14px"></div>' +
        '<div id="jmemCleanup" style="margin-bottom:14px"></div>' +
        '<div id="jmemReflect" style="margin-bottom:14px"></div>' +
        '<div id="jmemRecalls" style="margin-bottom:14px"></div>' +
        '<div style="display:flex;gap:8px;align-items:center;margin-bottom:12px;flex-wrap:wrap">' +
        '<input id="jmemQ" type="text" placeholder="Search your long-term memory…" ' +
        'style="flex:1;min-width:200px;padding:8px 10px;border-radius:8px;border:1px solid var(--border);background:var(--bg);color:var(--fg)">' +
        '<select id="jmemNs" style="padding:8px;border-radius:8px;border:1px solid var(--border);background:var(--bg);color:var(--fg)"></select>' +
        '</div><div id="jmemList"></div>' +
        '<div style="margin-top:18px">' +
        '<div style="font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em;margin-bottom:6px">Memory activity (live)</div>' +
        '<div id="jmemLogs" style="max-height:220px;overflow:auto;border:1px solid var(--border);border-radius:10px;padding:10px;background:var(--card,var(--bg))"></div>' +
        '</div></div>';
      body.querySelectorAll('[role="tab"][data-view]').forEach(function (b) {
        b.addEventListener("click", function () { setView(b.getAttribute("data-view")); });
      });
      applyView();
      var q = document.getElementById("jmemQ");
      var t = null;
      q.addEventListener("input", function () { clearTimeout(t); t = setTimeout(runSearch, 200); });
      document.getElementById("jmemNs").addEventListener("change", runSearch);
    }
    return body;
  }

  function _chip(label, val, danger) {
    return '<span style="font-size:11px;padding:3px 9px;border:1px solid var(--border);border-radius:999px;' +
      'color:' + (danger ? "var(--danger,#c33)" : "var(--muted)") + '">' +
      esc(label) + ': <b style="color:var(--fg)">' + esc(val) + "</b></span>";
  }

  async function loadStatus() {
    var el = document.getElementById("jmemStatus");
    if (!el) return;
    var d = {};
    try { d = await fetch("api/jarvis-memory/status").then(function (r) { return r.json(); }); } catch (e) { return; }
    if (!d || d.available === false) {
      el.innerHTML = '<span style="color:var(--muted);font-size:12px">Memory not initialized yet.</span>';
      return;
    }
    var html = _chip("Provider", "jarvis_memory");
    html += _chip("Embedder", (d.embed_model || "?") + " · " + (d.embed_dim || "?") + "d");
    html += _chip("Extraction", d.extract_model || d.extract || "?");
    html += _chip("Ollama", d.ollama_running ? "up" : "down (" + (d.ollama_url || "") + ")", !d.ollama_running);
    html += _chip("Memories", String(d.count != null ? d.count : "?"));
    el.innerHTML = html;
  }

  function rowHtml(e) {
    var meta = [e.source || "", e.namespace || "", ago(e.created_at)].filter(Boolean).join(" · ");
    return (
      '<div class="jmem-item" style="padding:10px 12px;border:1px solid var(--border);border-radius:10px;margin-bottom:8px;background:var(--card,var(--bg))">' +
      '<div style="white-space:pre-wrap;word-break:break-word">' + esc(e.body) + "</div>" +
      '<div style="display:flex;align-items:center;margin-top:6px;gap:10px">' +
      '<span style="color:var(--muted);font-size:11px">' + esc(meta) + "</span>" +
      '<button class="jmem-del" data-id="' + esc(e.id) + '" ' +
      'style="margin-left:auto;font-size:11px;color:var(--danger,#c33);background:none;border:none;cursor:pointer">Forget</button>' +
      "</div></div>"
    );
  }

  async function runSearch() {
    var body = renderShell();
    if (!body) return;
    var q = (document.getElementById("jmemQ") || {}).value || "";
    var ns = (document.getElementById("jmemNs") || {}).value || "";
    var list = document.getElementById("jmemList");
    list.innerHTML = '<div style="color:var(--muted);font-size:12px">Searching…</div>';
    var url = "api/jarvis-memory/search?limit=100&q=" + encodeURIComponent(q) + "&ns=" + encodeURIComponent(ns);
    var data;
    try { data = await fetch(url).then(function (r) { return r.json(); }); }
    catch (e) { list.innerHTML = '<div style="color:var(--danger,#c33)">Failed to load memory.</div>'; return; }
    var entries = (data && data.entries) || [];
    if (!entries.length) {
      list.innerHTML = '<div style="color:var(--muted);font-size:13px">' +
        (q ? "No memories match “" + esc(q) + "”." : "No memories captured yet.") + "</div>";
      return;
    }
    list.innerHTML = entries.map(rowHtml).join("");
    list.querySelectorAll(".jmem-del").forEach(function (b) {
      // Inline "Forget forever? Yes / No" instead of a browser dialog.
      b.addEventListener("click", function () {
        var holder = document.createElement("span");
        holder.style.cssText = "margin-left:auto;display:inline-flex;gap:6px;align-items:center;font-size:11px";
        holder.innerHTML = '<span style="color:var(--muted)">Forget forever?</span>' +
          '<button type="button" class="jmem-del-yes" style="font-size:11px;color:var(--danger,#c33);background:none;border:1px solid var(--border);border-radius:6px;cursor:pointer">Forget</button>' +
          '<button type="button" class="jmem-del-no" style="font-size:11px;background:none;border:1px solid var(--border);border-radius:6px;color:var(--muted);cursor:pointer">Cancel</button>';
        b.replaceWith(holder);
        holder.querySelector(".jmem-del-no").addEventListener("click", function () { holder.replaceWith(b); });
        holder.querySelector(".jmem-del-yes").addEventListener("click", async function (ev) {
          ev.target.disabled = true;
          try {
            await fetch("api/jarvis-memory/delete", {
              method: "POST", headers: { "Content-Type": "application/json" },
              body: JSON.stringify({ id: b.getAttribute("data-id") }),
            });
          } catch (e) {}
          runSearch();
          loadStatus();
        });
      });
    });
  }

  async function loadStats() {
    var sel = document.getElementById("jmemNs");
    if (!sel) return;
    var data;
    try { data = await fetch("api/jarvis-memory/stats").then(function (r) { return r.json(); }); } catch (e) { return; }
    if (data && data.available === false) {
      var b = document.getElementById("jmemBody");
      if (b) {
        b.dataset.built = "";
        b.innerHTML =
          '<div style="padding:8px;color:var(--muted);font-size:13px;line-height:1.6">' +
          "Long-term memory isn’t enabled yet.<br>Run <code>jarviscopilot memory setup</code> and choose " +
          "<b>jarvis_memory</b>, then chat — turns are captured automatically and become searchable here.</div>";
      }
      return;
    }
    if (data && data.namespaces) {
      var cur = sel.value;
      sel.innerHTML = data.namespaces
        .map(function (n) { return '<option value="' + esc(n.namespace) + '">' + esc(n.namespace) + " (" + n.count + ")</option>"; })
        .join("");
      if (cur) sel.value = cur;
    }
  }

  async function loadReflections() {
    var el = document.getElementById("jmemReflect");
    if (!el) return;
    var data = { reflections: [] };
    try { data = await fetch("api/jarvis-memory/reflections").then(function (r) { return r.json(); }); } catch (e) { return; }
    var cards = (data && data.reflections) || [];
    var head =
      '<div style="display:flex;align-items:center;gap:8px;margin-bottom:6px">' +
      '<span style="font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em">Insights</span>' +
      '<button id="jmemReflRefresh" style="margin-left:auto;font-size:11px;background:none;border:1px solid var(--border);' +
      'border-radius:6px;padding:2px 8px;color:var(--muted);cursor:pointer">Refresh</button></div>';
    var bodyHtml = cards.map(function (c) {
      return '<div style="padding:9px 11px;border:1px solid var(--border);border-radius:10px;margin-bottom:6px;background:var(--card,var(--bg))">' +
        '<div style="display:flex;align-items:center;gap:8px">' +
        '<span style="font-weight:600">' + esc(c.title) + "</span>" +
        '<span style="font-size:10px;color:var(--muted);border:1px solid var(--border);border-radius:6px;padding:0 6px">' + esc(c.kind || "") + "</span>" +
        '<button class="jmem-refl-dismiss" data-id="' + esc(c.id) + '" ' +
        'style="margin-left:auto;font-size:11px;color:var(--muted);background:none;border:none;cursor:pointer">Dismiss</button></div>' +
        (c.body ? '<div style="margin-top:4px;color:var(--muted);font-size:12px">' + esc(c.body) + "</div>" : "") +
        "</div>";
    }).join("");
    el.innerHTML = head + (cards.length ? bodyHtml :
      '<div style="font-size:12px;color:var(--muted)">No insights yet — they appear as Jarvis reviews your memory.</div>');
    var refresh = document.getElementById("jmemReflRefresh");
    if (refresh) refresh.addEventListener("click", async function () {
      refresh.textContent = "Thinking…";
      try { await fetch("api/jarvis-memory/reflections/run", { method: "POST" }); } catch (e) {}
      await loadReflections();
    });
    el.querySelectorAll(".jmem-refl-dismiss").forEach(function (b) {
      b.addEventListener("click", async function () {
        try {
          await fetch("api/jarvis-memory/reflections/dismiss", {
            method: "POST", headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ id: Number(b.getAttribute("data-id")) }),
          });
        } catch (e) {}
        loadReflections();
      });
    });
  }

  var _logTimer = null;
  var _logTicks = 0;

  async function loadLogs() {
    var el = document.getElementById("jmemLogs");
    if (!el) return;
    var d = { logs: [] };
    try { d = await fetch("api/jarvis-memory/logs").then(function (r) { return r.json(); }); } catch (e) { return; }
    var logs = (d && d.logs) || [];
    if (!logs.length) {
      el.innerHTML = '<div style="color:var(--muted);font-size:12px">No memory activity yet.</div>';
      return;
    }
    el.innerHTML = logs.slice().reverse().map(function (l) {
      var t = "";
      try { t = new Date((l.ts || 0) * 1000).toLocaleTimeString(); } catch (e) {}
      var warn = l.level === "WARNING" || l.level === "ERROR";
      return '<div style="font-family:ui-monospace,monospace;font-size:11px;line-height:1.5;' +
        'color:' + (warn ? "var(--danger,#c33)" : "var(--fg)") + '">' +
        '<span style="opacity:.5">' + esc(t) + "</span> " + esc(l.msg) + "</div>";
    }).join("");
  }

  function startLogPolling() {
    if (_logTimer) clearInterval(_logTimer);
    _logTimer = setInterval(function () {
      var el = document.getElementById("mainJmemory");
      if (!el || el.style.display === "none") {  // stop when the panel is hidden
        clearInterval(_logTimer);
        _logTimer = null;
        return;
      }
      loadLogs();
      // A cleanup started elsewhere shows up here (a running one polls itself).
      if (++_logTicks % 5 === 0 && !(_cleanupLast && _cleanupLast.running)) loadCleanup();
    }, 3000);
  }

  // ── Memory model: the one model (or harness) every memory call uses ──
  function agentValue(agent) {
    if (!agent) return "default";
    if (agent.harness_id) return "harness:" + agent.harness_id;
    if (agent.model) {
      var m = String(agent.model);
      return "model:" + (m.charAt(0) === "@" || !agent.provider ? m : "@" + agent.provider + ":" + m);
    }
    return "default";
  }

  function agentFrom(value) {
    var v = String(value || "default");
    if (v.indexOf("harness:") === 0) return { harness_id: v.slice(8) };
    if (v.indexOf("model:") === 0) return { model: v.slice(6), provider: null };
    return null;
  }

  async function loadModel() {
    var el = document.getElementById("jmemModel");
    if (!el) return;
    var d;
    try {
      if (typeof loadCronRunsOnChoices === "function") await loadCronRunsOnChoices();
      d = await fetch("api/jarvis-memory/map-settings").then(function (r) { return r.json(); });
    } catch (e) { return; }
    var value = agentValue(d.agent);
    var ctx = typeof _cronRunsOnCtx === "function" ? _cronRunsOnCtx(null) : null;
    var options = window.CronRunsOn && ctx
      ? CronRunsOn.optionsHtml(value, ctx)
      : '<option value="' + esc(value) + '">' + esc(d.label || "Default") + "</option>";
    el.innerHTML =
      '<span style="font-size:12px;color:var(--muted)">Memory model</span>' +
      '<select id="jmemModelSel" style="padding:6px 8px;border-radius:8px;border:1px solid var(--border);background:var(--bg);color:var(--fg)">' +
      options + "</select>" +
      '<span style="font-size:11px;color:var(--muted)">Reads chats, iMessage and Live to pull out dates, people and places' +
      (d.label ? " · " + esc(d.label) : "") + "</span>";
    document.getElementById("jmemModelSel").addEventListener("change", async function (ev) {
      try {
        await fetch("api/jarvis-memory/map-settings", {
          method: "POST", headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ agent: agentFrom(ev.target.value) }),
        });
      } catch (e) { /* the next load shows what stuck */ }
      loadModel();
    });
  }

  // ── Cleanup & map: one-time backfill of the memory map, with a report ──
  // A run can be started elsewhere (iPhone, CLI): status drives the card, the
  // panel's poll picks it up. No browser dialogs: confirm inline.
  var cleanupTimer = null;
  var _cleanupConfirm = false;
  var _cleanupSig = "";
  var _cleanupLast = null;
  var CLEANUP_LABELS = {
    merged: "Merged duplicates", hidden_trivial: "Hidden trivia", superseded: "Marked out of date",
    live_rewritten: "Live rewritten", restamped: "Times fixed", enriched: "Mapped", failed: "Couldn't map",
  };
  var CLEANUP_LINE = "One-time tidy-up: backs up, merges duplicates, fixes times, then maps older memories to dates, " +
    "people and places. New memories are mapped automatically — you don't need to run this again.";
  var CBTN = "font-size:12px;padding:3px 10px;border-radius:8px;border:1px solid var(--border);background:var(--bg);color:var(--text,var(--fg));cursor:pointer";

  async function loadCleanup(force) {
    var el = document.getElementById("jmemCleanup");
    if (!el) return;
    var d;
    try {
      var r = await fetch("api/jarvis-memory/cleanup/status");
      d = await r.json();
    } catch (e) { return; }
    if (!d || typeof d !== "object") return;
    clearTimeout(cleanupTimer);
    if (d.running) cleanupTimer = setTimeout(function () { loadCleanup(); }, 3000);
    var sig = JSON.stringify(d);
    if (!force && sig === _cleanupSig && el.innerHTML) return;   // unchanged: keep open <details>
    if (!d.running && _cleanupConfirm && !force) return;           // don't clobber an open "Are you sure?"
    _cleanupSig = sig;
    _cleanupLast = d;
    renderCleanup(el, d);
  }

  function renderCleanup(el, d) {
    var box = '<div style="border:1px solid var(--border);border-radius:10px;padding:10px 12px;background:var(--card,var(--bg))">';
    var head = '<div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap"><b style="font-size:13px">Cleanup &amp; map</b>';
    var line = '<div style="font-size:12px;color:var(--muted);margin-top:6px">' + esc(CLEANUP_LINE) + "</div>";
    if (d.running) {
      _cleanupConfirm = false;
      var p = d.progress || {};
      var stopping = !!d.stopping;
      el.innerHTML = box + head + '<span style="font-size:12px;color:var(--muted)">' +
        (stopping ? "Stopping…" : esc(p.step || "working") + (p.total ? " · " + esc(String(p.done)) + "/" + esc(String(p.total)) : "")) +
        "</span>" +
        '<button type="button" id="jmemCleanupStop" style="margin-left:auto;' + CBTN + '"' + (stopping ? " disabled" : "") + ">" +
        (stopping ? "Stopping…" : "Stop") + "</button></div>" + line + "</div>";
      var stop = document.getElementById("jmemCleanupStop");
      if (stop && !stopping) stop.addEventListener("click", async function () {
        stop.disabled = true;
        stop.textContent = "Stopping…";
        try {
          await fetch("api/jarvis-memory/cleanup/stop", {
            method: "POST", headers: { "Content-Type": "application/json" }, body: "{}",
          });
        } catch (e) { /* status shows what stuck */ }
        loadCleanup(true);
      });
      return;
    }
    var r = d.report;
    var actions = _cleanupConfirm
      ? '<span style="margin-left:auto;font-size:12px">Are you sure?</span>' +
        '<button type="button" id="jmemCleanupGo" style="' + CBTN + '">Run</button>' +
        '<button type="button" id="jmemCleanupCancel" style="' + CBTN + '">Cancel</button>'
      : '<button type="button" id="jmemCleanupRun" style="margin-left:auto;' + CBTN + '">' + (r ? "Run again" : "Run cleanup") + "</button>";
    var html = box + head + actions + "</div>" + line;
    if (d.error) html += '<div style="font-size:12px;color:var(--danger,#c33);margin-top:6px">' + esc(d.error) + "</div>";
    if (r) {
      html += '<div style="display:flex;flex-wrap:wrap;gap:6px;margin-top:8px">';
      Object.keys(CLEANUP_LABELS).forEach(function (k) {
        if (r.counts && r.counts[k]) html += _chip(CLEANUP_LABELS[k], String(r.counts[k]));
      });
      html += "</div>";
      ["merged", "hidden_trivial", "superseded"].forEach(function (k) {
        var rows = (r.examples || {})[k] || [];
        if (!rows.length) return;
        html += '<details style="margin-top:6px"><summary style="font-size:12px;cursor:pointer">' + esc(CLEANUP_LABELS[k]) + "</summary>";
        rows.forEach(function (x) {
          html += '<div style="display:flex;gap:8px;align-items:flex-start;font-size:12px;margin:4px 0">' +
            '<span style="flex:1">' + esc(x.body) + "</span>" +
            (k === "superseded" ? "" : '<button class="jmemRestore" data-id="' + esc(x.id) + '" style="font-size:11px">Restore</button>') +
            "</div>";
        });
        html += "</details>";
      });
    }
    el.innerHTML = html + "</div>";
    var run = document.getElementById("jmemCleanupRun");
    if (run) run.addEventListener("click", function () { _cleanupConfirm = true; renderCleanup(el, d); });
    var cancel = document.getElementById("jmemCleanupCancel");
    if (cancel) cancel.addEventListener("click", function () { _cleanupConfirm = false; renderCleanup(el, d); });
    var go = document.getElementById("jmemCleanupGo");
    if (go) go.addEventListener("click", async function () {
      go.disabled = true;
      _cleanupConfirm = false;
      try { await fetch("api/jarvis-memory/cleanup/start", { method: "POST" }); } catch (e) { /* status shows it */ }
      loadCleanup(true);
    });
    el.querySelectorAll(".jmemRestore").forEach(function (b) {
      b.addEventListener("click", async function () {
        b.disabled = true;
        try {
          await fetch("api/jarvis-memory/cleanup/restore", {
            method: "POST", headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ ids: [b.getAttribute("data-id")] }),
          });
          b.textContent = "Restored";
        } catch (e) { b.disabled = false; }
      });
    });
  }

  window.loadJarvisMemory = async function () {
    var body = renderShell();
    if (body) body.dataset.loadedOnce = "1";
    applyView();
    await loadStatus();
    await loadModel();
    await loadCleanup();
    await loadStats();
    await loadReflections();
    await loadRecalls();
    await runSearch();
    await loadLogs();
    startLogPolling();
  };

  function init() {
    injectNavButtons();
    ensurePanel();
    attachLeaveHandlers();
    try { initChips(); } catch (e) {}
    setTimeout(function () {
      injectNavButtons(); ensurePanel(); attachLeaveHandlers();
      try { initChips(); } catch (e) {}
    }, 1500);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();

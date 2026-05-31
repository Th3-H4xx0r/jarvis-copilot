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

  // ── Body sections ──
  function renderShell() {
    ensurePanel();
    var body = document.getElementById("jmemBody");
    if (!body) return null;
    if (!body.dataset.built) {
      body.dataset.built = "1";
      body.innerHTML =
        '<div id="jmemStatus" style="display:flex;flex-wrap:wrap;gap:6px;margin-bottom:14px"></div>' +
        '<div id="jmemReflect" style="margin-bottom:14px"></div>' +
        '<div style="display:flex;gap:8px;align-items:center;margin-bottom:12px;flex-wrap:wrap">' +
        '<input id="jmemQ" type="text" placeholder="Search your long-term memory…" ' +
        'style="flex:1;min-width:200px;padding:8px 10px;border-radius:8px;border:1px solid var(--border);background:var(--bg);color:var(--fg)">' +
        '<select id="jmemNs" style="padding:8px;border-radius:8px;border:1px solid var(--border);background:var(--bg);color:var(--fg)"></select>' +
        '</div><div id="jmemList"></div>' +
        '<div style="margin-top:18px">' +
        '<div style="font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em;margin-bottom:6px">Memory activity (live)</div>' +
        '<div id="jmemLogs" style="max-height:220px;overflow:auto;border:1px solid var(--border);border-radius:10px;padding:10px;background:var(--card,var(--bg))"></div>' +
        '</div>';
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
      b.addEventListener("click", async function () {
        if (!confirm("Forget this memory? This cannot be undone.")) return;
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
    }, 3000);
  }

  window.loadJarvisMemory = async function () {
    renderShell();
    await loadStatus();
    await loadStats();
    await loadReflections();
    await runSearch();
    await loadLogs();
    startLogPolling();
  };

  function init() {
    injectNavButtons();
    ensurePanel();
    attachLeaveHandlers();
    setTimeout(function () { injectNavButtons(); ensurePanel(); attachLeaveHandlers(); }, 1500);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();

/* jarvis_memory.js — webui "Long-term Memory" panel for the jarvis_memory provider.
 *
 * Self-contained + self-registering: it clones the existing Code-Memory nav
 * button (so styling matches), injects a `jmemory` panel-view container, and
 * defines window.loadJarvisMemory. This avoids editing the large index.html /
 * panels.js beyond a single <script> include. Backed by /api/jarvis-memory/*.
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

  function ensurePanel() {
    if (document.getElementById("panelJmemory")) return;
    var anchor = document.getElementById("panelMemory");
    if (!anchor || !anchor.parentNode) return;
    var div = document.createElement("div");
    div.className = "panel-view";
    div.id = "panelJmemory";
    div.innerHTML =
      '<div class="panel-head"><span>Long-term memory</span>' +
      '<span id="jmemStat" style="margin-left:auto;color:var(--muted);font-size:12px"></span></div>' +
      '<div id="jmemBody" style="padding:14px;overflow:auto;height:100%;box-sizing:border-box"></div>';
    anchor.insertAdjacentElement("afterend", div);
  }

  function injectNavButtons() {
    var srcs = document.querySelectorAll('[data-panel="codememory"]');
    srcs.forEach(function (src) {
      // Skip if we've already inserted next to this one.
      if (src.nextElementSibling && src.nextElementSibling.getAttribute("data-panel") === "jmemory") return;
      var btn = src.cloneNode(true);
      btn.setAttribute("data-panel", "jmemory");
      btn.setAttribute("data-tooltip", "Long-term Memory");
      if (btn.hasAttribute("aria-label")) btn.setAttribute("aria-label", "Long-term Memory");
      if (btn.hasAttribute("data-label")) btn.setAttribute("data-label", "Memory+");
      btn.removeAttribute("data-i18n-title");
      btn.removeAttribute("onclick");
      // A distinct sparkle-over-list icon so it isn't confused with Code Memory.
      btn.innerHTML =
        '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" ' +
        'stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
        '<path d="M4 6h10"/><path d="M4 12h8"/><path d="M4 18h6"/>' +
        '<path d="M18 3l1.2 3.2L22.4 7l-3.2 1.2L18 11l-1.2-2.8L13.6 7l3.2-.8z"/></svg>';
      btn.onclick = function () {
        try { if (typeof switchPanel === "function") switchPanel("jmemory", { fromRailClick: true }); } catch (e) {}
        ensurePanel();
        window.loadJarvisMemory();
      };
      src.insertAdjacentElement("afterend", btn);
    });
  }

  function renderShell() {
    ensurePanel();
    var body = document.getElementById("jmemBody");
    if (!body) return null;
    if (!body.dataset.built) {
      body.dataset.built = "1";
      body.innerHTML =
        '<div style="display:flex;gap:8px;align-items:center;margin-bottom:12px;flex-wrap:wrap">' +
        '<input id="jmemQ" type="text" placeholder="Search your long-term memory…" ' +
        'style="flex:1;min-width:200px;padding:8px 10px;border-radius:8px;border:1px solid var(--border);background:var(--bg);color:var(--fg)">' +
        '<select id="jmemNs" style="padding:8px;border-radius:8px;border:1px solid var(--border);background:var(--bg);color:var(--fg)"></select>' +
        '</div><div id="jmemList"></div>';
      var q = document.getElementById("jmemQ");
      var t = null;
      q.addEventListener("input", function () {
        clearTimeout(t);
        t = setTimeout(runSearch, 200);
      });
      document.getElementById("jmemNs").addEventListener("change", runSearch);
    }
    return body;
  }

  function rowHtml(e) {
    var meta = [e.source || "", e.namespace || "", ago(e.created_at)].filter(Boolean).join(" · ");
    return (
      '<div class="jmem-item" data-id="' + esc(e.id) + '" ' +
      'style="padding:10px 12px;border:1px solid var(--border);border-radius:10px;margin-bottom:8px;background:var(--card,var(--bg))">' +
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
    try {
      data = await fetch(url).then(function (r) { return r.json(); });
    } catch (e) {
      list.innerHTML = '<div style="color:var(--danger,#c33)">Failed to load memory.</div>';
      return;
    }
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
        loadStats();
      });
    });
  }

  async function loadStats() {
    var stat = document.getElementById("jmemStat");
    var sel = document.getElementById("jmemNs");
    var data;
    try {
      data = await fetch("api/jarvis-memory/stats").then(function (r) { return r.json(); });
    } catch (e) { return; }
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
    if (stat && data) stat.textContent = (data.count || 0) + " memories";
    if (sel && data && data.namespaces) {
      var cur = sel.value;
      sel.innerHTML = data.namespaces
        .map(function (n) { return '<option value="' + esc(n.namespace) + '">' + esc(n.namespace) + " (" + n.count + ")</option>"; })
        .join("");
      if (cur) sel.value = cur;
    }
  }

  window.loadJarvisMemory = async function () {
    renderShell();
    await loadStats();
    await runSearch();
  };

  function init() {
    injectNavButtons();
    // Re-inject if the nav is re-rendered later (best-effort, cheap).
    setTimeout(injectNavButtons, 1500);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();

/* edge.js — webui "Cloudflare" (edge exposure) full-screen panel.
 *
 * Self-registering (mirrors jarvis_memory.js): clones the Code-Memory nav
 * button, injects a MAIN-AREA view (#mainEdge) shown full-screen, and manages
 * the cloudflared tunnel + local nginx proxy via /api/edge/*. Lets the operator
 * install the binaries, set domain/routes/token, see the safety preflight +
 * process status, and enable/disable public exposure.
 */
(function () {
  "use strict";

  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  function jpost(path, obj) {
    return api(path, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(obj || {}),
    });
  }

  function dot(ok) {
    return '<span style="display:inline-block;width:10px;height:10px;border-radius:50%;margin-right:6px;vertical-align:middle;background:' +
      (ok ? "#3fb950" : "#f85149") + '"></span>';
  }

  // ── Panel container (MAIN area, like jarvis_memory) ──
  function ensurePanel() {
    if (document.getElementById("mainEdge")) return;
    var main = document.querySelector("main.main");
    if (!main) return;
    var div = document.createElement("div");
    div.id = "mainEdge";
    div.style.cssText = "display:none;flex-direction:column;height:100%;min-height:0;";
    div.innerHTML =
      '<div class="cm-header"><div class="cm-header-title">Cloudflare Tunnel</div></div>' +
      '<div id="edgeBody" style="padding:16px;overflow:auto;flex:1 1 auto;min-height:0;box-sizing:border-box;max-width:760px"></div>';
    main.appendChild(div);
  }

  function showPanel() {
    ensurePanel();
    var chat = document.getElementById("mainChat");
    if (chat) chat.style.display = "none";
    var el = document.getElementById("mainEdge");
    if (el) el.style.display = "flex";
    document.body.classList.add("cm-fullwidth");
    document.querySelectorAll("[data-panel]").forEach(function (b) {
      b.classList.toggle("active", b.dataset.panel === "edge");
    });
  }

  function hidePanel() {
    var el = document.getElementById("mainEdge");
    if (el) el.style.display = "none";
    var chat = document.getElementById("mainChat");
    if (chat) chat.style.display = "";
    document.body.classList.remove("cm-fullwidth");
  }

  function injectNavButtons() {
    document.querySelectorAll('[data-panel="codememory"]').forEach(function (src) {
      if (src.nextElementSibling && src.nextElementSibling.getAttribute("data-panel") === "edge") return;
      var btn = src.cloneNode(true);
      btn.setAttribute("data-panel", "edge");
      btn.setAttribute("data-tooltip", "Cloudflare");
      if (btn.hasAttribute("aria-label")) btn.setAttribute("aria-label", "Cloudflare");
      if (btn.hasAttribute("data-label")) btn.setAttribute("data-label", "Cloud");
      btn.removeAttribute("data-i18n-title");
      btn.removeAttribute("onclick");
      btn.innerHTML =
        '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" ' +
        'stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
        '<path d="M17.5 19a4.5 4.5 0 1 0 0-9 6 6 0 0 0-11.6-1.5A4 4 0 0 0 6.5 19z"/></svg>';
      btn.onclick = function () { showPanel(); loadEdge(); };
      src.insertAdjacentElement("afterend", btn);
    });
  }

  function attachLeaveHandlers() {
    document.querySelectorAll("[data-panel]").forEach(function (b) {
      if (b.dataset.panel === "edge" || b._edgeLeave) return;
      b._edgeLeave = true;
      b.addEventListener("click", function () { hidePanel(); }, true);
    });
  }

  // ── Render ──
  function row(label, ok, detail) {
    return '<div style="padding:3px 0;font-size:13px">' + dot(ok) +
      '<strong>' + esc(label) + '</strong>' +
      (detail ? ' <span style="color:var(--muted,#8b949e)">— ' + esc(detail) + '</span>' : '') + '</div>';
  }

  async function loadEdge() {
    var body = document.getElementById("edgeBody");
    if (!body) return;
    body.innerHTML = '<div style="color:var(--muted,#8b949e)">Loading…</div>';
    var s;
    try {
      s = await api("/api/edge/status");
    } catch (e) {
      body.innerHTML = '<div style="color:#f85149">Edge subsystem unavailable: ' + esc(e.message || e) + '</div>';
      return;
    }
    render(body, s);
  }

  function render(body, s) {
    var tools = s.tools || {}, procs = s.processes || {}, st = s.settings || {}, pf = s.preflight || { ok: false, checks: [] };
    var routesText = Object.keys(st.routes || {}).map(function (k) { return k + "=" + st.routes[k]; }).join("\n");
    var live = (procs.cloudflared || {}).running || (procs.nginx || {}).running;

    function toolRow(name) {
      var t = tools[name] || {};
      return '<div style="display:flex;align-items:center;gap:8px;padding:2px 0">' + dot(!!t.installed) +
        '<strong>' + name + '</strong>' +
        '<span style="color:var(--muted,#8b949e);font-size:12px">' + esc(t.version || (t.installed ? "installed" : "not installed")) + '</span>' +
        (t.installed ? '' : '<button data-install="' + name + '" style="margin-left:auto;font-size:12px">Install</button>') +
        '</div>';
    }

    body.innerHTML =
      '<h3 style="font-size:13px;margin:0 0 4px">Tooling</h3>' +
      toolRow("cloudflared") + toolRow("nginx") +

      '<h3 style="font-size:13px;margin:14px 0 4px">Configuration</h3>' +
      '<label style="font-size:12px">Domain</label>' +
      '<input id="edgeDomain" type="text" value="' + esc(st.domain || "") + '" placeholder="example.com" style="width:100%">' +
      '<label style="font-size:12px;display:block;margin-top:6px">Routes (one per line: <code>sub=127.0.0.1:port</code>, use <code>@</code> for apex)</label>' +
      '<textarea id="edgeRoutes" rows="4" placeholder="jarvis=127.0.0.1:8787" style="width:100%;font-family:monospace;font-size:12px">' + esc(routesText) + '</textarea>' +
      '<label style="font-size:12px;display:block;margin-top:6px">Tunnel token</label>' +
      '<input id="edgeToken" type="password" placeholder="' + (st.has_token ? "saved (" + esc(st.token_masked) + ")" : "paste cloudflared tunnel token") + '" style="width:100%">' +

      '<h3 style="font-size:13px;margin:14px 0 4px">Cloudflare Access service token (for native apps)</h3>' +
      '<div style="font-size:12px;color:var(--muted,#8b949e);margin-bottom:4px">Mobile/desktop apps can\'t do browser SSO. Create a service token in Zero Trust → Access → Service Auth, paste it here, and it\'s delivered to each device when it pairs.</div>' +
      '<label style="font-size:12px">Client ID</label>' +
      '<input id="edgeCfId" type="text" value="' + esc(st.cf_service_client_id || "") + '" placeholder="xxxxxxxx.access" style="width:100%">' +
      '<label style="font-size:12px;display:block;margin-top:6px">Client Secret</label>' +
      '<input id="edgeCfSecret" type="password" placeholder="' + (st.has_cf_service_token ? "saved (" + esc(st.cf_service_secret_masked) + ")" : "paste service token secret") + '" style="width:100%">' +

      '<button id="edgeSave" style="margin-top:8px">Save configuration</button>' +

      '<h3 style="font-size:13px;margin:14px 0 4px">Safety preflight</h3>' +
      (pf.checks || []).map(function (c) { return row(c.name, c.ok, c.detail); }).join("") +

      '<h3 style="font-size:13px;margin:14px 0 4px">Status</h3>' +
      row("cloudflared", (procs.cloudflared || {}).running, (procs.cloudflared || {}).running ? "pid " + procs.cloudflared.pid : "stopped") +
      row("nginx", (procs.nginx || {}).running, (procs.nginx || {}).running ? "pid " + procs.nginx.pid : "stopped") +
      '<button id="edgeToggle" style="margin-top:8px' + (live ? ";background:#f85149;color:#fff" : "") + '"' + (!live && !pf.ok ? " disabled" : "") + '>' +
      (live ? "Disable tunnel" : "Enable tunnel") + '</button>' +
      (!live && !pf.ok ? '<div style="font-size:12px;color:#d29922;margin-top:4px">Resolve all preflight checks before enabling.</div>' : '') +

      '<div style="font-size:12px;color:var(--muted,#8b949e);margin-top:14px;border-top:1px solid var(--border,#30363d);padding-top:8px">' +
      'Lock this down: in the Cloudflare Zero Trust dashboard, create an Access application for your domain that allows ONLY your email. ' +
      'The tunnel does not restrict who can reach it — Access does.</div>';

    // ── wire handlers ──
    body.querySelectorAll("[data-install]").forEach(function (b) {
      b.onclick = async function () {
        b.disabled = true; b.textContent = "Installing…";
        try { await jpost("/api/edge/install", { tool: b.getAttribute("data-install") }); } catch (e) { alert(e.message || e); }
        loadEdge();
      };
    });

    var saveBtn = document.getElementById("edgeSave");
    if (saveBtn) saveBtn.onclick = async function () {
      saveBtn.disabled = true;
      var routes = {};
      document.getElementById("edgeRoutes").value.split("\n").map(function (l) { return l.trim(); }).filter(Boolean).forEach(function (line) {
        var i = line.indexOf("=");
        if (i > 0) routes[line.slice(0, i).trim()] = line.slice(i + 1).trim();
      });
      var payload = { domain: document.getElementById("edgeDomain").value.trim(), routes: routes };
      var tok = document.getElementById("edgeToken").value.trim();
      if (tok) payload.token = tok;
      payload.cf_service_client_id = document.getElementById("edgeCfId").value.trim();
      var cfSecret = document.getElementById("edgeCfSecret").value.trim();
      if (cfSecret) payload.cf_service_client_secret = cfSecret;
      try {
        var r = await jpost("/api/edge/configure", payload);
        if (r && r.ok === false) alert(r.error || "Save failed");
      } catch (e) { alert(e.message || e); }
      loadEdge();
    };

    var toggle = document.getElementById("edgeToggle");
    if (toggle) toggle.onclick = async function () {
      toggle.disabled = true;
      try {
        var r = await jpost(live ? "/api/edge/disable" : "/api/edge/enable", {});
        if (r && r.ok === false) alert((r.error || "failed") + (r.detail ? "\n" + r.detail : ""));
      } catch (e) { alert(e.message || e); }
      loadEdge();
    };
  }

  window.loadEdge = loadEdge;

  function init() { injectNavButtons(); attachLeaveHandlers(); }
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();

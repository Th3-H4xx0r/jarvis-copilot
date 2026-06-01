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
    return '<span class="edge-dot" style="background:' + (ok ? "#3fb950" : "#f85149") + '"></span>';
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
    // Hide EVERY other main-area view, not just chat — Code Memory / Long-term
    // Memory inject their own #mainCodememory/#mainJmemory full-screen views,
    // and leaving them visible bleeds their header into ours (#glitch). Hide all
    // siblings of #mainEdge, then show ours.
    var main = document.querySelector("main.main");
    if (main) {
      Array.prototype.forEach.call(main.children, function (c) {
        if (c.id !== "mainEdge") c.style.display = "none";
      });
    }
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
      // Idempotent guard: scope to THIS rail (src's parent) and bail if an edge
      // button already exists in it. The immediate-sibling check used before was
      // fragile — jarvis_memory.js inserts its own button after codememory too,
      // so once it wedged in between, our guard stopped seeing ours and we got a
      // duplicate on every re-run. (#duplicate-cloud-tab)
      var rail = src.parentElement;
      if (!rail || rail.querySelector('[data-panel="edge"]')) return;
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
      // Append at the end of the rail (after jmemory if present) so we never sit
      // between codememory and jmemory and break jarvis_memory's adjacency guard.
      rail.appendChild(btn);
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
    return '<div class="edge-check">' + dot(ok) +
      '<strong>' + esc(label) + '</strong>' +
      (detail ? ' <span style="opacity:.7">— ' + esc(detail) + '</span>' : '') + '</div>';
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
      return '<div class="edge-row-install" style="display:flex;align-items:center;gap:8px;padding:3px 0">' + dot(!!t.installed) +
        '<strong>' + name + '</strong>' +
        '<span style="opacity:.7;font-size:12px">' + esc(t.version || (t.installed ? "installed" : "not installed")) + '</span>' +
        (t.installed ? '' : '<button type="button" data-install="' + name + '" style="margin-left:auto;font-size:12px">Install</button>') +
        '</div>';
    }

    // A status line with a per-service Start/Stop button.
    function serviceRow(name, proc, tool) {
      var running = !!proc.running;
      var detail = running ? "running (pid " + proc.pid + ")" : "stopped";
      var btn;
      if (running) {
        btn = '<button type="button" data-svc-stop="' + name + '" style="margin-left:auto;font-size:12px;background:#f85149;color:#fff;border-color:#f85149">Stop</button>';
      } else if (!tool.installed) {
        btn = '<button type="button" disabled style="margin-left:auto;font-size:12px" title="Install ' + name + ' first">Start</button>';
      } else {
        btn = '<button type="button" data-svc-start="' + name + '" style="margin-left:auto;font-size:12px">Start</button>';
      }
      return '<div class="edge-row-install" style="display:flex;align-items:center;gap:8px;padding:3px 0">' +
        dot(running) + '<strong>' + name + '</strong>' +
        '<span style="opacity:.7;font-size:12px">' + esc(detail) + '</span>' + btn + '</div>';
    }

    // Collapsible step-by-step help. `body` is a sequence of HTML strings/<li>s.
    function help(summary, stepsHtml) {
      return '<details class="edge-help"><summary>ⓘ ' + esc(summary) + '</summary>' +
        '<div class="edge-help-body">' + stepsHtml + '</div></details>';
    }
    function steps(arr) { return '<ol>' + arr.map(function (s) { return '<li>' + s + '</li>'; }).join('') + '</ol>'; }

    body.innerHTML =
      help('What does this page do? Start here', steps([
        'Cloudflare <b>Tunnel</b> exposes this server to the internet without opening any ports — <code>cloudflared</code> dials out to Cloudflare, and traffic comes back down that connection.',
        '<b>nginx</b> sits in front and routes each subdomain to the right local app, strips spoofable headers, and adds security headers.',
        'Cloudflare <b>Access</b> (set up in your Cloudflare dashboard) makes sure only <i>you</i> can reach it.',
        'Do it in order: <b>Install</b> the two tools → fill in <b>Configuration</b> → fix any red <b>Safety preflight</b> item → <b>Enable tunnel</b>.',
      ])) +

      '<h3>Tooling</h3>' +
      '<div class="edge-note">Both tools run on this server. Click Install; if it fails the reason is shown (e.g. you may need to install nginx manually on a locked-down host).</div>' +
      toolRow("cloudflared") + toolRow("nginx") +
      help('Install isn’t working?', steps([
        'The server installs via its package manager (apt/dnf/brew/…) or, for cloudflared, a direct download. It needs either root or passwordless <code>sudo</code>.',
        'On a minimal/root container with no package manager, install nginx yourself (e.g. <code>apk add nginx</code> / <code>apt-get install nginx</code>) then click the refresh — the dot turns green once it’s on PATH.',
        'cloudflared has no dependencies — if the download is blocked, grab the binary from Cloudflare’s GitHub releases and drop it in <code>~/.local/bin</code>.',
      ])) +

      '<h3>Configuration</h3>' +
      '<label class="has-tooltip has-tooltip--bottom-right" data-tooltip="The root domain you added to Cloudflare">Domain</label>' +
      '<input id="edgeDomain" type="text" value="' + esc(st.domain || "") + '" placeholder="example.com">' +
      '<label class="has-tooltip has-tooltip--bottom-right" data-tooltip="Map each hostname to a local app port">Routes (one per line: <code>sub=127.0.0.1:port</code>, use <code>@</code> for apex)</label>' +
      '<textarea id="edgeRoutes" rows="4" placeholder="jarvis=127.0.0.1:8787">' + esc(routesText) + '</textarea>' +
      '<label class="has-tooltip has-tooltip--bottom-right" data-tooltip="From: Cloudflare dashboard → Zero Trust → Networks → Tunnels">Tunnel token</label>' +
      '<input id="edgeToken" type="password" placeholder="' + (st.has_token ? "saved (" + esc(st.token_masked) + ")" : "paste cloudflared tunnel token") + '">' +
      help('How do I fill these in?', steps([
        '<b>Domain</b>: the root domain you’ve added to Cloudflare, e.g. <code>example.com</code>. Your nameservers must already point at Cloudflare.',
        '<b>Routes</b>: one per line, <code>subdomain=127.0.0.1:port</code>. e.g. <code>jarvis=127.0.0.1:8787</code> serves the WebUI at <code>jarvis.example.com</code>. Use <code>@</code> for the bare domain. Targets must be loopback (127.0.0.1) — nginx is the only thing that reaches your apps.',
        '<b>Tunnel token</b>: in the Cloudflare dashboard go to <b>Zero Trust → Networks → Tunnels → Create a tunnel</b> (choose <i>Cloudflared</i>). After naming it, the install screen shows a command containing <code>--token eyJ…</code>. Copy just that long token string and paste it here.',
      ])) +
      help('IMPORTANT: a token tunnel needs Public Hostnames added in Cloudflare', steps([
        'A <b>token-based</b> tunnel (the kind you have) does NOT use this page’s local ingress config — it pulls its routing from the Cloudflare dashboard. So even with everything green here, nothing reaches your apps until you add a <b>Public Hostname</b> there. (That’s why your “hostname routes” page is empty.)',
        'In the dashboard: <b>Zero Trust → Networks → Tunnels → your tunnel → Configure → Public Hostname → Add a public hostname</b>. (Use the <b>Public Hostnames</b> tab, NOT “Hostname routes”.)',
        'Set <b>Subdomain</b> = <code>jarvis</code>, <b>Domain</b> = your domain, leave Path blank.',
        'Set <b>Service</b> = Type <code>HTTP</code>, URL <code>localhost:' + (st.nginx_listen_port || 8788) + '</code> (this points at the nginx that this page runs). Save.',
        'Repeat for each route you added above. Cloudflare auto-creates the DNS record. Then the tunnel actually serves <code>jarvis.example.com</code>.',
      ])) +

      '<h3>Cloudflare Access service token (for native apps)</h3>' +
      '<div class="edge-note">Mobile/desktop apps can\'t do browser SSO. Create a service token, paste it here, and it\'s delivered to each device when it pairs.</div>' +
      '<label class="has-tooltip has-tooltip--bottom-right" data-tooltip="Zero Trust → Access → Service Auth → Service Tokens">Client ID</label>' +
      '<input id="edgeCfId" type="text" value="' + esc(st.cf_service_client_id || "") + '" placeholder="xxxxxxxx.access">' +
      '<label class="has-tooltip has-tooltip--bottom-right" data-tooltip="Shown only once when you create the token — copy it then">Client Secret</label>' +
      '<input id="edgeCfSecret" type="password" placeholder="' + (st.has_cf_service_token ? "saved (" + esc(st.cf_service_secret_masked) + ")" : "paste service token secret") + '">' +
      help('How do I create a service token?', steps([
        'In the Cloudflare dashboard: <b>Zero Trust → Access → Service Auth → Service Tokens → Create Service Token</b>.',
        'Name it (e.g. "jarvis-devices") and create it. Cloudflare shows a <b>Client ID</b> and <b>Client Secret</b> — the secret is shown <i>only once</i>, so copy both now.',
        'Paste them above and <b>Save</b>. Then edit your Access application’s policy to <b>include</b> this service token (so it’s allowed through).',
        'When a phone/desktop pairs, the token is handed to it automatically (it’s also embedded in the pairing QR) so the app can authenticate without a browser login.',
      ])) +

      '<div style="margin-top:12px"><button type="button" id="edgeSave">Save configuration</button></div>' +

      '<h3>Safety preflight</h3>' +
      '<div class="edge-note">All checks must be green before the tunnel can be enabled. Each line says what to fix.</div>' +
      (pf.checks || []).map(function (c) {
        return row(c.name, c.ok, c.detail) +
          (c.ackable
            ? '<div style="margin:2px 0 8px 16px"><button type="button" id="edgeAck" style="font-size:12px">I understand — my origin isn’t publicly exposed (container/firewall)</button></div>'
            : "");
      }).join("") +
      help('What do these checks mean?', steps([
        '<b>origin_bound_to_loopback</b>: the WebUI should bind <code>127.0.0.1</code> so only nginx can reach it. Set <code>HERMES_WEBUI_HOST=127.0.0.1</code> and restart (skip if WebUI + nginx share one container).',
        '<b>forwarded_host_csrf_fix</b>: confirms the server only trusts proxy headers from nginx — green means you’re patched.',
        '<b>routes_valid</b>: your Domain + Routes above parse and point at loopback targets.',
        '<b>tunnel_token_set</b>: a cloudflared tunnel token is saved.',
      ])) +

      '<h3>Status</h3>' +
      '<div class="edge-note">Start or stop each service individually. "Enable tunnel" below starts both at once (after preflight passes).</div>' +
      serviceRow("nginx", procs.nginx || {}, tools.nginx || {}) +
      serviceRow("cloudflared", procs.cloudflared || {}, tools.cloudflared || {}) +
      '<div style="margin-top:12px"><button type="button" id="edgeToggle"' +
      (live ? ' style="background:#f85149;color:#fff;border-color:#f85149"' : '') +
      (!live && !pf.ok ? " disabled" : "") + '>' +
      (live ? "Disable tunnel" : "Enable tunnel") + '</button></div>' +
      (!live && !pf.ok ? '<div class="edge-note" style="color:#d29922;margin-top:4px">Resolve all preflight checks before enabling.</div>' : '') +

      help('Last step: lock it to only you (Cloudflare Access)', steps([
        'The tunnel by itself is reachable by anyone who knows the URL — <b>Cloudflare Access</b> is what restricts it to you.',
        '<b>Zero Trust → Access → Applications → Add an application</b>. Pick the <b>Self-hosted and private</b> tab, then the <b>Public DNS</b> option (your app is a public hostname served by the tunnel), and click <b>Continue</b>.',
        '<b>Destinations</b>: add a public hostname destination = your route, e.g. <code>jarvis.example.com</code> (the same hostname you added as a Public Hostname on the tunnel).',
        '<b>Policies</b>: create a policy → Action <b>Allow</b> → add an <b>Include</b> rule, selector <b>Emails</b>, value <i>your email</i>. This is what makes it “only me”.',
        'Add a SECOND <b>Include</b> rule in that same policy: selector <b>Service Token</b> → choose the token you created above. Without this, your phone/desktop apps get blocked by Access.',
        '<b>Sources</b>: leave as the default identity provider (e.g. One-time PIN to your email) unless you’ve set up Google/GitHub login. Save the application.',
        'Now anyone hitting <code>jarvis.example.com</code> gets Cloudflare’s login wall; only your email (in a browser) or your service token (native apps) gets through.',
      ]));

    // ── wire handlers ──
    body.querySelectorAll("[data-install]").forEach(function (b) {
      b.onclick = async function () {
        b.disabled = true; b.textContent = "Installing…";
        try {
          var r = await jpost("/api/edge/install", { tool: b.getAttribute("data-install") });
          if (r && r.ok === false) {
            alert("Install failed: " + (r.error || "unknown error"));
          }
        } catch (e) {
          alert("Install failed: " + (e.message || e));
        }
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

    // Acknowledge non-loopback origin (container/firewall) — clears the gate.
    var ack = document.getElementById("edgeAck");
    if (ack) ack.onclick = async function () {
      ack.disabled = true;
      try { await jpost("/api/edge/configure", { loopback_ack: true }); }
      catch (e) { alert(e.message || e); }
      loadEdge();
    };

    // Per-service Start / Stop.
    function wireSvc(attr, endpoint) {
      body.querySelectorAll("[" + attr + "]").forEach(function (b) {
        b.onclick = async function () {
          b.disabled = true; b.textContent = "…";
          try {
            var r = await jpost(endpoint, { name: b.getAttribute(attr) });
            if (r && r.ok === false) alert((r.error || "failed") + (r.detail ? "\n" + r.detail : ""));
          } catch (e) { alert(e.message || e); }
          loadEdge();
        };
      });
    }
    wireSvc("data-svc-start", "/api/edge/service/start");
    wireSvc("data-svc-stop", "/api/edge/service/stop");
  }

  window.loadEdge = loadEdge;

  function init() { injectNavButtons(); attachLeaveHandlers(); }
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();

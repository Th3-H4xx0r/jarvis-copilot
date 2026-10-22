/* memory_map.js — the Map view of the Long-term Memory panel.
 *
 * A <canvas> force-directed graph of the memory map: You fixed at the center,
 * the people / places / events / topics / orgs around you. Wheel / pinch zoom,
 * drag to pan, drag a node to move it, click a node for its side panel
 * (memories, pin, expand in place, fix: rename + aliases, merge into…, remove
 * a wrong link). Filters by type / time / source; highlight mode lights up the
 * nodes one recall used. Graph logic lives in memory_graph.js (MemoryGraph).
 *
 * window.MemoryMap = {mount(container), show(), reload(), highlightRecall(id, query)}
 */
(function () {
  "use strict";

  var G = window.MemoryGraph;
  if (!G) return;

  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  function nowSec() { return Math.floor(Date.now() / 1000); }

  function getJson(url) {
    return fetch(url).then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    });
  }

  function postJson(url, body) {
    return fetch(url, {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body || {}),
    }).then(function (r) {
      return r.json().catch(function () { return {}; }).then(function (d) {
        if (!r.ok || (d && d.error)) throw new Error((d && d.error) || ("HTTP " + r.status));
        return d;
      });
    });
  }

  function fmtDay(ts) {
    if (!ts) return "";
    try {
      return new Date(ts * 1000).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
    } catch (e) { return ""; }
  }

  function sourceLabel(src) {
    var fam = String(src || "").split(":")[0];
    var hit = G.SOURCES.find(function (s) { return s.value && s.value === fam; });
    return hit ? hit.label : fam;
  }

  var FILTER_KEY = "jmem-map-filters";
  var BTN = "font-size:12px;padding:4px 10px;border-radius:8px;border:1px solid var(--border);" +
    "background:var(--bg);color:var(--text,var(--fg));cursor:pointer";
  var SEL = "padding:5px 8px;border-radius:8px;border:1px solid var(--border);background:var(--bg);color:var(--text,var(--fg));font-size:12px";
  var INPUT = "width:100%;box-sizing:border-box;padding:6px 8px;border-radius:8px;border:1px solid var(--border);" +
    "background:var(--bg);color:var(--text,var(--fg));font-size:12px";

  var st = {
    root: null, canvas: null, ctx: null, w: 0, h: 0, dpr: 1,
    graph: G.createGraph(), view: { x: 0, y: 0, k: 1 },
    filters: loadFilters(),
    selected: null, hover: null, highlight: null, highlightQuery: "",
    raf: 0, drawRaf: 0, ticks: 0, calm: 0,
    pointers: new Map(), drag: null, pinch: null,
    loaded: false, loading: false, seq: 0, sideSeq: 0,
    entity: null, fixOpen: false, mergeQ: "", confirmMerge: null, colors: null,
  };

  function loadFilters() {
    var f = { types: G.TYPES.slice(), time: "all", source: "" };
    try {
      var raw = JSON.parse(localStorage.getItem(FILTER_KEY) || "null");
      if (raw && Array.isArray(raw.types) && raw.types.length) f.types = raw.types.filter(function (t) { return G.TYPES.indexOf(t) >= 0; });
      if (raw && typeof raw.time === "string") f.time = raw.time;
      if (raw && typeof raw.source === "string") f.source = raw.source;
      if (!f.types.length) f.types = G.TYPES.slice();
    } catch (e) { /* per-viewer convenience only */ }
    return f;
  }

  function saveFilters() {
    try { localStorage.setItem(FILTER_KEY, JSON.stringify(st.filters)); } catch (e) {}
  }

  function readColors() {
    var cs = getComputedStyle(document.documentElement);
    function v(name, fb) { var x = (cs.getPropertyValue(name) || "").trim(); return x || fb; }
    st.colors = {
      accent: v("--accent", "#B8860B"), text: v("--text", "#222"), muted: v("--muted", "#777"),
      bg: v("--bg", "#fff"), border: v("--border", "#ddd"),
    };
  }

  // ── DOM ──
  function mount(container) {
    if (st.root && st.root.isConnected && container.contains(st.root)) return;
    container.innerHTML = "";
    var root = document.createElement("div");
    root.id = "jmapRoot";
    root.innerHTML =
      '<div id="jmapFilters" style="display:flex;flex-wrap:wrap;gap:6px;align-items:center;margin-bottom:10px"></div>' +
      '<div id="jmapBanner" style="display:none;align-items:center;gap:8px;margin-bottom:8px;padding:6px 10px;' +
      'border:1px solid var(--border);border-radius:10px;font-size:12px;background:var(--accent-bg,transparent)"></div>' +
      '<div style="display:flex;flex-wrap:wrap;gap:10px;align-items:stretch">' +
      '<div id="jmapStage" style="position:relative;flex:3 1 420px;min-width:0;height:calc(100vh - 290px);min-height:360px;' +
      'border:1px solid var(--border);border-radius:12px;overflow:hidden;background:var(--card,var(--bg));touch-action:none">' +
      '<canvas id="jmapCanvas" role="img" aria-label="Memory map" style="display:block;width:100%;height:100%;cursor:grab"></canvas>' +
      '<div id="jmapStatus" style="position:absolute;left:0;right:0;top:45%;text-align:center;font-size:13px;color:var(--muted);pointer-events:none"></div>' +
      '<div style="position:absolute;right:8px;bottom:8px;display:flex;gap:4px">' +
      '<button type="button" class="jmap-zoom" data-z="in" title="Zoom in" style="' + BTN + ';width:30px;padding:4px 0">+</button>' +
      '<button type="button" class="jmap-zoom" data-z="out" title="Zoom out" style="' + BTN + ';width:30px;padding:4px 0">&minus;</button>' +
      '<button type="button" class="jmap-zoom" data-z="fit" title="Fit" style="' + BTN + '">Fit</button></div>' +
      '<div style="position:absolute;left:8px;bottom:8px;font-size:10px;color:var(--muted);pointer-events:none" id="jmapCount"></div>' +
      "</div>" +
      '<div id="jmapSide" style="display:none;flex:1 1 300px;max-width:100%;min-width:0;max-height:calc(100vh - 290px);min-height:360px;overflow:auto;' +
      'border:1px solid var(--border);border-radius:12px;padding:12px;box-sizing:border-box;background:var(--card,var(--bg))"></div>' +
      "</div>";
    container.appendChild(root);
    st.root = root;
    st.canvas = root.querySelector("#jmapCanvas");
    st.ctx = st.canvas.getContext("2d");
    renderFilters();
    wireCanvas();
    root.querySelectorAll(".jmap-zoom").forEach(function (b) {
      b.addEventListener("click", function () {
        var z = b.getAttribute("data-z");
        if (z === "fit") fit();
        else st.view = G.zoomAt(st.view, z === "in" ? 1.3 : 1 / 1.3, st.w / 2, st.h / 2);
        requestDraw();
      });
    });
    var stage = root.querySelector("#jmapStage");
    if (window.ResizeObserver) new ResizeObserver(resize).observe(stage);
    else window.addEventListener("resize", resize);
    resize();
    if (st.selected) renderSide();
  }

  function visible() {
    return !!(st.canvas && st.canvas.isConnected && st.canvas.offsetParent !== null && !document.hidden);
  }

  function resize() {
    if (!st.canvas) return;
    var rect = st.canvas.getBoundingClientRect();
    var w = Math.max(1, Math.round(rect.width)), h = Math.max(1, Math.round(rect.height));
    if (!rect.width || !rect.height) return;
    var dpr = window.devicePixelRatio || 1;
    if (st.w && st.h) { st.view.x += (w - st.w) / 2; st.view.y += (h - st.h) / 2; }
    else { st.view = { x: w / 2, y: h / 2, k: 1 }; }
    st.w = w; st.h = h; st.dpr = dpr;
    st.canvas.width = Math.round(w * dpr);
    st.canvas.height = Math.round(h * dpr);
    requestDraw();
  }

  function fit() {
    var ns = st.graph.nodes;
    if (!ns.length || !st.w) return;
    var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    ns.forEach(function (n) {
      var r = G.radiusFor(n);
      minX = Math.min(minX, n.x - r); maxX = Math.max(maxX, n.x + r);
      minY = Math.min(minY, n.y - r); maxY = Math.max(maxY, n.y + r);
    });
    var k = Math.min(st.w / (maxX - minX + 80), st.h / (maxY - minY + 80), 2);
    k = Math.max(G.MIN_ZOOM, Math.min(G.MAX_ZOOM, k));
    st.view = { k: k, x: st.w / 2 - ((minX + maxX) / 2) * k, y: st.h / 2 - ((minY + maxY) / 2) * k };
  }

  // ── filters ──
  function renderFilters() {
    var el = st.root && st.root.querySelector("#jmapFilters");
    if (!el) return;
    var html = G.TYPES.map(function (t) {
      var on = st.filters.types.indexOf(t) >= 0;
      return '<button type="button" class="jmap-type" data-type="' + esc(t) + '" aria-pressed="' + on + '" style="' +
        "display:inline-flex;align-items:center;gap:6px;font-size:12px;padding:4px 10px;border-radius:999px;cursor:pointer;" +
        "border:1px solid " + (on ? G.colorFor(t) : "var(--border)") + ";background:" + (on ? "var(--accent-bg,transparent)" : "transparent") +
        ";color:" + (on ? "var(--text,var(--fg))" : "var(--muted)") + '">' +
        '<span style="width:8px;height:8px;border-radius:50%;background:' + G.colorFor(t) + ";opacity:" + (on ? 1 : 0.35) + '"></span>' +
        esc(G.TYPE_LABELS[t]) + "</button>";
    }).join("");
    html += '<select id="jmapTime" aria-label="Time" style="' + SEL + '">' + G.TIME_RANGES.map(function (r) {
      return '<option value="' + esc(r.value) + '"' + (r.value === st.filters.time ? " selected" : "") + ">" + esc(r.label) + "</option>";
    }).join("") + "</select>";
    html += '<select id="jmapSource" aria-label="Source" style="' + SEL + '">' + G.SOURCES.map(function (s) {
      return '<option value="' + esc(s.value) + '"' + (s.value === st.filters.source ? " selected" : "") + ">" + esc(s.label) + "</option>";
    }).join("") + "</select>";
    el.innerHTML = html;
    el.querySelectorAll(".jmap-type").forEach(function (b) {
      b.addEventListener("click", function () {
        var t = b.getAttribute("data-type");
        var i = st.filters.types.indexOf(t);
        if (i >= 0) { if (st.filters.types.length === 1) return; st.filters.types.splice(i, 1); }
        else st.filters.types.push(t);
        filtersChanged();
      });
    });
    el.querySelector("#jmapTime").addEventListener("change", function (ev) { st.filters.time = ev.target.value; filtersChanged(); });
    el.querySelector("#jmapSource").addEventListener("change", function (ev) { st.filters.source = ev.target.value; filtersChanged(); });
  }

  function filtersChanged() {
    saveFilters();
    renderFilters();
    clearHighlight(true);
    loadBase();
  }

  function setStatus(msg) {
    var el = st.root && st.root.querySelector("#jmapStatus");
    if (el) el.textContent = msg || "";
  }

  function updateCount() {
    var el = st.root && st.root.querySelector("#jmapCount");
    if (el) el.textContent = Math.max(0, st.graph.nodes.length - 1) + " nodes";
  }

  // ── loading ──
  function loadBase() {
    var seq = ++st.seq;
    st.loading = true;
    setStatus(st.graph.nodes.length > 1 ? "" : "Loading the map…");
    var url = G.graphUrl({ center: "me", types: st.filters.types, time: st.filters.time, source: st.filters.source }, nowSec());
    return getJson(url).then(function (d) {
      if (seq !== st.seq) return;
      G.loadGraph(st.graph, d);
      st.loaded = true;
      afterLoad(st.graph.nodes.length > 1 ? "" :
        "No mapped memories match these filters yet. New memories are mapped automatically.");
    }).catch(function () {
      if (seq !== st.seq) return;
      setStatus("Couldn’t load the map.");
    }).then(function () { if (seq === st.seq) st.loading = false; });
  }

  function afterLoad(status) {
    if (st.selected && !G.node(st.graph, st.selected)) closeSide();
    setStatus(status);
    updateCount();
    st.view = { x: st.w / 2, y: st.h / 2, k: 1 };
    kick();
  }

  function highlightRecall(recallId, query) {
    var seq = ++st.seq;
    st.loading = true;
    st.highlightQuery = query || "";
    setStatus("Loading…");
    return getJson("api/jarvis-memory/graph/highlight?recall=" + encodeURIComponent(recallId)).then(function (d) {
      if (seq !== st.seq) return;
      G.loadGraph(st.graph, d);
      st.highlight = new Set(((d && d.highlight) || []).map(String));
      st.loaded = true;
      renderBanner();
      afterLoad(st.graph.nodes.length > 1 ? "" : "Those memories aren’t mapped to anything yet.");
    }).catch(function () {
      if (seq !== st.seq) return;
      setStatus("Couldn’t load that recall.");
    }).then(function () { if (seq === st.seq) st.loading = false; });
  }

  function renderBanner() {
    var el = st.root && st.root.querySelector("#jmapBanner");
    if (!el) return;
    if (!st.highlight) { el.style.display = "none"; el.innerHTML = ""; return; }
    el.style.display = "flex";
    el.innerHTML = '<span style="flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">Memories used for ' +
      (st.highlightQuery ? "“" + esc(st.highlightQuery) + "”" : "this reply") + "</span>" +
      '<button type="button" id="jmapClearHl" style="' + BTN + '">Show all</button>';
    el.querySelector("#jmapClearHl").addEventListener("click", function () { clearHighlight(); loadBase(); });
  }

  function clearHighlight(silent) {
    st.highlight = null;
    st.highlightQuery = "";
    renderBanner();
    if (!silent) requestDraw();
  }

  // ── animation ──
  function kick() {
    st.ticks = 0;
    st.calm = 0;
    if (!st.raf && visible()) st.raf = requestAnimationFrame(frame);
  }

  function frame() {
    st.raf = 0;
    if (!visible()) return;                       // panel hidden: stop; show() restarts
    var e = G.step(st.graph);
    st.ticks++;
    draw();
    st.calm = G.isSettled(e, st.graph.nodes.length) ? st.calm + 1 : 0;
    if (!st.drag && (st.calm >= 10 || st.ticks > 1500)) return;   // settled: stop the loop
    st.raf = requestAnimationFrame(frame);
  }

  function requestDraw() {
    if (st.raf || st.drawRaf || !st.canvas) return;
    st.drawRaf = requestAnimationFrame(function () { st.drawRaf = 0; draw(); });
  }

  function stop() {
    if (st.raf) cancelAnimationFrame(st.raf);
    if (st.drawRaf) cancelAnimationFrame(st.drawRaf);
    st.raf = 0; st.drawRaf = 0;
  }

  function draw() {
    var c = st.ctx;
    if (!c || !st.w) return;
    if (!st.colors) readColors();
    var col = st.colors, v = st.view, hl = st.highlight;
    c.setTransform(1, 0, 0, 1, 0, 0);
    c.clearRect(0, 0, st.canvas.width, st.canvas.height);
    c.setTransform(st.dpr * v.k, 0, 0, st.dpr * v.k, st.dpr * v.x, st.dpr * v.y);
    var byId = new Map();
    st.graph.nodes.forEach(function (n) { byId.set(n.id, n); });
    c.strokeStyle = col.muted;
    st.graph.edges.forEach(function (e) {
      var a = byId.get(e.a), b = byId.get(e.b);
      if (!a || !b) return;
      var dim = G.isDimmed(a.id, hl) || G.isDimmed(b.id, hl);
      var focus = st.selected && (a.id === st.selected || b.id === st.selected);
      c.globalAlpha = dim ? 0.06 : (focus ? 0.7 : 0.28);
      c.lineWidth = (0.6 + Math.min(2.4, Math.log1p(e.weight) * 0.45)) / Math.sqrt(v.k);
      c.beginPath(); c.moveTo(a.x, a.y); c.lineTo(b.x, b.y); c.stroke();
    });
    var labelCtx = { selected: st.selected, hover: st.hover, highlight: hl };
    var labels = [];
    st.graph.nodes.forEach(function (n) {
      var r = G.radiusFor(n);
      var dim = G.isDimmed(n.id, hl);
      c.globalAlpha = dim ? 0.15 : 1;
      c.fillStyle = G.colorFor(n.type, col.accent);
      c.beginPath(); c.arc(n.x, n.y, r, 0, Math.PI * 2); c.fill();
      if (n.pinned || n.id === st.selected || (hl && hl.has(n.id))) {
        c.lineWidth = (n.id === st.selected ? 3 : 2) / v.k;
        c.strokeStyle = n.id === st.selected ? col.text : col.accent;
        c.beginPath(); c.arc(n.x, n.y, r + 3 / v.k, 0, Math.PI * 2); c.stroke();
      }
      if (G.showLabel(n, v.k, labelCtx)) labels.push([n, r, dim]);
    });
    var fs = 12 / v.k;
    c.font = (st.selected ? "500 " : "") + fs + "px system-ui, -apple-system, sans-serif";
    c.textAlign = "center";
    c.textBaseline = "top";
    c.lineJoin = "round";
    labels.forEach(function (l) {
      var n = l[0];
      var text = n.label.length > 28 ? n.label.slice(0, 27) + "…" : n.label;
      c.globalAlpha = l[2] ? 0.25 : 1;
      c.lineWidth = 3 / v.k;
      c.strokeStyle = col.bg;
      c.strokeText(text, n.x, n.y + l[1] + 3 / v.k);
      c.fillStyle = col.text;
      c.fillText(text, n.x, n.y + l[1] + 3 / v.k);
    });
    c.globalAlpha = 1;
  }

  // ── pointer input ──
  function local(e) {
    var r = st.canvas.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
  }

  function pinchState() {
    var pts = Array.from(st.pointers.values());
    var a = pts[0], b = pts[1];
    return { dist: Math.hypot(a.x - b.x, a.y - b.y) || 1, mid: { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 } };
  }

  function wireCanvas() {
    var cv = st.canvas;
    cv.addEventListener("pointerdown", function (e) {
      var p = local(e);
      try { cv.setPointerCapture(e.pointerId); } catch (err) {}
      st.pointers.set(e.pointerId, p);
      if (st.pointers.size === 2) {
        if (st.drag && st.drag.node) st.drag.node.fixed = false;
        st.drag = null;
        var ps = pinchState();
        st.pinch = { dist: ps.dist, mid: ps.mid, view: Object.assign({}, st.view) };
        return;
      }
      if (st.pointers.size > 2) return;
      var hit = G.hitTest(st.graph, st.view, p.x, p.y);
      st.drag = { node: hit && hit.id !== G.ME ? hit : null, hit: hit, start: p, moved: false, view: Object.assign({}, st.view) };
      if (st.drag.node) st.drag.node.fixed = true;
      cv.style.cursor = "grabbing";
    });
    cv.addEventListener("pointermove", function (e) {
      var p = local(e);
      if (st.pointers.has(e.pointerId)) st.pointers.set(e.pointerId, p);
      if (st.pinch && st.pointers.size >= 2) {
        var ps = pinchState();
        var v = G.zoomAt(st.pinch.view, ps.dist / st.pinch.dist, st.pinch.mid.x, st.pinch.mid.y);
        v.x += ps.mid.x - st.pinch.mid.x;
        v.y += ps.mid.y - st.pinch.mid.y;
        st.view = v;
        requestDraw();
        return;
      }
      var d = st.drag;
      if (d) {
        var dx = p.x - d.start.x, dy = p.y - d.start.y;
        if (!d.moved && Math.hypot(dx, dy) > 4) d.moved = true;
        if (!d.moved) return;
        if (d.node) {
          var w = G.toWorld(st.view, p.x, p.y);
          d.node.x = w.x; d.node.y = w.y; d.node.vx = 0; d.node.vy = 0;
          kick();
        } else {
          st.view = { x: d.view.x + dx, y: d.view.y + dy, k: d.view.k };
          requestDraw();
        }
        return;
      }
      var hit = G.hitTest(st.graph, st.view, p.x, p.y);
      var id = hit ? hit.id : null;
      cv.style.cursor = hit && hit.id !== G.ME ? "pointer" : "grab";
      if (id !== st.hover) { st.hover = id; requestDraw(); }
    });
    function end(e) {
      st.pointers.delete(e.pointerId);
      if (st.pinch) { if (st.pointers.size < 2) st.pinch = null; return; }
      var d = st.drag;
      st.drag = null;
      cv.style.cursor = "grab";
      if (!d) return;
      if (d.node) { d.node.fixed = false; kick(); }
      if (!d.moved && e.type === "pointerup") {
        if (d.hit && d.hit.id !== G.ME) openNode(d.hit.id);
        else closeSide();
      }
    }
    cv.addEventListener("pointerup", end);
    cv.addEventListener("pointercancel", end);
    cv.addEventListener("pointerleave", function () { if (st.hover && !st.drag) { st.hover = null; requestDraw(); } });
    cv.addEventListener("wheel", function (e) {
      e.preventDefault();
      var p = local(e);
      var dy = e.deltaMode === 1 ? e.deltaY * 16 : e.deltaY;
      st.view = G.zoomAt(st.view, Math.exp(-dy * (e.ctrlKey ? 0.01 : 0.0015)), p.x, p.y);
      requestDraw();
    }, { passive: false });
  }

  // ── side panel ──
  function sideEl() { return st.root && st.root.querySelector("#jmapSide"); }

  function closeSide() {
    st.selected = null;
    st.entity = null;
    st.fixOpen = false;
    st.confirmMerge = null;
    var el = sideEl();
    if (el) { el.style.display = "none"; el.innerHTML = ""; }
    requestDraw();
  }

  function openNode(id) {
    if (st.selected !== id) { st.fixOpen = false; st.mergeQ = ""; st.confirmMerge = null; }
    st.selected = id;
    st.entity = null;
    requestDraw();
    renderSide("Loading memories…");
    var seq = ++st.sideSeq;
    return getJson("api/jarvis-memory/entity?id=" + encodeURIComponent(id) + "&limit=50").then(function (d) {
      if (seq !== st.sideSeq || st.selected !== id) return;
      st.entity = d || {};
      var ent = st.entity.entity;
      var n = G.node(st.graph, id);
      if (n && ent) {
        if (ent.label != null) n.label = String(ent.label);
        if (Array.isArray(ent.aliases)) n.aliases = ent.aliases.slice();
        n.pinned = !!ent.pinned;
      }
      renderSide();
      requestDraw();
    }).catch(function () {
      if (seq !== st.sideSeq) return;
      renderSide("", "Couldn’t load this node’s memories.");
    });
  }

  function renderSide(loadingMsg, errMsg) {
    var el = sideEl();
    if (!el || !st.selected) return;
    var n = G.node(st.graph, st.selected) || {};
    var ent = (st.entity && st.entity.entity) || {};
    var label = ent.label || n.label || st.selected;
    var type = ent.type || n.type || "";
    var aliases = ent.aliases || n.aliases || [];
    var pinned = ent.pinned != null ? !!ent.pinned : !!n.pinned;
    var mems = (st.entity && st.entity.memories) || [];
    var html =
      '<div style="display:flex;align-items:flex-start;gap:8px">' +
      '<div style="flex:1;min-width:0"><div style="font-weight:600;font-size:15px;word-break:break-word">' + esc(label) + "</div>" +
      '<div style="display:flex;align-items:center;gap:6px;margin-top:3px">' +
      '<span style="width:8px;height:8px;border-radius:50%;background:' + G.colorFor(type) + '"></span>' +
      '<span style="font-size:11px;color:var(--muted);text-transform:capitalize">' + esc(type) + "</span>" +
      (ent.event_start ? '<span style="font-size:11px;color:var(--muted)">· ' + esc(fmtDay(ent.event_start)) + "</span>" : "") +
      "</div></div>" +
      '<button type="button" id="jmapClose" title="Close" aria-label="Close" style="background:none;border:none;color:var(--muted);cursor:pointer;font-size:18px;line-height:1">&times;</button></div>';
    if (aliases.length) {
      html += '<div style="font-size:12px;color:var(--muted);margin-top:6px">Also: ' + esc(aliases.join(", ")) + "</div>";
    }
    if (ent.summary) html += '<div style="font-size:12px;margin-top:6px">' + esc(ent.summary) + "</div>";
    html += '<div style="display:flex;flex-wrap:wrap;gap:6px;margin-top:10px">' +
      '<button type="button" id="jmapPin" aria-pressed="' + pinned + '" style="' + BTN + (pinned ? ";border-color:var(--accent)" : "") + '">' +
      (pinned ? "Pinned" : "Pin") + "</button>" +
      '<button type="button" id="jmapExpand" style="' + BTN + '">Expand</button>' +
      '<button type="button" id="jmapFixBtn" aria-expanded="' + st.fixOpen + '" style="' + BTN + '">Fix</button></div>' +
      '<div id="jmapMsg" style="font-size:12px;margin-top:6px;color:' + (errMsg ? "var(--danger,#c33)" : "var(--muted)") + '">' + esc(errMsg || "") + "</div>";
    if (st.fixOpen) html += fixHtml(label, aliases);
    html += '<div style="font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em;margin:12px 0 6px">Memories' +
      (mems.length ? " (" + mems.length + ")" : "") + "</div>";
    if (loadingMsg) html += '<div style="font-size:12px;color:var(--muted)">' + esc(loadingMsg) + "</div>";
    else if (!mems.length && !errMsg) html += '<div style="font-size:12px;color:var(--muted)">No memories under the current filters.</div>';
    html += mems.map(function (m) {
      var meta = [fmtDay(m.event_start || m.created_at), sourceLabel(m.source), m.role || ""].filter(Boolean).join(" · ");
      return '<div class="jmap-mem" style="padding:8px 10px;border:1px solid var(--border);border-radius:10px;margin-bottom:6px">' +
        '<div style="white-space:pre-wrap;word-break:break-word;font-size:13px">' + esc(m.body) + "</div>" +
        '<div style="display:flex;align-items:center;gap:6px;margin-top:5px;flex-wrap:wrap">' +
        '<span style="font-size:11px;color:var(--muted)">' + esc(meta) + "</span>" +
        (m.past ? '<span style="font-size:10px;padding:0 6px;border:1px solid var(--border);border-radius:6px;color:var(--muted)">no longer true</span>' : "") +
        '<button type="button" class="jmap-unlink" data-mem="' + esc(m.id) + '" style="margin-left:auto;font-size:11px;' +
        'color:var(--danger,#c33);background:none;border:none;cursor:pointer">Remove link</button></div></div>';
    }).join("");
    el.innerHTML = html;
    el.style.display = "block";
    wireSide(el);
  }

  function fixHtml(label, aliases) {
    var html = '<div style="margin-top:10px;padding:10px;border:1px solid var(--border);border-radius:10px">' +
      '<label style="font-size:11px;color:var(--muted)">Name</label>' +
      '<input id="jmapName" type="text" value="' + esc(label) + '" style="' + INPUT + ';margin:3px 0 8px">' +
      '<label style="font-size:11px;color:var(--muted)">Aliases (comma separated)</label>' +
      '<input id="jmapAliases" type="text" value="' + esc(aliases.join(", ")) + '" style="' + INPUT + ';margin:3px 0 8px">' +
      '<button type="button" id="jmapSave" style="' + BTN + '">Save</button>' +
      '<div style="font-size:11px;color:var(--muted);margin:12px 0 4px">Merge into…</div>' +
      '<input id="jmapMergeQ" type="text" placeholder="Filter" value="' + esc(st.mergeQ) + '" style="' + INPUT + ';margin-bottom:6px">' +
      '<div id="jmapMergeList" style="max-height:200px;overflow:auto">' + mergeListHtml() + "</div></div>";
    return html;
  }

  function mergeCandidates() {
    var list = G.mergeCandidates(st.graph, st.selected, st.mergeQ).map(function (n) { return { id: n.id, label: n.label }; });
    var self = G.node(st.graph, st.selected);
    var type = (st.entity && st.entity.entity && st.entity.entity.type) || (self && self.type);
    var q = st.mergeQ.trim().toLowerCase();
    ((st.entity && st.entity.neighbors) || []).forEach(function (nb) {
      if (!nb || nb.type !== type || String(nb.id) === st.selected) return;
      if (list.some(function (x) { return x.id === String(nb.id); })) return;
      if (q && String(nb.label || "").toLowerCase().indexOf(q) < 0) return;
      list.push({ id: String(nb.id), label: String(nb.label || nb.id) });
    });
    return list;
  }

  function mergeListHtml() {
    var list = mergeCandidates();
    if (!list.length) return '<div style="font-size:12px;color:var(--muted)">No other node of this type on the map.</div>';
    return list.map(function (c) {
      if (st.confirmMerge === c.id) {
        return '<div style="display:flex;align-items:center;gap:6px;padding:4px 0;font-size:12px">' +
          '<span style="flex:1;min-width:0">Merge into <b>' + esc(c.label) + "</b>?</span>" +
          '<button type="button" class="jmap-merge-go" data-id="' + esc(c.id) + '" style="' + BTN + '">Merge</button>' +
          '<button type="button" class="jmap-merge-cancel" style="' + BTN + '">Cancel</button></div>';
      }
      return '<button type="button" class="jmap-merge-pick" data-id="' + esc(c.id) + '" style="display:block;width:100%;text-align:left;' +
        'font-size:12px;padding:5px 6px;border:none;border-bottom:1px solid var(--border);background:none;color:var(--text,var(--fg));cursor:pointer">' +
        esc(c.label) + "</button>";
    }).join("");
  }

  function setMsg(text, err) {
    var m = st.root && st.root.querySelector("#jmapMsg");
    if (m) { m.textContent = text || ""; m.style.color = err ? "var(--danger,#c33)" : "var(--muted)"; }
  }

  function wireMergeList(el) {
    var list = el.querySelector("#jmapMergeList");
    if (!list) return;
    list.querySelectorAll(".jmap-merge-pick").forEach(function (b) {
      b.addEventListener("click", function () { st.confirmMerge = b.getAttribute("data-id"); list.innerHTML = mergeListHtml(); wireMergeList(el); });
    });
    list.querySelectorAll(".jmap-merge-cancel").forEach(function (b) {
      b.addEventListener("click", function () { st.confirmMerge = null; list.innerHTML = mergeListHtml(); wireMergeList(el); });
    });
    list.querySelectorAll(".jmap-merge-go").forEach(function (b) {
      b.addEventListener("click", function () {
        var from = st.selected, into = b.getAttribute("data-id");
        b.disabled = true;
        postJson("api/jarvis-memory/entity/merge", { from: from, into: into }).then(function (d) {
          var ent = (d && d.entity) || {};
          var survivor = ent.id != null ? String(ent.id) : into;
          G.mergeNodes(st.graph, from, survivor, ent);
          st.confirmMerge = null;
          st.fixOpen = false;
          updateCount();
          kick();
          openNode(survivor);
        }).catch(function (err) {
          b.disabled = false;
          setMsg("Couldn’t merge: " + (err && err.message ? err.message : "error"), true);
        });
      });
    });
  }

  function wireSide(el) {
    el.querySelector("#jmapClose").addEventListener("click", closeSide);
    el.querySelector("#jmapPin").addEventListener("click", function (ev) {
      var id = st.selected, n = G.node(st.graph, id);
      var ent = st.entity && st.entity.entity;
      var want = !(ent && ent.pinned != null ? ent.pinned : n && n.pinned);
      ev.target.disabled = true;
      postJson("api/jarvis-memory/entity", { id: id, pinned: want }).then(function (d) {
        var e = (d && d.entity) || {};
        var val = e.pinned != null ? !!e.pinned : want;
        if (n) n.pinned = val;
        if (ent) ent.pinned = val;
        if (st.selected === id) renderSide();
        requestDraw();
      }).catch(function () { ev.target.disabled = false; setMsg("Couldn’t change the pin.", true); });
    });
    el.querySelector("#jmapExpand").addEventListener("click", function (ev) {
      var id = st.selected, btn = ev.target;
      btn.disabled = true;
      btn.textContent = "Expanding…";
      var url = G.graphUrl({ center: id, types: st.filters.types, time: st.filters.time, source: st.filters.source }, nowSec());
      getJson(url).then(function (d) {
        var added = G.mergeGraph(st.graph, d, { anchor: id, cap: G.MAX_NODES, protect: [st.selected] });
        updateCount();
        kick();
        btn.textContent = added.length ? "Expanded (+" + added.length + ")" : "Nothing new";
      }).catch(function () {
        btn.disabled = false;
        btn.textContent = "Expand";
        setMsg("Couldn’t expand this node.", true);
      });
    });
    el.querySelector("#jmapFixBtn").addEventListener("click", function () { st.fixOpen = !st.fixOpen; renderSide(); });
    var save = el.querySelector("#jmapSave");
    if (save) save.addEventListener("click", function () {
      var id = st.selected;
      var name = (el.querySelector("#jmapName").value || "").trim();
      var aliases = (el.querySelector("#jmapAliases").value || "").split(",")
        .map(function (s) { return s.trim(); }).filter(Boolean);
      if (!name) { setMsg("The name can’t be empty.", true); return; }
      save.disabled = true;
      postJson("api/jarvis-memory/entity", { id: id, label: name, aliases: aliases }).then(function (d) {
        var ent = (d && d.entity) || {};
        var newId = ent.id != null ? String(ent.id) : id;
        if (newId !== id) {
          G.mergeNodes(st.graph, id, newId, ent);           // renamed onto an existing name: merged
          updateCount();
          kick();
          st.fixOpen = false;
          openNode(newId);
          return;
        }
        var n = G.node(st.graph, id);
        if (n) { n.label = ent.label != null ? String(ent.label) : name; n.aliases = Array.isArray(ent.aliases) ? ent.aliases.slice() : aliases; }
        if (st.entity && st.entity.entity) Object.assign(st.entity.entity, ent.id != null ? ent : { label: name, aliases: aliases });
        renderSide();
        setMsg("Saved.");
        requestDraw();
      }).catch(function (err) {
        save.disabled = false;
        setMsg("Couldn’t save: " + (err && err.message ? err.message : "error"), true);
      });
    });
    var mq = el.querySelector("#jmapMergeQ");
    if (mq) mq.addEventListener("input", function () {
      st.mergeQ = mq.value;
      st.confirmMerge = null;
      var list = el.querySelector("#jmapMergeList");
      if (list) { list.innerHTML = mergeListHtml(); wireMergeList(el); }
    });
    wireMergeList(el);
    el.querySelectorAll(".jmap-unlink").forEach(function (b) {
      b.addEventListener("click", function () {
        var id = st.selected, mem = b.getAttribute("data-mem");
        b.disabled = true;
        postJson("api/jarvis-memory/entity/unlink", { memory_id: mem, entity_id: id }).then(function () {
          if (st.entity && st.entity.memories) {
            st.entity.memories = st.entity.memories.filter(function (m) { return String(m.id) !== mem; });
          }
          var n = G.node(st.graph, id);
          if (n) n.weight = Math.max(0, n.weight - 1);
          if (st.selected === id) renderSide();
          requestDraw();
        }).catch(function () { b.disabled = false; setMsg("Couldn’t remove that link.", true); });
      });
    });
  }

  // ── public ──
  function show() {
    readColors();
    resize();
    if (!st.loaded && !st.loading) loadBase();
    else kick();
  }

  window.MemoryMap = {
    mount: mount,
    show: show,
    stop: stop,
    reload: function () { clearHighlight(true); return loadBase(); },
    highlightRecall: highlightRecall,
  };

  document.addEventListener("visibilitychange", function () { if (!document.hidden && visible()) kick(); });
})();

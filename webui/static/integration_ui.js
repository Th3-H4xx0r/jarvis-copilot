/* Integration UI on the web: draws the same JSON tree the iPhone draws for an
 * integration's card and page (validated by jarvis_registry/ui.py), for regular
 * integrations and Power integrations alike. The UI never changes data itself:
 * every control runs an action on the server (ctx.onAction) and the new state
 * comes back.
 *
 *   JCIntegrationUI.render(tree, state, ctx) -> HTMLElement
 *   ctx = { onAction(name, event) -> Promise<{state, toast, error}>, doc? }
 */
(function (root) {
  'use strict';

  function dig(obj, path) {
    if (obj == null || path == null) return undefined;
    if (Object.prototype.hasOwnProperty.call(obj, path)) return obj[path];   // flat widget keys win
    var cur = obj;
    var parts = String(path).split('.');
    for (var i = 0; i < parts.length; i++) {
      if (cur == null) return undefined;
      cur = cur[parts[i]];
    }
    return cur;
  }

  /** A prop's value: a literal, {"$": "state.path"}, or {"$row": "row.path"}; "default" fills gaps. */
  function resolve(v, state, row) {
    if (v && typeof v === 'object' && !Array.isArray(v)) {
      var out;
      if ('$' in v) out = dig(state, v.$);
      else if ('$row' in v) out = dig(row, v.$row);
      else return v;
      return out === undefined || out === null ? v['default'] : out;
    }
    return v;
  }

  function truthy(x) { return !(x === undefined || x === null || x === false || x === 0 || x === ''); }

  function cond(expr, state, row) {
    if (expr == null) return true;
    if (typeof expr !== 'object') return truthy(expr);
    if ('$' in expr || '$row' in expr) return truthy(resolve(expr, state, row));
    var op = Object.keys(expr)[0];
    var a = expr[op];
    var val = function (x) { return resolve(x, state, row); };
    switch (op) {
      case 'and': return (a || []).every(function (e) { return cond(e, state, row); });
      case 'or': return (a || []).some(function (e) { return cond(e, state, row); });
      case 'not': return !cond(a, state, row);
      case 'exists': return val(a) !== undefined && val(a) !== null;
      case 'eq': return val(a[0]) == val(a[1]);  // eslint-disable-line eqeqeq
      case 'ne': return val(a[0]) != val(a[1]);  // eslint-disable-line eqeqeq
      case 'gt': return Number(val(a[0])) > Number(val(a[1]));
      case 'lt': return Number(val(a[0])) < Number(val(a[1]));
      case 'between': return Number(val(a[0])) >= Number(val(a[1])) && Number(val(a[0])) <= Number(val(a[2]));
      default: return true;
    }
  }

  function text(v) {
    if (v === undefined || v === null) return '';
    if (typeof v === 'number') return String(Math.round(v * 100) / 100);
    if (typeof v === 'object') return '';
    return String(v);
  }

  function make(ctx, tag, cls, content) {
    var e = ctx.doc.createElement(tag);
    if (cls) e.className = cls;
    if (content !== undefined) e.textContent = content;
    return e;
  }

  function sparkSVG(ctx, points, cls) {
    var nums = (points || []).map(Number).filter(function (n) { return !isNaN(n); });
    var svg = make(ctx, 'div', cls);
    if (nums.length < 2) return svg;
    var min = Math.min.apply(null, nums), max = Math.max.apply(null, nums), span = (max - min) || 1;
    var d = nums.map(function (n, i) {
      return (i ? 'L' : 'M') + (i * 100 / (nums.length - 1)).toFixed(1) + ',' + (30 - (n - min) / span * 28 - 1).toFixed(1);
    }).join(' ');
    svg.innerHTML = '<svg viewBox="0 0 100 30" preserveAspectRatio="none"><path d="' + d +
      '" fill="none" stroke="currentColor" stroke-width="1.5" vector-effect="non-scaling-stroke"/></svg>';
    return svg;
  }

  function runAction(ctx, name, extra) {
    if (!name || !ctx.onAction) return;
    var confirmText = ctx.confirms && ctx.confirms[name];
    var go = function () { return ctx.onAction(name, extra || {}); };
    if (confirmText && ctx.confirmSheet) ctx.confirmSheet(confirmText, go);
    else go();
  }

  function node(n, ctx, state, row) {
    if (!n || typeof n !== 'object') return null;
    if (n.when !== undefined && !cond(n.when, state, row)) return null;
    var t = n.type;
    var p = function (k) { return resolve(n[k], state, row); };
    var e;
    switch (t) {
      case 'vstack': case 'hstack': case 'zstack': case 'hscroll': case 'grid': case 'section':
        e = make(ctx, 'div', 'jci-' + t);
        if (t === 'grid') e.style.gridTemplateColumns = 'repeat(' + (n.columns || 2) + ', minmax(0, 1fr))';
        if (t === 'section' && (n.title !== undefined || n.subtitle !== undefined)) {
          if (n.title !== undefined) e.appendChild(make(ctx, 'div', 'jci-section-title', text(p('title'))));
          if (n.subtitle !== undefined) e.appendChild(make(ctx, 'div', 'jci-muted', text(p('subtitle'))));
        }
        (n.children || []).forEach(function (c) {
          var child = node(c, ctx, state, row);
          if (child) {
            if (t === 'grid' && c && c.span) child.style.gridColumn = 'span ' + c.span;
            e.appendChild(child);
          }
        });
        break;
      case 'list':
        e = make(ctx, 'div', 'jci-list');
        var items = p('data');
        items = Array.isArray(items) ? items : [];
        if (n.max) items = items.slice(0, n.max);
        if (!items.length && n.empty) {
          var empty = node(n.empty, ctx, state, row);
          if (empty) e.appendChild(empty);
        }
        items.forEach(function (item) {
          var r = node(n.row, ctx, state, item);
          if (r) e.appendChild(r);
        });
        break;
      case 'spacer': e = make(ctx, 'div', 'jci-spacer'); break;
      case 'divider': e = make(ctx, 'hr', 'jci-divider'); break;
      case 'text': e = make(ctx, 'div', 'jci-text', text(p('value'))); break;
      case 'titleSubtitle':
        e = make(ctx, 'div', 'jci-titlesub');
        e.appendChild(make(ctx, 'div', 'jci-title', text(p('title'))));
        e.appendChild(make(ctx, 'div', 'jci-muted', text(p('subtitle'))));
        break;
      case 'stat':
        e = make(ctx, 'div', 'jci-stat');
        var v = make(ctx, 'div', 'jci-stat-value', text(p('value')));
        if (n.unit !== undefined) v.appendChild(make(ctx, 'span', 'jci-stat-unit', ' ' + text(p('unit'))));
        e.appendChild(v);
        if (n.caption !== undefined) e.appendChild(make(ctx, 'div', 'jci-muted', text(p('caption'))));
        break;
      case 'symbol': e = make(ctx, 'span', 'jci-symbol', '●'); e.title = text(p('name')); break;
      case 'symbolValue':
        e = make(ctx, 'div', 'jci-symbolvalue');
        e.appendChild(make(ctx, 'span', 'jci-symbol', '●'));
        e.appendChild(make(ctx, 'span', '', ' ' + text(p('value'))));
        break;
      case 'image':
        e = make(ctx, 'img', 'jci-image');
        var src = text(p('source'));
        if (/^https?:|^data:/.test(src)) e.src = src; else e.alt = text(p('fallback')) || src;
        break;
      case 'dot': e = make(ctx, 'span', 'jci-dot'); e.style.background = text(p('color')) || 'currentColor'; break;
      case 'badge': e = make(ctx, 'span', 'jci-badge', text(p('text'))); break;
      case 'progress':
        e = make(ctx, 'div', 'jci-progress');
        var bar = make(ctx, 'div', 'jci-progress-fill');
        bar.style.width = Math.max(0, Math.min(1, Number(p('value')) || 0)) * 100 + '%';
        e.appendChild(bar);
        break;
      case 'segbar':
        e = make(ctx, 'div', 'jci-segbar');
        (p('segments') || []).forEach(function (s) {
          var seg = make(ctx, 'div', 'jci-seg');
          seg.style.flex = String(Number(s && s.weight != null ? s.weight : 1) || 1);
          e.appendChild(seg);
        });
        break;
      case 'gauge':
        e = make(ctx, 'div', 'jci-gauge');
        var rings = n.rings || (n.value !== undefined ? [{ value: n.value }] : []);
        rings.forEach(function (ring) {
          var pct = Math.round(Math.max(0, Math.min(1, Number(resolve(ring.value, state, row)) || 0)) * 100);
          e.appendChild(make(ctx, 'div', 'jci-gauge-ring', pct + '%'));
        });
        if (n.label !== undefined) e.appendChild(make(ctx, 'div', 'jci-muted', text(p('label'))));
        break;
      case 'timer': case 'timeProgress':
        e = make(ctx, 'div', 'jci-text', text(p('to'))); break;
      case 'keyValue':
        e = make(ctx, 'div', 'jci-kv');
        (n.pairs || []).forEach(function (pair) {
          var r2 = make(ctx, 'div', 'jci-kv-row');
          r2.appendChild(make(ctx, 'span', 'jci-muted', text(resolve(pair.label, state, row))));
          r2.appendChild(make(ctx, 'span', '', text(resolve(pair.value, state, row))));
          e.appendChild(r2);
        });
        break;
      case 'sparkline': e = sparkSVG(ctx, p('points'), 'jci-sparkline'); break;
      case 'chart':
        var series = p('series') || [];
        var first = Array.isArray(series) && series.length ? series[0] : null;
        var pts = first && Array.isArray(first.points) ? first.points.map(function (q) {
          return typeof q === 'object' && q ? q.y : q;
        }) : (Array.isArray(series) ? series : []);
        e = sparkSVG(ctx, pts, 'jci-chart');
        break;
      case 'iconStrip':
        e = make(ctx, 'div', 'jci-iconstrip');
        (p('items') || []).forEach(function () { e.appendChild(make(ctx, 'span', 'jci-symbol', '●')); });
        break;
      case 'waveform': e = make(ctx, 'div', 'jci-waveform', '▁▃▅▃▁'); break;
      case 'accent': e = make(ctx, 'div', 'jci-accent'); break;
      case 'model': e = make(ctx, 'div', 'jci-model', text(n.device)); break;
      case 'row':
        e = make(ctx, 'div', 'jci-row');
        if (n.check !== undefined) {
          e.appendChild(make(ctx, 'span', 'jci-check', truthy(p('check')) ? '✓' : '○'));
        }
        var mid = make(ctx, 'div', 'jci-row-text');
        mid.appendChild(make(ctx, 'div', 'jci-title', text(p('title'))));
        if (n.subtitle !== undefined) mid.appendChild(make(ctx, 'div', 'jci-muted', text(p('subtitle'))));
        e.appendChild(mid);
        if (n.trailing !== undefined) e.appendChild(make(ctx, 'span', 'jci-muted', text(p('trailing'))));
        if (n.action) {
          e.classList.add('jci-tappable');
          e.addEventListener('click', function () { runAction(ctx, n.action, { control: n.id, row: row }); });
        }
        break;
      case 'button':
        e = make(ctx, 'button', 'jci-button' + (n.role ? ' jci-' + n.role : '') + (n.full ? ' jci-full' : ''), text(p('label')));
        e.type = 'button';
        e.addEventListener('click', function () { runAction(ctx, n.action, { control: n.id, row: row }); });
        break;
      case 'toggle':
        e = make(ctx, 'label', 'jci-toggle');
        e.appendChild(make(ctx, 'span', '', text(p('label'))));
        var box = make(ctx, 'input');
        box.type = 'checkbox';
        box.checked = truthy(p('value'));
        box.addEventListener('change', function () {
          runAction(ctx, n.action, { control: n.id, value: box.checked, row: row });
        });
        e.appendChild(box);
        break;
      case 'textField':
        e = make(ctx, 'input', 'jci-input');
        e.type = n.keyboard === 'number' ? 'number' : (n.keyboard === 'email' ? 'email' : 'text');
        e.placeholder = text(p('placeholder'));
        e.value = text(p('value'));
        if (n.submit) {
          e.addEventListener('keydown', function (ev) {
            if (ev.key === 'Enter') runAction(ctx, n.submit, { control: n.id, value: e.value, row: row });
          });
        }
        break;
      case 'picker':
        e = make(ctx, 'select', 'jci-picker');
        (n.options || []).forEach(function (o) {
          var opt = make(ctx, 'option', '', text(resolve(o.label, state, row)));
          opt.value = text(o.value);
          e.appendChild(opt);
        });
        e.value = text(p('value'));
        e.addEventListener('change', function () { runAction(ctx, n.action, { control: n.id, value: e.value, row: row }); });
        break;
      case 'slider': case 'stepper':
        e = make(ctx, 'input', 'jci-' + t);
        e.type = t === 'slider' ? 'range' : 'number';
        if (n.min !== undefined) e.min = text(p('min'));
        if (n.max !== undefined) e.max = text(p('max'));
        if (n.step !== undefined) e.step = text(p('step'));
        e.value = text(p('value'));
        e.addEventListener('change', function () {
          runAction(ctx, n.action, { control: n.id, value: Number(e.value), row: row });
        });
        break;
      case 'date':
        e = make(ctx, 'input', 'jci-date');
        e.type = n.mode === 'time' ? 'time' : (n.mode === 'dateTime' ? 'datetime-local' : 'date');
        e.value = text(p('value'));
        e.addEventListener('change', function () { runAction(ctx, n.action, { control: n.id, value: e.value, row: row }); });
        break;
      default:
        return null;
    }
    e.setAttribute('data-node', t);
    return e;
  }

  function render(tree, state, ctx) {
    ctx = ctx || {};
    ctx.doc = ctx.doc || (typeof document !== 'undefined' ? document : null);
    var wrap = make(ctx, 'div', 'jci-root');
    var built = node(tree, ctx, state || {}, null);
    if (built) wrap.appendChild(built);
    return wrap;
  }

  var api = { render: render, resolve: resolve, condition: cond };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.JCIntegrationUI = api;
})(this);

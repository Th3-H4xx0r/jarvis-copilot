// What a schedule runs on: Default (the server's default model), a model, or a
// harness. The schedule form (Tasks and Integrations) shows one "Runs on"
// select whose values are:
//   'default' · 'model:@provider:model' · 'harness:<id>'
// Model groups come from HarnessGraph.modelOptions(api/models groups), the
// harnesses from window.Harness.list(); the server's job carries `runs_on`
// ({kind, label, value, missing?}).
// UMD: window.CronRunsOn in the page, require() under `node --test`.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.CronRunsOn = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }

  const tr = (ctx, key, fallback) => {
    const fn = ctx && typeof ctx.t === 'function' ? ctx.t : null;
    const v = fn ? fn(key) : '';
    return v && v !== key ? v : fallback;
  };

  // The editor value for a job.
  function valueFor(job) {
    if (!job) return 'default';
    if (job.runs_on && job.runs_on.value) return String(job.runs_on.value);
    if (job.harness_id) return `harness:${job.harness_id}`;
    if (job.model) {
      const m = String(job.model);
      return `model:${m.startsWith('@') || !job.provider ? m : `@${job.provider}:${m}`}`;
    }
    return 'default';
  }

  // The create/update fields for a value. Every field is sent so an edit can
  // clear the others: a job runs on exactly one of Default, a model, a harness.
  function body(value) {
    const v = String(value || 'default');
    if (v.startsWith('harness:') && v.length > 8) return { model: '', provider: '', harness_id: v.slice(8) };
    if (v.startsWith('model:') && v.length > 6) return { model: v.slice(6), provider: '', harness_id: '' };
    return { model: '', provider: '', harness_id: '' };
  }

  function modelLabel(ref, ctx) {
    for (const g of (ctx && ctx.modelGroups) || []) {
      const o = (g.options || []).find(x => x.value === ref);
      if (o) return o.label;
    }
    const m = String(ref || '');
    return m.startsWith('@') ? m.slice(m.indexOf(':') + 1) : m;
  }

  function harnessLabel(h) {
    return `${h.icon ? h.icon + ' ' : ''}${h.name || h.id}`;
  }

  // What the detail view and the integration badge say.
  function label(job, ctx) {
    const v = valueFor(job);
    const ro = (job && job.runs_on) || {};
    if (v.startsWith('harness:')) {
      const id = v.slice(8);
      const h = ((ctx && ctx.harnesses) || []).find(x => x.id === id);
      const name = h ? harnessLabel(h) : (ro.label || id);
      return ro.missing && !h ? `${name} (${tr(ctx, 'cron_runs_on_missing', 'not found — runs on Default')})` : name;
    }
    if (v.startsWith('model:')) return modelLabel(v.slice(6), ctx);
    return tr(ctx, 'cron_runs_on_default', 'Default');
  }

  // <option>/<optgroup> HTML for the select. A current value the lists don't
  // know (a model off the catalog, a deleted harness) stays as its own option,
  // so saving the form never changes it behind the user's back.
  function optionsHtml(selected, ctx) {
    const cur = String(selected || 'default');
    const opt = (v, l) => `<option value="${esc(v)}"${v === cur ? ' selected' : ''}>${esc(l)}</option>`;
    const known = new Set(['default']);
    const def = tr(ctx, 'cron_runs_on_default', 'Default') + (ctx && ctx.defaultModel ? ` (${ctx.defaultModel})` : '');
    const models = tr(ctx, 'cron_runs_on_models', 'Models');
    let groups = ((ctx && ctx.modelGroups) || []).map(g => {
      const opts = (g.options || []).map(o => { known.add(`model:${o.value}`); return opt(`model:${o.value}`, o.label); });
      return opts.length ? `<optgroup label="${esc(`${models} · ${g.label}`)}">${opts.join('')}</optgroup>` : '';
    }).join('');
    const harnesses = (ctx && ctx.harnesses) || [];
    if (harnesses.length) {
      groups += `<optgroup label="${esc(tr(ctx, 'cron_runs_on_harnesses', 'Harnesses'))}">` + harnesses.map(h => {
        known.add(`harness:${h.id}`);
        return opt(`harness:${h.id}`, harnessLabel(h));
      }).join('') + '</optgroup>';
    }
    const extra = known.has(cur) ? '' : opt(cur, `${label({ runs_on: (ctx && ctx.currentRunsOn) || { value: cur } }, ctx)} (current)`);
    return opt('default', def) + extra + groups;
  }

  return { valueFor, body, label, optionsHtml, modelLabel };
});

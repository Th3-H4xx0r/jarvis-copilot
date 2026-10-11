// The "answered by" line under an assistant reply (agent harnesses): which
// model answered, how long it took, and whether it handed off. Formats the
// server's turn_meta / persisted _meta dict:
//   {kind: 'answer'|'background'|'review', model, ms?, handed_off?, note?,
//    route?: {label, by, model, confidence?, ms, error?}, ...}
// UMD: window.HarnessFormat in the page, require() under `node --test`.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.HarnessFormat = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  // "@claude-code:claude-sonnet-5-5" -> "Claude Sonnet 5.5"; "@x:gemma4:31b" -> "gemma4:31b".
  function shortModel(ref) {
    let m = String(ref || '').trim();
    if (m.startsWith('@')) m = m.slice(m.indexOf(':') + 1);
    if (m.includes('/')) m = m.slice(m.lastIndexOf('/') + 1);
    const c = m.match(/^claude-(opus|sonnet|haiku)-(\d+)(?:[-.](\d{1,2})(?!\d))?/i);
    if (c) return `Claude ${c[1][0].toUpperCase()}${c[1].slice(1).toLowerCase()} ${c[2]}${c[3] ? '.' + c[3] : ''}`;
    return m;
  }

  function secs(ms) {
    const s = (Number(ms) || 0) / 1000;
    return s < 10 ? `${s.toFixed(1)} s` : `${Math.round(s)} s`;
  }

  // Background and review replies arrive as their own assistant messages.
  function isSideReply(meta) {
    return !!(meta && (meta.kind === 'background' || meta.kind === 'review'));
  }

  // "routed deep 82%" — which wire a Route node picked (meta.route).
  function routedText(route) {
    if (!route || !route.label) return '';
    if (route.error) return 'routed default (router failed)';
    const pct = typeof route.confidence === 'number' ? ` ${Math.round(route.confidence * 100)}%` : '';
    return `routed ${route.label}${pct}`;
  }

  function answeredBy(meta) {
    if (!meta || !meta.model) return '';
    const parts = [shortModel(meta.model)];
    if (isSideReply(meta)) parts.push(meta.kind);
    if (meta.ms) parts.push(secs(meta.ms));
    const routed = isSideReply(meta) ? '' : routedText(meta.route);
    if (routed) parts.push(routed);
    if (meta.handed_off) parts.push('handed off');
    if (meta.note) parts.push(String(meta.note));
    return parts.join(' · ');
  }

  return { answeredBy, routedText, shortModel, isSideReply };
});

/* The Jarvis loader (styles live in loader.css — change the look there).
 *   jcLoader()                          → the default style, sized to the text
 *   jcLoader({style: 'draw', size: 20})  → a named style at 20px
 *   jcLoader({label: 'Loading…'})        → loader then a muted label
 * Returns an HTML string; the label is escaped. */
(function () {
  function esc(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }
  window.jcLoader = function jcLoader(opts) {
    const o = opts || {};
    const cls = 'jc-loader' + (o.style ? ' jc-loader--' + String(o.style).replace(/[^a-z0-9-]/gi, '') : '');
    const size = o.size ? ` style="--jc-loader-size:${Number(o.size) || 16}px"` : '';
    const spin = `<span class="${cls}"${size} role="status" aria-label="${esc(o.label || 'Loading')}"></span>`;
    return o.label ? `<span class="jc-loader-row">${spin}<span>${esc(o.label)}</span></span>` : spin;
  };
})();
